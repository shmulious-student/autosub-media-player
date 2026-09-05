// ConfidenceMeter (docs/design/COMPONENTS.md §ConfidenceMeter).
//
// Shows AI confidence for a bible proposal / TMDB match as a *band of trust* —
// never a bare number (principle P1). Low confidence is ORANGE, not red: a guess
// to review is collaboration, not a failure (DESIGN_SYSTEM §3.1).

import 'package:flutter/material.dart';

import '../bidi.dart';
import '../tokens.dart';

enum ConfidenceVariant { inline, bar, badge }

({Color color, String word}) confidenceBand(double v) {
  if (v >= 0.85) return (color: AppColors.confidenceHigh, word: 'Confident');
  if (v >= 0.6) return (color: AppColors.confidenceMed, word: 'Worth a check');
  return (color: AppColors.confidenceLow, word: 'Please review');
}

class ConfidenceMeter extends StatelessWidget {
  const ConfidenceMeter({
    super.key,
    required this.value,
    this.variant = ConfidenceVariant.inline,
  });

  /// 0..1.
  final double value;
  final ConfidenceVariant variant;

  @override
  Widget build(BuildContext context) {
    final band = confidenceBand(value);
    final pct = (value * 100).round();
    final semantics =
        'Confidence: ${band.word.toLowerCase()}, $pct percent';

    final wordPct = LtrIsland(
      child: Text.rich(
        TextSpan(children: [
          TextSpan(
              text: band.word,
              style: AppType.label.copyWith(color: band.color)),
          TextSpan(
              text: '  $pct%',
              style: AppType.monoTime.copyWith(color: AppColors.textSecondary)),
        ]),
      ),
    );

    switch (variant) {
      case ConfidenceVariant.badge:
        return Semantics(
          label: semantics,
          child: Text(band.word, style: AppType.label.copyWith(color: band.color)),
        );
      case ConfidenceVariant.inline:
        return Semantics(
          label: semantics,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: band.color, shape: BoxShape.circle),
            ),
            const SizedBox(width: AppSpacing.x2),
            wordPct,
          ]),
        );
      case ConfidenceVariant.bar:
        return Semantics(
          label: semantics,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              wordPct,
              const SizedBox(height: AppSpacing.x1),
              LtrIsland(
                child: SizedBox(
                  height: 6,
                  child: CustomPaint(
                    painter: _BandPainter(value),
                    size: const Size(double.infinity, 6),
                  ),
                ),
              ),
            ],
          ),
        );
    }
  }
}

/// A 3-zone (low/med/high) track with a marker at the value (LTR-pinned).
class _BandPainter extends CustomPainter {
  _BandPainter(this.value);
  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    final w = size.width;
    // Three zones: low [0,0.6) med [0.6,0.85) high [0.85,1].
    void zone(double a, double b, Color c) {
      final rect = Rect.fromLTWH(a * w, 0, (b - a) * w, size.height);
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, r), Paint()..color = c.withValues(alpha: 0.35));
    }

    zone(0, 0.6, AppColors.confidenceLow);
    zone(0.6, 0.85, AppColors.confidenceMed);
    zone(0.85, 1, AppColors.confidenceHigh);

    final markerX = (value.clamp(0.0, 1.0)) * w;
    canvas.drawCircle(
      Offset(markerX.clamp(size.height / 2, w - size.height / 2), size.height / 2),
      size.height / 2 + 1,
      Paint()..color = AppColors.neutral0,
    );
  }

  @override
  bool shouldRepaint(_BandPainter old) => old.value != value;
}
