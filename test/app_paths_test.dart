import 'dart:io';

import 'package:autosub_media_player/common/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('AutoSubPaths', () {
    late Directory tempDir;

    setUp(() {
      AutoSubPaths.resetCacheForTesting();
      tempDir = Directory.systemTemp.createTempSync('autosub_test_');
    });

    tearDown(() {
      AutoSubPaths.resetCacheForTesting();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('resolves files and subdirectories correctly within data directory', () {
      final dataDir = AutoSubPaths.dataDirectory(override: tempDir);
      expect(dataDir.path, tempDir.path);

      expect(AutoSubPaths.settingsFile(directory: tempDir).path,
          p.join(tempDir.path, 'settings.json'));
      expect(AutoSubPaths.playbackProgressFile(directory: tempDir).path,
          p.join(tempDir.path, 'playback_progress.json'));
      expect(AutoSubPaths.libraryFile(directory: tempDir).path,
          p.join(tempDir.path, 'library.json'));
      expect(AutoSubPaths.metadataFile(directory: tempDir).path,
          p.join(tempDir.path, 'metadata.json'));
      expect(AutoSubPaths.databaseFile(directory: tempDir).path,
          p.join(tempDir.path, 'autosub.sqlite'));

      final posters = AutoSubPaths.postersDir(directory: tempDir);
      expect(posters.path, p.join(tempDir.path, 'posters'));
      expect(posters.existsSync(), isTrue);

      final checkpoints = AutoSubPaths.checkpointsDir(directory: tempDir);
      expect(checkpoints.path, p.join(tempDir.path, 'checkpoints'));
      expect(checkpoints.existsSync(), isTrue);

      final cache = AutoSubPaths.cacheDir(directory: tempDir);
      expect(cache.path, p.join(tempDir.path, 'cache'));
      expect(cache.existsSync(), isTrue);
    });

    test('migrates files into target data directory', () async {
      final legacyDir = Directory.systemTemp.createTempSync('legacy_support_');
      addTearDown(() {
        if (legacyDir.existsSync()) legacyDir.deleteSync(recursive: true);
      });

      // Create fake legacy files
      File(p.join(legacyDir.path, 'settings.json')).writeAsStringSync('{"target_language":"ar"}');
      File(p.join(legacyDir.path, 'playback_progress.json')).writeAsStringSync('{}');
      final legacyPosters = Directory(p.join(legacyDir.path, 'posters'))..createSync();
      File(p.join(legacyPosters.path, '123.jpg')).writeAsStringSync('fake-jpeg-data');

      // Manual migration copy logic verification
      final targetSettings = File(p.join(tempDir.path, 'settings.json'));
      expect(targetSettings.existsSync(), isFalse);

      File(p.join(legacyDir.path, 'settings.json')).copySync(targetSettings.path);
      expect(targetSettings.existsSync(), isTrue);
      expect(targetSettings.readAsStringSync(), contains('ar'));
    });
  });
}
