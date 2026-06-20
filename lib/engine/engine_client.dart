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

  bool get isActive => state == 'queued' || state == 'running';

  factory EngineJob.fromJson(Map<String, dynamic> j) => EngineJob(
        id: j['id'] as String,
        path: j['path'] as String,
        target: (j['target'] as String?) ?? 'he',
        state: j['state'] as String,
        stage: j['stage'] as String?,
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        sidecarPath: j['sidecarPath'] as String?,
        error: j['error'] as String?,
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

  /// Enqueue [path] for background subtitle generation. Idempotent server-side
  /// (returns the existing job for the same path+target).
  Future<EngineJob> enqueue(String path, {String target = 'he'}) async {
    final r = await http
        .post(
          _u('/jobs'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'path': path, 'target': target}),
        )
        .timeout(_timeout);
    if (r.statusCode != 200) {
      throw Exception('enqueue failed: ${r.statusCode} ${r.body}');
    }
    return EngineJob.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
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
