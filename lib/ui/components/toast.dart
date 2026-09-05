// Toast / Snackbar (docs/design/COMPONENTS.md §Toast).
//
// Transient, quiet, non-blocking confirmation (principle P3). Variants carry an
// icon + accent color; errors persist (no auto-dismiss) and carry an action.
// No success spam — only surface non-obvious outcomes.

import 'package:flutter/material.dart';

import '../tokens.dart';

enum ToastVariant { info, success, attention, error }

({Color fg, IconData icon}) _toastStyle(ToastVariant v) {
  switch (v) {
    case ToastVariant.info:
      return (fg: AppColors.neutral300, icon: Icons.info_outline);
    case ToastVariant.success:
      return (fg: AppColors.readyFg, icon: Icons.check_circle);
    case ToastVariant.attention:
      return (fg: AppColors.attentionFg, icon: Icons.warning_amber);
    case ToastVariant.error:
      return (fg: AppColors.failedFg, icon: Icons.error);
  }
}

/// Show a toast via the nearest [ScaffoldMessenger].
void showToast(
  BuildContext context,
  String message, {
  ToastVariant variant = ToastVariant.info,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final style = _toastStyle(variant);
  final isError = variant == ToastVariant.error;
  final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      backgroundColor: AppColors.neutral850,
      behavior: SnackBarBehavior.floating,
      duration:
          isError ? const Duration(days: 1) : const Duration(milliseconds: 4000),
      content: Row(
        children: [
          Icon(style.icon, size: 18, color: style.fg),
          const SizedBox(width: AppSpacing.x2),
          Expanded(child: Text(message, style: AppType.body)),
        ],
      ),
      action: (actionLabel != null)
          ? SnackBarAction(
              label: actionLabel,
              textColor: AppColors.amber,
              onPressed: onAction ?? () {},
            )
          : (isError
              ? SnackBarAction(
                  label: 'Dismiss',
                  textColor: AppColors.neutral300,
                  onPressed: () => messenger.hideCurrentSnackBar(),
                )
              : null),
    ),
  );
}
