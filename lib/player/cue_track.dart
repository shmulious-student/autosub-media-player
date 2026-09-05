// CueTrack — the cue list of one subtitle file, indexed for playback lookups.
//
// The player needs to answer two questions many times a second: "which cue is on
// screen right now?" (dual-language rendering) and "where does the current cue
// start and end?" (cue looping). Both are binary searches over cues that are
// already sorted, so the whole thing is a sorted list plus a cursor — no parsing,
// no I/O on the hot path.
//
// Loading never throws. A missing or malformed file yields an empty track, which
// behaves exactly like a title with no second language: the feature quietly does
// nothing rather than interrupting playback.

import 'dart:io';

import '../subtitle/srt.dart';

class CueTrack {
  CueTrack(List<SrtCue> cues)
      : cues = List<SrtCue>.unmodifiable(
          cues.toList()..sort((a, b) => a.start.compareTo(b.start)),
        );

  const CueTrack.empty() : cues = const <SrtCue>[];

  final List<SrtCue> cues;

  bool get isEmpty => cues.isEmpty;
  bool get isNotEmpty => cues.isNotEmpty;

  /// Parse a subtitle file, or return an empty track if it cannot be read.
  factory CueTrack.fromFile(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return const CueTrack.empty();
      return CueTrack(parseSrt(file.readAsStringSync()));
    } catch (_) {
      return const CueTrack.empty();
    }
  }

  /// The cue on screen at [position], or null in the gap between cues.
  ///
  /// [offset] is the same subtitle delay the player pushes into mpv (positive =
  /// subtitles appear later), applied here so a nudged track and the dual-language
  /// overlay stay in step.
  SrtCue? cueAt(Duration position, {Duration offset = Duration.zero}) {
    final t = position - offset;
    final i = _lastStartingAtOrBefore(t);
    if (i < 0) return null;
    final cue = cues[i];
    return t < cue.end ? cue : null;
  }

  /// The cue to replay for [position]: the one on screen, or — when the position
  /// sits in a gap — the one that just finished. Looping "the current line" during
  /// a pause between sentences means the line you just heard.
  SrtCue? cueForReplay(Duration position, {Duration offset = Duration.zero}) {
    final i = _lastStartingAtOrBefore(position - offset);
    return i < 0 ? null : cues[i];
  }

  /// Index of the last cue starting at or before [t], or -1.
  int _lastStartingAtOrBefore(Duration t) {
    var lo = 0;
    var hi = cues.length - 1;
    var found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (cues[mid].start <= t) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }
}
