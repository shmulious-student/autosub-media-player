// SubtitleRunway — lets the video play NOW and lets subtitles arrive later.
//
// The old flow made playback wait for the whole preparation pipeline: resolve a
// source subtitle, maybe transcribe, then translate — tens of seconds at best,
// many minutes when ASR runs. For a player, time-to-first-frame is the metric
// that matters, and none of that work needs to finish before the picture starts.
//
// So the player opens the file immediately and this object owns everything that
// happens afterwards:
//
//   - It asks the engine to prepare THIS title first (preempting the background
//     sweep), because the thing you are watching outranks the thing you might
//     watch tonight.
//   - It watches the sidecar file and reports how far it is prepared — the
//     "runway". The progressive strategy writes a watchable draft long before the
//     final pass finishes, so there is usually something to show early.
//   - When the file appears or is rewritten (draft upgraded to final), it bumps
//     `revision` so the player can hot-swap the track mid-playback.
//
// It never blocks and never throws: an offline engine or an unreadable sidecar
// just means the film plays without subtitles, which is what a player should do.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../library/processing_manager.dart';
import '../subtitle/srt.dart';

/// What the player should tell the viewer about subtitle preparation.
enum RunwayPhase {
  /// Nothing to prepare — subtitles are already complete.
  ready,

  /// Waiting for a turn in the engine queue.
  queued,

  /// Transcribing or translating right now.
  preparing,

  /// Partly prepared and playable, with more still coming.
  partial,

  /// Preparation failed, or the engine is offline.
  attention,

  /// No subtitles and nothing being done about it (engine offline / no manager).
  none,
}

class SubtitleRunway extends ChangeNotifier {
  SubtitleRunway({
    required this.videoPath,
    required this.lang,
    this.manager,
    Duration pollInterval = const Duration(seconds: 2),
  }) : _pollInterval = pollInterval;

  final String videoPath;
  final String lang;
  final ProcessingManager? manager;
  final Duration _pollInterval;

  Timer? _timer;
  bool _requestedPreparation = false;

  /// Bumped whenever the sidecar's bytes change — the player reloads on this.
  int revision = 0;

  /// Path to the sidecar, when it exists on disk.
  String? path;

  /// End time of the last cue currently in the sidecar: everything up to here is
  /// prepared and playable.
  Duration? readyThrough;

  /// Total media duration, once the player knows it. Used only to decide whether
  /// the runway covers the whole film.
  Duration? mediaDuration;

  /// Fingerprint of the sidecar we last parsed (size + mtime), so a rewrite is
  /// detected without re-parsing the file every tick.
  ({int size, int mtimeMs})? _seen;

  String get sidecarPath => p.join(
    p.dirname(videoPath),
    '${p.basenameWithoutExtension(videoPath)}.$lang.srt',
  );

  bool get hasSubtitles => path != null;

  /// True once the sidecar covers (nearly) the whole film — the last cue can sit a
  /// little before the end credits, so allow a 30 s tail.
  bool get isComplete {
    final ready = readyThrough;
    final total = mediaDuration;
    if (ready == null) return false;
    if (total == null || total == Duration.zero) return true;
    return ready + const Duration(seconds: 30) >= total;
  }

  double? get progress => manager?.jobFor(videoPath)?.progress;
  Duration? get eta => manager?.timingFor(videoPath)?.eta;

  RunwayPhase get phase {
    final job = manager?.jobFor(videoPath);
    if (job?.state == 'failed') return RunwayPhase.attention;
    if (hasSubtitles && isComplete) return RunwayPhase.ready;
    if (hasSubtitles) return RunwayPhase.partial;
    if (job?.state == 'running') return RunwayPhase.preparing;
    if (job?.state == 'queued') return RunwayPhase.queued;
    if (manager?.engineOnline == false) return RunwayPhase.attention;
    return _requestedPreparation ? RunwayPhase.queued : RunwayPhase.none;
  }

  /// Begin watching. Safe to call once; later calls are ignored.
  void start() {
    if (_timer != null) return;
    manager?.addListener(_onManagerChanged);
    _poll();
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  /// Ask the engine to prepare this title ahead of everything else.
  ///
  /// Called when playback starts without complete subtitles. Preemption is the
  /// point: the background sweep may be halfway through some other title, and the
  /// viewer is watching THIS one.
  /// `force` re-asks after a failure (the pill's Retry), which must not be
  /// swallowed by the once-only guard that keeps normal playback from spamming
  /// the queue.
  Future<void> requestPreparation({bool force = false}) async {
    final m = manager;
    if (m == null || isComplete) return;
    if (_requestedPreparation && !force) return;
    _requestedPreparation = true;
    notifyListeners();
    try {
      await m.prioritize([videoPath], preempt: true, force: force);
    } catch (_) {
      // Offline or a daemon hiccup: the sweep retries, and the film keeps playing.
    }
  }

  void setMediaDuration(Duration duration) {
    if (duration == mediaDuration || duration == Duration.zero) return;
    mediaDuration = duration;
    notifyListeners();
  }

  void _onManagerChanged() {
    if (hasListeners) notifyListeners();
  }

  /// Re-read the sidecar if (and only if) its bytes changed.
  void _poll() {
    final file = File(sidecarPath);
    ({int size, int mtimeMs})? stamp;
    try {
      if (file.existsSync()) {
        final stat = file.statSync();
        stamp = (size: stat.size, mtimeMs: stat.modified.millisecondsSinceEpoch);
      }
    } catch (_) {
      stamp = null; // sandbox denied the sibling read — treat as "not there yet"
    }

    if (stamp == null) {
      if (path != null) {
        path = null;
        readyThrough = null;
        _seen = null;
        revision++;
        notifyListeners();
      }
      return;
    }
    if (_seen != null && _seen == stamp) return;

    _seen = stamp;
    path = sidecarPath;
    readyThrough = _lastCueEnd(file);
    revision++;
    notifyListeners();
  }

  Duration? _lastCueEnd(File file) {
    try {
      final cues = parseSrt(file.readAsStringSync());
      if (cues.isEmpty) return null;
      return cues.last.end;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    manager?.removeListener(_onManagerChanged);
    super.dispose();
  }
}
