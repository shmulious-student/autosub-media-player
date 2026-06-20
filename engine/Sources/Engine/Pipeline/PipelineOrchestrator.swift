// PipelineOrchestrator — the 12-stage pipeline + persistent JobQueue (SPEC §4).
//
// Pipeline (SPEC §4):
//   Scanner → MetadataEnrich(TMDB) → Grouper → BibleBootstrap → SourceSelector
//   → Demux/AudioExtract → ASR(WhisperKit+align) → Segmenter(CPS)
//   → Translator(bible-aware) → Assembler(.srt/.ass, RTL) → Store → SyncServer
//
// v0 status: stages are defined as an enum + a stub orchestrator that walks a
// job through them. JobQueue is an in-memory stub; persistence (crash-recoverable,
// priority, pause/resume) is TODO via the SQLite Store.

import Foundation

/// The ordered 12 stages of the engine pipeline (SPEC §4).
public enum PipelineStage: String, CaseIterable, Codable, Sendable {
    case scanner = "Scanner"
    case metadataEnrich = "MetadataEnrich"
    case grouper = "Grouper"
    case bibleBootstrap = "BibleBootstrap"
    case sourceSelector = "SourceSelector"
    case demuxAudioExtract = "Demux/AudioExtract"
    case asr = "ASR"
    case segmenter = "Segmenter"
    case translator = "Translator"
    case assembler = "Assembler"
    case store = "Store"
    case syncServer = "SyncServer"
}

/// A persistent, priority-ordered, crash-recoverable job queue.
///
/// v0: in-memory only. TODO: back this with the SQLite Store so jobs survive a
/// crash/restart and support pause/resume + reprioritize (SPEC §4 quality bar).
public actor JobQueue {
    private var jobs: [String: ProcessingJob] = [:]

    public init() {}

    /// Enqueue (or replace) a job. Higher `priority` runs sooner.
    public func enqueue(_ job: ProcessingJob) {
        jobs[job.id] = job
        // TODO: persist to Store; emit a queue-changed event.
    }

    /// Next runnable job: highest priority among `queued`.
    public func nextRunnable() -> ProcessingJob? {
        jobs.values
            .filter { $0.state == .queued }
            .sorted { $0.priority > $1.priority }
            .first
    }

    public func update(_ job: ProcessingJob) {
        jobs[job.id] = job
        // TODO: persist + push progress on the event stream.
    }

    public func all() -> [ProcessingJob] { Array(jobs.values) }

    public func pause(_ jobId: String) {
        guard var j = jobs[jobId] else { return }
        j.state = .paused
        jobs[jobId] = j
    }
}

/// Drives a title through the 12 stages. v0: stub that logs stage transitions.
public actor PipelineOrchestrator {
    private let queue: JobQueue
    private let modelPaths: ModelPaths

    public init(queue: JobQueue, modelPaths: ModelPaths) {
        self.queue = queue
        self.modelPaths = modelPaths
    }

    /// Enqueue a title at stage `Scanner`. Returns the created job.
    public func enqueueTitle(path: String, priority: Int = 0) async -> ProcessingJob {
        let job = ProcessingJob(
            id: UUID().uuidString,
            titleId: UUID().uuidString, // TODO: derive from content_hash via Store
            stage: PipelineStage.scanner.rawValue,
            state: .queued,
            priority: priority
        )
        await queue.enqueue(job)
        return job
    }

    /// Walk one job through every stage. v0: stubbed no-op stages with TODOs.
    ///
    /// TODO(v0 slice): wire Demux/AudioExtract → ASR (WhisperKit) → Segmenter →
    /// Translator (BibleAwareTranslator) → Assembler (.srt) → Store.
    public func run(_ job: ProcessingJob) async {
        var current = job
        for stage in PipelineStage.allCases {
            current.stage = stage.rawValue
            current.state = .running
            await queue.update(current)
            // TODO: dispatch to the concrete stage implementation.
        }
        current.state = .done
        current.progress = 1.0
        await queue.update(current)
    }
}
