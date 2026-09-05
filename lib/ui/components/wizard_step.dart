// WizardStep (docs/design/COMPONENTS.md §WizardStep).
//
// One step of first-run setup: a centered ≤720px column with a step indicator,
// display headline, explanatory body, the step body, and primary/secondary
// actions. Calm, lots of space (SCREENS §1).

import 'package:flutter/material.dart';

import '../tokens.dart';

class WizardStep extends StatelessWidget {
  const WizardStep({
    super.key,
    required this.stepIndex,
    required this.stepCount,
    required this.headline,
    required this.child,
    this.body,
    this.actions = const [],
  });

  final int stepIndex; // 0-based
  final int stepCount;
  final String headline;
  final String? body;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppSpacing.contentMaxWidth),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.x12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _Dots(count: stepCount, active: stepIndex),
              const SizedBox(height: AppSpacing.x8),
              Text(headline, style: AppType.display, textAlign: TextAlign.center),
              if (body != null) ...[
                const SizedBox(height: AppSpacing.x4),
                Text(
                  body!,
                  style: AppType.body.copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: AppSpacing.x8),
              child,
              if (actions.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.x8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: AppSpacing.x3),
                      actions[i],
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.active});
  final int count;
  final int active;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: AppSpacing.x1),
            width: i == active ? 24 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == active ? AppColors.amber : AppColors.neutral700,
              borderRadius: const BorderRadius.all(AppRadius.full),
            ),
          ),
      ],
    );
  }
}
