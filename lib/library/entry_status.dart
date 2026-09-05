// Per-entry + aggregate translation status — shared by the library cards, the
// series-card rollup, and the episode rows in the series detail. Keeps the
// status mapping in one place (DESIGN_SYSTEM §3.1 status palette).

import '../ui/tokens.dart';
import 'library_store.dart';
import 'processing_manager.dart';

enum StatusBucket { ready, inProgress, needsAttention }

class EntryStatus {
  const EntryStatus(this.style, this.label, this.progress, this.bucket);
  final StatusStyle? style; // null = ready/calm (no chip)
  final String? label;
  final double? progress;
  final StatusBucket bucket;

  static const ready = EntryStatus(null, null, null, StatusBucket.ready);
}

/// Status of a single title file. Job state takes precedence over an existing
/// sidecar, so a re-generate (running job over an old sidecar) shows as
/// translating rather than staying a calm "ready".
EntryStatus entryStatus(
    LibraryEntry e, ProcessingManager manager, String lang) {
  final job = manager.jobFor(e.path);
  if (job != null) {
    switch (job.state) {
      case 'running':
        // Progressive: a watchable 7B draft exists while the 12B refines gender.
        if (job.isRefining) {
          return EntryStatus(StatusStyles.running, 'Refining gender',
              job.progress, StatusBucket.ready);
        }
        return EntryStatus(StatusStyles.running, 'Translating', job.progress,
            StatusBucket.inProgress);
      case 'queued':
        return EntryStatus(
            StatusStyles.queued,
            e.hasSidecar(lang) ? 'Re-translating' : 'Waiting',
            null,
            StatusBucket.inProgress);
      case 'failed':
        return const EntryStatus(
            StatusStyles.failed, null, null, StatusBucket.needsAttention);
      case 'done':
        return EntryStatus.ready;
    }
  }
  if (e.hasSidecar(lang)) return EntryStatus.ready;
  return const EntryStatus(
      StatusStyles.queued, 'Waiting', null, StatusBucket.inProgress);
}

/// Roll up a series' episodes into one status (worst-of precedence: a running
/// episode beats queued beats ready; any failure surfaces as attention).
EntryStatus aggregateStatus(
    List<LibraryEntry> entries, ProcessingManager manager, String lang) {
  var running = 0, failed = 0, queued = 0;
  for (final e in entries) {
    final s = entryStatus(e, manager, lang);
    switch (s.bucket) {
      case StatusBucket.needsAttention:
        failed++;
      case StatusBucket.inProgress:
        if (s.style == StatusStyles.running) {
          running++;
        } else {
          queued++;
        }
      case StatusBucket.ready:
        break;
    }
  }
  if (running > 0) {
    return EntryStatus(StatusStyles.running, 'Translating $running', null,
        StatusBucket.inProgress);
  }
  if (failed > 0) {
    return EntryStatus(
        StatusStyles.failed, '$failed failed', null, StatusBucket.needsAttention);
  }
  if (queued > 0) {
    return const EntryStatus(
        StatusStyles.queued, null, null, StatusBucket.inProgress);
  }
  return EntryStatus.ready;
}
