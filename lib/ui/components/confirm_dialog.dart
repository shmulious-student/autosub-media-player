// ConfirmDialog (docs/design/COMPONENTS.md §ConfirmDialog).
//
// Consent for consequential/destructive actions. The re-queue variant is the most
// important dialog in the app (principle P1): it names the concrete consequence
// with numbers BEFORE the user commits. Focus is trapped; Esc cancels.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

/// A simple two-action confirm. Returns true on confirm, false/null on cancel.
Future<bool?> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: AppType.title),
      content: Text(message,
          style: AppType.body.copyWith(color: AppColors.textSecondary)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: AppColors.failedFg,
                  foregroundColor: AppColors.onAmber)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

/// The outcome of the bible re-queue consent dialog (COMPONENTS §ConfirmDialog).
enum RequeueChoice { retranslate, saveNameOnly, cancel }

/// The critical 3-action consent moment when a bible edit affects existing
/// subtitles (DESIGN_SYSTEM §7 — uses the spec copy near-verbatim).
Future<RequeueChoice> showRequeueDialog(
  BuildContext context, {
  required String characterName,
  required String changeDescription, // e.g. "gender to female"
  required int titleCount,
  required int lineCount,
}) async {
  final result = await showDialog<RequeueChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('This affects subtitles already made'),
      content: Text.rich(
        TextSpan(
          style: AppType.body.copyWith(color: AppColors.textSecondary),
          children: [
            const TextSpan(text: 'Changing '),
            TextSpan(
                text: characterName,
                style: AppType.body.copyWith(
                    color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
            TextSpan(text: "'s $changeDescription will re-translate "),
            TextSpan(
                text: '$titleCount titles, ~$lineCount lines',
                style: AppType.body.copyWith(
                    color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
            const TextSpan(text: '. Lines you edited yourself are kept.'),
          ],
        ),
      ),
      actionsOverflowButtonSpacing: AppSpacing.x2,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, RequeueChoice.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, RequeueChoice.saveNameOnly),
          child: const Text('Save name only'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, RequeueChoice.retranslate),
          child: const Text('Re-translate'),
        ),
      ],
    ),
  );
  return result ?? RequeueChoice.cancel;
}

/// Wraps dialog content so Esc cancels (focus-return is handled by Navigator).
class EscDismiss extends StatelessWidget {
  const EscDismiss({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
      },
      child: child,
    );
  }
}
