// PlayerPage — media_kit playback with an external RTL subtitle.
//
// Loads a local video + an external `.srt` sidecar (SPEC §3: portable sidecar next
// to media) and renders the translated-only Hebrew track. The on-screen subtitle
// is drawn by media_kit_video's SubtitleView overlay, with RTL limited to subtitle
// text and transport chrome pinned LTR (RTL.md §2). Full keyboard map per
// DESIGN_SYSTEM §6.4; ←/→ are always seek-back/forward, never mirrored.
//
// IMPORTANT (licensing, SPEC §3): media_kit must be the playback-only, LGPL-safe
// libmpv build. Never enable FFmpeg `--enable-gpl`.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../library/processing_manager.dart';
import '../settings/app_settings.dart';
import '../ui/components/toast.dart';
import '../ui/tokens.dart';
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
    _positionSub = _player.stream.position.listen((pos) => _position = pos);
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
  Future<void> _nudgeSubtitleDelay(int deltaMs) async {
    final next = (_subDelayMs + deltaMs).clamp(-30000, 30000);
    if (next == _subDelayMs) return;
    _subDelayMs = next;
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('sub-delay', (next / 1000).toStringAsFixed(3));
    }
    if (!mounted) return;
    setState(() {});
    showToast(
      context,
      next == 0
          ? 'Subtitle delay reset'
          : 'Subtitle delay ${next > 0 ? '+' : ''}$next ms',
    );
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
                    unawaited(_nudgeSubtitleDelay(-_subDelayMs)),
              },
              child: Focus(
                autofocus: true,
                child: Stack(
                  children: [
                    Positioned.fill(child: _video()),
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
            );
          },
        ),
      );
}
