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
    private var meta: [String: JobMeta] = [:]   // id -> durable ordering metadata
    private let store: SqliteStore?             // nil → pure in-memory (tests)
    private var nextSeq: Int = 1

    /// Durable per-job metadata that isn't part of the `DaemonJob` wire shape.
    private struct JobMeta {
        var seq: Int
        var priority: Int
        var createdAt: Double
        var titleId: String?
        var lastPersistedProgress: Double
        var lastStage: String?
    }

    public init(store: SqliteStore? = nil) { self.store = store }

    /// Rebuild the in-memory queue from SQLite (call once at startup). Any job
    /// left `running` when the process died is reset to `queued` — re-running is
    /// cheap because the pipeline short-circuits on an existing sidecar.
    public func reload() async {
        guard let store else { return }
        let persisted = (try? await store.loadJobs()) ?? []
        jobs = []; index = [:]; meta = [:]
        var resets: [DaemonJob] = []
        for p in persisted {
            var dj = DaemonJob(
                id: p.id, path: p.path, target: p.target,
                state: DaemonJob.State(rawValue: p.state) ?? .queued,
                stage: p.stage, progress: p.progress,
                sidecarPath: p.sidecarPath, error: p.error)
            var wasReset = false
            if dj.state == .running {
                dj.state = .queued; dj.stage = nil; dj.progress = 0; wasReset = true
            }
            index[dj.id] = jobs.count
            jobs.append(dj)
            meta[dj.id] = JobMeta(
                seq: p.seq, priority: p.priority, createdAt: p.createdAt,
                titleId: p.titleId, lastPersistedProgress: dj.progress, lastStage: dj.stage)
            if wasReset { resets.append(dj) }
        }
        nextSeq = (persisted.map(\.seq).max() ?? 0) + 1
        for j in resets { await persist(j) }
    }

    /// Enqueue a job for (path, target). If a non-failed job for the same
    /// (path, target) already exists, return it instead of duplicating.
    public func enqueue(path: String, target: String) async -> DaemonJob {
        if let existing = jobs.first(where: {
            $0.path == path && $0.target == target && $0.state != .failed
        }) {
            return existing
        }
        let job = DaemonJob(path: path, target: target)
        index[job.id] = jobs.count
        jobs.append(job)
        meta[job.id] = JobMeta(
            seq: nextSeq, priority: 0, createdAt: Date().timeIntervalSince1970,
            titleId: nil, lastPersistedProgress: 0, lastStage: nil)
        nextSeq += 1
        await persist(job)
        return job
    }

    public func all() -> [DaemonJob] { jobs }

    /// Link a job to the Title the worker created for it (durable; off-wire).
    public func setTitleId(_ id: String, titleId: String) async {
        meta[id]?.titleId = titleId
        if let i = index[id] { await persist(jobs[i]) }
    }

    /// Drop all still-`queued` jobs (e.g. the user cleared the library). A job
    /// already `running` is left to finish — cancelling mid-pipeline isn't
    /// supported yet. Returns how many were removed.
    @discardableResult
    public func clearQueued() async -> Int {
        let removed = jobs.filter { $0.state == .queued }.map(\.id)
        jobs.removeAll { $0.state == .queued }
        reindex()
        for id in removed { meta[id] = nil }
        if let store, !removed.isEmpty { try? await store.deleteJobs(ids: removed) }
        return removed.count
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
    public func markRunning(_ id: String, stage: String?, progress: Double) async -> DaemonJob? {
        let j = mutate(id) {
            $0.state = .running
            $0.stage = stage
            $0.progress = progress
        }
        if let j {
            meta[id]?.lastPersistedProgress = progress
            meta[id]?.lastStage = stage
            await persist(j)
        }
        return j
    }

    @discardableResult
    public func updateProgress(_ id: String, stage: String?, progress: Double) async -> DaemonJob? {
        let j = mutate(id) {
            // Don't resurrect a settled job.
            guard $0.state == .running || $0.state == .queued else { return }
            $0.state = .running
            $0.stage = stage
            $0.progress = progress
        }
        // Throttle DB writes: persist only on stage change or a ≥5% progress step.
        if let j {
            let m = meta[id]
            if m?.lastStage != stage || abs((m?.lastPersistedProgress ?? -1) - progress) >= 0.05 {
                meta[id]?.lastPersistedProgress = progress
                meta[id]?.lastStage = stage
                await persist(j)
            }
        }
        return j
    }

    @discardableResult
    public func markDone(_ id: String, sidecarPath: String, progress: Double = 1.0) async -> DaemonJob? {
        let j = mutate(id) {
            $0.state = .done
            $0.stage = "done"
            $0.progress = progress
            $0.sidecarPath = sidecarPath
            $0.error = nil
        }
        if let j { await persist(j) }
        return j
    }

    @discardableResult
    public func markFailed(_ id: String, error: String) async -> DaemonJob? {
        let j = mutate(id) {
            $0.state = .failed
            $0.error = error
        }
        if let j { await persist(j) }
        return j
    }

    @discardableResult
    private func mutate(_ id: String, _ body: (inout DaemonJob) -> Void) -> DaemonJob? {
        guard let i = index[id] else { return nil }
        body(&jobs[i])
        return jobs[i]
    }

    /// Write the current state of `job` to SQLite (best-effort; off the hot read path).
    private func persist(_ job: DaemonJob) async {
        guard let store, let m = meta[job.id] else { return }
        let pj = PersistedJob(
            id: job.id, path: job.path, target: job.target, state: job.state.rawValue,
            stage: job.stage, progress: job.progress, sidecarPath: job.sidecarPath,
            error: job.error, priority: m.priority, seq: m.seq, titleId: m.titleId,
            createdAt: m.createdAt)
        try? await store.saveJob(pj)
    }
}

// MARK: - Daemon server

/// The loopback HTTP surface + background worker. `start()` binds the socket and
/// returns; call `blockForever()` (or keep the process alive another way) to run.
public final class DaemonServer: @unchecked Sendable {
    private let config: DaemonConfig
    private let store: JobStore
    private let sqlite: SqliteStore?
    private let pipeline: SubtitlePipeline
    private let server = HttpServer()

    public init(config: DaemonConfig, pipeline: SubtitlePipeline, sqlite: SqliteStore? = nil) {
        self.config = config
        self.sqlite = sqlite
        self.store = JobStore(store: sqlite)
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
        // Recover any persisted queue (and reset interrupted jobs) before working.
        let sem = DispatchSemaphore(value: 0)
        Task { await self.store.reload(); sem.signal() }
        sem.wait()
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
        let sqlite = self.sqlite
        Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let job = await store.nextQueued() else {
                    try? await Task.sleep(nanoseconds: 250_000_000) // idle poll
                    continue
                }
                await store.markRunning(job.id, stage: "starting", progress: 0.0)
                self?.log("running job \(job.id): \(job.path) → \(job.target)")

                // Persist a Title up front (content-hash id) so its artifact can
                // link to it, and so the library survives a restart.
                var title: Title? = nil
                if let sqlite, let id = try? ContentHash.compute(path: job.path) {
                    let t = Title(
                        id: id, path: job.path, contentHash: id,
                        container: URL(fileURLWithPath: job.path).pathExtension.lowercased(),
                        status: "processing")
                    try? await sqlite.upsertTitle(t)
                    await store.setTitleId(job.id, titleId: id)
                    title = t
                }

                do {
                    let result = try await pipeline.run(
                        videoPath: job.path,
                        targetLang: job.target
                    ) { progress, stage in
                        Task { await store.updateProgress(job.id, stage: stage, progress: progress) }
                    }
                    await store.markDone(job.id, sidecarPath: result.sidecarPath)
                    self?.log("done job \(job.id): \(result.sidecarPath) (\(result.cueCount) cues)")

                    // Persist the finished Title + its SubtitleArtifact.
                    if let sqlite, var t = title {
                        t.status = "ready"
                        try? await sqlite.upsertTitle(t)
                        let artifact = SubtitleArtifact(
                            id: "\(t.id).\(job.target)",
                            titleId: t.id, lang: job.target,
                            format: .srt, source: result.source,
                            engine: "autosub", sidecarPath: result.sidecarPath,
                            cpsStats: result.cpsStats,
                            bibleVersionUsed: result.bibleVersionUsed)
                        try? await sqlite.upsertArtifact(artifact)
                    }
                } catch {
                    await store.markFailed(job.id, error: "\(error)")
                    self?.log("failed job \(job.id): \(error)")
                    if let sqlite, var t = title {
                        t.status = "failed"
                        try? await sqlite.upsertTitle(t)
                    }
                }
            }
        }
    }
}
