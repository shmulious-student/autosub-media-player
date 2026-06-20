// LibraryPage — placeholder grid of scanned titles (SPEC §1 Plex-like hub).
//
// v0 status: STUB. Pulls the (empty) library index from the EngineClient and
// renders a grid. Tapping a title would route to the PlayerPage with its video
// path + produced `.srt` sidecar.

import 'package:flutter/material.dart';

// Prefixed: our `Title` entity collides with Flutter's `Title` widget.
import '../data/models.dart' as models;
import '../engine/engine_client.dart';
import '../player/player_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.engine});

  final EngineClient engine;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late Future<List<models.Title>> _titles;

  @override
  void initState() {
    super.initState();
    _titles = widget.engine.getLibraryIndex();
  }

  void _openTitle(models.Title title) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          videoPath: title.path,
          // TODO(v0): resolve the produced sidecar path for this title from the
          // engine's SubtitleArtifact index instead of guessing `.srt`.
          subtitlePath: null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      body: FutureBuilder<List<models.Title>>(
        future: _titles,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final titles = snap.data ?? const <models.Title>[];
          if (titles.isEmpty) {
            return const Center(
              child: Text(
                'Library is empty.\nv0: point the engine at a folder to scan.',
                textAlign: TextAlign.center,
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate:
                const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              childAspectRatio: 2 / 3,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: titles.length,
            itemBuilder: (context, i) {
              final t = titles[i];
              return InkWell(
                onTap: () => _openTitle(t),
                child: Card(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(t.path.split('/').last),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
