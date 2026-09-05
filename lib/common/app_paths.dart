// AutoSubPaths — durable non-affected user data directory.
//
// Saves user preferences, progressions, library, metadata, finished jobs results,
// and artifacts in `~/.autosub` (or $AUTOSUB_DATA_DIR) which survives app restarts,
// uninstalls, reinstalls, updates, and code changes.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AutoSubPaths {
  AutoSubPaths._();

  static Directory? _cachedDataDir;

  /// Root directory for all persistent AutoSub user data.
  static Directory dataDirectory({Directory? override}) {
    if (override != null) return override;
    if (_cachedDataDir != null) return _cachedDataDir!;

    final envVar = Platform.environment['AUTOSUB_DATA_DIR'];
    final Directory dir;
    if (envVar != null && envVar.trim().isNotEmpty) {
      dir = Directory(envVar.trim());
    } else {
      final home = Platform.environment['HOME'];
      if (home != null && home.trim().isNotEmpty) {
        dir = Directory(p.join(home.trim(), '.autosub'));
      } else {
        // Fallback for environments where HOME is unset
        dir = Directory(p.join(Directory.systemTemp.path, '.autosub'));
      }
    }

    if (!dir.existsSync()) {
      try {
        dir.createSync(recursive: true);
      } catch (_) {}
    }
    return _cachedDataDir = dir;
  }

  static String dataDirectoryPath({Directory? override}) =>
      dataDirectory(override: override).path;

  static File settingsFile({Directory? directory}) =>
      File(p.join(dataDirectory(override: directory).path, 'settings.json'));

  static File playbackProgressFile({Directory? directory}) =>
      File(p.join(dataDirectory(override: directory).path, 'playback_progress.json'));

  static File libraryFile({Directory? directory}) =>
      File(p.join(dataDirectory(override: directory).path, 'library.json'));

  static File metadataFile({Directory? directory}) =>
      File(p.join(dataDirectory(override: directory).path, 'metadata.json'));

  static Directory postersDir({Directory? directory}) {
    final d = Directory(p.join(dataDirectory(override: directory).path, 'posters'));
    if (!d.existsSync()) {
      try {
        d.createSync(recursive: true);
      } catch (_) {}
    }
    return d;
  }

  static File databaseFile({Directory? directory}) =>
      File(p.join(dataDirectory(override: directory).path, 'autosub.sqlite'));

  static Directory checkpointsDir({Directory? directory}) {
    final d = Directory(p.join(dataDirectory(override: directory).path, 'checkpoints'));
    if (!d.existsSync()) {
      try {
        d.createSync(recursive: true);
      } catch (_) {}
    }
    return d;
  }

  static Directory cacheDir({Directory? directory}) {
    final d = Directory(p.join(dataDirectory(override: directory).path, 'cache'));
    if (!d.existsSync()) {
      try {
        d.createSync(recursive: true);
      } catch (_) {}
    }
    return d;
  }

  /// Automatically copy existing files from legacy Application Support
  /// directory into ~/.autosub if they exist and haven't been migrated yet.
  static Future<void> migrateFromLegacySupport({Directory? targetDirectory}) async {
    final target = dataDirectory(override: targetDirectory);
    try {
      final legacy = await getApplicationSupportDirectory();
      if (!legacy.existsSync()) return;

      final filesToMigrate = [
        'settings.json',
        'playback_progress.json',
        'library.json',
        'metadata.json',
      ];

      for (final fileName in filesToMigrate) {
        final legacyFile = File(p.join(legacy.path, fileName));
        final targetFile = File(p.join(target.path, fileName));
        if (legacyFile.existsSync() && !targetFile.existsSync()) {
          try {
            await legacyFile.copy(targetFile.path);
          } catch (_) {}
        }
      }

      // Migrate posters directory if present
      final legacyPosters = Directory(p.join(legacy.path, 'posters'));
      final targetPosters = Directory(p.join(target.path, 'posters'));
      if (legacyPosters.existsSync()) {
        if (!targetPosters.existsSync()) targetPosters.createSync(recursive: true);
        for (final entry in legacyPosters.listSync()) {
          if (entry is File) {
            final dest = File(p.join(targetPosters.path, p.basename(entry.path)));
            if (!dest.existsSync()) {
              try {
                entry.copySync(dest.path);
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {
      // Best-effort migration; ignores sandbox or permission quirks
    }
  }

  /// Reset in-memory cached data dir (useful for unit testing).
  static void resetCacheForTesting() {
    _cachedDataDir = null;
  }
}
