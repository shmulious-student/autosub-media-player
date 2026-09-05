// Export tests — the formatting is the whole feature, so it is worth pinning:
// a VTT that a browser rejects or an SRT that loses its bidi wrapping is a bug
// the user only discovers in another app.

import 'package:autosub_media_player/subtitle/srt.dart';
import 'package:autosub_media_player/subtitle/subtitle_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cues = [
    SrtCue(
      start: const Duration(milliseconds: 1500),
      end: const Duration(milliseconds: 3250),
      text: 'שלום',
    ),
    SrtCue(
      start: const Duration(hours: 1, minutes: 2, seconds: 3),
      end: const Duration(hours: 1, minutes: 2, seconds: 5),
      text: 'שורה\nשנייה',
    ),
  ];

  test('VTT carries the header and dot-separated milliseconds', () {
    final out = renderSubtitles(cues,
        format: SubtitleExportFormat.vtt, rtl: true);
    expect(out, startsWith('WEBVTT\n'));
    expect(out, contains('00:00:01.500 --> 00:00:03.250'));
    expect(out, contains('01:02:03.000 --> 01:02:05.000'));
    expect(out, isNot(contains(',500')), reason: 'VTT uses a dot, not a comma');
  });

  test('SRT keeps the engine comma timecodes and bidi wrapping for RTL', () {
    final out = renderSubtitles(cues,
        format: SubtitleExportFormat.srt, rtl: true);
    expect(out, contains('00:00:01,500 --> 00:00:03,250'));
    // The engine wraps RTL lines in RLE…PDF so players render them correctly;
    // an export that dropped that would display mangled in other apps.
    expect(out, contains('‫'));
    expect(out, contains('‬'));
  });

  test('plain text drops timings and flattens wrapped cues', () {
    final out = renderSubtitles(cues,
        format: SubtitleExportFormat.text, rtl: true);
    expect(out, 'שלום\nשורה שנייה\n');
    expect(out, isNot(contains('-->')));
  });

  test('suggested filename carries the title, language and format', () {
    expect(
      exportFileName(
          baseName: 'The Show S01E02',
          lang: 'he',
          format: SubtitleExportFormat.vtt),
      'The Show S01E02.he.vtt',
    );
  });

  test('every format has a distinct extension and a human label', () {
    final extensions =
        SubtitleExportFormat.values.map((f) => f.extension).toSet();
    expect(extensions.length, SubtitleExportFormat.values.length);
    for (final f in SubtitleExportFormat.values) {
      expect(f.label, contains(f.extension));
    }
  });

  test('an empty cue list still produces a valid VTT', () {
    expect(renderSubtitles([], format: SubtitleExportFormat.vtt, rtl: false),
        'WEBVTT\n\n');
  });
}
