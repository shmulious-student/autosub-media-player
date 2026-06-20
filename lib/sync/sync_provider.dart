// SyncProvider — dual-transport artifact sync (SPEC §6).
//
// Only *small* artifacts sync: the library index, character bibles, and
// subtitle sidecars. Video never syncs. The Mac is authoritative; bibles are
// the only iOS-editable entity, so they use per-record versioning with
// last-writer-wins + a merge prompt on conflict.
//
// v0 status: STUBS. Two impls are provided to lock the API shape:
//   - BonjourSyncProvider — fast LAN transport (home).
//   - ICloudSyncProvider  — CloudKit remote transport.

import 'dart:async';

import '../data/models.dart';

/// Outcome of pushing/pulling a record.
class SyncResult {
  const SyncResult({required this.record, this.conflict = false});
  final SyncRecord record;

  /// True when a version conflict was detected and a merge prompt is needed
  /// (bibles only — see SPEC §6 last-writer-wins + merge).
  final bool conflict;
}

/// Abstract dual-transport sync interface.
abstract class SyncProvider {
  /// Human-readable transport name, e.g. "Bonjour/LAN" or "iCloud".
  SyncTransport get transport;

  /// Whether this transport is currently usable (peer found / signed in).
  Future<bool> isAvailable();

  /// Push one artifact's bytes (sidecar/bible/index) to device targets.
  Future<SyncResult> pushArtifact(SubtitleArtifact artifact);

  /// Pull any artifacts updated remotely since [sinceCheckpoint] (opaque token).
  Future<List<SubtitleArtifact>> pullArtifacts({String? sinceCheckpoint});

  /// Push a (possibly iOS-edited) bible back to the Mac, honoring versioning.
  Future<SyncResult> pushBible(CharacterBible bible);

  /// Stream of incoming sync events (progress / conflicts) for the UI.
  Stream<SyncRecord> events();
}

/// Fast LAN transport over Bonjour/mDNS service discovery + a small file server
/// hosted by the same Mac daemon. Used when both devices are on the home LAN.
class BonjourSyncProvider implements SyncProvider {
  @override
  SyncTransport get transport => SyncTransport.lan;

  @override
  Future<bool> isAvailable() async {
    // TODO(v2): mDNS browse for the engine's advertised _autosub._tcp service.
    return false;
  }

  @override
  Future<SyncResult> pushArtifact(SubtitleArtifact artifact) async {
    // TODO(v2): HTTP PUT to the discovered peer; compute + record checksum.
    return SyncResult(
      record: SyncRecord(
        id: 'stub-lan-${artifact.id}',
        artifactId: artifact.id,
        transport: SyncTransport.lan,
      ),
    );
  }

  @override
  Future<List<SubtitleArtifact>> pullArtifacts({String? sinceCheckpoint}) async {
    // TODO(v2): GET changed artifacts from peer since checkpoint.
    return const <SubtitleArtifact>[];
  }

  @override
  Future<SyncResult> pushBible(CharacterBible bible) async {
    // TODO(v2): version-aware PUT; detect conflict via remote bible.version.
    return SyncResult(
      record: SyncRecord(
        id: 'stub-lan-bible-${bible.id}',
        artifactId: bible.id,
        transport: SyncTransport.lan,
      ),
    );
  }

  @override
  Stream<SyncRecord> events() => const Stream<SyncRecord>.empty();
}

/// Remote transport via CloudKit/iCloud. Used when off the home LAN.
class ICloudSyncProvider implements SyncProvider {
  @override
  SyncTransport get transport => SyncTransport.icloud;

  @override
  Future<bool> isAvailable() async {
    // TODO(v3): check iCloud account status / container availability.
    return false;
  }

  @override
  Future<SyncResult> pushArtifact(SubtitleArtifact artifact) async {
    // TODO(v3): save CKRecord for the artifact blob + metadata.
    return SyncResult(
      record: SyncRecord(
        id: 'stub-icloud-${artifact.id}',
        artifactId: artifact.id,
        transport: SyncTransport.icloud,
      ),
    );
  }

  @override
  Future<List<SubtitleArtifact>> pullArtifacts({String? sinceCheckpoint}) async {
    // TODO(v3): CKFetchRecordZoneChanges since the server change token.
    return const <SubtitleArtifact>[];
  }

  @override
  Future<SyncResult> pushBible(CharacterBible bible) async {
    // TODO(v3): version-aware CKRecord save; surface CKConflict as merge prompt.
    return SyncResult(
      record: SyncRecord(
        id: 'stub-icloud-bible-${bible.id}',
        artifactId: bible.id,
        transport: SyncTransport.icloud,
      ),
    );
  }

  @override
  Stream<SyncRecord> events() => const Stream<SyncRecord>.empty();
}
