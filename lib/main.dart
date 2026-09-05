// AutoSub Media Player — Flutter app entry (SPEC §9).
//
// Home is the app shell (Library · Queue · Settings). The app LAUNCHES the engine
// daemon as a child process (EngineSupervisor) — the engine does the heavy AI and,
// as the app's child, inherits the app's file-access prompt.
//
// Theme + tokens come from lib/ui/tokens.dart (DESIGN_SYSTEM §3): dark-only for v1,
// warm-amber accent over a cool-graphite base, replacing the old indigo seed.

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import 'engine/engine_client.dart';
import 'engine/engine_supervisor.dart';
import 'library/library_store.dart';
import 'library/processing_manager.dart';
import 'metadata/metadata_store.dart';
import 'metadata/opensubtitles_client.dart';
import 'metadata/podnapisi_client.dart';
import 'metadata/subtitle_source.dart';
import 'metadata/title_metadata.dart';
import 'player/player_page.dart';
import 'settings/app_settings.dart';
import 'shell/app_shell.dart';
import 'ui/tokens.dart';
import 'wizard/first_run_wizard.dart';
import 'player/playback_progress.dart';

/// Dev convenience: build with `--dart-define=DEV_FIXTURE=true` to launch straight
/// into the fixture player.
const bool kDevFixture = bool.fromEnvironment('DEV_FIXTURE');

/// UI-only runs: build with `--dart-define=NO_ENGINE=true` to skip launching the
/// engine daemon AND the background auto-translate sweep — so no heavy AI models
/// (WhisperKit / DictaLM / llama-server) are loaded. Use this for visual/UI
/// verification where the engine isn't needed.
const bool kNoEngine = bool.fromEnvironment('NO_ENGINE');
const String kFixtureVideo =
    '/Volumes/EP2TB/autosub-media-player/fixtures/sample.mkv';
const String kFixtureSub =
    '/Volumes/EP2TB/autosub-media-player/fixtures/sample.he.srt';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Required one-time init for media_kit / libmpv.
  MediaKit.ensureInitialized();

  // Launch + supervise the engine daemon as a child of this app (unless this is
  // a UI-only run — see kNoEngine — in which case no models are ever loaded).
  final engine = EngineSupervisor();
  if (!kNoEngine) engine.start();

  final settings = AppSettings();
  await settings.load();

  final store = LibraryStore();
  await store.load();

  // Where the viewer stopped watching each title, so reopening resumes.
  final progress = PlaybackProgressStore();
  await progress.load();

  // TMDB metadata + official posters for the library. The key comes from Settings
  // (stored locally), with a --dart-define=TMDB_API_KEY fallback for dev runs.
  final metadata = MetadataStore(
    apiKey: () => settings.tmdbApiKey.isNotEmpty
        ? settings.tmdbApiKey
        : const String.fromEnvironment('TMDB_API_KEY'),
  );
  await metadata.load();

  // Original-language subtitle providers. OpenSubtitles is optional/keyed; Podnapisi
  // is keyless. The resolver ranks candidates and writes the engine source sidecar.
  final openSubs = OpenSubtitlesClient(
    apiKey: () => settings.openSubtitlesApiKey.isNotEmpty
        ? settings.openSubtitlesApiKey
        : const String.fromEnvironment('OPENSUBTITLES_API_KEY'),
  );
  final sourceResolver = SubtitleSourceResolver(
    providers: [openSubs, PodnapisiClient()],
  );

  final engineClient = EngineClient();

  Future<({String lang, TitleMetadata? metadata})?> sourceContextFor(
    String path, {
    bool allowDefault = false,
  }) async {
    await metadata.enrich(path);
    final m = metadata.metadataFor(path);
    final audioLang = await engineClient.audioLanguage(path);
    final rawLang =
        audioLang ?? (m?.hasMatch == true ? m!.originalLanguage : null);
    if (rawLang == null) {
      return allowDefault
          ? (lang: 'en', metadata: m?.hasMatch == true ? m : null)
          : null;
    }
    final lang = SourceSubtitleCache.normalizeLang(rawLang);
    final target = SourceSubtitleCache.normalizeLang(settings.targetLanguage);
    if (!allowDefault && lang == target) return null;
    return (lang: lang, metadata: m?.hasMatch == true ? m : null);
  }

  // Pre-process the library in the background (translate un-subtitled titles).
  // Skipped under kNoEngine so the AI models stay unloaded. The manager reads the
  // user's chosen translation strategy live at enqueue time, and (best-effort) a
  // fetched source subtitle so the translator works from exact dialogue, not ASR.
  final manager = ProcessingManager(
    store,
    engine: engineClient,
    strategy: () => settings.translationStrategy.wire,
    fetchSourceSubtitle: (path, {bool force = false}) async {
      final source = await sourceContextFor(path);
      if (source == null) return null;
      final m = source.metadata;
      return sourceResolver.fetchBest(
        force: force,
        query: SourceSubtitleQuery(
          videoPath: path,
          originalLanguage: source.lang,
          tmdbId: m?.tmdbId,
          season: m?.season,
          episode: m?.episode,
          year: m?.year,
          query: m?.name ?? p.basenameWithoutExtension(path),
        ),
      );
    },
    importSourceSubtitleFile: (path, filePath) async {
      final source = await sourceContextFor(path, allowDefault: true);
      if (source == null) return null;
      return SourceSubtitleCache.importFile(
        videoPath: path,
        lang: source.lang,
        filePath: filePath,
      );
    },
    importSourceSubtitleUrl: (path, uri) async {
      final source = await sourceContextFor(path, allowDefault: true);
      if (source == null) return null;
      return sourceResolver.importUrl(
        videoPath: path,
        lang: source.lang,
        uri: uri,
      );
    },
    // Cast/crew gender map (TMDB credits) → deterministic speaker/addressee inflection.
    charactersFor: (path) async {
      await metadata.enrich(path); // match fresh titles
      final chars = await metadata.ensureCredits(
        path,
      ); // backfill credits if missing
      return chars.isNotEmpty ? chars : null;
    },
    // Gate the auto-sweep: finish enrichment (TMDB match + credits) BEFORE translating,
    // so the source subtitle + character genders are ready. No key → nothing to wait
    // for (translate via ASR). Not-ready (still matching / transient error) → wait for
    // the next tick.
    ensureEnriched: (path) async {
      if (!metadata.hasApiKey) return true;
      await metadata.enrich(path);
      final m = metadata.metadataFor(path);
      if (m == null || !m.searched) return false;
      if (m.hasMatch) await metadata.ensureCredits(path);
      return true;
    },
  );
  if (!kNoEngine) manager.start();

  runApp(
    AutoSubApp(
      store: store,
      progress: progress,
      manager: manager,
      metadata: metadata,
      settings: settings,
      engine: engine,
    ),
  );
}

class AutoSubApp extends StatefulWidget {
  const AutoSubApp({
    super.key,
    required this.store,
    required this.progress,
    required this.manager,
    required this.metadata,
    required this.settings,
    required this.engine,
  });

  final LibraryStore store;
  final PlaybackProgressStore progress;
  final ProcessingManager manager;
  final MetadataStore metadata;
  final AppSettings settings;
  final EngineSupervisor engine;

  @override
  State<AutoSubApp> createState() => _AutoSubAppState();
}

class _AutoSubAppState extends State<AutoSubApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.settings.addListener(_onSettings);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettings);
    WidgetsBinding.instance.removeObserver(this);
    widget.engine.stop();
    super.dispose();
  }

  void _onSettings() {
    if (mounted) setState(() {}); // re-apply UI text-size scaling
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
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      darkTheme: appTheme(),
      themeMode: ThemeMode.dark,
      // UI text size = the macOS Dynamic-Type substitute (DS §3.2.3). Cap chrome
      // scaling so dense desktop layouts don't break; clamp to the user's choice.
      builder: (context, child) {
        final scale = widget.settings.uiTextSize.scale;
        return MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: kDevFixture
          ? PlayerPage(
              videoPath: kFixtureVideo,
              subtitlePath: kFixtureSub,
              title: 'v0 fixture',
              autoPlay: true,
              loop: true,
              settings: widget.settings,
            )
          : widget.settings.setupComplete
          ? AppShell(
              store: widget.store,
              progress: widget.progress,
              manager: widget.manager,
              metadata: widget.metadata,
              settings: widget.settings,
              engine: widget.engine,
            )
          : FirstRunWizard(
              settings: widget.settings,
              onComplete: () => setState(() {}),
            ),
    );
  }
}
