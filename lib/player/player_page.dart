// PlayerPage — media_kit playback with an external RTL subtitle.
//
// Loads a local video + an external `.srt` sidecar (SPEC §3: portable sidecar next
// to media) and renders the translated-only Hebrew track. The on-screen subtitle
// is drawn by media_kit_video's SubtitleView overlay, with RTL limited to subtitle
// text and transport chrome pinned LTR (RTL.md §2). Full keyboard map per
// DESIGN_SYSTEM §6.4; ←/→ are always seek-back/forward, never mirrored.
//
// Three things here exist because they have to work WHILE watching, not in a
// settings screen you leave the film for: the subtitle offset (Z/X, persisted per
// title), the dual-language stack (D), and cue looping (A). Anything that makes
// the viewer exit fullscreen to fix a 200ms drift has already failed.
//
// IMPORTANT (licensing, SPEC §3): media_kit must be the playback-only, LGPL-safe
// libmpv build. Never enable FFmpeg `--enable-gpl`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../library/processing_manager.dart';
import '../metadata/subtitle_source.dart';
import '../settings/app_settings.dart';
import '../subtitle/subtitle_appearance.dart';
import '../ui/components/toast.dart';
import '../ui/tokens.dart';
import 'cue_track.dart';
import 'dual_subtitle_view.dart';
import 'playback_progress.dart';
import 'preparing_pill.dart';
import 'subtitle_runway.dart';
import 'transport_bar.dart';

const String _defaultTargetLang = 'he';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    this.videoPath,
    this.subtitlePath,
    this.title,
    this.autoPlay = false,
    this.loop = false,
    this.settings,
    this.manager,
    this.progress,
  });

  final String? videoPath;
  final String? subtitlePath;
  final String? title;
  final bool autoPlay;
  final bool loop;
  final AppSettings? settings;

  /// Lets the player ask the engine to prepare THIS title first and watch the
  /// sidecar appear. Null in previews/tests: playback still works, there is just
  /// nothing preparing subtitles in the background.
  final ProcessingManager? manager;

  /// Where the viewer stopped last time. Null in previews/tests: playback then
  /// simply always starts from the beginning.
  final PlaybackProgressStore? progress;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;

  SubtitleTrack? _loadedSub; // the Hebrew track, when one exists
  bool _subOn = true;
  String? _subStatus;
  SubtitleRunway? _runway;
  int _appliedRevision = -1;
  bool _announcedSubtitles = false;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  Timer? _progressTimer;
  bool _resumeApplied = false;

  /// Subtitle timing offset in milliseconds. Sidecar and ASR tracks are routinely
  /// a few hundred ms out against a particular release, and the fix has to be
  /// available WHILE watching — by the time you notice, you are mid-scene.
  int _subDelayMs = 0;
  bool _delayRestored = false;

  /// The Hebrew cues, parsed alongside the track mpv is rendering. mpv will not
  /// tell us where the current cue starts and ends, and cue looping is exactly
  /// that question.
  CueTrack _cues = const CueTrack.empty();

  /// The original-language cues, when a source sidecar exists — the second line
  /// of the dual-language stack.
  CueTrack _secondaryCues = const CueTrack.empty();
  bool _dualSubOn = false;

  /// While set, playback jumps back to the start of this cue every time it runs
  /// past the end — the "loop this sentence" study mode.
  ({Duration start, Duration end})? _loopingCue;

  BuildContext? _controlsContext; // captured inside the Video subtree

  SubtitleViewConfiguration get _subtitleViewConfiguration {
    final appearance = widget.settings?.subtitleAppearance;
    if (appearance == null) return const SubtitleViewConfiguration();
    return SubtitleViewConfiguration(
      style: appearance.textStyle(),
      textAlign: TextAlign.center,
      padding: appearance.padding(),
    );
  }

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: false,
      ),
    );
    widget.settings?.addListener(_onSettingsChanged);
    _startRunway();
    _maybeOpen();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _maybeOpen() async {
    final path = widget.videoPath;
    if (path == null) return;

    // Open FIRST. Nothing about subtitle preparation is allowed to delay the
    // first frame — everything else in this class happens after playback starts.
    await _player.open(Media(path), play: widget.autoPlay);
    if (widget.loop) {
      await _player.setPlaylistMode(PlaylistMode.loop);
    }

    // The runway needs the media duration to tell "prepared to the end" from
    // "prepared up to here".
    _durationSub = _player.stream.duration.listen((d) {
      _runway?.setMediaDuration(d);
      _maybeResume(d);
    });
    _positionSub = _player.stream.position.listen((pos) {
      _position = pos;
      _maybeLoopCue(pos);
    });
    _restoreSubtitleDelay();
    _loadSecondaryCues();
    // Record every 10s rather than on every position tick: the store debounces
    // its writes anyway, and this keeps the resume point fresh if the app is
    // force-quit.
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) => _recordProgress());

    await _applyRunwaySubtitle();
    // Only now, with the picture already up, ask the engine to prepare this title
    // ahead of whatever the background sweep was doing.
    if (_runway?.isComplete != true) {
      unawaited(_runway?.requestPreparation());
    }
  }

  Duration _position = Duration.zero;

  /// Re-apply the offset the viewer settled on last time for this title.
  ///
  /// A sidecar that is 300ms early is 300ms early on every sitting, so making
  /// them re-discover and re-nudge it each time is the actual defect.
  void _restoreSubtitleDelay() {
    if (_delayRestored) return;
    final path = widget.videoPath;
    final store = widget.progress;
    if (path == null || store == null) return;
    _delayRestored = true;
    final saved = store.subtitleDelayFor(path);
    if (saved != 0) unawaited(_applySubtitleDelay(saved, announce: false));
  }

  /// Find the cached original-language sidecar, if the source resolver wrote one.
  /// Its language is whatever the film was in, so we look for any of them.
  void _loadSecondaryCues() {
    final path = widget.videoPath;
    if (path == null) return;
    for (final lang in const ['en', 'es', 'fr', 'de', 'it', 'ru', 'ja']) {
      final found = SourceSubtitleCache.existingPath(
        videoPath: path,
        lang: lang,
      );
      if (found == null) continue;
      final track = CueTrack.fromFile(found);
      if (track.isEmpty) continue;
      if (!mounted) return;
      setState(() => _secondaryCues = track);
      return;
    }
  }

  /// Seek to the saved position once the duration is known (a resume point is
  /// meaningless until we can tell it from the end of the film).
  void _maybeResume(Duration duration) {
    if (_resumeApplied || duration <= Duration.zero) return;
    final path = widget.videoPath;
    final store = widget.progress;
    if (path == null || store == null) return;
    _resumeApplied = true;

    final resume = store.progressFor(path)?.resumePosition;
    if (resume == null || resume >= duration) return;
    unawaited(_player.seek(resume));
    if (!mounted) return;
    showToast(
      context,
      'Resumed from ${_clock(resume)}',
      actionLabel: 'Start over',
      onAction: () {
        unawaited(_player.seek(Duration.zero));
        unawaited(store.clearFor(path));
      },
    );
  }

  static String _clock(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  void _recordProgress() {
    final path = widget.videoPath;
    final store = widget.progress;
    if (path == null || store == null || !_resumeApplied) return;
    store.record(path, _position, _player.state.duration);
  }

  /// Nudge the subtitle timing. mpv owns `sub-delay` (in seconds, positive = the
  /// subtitle appears later), so we push it straight through rather than
  /// rewriting the cue file.
  Future<void> _nudgeSubtitleDelay(int deltaMs) =>
      _applySubtitleDelay(_subDelayMs + deltaMs);

  /// Set the offset to an absolute value, push it to mpv, and remember it.
  ///
  /// [announce] is false when restoring a saved offset on open: the viewer chose
  /// it on a previous sitting and does not need to be told about their own
  /// setting every time the film starts.
  Future<void> _applySubtitleDelay(int delayMs, {bool announce = true}) async {
    final next = delayMs.clamp(-30000, 30000);
    if (next == _subDelayMs && announce) return;
    _subDelayMs = next;
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('sub-delay', (next / 1000).toStringAsFixed(3));
    }
    final path = widget.videoPath;
    if (path != null) widget.progress?.recordSubtitleDelay(path, next);
    if (!mounted) return;
    setState(() {});
    if (!announce) return;
    showToast(
      context,
      next == 0
          ? 'Subtitle delay reset'
          : 'Subtitle delay ${next > 0 ? '+' : ''}$next ms',
    );
  }

  /// Replay the line currently on screen, and keep replaying it until the viewer
  /// says otherwise. The second press of the same key releases the loop, so the
  /// study gesture is one key, not a mode to remember exiting.
  void _toggleCueLoop() {
    if (_loopingCue != null) {
      setState(() => _loopingCue = null);
      showToast(context, 'Cue loop off');
      return;
    }
    final cue = _cues.cueForReplay(
      _player.state.position,
      offset: Duration(milliseconds: _subDelayMs),
    );
    if (cue == null) {
      showToast(context, 'No subtitle line here to loop');
      return;
    }
    final offset = Duration(milliseconds: _subDelayMs);
    setState(() => _loopingCue = (start: cue.start + offset, end: cue.end + offset));
    unawaited(_player.seek(cue.start + offset));
    showToast(context, 'Looping this line — press A again to stop');
  }

  /// Jump back to the start of the current line once, without looping.
  void _replayCue() {
    final cue = _cues.cueForReplay(
      _player.state.position,
      offset: Duration(milliseconds: _subDelayMs),
    );
    if (cue == null) return;
    unawaited(_player.seek(cue.start + Duration(milliseconds: _subDelayMs)));
  }

  /// Called on every position tick: the loop is enforced here rather than with a
  /// timer so it tracks seeks the viewer makes themselves.
  void _maybeLoopCue(Duration pos) {
    final loop = _loopingCue;
    if (loop == null) return;
    // A seek well outside the cue is the viewer moving on — drop the loop rather
    // than yanking them back.
    if (pos < loop.start - const Duration(seconds: 2)) {
      if (mounted) setState(() => _loopingCue = null);
      return;
    }
    if (pos >= loop.end) unawaited(_player.seek(loop.start));
  }

  void _toggleDualSubtitles() {
    if (_secondaryCues.isEmpty) {
      showToast(context, 'No original-language subtitles for this title');
      return;
    }
    setState(() => _dualSubOn = !_dualSubOn);
  }

  void _startRunway() {
    final path = widget.videoPath;
    if (path == null) return;
    final runway = SubtitleRunway(
      videoPath: path,
      lang: _defaultTargetLang,
      manager: widget.manager,
    );
    // An explicitly-passed subtitle wins, so a caller can still pin a file.
    _runway = runway;
    runway.addListener(_onRunwayChanged);
    runway.start();
  }

  void _onRunwayChanged() {
    if (!mounted) return;
    setState(() {}); // refresh the pill
    unawaited(_applyRunwaySubtitle());
  }

  /// Load (or hot-swap) the subtitle track for whatever is on disk right now.
  ///
  /// This runs mid-playback: the draft written by the progressive strategy is
  /// replaced by the final pass, and the viewer sees the better track appear
  /// without the video so much as stuttering. Position is untouched by
  /// `setSubtitleTrack`, so there is nothing to restore.
  Future<void> _applyRunwaySubtitle() async {
    final runway = _runway;
    final path = widget.subtitlePath ?? runway?.path;
    if (path == null) {
      if (mounted && _subStatus == null) {
        setState(() => _subStatus = 'Subtitles will appear when they are ready');
      }
      return;
    }
    // A pinned subtitle is loaded once; a runway one reloads on every revision.
    final revision = widget.subtitlePath != null ? 0 : (runway?.revision ?? 0);
    if (revision == _appliedRevision) return;
    _appliedRevision = revision;

    final track = SubtitleTrack.uri(
      path,
      title: 'Hebrew',
      language: _defaultTargetLang,
    );
    _loadedSub = track;
    // Keep our own cue index in step with the track mpv renders: the hot-swap
    // replaces a draft with the final pass, and a stale index would loop the
    // wrong line.
    _cues = CueTrack.fromFile(path);
    if (_subOn) await _player.setSubtitleTrack(track);
    if (!mounted) return;
    setState(() => _subStatus = null);

    // Announce the arrival once — a track appearing mid-film is easy to miss.
    if (!_announcedSubtitles && widget.subtitlePath == null) {
      _announcedSubtitles = true;
      showToast(context, 'Hebrew subtitles are ready',
          variant: ToastVariant.success);
    }
  }

  Future<void> _toggleSubtitles() async {
    if (_loadedSub == null) return;
    if (_subOn) {
      await _player.setSubtitleTrack(SubtitleTrack.no());
    } else {
      await _player.setSubtitleTrack(_loadedSub!);
    }
    if (mounted) setState(() => _subOn = !_subOn);
  }

  void _seekBy(Duration delta) {
    final target = _player.state.position + delta;
    final dur = _player.state.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > dur ? dur : target);
    _player.seek(clamped);
  }

  void _nudgeVolume(double delta) {
    final v = (_player.state.volume + delta).clamp(0.0, 100.0);
    _player.setVolume(v);
  }

  void _toggleFullscreen() {
    final ctx = _controlsContext;
    if (ctx == null) return;
    try {
      toggleFullscreen(ctx);
    } catch (_) {
      // Fullscreen helper needs the Video subtree context; ignore if unavailable.
    }
  }

  @override
  void dispose() {
    widget.settings?.removeListener(_onSettingsChanged);
    _recordProgress();
    unawaited(widget.progress?.flush());
    _progressTimer?.cancel();
    _durationSub?.cancel();
    _positionSub?.cancel();
    _runway?.removeListener(_onRunwayChanged);
    _runway?.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: AppColors.neutral950,
        elevation: 0,
        title: Text(widget.title ?? 'Player', style: AppType.subtitle),
        bottom: _subStatus == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(22),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: AppSpacing.x4,
                    bottom: AppSpacing.x1,
                  ),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      _subStatus!,
                      style: AppType.bodySm.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
      ),
      body: widget.videoPath == null
          ? const Center(
              child: Text(
                'No media loaded.\nOpen a video from the Library.',
                textAlign: TextAlign.center,
              ),
            )
          : CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.space): () =>
                    _player.playOrPause(),
                const SingleActivator(LogicalKeyboardKey.keyK): () =>
                    _player.playOrPause(),
                // ←/→ are ALWAYS seek (never mirrored under RTL — RTL.md §2).
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                    _seekBy(const Duration(seconds: -10)),
                const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                    _seekBy(const Duration(seconds: 10)),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                    _nudgeVolume(10),
                const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                    _nudgeVolume(-10),
                const SingleActivator(LogicalKeyboardKey.keyS):
                    _toggleSubtitles,
                const SingleActivator(LogicalKeyboardKey.keyF):
                    _toggleFullscreen,
                // , / . nudge subtitle timing by 100 ms (mpv's own convention).
                const SingleActivator(LogicalKeyboardKey.comma): () =>
                    unawaited(_nudgeSubtitleDelay(-100)),
                const SingleActivator(LogicalKeyboardKey.period): () =>
                    unawaited(_nudgeSubtitleDelay(100)),
                const SingleActivator(LogicalKeyboardKey.slash): () =>
                    unawaited(_applySubtitleDelay(0)),
                // Z / X are the precision pair: 50 ms is about the smallest drift
                // a viewer can actually hear, and sits under the left hand.
                const SingleActivator(LogicalKeyboardKey.keyZ): () =>
                    unawaited(_nudgeSubtitleDelay(-50)),
                const SingleActivator(LogicalKeyboardKey.keyX): () =>
                    unawaited(_nudgeSubtitleDelay(50)),
                const SingleActivator(LogicalKeyboardKey.keyD):
                    _toggleDualSubtitles,
                // A loops the current line; ⇧A replays it once. (The blueprint
                // put replay on S, which is already subtitle toggle.)
                const SingleActivator(LogicalKeyboardKey.keyA): _toggleCueLoop,
                const SingleActivator(LogicalKeyboardKey.keyA, shift: true):
                    _replayCue,
              },
              child: Focus(
                autofocus: true,
                child: Stack(
                  children: [
                    Positioned.fill(child: _video()),
                    // The secondary language rides above the primary overlay that
                    // media_kit draws; it is decoration, never a hit target.
                    if (_dualSubOn && _secondaryCues.isNotEmpty)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DualSubtitleView(
                            player: _player,
                            track: _secondaryCues,
                            appearance: widget.settings?.subtitleAppearance ??
                                const SubtitleAppearance(),
                            offset: Duration(milliseconds: _subDelayMs),
                          ),
                        ),
                      ),
                    // Preparation state sits over the picture, never in front of it.
                    if (_runway != null)
                      PositionedDirectional(
                        top: AppSpacing.x4,
                        start: AppSpacing.x4,
                        child: PreparingPill(
                          runway: _runway!,
                          onRetry: () =>
                              unawaited(_runway!.requestPreparation(force: true)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _video() => Video(
        controller: _controller,
        subtitleViewConfiguration: _subtitleViewConfiguration,
        controls: (state) => Builder(
          builder: (ctx) {
            _controlsContext = ctx;
            return TransportBar(
              player: _player,
              subtitlesAvailable: _loadedSub != null,
              subtitlesOn: _subOn,
              onToggleSubtitles: _toggleSubtitles,
              isFullscreen: isFullscreen(ctx),
              onToggleFullscreen: () => toggleFullscreen(ctx),
              subtitleDelayMs: _subDelayMs,
              onNudgeSubtitleDelay: (delta) =>
                  unawaited(_nudgeSubtitleDelay(delta)),
              onResetSubtitleDelay: () => unawaited(_applySubtitleDelay(0)),
              readyThrough:
                  _runway?.isComplete == true ? null : _runway?.readyThrough,
              dualSubtitlesAvailable: _secondaryCues.isNotEmpty,
              dualSubtitlesOn: _dualSubOn,
              onToggleDualSubtitles: _toggleDualSubtitles,
            );
          },
        ),
      );
}
