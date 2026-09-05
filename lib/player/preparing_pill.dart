// PreparingPill — the one piece of chrome that tells the viewer subtitles are on
// their way, without ever getting between them and the picture.
//
// The rule it follows (UX review, "play immediately"): a long operation may not
// block playback, and it may not be silent either. So preparation state lives in a
// small pill over the top-left of the video — visible, ignorable, and gone the
// moment the subtitles are complete.

import 'package:flutter/material.dart';

import '../ui/duration_format.dart';
import '../ui/tokens.dart';
import 'subtitle_runway.dart';

class PreparingPill extends StatelessWidget {
  const PreparingPill({super.key, required this.runway, this.onRetry});

  final SubtitleRunway runway;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final phase = runway.phase;
    // Complete subtitles need no announcement — the pill disappears entirely.
    if (phase == RunwayPhase.ready) return const SizedBox.shrink();

    final (icon, color, text) = _content(phase);
    if (text == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.x3,
        vertical: AppSpacing.x2,
      ),
      decoration: BoxDecoration(
        color: AppColors.neutral950.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: AppSpacing.x2),
          Text(text, style: AppType.bodySm.copyWith(color: AppColors.textPrimary)),
          if (phase == RunwayPhase.attention && onRetry != null) ...[
            const SizedBox(width: AppSpacing.x2),
            GestureDetector(
              onTap: onRetry,
              child: Text(
                'Retry',
                style: AppType.bodySm.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Icon, accent colour and the sentence to show — or a null sentence when there
  /// is nothing worth saying.
  (IconData, Color, String?) _content(RunwayPhase phase) {
    switch (phase) {
      case RunwayPhase.ready:
        return (Icons.check_circle, AppColors.readyFg, null);

      case RunwayPhase.partial:
        // Something is watchable already. Say how far it reaches, so the viewer
        // knows whether to keep going or wait.
        final ready = runway.readyThrough;
        final detail = ready == null
            ? 'Subtitles ready'
            : 'Subtitles ready to ${fmtElapsed(ready)}';
        return (Icons.subtitles, AppColors.readyFg, '$detail · still preparing');

      case RunwayPhase.preparing:
        return (Icons.autorenew, AppColors.runningFg, _preparingText());

      case RunwayPhase.queued:
        return (Icons.schedule, AppColors.runningFg, 'Subtitles queued');

      case RunwayPhase.attention:
        return (
          Icons.error_outline,
          AppColors.attentionFg,
          'Subtitles unavailable',
        );

      case RunwayPhase.none:
        return (Icons.subtitles_off, AppColors.textSecondary, 'No subtitles yet');
    }
  }

  String _preparingText() {
    final buf = StringBuffer('Preparing subtitles');
    final progress = runway.progress;
    if (progress != null && progress > 0) {
      buf.write(' · ${(progress * 100).round()}%');
    }
    final eta = runway.eta;
    if (eta != null) buf.write(' · ${fmtEta(eta)}');
    return buf.toString();
  }
}
