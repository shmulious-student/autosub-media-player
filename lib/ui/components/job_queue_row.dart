// JobQueueRow (docs/design/COMPONENTS.md §JobQueueRow).
//
// One job in the Processing/Queue view: stage, live progress, and the controls
// the engine supports today (retry on failure; move queued jobs to the front;
// bulk clear lives on the page). The progress segment is pinned LTR (RTL.md §2).
// Pause/resume endpoints don't exist yet — omitted rather than faked.

import 'package:flutter/material.dart';

import '../bidi.dart';
import '../duration_format.dart';
import '../tokens.dart';
import 'progress.dart';
import 'status_chip.dart';

class JobQueueRow extends StatelessWidget {
  const JobQueueRow({
    super.key,
    required this.title,
    required this.style,
    this.stage,
    this.progress,
    this.detailLabel,
    this.queueLabel,
    this.queuedAtLabel,
    this.startedAtLabel,
    this.endedAtLabel,
    this.durationLabel,
    this.ratingScore,
    this.ratingLabel,
    this.ratingSummary,
    this.error,
    this.elapsed,
    this.eta,
    this.onCancel,
    this.onPause,
    this.onResume,
    this.onRedo,
    this.onRetry,
    this.onMoveNext,
    this.onDeleteHistory,
    this.onOpenDetails,
  });

  final String title;
  final StatusStyle style;

  /// Current pipeline stage name (SPEC §4: Scan…Sync).
  final String? stage;
  final double? progress;

  /// Sub-label, e.g. "he · v3" (target lang · bible version).
  final String? detailLabel;
  final String? queueLabel;
  final String? queuedAtLabel;
  final String? startedAtLabel;
  final String? endedAtLabel;
  final String? durationLabel;
  final int? ratingScore;
  final String? ratingLabel;
  final String? ratingSummary;
  final String? error;

  /// Live timing for a running job (elapsed so far; ETA when estimable).
  final Duration? elapsed;
  final Duration? eta;

  final VoidCallback? onCancel;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onRedo;
  final VoidCallback? onRetry;
  final VoidCallback? onMoveNext;
  final VoidCallback? onDeleteHistory;
  final VoidCallback? onOpenDetails;

  bool get _running => style == StatusStyles.running;
  bool get _paused => style == StatusStyles.paused;
  bool get _failed => style == StatusStyles.failed;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 620;
        final content = compact ? _compactContent() : _wideContent();

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onOpenDetails,
            child: Container(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: AppSpacing.x4,
                vertical: AppSpacing.x3,
              ),
              decoration: BoxDecoration(
                border: _failed
                    ? const BorderDirectional(
                        start: BorderSide(color: AppColors.failedFg, width: 3),
                      )
                    : null,
              ),
              child: content,
            ),
          ),
        );
      },
    );
  }

  Widget _wideContent() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _StateGlyph(style: style),
        const SizedBox(width: AppSpacing.x3),
        Expanded(child: _titleBlock()),
        const SizedBox(width: AppSpacing.x4),
        _statusOrProgress(width: 220, alignEnd: true),
        _actions(),
      ],
    );
  }

  Widget _compactContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StateGlyph(style: style),
            const SizedBox(width: AppSpacing.x3),
            Expanded(child: _titleBlock()),
            if ((!_running && !_paused) || progress == null) ...[
              const SizedBox(width: AppSpacing.x2),
              StatusChip(style: style, size: StatusChipSize.sm),
            ],
          ],
        ),
        if ((_running || _paused) && progress != null) ...[
          const SizedBox(height: AppSpacing.x3),
          _statusOrProgress(width: double.infinity, alignEnd: false),
        ],
        _actions(compact: true),
      ],
    );
  }

  Widget _titleBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AutoDirText(
          title,
          style: AppType.subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpacing.x1),
        if (_failed && error != null)
          Text(
            error!,
            style: AppType.bodySm.copyWith(color: AppColors.failedFg),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          )
        else
          _metadataLine(),
        if (_historyLine() case final line?) ...[
          const SizedBox(height: AppSpacing.x1),
          line,
        ],
      ],
    );
  }

  Widget _metadataLine() {
    final parts = <String>[
      if (stage != null && stage!.isNotEmpty) _stageWord(stage!),
      if (detailLabel != null && detailLabel!.isNotEmpty) detailLabel!,
      if (queueLabel != null && queueLabel!.isNotEmpty) queueLabel!,
    ];

    if (parts.isEmpty) {
      return Text(
        style.spoken,
        style: AppType.bodySm.copyWith(color: AppColors.textSecondary),
      );
    }

    return Text(
      parts.join('  ·  '),
      style: AppType.bodySm.copyWith(color: AppColors.textSecondary),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget? _historyLine() {
    final timing = <String>[
      if (startedAtLabel != null) 'Started $startedAtLabel',
      if (startedAtLabel == null && queuedAtLabel != null)
        'Queued $queuedAtLabel',
      if (endedAtLabel != null) 'Ended $endedAtLabel',
      if (durationLabel != null) 'Took $durationLabel',
    ];
    if (timing.isEmpty && ratingScore == null) return null;

    return Wrap(
      spacing: AppSpacing.x2,
      runSpacing: AppSpacing.x1,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (timing.isNotEmpty)
          Text(
            timing.join('  ·  '),
            style: AppType.bodySm.copyWith(color: AppColors.neutral300),
          ),
        if (ratingScore != null)
          _RatingPill(
            score: ratingScore!,
            label: ratingLabel ?? 'Rated',
            summary: ratingSummary,
          ),
      ],
    );
  }

  Widget _statusOrProgress({required double width, required bool alignEnd}) {
    if ((!_running && !_paused) || progress == null) {
      return StatusChip(style: style, size: StatusChipSize.md);
    }

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: alignEnd
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppProgressBar(
            value: progress,
            label: '${(progress! * 100).round()}%',
          ),
          if (_running && elapsed != null) ...[
            const SizedBox(height: AppSpacing.x1),
            LtrIsland(
              child: Text(
                eta != null
                    ? '${fmtElapsed(elapsed!)} · ${fmtEta(eta!)}'
                    : '${fmtElapsed(elapsed!)} · estimating…',
                style: AppType.bodySm.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ] else if (_paused) ...[
            const SizedBox(height: AppSpacing.x1),
            Text(
              'Paused',
              style: AppType.bodySm.copyWith(color: AppColors.pausedFg),
            ),
          ],
        ],
      ),
    );
  }

  Widget _actions({bool compact = false}) {
    final children = <Widget>[
      if (onResume != null)
        Tooltip(
          message: 'Resume',
          child: IconButton(
            onPressed: onResume,
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
            color: AppColors.readyFg,
          ),
        ),
      if (onPause != null)
        Tooltip(
          message: 'Pause',
          child: IconButton(
            onPressed: onPause,
            icon: const Icon(Icons.pause_rounded, size: 20),
            color: AppColors.textSecondary,
          ),
        ),
      if (onMoveNext != null)
        Tooltip(
          message: 'Move to front',
          child: IconButton(
            onPressed: onMoveNext,
            icon: const Icon(Icons.vertical_align_top, size: 18),
            color: AppColors.textSecondary,
          ),
        ),
      if (_failed && onRetry != null)
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Retry'),
        ),
      if (onRedo != null)
        Tooltip(
          message: 'Redo from start',
          child: IconButton(
            onPressed: onRedo,
            icon: const Icon(Icons.restart_alt, size: 18),
            color: AppColors.textSecondary,
          ),
        ),
      if (onCancel != null)
        Tooltip(
          message: 'Cancel',
          child: IconButton(
            onPressed: onCancel,
            icon: const Icon(Icons.cancel_outlined, size: 18),
            color: AppColors.failedFg,
          ),
        ),
      if (onDeleteHistory != null)
        Tooltip(
          message: 'Delete from history',
          child: IconButton(
            onPressed: onDeleteHistory,
            icon: const Icon(Icons.delete_outline, size: 18),
            color: AppColors.textSecondary,
          ),
        ),
    ];

    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    if (compact) {
      return Padding(
        padding: const EdgeInsetsDirectional.only(
          start: 44,
          top: AppSpacing.x2,
        ),
        child: Wrap(
          spacing: AppSpacing.x2,
          runSpacing: AppSpacing.x1,
          children: children,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsetsDirectional.only(start: AppSpacing.x2),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  /// Title-case the engine's stage token for display.
  static String _stageWord(String stage) {
    if (stage.isEmpty) return '';
    return stage[0].toUpperCase() + stage.substring(1);
  }
}

class _StateGlyph extends StatelessWidget {
  const _StateGlyph({required this.style});

  final StatusStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: style.tint,
        borderRadius: const BorderRadius.all(AppRadius.sm),
      ),
      child: Icon(style.icon, size: 18, color: style.fg),
    );
  }
}

class _RatingPill extends StatelessWidget {
  const _RatingPill({
    required this.score,
    required this.label,
    required this.summary,
  });

  final int score;
  final String label;
  final String? summary;

  @override
  Widget build(BuildContext context) {
    final clamped = score.clamp(0, 100);
    final color = clamped >= 90
        ? AppColors.readyFg
        : clamped >= 75
        ? AppColors.attentionFg
        : clamped >= 55
        ? AppColors.confidenceLow
        : AppColors.failedFg;
    final text = '$label · $clamped';

    return Tooltip(
      message: summary == null || summary!.isEmpty ? text : summary!,
      child: Container(
        height: 22,
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: AppSpacing.x2,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: const BorderRadius.all(AppRadius.full),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 13, color: color),
            const SizedBox(width: AppSpacing.x1),
            Text(text, style: AppType.label.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}
