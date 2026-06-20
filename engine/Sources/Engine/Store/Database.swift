// AppDatabase — GRDB connection + schema migrations (SPEC §3, §5).
//
// The SQLite file is the Mac's source of truth. It is SMALL and lives on the
// INTERNAL disk under ~/Library/Application Support/AutoSub — NOT on
// $AUTOSUB_MODELS (only multi-GB model WEIGHTS go on the external drive,
// docs/MODELS.md). A DatabasePool gives WAL mode (concurrent readers while the
// worker writes).
//
// Migrations are append-only: never edit a shipped migration; add "v2", "v3", …

import Foundation
import GRDB

public final class AppDatabase: @unchecked Sendable {
    public let pool: DatabasePool

    init(pool: DatabasePool) { self.pool = pool }

    /// Default on-disk location (internal disk, created if absent).
    public static func appSupportURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("AutoSub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("autosub.sqlite")
    }

    /// Open + migrate. `url == nil` → the default app-support path. Tests pass a
    /// temp-file URL (DatabasePool needs a real file for WAL; not `:memory:`).
    public static func open(at url: URL? = nil) throws -> AppDatabase {
        let dbURL = try url ?? appSupportURL()
        let pool = try DatabasePool(path: dbURL.path)
        try migrator.migrate(pool)
        return AppDatabase(pool: pool)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: schemaV1)
        }
        return migrator
    }
}

// MARK: - v1 schema

// Tables mirror the §5 entities. Leaf collections (name_translations, aliases,
// relationships, cps_stats, qa_flags, audio_tracks) are JSON-encoded TEXT
// columns; `bible_character` is a TABLE OF ROWS (not a blob) so corrections can
// `UPDATE … WHERE user_corrected = 0` per character (M2/M3). No FK constraints —
// this is a single-writer local DB and the manual child management (delete
// bible_character by bible_id) doesn't need them; indexes carry the query load.
private let schemaV1 = """
CREATE TABLE contextual_parent (
  id         TEXT PRIMARY KEY,
  type       TEXT NOT NULL,
  tmdb_id    INTEGER,
  bible_id   TEXT,
  group_key  TEXT
);
CREATE UNIQUE INDEX idx_parent_groupkey ON contextual_parent(group_key) WHERE group_key IS NOT NULL;
CREATE INDEX idx_parent_tmdb ON contextual_parent(tmdb_id) WHERE tmdb_id IS NOT NULL;

CREATE TABLE title (
  id                   TEXT PRIMARY KEY,
  path                 TEXT NOT NULL,
  content_hash         TEXT,
  container            TEXT,
  codec                TEXT,
  duration_ms          INTEGER,
  contextual_parent_id TEXT,
  tmdb_id              INTEGER,
  source_preference    TEXT NOT NULL DEFAULT 'auto',
  status               TEXT NOT NULL DEFAULT 'new',
  audio_tracks_json    TEXT
);
CREATE UNIQUE INDEX idx_title_content_hash ON title(content_hash) WHERE content_hash IS NOT NULL;
CREATE INDEX idx_title_parent ON title(contextual_parent_id);
CREATE INDEX idx_title_path ON title(path);

CREATE TABLE character_bible (
  id                   TEXT PRIMARY KEY,
  contextual_parent_id TEXT NOT NULL,
  version              INTEGER NOT NULL DEFAULT 1,
  locked_by_user       INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX idx_bible_parent ON character_bible(contextual_parent_id);

CREATE TABLE bible_character (
  id                 TEXT PRIMARY KEY,
  bible_id           TEXT NOT NULL,
  canonical_name     TEXT NOT NULL,
  gender             TEXT NOT NULL DEFAULT 'unknown',
  name_translations  TEXT NOT NULL DEFAULT '{}',
  aliases            TEXT NOT NULL DEFAULT '[]',
  relationships      TEXT NOT NULL DEFAULT '[]',
  confidence         REAL NOT NULL DEFAULT 0,
  user_corrected     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_char_bible ON bible_character(bible_id);

CREATE TABLE subtitle_artifact (
  id                 TEXT PRIMARY KEY,
  title_id           TEXT NOT NULL,
  lang               TEXT NOT NULL,
  format             TEXT NOT NULL DEFAULT 'srt',
  source             TEXT NOT NULL DEFAULT 'asr',
  engine             TEXT NOT NULL DEFAULT '',
  model              TEXT NOT NULL DEFAULT '',
  version            TEXT NOT NULL DEFAULT '',
  sidecar_path       TEXT,
  internal_blob_id   TEXT,
  cps_stats          TEXT NOT NULL DEFAULT '{}',
  qa_flags           TEXT NOT NULL DEFAULT '[]',
  bible_version_used INTEGER,
  state              TEXT NOT NULL DEFAULT 'ready',
  has_user_edits     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_artifact_title ON subtitle_artifact(title_id);
CREATE INDEX idx_artifact_title_lang ON subtitle_artifact(title_id, lang);

CREATE TABLE job (
  id           TEXT PRIMARY KEY,
  path         TEXT NOT NULL,
  target       TEXT NOT NULL,
  state        TEXT NOT NULL,
  stage        TEXT,
  progress     REAL NOT NULL DEFAULT 0,
  sidecar_path TEXT,
  error        TEXT,
  priority     INTEGER NOT NULL DEFAULT 0,
  seq          INTEGER NOT NULL,
  title_id     TEXT,
  created_at   REAL NOT NULL
);
CREATE INDEX idx_job_state ON job(state);
CREATE INDEX idx_job_order ON job(state, priority DESC, seq ASC);

CREATE TABLE processing_job (
  id        TEXT PRIMARY KEY,
  title_id  TEXT NOT NULL,
  stage     TEXT NOT NULL,
  state     TEXT NOT NULL,
  priority  INTEGER NOT NULL DEFAULT 0,
  progress  REAL NOT NULL DEFAULT 0,
  attempts  INTEGER NOT NULL DEFAULT 0,
  error     TEXT
);

CREATE TABLE sync_record (
  id             TEXT PRIMARY KEY,
  artifact_id    TEXT NOT NULL,
  transport      TEXT NOT NULL,
  state          TEXT NOT NULL DEFAULT 'pending',
  checksum       TEXT,
  device_targets TEXT NOT NULL DEFAULT '[]'
);
"""
