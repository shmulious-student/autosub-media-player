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

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../settings/app_settings.dart';
import '../ui/tokens.dart';
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
  });

  final String? videoPath;
  final String? subtitlePath;
  final String? title;
  final bool autoPlay;
  final bool loop;
  final AppSettings? settings;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;

  SubtitleTrack? _loadedSub; // the Hebrew track, when one exists
  bool _subOn = true;
  String? _subStatus;
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
    _maybeOpen();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {});
  }

  String? _resolveSubtitle(String videoPath) {
    if (widget.subtitlePath != null) return widget.subtitlePath;
    final sibling = p.join(
      p.dirname(videoPath),
      '${p.basenameWithoutExtension(videoPath)}.$_defaultTargetLang.srt',
    );
    try {
      if (File(sibling).existsSync()) return sibling;
    } catch (_) {}
    return null;
  }

  Future<void> _maybeOpen() async {
    final path = widget.videoPath;
    if (path == null) return;

    await _player.open(Media(path), play: widget.autoPlay);
    if (widget.loop) {
      await _player.setPlaylistMode(PlaylistMode.loop);
    }

    final sub = _resolveSubtitle(path);
    if (sub != null) {
      final track = SubtitleTrack.uri(
        sub,
        title: 'Hebrew',
        language: _defaultTargetLang,
      );
      _loadedSub = track;
      await _player.setSubtitleTrack(track);
      if (mounted) {
        setState(() {
          _subOn = true;
          _subStatus = 'Hebrew subtitles loaded';
        });
      }
    } else {
      if (mounted) setState(() => _subStatus = 'No subtitles for this title');
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
              },
              child: Focus(
                autofocus: true,
                child: Video(
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
                ),
              ),
            ),
    );
  }
}
