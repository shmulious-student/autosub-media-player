// QueuePage — the processing queue (SPEC §4, SCREENS §7).
//
// The persistent queue with the controls the engine supports today: live per-job
// progress + stage, retry on failure, and a bulk "Clear queue". Jobs are grouped
// Active · Failed · Recently finished. Engine-offline freezes the queue with an
// explanation (OfflineBanner), not a per-job error.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../engine/engine_client.dart';
import '../library/library_store.dart';
import '../library/processing_manager.dart';
import '../ui/components/confirm_dialog.dart';
import '../ui/components/empty_state.dart';
import '../ui/components/job_queue_row.dart';
import '../ui/components/offline_banner.dart';
import '../ui/components/toast.dart';
import '../ui/duration_format.dart';
import '../ui/tokens.dart';

class QueuePage extends StatefulWidget {
  const QueuePage({super.key, required this.store, required this.manager});

  final LibraryStore store;
  final ProcessingManager manager;

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  Timer? _ticker;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onChange);
    // Tick once a second so elapsed time / ETA advance smoothly between the
    // manager's 2s status polls (only repaints while something is running).
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.manager.jobs.any((j) => j.state == 'running')) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.manager.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  String _titleFor(EngineJob j) {
    final match = widget.store.entries
        .where((e) => e.path == j.path)
        .map((e) => e.displayTitle);
    if (match.isNotEmpty) return match.first;
    return p.basenameWithoutExtension(j.path);
  }

  String _detailFor(EngineJob j) {
    return '${_languageName(j.target)} · ${_strategyName(j.strategy)}';
  }

  String _queueLabel(int index, int total) {
    if (total <= 1) return 'Next in line';
    return '#${index + 1} of $total queued';
  }

  Future<void> _retryFailed(List<EngineJob> failed) async {
    if (failed.isEmpty || _busy) return;
    if (!widget.manager.engineOnline) {
      showToast(
        context,
        'Engine offline — retry is paused until it reconnects.',
        variant: ToastVariant.attention,
      );
      return;
    }

    setState(() => _busy = true);
    try {
      for (final j in failed) {
        await widget.manager.retry(j.path);
      }
      if (mounted) {
        showToast(
          context,
          failed.length == 1
              ? 'Retrying failed job.'
              : 'Retrying ${failed.length} failed jobs.',
          variant: ToastVariant.success,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _moveNext(EngineJob job) async {
    if (_busy) return;
    if (!widget.manager.engineOnline) {
      showToast(
        context,
        'Engine offline — can\'t reprioritize now.',
        variant: ToastVariant.attention,
      );
      return;
    }

    setState(() => _busy = true);
    try {
      await widget.manager.prioritize([job.path]);
      if (mounted) {
        showToast(
          context,
          'Moved to the front of the queue.',
          variant: ToastVariant.success,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearQueue(List<EngineJob> jobs) async {
    if (jobs.isEmpty || _busy) return;
    final active = jobs.where((j) => j.isActive).length;

    if (active > 0) {
      final ok = await showConfirmDialog(
        context,
        title: 'Clear queue?',
        message:
            'This clears tracked queued, failed, and completed jobs from the '
            'queue view. A job already running on the engine may still finish '
            'in the background.',
        confirmLabel: 'Clear queue',
        destructive: true,
      );
      if (!(ok ?? false)) return;
    }

    setState(() => _busy = true);
    try {
      await widget.manager.clearQueue();
      if (mounted) showToast(context, 'Queue cleared.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteHistory(EngineJob job) async {
    if (_busy) return;
    if (!widget.manager.engineOnline) {
      showToast(
        context,
        'Engine offline — can\'t update history now.',
        variant: ToastVariant.attention,
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final ok = await widget.manager.deleteHistoryJob(job);
      if (mounted) {
        showToast(
          context,
          ok ? 'Removed from history.' : 'History item could not be removed.',
          variant: ok ? ToastVariant.info : ToastVariant.attention,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final jobs = widget.manager.jobs;
    final running = jobs.where((j) => j.state == 'running').toList();
    final queued = jobs.where((j) => j.state == 'queued').toList();
    final active = [...running, ...queued];
    final failed = jobs.where((j) => j.state == 'failed').toList();
    final done = jobs.where((j) => j.state == 'done').toList();

    return Scaffold(
      backgroundColor: AppColors.neutral950,
      body: Column(
        children: [
          _header(
            jobs: jobs,
            running: running.length,
            queued: queued.length,
            failed: failed.length,
            done: done.length,
            onRetryFailed: failed.isEmpty ? null : () => _retryFailed(failed),
          ),
          const Divider(height: 1, color: AppColors.hairline),
          if (!widget.manager.engineOnline)
            OfflineBanner(
              message:
                  'Engine offline — the queue is paused until it reconnects.',
              onAction: () => widget.manager.reconnect(),
            ),
          Expanded(
            child: jobs.isEmpty
                ? const EmptyState(
                    icon: Icons.playlist_play,
                    title: 'Nothing in the queue.',
                    message:
                        'New titles are translated automatically as you add them.',
                  )
                : ListView(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      AppSpacing.x6,
                      AppSpacing.x5,
                      AppSpacing.x6,
                      AppSpacing.x12,
                    ),
                    children: [
                      if (active.isNotEmpty)
                        _group(
                          'Active',
                          active,
                          queued: queued,
                          retryable: false,
                        ),
                      if (failed.isNotEmpty)
                        _group(
                          'Failed',
                          failed,
                          queued: queued,
                          retryable: true,
                          trailing: TextButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _retryFailed(failed),
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Retry all'),
                          ),
                        ),
                      if (done.isNotEmpty)
                        _group(
                          'Recently finished',
                          done,
                          queued: queued,
                          retryable: false,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _header({
    required List<EngineJob> jobs,
    required int running,
    required int queued,
    required int failed,
    required int done,
    required VoidCallback? onRetryFailed,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        final actions = Wrap(
          spacing: AppSpacing.x2,
          runSpacing: AppSpacing.x2,
          alignment: narrow ? WrapAlignment.start : WrapAlignment.end,
          children: [
            if (failed > 0)
              OutlinedButton.icon(
                onPressed: _busy ? null : onRetryFailed,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry failed'),
              ),
            OutlinedButton.icon(
              onPressed: jobs.isEmpty || _busy ? null : () => _clearQueue(jobs),
              icon: const Icon(Icons.clear_all, size: 18),
              label: const Text('Clear queue'),
            ),
          ],
        );

        return Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            AppSpacing.x6,
            AppSpacing.x12,
            AppSpacing.x6,
            AppSpacing.x5,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (narrow)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _titleBlock(jobs.length),
                    const SizedBox(height: AppSpacing.x4),
                    actions,
                  ],
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _titleBlock(jobs.length)),
                    const SizedBox(width: AppSpacing.x6),
                    actions,
                  ],
                ),
              const SizedBox(height: AppSpacing.x5),
              Wrap(
                spacing: AppSpacing.x3,
                runSpacing: AppSpacing.x3,
                children: [
                  _SummaryTile(
                    icon: Icons.autorenew,
                    label: 'Running',
                    value: '$running',
                    style: StatusStyles.running,
                  ),
                  _SummaryTile(
                    icon: Icons.schedule,
                    label: 'Queued',
                    value: '$queued',
                    style: StatusStyles.queued,
                  ),
                  _SummaryTile(
                    icon: Icons.error_outline,
                    label: 'Failed',
                    value: '$failed',
                    style: StatusStyles.failed,
                  ),
                  _SummaryTile(
                    icon: Icons.check_circle_outline,
                    label: 'Done',
                    value: '$done',
                    style: StatusStyles.ready,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _titleBlock(int total) {
    final health = widget.manager.engineOnline
        ? 'Engine online'
        : 'Engine offline';
    final count = total == 1 ? '1 tracked job' : '$total tracked jobs';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Queue', style: AppType.titleLg),
        const SizedBox(height: AppSpacing.x1),
        Text(
          '$count · $health',
          style: AppType.body.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _group(
    String label,
    List<EngineJob> jobs, {
    required List<EngineJob> queued,
    required bool retryable,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: AppSpacing.x5),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.neutral900,
          border: Border.all(color: AppColors.hairline),
          borderRadius: const BorderRadius.all(AppRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpacing.x4,
                AppSpacing.x3,
                AppSpacing.x3,
                AppSpacing.x2,
              ),
              child: Row(
                children: [
                  Text(
                    label.toUpperCase(),
                    style: AppType.label.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Text(
                    '${jobs.length}',
                    style: AppType.label.copyWith(color: AppColors.neutral500),
                  ),
                  const Spacer(),
                  ?trailing,
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.hairline),
            for (var i = 0; i < jobs.length; i++) ...[
              _rowFor(jobs[i], queued: queued, retryable: retryable),
              if (i != jobs.length - 1)
                const Divider(
                  height: 1,
                  color: AppColors.hairline,
                  indent: AppSpacing.x4,
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rowFor(
    EngineJob job, {
    required List<EngineJob> queued,
    required bool retryable,
  }) {
    final timing = widget.manager.timingFor(job.path);
    final queuedIndex = queued.indexWhere((j) => j.path == job.path);
    final startedAt = job.startedAtUtc?.toLocal();
    final endedAt = job.endedAtUtc?.toLocal();
    final duration = job.finishedDuration ?? timing?.elapsed;
    final rating = job.rating;

    return JobQueueRow(
      title: _titleFor(job),
      style: StatusStyles.forState(job.state),
      stage: job.stage,
      progress: job.state == 'running' ? job.progress : null,
      detailLabel: _detailFor(job),
      queueLabel: queuedIndex >= 0
          ? _queueLabel(queuedIndex, queued.length)
          : null,
      queuedAtLabel: fmtLocalJobTime(job.queuedAtUtc.toLocal()),
      startedAtLabel: startedAt == null ? null : fmtLocalJobTime(startedAt),
      endedAtLabel: endedAt == null ? null : fmtLocalJobTime(endedAt),
      durationLabel: duration == null ? null : fmtElapsed(duration),
      ratingScore: rating?.score,
      ratingLabel: rating?.label,
      ratingSummary: rating?.summary,
      error: job.error,
      elapsed: timing?.elapsed,
      eta: timing?.eta,
      onRetry: retryable ? () => _retryFailed([job]) : null,
      onMoveNext: job.state == 'queued' && queuedIndex > 0
          ? () => _moveNext(job)
          : null,
      onDeleteHistory: (job.state == 'done' || job.state == 'failed')
          ? () => _deleteHistory(job)
          : null,
    );
  }

  String _languageName(String code) => switch (code) {
    'he' => 'Hebrew',
    'ar' => 'Arabic',
    'es' => 'Spanish',
    'fr' => 'French',
    'de' => 'German',
    _ => code,
  };

  String _strategyName(String strategy) => switch (strategy) {
    'quality' => 'Quality',
    'fast' => 'Fast',
    'progressive' => 'Progressive',
    _ => strategy,
  };
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.style,
  });

  final IconData icon;
  final String label;
  final String value;
  final StatusStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 156,
      padding: const EdgeInsets.all(AppSpacing.x3),
      decoration: BoxDecoration(
        color: AppColors.neutral900,
        border: Border.all(color: AppColors.hairline),
        borderRadius: const BorderRadius.all(AppRadius.md),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: style.tint,
              borderRadius: const BorderRadius.all(AppRadius.sm),
            ),
            child: Icon(icon, size: 18, color: style.fg),
          ),
          const SizedBox(width: AppSpacing.x3),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: AppType.subtitle),
              Text(
                label,
                style: AppType.bodySm.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
