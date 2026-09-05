// SettingsRow + section scaffolding (docs/design/COMPONENTS.md §SettingsRow).
//
// One preference: [label + helper caption] ……… [control]. Settings is plain,
// scannable, grouped under section headers (principle P4 — calm, not surveillance).

import 'package:flutter/material.dart';

import '../tokens.dart';

class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(
              bottom: AppSpacing.x2, top: AppSpacing.x6),
          child: Text(title,
              style: AppType.label.copyWith(color: AppColors.textSecondary)),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.neutral900,
            borderRadius: const BorderRadius.all(AppRadius.lg),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: AppColors.hairline),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    this.caption,
    this.control,
  });

  final String label;
  final String? caption;
  final Widget? control;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppType.body),
                if (caption != null) ...[
                  const SizedBox(height: AppSpacing.x0_5),
                  Text(caption!,
                      style: AppType.bodySm
                          .copyWith(color: AppColors.textSecondary)),
                ],
              ],
            ),
          ),
          if (control != null) ...[
            const SizedBox(width: AppSpacing.x4),
            control!,
          ],
        ],
      ),
    );
  }
}

/// A small segmented control for settings (UI text size, quality tier).
class SettingsSegmented<T> extends StatelessWidget {
  const SettingsSegmented({
    super.key,
    required this.value,
    required this.items,
    required this.labelOf,
    required this.onChanged,
  });

  final T value;
  final List<T> items;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.neutral800,
        borderRadius: const BorderRadius.all(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final i in items)
            InkWell(
              onTap: () => onChanged(i),
              borderRadius: const BorderRadius.all(AppRadius.sm),
              child: Container(
                padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: AppSpacing.x3, vertical: AppSpacing.x1),
                decoration: BoxDecoration(
                  color: i == value ? AppColors.amber : Colors.transparent,
                  borderRadius: const BorderRadius.all(AppRadius.sm),
                ),
                child: Text(
                  labelOf(i),
                  style: AppType.label.copyWith(
                    color: i == value
                        ? AppColors.onAmber
                        : AppColors.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
