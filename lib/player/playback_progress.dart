// PlaybackProgressStore — remember where you stopped watching, and how you had
// the subtitles timed.
//
// The translation cache remembers everything about a title and the player
// remembered nothing: closing an episode and reopening it started from zero. This
// is the smallest possible fix — a JSON map of video path → position, saved while
// you watch and read when you open.
//
// Two judgement calls are baked in, both about not being annoying:
//   - The first 60 seconds are not worth resuming. Someone who stopped there was
//     sampling, not watching, and being dropped a minute in feels broken.
//   - The last 90 seconds count as finished. Resuming into the end credits is
//     never what anyone wants; the title is marked watched and starts over.
//
// The subtitle delay lives here too rather than in a store of its own: it is the
// same thing — per-title viewing state, keyed by video path, saved while you watch
// and read when you open. A sidecar that runs 300ms early runs 300ms early every
// night, so making the viewer re-nudge it on each sitting is the actual bug.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../common/app_paths.dart';

/// How far into one title the viewer got.
class PlaybackProgress {
  const PlaybackProgress({
    required this.position,
    required this.duration,
    required this.updatedAtMs,
    this.subtitleDelayMs = 0,
  });

  final Duration position;

  /// Total media duration, or zero when the player never reported one.
  final Duration duration;
  final int updatedAtMs;

  /// Subtitle timing offset the viewer settled on, in milliseconds (positive =
  /// subtitles appear later). Survives closing the title.
  final int subtitleDelayMs;

  /// Below this, resuming is more surprising than helpful.
  static const minimumResume = Duration(seconds: 60);

  /// Within this of the end, the title counts as watched.
  static const endCreditsWindow = Duration(seconds: 90);

  bool get isWatched =>
      duration > Duration.zero && position + endCreditsWindow >= duration;

  /// Where playback should actually start, or null to start from the beginning.
  Duration? get resumePosition {
    if (isWatched) return null;
    return position >= minimumResume ? position : null;
  }

  /// 0..1 for a progress bar, or null when the duration is unknown.
  double? get fraction {
    if (duration <= Duration.zero) return null;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  PlaybackProgress copyWith({
    Duration? position,
    Duration? duration,
    int? updatedAtMs,
    int? subtitleDelayMs,
  }) =>
      PlaybackProgress(
        position: position ?? this.position,
        duration: duration ?? this.duration,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
        subtitleDelayMs: subtitleDelayMs ?? this.subtitleDelayMs,
      );

  Map<String, dynamic> toJson() => {
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'updatedAtMs': updatedAtMs,
        if (subtitleDelayMs != 0) 'subtitleDelayMs': subtitleDelayMs,
      };

  factory PlaybackProgress.fromJson(Map<String, dynamic> j) => PlaybackProgress(
        position: Duration(milliseconds: (j['positionMs'] as num?)?.toInt() ?? 0),
        duration: Duration(milliseconds: (j['durationMs'] as num?)?.toInt() ?? 0),
        updatedAtMs: (j['updatedAtMs'] as num?)?.toInt() ?? 0,
        subtitleDelayMs: (j['subtitleDelayMs'] as num?)?.toInt() ?? 0,
      );
}

class PlaybackProgressStore extends ChangeNotifier {
  PlaybackProgressStore({Directory? directory}) : _directory = directory;

  final Directory? _directory;
  final Map<String, PlaybackProgress> _byPath = {};
  File? _file;
  Timer? _saveDebounce;

  Future<File> _storeFile() async {
    if (_file != null) return _file!;
    if (_directory != null) {
      return _file = File(p.join(_directory.path, 'playback_progress.json'));
    }
    return _file = AutoSubPaths.playbackProgressFile();
  }

  Future<void> load() async {
    try {
      final f = await _storeFile();
      if (!f.existsSync()) return;
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _byPath
        ..clear()
        ..addAll(map.map((path, j) => MapEntry(
              path,
              PlaybackProgress.fromJson(j as Map<String, dynamic>),
            )));
      notifyListeners();
    } catch (_) {
      // Corrupt or missing → everyone starts from the beginning. Not worth an error.
    }
  }

  PlaybackProgress? progressFor(String path) => _byPath[path];

  /// Record a position. Writes are debounced: this is called every few seconds
  /// during playback and the file is small but not free.
  void record(String path, Duration position, Duration duration) {
    // Ignore the zero position a player reports while a file is still opening —
    // it would wipe a real saved position before playback even starts.
    if (position <= Duration.zero) return;
    _byPath[path] = PlaybackProgress(
      position: position,
      duration: duration,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      // A recorded position must never wipe the timing the viewer dialled in.
      subtitleDelayMs: _byPath[path]?.subtitleDelayMs ?? 0,
    );
    notifyListeners();
    _scheduleSave();
  }

  /// The saved subtitle offset for one title, or 0 when it was never nudged.
  int subtitleDelayFor(String path) => _byPath[path]?.subtitleDelayMs ?? 0;

  /// Remember the subtitle offset for one title.
  ///
  /// Unlike [record] this accepts a title with no watched position yet: someone
  /// can fix the sync in the first ten seconds, and that fix has to stick.
  void recordSubtitleDelay(String path, int delayMs) {
    final existing = _byPath[path];
    if (existing?.subtitleDelayMs == delayMs) return;
    _byPath[path] = (existing ??
            PlaybackProgress(
              position: Duration.zero,
              duration: Duration.zero,
              updatedAtMs: DateTime.now().millisecondsSinceEpoch,
            ))
        .copyWith(subtitleDelayMs: delayMs);
    notifyListeners();
    _scheduleSave();
  }

  /// Forget one title (the "Start over" action).
  Future<void> clearFor(String path) async {
    if (_byPath.remove(path) == null) return;
    notifyListeners();
    await _save();
  }

  /// Titles with a resumable position, most recently watched first — the
  /// "Continue watching" order.
  List<String> continueWatching({int limit = 20}) {
    final resumable = _byPath.entries
        .where((e) => e.value.resumePosition != null)
        .toList()
      ..sort((a, b) => b.value.updatedAtMs.compareTo(a.value.updatedAtMs));
    return resumable.take(limit).map((e) => e.key).toList();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 3), () => unawaited(_save()));
  }

  Future<void> _save() async {
    try {
      final f = await _storeFile();
      await f.writeAsString(
        jsonEncode(_byPath.map((path, v) => MapEntry(path, v.toJson()))),
      );
    } catch (_) {
      // A failed write costs a resume point, never a crash.
    }
  }

  /// Flush immediately (on player close, so the position survives a quit).
  Future<void> flush() async {
    _saveDebounce?.cancel();
    await _save();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }
}
