// AutoSub Media Player — Flutter app entry (SPEC §9).
//
// Home is the Library: open any video (or add a folder) and play it with its
// generated Hebrew sidecar. The Mac native engine (SwiftPM package under
// `engine/`) does the heavy AI; this shell handles browsing + playback.

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'library/library_page.dart';
import 'library/library_store.dart';
import 'player/player_page.dart';

/// Dev convenience: build with `--dart-define=DEV_FIXTURE=true` to launch straight
/// into the fixture player (requires the sandbox-disabled debug build to read the
/// absolute fixture path).
const bool kDevFixture = bool.fromEnvironment('DEV_FIXTURE');
const String kFixtureVideo =
    '/Volumes/EP2TB/autosub-media-player/fixtures/sample.mkv';
const String kFixtureSub =
    '/Volumes/EP2TB/autosub-media-player/fixtures/sample.he.srt';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Required one-time init for media_kit / libmpv.
  MediaKit.ensureInitialized();

  final store = LibraryStore();
  await store.load();

  runApp(AutoSubApp(store: store));
}

class AutoSubApp extends StatelessWidget {
  const AutoSubApp({super.key, required this.store});

  final LibraryStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AutoSub Media Player',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: kDevFixture
          ? const PlayerPage(
              videoPath: kFixtureVideo,
              subtitlePath: kFixtureSub,
              title: 'v0 fixture',
              autoPlay: true,
              loop: true,
            )
          : LibraryPage(store: store),
    );
  }
}
