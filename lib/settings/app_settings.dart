// AppSettings — user preferences (SPEC §9, SCREENS §9). JSON-persisted, observable.
//
// Diagnostics is OFF by default and stays that way unless the user opts in — a
// hard requirement (principle P4, local-first reads as trust). UI text size is the
// macOS Dynamic-Type substitute (DESIGN_SYSTEM §3.2.3).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../subtitle/subtitle_appearance.dart';

/// Translation strategy the engine should use (SPEC §9). Proven on-device:
///   quality     — single lean pass on the 12B. Best Hebrew gender (~88%). Default.
///   fast        — single lean pass on the 7B. Fastest (~5 min/30 min), ~75% gender.
///   progressive — 7B draft is watchable in ~5 min, then the 12B re-resolves gender
///                 on flagged lines in the BACKGROUND and upgrades the file in place.
enum TranslationStrategy { quality, fast, progressive }

extension TranslationStrategyMeta on TranslationStrategy {
  /// Wire value sent to the daemon (matches the engine's TranslationStrategy).
  String get wire => name;

  String get label => switch (this) {
    TranslationStrategy.quality => 'Quality · 12B',
    TranslationStrategy.fast => 'Fast · 7B',
    TranslationStrategy.progressive => 'Progressive',
  };

  String get blurb => switch (this) {
    TranslationStrategy.quality =>
      'One pass on the 12B model. Best Hebrew gender & pronoun accuracy. ~8–9 min per 30 min.',
    TranslationStrategy.fast =>
      'One pass on the faster 7B model. ~5 min per 30 min, slightly lower gender accuracy.',
    TranslationStrategy.progressive =>
      'Start watching in ~5 min with a 7B draft; the 12B then perfects gender in the background.',
  };
}

/// UI text size — the desktop Dynamic-Type control (DS §3.2.3).
enum UiTextSize { s, m, l, xl }

extension UiTextSizeScale on UiTextSize {
  double get scale => switch (this) {
    UiTextSize.s => 0.9,
    UiTextSize.m => 1.0,
    UiTextSize.l => 1.15,
    UiTextSize.xl => 1.3,
  };
  String get label => switch (this) {
    UiTextSize.s => 'S',
    UiTextSize.m => 'M',
    UiTextSize.l => 'L',
    UiTextSize.xl => 'XL',
  };
}

class AppSettings extends ChangeNotifier {
  AppSettings({
    String targetLanguage = 'he',
    TranslationStrategy translationStrategy = TranslationStrategy.quality,
    int readingSpeedCps = 17,
    bool diagnostics = false,
    UiTextSize uiTextSize = UiTextSize.m,
    String modelLocation = '/Volumes/EP2TB/autosub-models',
    bool setupComplete = false,
    String tmdbApiKey = '',
    String openSubtitlesApiKey = '',
    SubtitleAppearance subtitleAppearance = const SubtitleAppearance(),
  }) : _targetLanguage = targetLanguage,
       _translationStrategy = translationStrategy,
       _readingSpeedCps = readingSpeedCps,
       _diagnostics = diagnostics,
       _uiTextSize = uiTextSize,
       _modelLocation = modelLocation,
       _setupComplete = setupComplete,
       _tmdbApiKey = tmdbApiKey,
       _openSubtitlesApiKey = openSubtitlesApiKey,
       _subtitleAppearance = subtitleAppearance;

  String _targetLanguage;
  TranslationStrategy _translationStrategy;
  int _readingSpeedCps;
  bool _diagnostics;
  UiTextSize _uiTextSize;
  String _modelLocation;
  bool _setupComplete;
  String _tmdbApiKey;
  String _openSubtitlesApiKey;
  SubtitleAppearance _subtitleAppearance;

  String get targetLanguage => _targetLanguage;
  TranslationStrategy get translationStrategy => _translationStrategy;
  int get readingSpeedCps => _readingSpeedCps;
  bool get diagnostics => _diagnostics;
  UiTextSize get uiTextSize => _uiTextSize;
  String get modelLocation => _modelLocation;
  SubtitleAppearance get subtitleAppearance => _subtitleAppearance;

  /// True once the user has passed the first-run setup wizard (SPEC §11).
  bool get setupComplete => _setupComplete;

  /// The user's TMDB API key (v3 key or v4 read token), for metadata + posters.
  /// Stored locally in Application Support — never in the repo.
  String get tmdbApiKey => _tmdbApiKey;

  /// Optional OpenSubtitles API key. Keyless providers are also tried; ASR remains
  /// the fallback when no original-language subtitle is found. Stored locally only.
  String get openSubtitlesApiKey => _openSubtitlesApiKey;

  set targetLanguage(String v) => _set(() => _targetLanguage = v);
  set translationStrategy(TranslationStrategy v) =>
      _set(() => _translationStrategy = v);
  set readingSpeedCps(int v) => _set(() => _readingSpeedCps = v);
  set diagnostics(bool v) => _set(() => _diagnostics = v);
  set uiTextSize(UiTextSize v) => _set(() => _uiTextSize = v);
  set modelLocation(String v) => _set(() => _modelLocation = v);
  set setupComplete(bool v) => _set(() => _setupComplete = v);
  set tmdbApiKey(String v) => _set(() => _tmdbApiKey = v.trim());
  set openSubtitlesApiKey(String v) =>
      _set(() => _openSubtitlesApiKey = v.trim());
  set subtitleAppearance(SubtitleAppearance v) =>
      _set(() => _subtitleAppearance = v);

  /// True if the model location is currently mounted/readable.
  bool get modelLocationMounted {
    try {
      return Directory(_modelLocation).existsSync();
    } catch (_) {
      return false;
    }
  }

  void _set(VoidCallback mutate) {
    mutate();
    notifyListeners();
    unawaited(_save());
  }

  /// Factory reset: wipe ALL settings (including API keys and setup state) back to
  /// first-run defaults. Used by Settings → "Reset all data".
  Future<void> resetToDefaults() async {
    _targetLanguage = 'he';
    _translationStrategy = TranslationStrategy.quality;
    _readingSpeedCps = 17;
    _diagnostics = false;
    _uiTextSize = UiTextSize.m;
    _modelLocation = '/Volumes/EP2TB/autosub-models';
    _setupComplete = false;
    _tmdbApiKey = '';
    _openSubtitlesApiKey = '';
    _subtitleAppearance = const SubtitleAppearance();
    notifyListeners();
    await _save();
  }

  File? _file;

  Future<File> _storeFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    return _file = File(p.join(dir.path, 'settings.json'));
  }

  Future<void> load() async {
    try {
      final f = await _storeFile();
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      _targetLanguage = (j['target_language'] as String?) ?? _targetLanguage;
      _translationStrategy = TranslationStrategy.values.firstWhere(
        (e) => e.name == j['translation_strategy'],
        orElse: () => _translationStrategy,
      );
      _readingSpeedCps =
          (j['reading_speed_cps'] as num?)?.toInt() ?? _readingSpeedCps;
      _diagnostics = (j['diagnostics'] as bool?) ?? false; // never default-on
      _uiTextSize = UiTextSize.values.firstWhere(
        (e) => e.name == j['ui_text_size'],
        orElse: () => _uiTextSize,
      );
      _modelLocation = (j['model_location'] as String?) ?? _modelLocation;
      _setupComplete = (j['setup_complete'] as bool?) ?? false;
      _tmdbApiKey = (j['tmdb_api_key'] as String?) ?? _tmdbApiKey;
      _openSubtitlesApiKey =
          (j['open_subtitles_api_key'] as String?) ?? _openSubtitlesApiKey;
      _subtitleAppearance = SubtitleAppearance.fromJson(
        j['subtitle_appearance'],
      );
      notifyListeners();
    } catch (_) {
      // Corrupt/missing → keep defaults.
    }
  }

  Future<void> _save() async {
    try {
      final f = await _storeFile();
      await f.writeAsString(
        jsonEncode({
          'target_language': _targetLanguage,
          'translation_strategy': _translationStrategy.name,
          'reading_speed_cps': _readingSpeedCps,
          'diagnostics': _diagnostics,
          'ui_text_size': _uiTextSize.name,
          'model_location': _modelLocation,
          'setup_complete': _setupComplete,
          'tmdb_api_key': _tmdbApiKey,
          'open_subtitles_api_key': _openSubtitlesApiKey,
          'subtitle_appearance': _subtitleAppearance.toJson(),
        }),
      );
    } catch (_) {
      // Best-effort persistence.
    }
  }
}
