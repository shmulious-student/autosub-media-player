// EmptyState (docs/design/COMPONENTS.md §EmptyState).
//
// Calm, helpful zero-data states (library, queue, bible, search). The only place
// big illustrations appear. Centered glyph + title + one-line guidance + actions.

import 'package:flutter/material.dart';

import '../tokens.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String? message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppSpacing.contentMaxWidth),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.x8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 64, color: AppColors.neutral500),
              const SizedBox(height: AppSpacing.x4),
              Text(title,
                  style: AppType.titleLg, textAlign: TextAlign.center),
              if (message != null) ...[
                const SizedBox(height: AppSpacing.x2),
                Text(
                  message!,
                  style: AppType.body.copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.x6),
                Wrap(
                  spacing: AppSpacing.x3,
                  runSpacing: AppSpacing.x2,
                  alignment: WrapAlignment.center,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
