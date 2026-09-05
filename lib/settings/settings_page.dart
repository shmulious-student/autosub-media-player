// SettingsPage — preferences (SPEC §9, SCREENS §9).
//
// Plain, grouped, calm (principle P4). Diagnostics is OFF by default with a plain
// disclosure — a hard requirement. Autosave with no "Save" button; changes persist
// through AppSettings immediately.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../library/library_store.dart';
import '../library/processing_manager.dart';
import '../metadata/metadata_store.dart';
import '../subtitle/subtitle_appearance.dart';
import '../ui/components/confirm_dialog.dart';
import '../ui/components/settings_row.dart';
import '../ui/components/status_chip.dart';
import '../ui/components/toast.dart';
import '../ui/tokens.dart';
import 'app_settings.dart';

/// Supported subtitle target languages (v1: Hebrew default).
const Map<String, String> _languages = {
  'he': 'Hebrew',
  'ar': 'Arabic',
  'es': 'Spanish',
  'fr': 'French',
  'de': 'German',
};

const List<int> _cpsOptions = [12, 15, 17, 20];

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.store,
    required this.manager,
    required this.settings,
    required this.metadata,
  });

  final LibraryStore store;
  final ProcessingManager manager;
  final AppSettings settings;
  final MetadataStore metadata;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppSettings get s => widget.settings;

  @override
  void initState() {
    super.initState();
    s.addListener(_onChange);
  }

  @override
  void dispose() {
    s.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _updateSubtitleAppearance(SubtitleAppearance appearance) {
    s.subtitleAppearance = appearance;
  }

  Future<void> _clearLibrary() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Clear library?',
      message:
          'This removes all titles from the list. Your video files and any '
          'generated subtitle files are not deleted.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (ok ?? false) {
      await widget.store.clear();
      await widget.manager.clearQueue();
      if (mounted) showToast(context, 'Library and translation queue cleared.');
    }
  }

  Future<void> _resetAllData() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Reset all data?',
      message:
          'Removes the library, all TMDB metadata & posters, the translation '
          'queue, and your saved settings — including your TMDB and OpenSubtitles '
          'API keys. The app returns to first-run setup.\n\n'
          'Your video files and any generated subtitle files are NOT deleted.',
      confirmLabel: 'Reset everything',
      destructive: true,
    );
    if (!(ok ?? false)) return;
    await widget.manager.clearQueue();
    await widget.store.clear();
    await widget.metadata.clearAll();
    await widget.settings.resetToDefaults();
    if (mounted) {
      showToast(
        context,
        'All app data reset. Restart the app to run setup again.',
        variant: ToastVariant.success,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.neutral950,
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              AppSpacing.x6,
              AppSpacing.x12,
              AppSpacing.x6,
              0,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppSpacing.contentMaxWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Settings', style: AppType.titleLg),

                    SettingsSection(
                      title: 'Language & quality',
                      children: [
                        SettingsRow(
                          label: 'Target language',
                          caption:
                              'The language AutoSub translates subtitles into.',
                          control: DropdownButton<String>(
                            value: s.targetLanguage,
                            dropdownColor: AppColors.neutral850,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final e in _languages.entries)
                                DropdownMenuItem(
                                  value: e.key,
                                  child: Text(e.value),
                                ),
                            ],
                            onChanged: (v) {
                              if (v != null) s.targetLanguage = v;
                            },
                          ),
                        ),
                        SettingsRow(
                          label: 'Translation',
                          caption: s.translationStrategy.blurb,
                          control: DropdownButton<TranslationStrategy>(
                            value: s.translationStrategy,
                            dropdownColor: AppColors.neutral850,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final t in TranslationStrategy.values)
                                DropdownMenuItem(
                                  value: t,
                                  child: Text(t.label),
                                ),
                            ],
                            onChanged: (v) {
                              if (v != null) s.translationStrategy = v;
                            },
                          ),
                        ),
                      ],
                    ),

                    SettingsSection(
                      title: 'Subtitles',
                      children: [
                        _SubtitlePreview(appearance: s.subtitleAppearance),
                        SettingsRow(
                          label: 'Reading speed (CPS)',
                          caption:
                              'Maximum characters per second. Lower is easier to read.',
                          control: DropdownButton<int>(
                            value: _cpsOptions.contains(s.readingSpeedCps)
                                ? s.readingSpeedCps
                                : 17,
                            dropdownColor: AppColors.neutral850,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final c in _cpsOptions)
                                DropdownMenuItem(
                                  value: c,
                                  child: Text('$c chars/s'),
                                ),
                            ],
                            onChanged: (v) {
                              if (v != null) s.readingSpeedCps = v;
                            },
                          ),
                        ),
                        SettingsRow(
                          label: 'Font',
                          caption:
                              'Subtitle fonts are limited to Hebrew and English capable stacks.',
                          control: DropdownButton<SubtitleFontFamily>(
                            value: s.subtitleAppearance.fontFamily,
                            dropdownColor: AppColors.neutral850,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final font in SubtitleFontFamily.values)
                                DropdownMenuItem(
                                  value: font,
                                  child: Text(font.label),
                                ),
                            ],
                            onChanged: (font) {
                              if (font != null) {
                                _updateSubtitleAppearance(
                                  s.subtitleAppearance.copyWith(
                                    fontFamily: font,
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                        SettingsRow(
                          label: 'Size',
                          caption: 'Controls the subtitle text size on video.',
                          control: _SliderValue(
                            width: 240,
                            value: s.subtitleAppearance.fontSize,
                            min: SubtitleAppearance.minFontSize,
                            max: SubtitleAppearance.maxFontSize,
                            divisions: 24,
                            label: '${s.subtitleAppearance.fontSize.round()}',
                            onChanged: (v) => _updateSubtitleAppearance(
                              s.subtitleAppearance.copyWith(fontSize: v),
                            ),
                          ),
                        ),
                        SettingsRow(
                          label: 'Weight',
                          caption: 'Bolder text is easier to read over motion.',
                          control: SettingsSegmented<SubtitleFontWeight>(
                            value: s.subtitleAppearance.fontWeight,
                            items: SubtitleFontWeight.values,
                            labelOf: (w) => w.label,
                            onChanged: (w) => _updateSubtitleAppearance(
                              s.subtitleAppearance.copyWith(fontWeight: w),
                            ),
                          ),
                        ),
                        SettingsRow(
                          label: 'Text color',
                          caption: 'Choose a subtitle color for contrast.',
                          control: _SubtitleColorSwatches(
                            value: s.subtitleAppearance.textColor,
                            onChanged: (c) => _updateSubtitleAppearance(
                              s.subtitleAppearance.copyWith(textColor: c),
                            ),
                          ),
                        ),
                        SettingsRow(
                          label: 'Background',
                          caption: 'Adds a translucent backing behind text.',
                          control: _SliderValue(
                            width: 240,
                            value: s.subtitleAppearance.backgroundOpacity,
                            min: SubtitleAppearance.minBackgroundOpacity,
                            max: SubtitleAppearance.maxBackgroundOpacity,
                            divisions: 17,
                            label:
                                '${(s.subtitleAppearance.backgroundOpacity * 100).round()}%',
                            onChanged: (v) => _updateSubtitleAppearance(
                              s.subtitleAppearance.copyWith(
                                backgroundOpacity: v,
                              ),
                            ),
                          ),
                        ),
                        SettingsRow(
                          label: 'Shadow',
                          caption:
                              'Adds edge contrast without changing timing.',
                          control: Switch(
                            value: s.subtitleAppearance.shadow,
                            onChanged: (v) => _updateSubtitleAppearance(
                              s.subtitleAppearance.copyWith(shadow: v),
                            ),
                          ),
                        ),
                        SettingsRow(
                          label: 'Vertical position',
                          caption:
                              'Raises subtitles when the bottom of the frame is busy.',
                          control: _SliderValue(
                            width: 240,
                            value: s.subtitleAppearance.bottomPadding,
                            min: SubtitleAppearance.minBottomPadding,
                            max: SubtitleAppearance.maxBottomPadding,
                            divisions: 12,
                            label:
                                '${s.subtitleAppearance.bottomPadding.round()} px',
                            onChanged: (v) => _updateSubtitleAppearance(
                              s.subtitleAppearance.copyWith(bottomPadding: v),
                            ),
                          ),
                        ),
                        SettingsRow(
                          label: 'Style preset',
                          caption: 'Restore the default subtitle look.',
                          control: TextButton.icon(
                            onPressed: () => _updateSubtitleAppearance(
                              const SubtitleAppearance(),
                            ),
                            icon: const Icon(Icons.restart_alt, size: 18),
                            label: const Text('Reset'),
                          ),
                        ),
                      ],
                    ),

                    SettingsSection(
                      title: 'Storage',
                      children: [
                        SettingsRow(
                          label: 'Model location',
                          caption: s.modelLocation,
                          control: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              StatusChip(
                                style: s.modelLocationMounted
                                    ? StatusStyles.ready
                                    : StatusStyles.attention,
                                label: s.modelLocationMounted
                                    ? 'Mounted'
                                    : 'Not found',
                                size: StatusChipSize.md,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    SettingsSection(
                      title: 'Metadata',
                      children: [
                        SettingsRow(
                          label: 'TMDB API key',
                          caption:
                              'Fetches official posters & metadata from TMDB. '
                              'Stored only on this Mac.',
                          control: SizedBox(
                            width: 260,
                            child: _TmdbKeyField(settings: s),
                          ),
                        ),
                        SettingsRow(
                          label: 'OpenSubtitles API key',
                          caption:
                              'Optional keyed source for original-language subtitles. '
                              'Keyless sources are tried too; speech recognition is '
                              'the final fallback. Stored only on this Mac.',
                          control: SizedBox(
                            width: 260,
                            child: _OpenSubtitlesKeyField(settings: s),
                          ),
                        ),
                      ],
                    ),

                    SettingsSection(
                      title: 'Privacy',
                      children: [
                        SettingsRow(
                          label: 'Diagnostics',
                          caption:
                              'Sends anonymized crash & usage data. Never your '
                              'media, subtitles, or library.',
                          control: Switch(
                            value: s.diagnostics,
                            onChanged: (v) => s.diagnostics = v,
                          ),
                        ),
                      ],
                    ),

                    SettingsSection(
                      title: 'Appearance',
                      children: [
                        SettingsRow(
                          label: 'UI text size',
                          caption: 'Scales the interface text.',
                          control: SettingsSegmented<UiTextSize>(
                            value: s.uiTextSize,
                            items: UiTextSize.values,
                            labelOf: (u) => u.label,
                            onChanged: (u) => s.uiTextSize = u,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: AppSpacing.x6),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: OutlinedButton.icon(
                        onPressed: _clearLibrary,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.failedFg,
                          side: const BorderSide(color: AppColors.failedFg),
                        ),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('Clear library…'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.x2),
                    Text(
                      'Media & sidecars are kept.',
                      style: AppType.bodySm.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.x6),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: OutlinedButton.icon(
                        onPressed: _resetAllData,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.failedFg,
                          side: const BorderSide(color: AppColors.failedFg),
                        ),
                        icon: const Icon(Icons.restart_alt, size: 18),
                        label: const Text('Reset all data…'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.x2),
                    Text(
                      'Clears library, metadata, queue, and settings (incl. API keys). '
                      'Media & generated subtitle files are kept.',
                      style: AppType.bodySm.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.x12),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubtitlePreview extends StatelessWidget {
  const _SubtitlePreview({required this.appearance});

  final SubtitleAppearance appearance;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: ClipRRect(
        borderRadius: AppRadius.borderSm,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final scale = _subtitleScale(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFF233041),
                          Color(0xFF0B0D10),
                          Color(0xFF151A20),
                        ],
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: CustomPaint(painter: _PreviewFramePainter()),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: appearance.padding(),
                      child: Directionality(
                        textDirection: TextDirection.rtl,
                        child: Text(
                          'הכתוביות צריכות להישאר קריאות גם בסצנה חשוכה',
                          textAlign: TextAlign.center,
                          style: appearance.textStyle(scale: scale),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  double _subtitleScale(double width, double height) {
    const referenceArea = 1920 * 1080;
    final area = width * height;
    return math.sqrt(area / referenceArea).clamp(0.34, 0.7).toDouble();
  }
}

class _PreviewFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withValues(alpha: 0.22);
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.64, size.width, size.height * 0.36),
      paint,
    );

    final shade = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Color(0x66000000)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, shade);

    final bandPaint = Paint()
      ..color = AppColors.neutral0.withValues(alpha: 0.05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width * 0.08, size.height * 0.22),
      Offset(size.width * 0.92, size.height * 0.18),
      bandPaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.18, size.height * 0.48),
      Offset(size.width * 0.84, size.height * 0.44),
      bandPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SliderValue extends StatelessWidget {
  const _SliderValue({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
    this.width = 220,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Slider(
              value: value.clamp(min, max).toDouble(),
              min: min,
              max: max,
              divisions: divisions,
              label: label,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              label,
              textAlign: TextAlign.end,
              style: AppType.monoTime.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubtitleColorSwatches extends StatelessWidget {
  const _SubtitleColorSwatches({required this.value, required this.onChanged});

  final SubtitleTextColor value;
  final ValueChanged<SubtitleTextColor> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final color in SubtitleTextColor.values) ...[
          Tooltip(
            message: color.label,
            child: InkWell(
              onTap: () => onChanged(color),
              borderRadius: AppRadius.borderSm,
              child: Container(
                width: 30,
                height: 30,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: AppRadius.borderSm,
                  border: Border.all(
                    color: color == value
                        ? AppColors.amber
                        : AppColors.neutral700,
                    width: color == value ? 2 : 1,
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.color,
                    borderRadius: AppRadius.borderSm,
                  ),
                ),
              ),
            ),
          ),
          if (color != SubtitleTextColor.values.last)
            const SizedBox(width: AppSpacing.x2),
        ],
      ],
    );
  }
}

/// An obscured TMDB-key field that commits on change (autosave) with a show/hide
/// toggle and a "set/not set" cue.
class _TmdbKeyField extends StatefulWidget {
  const _TmdbKeyField({required this.settings});
  final AppSettings settings;

  @override
  State<_TmdbKeyField> createState() => _TmdbKeyFieldState();
}

class _TmdbKeyFieldState extends State<_TmdbKeyField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.settings.tmdbApiKey,
  );
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      obscureText: _obscure,
      onChanged: (v) => widget.settings.tmdbApiKey = v,
      style: AppType.body,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Paste your TMDB key',
        suffixIcon: IconButton(
          icon: Icon(
            _obscure ? Icons.visibility_off : Icons.visibility,
            size: 18,
          ),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
    );
  }
}

class _OpenSubtitlesKeyField extends StatefulWidget {
  const _OpenSubtitlesKeyField({required this.settings});
  final AppSettings settings;

  @override
  State<_OpenSubtitlesKeyField> createState() => _OpenSubtitlesKeyFieldState();
}

class _OpenSubtitlesKeyFieldState extends State<_OpenSubtitlesKeyField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.settings.openSubtitlesApiKey,
  );
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      obscureText: _obscure,
      onChanged: (v) => widget.settings.openSubtitlesApiKey = v,
      style: AppType.body,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Paste your OpenSubtitles key',
        suffixIcon: IconButton(
          icon: Icon(
            _obscure ? Icons.visibility_off : Icons.visibility,
            size: 18,
          ),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
    );
  }
}
