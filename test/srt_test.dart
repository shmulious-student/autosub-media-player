// SRT parse/serialize round-trip tests (lib/subtitle/srt.dart).

import 'package:flutter_test/flutter_test.dart';

import 'package:autosub_media_player/subtitle/srt.dart';

const _sample = '1\n'
    '00:00:01,000 --> 00:00:04,000\n'
    '\u202Bשלום, יעל. מה שלומך?\u202C\n'
    '\n'
    '2\n'
    '00:00:05,500 --> 00:00:07,250\n'
    '\u202Bכן.\u202C\n';

void main() {
  test('parse strips bidi controls and reads timing', () {
    final cues = parseSrt(_sample);
    expect(cues.length, 2);
    expect(cues[0].text, 'שלום, יעל. מה שלומך?'); // RLE/PDF stripped
    expect(cues[0].start, const Duration(seconds: 1));
    expect(cues[0].end, const Duration(seconds: 4));
    expect(cues[1].start, const Duration(seconds: 5, milliseconds: 500));
  });

  test('serialize re-wraps RTL lines in RLE…PDF', () {
    final cues = parseSrt(_sample);
    final out = serializeSrt(cues, rtl: true);
    expect(out.contains('\u202Bשלום, יעל. מה שלומך?\u202C'), isTrue);
    // Re-parsing the serialized output yields the same clean text (round-trip).
    final reparsed = parseSrt(out);
    expect(reparsed[0].text, cues[0].text);
    expect(reparsed[1].text, cues[1].text);
  });

  test('cps reflects characters over on-screen seconds', () {
    final cue = SrtCue(
      start: Duration.zero,
      end: const Duration(seconds: 2),
      text: 'abcdefghij', // 10 chars over 2s → 5 cps
    );
    expect(cue.cps, 5.0);
  });

  test('formatTimecode pads to SubRip form', () {
    expect(formatTimecode(const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 4)),
        '01:02:03,004');
  });

  test('syncCueTiming extends an over-CPS cue into the following gap', () {
    // 20 chars over 1s → 20 cps (> 17). Next cue starts at 5s, so there's room.
    final cues = [
      SrtCue(
          start: const Duration(seconds: 1),
          end: const Duration(seconds: 2),
          text: '12345678901234567890'),
      SrtCue(
          start: const Duration(seconds: 5),
          end: const Duration(seconds: 6),
          text: 'next'),
    ];
    final res = syncCueTiming(cues, 0, 17);
    expect(res, isNotNull);
    // Needs 20/17 ≈ 1.177s; extends end from 2.0s to ~2.177s, within the gap.
    expect(res!.start, const Duration(seconds: 1));
    expect(res.end.inMilliseconds, 1000 + (20 / 17 * 1000).ceil());
    // The result reads at or below target.
    final fixed = SrtCue(start: res.start, end: res.end, text: cues[0].text);
    expect(fixed.cps <= 17, isTrue);
  });

  test('syncCueTiming never overlaps the next cue', () {
    // No room: next cue starts right after, so the extension is clamped.
    final cues = [
      SrtCue(
          start: Duration.zero,
          end: const Duration(seconds: 1),
          text: '12345678901234567890'),
      SrtCue(
          start: const Duration(milliseconds: 1100),
          end: const Duration(seconds: 2),
          text: 'next'),
    ];
    final res = syncCueTiming(cues, 0, 17);
    // Clamped to next.start - 80ms gap = 1020ms (still an improvement, no overlap).
    expect(res!.end.inMilliseconds <= 1100 - 80, isTrue);
  });

  test('syncCueTiming returns null when the cue already reads comfortably', () {
    final cues = [
      SrtCue(
          start: Duration.zero,
          end: const Duration(seconds: 3),
          text: 'short'),
    ];
    expect(syncCueTiming(cues, 0, 17), isNull);
  });

  test('syncCueTiming returns null when a cue is boxed in on both sides', () {
    // Wall-to-wall: previous ends and next starts within the min gap, so there's
    // no room to extend or lead in — the honest answer is "shorten the text".
    final cues = [
      SrtCue(
          start: Duration.zero,
          end: const Duration(seconds: 1),
          text: 'prev'),
      SrtCue(
          start: const Duration(milliseconds: 1050),
          end: const Duration(milliseconds: 2000),
          text: '12345678901234567890'), // ~21 cps, over 17
      SrtCue(
          start: const Duration(milliseconds: 2050),
          end: const Duration(seconds: 3),
          text: 'next'),
    ];
    expect(syncCueTiming(cues, 1, 17), isNull);
  });

  test('syncCueTiming caps the lead-in so a line never appears far before speech',
      () {
    final cues = [
      SrtCue(
          start: const Duration(seconds: 2),
          end: const Duration(milliseconds: 2400),
          text: '1234567890123456789012345678901234'), // 34 chars → need 2.0s
      SrtCue(
          start: const Duration(milliseconds: 2600),
          end: const Duration(seconds: 4),
          text: 'next'),
    ];
    final res = syncCueTiming(cues, 0, 17);
    // End extends into the gap (2.4 → 2.52s); start pulls at most 500ms (2.0 → 1.5s).
    expect(res!.end, const Duration(milliseconds: 2520));
    expect(res.start, const Duration(milliseconds: 1500));
  });
}
