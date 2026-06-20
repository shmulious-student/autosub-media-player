// EngineSupervisor — launch + supervise the engine daemon as a CHILD of the app.
//
// Because the engine is a child of the (non-sandboxed) GUI app, macOS attributes
// its file access to AutoSub, so the standard "would like to access your Downloads
// folder" prompt covers the engine's ffmpeg too — no Full Disk Access or
// security-scoped bookmarks needed. The supervisor restarts the daemon if it dies
// and kills it when the app exits (no orphans).

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

class EngineSupervisor {
  EngineSupervisor({this.modelsDir = '/Volumes/EP2TB/autosub-models'});

  final String modelsDir;
  Process? _proc;
  bool _stopped = false;

  /// Locate the engine binary: env override → bundled next to the app → dev build.
  String? _resolveBin() {
    final env = Platform.environment['AUTOSUB_ENGINE_BIN'];
    if (env != null && File(env).existsSync()) return env;

    final exeDir = p.dirname(Platform.resolvedExecutable);
    for (final c in [
      p.join(exeDir, 'AutoSubEngine'), // bundled in Contents/MacOS (future)
      p.join(exeDir, '..', 'Resources', 'AutoSubEngine'),
    ]) {
      if (File(c).existsSync()) return c;
    }
    // Dev fallback: the SwiftPM debug build.
    const dev =
        '/Volumes/EP2TB/autosub-media-player/engine/.build/debug/AutoSubEngine';
    return File(dev).existsSync() ? dev : null;
  }

  Future<void> start() async {
    _stopped = false;
    // Clear any stale daemon from a previous run so the port is free.
    try {
      await Process.run('pkill', ['-f', 'AutoSubEngine daemon']);
    } catch (_) {}
    await _spawn();
  }

  Future<void> _spawn() async {
    if (_stopped) return;
    final bin = _resolveBin();
    if (bin == null) {
      stderr.writeln('[EngineSupervisor] engine binary not found');
      return;
    }
    try {
      final proc = await Process.start(
        bin,
        ['daemon'],
        environment: {'AUTOSUB_MODELS': modelsDir},
      );
      _proc = proc;
      // Drain output so the child never blocks on a full pipe.
      proc.stdout.drain<void>();
      proc.stderr.drain<void>();
      unawaited(proc.exitCode.then((_) {
        _proc = null;
        if (!_stopped) {
          Future.delayed(const Duration(seconds: 2), _spawn); // restart
        }
      }));
    } catch (_) {
      if (!_stopped) Future.delayed(const Duration(seconds: 3), _spawn);
    }
  }

  void stop() {
    _stopped = true;
    _proc?.kill();
    _proc = null;
  }
}
