// EngineClient — loopback HTTP client to the Mac engine daemon (SPEC §3).
//
// The engine runs as a separate process (`AutoSubEngine daemon`) that does the
// heavy AI and writes `.srt` sidecars. The sandboxed app can't spawn it, so it
// talks to it over 127.0.0.1 only. The daemon's job API is the contract below.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Default loopback endpoint of the engine daemon. Port 8770 (8765 commonly
/// collides with Unity's Mono-HTTPAPI on dev machines).
const String kDefaultEngineBaseUrl = 'http://127.0.0.1:8770';

class JobRating {
  const JobRating({
    required this.score,
    required this.label,
    required this.summary,
  });

  final int score;
  final String label;
  final String summary;

  factory JobRating.fromJson(Map<String, dynamic> j) => JobRating(
    score: (j['score'] as num?)?.toInt() ?? 0,
    label: (j['label'] as String?) ?? 'Unknown',
    summary: (j['summary'] as String?) ?? '',
  );
}

/// A background subtitle-generation job, mirroring the daemon's JSON shape.
class EngineJob {
  EngineJob({
    required this.id,
    required this.path,
    required this.target,
    required this.state,
    this.stage,
    this.progress = 0,
    this.sidecarPath,
    this.error,
    this.strategy = 'quality',
    required this.queuedAtUtcMs,
    this.startedAtUtcMs,
    this.endedAtUtcMs,
    this.durationMs,
    this.rating,
  });

  final String id;
  final String path;
  final String target;

  /// queued | running | done | failed
  final String state;
  final String? stage;
  final double progress;
  final String? sidecarPath;
  final String? error;

  /// quality | fast | progressive
  final String strategy;

  /// Epoch milliseconds in UTC. Convert to local only at display boundaries.
  final int queuedAtUtcMs;
  final int? startedAtUtcMs;
  final int? endedAtUtcMs;
  final int? durationMs;
  final JobRating? rating;

  bool get isActive => state == 'queued' || state == 'running';

  /// Progressive strategy: the 7B draft sidecar is written and watchable, but the
  /// 12B is still upgrading gender in the background. The app can play now and
  /// reload when the job reaches `done`.
  bool get isRefining =>
      state == 'running' && stage == 'refining' && sidecarPath != null;

  /// A sidecar the user can already watch (final, or a refining draft).
  bool get hasWatchableSubtitle =>
      sidecarPath != null && (state == 'done' || isRefining);

  DateTime get queuedAtUtc =>
      DateTime.fromMillisecondsSinceEpoch(queuedAtUtcMs, isUtc: true);

  DateTime? get startedAtUtc => startedAtUtcMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(startedAtUtcMs!, isUtc: true);

  DateTime? get endedAtUtc => endedAtUtcMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(endedAtUtcMs!, isUtc: true);

  Duration? get finishedDuration {
    if (durationMs != null) return Duration(milliseconds: durationMs!);
    if (startedAtUtcMs != null && endedAtUtcMs != null) {
      return Duration(
        milliseconds: (endedAtUtcMs! - startedAtUtcMs!).clamp(0, 1 << 53),
      );
    }
    return null;
  }

  factory EngineJob.fromJson(Map<String, dynamic> j) => EngineJob(
    id: j['id'] as String,
    path: j['path'] as String,
    target: (j['target'] as String?) ?? 'he',
    state: j['state'] as String,
    stage: j['stage'] as String?,
    progress: (j['progress'] as num?)?.toDouble() ?? 0,
    sidecarPath: j['sidecarPath'] as String?,
    error: j['error'] as String?,
    strategy: (j['strategy'] as String?) ?? 'quality',
    queuedAtUtcMs:
        (j['queuedAtUtcMs'] as num?)?.toInt() ??
        DateTime.now().toUtc().millisecondsSinceEpoch,
    startedAtUtcMs: (j['startedAtUtcMs'] as num?)?.toInt(),
    endedAtUtcMs: (j['endedAtUtcMs'] as num?)?.toInt(),
    durationMs: (j['durationMs'] as num?)?.toInt(),
    rating: j['rating'] is Map<String, dynamic>
        ? JobRating.fromJson(j['rating'] as Map<String, dynamic>)
        : null,
  );
}

/// Client for the local engine daemon.
class EngineClient {
  EngineClient({this.baseUrl = kDefaultEngineBaseUrl});

  final String baseUrl;
  static const Duration _timeout = Duration(seconds: 4);

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  /// True if the daemon is up.
  Future<bool> health() async {
    try {
      final r = await http.get(_u('/health')).timeout(_timeout);
      return r.statusCode == 200 && r.body.contains('ok');
    } catch (_) {
      return false;
    }
  }

  /// Best-effort language tag from the first tagged audio track, if the daemon can
  /// probe the media. Returns null for offline daemon, untagged files, or errors.
  Future<String?> audioLanguage(String path) async {
    try {
      final r = await http
          .post(
            _u('/probe/audio-language'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'path': path}),
          )
          .timeout(_timeout);
      if (r.statusCode != 200) return null;
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final language = body['language'] as String?;
      return language?.trim().isEmpty ?? true ? null : language;
    } catch (_) {
      return null;
    }
  }

  /// Enqueue [path] for background subtitle generation. Idempotent server-side
  /// (returns the existing job for the same path+target).
  Future<EngineJob> enqueue(
    String path, {
    String target = 'he',
    String strategy = 'quality',
    bool force = false,
    String? sourceSubtitlePath,
    bool sourceSubtitleOverride = false,
    Map<String, String>? characters,
  }) async {
    final r = await http
        .post(
          _u('/jobs'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'path': path,
            'target': target,
            'strategy': strategy,
            'force': force,
            'sourceSubtitlePath': ?sourceSubtitlePath,
            if (sourceSubtitleOverride) 'sourceSubtitleOverride': true,
            if (characters != null && characters.isNotEmpty)
              'characters': characters,
          }),
        )
        .timeout(_timeout);
    if (r.statusCode != 200) {
      throw Exception('enqueue failed: ${r.statusCode} ${r.body}');
    }
    return EngineJob.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Move [paths] to the front of the queue (highest priority, runs next). When
  /// [preempt] is true, the daemon also stops the currently-running job and
  /// re-queues it, so a prioritized title starts immediately. Missing jobs are
  /// created. Returns the updated jobs.
  Future<List<EngineJob>> prioritize(
    List<String> paths, {
    String target = 'he',
    String strategy = 'quality',
    bool preempt = false,
    bool force = false,
  }) async {
    final r = await http
        .post(
          _u('/jobs/prioritize'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'paths': paths,
            'target': target,
            'strategy': strategy,
            'preempt': preempt,
            'force': force,
          }),
        )
        .timeout(_timeout);
    if (r.statusCode != 200) {
      throw Exception('prioritize failed: ${r.statusCode} ${r.body}');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final list = (body['jobs'] as List<dynamic>? ?? const []);
    return list
        .map((e) => EngineJob.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Clear all non-running jobs on the daemon (a running job finishes). Returns
  /// the number cleared.
  Future<int> clearJobs() async {
    final r = await http.delete(_u('/jobs')).timeout(_timeout);
    if (r.statusCode != 200) {
      throw Exception('clearJobs failed: ${r.statusCode}');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return (body['cleared'] as num?)?.toInt() ?? 0;
  }

  /// Remove one finished/failed history item. This is not cancellation.
  Future<void> deleteJob(String id) async {
    final r = await http
        .delete(_u('/jobs/${Uri.encodeComponent(id)}'))
        .timeout(_timeout);
    if (r.statusCode != 200) {
      throw Exception('deleteJob failed: ${r.statusCode}');
    }
  }

  /// Ask the engine's local model for a one-sentence "role in the plot" per
  /// character (AI-generated, grounded in the title's overview). Returns character
  /// name → sentence; empty on any failure. A long timeout because the first call
  /// may warm the model.
  Future<Map<String, String>> characterSummaries({
    required String title,
    int? year,
    String? overview,
    required List<String> characters,
  }) async {
    if (characters.isEmpty) return const {};
    try {
      final r = await http
          .post(
            _u('/character-summaries'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'title': title,
              'year': ?year,
              if (overview != null && overview.isNotEmpty) 'overview': overview,
              'characters': characters,
            }),
          )
          .timeout(const Duration(seconds: 120));
      if (r.statusCode != 200) return const {};
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final s = (body['summaries'] as Map?) ?? const {};
      return s.map((k, v) => MapEntry(k as String, v as String));
    } catch (_) {
      return const {};
    }
  }

  /// All jobs the daemon knows about.
  Future<List<EngineJob>> getJobs() async {
    final r = await http.get(_u('/jobs')).timeout(_timeout);
    if (r.statusCode != 200) {
      throw Exception('getJobs failed: ${r.statusCode}');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final list = (body['jobs'] as List<dynamic>? ?? const []);
    return list
        .map((e) => EngineJob.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
