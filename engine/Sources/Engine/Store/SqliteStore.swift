// SqliteStore — the GRDB-backed `Store` (SPEC §3 source of truth).
//
// Conforms to the existing `Store` protocol (titles, contextual parents, bibles,
// artifacts, ProcessingJob, sync records) and adds concrete daemon-job
// persistence (`PersistedJob`) used by DaemonServer.JobStore for a
// crash-recoverable queue. Maps the §5 model structs ↔ flat table rows; nested
// collections are JSON columns. Relies on GRDB's DatabasePool for serialization
// (no extra actor) — every method is a short read/write transaction.

import Foundation
import GRDB

/// A persisted daemon-queue job: the wire `DaemonJob` fields + durable ordering
/// metadata (seq/created_at/priority) and an optional link to its Title. Kept
/// separate from §5 `ProcessingJob` so the live queue stays decoupled from the
/// dormant 12-stage scaffold.
public struct PersistedJob: Sendable {
    public var id: String
    public var path: String
    public var target: String
    public var state: String
    public var stage: String?
    public var progress: Double
    public var sidecarPath: String?
    public var error: String?
    public var priority: Int
    public var seq: Int
    public var titleId: String?
    public var createdAt: Double

    public init(
        id: String, path: String, target: String, state: String,
        stage: String? = nil, progress: Double = 0, sidecarPath: String? = nil,
        error: String? = nil, priority: Int = 0, seq: Int, titleId: String? = nil,
        createdAt: Double
    ) {
        self.id = id; self.path = path; self.target = target; self.state = state
        self.stage = stage; self.progress = progress; self.sidecarPath = sidecarPath
        self.error = error; self.priority = priority; self.seq = seq
        self.titleId = titleId; self.createdAt = createdAt
    }
}

public final class SqliteStore: Store, @unchecked Sendable {
    private let db: AppDatabase
    private var pool: DatabasePool { db.pool }

    public init(_ db: AppDatabase) { self.db = db }

    /// Convenience: open (and migrate) the default on-disk DB.
    public static func open() throws -> SqliteStore {
        SqliteStore(try AppDatabase.open())
    }

    // MARK: - Titles

    public func upsertTitle(_ t: Title) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO title
                  (id, path, content_hash, container, codec, duration_ms,
                   contextual_parent_id, tmdb_id, source_preference, status)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  path=excluded.path, content_hash=excluded.content_hash,
                  container=excluded.container, codec=excluded.codec,
                  duration_ms=excluded.duration_ms,
                  contextual_parent_id=excluded.contextual_parent_id,
                  tmdb_id=excluded.tmdb_id, source_preference=excluded.source_preference,
                  status=excluded.status
                """,
                arguments: [t.id, t.path, t.contentHash, t.container, t.codec,
                            t.durationMs, t.contextualParentId, t.tmdbId,
                            t.sourcePreference.rawValue, t.status])
        }
    }

    public func titles() async throws -> [Title] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM title").map(Self.title(from:))
        }
    }

    // MARK: - Contextual parents + bibles

    public func upsertContextualParent(_ p: ContextualParent) async throws {
        // group_key is engine-internal (set by the M2 resolver via a dedicated
        // path); preserve it across upserts of the §5 model.
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO contextual_parent (id, type, tmdb_id, bible_id)
                VALUES (?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  type=excluded.type, tmdb_id=excluded.tmdb_id, bible_id=excluded.bible_id
                """,
                arguments: [p.id, p.type.rawValue, p.tmdbId, p.bibleId])
        }
    }

    public func upsertBible(_ b: CharacterBible) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO character_bible (id, contextual_parent_id, version, locked_by_user)
                VALUES (?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  contextual_parent_id=excluded.contextual_parent_id,
                  version=excluded.version, locked_by_user=excluded.locked_by_user
                """,
                arguments: [b.id, b.contextualParentId, b.version, b.lockedByUser])
            // Replace the character set wholesale (the bible is the unit of edit).
            try db.execute(sql: "DELETE FROM bible_character WHERE bible_id = ?", arguments: [b.id])
            for c in b.characters {
                try db.execute(sql: """
                    INSERT INTO bible_character
                      (id, bible_id, canonical_name, gender, name_translations,
                       aliases, relationships, confidence, user_corrected)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    """,
                    arguments: [c.id, b.id, c.canonicalName, c.gender.rawValue,
                                Self.json(c.nameTranslations), Self.json(c.aliases),
                                Self.json(c.relationships), c.confidence, c.userCorrected])
            }
        }
    }

    public func bible(forContextualParentId id: String) async throws -> CharacterBible? {
        try await pool.read { db in
            guard let brow = try Row.fetchOne(
                db, sql: "SELECT * FROM character_bible WHERE contextual_parent_id = ?",
                arguments: [id]) else { return nil }
            let bibleId: String = brow["id"]
            let chars = try Row.fetchAll(
                db, sql: "SELECT * FROM bible_character WHERE bible_id = ?",
                arguments: [bibleId]).map(Self.character(from:))
            return CharacterBible(
                id: bibleId,
                contextualParentId: brow["contextual_parent_id"],
                version: brow["version"],
                lockedByUser: brow["locked_by_user"],
                characters: chars)
        }
    }

    // MARK: - Artifacts

    public func upsertArtifact(_ a: SubtitleArtifact) async throws {
        // Preserve state/has_user_edits across re-upserts? state cycles with the
        // worker (a fresh successful run is 'ready'); has_user_edits is set only
        // by the future editor and must never be clobbered by a re-generation, so
        // it's INSERT-only here.
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO subtitle_artifact
                  (id, title_id, lang, format, source, engine, model, version,
                   sidecar_path, internal_blob_id, cps_stats, qa_flags,
                   bible_version_used, state)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?, 'ready')
                ON CONFLICT(id) DO UPDATE SET
                  title_id=excluded.title_id, lang=excluded.lang, format=excluded.format,
                  source=excluded.source, engine=excluded.engine, model=excluded.model,
                  version=excluded.version, sidecar_path=excluded.sidecar_path,
                  internal_blob_id=excluded.internal_blob_id, cps_stats=excluded.cps_stats,
                  qa_flags=excluded.qa_flags, bible_version_used=excluded.bible_version_used,
                  state='ready'
                """,
                arguments: [a.id, a.titleId, a.lang, a.format.rawValue, a.source.rawValue,
                            a.engine, a.model, a.version, a.sidecarPath, a.internalBlobId,
                            Self.json(a.cpsStats), Self.json(a.qaFlags), a.bibleVersionUsed])
        }
    }

    public func artifacts(forTitleId id: String) async throws -> [SubtitleArtifact] {
        try await pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM subtitle_artifact WHERE title_id = ?",
                arguments: [id]).map(Self.artifact(from:))
        }
    }

    // MARK: - §5 ProcessingJob (dormant scaffold conformance)

    public func upsertJob(_ j: ProcessingJob) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO processing_job (id, title_id, stage, state, priority, progress, attempts, error)
                VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  title_id=excluded.title_id, stage=excluded.stage, state=excluded.state,
                  priority=excluded.priority, progress=excluded.progress,
                  attempts=excluded.attempts, error=excluded.error
                """,
                arguments: [j.id, j.titleId, j.stage, j.state.rawValue, j.priority,
                            j.progress, j.attempts, j.error])
        }
    }

    public func jobs() async throws -> [ProcessingJob] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM processing_job").map(Self.processingJob(from:))
        }
    }

    public func upsertSyncRecord(_ r: SyncRecord) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO sync_record (id, artifact_id, transport, state, checksum, device_targets)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  artifact_id=excluded.artifact_id, transport=excluded.transport,
                  state=excluded.state, checksum=excluded.checksum,
                  device_targets=excluded.device_targets
                """,
                arguments: [r.id, r.artifactId, r.transport.rawValue, r.state.rawValue,
                            r.checksum, Self.json(r.deviceTargets)])
        }
    }

    // MARK: - Daemon jobs (live queue, crash-recoverable)

    public func saveJob(_ j: PersistedJob) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO job (id, path, target, state, stage, progress, sidecar_path,
                                 error, priority, seq, title_id, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  path=excluded.path, target=excluded.target, state=excluded.state,
                  stage=excluded.stage, progress=excluded.progress,
                  sidecar_path=excluded.sidecar_path, error=excluded.error,
                  priority=excluded.priority, title_id=excluded.title_id
                """,
                arguments: [j.id, j.path, j.target, j.state, j.stage, j.progress,
                            j.sidecarPath, j.error, j.priority, j.seq, j.titleId, j.createdAt])
        }
    }

    /// All persisted jobs in FIFO (seq) order.
    public func loadJobs() async throws -> [PersistedJob] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM job ORDER BY seq ASC").map { row in
                PersistedJob(
                    id: row["id"], path: row["path"], target: row["target"],
                    state: row["state"], stage: row["stage"], progress: row["progress"],
                    sidecarPath: row["sidecar_path"], error: row["error"],
                    priority: row["priority"], seq: row["seq"], titleId: row["title_id"],
                    createdAt: row["created_at"])
            }
        }
    }

    public func deleteJobs(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await pool.write { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try db.execute(sql: "DELETE FROM job WHERE id IN (\(placeholders))",
                           arguments: StatementArguments(ids))
        }
    }

    // MARK: - Row ↔ model mapping

    private static func title(from row: Row) -> Title {
        Title(
            id: row["id"], path: row["path"], contentHash: row["content_hash"],
            container: row["container"], codec: row["codec"], durationMs: row["duration_ms"],
            contextualParentId: row["contextual_parent_id"], tmdbId: row["tmdb_id"],
            sourcePreference: SourcePreference(rawValue: row["source_preference"]) ?? .auto,
            status: row["status"])
    }

    private static func character(from row: Row) -> BibleCharacter {
        BibleCharacter(
            id: row["id"], canonicalName: row["canonical_name"],
            gender: Gender(rawValue: row["gender"]) ?? .unknown,
            nameTranslations: decode(row["name_translations"], default: [:]),
            aliases: decode(row["aliases"], default: []),
            relationships: decode(row["relationships"], default: []),
            confidence: row["confidence"], userCorrected: row["user_corrected"])
    }

    private static func artifact(from row: Row) -> SubtitleArtifact {
        SubtitleArtifact(
            id: row["id"], titleId: row["title_id"], lang: row["lang"],
            format: SubtitleFormat(rawValue: row["format"]) ?? .srt,
            source: SubtitleSource(rawValue: row["source"]) ?? .asr,
            engine: row["engine"], model: row["model"], version: row["version"],
            sidecarPath: row["sidecar_path"], internalBlobId: row["internal_blob_id"],
            cpsStats: decode(row["cps_stats"], default: [:]),
            qaFlags: decode(row["qa_flags"], default: []),
            bibleVersionUsed: row["bible_version_used"])
    }

    private static func processingJob(from row: Row) -> ProcessingJob {
        ProcessingJob(
            id: row["id"], titleId: row["title_id"], stage: row["stage"],
            state: JobState(rawValue: row["state"]) ?? .queued,
            priority: row["priority"], progress: row["progress"],
            attempts: row["attempts"], error: row["error"])
    }

    // MARK: - JSON helpers

    private static func json<T: Encodable>(_ v: T) -> String {
        guard let data = try? JSONEncoder().encode(v),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    private static func decode<T: Decodable>(_ s: String?, default def: T) -> T {
        guard let s, let data = s.data(using: .utf8),
              let v = try? JSONDecoder().decode(T.self, from: data) else { return def }
        return v
    }
}
