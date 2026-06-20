// PlayerPage — media_kit / libmpv playback with an external RTL subtitle.
//
// Loads a local video path and an external `.srt` sidecar (SPEC §3: portable
// sidecar next to media). Renders the translated-only Hebrew track right-to-left.
//
// v0 status: API is fully wired against media_kit; the default path points at a
// placeholder so the widget runs even before the engine produces real media.
//
// IMPORTANT (licensing, SPEC §3): the media_kit libs we depend on must be the
// playback-only, LGPL-safe libmpv build. Never enable FFmpeg `--enable-gpl`.

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Plays [videoPath] with an external subtitle sidecar [subtitlePath].
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    this.videoPath,
    this.subtitlePath,
  });

  /// Absolute path or URL to the video. When null, nothing is opened (v0 stub).
  final String? videoPath;

  /// Absolute path to the external `.srt`/`.ass` sidecar.
  final String? subtitlePath;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player;
  late final VideoController _controller;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _maybeOpen();
  }

  Future<void> _maybeOpen() async {
    final path = widget.videoPath;
    if (path == null) return;

    // Open the media. We pass `play: false` so the user starts it explicitly.
    await _player.open(Media(path), play: false);

    // Attach the external subtitle sidecar, if provided.
    final sub = widget.subtitlePath;
    if (sub != null) {
      // TODO(v0): confirm encoding (UTF-8) + RTL rendering once real Hebrew
      // sidecars exist. media_kit forwards this to libmpv's sub-add.
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(sub, title: 'Hebrew', language: 'he'),
      );
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
        appBar: AppBar(title: const Text('Player')),
        body: Center(
          child: widget.videoPath == null
              ? const Text(
                  'No media loaded.\nv0: pick an MKV from the Library.',
                  textAlign: TextAlign.center,
                )
              : Video(controller: _controller),
        ),
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
