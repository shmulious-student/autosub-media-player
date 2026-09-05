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
///   "sidecarPath": <abs .srt or null>, "error": <string or null>,
///   "queuedAtUtcMs": <epoch-ms>, "startedAtUtcMs": <epoch-ms or null>,
///   "endedAtUtcMs": <epoch-ms or null>, "durationMs": <ms or null>,
///   "rating": {"score": 0...100, "label": <string>, "summary": <string>} | null
/// }
/// ```
public struct JobRating: Codable, Sendable {
    public var score: Int
    public var label: String
    public var summary: String

    public init(score: Int, label: String, summary: String) {
        self.score = max(0, min(100, score))
        self.label = label
        self.summary = summary
    }

    public func jsonObject() -> [String: Any] {
        ["score": score, "label": label, "summary": summary]
    }

    public static func success(result: SubtitleJobResult) -> JobRating {
        var score = 100
        var unverified = 0
        var lowConfidence = 0
        var fastCps = 0
        var other = 0
        for flag in result.qaFlags {
            if flag.hasPrefix("unverified@") {
                unverified += 1; score -= 18
            } else if flag.hasPrefix("low-confidence@") {
                lowConfidence += 1; score -= 8
            } else if flag.hasPrefix("fast-cps@") {
                fastCps += 1; score -= 6
            } else {
                other += 1; score -= 5
            }
        }

        let maxCps = result.cpsStats["max"] ?? 0
        if maxCps > 28 {
            score -= 18
        } else if maxCps > 22 {
            score -= 8
        }
        if result.cueCount == 0 { score = min(score, 40) }
        score = max(0, min(100, score))

        let label: String
        if score >= 90 {
            label = "Great"
        } else if score >= 75 {
            label = "Good"
        } else if score >= 55 {
            label = "Review"
        } else {
            label = "Poor"
        }

        var parts: [String] = []
        if result.qaFlags.isEmpty {
            parts.append("Clean QA pass")
        } else {
            parts.append("\(result.qaFlags.count) QA flags")
        }
        if unverified > 0 { parts.append("\(unverified) unverified") }
        if lowConfidence > 0 { parts.append("\(lowConfidence) low confidence") }
        if fastCps > 0 { parts.append("\(fastCps) fast CPS") }
        if other > 0 { parts.append("\(other) other") }
        if maxCps > 0 { parts.append(String(format: "max %.1f CPS", maxCps)) }

        return JobRating(score: score, label: label, summary: parts.joined(separator: " · "))
    }

    public static func failed(error: String) -> JobRating {
        JobRating(score: 0, label: "Failed", summary: error)
    }
}

public struct DaemonJob: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case queued, running, paused, done, failed
    }

    public var id: String
    public var path: String
    public var target: String
    public var state: State
    public var stage: String?
    public var progress: Double
    public var sidecarPath: String?
    public var error: String?
    public var queuedAtUtcMs: Int64
    public var startedAtUtcMs: Int64?
    public var endedAtUtcMs: Int64?
    public var rating: JobRating?
    /// Speed/quality tier (SPEC §9): "quality" (12B, default) | "fast" (7B) |
    /// "progressive" (7B draft now, 12B gender-fix in background). A per-enqueue
    /// preference the app sends; not persisted (defaults to quality on restart).
    public var strategy: String
    /// Re-generate: run the pipeline even though a sidecar already exists,
    /// overwriting it. In-memory only (a fresh run resets it via re-enqueue).
    public var force: Bool
    /// Absolute path to a source-language subtitle the app fetched/imported, used
    /// as the translation source instead of ASR. In-memory only.
    public var sourceSubtitlePath: String?
    /// Manual file/URL source overrides should beat embedded subtitles. Automatic
    /// downloaded sources keep embedded subtitles first. In-memory only.
    public var sourceSubtitleOverride: Bool
    /// Known character/person gender map (name → "m"/"f"), e.g. seeded from TMDB
    /// credits, injected into prompts for deterministic gender. In-memory only.
    public var characters: [String: String]?

    public init(
        id: String = UUID().uuidString,
        path: String,
        target: String,
        state: State = .queued,
        stage: String? = nil,
        progress: Double = 0.0,
        sidecarPath: String? = nil,
        error: String? = nil,
        queuedAtUtcMs: Int64 = DaemonJob.nowUtcMs(),
        startedAtUtcMs: Int64? = nil,
        endedAtUtcMs: Int64? = nil,
        rating: JobRating? = nil,
        strategy: String = "quality",
        force: Bool = false,
        sourceSubtitlePath: String? = nil,
        sourceSubtitleOverride: Bool = false,
        characters: [String: String]? = nil
    ) {
        self.id = id
        self.path = path
        self.target = target
        self.state = state
        self.stage = stage
        self.progress = progress
        self.sidecarPath = sidecarPath
        self.error = error
        self.queuedAtUtcMs = queuedAtUtcMs
        self.startedAtUtcMs = startedAtUtcMs
        self.endedAtUtcMs = endedAtUtcMs
        self.rating = rating
        self.strategy = strategy
        self.force = force
        self.sourceSubtitlePath = sourceSubtitlePath
        self.sourceSubtitleOverride = sourceSubtitleOverride
        self.characters = characters
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
            "strategy": strategy,
            "queuedAtUtcMs": queuedAtUtcMs,
            "startedAtUtcMs": startedAtUtcMs as Any? ?? NSNull(),
            "endedAtUtcMs": endedAtUtcMs as Any? ?? NSNull(),
            "durationMs": durationMs as Any? ?? NSNull(),
            "rating": rating?.jsonObject() as Any? ?? NSNull(),
        ]
    }

    public var durationMs: Int64? {
        guard let startedAtUtcMs, let endedAtUtcMs else { return nil }
        return max(0, endedAtUtcMs - startedAtUtcMs)
    }

    public static func nowUtcMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
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
                sidecarPath: p.sidecarPath, error: p.error,
                queuedAtUtcMs: Self.ms(fromUnixSeconds: p.createdAt),
                startedAtUtcMs: Self.optionalMs(fromUnixSeconds: p.startedAt),
                endedAtUtcMs: Self.optionalMs(fromUnixSeconds: p.endedAt),
                rating: p.rating)
            var wasReset = false
            if dj.state == .running {
                dj.state = .queued; dj.stage = nil; dj.progress = 0
                dj.startedAtUtcMs = nil; dj.endedAtUtcMs = nil; dj.rating = nil
                wasReset = true
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
        await pruneExpiredHistory()
    }

    /// Enqueue a job for (path, target). If a non-failed job for the same
    /// (path, target) already exists, return it instead of duplicating — UNLESS
    /// [force] (re-generate): then any existing job for the pair is dropped and a
    /// fresh `force` job is queued, so the pipeline overwrites the sidecar.
    public func enqueue(
        path: String, target: String, strategy: String = "quality", force: Bool = false,
        sourceSubtitlePath: String? = nil, sourceSubtitleOverride: Bool = false,
        characters: [String: String]? = nil
    ) async -> DaemonJob {
        if force {
            let stale = jobs.filter { $0.path == path && $0.target == target }.map(\.id)
            jobs.removeAll { $0.path == path && $0.target == target }
            reindex()
            for id in stale { meta[id] = nil }
            if let store, !stale.isEmpty { try? await store.deleteJobs(ids: stale) }
        } else if let existing = jobs.first(where: {
            $0.path == path && $0.target == target && $0.state != .failed
        }) {
            return existing
        }
        let job = DaemonJob(path: path, target: target, strategy: strategy, force: force,
                            sourceSubtitlePath: sourceSubtitlePath,
                            sourceSubtitleOverride: sourceSubtitleOverride,
                            characters: characters)
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

    public func pruneExpiredHistory(nowMs: Int64 = DaemonJob.nowUtcMs()) async {
        let cutoff = nowMs - 3 * 24 * 60 * 60 * 1000
        let removed = jobs
            .filter { ($0.state == .done || $0.state == .failed) && ($0.endedAtUtcMs ?? Int64.max) < cutoff }
            .map(\.id)
        guard !removed.isEmpty else { return }
        jobs.removeAll { removed.contains($0.id) }
        reindex()
        for id in removed { meta[id] = nil }
        if let store { try? await store.deleteJobs(ids: removed) }
    }

    /// Link a job to the Title the worker created for it (durable; off-wire).
    public func setTitleId(_ id: String, titleId: String) async {
        meta[id]?.titleId = titleId
        if let i = index[id] { await persist(jobs[i]) }
    }

    /// Drop all non-running jobs (e.g. the user cleared the queue/library). A job
    /// already `running` is left to finish — cancelling mid-pipeline isn't
    /// supported yet. Returns how many were removed.
    @discardableResult
    public func clearNonRunning() async -> Int {
        let removed = jobs.filter { $0.state != .running }.map(\.id)
        jobs.removeAll { $0.state != .running }
        reindex()
        for id in removed { meta[id] = nil }
        if let store, !removed.isEmpty { try? await store.deleteJobs(ids: removed) }
        return removed.count
    }

    @discardableResult
    public func deleteHistoryJob(id: String) async -> Bool {
        guard let i = index[id] else { return false }
        let state = jobs[i].state
        guard state == .done || state == .failed else { return false }
        jobs.remove(at: i)
        reindex()
        meta[id] = nil
        if let store { try? await store.deleteJobs(ids: [id]) }
        return true
    }

    private func reindex() {
        index.removeAll(keepingCapacity: true)
        for (i, j) in jobs.enumerated() { index[j.id] = i }
    }

    public func job(id: String) -> DaemonJob? {
        guard let i = index[id] else { return nil }
        return jobs[i]
    }

    /// The next job to run: the highest-priority `queued` job, FIFO within a
    /// priority (lower seq runs first). Default priority is 0, so an un-prioritized
    /// queue stays plain FIFO.
    public func nextQueued() -> DaemonJob? {
        jobs.filter { $0.state == .queued }.max { a, b in
            let pa = meta[a.id]?.priority ?? 0
            let pb = meta[b.id]?.priority ?? 0
            if pa != pb { return pa < pb } // higher priority is "greater"
            let sa = meta[a.id]?.seq ?? Int.max
            let sb = meta[b.id]?.seq ?? Int.max
            return sa > sb // lower seq is "greater" → picked first by max
        }
    }

    /// Bump [paths] to the front of the queue (each above the current max
    /// priority, preserving the given order). Missing jobs are enqueued. Returns
    /// the affected jobs. Used by the app's "Translate next / now" actions.
    public func prioritize(
        paths: [String], target: String, strategy: String, force: Bool = false
    ) async -> [DaemonJob] {
        let currentMax = meta.values.map(\.priority).max() ?? 0
        let base = currentMax + paths.count + 1
        var out: [DaemonJob] = []
        for (i, path) in paths.enumerated() {
            let job = await enqueue(
                path: path, target: target, strategy: strategy, force: force)
            meta[job.id]?.priority = base - i
            await persist(job)
            out.append(job)
        }
        return out
    }

    /// The currently-running job whose path isn't in [excludingPaths] — i.e. the
    /// job a preempt request should stop so a prioritized title can start.
    public func runningJob(excludingPaths: Set<String>) -> DaemonJob? {
        jobs.first { $0.state == .running && !excludingPaths.contains($0.path) }
    }

    /// Re-queue a job that was preempted mid-run (state → queued, progress reset)
    /// or resume a paused job.
    @discardableResult
    public func markQueued(_ id: String) async -> DaemonJob? {
        var wasPaused = false
        let j = mutate(id) {
            guard $0.state == .running || $0.state == .paused else { return }
            wasPaused = ($0.state == .paused)
            $0.state = .queued
            $0.error = nil
            if !wasPaused {
                $0.stage = nil
                $0.progress = 0
                $0.startedAtUtcMs = nil
                $0.endedAtUtcMs = nil
                $0.rating = nil
            }
        }
        if let j {
            if !wasPaused {
                meta[id]?.lastPersistedProgress = 0
                meta[id]?.lastStage = nil
            }
            await persist(j)
        }
        return j
    }

    // MARK: State transitions (all funnel through here)

    @discardableResult
    public func markRunning(_ id: String, stage: String?, progress: Double) async -> DaemonJob? {
        let j = mutate(id) {
            $0.state = .running
            $0.stage = stage
            $0.progress = progress
            if $0.startedAtUtcMs == nil { $0.startedAtUtcMs = DaemonJob.nowUtcMs() }
            $0.endedAtUtcMs = nil
            $0.rating = nil
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
            if $0.startedAtUtcMs == nil { $0.startedAtUtcMs = DaemonJob.nowUtcMs() }
            $0.endedAtUtcMs = nil
            $0.rating = nil
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
    public func markDone(
        _ id: String,
        sidecarPath: String,
        progress: Double = 1.0,
        rating: JobRating? = nil
    ) async -> DaemonJob? {
        let j = mutate(id) {
            $0.state = .done
            $0.stage = "done"
            $0.progress = progress
            $0.sidecarPath = sidecarPath
            $0.error = nil
            if $0.startedAtUtcMs == nil { $0.startedAtUtcMs = DaemonJob.nowUtcMs() }
            $0.endedAtUtcMs = DaemonJob.nowUtcMs()
            $0.rating = rating
        }
        if let j { await persist(j) }
        return j
    }

    /// Progressive strategy: the watchable 7B draft is written, but the job keeps
    /// running while the 12B upgrades gender in the background. Sets `sidecarPath`
    /// (so the app can play now) without leaving `running`.
    @discardableResult
    public func markDraftReady(_ id: String, sidecarPath: String, progress: Double) async -> DaemonJob? {
        let j = mutate(id) {
            guard $0.state == .running || $0.state == .queued else { return }
            $0.state = .running
            $0.stage = "refining"
            $0.progress = progress
            $0.sidecarPath = sidecarPath
        }
        if let j { await persist(j) }
        return j
    }

    @discardableResult
    public func markFailed(_ id: String, error: String) async -> DaemonJob? {
        let j = mutate(id) {
            $0.state = .failed
            $0.error = error
            $0.endedAtUtcMs = DaemonJob.nowUtcMs()
            $0.rating = .failed(error: error)
        }
        if let j { await persist(j) }
        return j
    }

    @discardableResult
    public func markPaused(_ id: String) async -> DaemonJob? {
        let j = mutate(id) {
            $0.state = .paused
            if $0.stage == nil { $0.stage = "paused" }
        }
        if let j { await persist(j) }
        return j
    }

    @discardableResult
    public func markCancelled(_ id: String) async -> DaemonJob? {
        let j = mutate(id) {
            $0.state = .failed
            $0.error = "Cancelled by user"
            $0.endedAtUtcMs = DaemonJob.nowUtcMs()
            $0.rating = .failed(error: "Cancelled by user")
        }
        if let j { await persist(j) }
        return j
    }

    @discardableResult
    public func cancelJob(id: String) async -> DaemonJob? {
        guard index[id] != nil else { return nil }
        return await markCancelled(id)
    }

    @discardableResult
    public func redoJob(id: String) async -> DaemonJob? {
        guard index[id] != nil else { return nil }
        let j = mutate(id) {
            $0.state = .queued
            $0.stage = nil
            $0.progress = 0.0
            $0.startedAtUtcMs = nil
            $0.endedAtUtcMs = nil
            $0.rating = nil
            $0.error = nil
            $0.force = true
        }
        if let j {
            meta[id]?.lastPersistedProgress = 0.0
            meta[id]?.lastStage = nil
            await persist(j)
        }
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
            createdAt: Double(job.queuedAtUtcMs) / 1000.0,
            startedAt: Self.optionalSeconds(fromMs: job.startedAtUtcMs),
            endedAt: Self.optionalSeconds(fromMs: job.endedAtUtcMs),
            rating: job.rating)
        try? await store.saveJob(pj)
    }

    private static func ms(fromUnixSeconds seconds: Double) -> Int64 {
        Int64((seconds * 1000).rounded())
    }

    private static func optionalMs(fromUnixSeconds seconds: Double?) -> Int64? {
        guard let seconds else { return nil }
        return ms(fromUnixSeconds: seconds)
    }

    private static func optionalSeconds(fromMs ms: Int64?) -> Double? {
        guard let ms else { return nil }
        return Double(ms) / 1000.0
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

    // Preemption / Pause / Cancel: track the running job + a cancel hook so external
    // requests can stop it. Guarded by a lock (the worker runs on a detached task,
    // the route handlers on Swifter's threads).
    public enum StopReason {
        case preempt
        case pause
        case cancel
    }

    private let runLock = NSLock()
    private var currentJobId: String?
    private var cancelCurrent: (() -> Void)?
    private var pendingStopReasons: [String: StopReason] = [:]

    private func setCurrent(_ id: String, cancel: @escaping () -> Void) {
        runLock.lock(); currentJobId = id; cancelCurrent = cancel; runLock.unlock()
    }

    private func clearCurrent() {
        runLock.lock(); currentJobId = nil; cancelCurrent = nil; runLock.unlock()
    }

    /// Request a stop for the running job with the given reason.
    private func requestStop(id: String, reason: StopReason) {
        runLock.lock()
        let match = currentJobId == id
        let cancel = cancelCurrent
        if match { pendingStopReasons[id] = reason }
        runLock.unlock()
        if match { cancel?() }
    }

    /// Consume the stop reason for [id] if one was registered.
    private func takeStopReason(_ id: String) -> StopReason? {
        runLock.lock(); defer { runLock.unlock() }
        return pendingStopReasons.removeValue(forKey: id)
    }

    /// Cancel the running job iff it matches [id]; remember that we asked, so the
    /// worker re-queues (not fails) it.
    private func preempt(id: String) {
        requestStop(id: id, reason: .preempt)
    }

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
        server.GET["/health"] = { [pipeline] _ in
            let env = Self.blockingAwait { await pipeline.currentBackendEnvironment }
            let quota = Self.blockingAwait { await CloudRateLimiter.shared.snapshot() }
            let quotaJson = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(quota))) as? [String: Any] ?? [:]
            return .ok(.json([
                "status": "ok",
                "backend": env.rawValue,
                "cloudQuota": quotaJson
            ]))
        }

        // GET /backend-env
        server.GET["/backend-env"] = { [pipeline] _ in
            let cfg = Self.blockingAwait { await pipeline.currentCloudConfig }
            let quota = Self.blockingAwait { await CloudRateLimiter.shared.snapshot() }
            let quotaJson = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(quota))) as? [String: Any] ?? [:]
            var res = cfg.jsonObject()
            res["cloudQuota"] = quotaJson
            return .ok(.json(res))
        }

        // POST /backend-env
        server.POST["/backend-env"] = { [pipeline] req in
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(req.body))) as? [String: Any] else {
                return Self.jsonError(400, "expected JSON body")
            }
            let envStr = (obj["environment"] as? String)?.lowercased() ?? "local"
            let backendEnv: BackendEnvironment = envStr == "cloud" ? .cloud : .local

            let currentCfg = Self.blockingAwait { await pipeline.currentCloudConfig }
            let groq = (obj["groqApiKey"] as? String) ?? currentCfg.groqApiKey
            let gemini = (obj["geminiApiKey"] as? String) ?? currentCfg.geminiApiKey
            let cfAcc = (obj["cloudflareAccountId"] as? String) ?? currentCfg.cloudflareAccountId
            let cfTok = (obj["cloudflareApiToken"] as? String) ?? currentCfg.cloudflareApiToken

            let newCfg = CloudConfig(
                environment: backendEnv,
                groqApiKey: groq,
                geminiApiKey: gemini,
                cloudflareAccountId: cfAcc,
                cloudflareApiToken: cfTok
            )

            Self.blockingAwait { await pipeline.setCloudConfig(newCfg) }
            return .ok(.json(newCfg.jsonObject()))
        }

        // POST /cloud/verify — test the configured keys without spending quota.
        //
        // Optional body fields override the daemon's current config, so Settings
        // can test a key the user just typed before committing to it.
        server.POST["/cloud/verify"] = { [pipeline] req in
            let obj = (try? JSONSerialization.jsonObject(with: Data(req.body))) as? [String: Any] ?? [:]
            let current = Self.blockingAwait { await pipeline.currentCloudConfig }
            let cfg = CloudConfig(
                environment: current.environment,
                groqApiKey: (obj["groqApiKey"] as? String) ?? current.groqApiKey,
                geminiApiKey: (obj["geminiApiKey"] as? String) ?? current.geminiApiKey,
                cloudflareAccountId: (obj["cloudflareAccountId"] as? String) ?? current.cloudflareAccountId,
                cloudflareApiToken: (obj["cloudflareApiToken"] as? String) ?? current.cloudflareApiToken
            )
            let results = Self.blockingAwait { await CloudProbe.verify(config: cfg) }
            let quota = Self.blockingAwait { await CloudRateLimiter.shared.snapshot() }
            let payload = CloudProbeReport(providers: results, quota: quota)
            guard let json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))) as? [String: Any] else {
                return Self.jsonError(500, "could not encode probe report")
            }
            return .ok(.json(json))
        }

        // GET /jobs
        server.GET["/jobs"] = { [store] _ in
            Self.blockingAwait { await store.pruneExpiredHistory() }
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

        // DELETE /jobs/{id} — remove one finished/failed history item.
        server.DELETE["/jobs/:id"] = { [store] req in
            guard let id = req.params[":id"] else {
                return Self.jsonError(404, "not found")
            }
            let deleted = Self.blockingAwait { await store.deleteHistoryJob(id: id) }
            guard deleted else {
                return Self.jsonError(404, "history item not found")
            }
            return .ok(.json(["deleted": true]))
        }

        // POST /jobs/{id}/cancel
        server.POST["/jobs/:id/cancel"] = { [store, weak self] req in
            guard let id = req.params[":id"] else {
                return Self.jsonError(404, "not found")
            }
            self?.requestStop(id: id, reason: .cancel)
            let job = Self.blockingAwait { await store.cancelJob(id: id) }
            guard let job else {
                return Self.jsonError(404, "job not found")
            }
            return .ok(.json(job.jsonObject()))
        }

        // POST /jobs/{id}/pause
        server.POST["/jobs/:id/pause"] = { [store, weak self] req in
            guard let id = req.params[":id"] else {
                return Self.jsonError(404, "not found")
            }
            self?.requestStop(id: id, reason: .pause)
            let job = Self.blockingAwait { await store.markPaused(id) }
            guard let job else {
                return Self.jsonError(404, "job not found")
            }
            return .ok(.json(job.jsonObject()))
        }

        // POST /jobs/{id}/resume
        server.POST["/jobs/:id/resume"] = { [store] req in
            guard let id = req.params[":id"] else {
                return Self.jsonError(404, "not found")
            }
            let job = Self.blockingAwait { await store.markQueued(id) }
            guard let job else {
                return Self.jsonError(404, "job not found")
            }
            return .ok(.json(job.jsonObject()))
        }

        // POST /jobs/{id}/redo
        server.POST["/jobs/:id/redo"] = { [store, weak self] req in
            guard let id = req.params[":id"] else {
                return Self.jsonError(404, "not found")
            }
            self?.requestStop(id: id, reason: .cancel)
            let job = Self.blockingAwait {
                if let j = await store.job(id: id) {
                    PipelineCheckpointStore().remove(videoPath: j.path, targetLang: j.target)
                }
                return await store.redoJob(id: id)
            }
            guard let job else {
                return Self.jsonError(404, "job not found")
            }
            return .ok(.json(job.jsonObject()))
        }

        // POST /probe/audio-language  body {"path":"..."}
        server.POST["/probe/audio-language"] = { req in
            guard
                let obj = (try? JSONSerialization.jsonObject(with: Data(req.body))) as? [String: Any],
                let path = obj["path"] as? String, !path.isEmpty
            else {
                return Self.jsonError(400, "expected JSON body {\"path\":...}")
            }
            let lang = (try? AudioTrackProbe().probe(videoPath: path))?
                .first(where: { $0.language != nil })?.language
            return .ok(.json(["language": lang as Any? ?? NSNull()]))
        }

        // POST /character-summaries  body {title, year?, overview?, characters:[...]}
        // → {summaries: {character: "one-sentence role in the plot"}} (AI-generated).
        server.POST["/character-summaries"] = { [pipeline] req in
            guard
                let obj = (try? JSONSerialization.jsonObject(with: Data(req.body))) as? [String: Any],
                let title = obj["title"] as? String, !title.isEmpty,
                let characters = (obj["characters"] as? [Any])?.compactMap({ $0 as? String }),
                !characters.isEmpty
            else {
                return Self.jsonError(400, "expected JSON body {\"title\":..., \"characters\":[...]}")
            }
            let year = (obj["year"] as? Int) ?? (obj["year"] as? NSNumber)?.intValue
            let overview = (obj["overview"] as? String) ?? ""
            let summaries = Self.blockingAwait {
                (try? await pipeline.characterRoles(
                    title: title, year: year, overview: overview, characters: characters)) ?? [:]
            }
            return .ok(.json(["summaries": summaries]))
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
            let strategy = (obj["strategy"] as? String) ?? "quality"
            let force = (obj["force"] as? Bool) ?? false
            let sourceSubtitlePath = (obj["sourceSubtitlePath"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            let sourceSubtitleOverride = (obj["sourceSubtitleOverride"] as? Bool) ?? false
            let characters = (obj["characters"] as? [String: Any])?
                .compactMapValues { $0 as? String }
            let job = Self.blockingAwait {
                await store.enqueue(path: path, target: target, strategy: strategy,
                                    force: force, sourceSubtitlePath: sourceSubtitlePath,
                                    sourceSubtitleOverride: sourceSubtitleOverride,
                                    characters: characters)
            }
            return .ok(.json(job.jsonObject()))
        }

        // POST /jobs/prioritize  body {"paths":[...],"target":"he","strategy":"...","preempt":false}
        // Move paths to the front of the queue; with preempt, stop the running job.
        server.POST["/jobs/prioritize"] = { [store, weak self] req in
            guard
                let obj = (try? JSONSerialization.jsonObject(with: Data(req.body))) as? [String: Any],
                let paths = obj["paths"] as? [String], !paths.isEmpty,
                let target = obj["target"] as? String, !target.isEmpty
            else {
                return Self.jsonError(400, "expected JSON body {\"paths\":[...], \"target\":...}")
            }
            let strategy = (obj["strategy"] as? String) ?? "quality"
            let preempt = (obj["preempt"] as? Bool) ?? false
            let force = (obj["force"] as? Bool) ?? false
            let jobs = Self.blockingAwait {
                await store.prioritize(paths: paths, target: target, strategy: strategy, force: force)
            }
            if preempt {
                let exclude = Set(paths)
                if let running = Self.blockingAwait({ await store.runningJob(excludingPaths: exclude) }) {
                    self?.preempt(id: running.id)
                }
            }
            return .ok(.json(["jobs": jobs.map { $0.jsonObject() }]))
        }

        // DELETE /jobs — clear all non-running jobs (running one finishes).
        server.DELETE["/jobs"] = { [store] _ in
            let n = Self.blockingAwait { await store.clearNonRunning() }
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

                self?.log("job \(job.id): source=\(job.sourceSubtitlePath != nil ? "file" : "asr"), knownChars=\(job.characters?.count ?? 0)")
                // Run the pipeline in a child task so a "Translate now" request can
                // cancel it mid-flight (cooperative — cancellation lands at the next
                // await/chunk boundary).
                let jobTask = Task {
                    try await pipeline.run(
                        videoPath: job.path,
                        targetLang: job.target,
                        strategy: TranslationStrategy(wire: job.strategy),
                        sourceSubtitlePath: job.sourceSubtitlePath,
                        sourceSubtitleOverride: job.sourceSubtitleOverride,
                        characters: job.characters ?? [:],
                        force: job.force,
                        onProgress: { progress, stage in
                            Task { await store.updateProgress(job.id, stage: stage, progress: progress) }
                        },
                        onDraftReady: { draftPath in
                            // Progressive: the 7B draft is watchable now; keep refining.
                            Task { await store.markDraftReady(job.id, sidecarPath: draftPath, progress: 0.70) }
                        }
                    )
                }
                self?.setCurrent(job.id, cancel: { jobTask.cancel() })

                do {
                    let result = try await jobTask.value
                    self?.clearCurrent()
                    await store.markDone(
                        job.id,
                        sidecarPath: result.sidecarPath,
                        rating: JobRating.success(result: result))
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
                            qaFlags: result.qaFlags,
                            bibleVersionUsed: result.bibleVersionUsed)
                        try? await sqlite.upsertArtifact(artifact)
                    }
                } catch {
                    self?.clearCurrent()
                    let stopReason = self?.takeStopReason(job.id)
                    switch stopReason {
                    case .pause:
                        await store.markPaused(job.id)
                        self?.log("paused job \(job.id)")
                    case .cancel:
                        await store.markCancelled(job.id)
                        self?.log("cancelled job \(job.id)")
                    case .preempt:
                        await store.markQueued(job.id)
                        self?.log("preempted job \(job.id) → re-queued")
                    case .none:
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
}
