// PlaybackProgressStore — resuming has to feel right, which is mostly about the
// two thresholds: don't resume from the first minute, and don't resume into the
// end credits.

import 'dart:io';

import 'package:autosub_media_player/player/playback_progress.dart';
import 'package:flutter_test/flutter_test.dart';

PlaybackProgress at(Duration position, {Duration? duration}) => PlaybackProgress(
      position: position,
      duration: duration ?? const Duration(minutes: 45),
      updatedAtMs: 0,
    );

void main() {
  group('resume thresholds', () {
    test('the first minute is not worth resuming', () {
      expect(at(const Duration(seconds: 20)).resumePosition, isNull);
      expect(at(const Duration(seconds: 59)).resumePosition, isNull);
      expect(at(const Duration(seconds: 61)).resumePosition,
          const Duration(seconds: 61));
    });

    test('the end credits count as watched, not as a resume point', () {
      final almostOver = at(const Duration(minutes: 44, seconds: 30));
      expect(almostOver.isWatched, isTrue);
      expect(almostOver.resumePosition, isNull);
    });

    test('a mid-film position is resumable and reports a fraction', () {
      final half = at(const Duration(minutes: 22, seconds: 30));
      expect(half.isWatched, isFalse);
      expect(half.resumePosition, const Duration(minutes: 22, seconds: 30));
      expect(half.fraction, closeTo(0.5, 0.01));
    });

    test('an unknown duration is never "watched" and has no fraction', () {
      final unknown = at(const Duration(minutes: 5), duration: Duration.zero);
      expect(unknown.isWatched, isFalse);
      expect(unknown.fraction, isNull);
      expect(unknown.resumePosition, const Duration(minutes: 5));
    });
  });

  group('store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('progress'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('persists positions across a restart', () async {
      final store = PlaybackProgressStore(directory: dir);
      store.record('/films/a.mkv', const Duration(minutes: 10),
          const Duration(minutes: 90));
      await store.flush();

      final reopened = PlaybackProgressStore(directory: dir);
      await reopened.load();
      expect(reopened.progressFor('/films/a.mkv')?.position,
          const Duration(minutes: 10));
    });

    test('ignores the zero position a player reports while opening', () async {
      final store = PlaybackProgressStore(directory: dir);
      store.record('/films/a.mkv', const Duration(minutes: 10),
          const Duration(minutes: 90));
      // A freshly-opened player emits 0 before it seeks; that must not wipe the
      // saved position out from under the resume.
      store.record('/films/a.mkv', Duration.zero, const Duration(minutes: 90));
      expect(store.progressFor('/films/a.mkv')?.position,
          const Duration(minutes: 10));
    });

    test('"start over" forgets one title only', () async {
      final store = PlaybackProgressStore(directory: dir);
      store.record('/films/a.mkv', const Duration(minutes: 10),
          const Duration(minutes: 90));
      store.record('/films/b.mkv', const Duration(minutes: 20),
          const Duration(minutes: 90));
      await store.clearFor('/films/a.mkv');

      expect(store.progressFor('/films/a.mkv'), isNull);
      expect(store.progressFor('/films/b.mkv'), isNotNull);
    });

    test('continue watching lists resumable titles, most recent first', () async {
      final store = PlaybackProgressStore(directory: dir);
      store.record('/films/old.mkv', const Duration(minutes: 10),
          const Duration(minutes: 90));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      store.record('/films/new.mkv', const Duration(minutes: 30),
          const Duration(minutes: 90));
      // Barely started and already finished are both excluded.
      store.record('/films/sampled.mkv', const Duration(seconds: 10),
          const Duration(minutes: 90));
      store.record('/films/done.mkv', const Duration(minutes: 89, seconds: 30),
          const Duration(minutes: 90));

      expect(store.continueWatching(), ['/films/new.mkv', '/films/old.mkv']);
    });
  });
}
