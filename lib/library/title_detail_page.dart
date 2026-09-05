// TitleDetailPage — per-title metadata + processing controls (SCREENS §3).
//
// Identity comes from TMDB: the official poster (the title's graphical
// representation), name, year/episode, rating, and overview. The poster's extracted
// colors tint this page — a per-title palette over the calm base. Below the hero are
// the subtitle controls (status, source, generate) wired to the engine queue.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/models.dart';
import '../engine/engine_client.dart';
import '../metadata/fix_match_dialog.dart';
import '../metadata/metadata_store.dart';
import '../metadata/subtitle_source.dart';
import '../metadata/title_metadata.dart';
import '../player/player_page.dart';
import '../platform/secure_files.dart';
import '../settings/app_settings.dart';
import '../subtitle/subtitle_editor_page.dart';
import '../ui/bidi.dart';
import '../ui/components/characters_section.dart';
import '../ui/components/confidence_meter.dart';
import '../ui/components/source_picker.dart';
import '../ui/components/status_chip.dart';
import '../ui/components/toast.dart';
import '../ui/duration_format.dart';
import '../ui/tokens.dart';
import 'library_store.dart';
import 'processing_manager.dart';

class TitleDetailPage extends StatefulWidget {
  const TitleDetailPage({
    super.key,
    required this.entry,
    required this.store,
    required this.manager,
    required this.metadata,
    required this.settings,
  });

  final LibraryEntry entry;
  final LibraryStore store;
  final ProcessingManager manager;
  final MetadataStore metadata;
  final AppSettings settings;

  @override
  State<TitleDetailPage> createState() => _TitleDetailPageState();
}

class _TitleDetailPageState extends State<TitleDetailPage> {
  late SourcePreference _source;
  bool _sourceBusy = false;

  String get _lang => widget.settings.targetLanguage;
  LibraryEntry get _entry => widget.entry;
  TitleMetadata? get _meta => widget.metadata.metadataFor(_entry.path);

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onChange);
    widget.metadata.addListener(_onChange);
    // Ensure this title is enriched even if the background sweep hasn't reached it.
    widget.metadata.enrich(_entry.path);
    _source = SourcePreference.auto;
    // Advance the elapsed/ETA readout each second while this title is translating.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final job = widget.manager.jobFor(_entry.path);
      if (mounted && job?.state == 'running') setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.manager.removeListener(_onChange);
    widget.metadata.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  String get _sourceLang =>
      SourceSubtitleCache.normalizeLang(_meta?.originalLanguage ?? 'en');

  SourceSubtitleResult? get _sourceSubtitle =>
      SourceSubtitleCache.read(videoPath: _entry.path, lang: _sourceLang);

  String? _siblingSidecar() {
    final path = _siblingSidecarPath();
    return path == null ? null : p.basename(path);
  }

  String? _siblingSidecarPath() {
    final langs = <String>{_sourceLang, if (_sourceLang == 'en') 'eng'};
    for (final lang in langs) {
      final path = p.join(
        p.dirname(_entry.path),
        '${p.basenameWithoutExtension(_entry.path)}.$lang.srt',
      );
      try {
        if (File(path).existsSync()) return path;
      } catch (_) {}
    }
    return null;
  }

  void _play() {
    final sub = _entry.hasSidecar(_lang) ? _entry.sidecarPath(_lang) : null;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          videoPath: _entry.path,
          subtitlePath: sub,
          title: _displayName,
          autoPlay: true,
          settings: widget.settings,
          manager: widget.manager,
        ),
      ),
    );
  }

  Future<void> _generate() async {
    if (!widget.manager.engineOnline) {
      showToast(
        context,
        'Engine offline — translation is paused.',
        variant: ToastVariant.attention,
      );
      return;
    }
    // Re-generate (sidecar already present) forces a fresh run that overwrites it.
    final force = _entry.hasSidecar(_lang);
    if (_source == SourcePreference.embedded) {
      final sibling = _siblingSidecarPath();
      if (sibling != null) {
        await widget.manager.importSourceSubtitleFile(_entry.path, sibling);
      }
    }
    await widget.manager.retry(
      _entry.path,
      target: _lang,
      force: force,
      fetchSource: _source != SourcePreference.asr,
    );
    if (mounted) {
      showToast(
        context,
        force
            ? 'Re-translating — track it in Queue.'
            : 'Added to the queue — track it in Queue.',
        variant: ToastVariant.success,
      );
    }
  }

  Future<void> _refetchSourceSubtitle() async {
    setState(() => _sourceBusy = true);
    final result = await widget.manager.refetchSourceSubtitle(_entry.path);
    if (!mounted) return;
    setState(() => _sourceBusy = false);
    showToast(
      context,
      result == null
          ? 'No original-language source subtitle found.'
          : 'Source subtitle updated from ${result.providerName}.',
      variant: result == null ? ToastVariant.attention : ToastVariant.success,
    );
  }

  Future<void> _pickSourceSubtitleFile() async {
    setState(() => _sourceBusy = true);
    try {
      final picked = await const SecureFiles().pickFile();
      if (picked == null) return;
      final result = await widget.manager.importSourceSubtitleFile(
        _entry.path,
        picked.path,
      );
      if (!mounted) return;
      showToast(
        context,
        result == null
            ? "Couldn't use that subtitle file."
            : 'Source subtitle swapped to ${p.basename(picked.path)}.',
        variant: result == null ? ToastVariant.error : ToastVariant.success,
      );
    } finally {
      if (mounted) setState(() => _sourceBusy = false);
    }
  }

  Future<void> _pasteSourceSubtitleUrl() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use subtitle URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/subtitles.srt',
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Use URL'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (raw == null || raw.trim().isEmpty) return;
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      if (!mounted) return;
      showToast(
        context,
        'Use a valid http or https subtitle URL.',
        variant: ToastVariant.error,
      );
      return;
    }

    setState(() => _sourceBusy = true);
    final result = await widget.manager.importSourceSubtitleUrl(
      _entry.path,
      uri,
    );
    if (!mounted) return;
    setState(() => _sourceBusy = false);
    showToast(
      context,
      result == null
          ? "Couldn't download a subtitle from that URL."
          : 'Source subtitle swapped from URL.',
      variant: result == null ? ToastVariant.error : ToastVariant.success,
    );
  }

  void _editSubtitles() {
    final sidecar = _entry.sidecarPath(_lang);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SubtitleEditorPage(
          sidecarPath: sidecar,
          title: _displayName,
          targetLang: _lang,
          maxCps: widget.settings.readingSpeedCps,
        ),
      ),
    );
  }

  void _fixMatch() {
    showFixMatchDialog(
      context,
      metadata: widget.metadata,
      path: _entry.path,
      initialQuery: _meta?.name ?? _entry.displayTitle,
      currentTmdbId: _meta?.tmdbId,
    );
  }

  Future<void> _refetchMetadata() async {
    showToast(context, 'Refetching metadata…');
    await widget.metadata.refetch(_entry.path);
    if (mounted) {
      showToast(context, 'Metadata refetched.', variant: ToastVariant.success);
    }
  }

  String get _displayName =>
      (_meta?.name?.isNotEmpty ?? false) ? _meta!.name! : _entry.displayTitle;

  @override
  Widget build(BuildContext context) {
    final meta = _meta;
    final ready = _entry.hasSidecar(_lang);
    final job = widget.manager.jobFor(_entry.path);
    final tint = meta?.dominant ?? AppColors.neutral900;
    final accent = meta?.accent ?? AppColors.amber;

    return Scaffold(
      backgroundColor: AppColors.neutral950,
      body: Stack(
        children: [
          // Per-title palette wash from the poster's dominant color (SCREENS §3:
          // "dictate the colors / palette of the detail page").
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    tint.withValues(alpha: 0.42),
                    tint.withValues(alpha: 0.12),
                    AppColors.neutral950,
                  ],
                  stops: const [0.0, 0.32, 0.62],
                ),
              ),
            ),
          ),
          CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                leading: BackButton(
                  onPressed: () => Navigator.of(context).pop(),
                ),
                title: Text(
                  'Library',
                  style: AppType.body.copyWith(color: AppColors.textSecondary),
                ),
              ),
              SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: AppSpacing.contentMaxWidth,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.x6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _hero(meta, accent),
                          const SizedBox(height: AppSpacing.x6),
                          const Divider(height: 1, color: AppColors.hairline),
                          const SizedBox(height: AppSpacing.x6),
                          _subtitles(ready, job),
                          const SizedBox(height: AppSpacing.x6),
                          const Divider(height: 1, color: AppColors.hairline),
                          const SizedBox(height: AppSpacing.x6),
                          CharactersSection(
                            metadata: widget.metadata,
                            manager: widget.manager,
                            path: _entry.path,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _hero(TitleMetadata? meta, Color accent) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Poster (official artwork) with an accent-tinted glow.
        Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(AppRadius.lg),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.35),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.all(AppRadius.lg),
            child: SizedBox(
              width: 160,
              height: 240,
              child: (meta?.posterFile != null)
                  ? Image.file(
                      File(meta!.posterFile!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _posterPlaceholder(),
                    )
                  : _posterPlaceholder(),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.x5),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AutoDirText(_displayName, style: AppType.titleLg),
              const SizedBox(height: AppSpacing.x2),
              _metaLine(meta, accent),
              if (meta?.overview != null && meta!.overview!.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.x3),
                AutoDirText(
                  meta.overview!,
                  style: AppType.body.copyWith(color: AppColors.textSecondary),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: AppSpacing.x5),
              Wrap(
                spacing: AppSpacing.x3,
                runSpacing: AppSpacing.x3,
                children: [
                  FilledButton.icon(
                    onPressed: _play,
                    icon: const Icon(Icons.play_arrow, size: 20),
                    label: Text(
                      _entry.hasSidecar(_lang) ? 'Play' : 'Play (no subtitles)',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.metadata.hasApiKey ? _fixMatch : null,
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('Fix match'),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.metadata.hasApiKey ? _refetchMetadata : null,
                    icon: const Icon(Icons.cloud_sync_outlined, size: 18),
                    label: const Text('Refetch metadata'),
                  ),
                ],
              ),
              if (meta != null && meta.lowConfidence) ...[
                const SizedBox(height: AppSpacing.x3),
                Row(
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 16,
                      color: AppColors.attentionFg,
                    ),
                    const SizedBox(width: AppSpacing.x2),
                    Text(
                      'Unconfirmed match',
                      style: AppType.bodySm.copyWith(
                        color: AppColors.attentionFg,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.x3),
                    ConfidenceMeter(value: meta.confidence),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _metaLine(TitleMetadata? meta, Color accent) {
    final bits = <Widget>[];
    if (meta?.metaLine != null) {
      bits.add(
        Text(
          meta!.metaLine!,
          style: AppType.body.copyWith(color: AppColors.textSecondary),
        ),
      );
    }
    if (meta?.isTv ?? false) {
      bits.add(
        Text(
          'Series',
          style: AppType.body.copyWith(color: AppColors.textSecondary),
        ),
      );
    } else if (meta?.mediaType == 'movie') {
      bits.add(
        Text(
          'Movie',
          style: AppType.body.copyWith(color: AppColors.textSecondary),
        ),
      );
    }
    if (meta?.voteAverage != null && meta!.voteAverage! > 0) {
      bits.add(
        LtrIsland(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.star, size: 15, color: accent),
              const SizedBox(width: 2),
              Text(
                meta.voteAverage!.toStringAsFixed(1),
                style: AppType.monoTime.copyWith(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      );
    }
    if (bits.isEmpty) {
      return Text(
        p.extension(_entry.path).replaceFirst('.', '').toUpperCase(),
        style: AppType.body.copyWith(color: AppColors.textSecondary),
      );
    }
    return Wrap(
      spacing: AppSpacing.x3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: bits,
    );
  }

  Widget _subtitles(bool ready, EngineJob? job) {
    final sourceSub = _sourceSubtitle;
    final sibling = _siblingSidecar();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Subtitles', style: AppType.title),
            const SizedBox(width: AppSpacing.x3),
            _statusChip(ready, job),
          ],
        ),
        const SizedBox(height: AppSpacing.x4),
        Row(
          children: [
            Expanded(child: Text('Target language', style: AppType.body)),
            Text(_languageName(_lang), style: AppType.body),
          ],
        ),
        const SizedBox(height: AppSpacing.x4),
        Text(
          'Source',
          style: AppType.body.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.x2),
        SourcePicker<SourcePreference>(
          selected: _source,
          onChanged: (v) => setState(() => _source = v),
          options: [
            SourceOption(
              value: SourcePreference.auto,
              title: 'Auto source',
              tradeoff: sourceSub == null
                  ? 'Find original-language subtitles, then transcribe if none match.'
                  : 'Using ${sourceSub.providerName}; embedded subtitles still win unless manually swapped.',
              detail: sourceSub == null ? null : _sourceLang.toUpperCase(),
              recommended: true,
            ),
            const SourceOption(
              value: SourcePreference.asr,
              title: 'Transcribe the audio (ASR)',
              tradeoff:
                  'Skip online subtitle search; local embedded text can still win.',
            ),
            SourceOption(
              value: SourcePreference.embedded,
              title: 'Use sibling subtitle file',
              tradeoff: 'Use a subtitle file next to this video as the source.',
              detail: sibling,
              enabled: sibling != null,
              disabledReason:
                  'No ${_sourceLang.toUpperCase()} sibling subtitle found next to this file.',
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.x3),
        _sourceSubtitleTools(sourceSub),
        const SizedBox(height: AppSpacing.x5),
        Row(
          children: [
            FilledButton.icon(
              onPressed: job != null && job.isActive ? null : _generate,
              icon: Icon(
                ready ? Icons.refresh : Icons.subtitles_outlined,
                size: 18,
              ),
              label: Text(
                ready ? 'Re-generate subtitles' : 'Generate subtitles',
              ),
            ),
            if (ready) ...[
              const SizedBox(width: AppSpacing.x3),
              OutlinedButton.icon(
                onPressed: _editSubtitles,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit subtitles'),
              ),
            ],
            if (job != null && job.isActive) ...[
              const SizedBox(width: AppSpacing.x3),
              Text(
                _queueStatusText(job),
                style: AppType.body.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ],
        ),
      ],
    );
  }

  String _queueStatusText(EngineJob job) {
    if (job.state != 'running') return 'In the queue…';
    final t = widget.manager.timingFor(_entry.path);
    if (t == null) return 'Translating…';
    final elapsed = fmtElapsed(t.elapsed);
    return t.eta != null
        ? 'Translating — $elapsed · ${fmtEta(t.eta!)}'
        : 'Translating — $elapsed · estimating…';
  }

  Widget _sourceSubtitleTools(SourceSubtitleResult? source) {
    final text = source == null
        ? 'Original source: none cached'
        : [
            'Original source: ${source.providerName}',
            source.language.toUpperCase(),
            if (source.releaseName != null && source.releaseName!.isNotEmpty)
              p.basename(source.releaseName!),
            if (source.overrideEmbedded) 'override',
          ].join(' · ');

    return Wrap(
      spacing: AppSpacing.x2,
      runSpacing: AppSpacing.x2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                source == null
                    ? Icons.subtitles_off_outlined
                    : Icons.subtitles_outlined,
                size: 18,
                color: source == null
                    ? AppColors.textSecondary
                    : AppColors.amber,
              ),
              const SizedBox(width: AppSpacing.x2),
              Flexible(
                child: Text(
                  text,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.bodySm.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        OutlinedButton.icon(
          onPressed: _sourceBusy ? null : _refetchSourceSubtitle,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Refetch'),
        ),
        OutlinedButton.icon(
          onPressed: _sourceBusy ? null : _pickSourceSubtitleFile,
          icon: const Icon(Icons.upload_file, size: 18),
          label: const Text('File'),
        ),
        OutlinedButton.icon(
          onPressed: _sourceBusy ? null : _pasteSourceSubtitleUrl,
          icon: const Icon(Icons.link, size: 18),
          label: const Text('URL'),
        ),
      ],
    );
  }

  Widget _posterPlaceholder() => const ColoredBox(
    color: AppColors.neutral850,
    child: Icon(Icons.movie_outlined, size: 40, color: AppColors.neutral500),
  );

  Widget _statusChip(bool ready, EngineJob? job) {
    if (ready) {
      return const StatusChip(
        style: StatusStyles.ready,
        size: StatusChipSize.md,
      );
    }
    if (job != null) {
      return StatusChip.forState(
        job.state,
        progress: job.state == 'running' ? job.progress : null,
        size: StatusChipSize.md,
      );
    }
    return const StatusChip(
      style: StatusStyles.queued,
      label: 'Not generated',
      size: StatusChipSize.md,
    );
  }

  String _languageName(String code) => switch (code) {
    'he' => 'Hebrew',
    'ar' => 'Arabic',
    'es' => 'Spanish',
    'fr' => 'French',
    'de' => 'German',
    _ => code,
  };
}
