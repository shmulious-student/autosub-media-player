// SubtitleRunway — the object that lets playback start before subtitles exist.
//
// These cover the part that must be right without an engine attached: noticing a
// sidecar appear, noticing it get REWRITTEN (draft upgraded to final) so the
// player hot-swaps, and describing how far the film is actually prepared.

import 'dart:io';

import 'package:autosub_media_player/player/subtitle_runway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String _srt(List<(int startMs, int endMs, String text)> cues) {
  String stamp(int ms) {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    final d = Duration(milliseconds: ms);
    return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:'
        '${two(d.inSeconds.remainder(60))},${three(ms.remainder(1000))}';
  }

  final buf = StringBuffer();
  for (var i = 0; i < cues.length; i++) {
    final (start, end, text) = cues[i];
    buf.writeln('${i + 1}');
    buf.writeln('${stamp(start)} --> ${stamp(end)}');
    buf.writeln(text);
    buf.writeln();
  }
  return buf.toString();
}

void main() {
  late Directory dir;
  late String videoPath;
  late String sidecarPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('runway');
    videoPath = p.join(dir.path, 'Film.mkv');
    File(videoPath).writeAsStringSync('not really a video');
    sidecarPath = p.join(dir.path, 'Film.he.srt');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  SubtitleRunway makeRunway() => SubtitleRunway(
        videoPath: videoPath,
        lang: 'he',
        pollInterval: const Duration(milliseconds: 20),
      );

  test('starts with no subtitles and does not block on them', () {
    final runway = makeRunway()..start();
    addTearDown(runway.dispose);

    expect(runway.hasSubtitles, isFalse);
    expect(runway.readyThrough, isNull);
    // Without an engine there is nothing preparing anything — say so plainly
    // rather than implying work is happening.
    expect(runway.phase, RunwayPhase.none);
  });

  test('picks up a sidecar that appears during playback', () async {
    final runway = makeRunway()..start();
    addTearDown(runway.dispose);
    expect(runway.hasSubtitles, isFalse);

    var notified = 0;
    runway.addListener(() => notified++);
    File(sidecarPath).writeAsStringSync(_srt([(0, 2000, 'שלום')]));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(runway.hasSubtitles, isTrue);
    expect(runway.path, sidecarPath);
    expect(runway.readyThrough, const Duration(seconds: 2));
    expect(notified, greaterThan(0), reason: 'the player must be told to load it');
  });

  test('bumps the revision when a draft is rewritten as the final pass', () async {
    File(sidecarPath).writeAsStringSync(_srt([(0, 2000, 'טיוטה')]));
    final runway = makeRunway()..start();
    addTearDown(runway.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final first = runway.revision;

    // The engine rewrites the same path with the upgraded translation.
    File(sidecarPath).writeAsStringSync(
      _srt([(0, 2000, 'סופי'), (3000, 6000, 'עוד שורה')]),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(runway.revision, greaterThan(first),
        reason: 'a rewritten sidecar must trigger a hot-swap');
    expect(runway.readyThrough, const Duration(seconds: 6));
  });

  test('reports partial preparation until the runway reaches the end', () async {
    File(sidecarPath).writeAsStringSync(_srt([(0, 60000, 'התחלה')]));
    final runway = makeRunway()..start();
    addTearDown(runway.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // A 40-minute film with one minute prepared: watchable, but not finished.
    runway.setMediaDuration(const Duration(minutes: 40));
    expect(runway.isComplete, isFalse);
    expect(runway.phase, RunwayPhase.partial);

    // A one-minute film with the same sidecar is fully prepared.
    runway.setMediaDuration(const Duration(minutes: 1));
    expect(runway.isComplete, isTrue);
    expect(runway.phase, RunwayPhase.ready);
  });

  test('treats a sidecar ending just before the credits as complete', () async {
    File(sidecarPath).writeAsStringSync(_srt([(0, 3_580_000, 'סוף')]));
    final runway = makeRunway()..start();
    addTearDown(runway.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    runway.setMediaDuration(const Duration(minutes: 60));
    expect(runway.isComplete, isTrue,
        reason: 'the last line lands before the credits roll');
  });

  test('an unknown media duration does not report false progress', () async {
    File(sidecarPath).writeAsStringSync(_srt([(0, 2000, 'שלום')]));
    final runway = makeRunway()..start();
    addTearDown(runway.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // Before the player reports a duration, a present sidecar is assumed whole —
    // better than showing "still preparing" over a finished track.
    expect(runway.mediaDuration, isNull);
    expect(runway.isComplete, isTrue);
  });

  test('notices a sidecar being deleted', () async {
    File(sidecarPath).writeAsStringSync(_srt([(0, 2000, 'שלום')]));
    final runway = makeRunway()..start();
    addTearDown(runway.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(runway.hasSubtitles, isTrue);

    File(sidecarPath).deleteSync();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(runway.hasSubtitles, isFalse);
    expect(runway.readyThrough, isNull);
  });
}
