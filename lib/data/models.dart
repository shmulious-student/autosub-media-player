// AutoSub Media Player — core data model (SPEC §5).
//
// These are the app-side Dart mirrors of the entities. The Mac engine's SQLite
// store (Swift) is the source of truth; the app consumes a derived read-only
// library index plus locally-edited bibles. Keep these field names in lockstep
// with `engine/Sources/Engine/Models/*` and SPEC §5.
//
// JSON (de)serialization is hand-written (no codegen) so this file stays
// dependency-free and trivially testable.

import 'dart:convert';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// How subtitles should be sourced for a [Title].
enum SourcePreference { embedded, asr, auto }

/// Kind of [ContextualParent] that owns a shared bible.
enum ContextualParentType { series, franchise, standalone }

/// Grammatical gender used for Hebrew gender/grammar correctness (SPEC §4).
enum Gender { m, f, nb, unknown }

/// On-disk subtitle container format.
enum SubtitleFormat { srt, ass }

/// Where a subtitle's text came from.
enum SubtitleSource { embedded, asr }

/// Lifecycle state of a [ProcessingJob].
enum JobState { queued, running, paused, failed, done }

/// Transport used to move an artifact to another device (SPEC §6).
enum SyncTransport { icloud, lan }

/// Per-record sync lifecycle state.
enum SyncState { pending, inFlight, synced, conflict, failed }

// ---------------------------------------------------------------------------
// Enum <-> wire-string helpers
// ---------------------------------------------------------------------------

T _enumFromString<T>(List<T> values, String? raw, T fallback) {
  if (raw == null) return fallback;
  for (final v in values) {
    if (_enumName(v as Enum) == raw) return v;
  }
  return fallback;
}

String _enumName(Enum e) => e.name;

// ---------------------------------------------------------------------------
// Title
// ---------------------------------------------------------------------------

/// A single media file in the library. SPEC §5.
class Title {
  final String id;
  final String path;
  final String? contentHash;
  final String? container; // e.g. "mkv"
  final String? codec; // e.g. "hevc"
  final Duration? duration;
  final String? contextualParentId;
  final int? tmdbId;
  final SourcePreference sourcePreference;
  final String status;

  const Title({
    required this.id,
    required this.path,
    this.contentHash,
    this.container,
    this.codec,
    this.duration,
    this.contextualParentId,
    this.tmdbId,
    this.sourcePreference = SourcePreference.auto,
    this.status = 'new',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'content_hash': contentHash,
        'container': container,
        'codec': codec,
        'duration_ms': duration?.inMilliseconds,
        'contextual_parent_id': contextualParentId,
        'tmdb_id': tmdbId,
        'source_preference': sourcePreference.name,
        'status': status,
      };

  factory Title.fromJson(Map<String, dynamic> j) => Title(
        id: j['id'] as String,
        path: j['path'] as String,
        contentHash: j['content_hash'] as String?,
        container: j['container'] as String?,
        codec: j['codec'] as String?,
        duration: j['duration_ms'] == null
            ? null
            : Duration(milliseconds: (j['duration_ms'] as num).toInt()),
        contextualParentId: j['contextual_parent_id'] as String?,
        tmdbId: (j['tmdb_id'] as num?)?.toInt(),
        sourcePreference: _enumFromString(
            SourcePreference.values, j['source_preference'] as String?,
            SourcePreference.auto),
        status: (j['status'] as String?) ?? 'new',
      );
}

// ---------------------------------------------------------------------------
// ContextualParent
// ---------------------------------------------------------------------------

/// The series/franchise/standalone unit that owns one shared bible. SPEC §5.
class ContextualParent {
  final String id;
  final ContextualParentType type;
  final int? tmdbId;
  final String? bibleId;

  const ContextualParent({
    required this.id,
    required this.type,
    this.tmdbId,
    this.bibleId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'tmdb_id': tmdbId,
        'bible_id': bibleId,
      };

  factory ContextualParent.fromJson(Map<String, dynamic> j) => ContextualParent(
        id: j['id'] as String,
        type: _enumFromString(ContextualParentType.values, j['type'] as String?,
            ContextualParentType.standalone),
        tmdbId: (j['tmdb_id'] as num?)?.toInt(),
        bibleId: j['bible_id'] as String?,
      );
}

// ---------------------------------------------------------------------------
// CharacterBible + Character
// ---------------------------------------------------------------------------

/// A versioned bag of [Character]s scoped to one [ContextualParent]. SPEC §5.
///
/// Bumping [version] after a user correction is what triggers invalidation +
/// re-queue of artifacts whose `bibleVersionUsed` is older (SPEC §4).
class CharacterBible {
  final String id;
  final String contextualParentId;
  final int version;
  final bool lockedByUser;
  final List<Character> characters;

  const CharacterBible({
    required this.id,
    required this.contextualParentId,
    this.version = 1,
    this.lockedByUser = false,
    this.characters = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'contextual_parent_id': contextualParentId,
        'version': version,
        'locked_by_user': lockedByUser,
        'characters': characters.map((c) => c.toJson()).toList(),
      };

  factory CharacterBible.fromJson(Map<String, dynamic> j) => CharacterBible(
        id: j['id'] as String,
        contextualParentId: j['contextual_parent_id'] as String,
        version: (j['version'] as num?)?.toInt() ?? 1,
        lockedByUser: (j['locked_by_user'] as bool?) ?? false,
        characters: ((j['characters'] as List?) ?? const [])
            .map((e) => Character.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// One character within a [CharacterBible]. SPEC §5.
///
/// `nameTranslations` is a glossary-locked map of lang-code -> translated name
/// so a character's rendered name never drifts across episodes/films (SPEC §4).
class Character {
  final String id;
  final String canonicalName;
  final Gender gender;
  final Map<String, String> nameTranslations; // lang -> translated name
  final List<String> aliases;
  final List<String> relationships;
  final double confidence;
  final bool userCorrected;

  const Character({
    required this.id,
    required this.canonicalName,
    this.gender = Gender.unknown,
    this.nameTranslations = const {},
    this.aliases = const [],
    this.relationships = const [],
    this.confidence = 0.0,
    this.userCorrected = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'canonical_name': canonicalName,
        'gender': gender.name,
        'name_translations': nameTranslations,
        'aliases': aliases,
        'relationships': relationships,
        'confidence': confidence,
        'user_corrected': userCorrected,
      };

  factory Character.fromJson(Map<String, dynamic> j) => Character(
        id: j['id'] as String,
        canonicalName: j['canonical_name'] as String,
        gender: _enumFromString(
            Gender.values, j['gender'] as String?, Gender.unknown),
        nameTranslations: ((j['name_translations'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, v as String)),
        aliases: ((j['aliases'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        relationships: ((j['relationships'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0.0,
        userCorrected: (j['user_corrected'] as bool?) ?? false,
      );
}

// ---------------------------------------------------------------------------
// SubtitleArtifact
// ---------------------------------------------------------------------------

/// A produced subtitle file + its provenance/QA metadata. SPEC §5.
class SubtitleArtifact {
  final String id;
  final String titleId;
  final String lang; // BCP-47-ish, e.g. "he"
  final SubtitleFormat format;
  final SubtitleSource source;
  final String engine; // e.g. "whisperkit+dictalm"
  final String model; // e.g. "dictalm-3.0-12b"
  final String version; // model/pipeline version stamp
  final String? sidecarPath;
  final String? internalBlobId;
  final Map<String, dynamic> cpsStats;
  final List<String> qaFlags;
  final int? bibleVersionUsed;

  const SubtitleArtifact({
    required this.id,
    required this.titleId,
    required this.lang,
    this.format = SubtitleFormat.srt,
    this.source = SubtitleSource.asr,
    this.engine = '',
    this.model = '',
    this.version = '',
    this.sidecarPath,
    this.internalBlobId,
    this.cpsStats = const {},
    this.qaFlags = const [],
    this.bibleVersionUsed,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title_id': titleId,
        'lang': lang,
        'format': format.name,
        'source': source.name,
        'engine': engine,
        'model': model,
        'version': version,
        'sidecar_path': sidecarPath,
        'internal_blob_id': internalBlobId,
        'cps_stats': cpsStats,
        'qa_flags': qaFlags,
        'bible_version_used': bibleVersionUsed,
      };

  factory SubtitleArtifact.fromJson(Map<String, dynamic> j) => SubtitleArtifact(
        id: j['id'] as String,
        titleId: j['title_id'] as String,
        lang: j['lang'] as String,
        format: _enumFromString(
            SubtitleFormat.values, j['format'] as String?, SubtitleFormat.srt),
        source: _enumFromString(
            SubtitleSource.values, j['source'] as String?, SubtitleSource.asr),
        engine: (j['engine'] as String?) ?? '',
        model: (j['model'] as String?) ?? '',
        version: (j['version'] as String?) ?? '',
        sidecarPath: j['sidecar_path'] as String?,
        internalBlobId: j['internal_blob_id'] as String?,
        cpsStats: ((j['cps_stats'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k as String, v)),
        qaFlags: ((j['qa_flags'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        bibleVersionUsed: (j['bible_version_used'] as num?)?.toInt(),
      );
}

// ---------------------------------------------------------------------------
// ProcessingJob
// ---------------------------------------------------------------------------

/// A unit of work in the engine's persistent queue. SPEC §4/§5.
class ProcessingJob {
  final String id;
  final String titleId;
  final String stage; // current pipeline stage name (see SPEC §4)
  final JobState state;
  final int priority; // higher = runs sooner
  final double progress; // 0.0..1.0
  final int attempts;
  final String? error;

  const ProcessingJob({
    required this.id,
    required this.titleId,
    required this.stage,
    this.state = JobState.queued,
    this.priority = 0,
    this.progress = 0.0,
    this.attempts = 0,
    this.error,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title_id': titleId,
        'stage': stage,
        'state': state.name,
        'priority': priority,
        'progress': progress,
        'attempts': attempts,
        'error': error,
      };

  factory ProcessingJob.fromJson(Map<String, dynamic> j) => ProcessingJob(
        id: j['id'] as String,
        titleId: j['title_id'] as String,
        stage: (j['stage'] as String?) ?? '',
        state:
            _enumFromString(JobState.values, j['state'] as String?, JobState.queued),
        priority: (j['priority'] as num?)?.toInt() ?? 0,
        progress: (j['progress'] as num?)?.toDouble() ?? 0.0,
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        error: j['error'] as String?,
      );
}

// ---------------------------------------------------------------------------
// SyncRecord
// ---------------------------------------------------------------------------

/// Tracks delivery of one artifact to device targets. SPEC §5/§6.
class SyncRecord {
  final String id;
  final String artifactId;
  final SyncTransport transport;
  final SyncState state;
  final String? checksum;
  final List<String> deviceTargets;

  const SyncRecord({
    required this.id,
    required this.artifactId,
    required this.transport,
    this.state = SyncState.pending,
    this.checksum,
    this.deviceTargets = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'artifact_id': artifactId,
        'transport': transport.name,
        'state': state.name,
        'checksum': checksum,
        'device_targets': deviceTargets,
      };

  factory SyncRecord.fromJson(Map<String, dynamic> j) => SyncRecord(
        id: j['id'] as String,
        artifactId: j['artifact_id'] as String,
        transport: _enumFromString(SyncTransport.values,
            j['transport'] as String?, SyncTransport.lan),
        state: _enumFromString(
            SyncState.values, j['state'] as String?, SyncState.pending),
        checksum: j['checksum'] as String?,
        deviceTargets: ((j['device_targets'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
      );
}

// ---------------------------------------------------------------------------
// Convenience codecs (string <-> object), handy for the engine HTTP bridge.
// ---------------------------------------------------------------------------

String encodeModel(Object model) => jsonEncode((model as dynamic).toJson());
