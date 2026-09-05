// CueTrack — the lookups behind dual-language subtitles and cue looping.
//
// Both features ask "which line is this?" many times a second while the viewer
// is also nudging the sync, so the offset has to be part of the answer, not
// something applied afterwards.

import 'dart:io';

import 'package:autosub_media_player/player/cue_track.dart';
import 'package:autosub_media_player/subtitle/srt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

CueTrack _track() => CueTrack([
      SrtCue(
        start: const Duration(seconds: 10),
        end: const Duration(seconds: 12),
        text: 'First line',
      ),
      SrtCue(
        start: const Duration(seconds: 20),
        end: const Duration(seconds: 23),
        text: 'Second line',
      ),
    ]);

void main() {
  group('cueAt', () {
    test('finds the cue on screen and nothing in the gaps', () {
      final t = _track();
      expect(t.cueAt(const Duration(seconds: 11))?.text, 'First line');
      expect(t.cueAt(const Duration(seconds: 21))?.text, 'Second line');
      // Before the first cue, between cues, and after the last one.
      expect(t.cueAt(const Duration(seconds: 2)), isNull);
      expect(t.cueAt(const Duration(seconds: 15)), isNull);
      expect(t.cueAt(const Duration(seconds: 30)), isNull);
    });

    test('cue boundaries are start-inclusive and end-exclusive', () {
      final t = _track();
      expect(t.cueAt(const Duration(seconds: 10)), isNotNull);
      expect(t.cueAt(const Duration(seconds: 12)), isNull);
    });

    test('a subtitle offset moves the lookup with the track', () {
      final t = _track();
      const later = Duration(milliseconds: 500);
      // Subtitles pushed 500ms later: at 10.2s the first line is not up yet.
      expect(t.cueAt(const Duration(milliseconds: 10200), offset: later), isNull);
      expect(
        t.cueAt(const Duration(milliseconds: 10600), offset: later)?.text,
        'First line',
      );
    });
  });

  group('cueForReplay', () {
    test('in a gap, replays the line that just finished', () {
      final t = _track();
      expect(t.cueForReplay(const Duration(seconds: 15))?.text, 'First line');
    });

    test('before any line there is nothing to replay', () {
      expect(_track().cueForReplay(const Duration(seconds: 1)), isNull);
    });
  });

  group('loading', () {
    test('a missing or unreadable file is an empty track, not a throw', () {
      final dir = Directory.systemTemp.createTempSync('cues');
      addTearDown(() => dir.deleteSync(recursive: true));

      expect(CueTrack.fromFile(p.join(dir.path, 'nope.srt')).isEmpty, isTrue);

      final junk = File(p.join(dir.path, 'junk.srt'))
        ..writeAsStringSync('not a subtitle file at all');
      expect(CueTrack.fromFile(junk.path).isEmpty, isTrue);
    });

    test('cues out of order in the file are still indexed correctly', () {
      final t = CueTrack([
        SrtCue(
          start: const Duration(seconds: 20),
          end: const Duration(seconds: 23),
          text: 'Second',
        ),
        SrtCue(
          start: const Duration(seconds: 10),
          end: const Duration(seconds: 12),
          text: 'First',
        ),
      ]);
      expect(t.cueAt(const Duration(seconds: 11))?.text, 'First');
      expect(t.cueAt(const Duration(seconds: 21))?.text, 'Second');
    });
  });
}
