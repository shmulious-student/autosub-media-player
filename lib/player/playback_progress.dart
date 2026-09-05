// PlaybackProgressStore — remember where you stopped watching.
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// How far into one title the viewer got.
class PlaybackProgress {
  const PlaybackProgress({
    required this.position,
    required this.duration,
    required this.updatedAtMs,
  });

  final Duration position;

  /// Total media duration, or zero when the player never reported one.
  final Duration duration;
  final int updatedAtMs;

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

  Map<String, dynamic> toJson() => {
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'updatedAtMs': updatedAtMs,
      };

  factory PlaybackProgress.fromJson(Map<String, dynamic> j) => PlaybackProgress(
        position: Duration(milliseconds: (j['positionMs'] as num?)?.toInt() ?? 0),
        duration: Duration(milliseconds: (j['durationMs'] as num?)?.toInt() ?? 0),
        updatedAtMs: (j['updatedAtMs'] as num?)?.toInt() ?? 0,
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
    final dir = _directory ?? await getApplicationSupportDirectory();
    return _file = File(p.join(dir.path, 'playback_progress.json'));
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
    );
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
