// SRT parse + serialize — the editor's local data source (SCREENS §5).
//
// The engine's SrtAssembler writes each RTL line wrapped in RLE...PDF bidi controls
// (U+202B ... U+202C). We strip those (and other stray bidi controls) for editing so
// the stored artifact stays clean (RTL.md §7.3), then re-apply them on save for RTL
// targets — a faithful round-trip of the engine's own format.

/// A single subtitle cue.
class SrtCue {
  SrtCue({
    required this.start,
    required this.end,
    required this.text,
    this.userEdited = false,
  });

  Duration start;
  Duration end;
  String text;
  bool userEdited;

  Duration get duration => end - start;

  /// Characters-per-second over the cue's on-screen time (display reading speed).
  double get cps {
    final secs = duration.inMilliseconds / 1000.0;
    if (secs <= 0) return 0;
    // Count visible characters (ignore newlines).
    final chars = text.replaceAll('\n', '').length;
    return chars / secs;
  }
}

// Bidi control characters the engine may have written / that should never live in
// the editable text: embeddings/overrides (U+202A–202E) and isolates (U+2066–2069),
// plus the marks (U+200E/200F).
final RegExp _bidiControls =
    RegExp('[\u202A-\u202E\u2066-\u2069\u200E\u200F]');

String _stripBidi(String s) => s.replaceAll(_bidiControls, '');

Duration _parseTimecode(String s) {
  // 00:01:12,300
  final m = RegExp(r'(\d+):(\d{2}):(\d{2})[,.](\d{1,3})').firstMatch(s.trim());
  if (m == null) return Duration.zero;
  return Duration(
    hours: int.parse(m.group(1)!),
    minutes: int.parse(m.group(2)!),
    seconds: int.parse(m.group(3)!),
    milliseconds: int.parse(m.group(4)!.padRight(3, '0')),
  );
}

String formatTimecode(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:'
      '${two(d.inSeconds.remainder(60))},${three(d.inMilliseconds.remainder(1000))}';
}

/// Parse SubRip text into cues (bidi controls stripped from the editable text).
List<SrtCue> parseSrt(String content) {
  final cues = <SrtCue>[];
  // Normalize newlines; split on blank-line separators.
  final blocks = content
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split(RegExp(r'\n[ \t]*\n'));
  for (final block in blocks) {
    final lines = block.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) continue;
    // Find the timing line (skip a leading numeric index if present).
    var i = 0;
    if (!lines[i].contains('-->') && RegExp(r'^\d+$').hasMatch(lines[i].trim())) {
      i++;
    }
    if (i >= lines.length || !lines[i].contains('-->')) continue;
    final parts = lines[i].split('-->');
    if (parts.length != 2) continue;
    final start = _parseTimecode(parts[0]);
    final end = _parseTimecode(parts[1]);
    final text = _stripBidi(lines.sublist(i + 1).join('\n')).trim();
    cues.add(SrtCue(start: start, end: end, text: text));
  }
  return cues;
}

/// Serialize cues back to SubRip. For RTL targets each line is wrapped in RLE…PDF
/// to match the engine's SrtAssembler output exactly.
String serializeSrt(List<SrtCue> cues, {required bool rtl}) {
  final buf = StringBuffer();
  for (var i = 0; i < cues.length; i++) {
    final c = cues[i];
    final body = rtl ? '\u202B${c.text}\u202C' : c.text;
    buf.writeln('${i + 1}');
    buf.writeln('${formatTimecode(c.start)} --> ${formatTimecode(c.end)}');
    buf.writeln(body);
    buf.writeln();
  }
  return buf.toString();
}

/// RTL target languages (matches the engine's SrtAssembler.rtlLanguages).
const Set<String> kRtlLanguages = {'he', 'iw', 'ar', 'fa', 'ur'};

/// The minimum on-screen duration a cue's text needs to read at or below [maxCps].
Duration minDurationForCps(SrtCue cue, int maxCps) {
  if (maxCps <= 0) return cue.duration;
  final chars = cue.text.replaceAll('\n', '').length;
  return Duration(milliseconds: (chars / maxCps * 1000).ceil());
}

/// A proposed retime that brings cue [i]'s reading speed to within [maxCps], by
/// extending its end into the gap before the next cue and — only if still too
/// fast — pulling its start earlier into the gap after the previous cue. Neighbors
/// are never overlapped (a [minGap] is kept). Returns null when the cue already
/// reads comfortably or there's no room to improve it.
///
/// This is the standard subtitling fix: keep the line up a little longer so it's
/// readable, without ever colliding with the next/previous cue.
({Duration start, Duration end})? syncCueTiming(
  List<SrtCue> cues,
  int i,
  int maxCps, {
  Duration minGap = const Duration(milliseconds: 80),
  Duration maxLeadIn = const Duration(milliseconds: 500),
}) {
  final cue = cues[i];
  final need = minDurationForCps(cue, maxCps);
  if (cue.duration >= need) return null; // already within budget

  var start = cue.start;
  var end = cue.end;

  // 1. Extend the end forward into the gap before the next cue (lead-out). Only
  //    ever EXTEND — never pull the end earlier — so we can't worsen the CPS.
  final hardMaxEnd = (i + 1 < cues.length) ? cues[i + 1].start - minGap : null;
  final wantEnd = start + need;
  if (hardMaxEnd == null) {
    end = wantEnd;
  } else if (hardMaxEnd > end) {
    end = wantEnd < hardMaxEnd ? wantEnd : hardMaxEnd;
  }

  // 2. Still short? Pull the start earlier by a SMALL lead-in (capped, and never
  //    into the previous cue) — so the line never appears long before the speech.
  if (end - start < need) {
    final earliest = start - maxLeadIn;
    final floor = (i > 0) ? cues[i - 1].end + minGap : Duration.zero;
    final minStart = earliest > floor ? earliest : floor;
    final deficit = need - (end - start);
    final wantStart = start - deficit;
    if (minStart < start) {
      start = wantStart >= minStart ? wantStart : minStart;
    }
    if (start < Duration.zero) start = Duration.zero;
  }

  // Only suggest a change that actually lengthens the cue (improves the CPS).
  if ((end - start) <= cue.duration) return null;
  return (start: start, end: end);
}
