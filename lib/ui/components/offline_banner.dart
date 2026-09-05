// OfflineBanner (docs/design/COMPONENTS.md §OfflineBanner).
//
// Engine-daemon-offline state: background translation is paused. This is
// *infrastructure* (amber/attention), not a per-job failure (red). Non-blocking —
// the library stays browsable/playable.

import 'package:flutter/material.dart';

import '../tokens.dart';

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({
    super.key,
    this.message =
        'Engine offline — background translation is paused.',
    this.actionLabel = 'Reconnect',
    this.onAction,
    this.reconnecting = false,
  });

  final String message;
  final String actionLabel;
  final VoidCallback? onAction;
  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.attentionTint,
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
            horizontal: AppSpacing.x4, vertical: AppSpacing.x3),
        child: Row(
          children: [
            const Icon(Icons.cloud_off,
                size: 18, color: AppColors.attentionFg),
            const SizedBox(width: AppSpacing.x2),
            Expanded(
              child: Text(message,
                  style: AppType.body.copyWith(color: AppColors.attentionFg)),
            ),
            if (onAction != null)
              TextButton(
                onPressed: reconnecting ? null : onAction,
                child: reconnecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(actionLabel),
              ),
          ],
        ),
      ),
    );
  }
}
