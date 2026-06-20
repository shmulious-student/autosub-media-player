// AutoSub Media Player — Flutter app entry (SPEC §9).
//
// Home is the Library: open any video (or add a folder) and play it with its
// generated Hebrew sidecar. The app LAUNCHES the engine daemon as a child process
// (EngineSupervisor) — the engine does the heavy AI and, as the app's child,
// inherits the app's file-access prompt (no sandbox / Full Disk Access needed).

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'engine/engine_supervisor.dart';
import 'library/library_page.dart';
import 'library/library_store.dart';
import 'library/processing_manager.dart';
import 'player/player_page.dart';

/// Dev convenience: build with `--dart-define=DEV_FIXTURE=true` to launch straight
/// into the fixture player.
const bool kDevFixture = bool.fromEnvironment('DEV_FIXTURE');
const String kFixtureVideo =
    '/Volumes/EP2TB/autosub-media-player/fixtures/sample.mkv';
const String kFixtureSub =
    '/Volumes/EP2TB/autosub-media-player/fixtures/sample.he.srt';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Required one-time init for media_kit / libmpv.
  MediaKit.ensureInitialized();

  // Launch + supervise the engine daemon as a child of this app.
  final engine = EngineSupervisor()..start();

  final store = LibraryStore();
  await store.load();

  // Pre-process the library in the background (translate un-subtitled titles).
  final manager = ProcessingManager(store)..start();

  runApp(AutoSubApp(store: store, manager: manager, engine: engine));
}

class AutoSubApp extends StatefulWidget {
  const AutoSubApp({
    super.key,
    required this.store,
    required this.manager,
    required this.engine,
  });

  final LibraryStore store;
  final ProcessingManager manager;
  final EngineSupervisor engine;

  @override
  State<AutoSubApp> createState() => _AutoSubAppState();
}

class _AutoSubAppState extends State<AutoSubApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.engine.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Kill the child engine when the app is shutting down (no orphans).
    if (state == AppLifecycleState.detached) widget.engine.stop();
  }

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
          : LibraryPage(store: widget.store, manager: widget.manager),
    );
  }
}
