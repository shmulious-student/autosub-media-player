import 'package:autosub_media_player/subtitle/subtitle_appearance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SubtitleAppearance round-trips through json', () {
    const appearance = SubtitleAppearance(
      fontFamily: SubtitleFontFamily.notoSansHebrew,
      fontSize: 40,
      textColor: SubtitleTextColor.amber,
      fontWeight: SubtitleFontWeight.bold,
      backgroundOpacity: 0.35,
      shadow: false,
      bottomPadding: 80,
    );

    expect(SubtitleAppearance.fromJson(appearance.toJson()), appearance);
  });

  test('SubtitleAppearance clamps corrupt json to readable bounds', () {
    final appearance = SubtitleAppearance.fromJson({
      'font_size': 200,
      'background_opacity': -1,
      'bottom_padding': double.infinity,
      'font_family': 'papyrus',
      'shadow': 'yes',
    });

    expect(appearance.fontFamily, const SubtitleAppearance().fontFamily);
    expect(appearance.fontSize, SubtitleAppearance.maxFontSize);
    expect(
      appearance.backgroundOpacity,
      SubtitleAppearance.minBackgroundOpacity,
    );
    expect(appearance.bottomPadding, const SubtitleAppearance().bottomPadding);
    expect(appearance.shadow, const SubtitleAppearance().shadow);
  });

  test('font choices keep Hebrew and English capable fallbacks', () {
    for (final font in SubtitleFontFamily.values) {
      final style = SubtitleAppearance(fontFamily: font).textStyle();
      final fallbacks = style.fontFamilyFallback ?? const <String>[];

      expect(
        fallbacks.any((f) => f == 'Arial Hebrew' || f == 'Noto Sans Hebrew'),
        isTrue,
        reason: '${font.name} needs a Hebrew-capable fallback',
      );
      expect(
        style.fontFamily == null ||
            style.fontFamily == 'Arial' ||
            fallbacks.any((f) => f == 'Arial' || f == 'Inter'),
        isTrue,
        reason: '${font.name} needs an English-capable primary or fallback',
      );
    }
  });
}
