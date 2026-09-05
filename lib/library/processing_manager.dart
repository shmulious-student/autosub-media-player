// ProcessingManager — pre-process the library in the background (SPEC: auto-queue).
//
// Periodically: checks the engine daemon is up, enqueues every library title that
// has no Hebrew sidecar yet, polls job status, and exposes per-title state so the
// Library can show "Queued / Translating … / Ready". This realizes the spec's
// "pre-process first" model — titles get translated ahead of time, ready to watch.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/engine_client.dart';
import '../metadata/subtitle_source.dart';
import 'library_store.dart';

const String _targetLang = 'he';

/// Live timing for a running job: how long it's been going + an estimate of how
/// much longer. ETA is null until there's enough signal to estimate.
class JobTiming {
  const JobTiming({required this.elapsed, this.eta});
  final Duration elapsed;
  final Duration? eta;
}

/// Anchor captured the first time we observe a job running, used to estimate rate.
class _Anchor {
  _Anchor(this.jobId, this.atMs, this.progress);
  final String jobId;
  final int atMs;
  final double progress;
}

class ProcessingManager extends ChangeNotifier {
  ProcessingManager(
    this.store, {
    EngineClient? engine,
    String Function()? strategy,
    Future<SourceSubtitleResult?> Function(String path, {bool force})?
    fetchSourceSubtitle,
    Future<SourceSubtitleResult?> Function(String path, String filePath)?
    importSourceSubtitleFile,
    Future<SourceSubtitleResult?> Function(String path, Uri uri)?
    importSourceSubtitleUrl,
    Future<Map<String, String>?> Function(String path)? charactersFor,
    Future<bool> Function(String path)? ensureEnriched,
  }) : engine = engine ?? EngineClient(),
       _strategy = strategy ?? (() => 'quality'),
       _fetchSourceSubtitle = fetchSourceSubtitle,
       _importSourceSubtitleFile = importSourceSubtitleFile,
       _importSourceSubtitleUrl = importSourceSubtitleUrl,
       _charactersFor = charactersFor,
       _ensureEnriched = ensureEnriched;

  final LibraryStore store;
  final EngineClient engine;

  /// Live read of the user's chosen translation strategy (wire value) at enqueue
  /// time, so changing it in Settings affects newly-queued titles.
  final String Function() _strategy;

  /// Best-effort: fetch/import an original-language subtitle to use as the
  /// translation source. Returns a saved sidecar result or null (then the engine
  /// falls back to ASR). Never throws.
  final Future<SourceSubtitleResult?> Function(String path, {bool force})?
  _fetchSourceSubtitle;

  final Future<SourceSubtitleResult?> Function(String path, String filePath)?
  _importSourceSubtitleFile;

  final Future<SourceSubtitleResult?> Function(String path, Uri uri)?
  _importSourceSubtitleUrl;

  /// Best-effort: known character/person gender map (name → "m"/"f") for the title,
  /// e.g. from TMDB credits, so the translator inflects named people deterministically.
  final Future<Map<String, String>?> Function(String path)? _charactersFor;

  /// Gate the auto-sweep: complete metadata enrichment (TMDB match + credits) BEFORE
  /// a title is enqueued, so translation always has the source subtitle + character
  /// gender map. Returns true when ready (or when there's nothing to wait for — no
  /// key); false means "not ready yet, try again next tick". Never throws.
  final Future<bool> Function(String path)? _ensureEnriched;

  Future<bool> _ready(String path) async {
    final fn = _ensureEnriched;
    if (fn == null) return true;
    try {
      return await fn(path);
    } catch (_) {
      return true; // don't get stuck if enrichment errors — fall through to ASR
    }
  }

  /// Resolve a source subtitle for [path], swallowing any error so a fetch problem
  /// never blocks translation — the engine just transcribes instead.
  Future<SourceSubtitleResult?> _sourceFor(
    String path, {
    bool force = false,
  }) async {
    final fetch = _fetchSourceSubtitle;
    if (fetch == null) return null;
    try {
      return await fetch(path, force: force);
    } catch (_) {
      return null;
    }
  }

  Future<SourceSubtitleResult?> refetchSourceSubtitle(String path) async {
    final result = await _sourceFor(path, force: true);
    notifyListeners();
    return result;
  }

  Future<SourceSubtitleResult?> importSourceSubtitleFile(
    String path,
    String filePath,
  ) async {
    final fn = _importSourceSubtitleFile;
    if (fn == null) return null;
    try {
      final result = await fn(path, filePath);
      notifyListeners();
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<SourceSubtitleResult?> importSourceSubtitleUrl(
    String path,
    Uri uri,
  ) async {
    final fn = _importSourceSubtitleUrl;
    if (fn == null) return null;
    try {
      final result = await fn(path, uri);
      notifyListeners();
      return result;
    } catch (_) {
      return null;
    }
  }

  /// Resolve the character gender map for [path]; null on any error.
  Future<Map<String, String>?> _charsFor(String path) async {
    final fn = _charactersFor;
    if (fn == null) return null;
    try {
      return await fn(path);
    } catch (_) {
      return null;
    }
  }

  bool _engineOnline = false;
  bool get engineOnline => _engineOnline;

  /// Latest job per video path.
  final Map<String, EngineJob> _byPath = {};

  /// Per-path timing anchor (set when a job is first seen running).
  final Map<String, _Anchor> _anchors = {};

  Timer? _timer;
  bool _ticking = false;

  void start({Duration interval = const Duration(seconds: 2)}) {
    if (_timer != null) return;
    unawaited(_tick());
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  EngineJob? jobFor(String path) => _byPath[path];

  /// All jobs the manager is currently tracking (for the Queue view).
  List<EngineJob> get jobs => List.unmodifiable(_byPath.values);

  /// Elapsed time + ETA for a running job, or null if it isn't running. Elapsed is
  /// measured from when we first saw it running; ETA is back-projected from the
  /// observed progress rate (null until there's enough signal — "estimating…").
  JobTiming? timingFor(String path) {
    final j = _byPath[path];
    final a = _anchors[path];
    if (j == null || a == null || j.state != 'running') return null;
    final nowMs = _nowMs();
    final elapsedMs = nowMs - a.atMs;
    Duration? eta;
    final dp = j.progress - a.progress;
    if (dp > 0.005 && elapsedMs > 2000) {
      final ratePerMs = dp / elapsedMs;
      final remMs = ((1 - j.progress) / ratePerMs).round();
      if (remMs >= 0 && remMs < Duration.millisecondsPerDay) {
        eta = Duration(milliseconds: remMs);
      }
    }
    return JobTiming(
      elapsed: Duration(milliseconds: elapsedMs),
      eta: eta,
    );
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Refresh timing anchors against the latest jobs: set an anchor when a job
  /// starts running, drop it when it stops or the job id changes.
  void _reconcileAnchors() {
    final nowMs = _nowMs();
    for (final j in _byPath.values) {
      if (j.state == 'running') {
        final a = _anchors[j.path];
        if (a == null || a.jobId != j.id) {
          _anchors[j.path] = _Anchor(j.id, nowMs, j.progress);
        }
      } else {
        _anchors.remove(j.path);
      }
    }
    _anchors.removeWhere((path, _) => !_byPath.containsKey(path));
  }

  /// Re-enqueue a path (used by the Queue "Retry" action on a failed job). The
  /// daemon creates a fresh job because the previous one is in `failed` state.
  Future<void> retry(
    String path, {
    String target = _targetLang,
    bool force = false,
    bool fetchSource = true,
  }) async {
    try {
      final src = fetchSource ? await _sourceFor(path) : null;
      final chars = await _charsFor(path);
      _byPath[path] = await engine.enqueue(
        path,
        target: target,
        strategy: _strategy(),
        force: force,
        sourceSubtitlePath: src?.path,
        sourceSubtitleOverride: src?.overrideEmbedded ?? false,
        characters: chars,
      );
      notifyListeners();
    } catch (_) {
      // Daemon offline — surfaced by the offline banner; user can retry again.
    }
  }

  /// Force an immediate health + status poll (Reconnect action on the banner).
  Future<void> reconnect() => _tick();

  /// Enqueue translation for a set of paths (e.g. a whole season/series). Paths
  /// that already have a sidecar are skipped.
  Future<void> generateAll(List<String> paths, {bool force = false}) async {
    for (final path in paths) {
      try {
        final src = await _sourceFor(path);
        final chars = await _charsFor(path);
        _byPath[path] = await engine.enqueue(
          path,
          target: _targetLang,
          strategy: _strategy(),
          force: force,
          sourceSubtitlePath: src?.path,
          sourceSubtitleOverride: src?.overrideEmbedded ?? false,
          characters: chars,
        );
      } catch (_) {
        // Daemon hiccup — the auto-sweep will retry.
      }
    }
    notifyListeners();
  }

  /// Move [paths] to the front of the queue. With [preempt], the daemon stops the
  /// running job and re-queues it so a selected title starts immediately. Used by
  /// the right-click "Translate next / Translate now" actions.
  Future<void> prioritize(
    List<String> paths, {
    bool preempt = false,
    bool force = false,
  }) async {
    try {
      // The prioritize endpoint only reorders; it can't carry the fetched source
      // subtitle / gender map. So first (idempotently) create each job WITH them,
      // then reorder — otherwise "Translate now" would fall back to ASR.
      for (final path in paths) {
        if (!force && _byPath.containsKey(path)) continue;
        final src = await _sourceFor(path);
        final chars = await _charsFor(path);
        _byPath[path] = await engine.enqueue(
          path,
          target: _targetLang,
          strategy: _strategy(),
          force: force,
          sourceSubtitlePath: src?.path,
          sourceSubtitleOverride: src?.overrideEmbedded ?? false,
          characters: chars,
        );
      }
      final updated = await engine.prioritize(
        paths,
        target: _targetLang,
        strategy: _strategy(),
        preempt: preempt,
        force: false,
      );
      for (final j in updated) {
        _byPath[j.path] = j;
      }
      _reconcileAnchors();
      notifyListeners();
    } catch (_) {
      // Daemon offline — surfaced by the offline banner.
    }
  }

  /// Clear local job tracking and the daemon's non-running jobs (used when the
  /// library or queue is cleared). A job already running on the daemon finishes.
  Future<void> clearQueue() async {
    _byPath.clear();
    _anchors.clear();
    notifyListeners();
    try {
      await engine.clearJobs();
    } catch (_) {
      // Daemon offline or hiccup — local state is already cleared.
    }
  }

  /// Remove one finished/failed job from the daemon's history log. This is not a
  /// cancellation path; active jobs stay owned by the daemon queue.
  Future<bool> deleteHistoryJob(EngineJob job) async {
    if (job.state != 'done' && job.state != 'failed') return false;
    try {
      await engine.deleteJob(job.id);
      if (_byPath[job.path]?.id == job.id) {
        _byPath.remove(job.path);
      }
      _anchors.remove(job.path);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final online = await engine.health();
      if (online != _engineOnline) {
        _engineOnline = online;
        notifyListeners();
      }
      if (!online) return;

      // Enqueue any untranslated title we're not yet tracking. We do NOT auto-
      // re-enqueue failed jobs (that would hammer the daemon on a persistent
      // error like a permission denial) — failures surface in the UI and a retry
      // is an explicit action.
      for (final e in store.entries) {
        if (e.hasSidecar(_targetLang)) continue;
        if (_byPath.containsKey(e.path)) continue;
        // Don't start translating until enrichment (TMDB match + credits) is done —
        // so the source subtitle + character gender map are ready. Not-ready titles
        // are retried on the next tick.
        if (!await _ready(e.path)) continue;
        try {
          final src = await _sourceFor(e.path);
          final chars = await _charsFor(e.path);
          _byPath[e.path] = await engine.enqueue(
            e.path,
            target: _targetLang,
            strategy: _strategy(),
            sourceSubtitlePath: src?.path,
            sourceSubtitleOverride: src?.overrideEmbedded ?? false,
            characters: chars,
          );
        } catch (_) {
          // Daemon hiccup — retry next tick.
        }
      }

      // Refresh statuses.
      try {
        final remoteJobs = await engine.getJobs();
        final remotePaths = remoteJobs.map((j) => j.path).toSet();
        _byPath.removeWhere((path, _) => !remotePaths.contains(path));
        for (final j in remoteJobs) {
          _byPath[j.path] = j;
        }
      } catch (_) {}

      _reconcileAnchors();
      notifyListeners();
    } finally {
      _ticking = false;
    }
  }
}
