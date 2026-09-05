// StatusChip — the universal state badge (docs/design/COMPONENTS.md §StatusChip).
//
// The single most-reused component: a tinted pill with a saturated icon + label
// drawn from the status palette (DESIGN_SYSTEM §3.1). Every status carries an
// icon + text label, never color alone (a11y, DS §6.2). The `running` variant
// spins its icon (paused under reduced-motion → static icon + text).

import 'package:flutter/material.dart';

import '../bidi.dart';
import '../tokens.dart';

enum StatusChipSize { sm, md }

class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.style,
    this.label,
    this.progress,
    this.detail,
    this.size = StatusChipSize.sm,
    this.onTap,
  });

  /// Convenience: build from an engine/job wire-state string.
  factory StatusChip.forState(
    String state, {
    Key? key,
    String? label,
    double? progress,
    String? detail,
    StatusChipSize size = StatusChipSize.sm,
    VoidCallback? onTap,
  }) =>
      StatusChip(
        key: key,
        style: StatusStyles.forState(state),
        label: label,
        progress: progress,
        detail: detail,
        size: size,
        onTap: onTap,
      );

  final StatusStyle style;

  /// Overrides the status's default spoken word as the visible label.
  final String? label;

  /// 0..1 — when set on the `running` style, appends "· 62%".
  final double? progress;

  /// Extra trailing detail (e.g. stage name) appended after "·".
  final String? detail;

  final StatusChipSize size;
  final VoidCallback? onTap;

  bool get _isRunning => style == StatusStyles.running;

  String get _visibleLabel {
    final base = label ?? style.spoken;
    if (progress != null && _isRunning) {
      return '$base · ${(progress! * 100).round()}%';
    }
    if (detail != null && detail!.isNotEmpty) return '$base · $detail';
    return base;
  }

  String get _spoken {
    final parts = <String>[style.spoken];
    if (progress != null) parts.add('${(progress! * 100).round()} percent');
    if (detail != null && detail!.isNotEmpty) parts.add('stage $detail');
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final isMd = size == StatusChipSize.md;
    final height = isMd ? 28.0 : 20.0;
    final iconSize = isMd ? 16.0 : 14.0;
    final hPad = isMd ? AppSpacing.x3 : AppSpacing.x2;

    Widget icon = Icon(style.icon, size: iconSize, color: style.fg);
    if (_isRunning) {
      icon = _SpinningIcon(icon: style.icon, size: iconSize, color: style.fg);
    }

    final chip = Container(
      height: height,
      padding: EdgeInsetsDirectional.symmetric(horizontal: hPad),
      decoration: BoxDecoration(
        color: style.tint,
        borderRadius: const BorderRadius.all(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: AppSpacing.x1),
          // Label is chrome (status word + isolated numerals) → LTR island so
          // the percent never reorders inside a future RTL UI.
          LtrIsland(
            child: Text(
              _visibleLabel,
              style: AppType.label.copyWith(color: style.fg),
            ),
          ),
        ],
      ),
    );

    final semantic = Semantics(
      label: _spoken,
      container: true,
      button: onTap != null,
      child: chip,
    );

    if (onTap == null) return semantic;
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(AppRadius.full),
      child: semantic,
    );
  }
}

/// The `autorenew` spinner for the running state — 1 rev / 1.4s, frozen under
/// reduced motion (DESIGN_SYSTEM §3.6).
class _SpinningIcon extends StatefulWidget {
  const _SpinningIcon(
      {required this.icon, required this.size, required this.color});
  final IconData icon;
  final double size;
  final Color color;

  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeAnimate();
  }

  void _maybeAnimate() {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final iconWidget =
        Icon(widget.icon, size: widget.size, color: widget.color);
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return iconWidget;
    return RotationTransition(turns: _c, child: iconWidget);
  }
}
