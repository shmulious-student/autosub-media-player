// DaemonServer — loopback HTTP server skeleton (SPEC §3).
//
// The engine exposes a small HTTP API + an event stream over 127.0.0.1 ONLY.
// The Flutter app (EngineClient) talks to this; the same daemon also hosts the
// Bonjour LAN server (later phase).
//
// v0 status: route table + handler stubs only. No real socket is bound yet.
//
// TODO(v0): add a light embedded HTTP server (e.g. Swifter) — kept out of
// Package.swift deps for now to avoid pulling network deps into the skeleton.
// Bind to 127.0.0.1 exclusively; never a routable interface.

import Foundation

/// Loopback bind config.
public struct DaemonConfig: Sendable {
    public let host: String
    public let port: Int

    public init(host: String = "127.0.0.1", port: Int = 8765) {
        self.host = host
        self.port = port
    }
}

/// The HTTP surface the app depends on (mirror of EngineClient in Dart).
public actor DaemonServer {
    private let config: DaemonConfig
    private let orchestrator: PipelineOrchestrator
    private let queue: JobQueue

    public init(config: DaemonConfig, orchestrator: PipelineOrchestrator, queue: JobQueue) {
        self.config = config
        self.orchestrator = orchestrator
        self.queue = queue
    }

    /// Start listening on the loopback interface.
    ///
    /// TODO(v0): bind a real HTTP server and register the routes below.
    public func start() async throws {
        // Routes (planned):
        //   POST  /jobs                -> enqueueTitle  -> ProcessingJob (JSON)
        //   GET   /jobs/{id}/events    -> SSE stream of ProcessingJob progress
        //   GET   /library            -> [Title] (derived read-only index)
        //   GET   /health             -> { ok: true }
        FileHandle.standardError.write(
            Data("[DaemonServer] STUB: would listen on \(config.host):\(config.port)\n".utf8)
        )
    }

    // MARK: - Handlers (stubs; called by the future router)

    /// POST /jobs
    public func handleEnqueue(titlePath: String) async -> ProcessingJob {
        await orchestrator.enqueueTitle(path: titlePath)
    }

    /// GET /library
    public func handleLibrary() async -> [Title] {
        // TODO: read derived index from Store.
        []
    }

    /// GET /health
    public func handleHealth() -> [String: Bool] {
        ["ok": true]
    }
}
