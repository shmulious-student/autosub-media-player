// DaemonServer — loopback HTTP job server (SPEC §3).
//
// The engine exposes a small HTTP API over 127.0.0.1 ONLY. The Flutter app
// (EngineClient) POSTs media files to /jobs; a single background worker drains a
// serial queue (models are heavy — process ONE job at a time) and drives each
// job through the warm SubtitlePipeline, updating state/stage/progress as it goes.
//
// Bound to 127.0.0.1 exclusively via Swifter (MIT), never a routable interface.

import Foundation
import Swifter

/// Loopback bind config.
public struct DaemonConfig: Sendable {
    public let host: String
    public let port: Int

    public init(host: String = "127.0.0.1", port: Int = 8770) {
        self.host = host
        self.port = port
    }
}

// MARK: - Job model (JSON contract — must match the app exactly)

/// A subtitle-generation job as seen on the wire.
///
/// JSON shape (CONTRACT):
/// ```
/// {
///   "id": <uuid>, "path": <abs video path>, "target": <lang>,
///   "state": "queued"|"running"|"done"|"failed",
///   "stage": <label or null>, "progress": <0.0..1.0>,
///   "sidecarPath": <abs .srt or null>, "error": <string or null>
/// }
/// ```
public struct DaemonJob: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case queued, running, done, failed
    }

    public var id: String
    public var path: String
    public var target: String
    public var state: State
    public var stage: String?
    public var progress: Double
    public var sidecarPath: String?
    public var error: String?

    public init(
        id: String = UUID().uuidString,
        path: String,
        target: String,
        state: State = .queued,
        stage: String? = nil,
        progress: Double = 0.0,
        sidecarPath: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.path = path
        self.target = target
        self.state = state
        self.stage = stage
        self.progress = progress
        self.sidecarPath = sidecarPath
        self.error = error
    }

    /// JSON-object form for Swifter's `.json` body (keys match the contract).
    public func jsonObject() -> [String: Any] {
        [
            "id": id,
            "path": path,
            "target": target,
            "state": state.rawValue,
            "stage": stage as Any? ?? NSNull(),
            "progress": progress,
            "sidecarPath": sidecarPath as Any? ?? NSNull(),
            "error": error as Any? ?? NSNull(),
        ]
    }
}

// MARK: - Job store (serial queue + state)

/// An actor-backed serial job store: holds all jobs, hands out the next queued
/// one (FIFO by insertion), and owns every state transition. One job runs at a
/// time — the worker only pulls a new job after the current one settles.
public actor JobStore {
    private var jobs: [DaemonJob] = []          // insertion order = FIFO
    private var index: [String: Int] = [:]      // id -> position in `jobs`

    public init() {}

    /// Enqueue a job for (path, target). If a non-failed job for the same
    /// (path, target) already exists, return it instead of duplicating.
    public func enqueue(path: String, target: String) -> DaemonJob {
        if let existing = jobs.first(where: {
            $0.path == path && $0.target == target && $0.state != .failed
        }) {
            return existing
        }
        let job = DaemonJob(path: path, target: target)
        index[job.id] = jobs.count
        jobs.append(job)
        return job
    }

    public func all() -> [DaemonJob] { jobs }

    /// Drop all still-`queued` jobs (e.g. the user cleared the library). A job
    /// already `running` is left to finish — cancelling mid-pipeline isn't
    /// supported yet. Returns how many were removed.
    @discardableResult
    public func clearQueued() -> Int {
        let before = jobs.count
        jobs.removeAll { $0.state == .queued }
        reindex()
        return before - jobs.count
    }

    private func reindex() {
        index.removeAll(keepingCapacity: true)
        for (i, j) in jobs.enumerated() { index[j.id] = i }
    }

    public func job(id: String) -> DaemonJob? {
        guard let i = index[id] else { return nil }
        return jobs[i]
    }

    /// The next job to run: the oldest one still `queued`.
    public func nextQueued() -> DaemonJob? {
        jobs.first { $0.state == .queued }
    }

    // MARK: State transitions (all funnel through here)

    @discardableResult
    public func markRunning(_ id: String, stage: String?, progress: Double) -> DaemonJob? {
        mutate(id) {
            $0.state = .running
            $0.stage = stage
            $0.progress = progress
        }
    }

    @discardableResult
    public func updateProgress(_ id: String, stage: String?, progress: Double) -> DaemonJob? {
        mutate(id) {
            // Don't resurrect a settled job.
            guard $0.state == .running || $0.state == .queued else { return }
            $0.state = .running
            $0.stage = stage
            $0.progress = progress
        }
    }

    @discardableResult
    public func markDone(_ id: String, sidecarPath: String, progress: Double = 1.0) -> DaemonJob? {
        mutate(id) {
            $0.state = .done
            $0.stage = "done"
            $0.progress = progress
            $0.sidecarPath = sidecarPath
            $0.error = nil
        }
    }

    @discardableResult
    public func markFailed(_ id: String, error: String) -> DaemonJob? {
        mutate(id) {
            $0.state = .failed
            $0.error = error
        }
    }

    @discardableResult
    private func mutate(_ id: String, _ body: (inout DaemonJob) -> Void) -> DaemonJob? {
        guard let i = index[id] else { return nil }
        body(&jobs[i])
        return jobs[i]
    }
}

// MARK: - Daemon server

/// The loopback HTTP surface + background worker. `start()` binds the socket and
/// returns; call `blockForever()` (or keep the process alive another way) to run.
public final class DaemonServer: @unchecked Sendable {
    private let config: DaemonConfig
    private let store: JobStore
    private let pipeline: SubtitlePipeline
    private let server = HttpServer()

    public init(config: DaemonConfig, pipeline: SubtitlePipeline, store: JobStore = JobStore()) {
        self.config = config
        self.store = store
        self.pipeline = pipeline
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("[DaemonServer] \(s)\n".utf8))
    }

    /// Bind the loopback socket, register routes, and launch the worker loop.
    public func start() throws {
        registerRoutes()
        // Loopback only — never a routable interface.
        server.listenAddressIPv4 = config.host
        try server.start(in_port_t(config.port), forceIPv4: true)
        log("listening on \(config.host):\(config.port)")
        startWorker()
    }

    public func stop() {
        server.stop()
    }

    // MARK: Routes

    private func registerRoutes() {
        // GET /health
        server.GET["/health"] = { _ in
            .ok(.json(["status": "ok"]))
        }

        // GET /jobs
        server.GET["/jobs"] = { [store] _ in
            let jobs = Self.blockingAwait { await store.all() }
            return .ok(.json(["jobs": jobs.map { $0.jsonObject() }]))
        }

        // GET /jobs/{id}
        server.GET["/jobs/:id"] = { [store] req in
            guard let id = req.params[":id"] else {
                return Self.jsonError(404, "not found")
            }
            guard let job = Self.blockingAwait({ await store.job(id: id) }) else {
                return Self.jsonError(404, "not found")
            }
            return .ok(.json(job.jsonObject()))
        }

        // POST /jobs  body {"path":"...","target":"he"}
        server.POST["/jobs"] = { [store] req in
            guard
                let obj = (try? JSONSerialization.jsonObject(with: Data(req.body))) as? [String: Any],
                let path = obj["path"] as? String, !path.isEmpty,
                let target = obj["target"] as? String, !target.isEmpty
            else {
                return Self.jsonError(400, "expected JSON body {\"path\":..., \"target\":...}")
            }
            let job = Self.blockingAwait { await store.enqueue(path: path, target: target) }
            return .ok(.json(job.jsonObject()))
        }

        // DELETE /jobs — clear all queued jobs (running one finishes).
        server.DELETE["/jobs"] = { [store] _ in
            let n = Self.blockingAwait { await store.clearQueued() }
            return .ok(.json(["cleared": n]))
        }
    }

    /// A 4xx/5xx response carrying a JSON `{"error": ...}` body with the given code.
    private static func jsonError(_ code: Int, _ message: String) -> HttpResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return .raw(code, code == 404 ? "Not Found" : "Bad Request",
                    ["Content-Type": "application/json"]) { writer in
            try writer.write(body)
        }
    }

    /// Swifter handlers are synchronous; bridge to our async actor calls. The
    /// store's operations are short and non-blocking, so a brief wait is fine.
    private static func blockingAwait<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            box.value = await op()
            sem.signal()
        }
        sem.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable { var value: T? }

    // MARK: Worker

    /// Background worker: drain the queue ONE job at a time through the warm
    /// pipeline, updating state/stage/progress as it runs.
    private func startWorker() {
        let store = self.store
        let pipeline = self.pipeline
        Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let job = await store.nextQueued() else {
                    try? await Task.sleep(nanoseconds: 250_000_000) // idle poll
                    continue
                }
                await store.markRunning(job.id, stage: "starting", progress: 0.0)
                self?.log("running job \(job.id): \(job.path) → \(job.target)")
                do {
                    let result = try await pipeline.run(
                        videoPath: job.path,
                        targetLang: job.target
                    ) { progress, stage in
                        Task { await store.updateProgress(job.id, stage: stage, progress: progress) }
                    }
                    await store.markDone(job.id, sidecarPath: result.sidecarPath)
                    self?.log("done job \(job.id): \(result.sidecarPath) (\(result.cueCount) cues)")
                } catch {
                    await store.markFailed(job.id, error: "\(error)")
                    self?.log("failed job \(job.id): \(error)")
                }
            }
        }
    }
}
