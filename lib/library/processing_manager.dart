// ProcessingManager — pre-process the library in the background (SPEC: auto-queue).
//
// Periodically: checks the engine daemon is up, enqueues every library title that
// has no Hebrew sidecar yet, polls job status, and exposes per-title state so the
// Library can show "Queued / Translating … / Ready". This realizes the spec's
// "pre-process first" model — titles get translated ahead of time, ready to watch.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/engine_client.dart';
import 'library_store.dart';

const String _targetLang = 'he';

class ProcessingManager extends ChangeNotifier {
  ProcessingManager(this.store, {EngineClient? engine})
      : engine = engine ?? EngineClient();

  final LibraryStore store;
  final EngineClient engine;

  bool _engineOnline = false;
  bool get engineOnline => _engineOnline;

  /// Latest job per video path.
  final Map<String, EngineJob> _byPath = {};

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

  /// Clear local job tracking and the daemon's queued jobs (used when the
  /// library is cleared). A job already running on the daemon finishes.
  Future<void> clearQueue() async {
    _byPath.clear();
    notifyListeners();
    try {
      await engine.clearJobs();
    } catch (_) {
      // Daemon offline or hiccup — local state is already cleared.
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

      // Enqueue any untranslated title we're not already tracking.
      for (final e in store.entries) {
        if (e.hasSidecar(_targetLang)) continue;
        final existing = _byPath[e.path];
        if (existing == null || existing.state == 'failed') {
          try {
            _byPath[e.path] = await engine.enqueue(e.path, target: _targetLang);
          } catch (_) {
            // Daemon hiccup — retry next tick.
          }
        }
      }

      // Refresh statuses.
      try {
        for (final j in await engine.getJobs()) {
          _byPath[j.path] = j;
        }
      } catch (_) {}

      notifyListeners();
    } finally {
      _ticking = false;
    }
  }
}
