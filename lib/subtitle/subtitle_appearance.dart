import 'package:flutter/material.dart';

import '../ui/tokens.dart';

enum SubtitleTextColor { white, warm, amber, cyan }

extension SubtitleTextColorMeta on SubtitleTextColor {
  String get label => switch (this) {
    SubtitleTextColor.white => 'White',
    SubtitleTextColor.warm => 'Warm',
    SubtitleTextColor.amber => 'Amber',
    SubtitleTextColor.cyan => 'Cyan',
  };

  Color get color => switch (this) {
    SubtitleTextColor.white => Colors.white,
    SubtitleTextColor.warm => const Color(0xFFFFF1D2),
    SubtitleTextColor.amber => AppColors.amberHover,
    SubtitleTextColor.cyan => const Color(0xFFBDEFFF),
  };
}

enum SubtitleFontWeight { regular, semibold, bold }

extension SubtitleFontWeightMeta on SubtitleFontWeight {
  String get label => switch (this) {
    SubtitleFontWeight.regular => 'Regular',
    SubtitleFontWeight.semibold => 'Semi',
    SubtitleFontWeight.bold => 'Bold',
  };

  FontWeight get value => switch (this) {
    SubtitleFontWeight.regular => FontWeight.w500,
    SubtitleFontWeight.semibold => FontWeight.w600,
    SubtitleFontWeight.bold => FontWeight.w700,
  };
}

enum SubtitleFontFamily { appSans, system, arial, notoSansHebrew }

extension SubtitleFontFamilyMeta on SubtitleFontFamily {
  String get label => switch (this) {
    SubtitleFontFamily.appSans => 'App Sans',
    SubtitleFontFamily.system => 'System',
    SubtitleFontFamily.arial => 'Arial',
    SubtitleFontFamily.notoSansHebrew => 'Noto Hebrew',
  };

  String? get primary => switch (this) {
    SubtitleFontFamily.appSans => AppType.latin,
    SubtitleFontFamily.system => null,
    SubtitleFontFamily.arial => 'Arial',
    SubtitleFontFamily.notoSansHebrew => 'Noto Sans Hebrew',
  };

  List<String> get fallback => switch (this) {
    SubtitleFontFamily.appSans => [
      ...AppType.fallback,
      'Arial Hebrew',
      'Arial',
    ],
    SubtitleFontFamily.system => ['Arial Hebrew', 'Noto Sans Hebrew', 'Arial'],
    SubtitleFontFamily.arial => [
      'Arial Hebrew',
      'Noto Sans Hebrew',
      AppType.latin,
    ],
    SubtitleFontFamily.notoSansHebrew => [
      'Arial Hebrew',
      'Arial',
      AppType.latin,
    ],
  };
}

class SubtitleAppearance {
  const SubtitleAppearance({
    this.fontFamily = SubtitleFontFamily.appSans,
    this.fontSize = 34,
    this.textColor = SubtitleTextColor.white,
    this.fontWeight = SubtitleFontWeight.semibold,
    this.backgroundOpacity = 0.62,
    this.shadow = true,
    this.bottomPadding = 34,
  });

  static const double minFontSize = 24;
  static const double maxFontSize = 72;
  static const double minBackgroundOpacity = 0;
  static const double maxBackgroundOpacity = 0.85;
  static const double minBottomPadding = 16;
  static const double maxBottomPadding = 112;

  final SubtitleFontFamily fontFamily;
  final double fontSize;
  final SubtitleTextColor textColor;
  final SubtitleFontWeight fontWeight;
  final double backgroundOpacity;
  final bool shadow;
  final double bottomPadding;

  SubtitleAppearance copyWith({
    SubtitleFontFamily? fontFamily,
    double? fontSize,
    SubtitleTextColor? textColor,
    SubtitleFontWeight? fontWeight,
    double? backgroundOpacity,
    bool? shadow,
    double? bottomPadding,
  }) {
    return SubtitleAppearance(
      fontFamily: fontFamily ?? this.fontFamily,
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      fontWeight: fontWeight ?? this.fontWeight,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      shadow: shadow ?? this.shadow,
      bottomPadding: bottomPadding ?? this.bottomPadding,
    );
  }

  TextStyle textStyle({double scale = 1}) {
    return TextStyle(
      fontFamily: fontFamily.primary,
      fontFamilyFallback: fontFamily.fallback,
      fontSize: fontSize * scale,
      height: 1.28,
      letterSpacing: 0,
      color: textColor.color,
      fontWeight: fontWeight.value,
      backgroundColor: Colors.black.withValues(alpha: backgroundOpacity),
      shadows: shadow
          ? const [
              Shadow(
                color: Color(0xE6000000),
                offset: Offset(0, 2),
                blurRadius: 4,
              ),
            ]
          : null,
    );
  }

  EdgeInsets padding({double scale = 1}) {
    return EdgeInsets.fromLTRB(
      16 * scale,
      0,
      16 * scale,
      bottomPadding * scale,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'font_family': fontFamily.name,
      'font_size': fontSize,
      'text_color': textColor.name,
      'font_weight': fontWeight.name,
      'background_opacity': backgroundOpacity,
      'shadow': shadow,
      'bottom_padding': bottomPadding,
    };
  }

  factory SubtitleAppearance.fromJson(Object? value) {
    if (value is! Map) return const SubtitleAppearance();
    const defaults = SubtitleAppearance();
    final shadow = value['shadow'];
    return SubtitleAppearance(
      fontFamily: SubtitleFontFamily.values.firstWhere(
        (f) => f.name == value['font_family'],
        orElse: () => defaults.fontFamily,
      ),
      fontSize: _doubleInRange(
        value['font_size'],
        minFontSize,
        maxFontSize,
        defaults.fontSize,
      ),
      textColor: SubtitleTextColor.values.firstWhere(
        (c) => c.name == value['text_color'],
        orElse: () => defaults.textColor,
      ),
      fontWeight: SubtitleFontWeight.values.firstWhere(
        (w) => w.name == value['font_weight'],
        orElse: () => defaults.fontWeight,
      ),
      backgroundOpacity: _doubleInRange(
        value['background_opacity'],
        minBackgroundOpacity,
        maxBackgroundOpacity,
        defaults.backgroundOpacity,
      ),
      shadow: shadow is bool ? shadow : defaults.shadow,
      bottomPadding: _doubleInRange(
        value['bottom_padding'],
        minBottomPadding,
        maxBottomPadding,
        defaults.bottomPadding,
      ),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SubtitleAppearance &&
        other.fontFamily == fontFamily &&
        other.fontSize == fontSize &&
        other.textColor == textColor &&
        other.fontWeight == fontWeight &&
        other.backgroundOpacity == backgroundOpacity &&
        other.shadow == shadow &&
        other.bottomPadding == bottomPadding;
  }

  @override
  int get hashCode => Object.hash(
    fontFamily,
    fontSize,
    textColor,
    fontWeight,
    backgroundOpacity,
    shadow,
    bottomPadding,
  );
}

double _doubleInRange(Object? value, double min, double max, double fallback) {
  final number = (value as num?)?.toDouble();
  if (number == null || number.isNaN || number.isInfinite) return fallback;
  return number.clamp(min, max).toDouble();
}
