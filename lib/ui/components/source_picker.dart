// SourcePicker (docs/design/COMPONENTS.md §SourcePicker).
//
// The "smart default + override" subtitle-source choice. A radio group of option
// cards; the recommended one is pre-selected with a "Recommended" tag. Each option
// states its speed/quality tradeoff in one phrase. Options that don't apply are
// DISABLED WITH A REASON, not hidden — so the user understands why ASR is default.

import 'package:flutter/material.dart';

import '../tokens.dart';

class SourceOption<T> {
  const SourceOption({
    required this.value,
    required this.title,
    required this.tradeoff,
    this.detail,
    this.recommended = false,
    this.enabled = true,
    this.disabledReason,
  });

  final T value;
  final String title;
  final String tradeoff;
  final String? detail;
  final bool recommended;
  final bool enabled;
  final String? disabledReason;
}

class SourcePicker<T> extends StatelessWidget {
  const SourcePicker({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<SourceOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final o in options) ...[
          _OptionCard<T>(
            option: o,
            selected: o.value == selected,
            onTap: o.enabled ? () => onChanged(o.value) : null,
          ),
          if (o != options.last) const SizedBox(height: AppSpacing.x2),
        ],
      ],
    );
  }
}

class _OptionCard<T> extends StatelessWidget {
  const _OptionCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final SourceOption<T> option;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = !option.enabled;
    final fg = disabled ? AppColors.textDisabled : AppColors.textPrimary;

    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: option.enabled,
      label:
          '${option.title}. ${option.tradeoff}.${option.recommended ? ' Recommended.' : ''}',
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.x3),
          decoration: BoxDecoration(
            color: selected ? AppColors.amberSubtle : AppColors.neutral900,
            borderRadius: const BorderRadius.all(AppRadius.md),
            border: Border.all(
              color: selected ? AppColors.amber : AppColors.hairline,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: selected
                    ? AppColors.amber
                    : (disabled ? AppColors.neutral500 : AppColors.neutral300),
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(option.title,
                              style: AppType.body.copyWith(
                                  color: fg, fontWeight: FontWeight.w500)),
                        ),
                        if (option.detail != null) ...[
                          const SizedBox(width: AppSpacing.x2),
                          _Pill(option.detail!),
                        ],
                        if (option.recommended) ...[
                          const SizedBox(width: AppSpacing.x2),
                          const _Pill('Recommended', accent: true),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.x0_5),
                    Text(
                      disabled
                          ? (option.disabledReason ?? option.tradeoff)
                          : option.tradeoff,
                      style: AppType.bodySm
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.accent = false});
  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.symmetric(
          horizontal: AppSpacing.x2, vertical: 1),
      decoration: BoxDecoration(
        color: accent ? AppColors.amberSubtle : AppColors.neutral800,
        borderRadius: const BorderRadius.all(AppRadius.sm),
      ),
      child: Text(
        text,
        style: AppType.label.copyWith(
            color: accent ? AppColors.amber : AppColors.textSecondary),
      ),
    );
  }
}
