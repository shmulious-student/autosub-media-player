// Store — SQLite source of truth (SPEC §3).
//
// The Mac's SQLite DB is authoritative for titles, contextual parents, bibles,
// artifacts, jobs, and sync records. A derived read-only library index is what
// gets published to the app + synced to iOS.
//
// v0 status: protocol + in-memory stub. TODO: back with SQLite (e.g. GRDB or the
// system libsqlite3). The DB file itself is small and stays on the internal
// disk; only model WEIGHTS go on the external drive (docs/MODELS.md).

import Foundation

public protocol Store: Sendable {
    // Titles
    func upsertTitle(_ title: Title) async throws
    func titles() async throws -> [Title]

    // Contextual parents + bibles
    func upsertContextualParent(_ parent: ContextualParent) async throws
    func upsertBible(_ bible: CharacterBible) async throws
    func bible(forContextualParentId id: String) async throws -> CharacterBible?

    // Artifacts
    func upsertArtifact(_ artifact: SubtitleArtifact) async throws
    func artifacts(forTitleId id: String) async throws -> [SubtitleArtifact]

    // Jobs + sync
    func upsertJob(_ job: ProcessingJob) async throws
    func jobs() async throws -> [ProcessingJob]
    func upsertSyncRecord(_ record: SyncRecord) async throws
}

/// In-memory stub Store so the engine compiles + runs end-to-end without SQLite.
public actor InMemoryStore: Store {
    private var titlesById: [String: Title] = [:]
    private var parentsById: [String: ContextualParent] = [:]
    private var biblesByParent: [String: CharacterBible] = [:]
    private var artifactsByTitle: [String: [SubtitleArtifact]] = [:]
    private var jobsById: [String: ProcessingJob] = [:]
    private var syncById: [String: SyncRecord] = [:]

    public init() {}

    public func upsertTitle(_ title: Title) async throws { titlesById[title.id] = title }
    public func titles() async throws -> [Title] { Array(titlesById.values) }

    public func upsertContextualParent(_ parent: ContextualParent) async throws {
        parentsById[parent.id] = parent
    }
    public func upsertBible(_ bible: CharacterBible) async throws {
        biblesByParent[bible.contextualParentId] = bible
    }
    public func bible(forContextualParentId id: String) async throws -> CharacterBible? {
        biblesByParent[id]
    }

    public func upsertArtifact(_ artifact: SubtitleArtifact) async throws {
        artifactsByTitle[artifact.titleId, default: []].append(artifact)
    }
    public func artifacts(forTitleId id: String) async throws -> [SubtitleArtifact] {
        artifactsByTitle[id] ?? []
    }

    public func upsertJob(_ job: ProcessingJob) async throws { jobsById[job.id] = job }
    public func jobs() async throws -> [ProcessingJob] { Array(jobsById.values) }
    public func upsertSyncRecord(_ record: SyncRecord) async throws {
        syncById[record.id] = record
    }
}
