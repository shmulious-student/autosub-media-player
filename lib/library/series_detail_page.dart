// SeriesDetailPage — the "main subject" view for a series: official poster + show
// metadata up top (palette-tinted like the movie detail), then the seasons, each
// collapsible into its episode rows (SCREENS §3 episode list). Every level — series,
// season, episode — has a right-click menu to play / prioritize / preempt / generate.

import 'dart:io';

import 'package:flutter/material.dart';

import '../metadata/fix_match_dialog.dart';
import '../metadata/metadata_store.dart';
import '../metadata/title_metadata.dart';
import '../player/player_page.dart';
import '../settings/app_settings.dart';
import '../subtitle/subtitle_editor_page.dart';
import '../ui/bidi.dart';
import '../ui/components/characters_section.dart';
import '../ui/components/item_menu.dart';
import '../ui/components/status_chip.dart';
import '../ui/components/toast.dart';
import '../ui/tokens.dart';
import 'entry_status.dart';
import 'library_grouping.dart';
import 'library_store.dart';
import 'processing_manager.dart';
import 'title_detail_page.dart';

class SeriesDetailPage extends StatefulWidget {
  const SeriesDetailPage({
    super.key,
    required this.seriesKey,
    required this.store,
    required this.manager,
    required this.metadata,
    required this.settings,
  });

  final String seriesKey;
  final LibraryStore store;
  final ProcessingManager manager;
  final MetadataStore metadata;
  final AppSettings settings;

  @override
  State<SeriesDetailPage> createState() => _SeriesDetailPageState();
}

class _SeriesDetailPageState extends State<SeriesDetailPage> {
  String get _lang => widget.settings.targetLanguage;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onChange);
    widget.manager.addListener(_onChange);
    widget.metadata.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.store.removeListener(_onChange);
    widget.manager.removeListener(_onChange);
    widget.metadata.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _refetchSeriesMetadata(LibraryGroup g) async {
    showToast(context, 'Refetching metadata for ${g.entries.length} episodes…');
    await widget.metadata.refetchAll(g.entries.map((e) => e.path));
    if (mounted) {
      showToast(context, 'Metadata refetched.', variant: ToastVariant.success);
    }
  }

  LibraryGroup? get _group {
    for (final g in groupLibrary(widget.store.entries, widget.metadata)) {
      if (g.key == widget.seriesKey) return g;
    }
    return null;
  }

  void _playEpisode(LibraryEntry e) {
    final sub = e.hasSidecar(_lang) ? e.sidecarPath(_lang) : null;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          videoPath: e.path,
          subtitlePath: sub,
          title: e.displayTitle,
          autoPlay: true,
          settings: widget.settings,
          manager: widget.manager,
        ),
      ),
    );
  }

  void _openEpisode(LibraryEntry e) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TitleDetailPage(
          entry: e,
          store: widget.store,
          manager: widget.manager,
          metadata: widget.metadata,
          settings: widget.settings,
        ),
      ),
    );
  }

  void _editEpisode(LibraryEntry e) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SubtitleEditorPage(
        sidecarPath: e.sidecarPath(_lang),
        title: e.displayTitle,
        targetLang: _lang,
        maxCps: widget.settings.readingSpeedCps,
      ),
    ));
  }

  void _menu(
    List<LibraryEntry> entries,
    String scopeNoun,
    Offset pos, {
    VoidCallback? onPlay,
    VoidCallback? onOpen,
    VoidCallback? onEdit,
  }) {
    showItemMenu(
      context,
      position: pos,
      manager: widget.manager,
      metadata: widget.metadata,
      store: widget.store,
      lang: _lang,
      entries: entries,
      scopeNoun: scopeNoun,
      onPlay: onPlay,
      onOpen: onOpen,
      onEdit: onEdit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = _group;
    if (g == null) {
      // Series was emptied (all episodes removed) — go back.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const Scaffold(backgroundColor: AppColors.neutral950);
    }
    final meta = g.meta;
    final tint = meta?.dominant ?? AppColors.neutral900;
    final accent = meta?.accent ?? AppColors.amber;
    final seasons = groupSeasons(g, widget.metadata);

    return Scaffold(
      backgroundColor: AppColors.neutral950,
      body: Stack(
        children: [
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
                  stops: const [0.0, 0.3, 0.6],
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
                          _hero(g, meta, accent),
                          const SizedBox(height: AppSpacing.x6),
                          const Divider(height: 1, color: AppColors.hairline),
                          const SizedBox(height: AppSpacing.x4),
                          for (final s in seasons) _season(g, s),
                          const SizedBox(height: AppSpacing.x6),
                          const Divider(height: 1, color: AppColors.hairline),
                          const SizedBox(height: AppSpacing.x6),
                          CharactersSection(
                            metadata: widget.metadata,
                            manager: widget.manager,
                            path: g.representative.path,
                          ),
                          const SizedBox(height: AppSpacing.x12),
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

  Widget _hero(LibraryGroup g, TitleMetadata? meta, Color accent) {
    final st = aggregateStatus(g.entries, widget.manager, _lang);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
              child: (g.posterFile != null)
                  ? Image.file(
                      File(g.posterFile!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _posterPh(),
                    )
                  : _posterPh(),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.x5),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AutoDirText(g.title, style: AppType.titleLg),
              const SizedBox(height: AppSpacing.x2),
              Row(
                children: [
                  Text(
                    [
                      'Series',
                      if (g.year != null) '${g.year}',
                      '${g.count} episode${g.count == 1 ? '' : 's'}',
                    ].join(' · '),
                    style: AppType.body.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (st.style != null) ...[
                    const SizedBox(width: AppSpacing.x3),
                    StatusChip(
                      style: st.style!,
                      label: st.label,
                      size: StatusChipSize.sm,
                    ),
                  ],
                ],
              ),
              if (meta?.overview != null && meta!.overview!.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.x3),
                AutoDirText(
                  meta.overview!,
                  style: AppType.body.copyWith(color: AppColors.textSecondary),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: AppSpacing.x5),
              Wrap(
                spacing: AppSpacing.x3,
                runSpacing: AppSpacing.x3,
                children: [
                  FilledButton.icon(
                    onPressed: () => widget.manager.generateAll(
                      g.entries.map((e) => e.path).toList(),
                    ),
                    icon: const Icon(Icons.subtitles_outlined, size: 18),
                    label: const Text('Translate all'),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.metadata.hasApiKey
                        ? () => showFixMatchDialog(
                            context,
                            metadata: widget.metadata,
                            path: g.representative.path,
                            initialQuery: g.title,
                            currentTmdbId: meta?.tmdbId,
                          )
                        : null,
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('Fix match'),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.metadata.hasApiKey
                        ? () => _refetchSeriesMetadata(g)
                        : null,
                    icon: const Icon(Icons.cloud_sync_outlined, size: 18),
                    label: const Text('Refetch metadata'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _season(LibraryGroup series, SeasonGroup s) {
    final st = aggregateStatus(s.episodes, widget.manager, _lang);
    return Theme(
      // Strip the ExpansionTile dividers; we draw our own hairlines.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: GestureDetector(
        onSecondaryTapDown: (d) =>
            _menu(s.episodes, 'season', d.globalPosition),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsetsDirectional.only(
            bottom: AppSpacing.x3,
          ),
          title: Row(
            children: [
              Text(s.label, style: AppType.title),
              const SizedBox(width: AppSpacing.x3),
              if (st.style != null)
                StatusChip(style: st.style!, label: st.label),
              const Spacer(),
              Builder(
                builder: (btnContext) => IconButton(
                  tooltip: 'Season actions',
                  icon: const Icon(Icons.more_horiz, size: 20),
                  onPressed: () {
                    final box = btnContext.findRenderObject() as RenderBox;
                    _menu(
                      s.episodes,
                      'season',
                      box.localToGlobal(box.size.center(Offset.zero)),
                    );
                  },
                ),
              ),
            ],
          ),
          children: [for (final e in s.episodes) _episodeRow(e)],
        ),
      ),
    );
  }

  Widget _episodeRow(LibraryEntry e) {
    final st = entryStatus(e, widget.manager, _lang);
    final num = episodeNumberOf(e, widget.metadata);
    final label = num.episode != null
        ? 'Episode ${num.episode}'
        : e.displayTitle;
    return GestureDetector(
      onSecondaryTapDown: (d) => _menu(
        [e],
        'episode',
        d.globalPosition,
        onPlay: () => _playEpisode(e),
        onOpen: () => _openEpisode(e),
        onEdit: () => _editEpisode(e),
      ),
      child: InkWell(
        onTap: () => _openEpisode(e),
        child: Container(
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: AppSpacing.x3,
            vertical: AppSpacing.x3,
          ),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.hairline)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.play_circle_outline,
                size: 20,
                color: AppColors.neutral500,
              ),
              const SizedBox(width: AppSpacing.x3),
              Expanded(child: Text(label, style: AppType.body)),
              if (st.style != null)
                StatusChip(
                  style: st.style!,
                  label: st.label,
                  progress: st.progress,
                )
              else
                const StatusChip(style: StatusStyles.ready),
              Builder(
                builder: (btnContext) => IconButton(
                  tooltip: 'Episode actions',
                  icon: const Icon(Icons.more_horiz, size: 20),
                  onPressed: () {
                    final box = btnContext.findRenderObject() as RenderBox;
                    _menu(
                      [e],
                      'episode',
                      box.localToGlobal(box.size.center(Offset.zero)),
                      onPlay: () => _playEpisode(e),
                      onOpen: () => _openEpisode(e),
                      onEdit: () => _editEpisode(e),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _posterPh() => const ColoredBox(
    color: AppColors.neutral850,
    child: Icon(Icons.movie_outlined, size: 40, color: AppColors.neutral500),
  );
}
