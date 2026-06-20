// PlayerPage — media_kit / libmpv playback with an external RTL subtitle.
//
// Loads a local video path and an external `.srt` sidecar (SPEC §3: portable
// sidecar next to media). Renders the translated-only Hebrew track right-to-left.
// When no sidecar is passed it auto-detects a sibling `<name>.he.srt`.
//
// IMPORTANT (licensing, SPEC §3): the media_kit libs we depend on must be the
// playback-only, LGPL-safe libmpv build. Never enable FFmpeg `--enable-gpl`.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

const String _defaultTargetLang = 'he';

/// Plays [videoPath] with an external subtitle sidecar.
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    this.videoPath,
    this.subtitlePath,
    this.title,
    this.autoPlay = false,
    this.loop = false,
  });

  /// Absolute path or URL to the video. When null, nothing is opened.
  final String? videoPath;

  /// Absolute path to the external `.srt`/`.ass` sidecar. When null, a sibling
  /// `<name>.he.srt` is auto-detected.
  final String? subtitlePath;

  /// Display name for the app bar.
  final String? title;

  /// Start playback immediately once media + subtitle are loaded.
  final bool autoPlay;

  /// Loop playback (used by the dev fixture so a subtitle is always on screen).
  final bool loop;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  String? _subStatus;

  @override
  void initState() {
    super.initState();
    _player = Player();
    // Disable hardware-accelerated rendering: on macOS the HW path can stall to
    // a spinner with no frame (libmpv decodes fine headless). Software rendering
    // is reliable for v0; revisit HW accel per-codec later.
    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: false,
      ),
    );
    _maybeOpen();
  }

  /// Resolve the subtitle: explicit path, else a sibling `<base>.he.srt`.
  String? _resolveSubtitle(String videoPath) {
    if (widget.subtitlePath != null) return widget.subtitlePath;
    final sibling = p.join(p.dirname(videoPath),
        '${p.basenameWithoutExtension(videoPath)}.$_defaultTargetLang.srt');
    try {
      if (File(sibling).existsSync()) return sibling;
    } catch (_) {
      // Sandbox may block sibling access unless a folder was granted.
    }
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
      // media_kit forwards this to libmpv's sub-add; our sidecars are UTF-8 with
      // RTL embedding controls (SrtAssembler), so Hebrew renders right-to-left.
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(sub, title: 'Hebrew', language: _defaultTargetLang),
      );
      if (mounted) setState(() => _subStatus = 'Hebrew subtitles loaded');
    } else {
      if (mounted) setState(() => _subStatus = 'No subtitles for this title');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Force RTL so the subtitle overlay + any controls lay out correctly for
    // Hebrew (SPEC: RTL is a first-class requirement).
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title ?? 'Player'),
          bottom: _subStatus == null
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(20),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(_subStatus!,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ),
        ),
        // The Video widget must fill its constraints — wrapping it in a Center
        // collapses it to 0×0 (nothing renders). Give it the whole body.
        body: widget.videoPath == null
            ? const Center(
                child: Text(
                  'No media loaded.\nOpen a video from the Library.',
                  textAlign: TextAlign.center,
                ),
              )
            : Video(controller: _controller),
        floatingActionButton: widget.videoPath == null
            ? null
            : FloatingActionButton(
                onPressed: () => _player.playOrPause(),
                child: const Icon(Icons.play_arrow),
              ),
      ),
    );
  }
}
