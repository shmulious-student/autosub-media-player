// Swift mirrors of the core entities (SPEC §5).
//
// These are the engine-side source-of-truth structs. Keep field names in lockstep
// with `lib/data/models.dart` so the loopback HTTP bridge can round-trip JSON.
// All types are Codable for the IPC layer + SQLite (de)serialization.

import Foundation

// MARK: - Enums

public enum SourcePreference: String, Codable, Sendable {
    case embedded, asr, auto
}

public enum ContextualParentType: String, Codable, Sendable {
    case series, franchise, standalone
}

public enum Gender: String, Codable, Sendable {
    case m, f, nb, unknown
}

public enum SubtitleFormat: String, Codable, Sendable {
    case srt, ass
}

public enum SubtitleSource: String, Codable, Sendable {
    case embedded, asr
}

public enum JobState: String, Codable, Sendable {
    case queued, running, paused, failed, done
}

public enum SyncTransport: String, Codable, Sendable {
    case icloud, lan
}

public enum SyncState: String, Codable, Sendable {
    case pending, inFlight, synced, conflict, failed
}

// MARK: - Title

public struct Title: Codable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var contentHash: String?
    public var container: String?
    public var codec: String?
    public var durationMs: Int?
    public var contextualParentId: String?
    public var tmdbId: Int?
    public var sourcePreference: SourcePreference
    public var status: String

    public init(
        id: String,
        path: String,
        contentHash: String? = nil,
        container: String? = nil,
        codec: String? = nil,
        durationMs: Int? = nil,
        contextualParentId: String? = nil,
        tmdbId: Int? = nil,
        sourcePreference: SourcePreference = .auto,
        status: String = "new"
    ) {
        self.id = id
        self.path = path
        self.contentHash = contentHash
        self.container = container
        self.codec = codec
        self.durationMs = durationMs
        self.contextualParentId = contextualParentId
        self.tmdbId = tmdbId
        self.sourcePreference = sourcePreference
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, path, container, codec, status
        case contentHash = "content_hash"
        case durationMs = "duration_ms"
        case contextualParentId = "contextual_parent_id"
        case tmdbId = "tmdb_id"
        case sourcePreference = "source_preference"
    }
}

// MARK: - ContextualParent

public struct ContextualParent: Codable, Sendable, Identifiable {
    public var id: String
    public var type: ContextualParentType
    public var tmdbId: Int?
    public var bibleId: String?

    public init(id: String, type: ContextualParentType, tmdbId: Int? = nil, bibleId: String? = nil) {
        self.id = id
        self.type = type
        self.tmdbId = tmdbId
        self.bibleId = bibleId
    }

    enum CodingKeys: String, CodingKey {
        case id, type
        case tmdbId = "tmdb_id"
        case bibleId = "bible_id"
    }
}

// MARK: - CharacterBible + BibleCharacter

public struct CharacterBible: Codable, Sendable, Identifiable {
    public var id: String
    public var contextualParentId: String
    public var version: Int
    public var lockedByUser: Bool
    public var characters: [BibleCharacter]

    public init(
        id: String,
        contextualParentId: String,
        version: Int = 1,
        lockedByUser: Bool = false,
        characters: [BibleCharacter] = []
    ) {
        self.id = id
        self.contextualParentId = contextualParentId
        self.version = version
        self.lockedByUser = lockedByUser
        self.characters = characters
    }

    enum CodingKeys: String, CodingKey {
        case id, version, characters
        case contextualParentId = "contextual_parent_id"
        case lockedByUser = "locked_by_user"
    }
}

public struct BibleCharacter: Codable, Sendable, Identifiable {
    public var id: String
    public var canonicalName: String
    public var gender: Gender
    /// lang code -> translated name (glossary-locked, SPEC §4).
    public var nameTranslations: [String: String]
    public var aliases: [String]
    public var relationships: [String]
    public var confidence: Double
    public var userCorrected: Bool

    public init(
        id: String,
        canonicalName: String,
        gender: Gender = .unknown,
        nameTranslations: [String: String] = [:],
        aliases: [String] = [],
        relationships: [String] = [],
        confidence: Double = 0.0,
        userCorrected: Bool = false
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.gender = gender
        self.nameTranslations = nameTranslations
        self.aliases = aliases
        self.relationships = relationships
        self.confidence = confidence
        self.userCorrected = userCorrected
    }

    enum CodingKeys: String, CodingKey {
        case id, gender, aliases, relationships, confidence
        case canonicalName = "canonical_name"
        case nameTranslations = "name_translations"
        case userCorrected = "user_corrected"
    }
}

// MARK: - SubtitleArtifact

public struct SubtitleArtifact: Codable, Sendable, Identifiable {
    public var id: String
    public var titleId: String
    public var lang: String
    public var format: SubtitleFormat
    public var source: SubtitleSource
    public var engine: String
    public var model: String
    public var version: String
    public var sidecarPath: String?
    public var internalBlobId: String?
    public var cpsStats: [String: Double]
    public var qaFlags: [String]
    public var bibleVersionUsed: Int?

    public init(
        id: String,
        titleId: String,
        lang: String,
        format: SubtitleFormat = .srt,
        source: SubtitleSource = .asr,
        engine: String = "",
        model: String = "",
        version: String = "",
        sidecarPath: String? = nil,
        internalBlobId: String? = nil,
        cpsStats: [String: Double] = [:],
        qaFlags: [String] = [],
        bibleVersionUsed: Int? = nil
    ) {
        self.id = id
        self.titleId = titleId
        self.lang = lang
        self.format = format
        self.source = source
        self.engine = engine
        self.model = model
        self.version = version
        self.sidecarPath = sidecarPath
        self.internalBlobId = internalBlobId
        self.cpsStats = cpsStats
        self.qaFlags = qaFlags
        self.bibleVersionUsed = bibleVersionUsed
    }

    enum CodingKeys: String, CodingKey {
        case id, lang, format, source, engine, model, version
        case titleId = "title_id"
        case sidecarPath = "sidecar_path"
        case internalBlobId = "internal_blob_id"
        case cpsStats = "cps_stats"
        case qaFlags = "qa_flags"
        case bibleVersionUsed = "bible_version_used"
    }
}

// MARK: - ProcessingJob

public struct ProcessingJob: Codable, Sendable, Identifiable {
    public var id: String
    public var titleId: String
    public var stage: String
    public var state: JobState
    public var priority: Int
    public var progress: Double
    public var attempts: Int
    public var error: String?

    public init(
        id: String,
        titleId: String,
        stage: String,
        state: JobState = .queued,
        priority: Int = 0,
        progress: Double = 0.0,
        attempts: Int = 0,
        error: String? = nil
    ) {
        self.id = id
        self.titleId = titleId
        self.stage = stage
        self.state = state
        self.priority = priority
        self.progress = progress
        self.attempts = attempts
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case id, stage, state, priority, progress, attempts, error
        case titleId = "title_id"
    }
}

// MARK: - SyncRecord

public struct SyncRecord: Codable, Sendable, Identifiable {
    public var id: String
    public var artifactId: String
    public var transport: SyncTransport
    public var state: SyncState
    public var checksum: String?
    public var deviceTargets: [String]

    public init(
        id: String,
        artifactId: String,
        transport: SyncTransport,
        state: SyncState = .pending,
        checksum: String? = nil,
        deviceTargets: [String] = []
    ) {
        self.id = id
        self.artifactId = artifactId
        self.transport = transport
        self.state = state
        self.checksum = checksum
        self.deviceTargets = deviceTargets
    }

    enum CodingKeys: String, CodingKey {
        case id, transport, state, checksum
        case artifactId = "artifact_id"
        case deviceTargets = "device_targets"
    }
}
