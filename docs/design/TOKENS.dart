// AutoSub Media Player — Design Tokens (ready to paste).
//
// Source of truth: docs/DESIGN_SYSTEM.md §3. This file is the Dart realization of
// those tokens so engineering wires the theme without re-deriving values.
//
// Usage:
//   MaterialApp(theme: appTheme(), darkTheme: appTheme(), themeMode: ThemeMode.dark, …)
// Then reference AppColors.* / AppSpacing.* / AppRadius.* / AppMotion.* in widgets.
// NEVER hardcode a hex/size/duration in a widget — add or reuse a token here.
//
// This REPLACES the current `ColorScheme.fromSeed(seedColor: Colors.indigo)` in
// lib/main.dart. The system is dark-only for v1 (DESIGN_SYSTEM §2 light-mode stance);
// the semantic layer makes a future light theme a token swap, not a refactor.
//
// Suggested home: lib/ui/tokens.dart (+ lib/ui/bidi.dart for the RTL helpers in
// docs/design/RTL.md §6).

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Color — raw ramp (defines roles; do not reference ramps directly in widgets,
// use the semantic roles below).
// ---------------------------------------------------------------------------

abstract final class AppColors {
  // Neutral ramp (cool graphite).
  static const neutral950 = Color(0xFF0B0D10); // app background ("the room")
  static const neutral900 = Color(0xFF111418); // surface / cards at rest
  static const neutral850 = Color(0xFF171B20); // raised: panels, sheets, menus
  static const neutral800 = Color(0xFF1E232A); // hover surface / input fields
  static const neutral700 = Color(0xFF2A313A); // hairline dividers / borders (~60% α)
  static const neutral500 = Color(0xFF5A6573); // disabled text, tertiary icons
  static const neutral300 = Color(0xFF9AA4B2); // secondary text, metadata
  static const neutral100 = Color(0xFFD7DCE3); // primary text (softer than white)
  static const neutral0 = Color(0xFFF4F6F9); // high-emphasis text, active labels

  // Brand / accent (warm amber over cool base).
  static const amber = Color(0xFFE8A33D); // primary, active selection, focus
  static const amberHover = Color(0xFFF2B45A);
  static const amberPress = Color(0xFFCE8C29);
  static const amberSubtle = Color(0xFF3A2E18); // tinted fill (selected row bg)
  static const onAmber = Color(0xFF1A1205); // text/icon on an amber fill

  // Semantic status — foreground / tint-fill pairs (DESIGN_SYSTEM §3.1).
  static const readyFg = Color(0xFF4ADE80);
  static const readyTint = Color(0xFF10231A);
  static const runningFg = Color(0xFF5BB8F5);
  static const runningTint = Color(0xFF0E2030);
  static const queuedFg = Color(0xFFC9D1DA);
  static const queuedTint = Color(0xFF1A1F26);
  static const pausedFg = Color(0xFFA6B0BD);
  static const pausedTint = Color(0xFF181C22);
  static const failedFg = Color(0xFFFF6B6B);
  static const failedTint = Color(0xFF2A1416);
  static const attentionFg = Color(0xFFF2B45A);
  static const attentionTint = Color(0xFF2A2010);

  // AI confidence (low is ORANGE, not red — a guess to review isn't a failure).
  static const confidenceHigh = Color(0xFF4ADE80); // ≥0.85 "Confident"
  static const confidenceMed = Color(0xFFF2B45A); // 0.6–0.85 "Worth a check"
  static const confidenceLow = Color(0xFFFF8A5B); // <0.6 "Please review"

  // Functional.
  static const focusRing = Color(0xFFF2B45A);
  static const scrim = Color(0x99000000); // 60% black (dialogs)

  // Text roles.
  static const textPrimary = neutral100;
  static const textSecondary = neutral300;
  static const textDisabled = neutral500;
  static const textHighEmphasis = neutral0;
}

/// A status's (foreground, tint) pair + spoken word — for StatusChip / chips.
class StatusStyle {
  const StatusStyle(this.fg, this.tint, this.spoken);
  final Color fg;
  final Color tint;
  final String spoken;
}

/// Map JobState / title-status keys to their style. Keep keys in lockstep with
/// JobState (lib/data/models.dart) + the synthetic 'ready'/'attention' states.
abstract final class StatusStyles {
  static const ready = StatusStyle(AppColors.readyFg, AppColors.readyTint, 'Ready');
  static const running = StatusStyle(AppColors.runningFg, AppColors.runningTint, 'Translating');
  static const queued = StatusStyle(AppColors.queuedFg, AppColors.queuedTint, 'Queued');
  static const paused = StatusStyle(AppColors.pausedFg, AppColors.pausedTint, 'Paused');
  static const failed = StatusStyle(AppColors.failedFg, AppColors.failedTint, 'Failed');
  static const attention = StatusStyle(AppColors.attentionFg, AppColors.attentionTint, 'Needs attention');
}

// ---------------------------------------------------------------------------
// Spacing (4pt base) · Radii · Elevation
// ---------------------------------------------------------------------------

abstract final class AppSpacing {
  static const double x0_5 = 2;
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16; // default gutter / card padding
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x12 = 48;

  /// Library grid: poster max cross-axis extent (reflows responsively).
  static const double posterMaxExtent = 200;
  static const double posterGap = 24;

  /// Desktop readable content column cap (detail/settings/wizard).
  static const double contentMaxWidth = 720;
}

abstract final class AppRadius {
  static const sm = Radius.circular(6); // chips, badges, inputs
  static const md = Radius.circular(10); // buttons, list rows, small cards
  static const lg = Radius.circular(14); // poster cards, panels, sheets
  static const xl = Radius.circular(20); // dialogs, restyle overlay
  static const full = Radius.circular(999);

  static const borderSm = BorderRadius.all(sm);
  static const borderMd = BorderRadius.all(md);
  static const borderLg = BorderRadius.all(lg);
  static const borderXl = BorderRadius.all(xl);
}

abstract final class AppElevation {
  // Dark UI: surface lightness + soft shadow (DESIGN_SYSTEM §3.5).
  static const List<BoxShadow> e1 = [
    BoxShadow(color: Color(0x4D000000), blurRadius: 3, offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> e2 = [
    BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 6)),
  ];
  static const List<BoxShadow> e3 = [
    BoxShadow(color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 12)),
  ];
}

// ---------------------------------------------------------------------------
// Motion (halve / disable under MediaQuery.disableAnimations — DESIGN_SYSTEM §3.6/§6.6)
// ---------------------------------------------------------------------------

abstract final class AppMotion {
  static const instant = Duration(milliseconds: 80);
  static const fast = Duration(milliseconds: 140);
  static const base = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 320);

  static const curveOut = Curves.easeOutCubic;
  static const curveInOut = Curves.easeInOutCubic;

  /// Resolve a duration honoring reduced-motion.
  static Duration resolve(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false
          ? Duration.zero
          : d;
}

// ---------------------------------------------------------------------------
// Typography — Inter (Latin/UI) + Noto Sans Hebrew (RTL fallback).
// Bundle both via pubspec `fonts:` (or google_fonts). Noto is set as fallback so
// Hebrew glyphs resolve inside mixed strings (DESIGN_SYSTEM §3.2 / RTL.md).
// ---------------------------------------------------------------------------

abstract final class AppType {
  static const String latin = 'Inter';
  static const List<String> fallback = ['Noto Sans Hebrew'];

  static const _tnum = [FontFeature.tabularFigures()];

  static const TextStyle display = TextStyle(
      fontFamily: latin, fontFamilyFallback: fallback, fontSize: 32, height: 40 / 32, fontWeight: FontWeight.w600);
  static const TextStyle titleLg = TextStyle(
      fontFamily: latin, fontFamilyFallback: fallback, fontSize: 24, height: 32 / 24, fontWeight: FontWeight.w600);
  static const TextStyle title = TextStyle(
      fontFamily: latin, fontFamilyFallback: fallback, fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w600);
  static const TextStyle subtitle = TextStyle(
      fontFamily: latin, fontFamilyFallback: fallback, fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w500);
  static const TextStyle body = TextStyle(
      fontFamily: latin, fontFamilyFallback: fallback, fontSize: 14, height: 22 / 14, fontWeight: FontWeight.w400);
  static const TextStyle bodySm = TextStyle(
      fontFamily: latin, fontFamilyFallback: fallback, fontSize: 13, height: 20 / 13, fontWeight: FontWeight.w400);
  static const TextStyle label = TextStyle(
      fontFamily: latin, fontFamilyFallback: fallback, fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w600, letterSpacing: 0.2);
  // Timecodes / CPS — tabular figures so digits don't shift.
  static const TextStyle monoTime = TextStyle(
      fontFamily: latin, fontFamilyFallback: fallback, fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500, fontFeatures: _tnum);
}

// ---------------------------------------------------------------------------
// ThemeData — the assembled dark theme. Wire into MaterialApp.
// ---------------------------------------------------------------------------

ThemeData appTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.amber,
    onPrimary: AppColors.onAmber,
    secondary: AppColors.amber,
    onSecondary: AppColors.onAmber,
    surface: AppColors.neutral900,
    onSurface: AppColors.textPrimary,
    error: AppColors.failedFg,
    onError: AppColors.onAmber,
    outline: AppColors.neutral700,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.neutral950,
    canvasColor: AppColors.neutral900,
    dividerColor: AppColors.neutral700.withValues(alpha: 0.6),
    splashFactory: InkSparkle.splashFactory,
    fontFamily: AppType.latin,
    fontFamilyFallback: AppType.fallback,
    textTheme: const TextTheme(
      displaySmall: AppType.display,
      headlineSmall: AppType.titleLg,
      titleLarge: AppType.title,
      titleMedium: AppType.subtitle,
      bodyMedium: AppType.body,
      bodySmall: AppType.bodySm,
      labelMedium: AppType.label,
    ).apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.amber,
        foregroundColor: AppColors.onAmber,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.borderMd),
      ),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.neutral900,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.borderLg),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.neutral850,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.borderXl),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.neutral800,
      border: const OutlineInputBorder(borderRadius: AppRadius.borderSm, borderSide: BorderSide.none),
      focusedBorder: const OutlineInputBorder(
        borderRadius: AppRadius.borderSm,
        borderSide: BorderSide(color: AppColors.focusRing, width: 2),
      ),
    ),
    focusColor: AppColors.focusRing,
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.neutral850,
      contentTextStyle: AppType.body,
      behavior: SnackBarBehavior.floating,
    ),
  );
}
