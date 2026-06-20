// EngineClient — thin Dart client to the Mac native sidecar daemon (SPEC §3).
//
// The engine runs as a separate Swift process inside the .app bundle and exposes
// a loopback HTTP API + an event stream for job progress. We talk to it over
// 127.0.0.1 only — never a routable interface. See
// `engine/Sources/Engine/IPC/DaemonServer.swift` for the server side.
//
// v0 status: STUBS. No real HTTP calls are wired yet; methods return
// placeholder data / empty streams so the UI can be built against the API shape.

import 'dart:async';

import '../data/models.dart';

/// Default loopback endpoint of the engine daemon.
const String kDefaultEngineBaseUrl = 'http://127.0.0.1:8765';

/// Client for the local engine daemon.
class EngineClient {
  EngineClient({this.baseUrl = kDefaultEngineBaseUrl});

  final String baseUrl;

  /// Enqueue a title for the full 12-stage pipeline (SPEC §4).
  ///
  /// Returns the created [ProcessingJob] (queued). The engine auto-queues new
  /// imports, but this lets the UI manually (re)trigger a specific title.
  ///
  /// TODO(v0): POST $baseUrl/jobs  body={"title_path": ...}; parse ProcessingJob.
  Future<ProcessingJob> enqueueTitle(String titlePath) async {
    // TODO: real HTTP. Placeholder so callers compile.
    return ProcessingJob(
      id: 'stub-job',
      titleId: 'stub-title',
      stage: 'Scanner',
      state: JobState.queued,
    );
  }

  /// Live progress for one job, pushed from the engine's event stream.
  ///
  /// TODO(v0): subscribe to Server-Sent Events at
  /// $baseUrl/jobs/$jobId/events and map frames -> ProcessingJob.
  Stream<ProcessingJob> jobProgressStream(String jobId) {
    // TODO: real SSE/websocket. Empty stream for now.
    return const Stream<ProcessingJob>.empty();
  }

  /// Fetch the derived read-only library index (titles + artifacts) the engine
  /// publishes. This is the same index that syncs to iOS (SPEC §6).
  ///
  /// TODO(v0): GET $baseUrl/library; parse into [Title]s.
  Future<List<Title>> getLibraryIndex() async {
    // TODO: real HTTP. Empty library for now.
    return const <Title>[];
  }
}
