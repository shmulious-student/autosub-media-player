// AutoSub Media Player — Flutter app entry (SPEC §9).
//
// v0: a simple home with navigation to the Library and the Player. The Mac
// native engine (SwiftPM package under `engine/`) does the heavy AI; this shell
// talks to it over loopback HTTP via EngineClient.

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'engine/engine_client.dart';
import 'library/library_page.dart';
import 'player/player_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Required one-time init for media_kit / libmpv.
  MediaKit.ensureInitialized();
  runApp(const AutoSubApp());
}

class AutoSubApp extends StatelessWidget {
  const AutoSubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AutoSub Media Player',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final engine = EngineClient();
    return Scaffold(
      appBar: AppBar(title: const Text('AutoSub Media Player')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'v0 vertical slice (Mac)',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.video_library),
              label: const Text('Library'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => LibraryPage(engine: engine),
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.play_circle),
              label: const Text('Player (no media)'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const PlayerPage(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
