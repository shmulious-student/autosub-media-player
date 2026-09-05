// ProgressBar / ProgressRing (docs/design/COMPONENTS.md §ProgressBar).
//
// Determinate job/download progress; indeterminate only before the first event.
// ALWAYS LTR-pinned (RTL.md §2) — fill grows left→right = "more done", even on a
// Hebrew UI. Job fills use status/running blue; downloads use accent amber.

import 'package:flutter/material.dart';

import '../bidi.dart';
import '../tokens.dart';

class AppProgressBar extends StatelessWidget {
  const AppProgressBar({
    super.key,
    required this.value,
    this.height = 6,
    this.fillColor = AppColors.runningFg,
    this.trackColor = AppColors.neutral800,
    this.label,
  });

  /// 0..1, or null for indeterminate (pre-first-event).
  final double? value;
  final double height;
  final Color fillColor;
  final Color trackColor;

  /// Optional trailing `mono-time` label, e.g. "62%".
  final String? label;

  @override
  Widget build(BuildContext context) {
    final bar = LtrIsland(
      child: ClipRRect(
        borderRadius: const BorderRadius.all(AppRadius.full),
        child: TweenAnimationBuilder<double>(
          duration: AppMotion.resolve(context, AppMotion.fast),
          curve: AppMotion.curveOut,
          tween: Tween(begin: 0, end: value ?? 0),
          builder: (context, animated, _) => LinearProgressIndicator(
            value: value == null ? null : animated,
            minHeight: height,
            backgroundColor: trackColor,
            valueColor: AlwaysStoppedAnimation(fillColor),
          ),
        ),
      ),
    );

    final semantics = Semantics(
      value: value == null ? null : '${(value! * 100).round()}%',
      child: bar,
    );

    if (label == null) return semantics;
    return Row(
      children: [
        Expanded(child: semantics),
        const SizedBox(width: AppSpacing.x2),
        LtrIsland(
          child: Text(label!,
              style: AppType.monoTime.copyWith(color: AppColors.textSecondary)),
        ),
      ],
    );
  }
}

/// Compact ring for card corners / Now Playing (COMPONENTS §ProgressBar).
class AppProgressRing extends StatelessWidget {
  const AppProgressRing({
    super.key,
    required this.value,
    this.size = 24,
    this.strokeWidth = 3,
    this.color = AppColors.runningFg,
  });

  final double? value;
  final double size;
  final double strokeWidth;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Semantics(
        value: value == null ? null : '${(value! * 100).round()}%',
        child: CircularProgressIndicator(
          value: value,
          strokeWidth: strokeWidth,
          backgroundColor: AppColors.neutral800,
          valueColor: AlwaysStoppedAnimation(color),
        ),
      ),
    );
  }
}
