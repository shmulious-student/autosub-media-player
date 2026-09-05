// Subtitle export — let the translated track leave the app.
//
// The Hebrew track already exists as a sidecar next to the video, but that is our
// filename in our folder. People want it somewhere else and in the format their
// other device wants: a VTT for a browser or Plex, an SRT for a TV stick, a plain
// text transcript to read or search.
//
// Conversion is done here rather than by re-asking the engine, because the cues
// are already final — export is a formatting problem, not a translation one.

import '../platform/secure_files.dart';
import 'srt.dart';

enum SubtitleExportFormat { srt, vtt, text }

extension SubtitleExportFormatInfo on SubtitleExportFormat {
  String get extension => switch (this) {
        SubtitleExportFormat.srt => 'srt',
        SubtitleExportFormat.vtt => 'vtt',
        SubtitleExportFormat.text => 'txt',
      };

  String get label => switch (this) {
        SubtitleExportFormat.srt => 'SubRip (.srt)',
        SubtitleExportFormat.vtt => 'WebVTT (.vtt)',
        SubtitleExportFormat.text => 'Plain text (.txt)',
      };
}

/// Render [cues] in [format]. `rtl` re-applies the engine's bidi wrapping for
/// right-to-left targets, so an exported SRT renders identically to ours.
String renderSubtitles(
  List<SrtCue> cues, {
  required SubtitleExportFormat format,
  required bool rtl,
}) {
  switch (format) {
    case SubtitleExportFormat.srt:
      return serializeSrt(cues, rtl: rtl);
    case SubtitleExportFormat.vtt:
      return _vtt(cues);
    case SubtitleExportFormat.text:
      // Timings dropped on purpose: this is for reading and searching, and cue
      // boundaries are a display artifact, not sentence boundaries.
      return '${cues.map((c) => c.text.replaceAll('\n', ' ')).join('\n')}\n';
  }
}

/// WebVTT: the same cues with a header and `.` for the millisecond separator.
String _vtt(List<SrtCue> cues) {
  final buf = StringBuffer('WEBVTT\n\n');
  for (var i = 0; i < cues.length; i++) {
    final c = cues[i];
    buf.writeln('${i + 1}');
    buf.writeln('${_vttStamp(c.start)} --> ${_vttStamp(c.end)}');
    buf.writeln(c.text);
    buf.writeln();
  }
  return buf.toString();
}

String _vttStamp(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:'
      '${two(d.inSeconds.remainder(60))}.${three(d.inMilliseconds.remainder(1000))}';
}

/// Suggested filename for the save panel: the title, the language, the format.
String exportFileName({
  required String baseName,
  required String lang,
  required SubtitleExportFormat format,
}) =>
    '$baseName.$lang.${format.extension}';

/// Show the save panel and write the export. Returns the written path, or null
/// when the user cancelled.
Future<String?> exportSubtitles(
  List<SrtCue> cues, {
  required String baseName,
  required String lang,
  required SubtitleExportFormat format,
  required bool rtl,
  SecureFiles files = const SecureFiles(),
}) {
  return files.saveFile(
    suggestedName: exportFileName(baseName: baseName, lang: lang, format: format),
    contents: renderSubtitles(cues, format: format, rtl: rtl),
    allowedExtensions: [format.extension],
  );
}
