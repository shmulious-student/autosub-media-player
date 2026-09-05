// LibraryPage — the media hub (SPEC §1, SCREENS §2). Calm, poster-forward, and
// virtualized for tens of thousands of titles. Grid (default) + list views, a
// chrome toolbar (search · sort · filter · grid/list · add), the offline banner,
// and the empty state.
//
// File access goes through the system picker (SecureFiles → security-scoped
// bookmarks) so a sandboxed app keeps access to user-picked files/folders across
// launches (see lib/platform/secure_files.dart).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../metadata/metadata_store.dart';
import '../platform/secure_files.dart';
import '../player/player_page.dart';
import '../settings/app_settings.dart';
import '../ui/components/empty_state.dart';
import '../ui/components/item_menu.dart';
import '../ui/components/offline_banner.dart';
import '../ui/components/title_card.dart';
import '../ui/components/toast.dart';
import '../ui/tokens.dart';
import '../subtitle/subtitle_editor_page.dart';
import 'entry_status.dart';
import 'library_grouping.dart';
import 'library_store.dart';
import 'processing_manager.dart';
import 'series_detail_page.dart';
import 'title_detail_page.dart';

const List<String> _videoExts = [
  'mkv',
  'mp4',
  'mov',
  'm4v',
  'avi',
  'webm',
  'ts',
  'm2ts',
];

enum LibraryView { grid, list }

enum LibrarySort { recentlyAdded, title, status }

enum LibraryFilter { all, ready, inProgress, needsAttention }

extension on LibrarySort {
  String get label => switch (this) {
    LibrarySort.recentlyAdded => 'Recently added',
    LibrarySort.title => 'Title',
    LibrarySort.status => 'Status',
  };
}

extension on LibraryFilter {
  String get label => switch (this) {
    LibraryFilter.all => 'All',
    LibraryFilter.ready => 'Ready',
    LibraryFilter.inProgress => 'In progress',
    LibraryFilter.needsAttention => 'Needs attention',
  };
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.store,
    required this.manager,
    required this.metadata,
    required this.settings,
  });

  final LibraryStore store;
  final ProcessingManager manager;
  final MetadataStore metadata;
  final AppSettings settings;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  LibraryView _view = LibraryView.grid;
  LibrarySort _sort = LibrarySort.recentlyAdded;
  LibraryFilter _filter = LibraryFilter.all;
  String _query = '';
  final _searchFocus = FocusNode();
  final _searchController = TextEditingController();

  String get _lang => widget.settings.targetLanguage;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStoreOrSettings);
    widget.manager.addListener(_onChange);
    widget.metadata.addListener(_onChange);
    widget.settings.addListener(_onStoreOrSettings);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeSweep());
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreOrSettings);
    widget.manager.removeListener(_onChange);
    widget.metadata.removeListener(_onChange);
    widget.settings.removeListener(_onStoreOrSettings);
    _searchFocus.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  /// Library or settings changed — repaint and (if new titles / a freshly-pasted
  /// TMDB key) kick off metadata enrichment.
  void _onStoreOrSettings() {
    if (mounted) setState(() {});
    _maybeSweep();
  }

  /// Enrich any titles that haven't been searched yet (guarded against re-entry by
  /// the store itself). Names the network activity nowhere noisy — the toolbar
  /// shows a quiet "Fetching from TMDB…" while it runs.
  void _maybeSweep() {
    if (!widget.metadata.hasApiKey) return;
    final pending = widget.store.entries.map((e) => e.path).where((path) {
      final m = widget.metadata.metadataFor(path);
      return m == null || (!m.hasMatch && !m.searched);
    }).toList();
    if (pending.isEmpty) return;
    widget.metadata.sweep(pending);
  }

  // --- Data shaping -------------------------------------------------------

  LibraryFilter _bucketToFilter(StatusBucket b) => switch (b) {
    StatusBucket.ready => LibraryFilter.ready,
    StatusBucket.inProgress => LibraryFilter.inProgress,
    StatusBucket.needsAttention => LibraryFilter.needsAttention,
  };

  /// Aggregate status for a group (a single movie or a whole series).
  EntryStatus _groupStatus(LibraryGroup g) => g.isSeries
      ? aggregateStatus(g.entries, widget.manager, _lang)
      : entryStatus(g.representative, widget.manager, _lang);

  /// Map a group to a TitleCard + its filter bucket. Identity (poster, official
  /// name) comes from TMDB metadata; status from the job(s).
  ({TitleCardData card, LibraryFilter bucket}) _shapeGroup(LibraryGroup g) {
    final st = _groupStatus(g);
    final container = g.isSeries
        ? null
        : p
              .extension(g.representative.path)
              .replaceFirst('.', '')
              .toUpperCase();
    final subtitle = g.isSeries
        ? [
            if (g.year != null) '${g.year}',
            '${g.count} episode${g.count == 1 ? '' : 's'}',
          ].join(' · ')
        : (g.meta?.metaLine ?? container);

    return (
      card: TitleCardData(
        title: g.title,
        subtitle: subtitle,
        posterFile: g.posterFile,
        status: st.style,
        statusLabel: st.label,
        progress: st.progress,
      ),
      bucket: _bucketToFilter(st.bucket),
    );
  }

  List<LibraryGroup> get _visibleGroups {
    var groups = groupLibrary(widget.store.entries, widget.metadata);
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      groups = groups
          .where(
            (g) =>
                g.title.toLowerCase().contains(q) ||
                g.entries.any((e) => e.fileName.toLowerCase().contains(q)),
          )
          .toList();
    }
    if (_filter != LibraryFilter.all) {
      groups = groups.where((g) => _shapeGroup(g).bucket == _filter).toList();
    }
    switch (_sort) {
      case LibrarySort.recentlyAdded:
        groups.sort(
          (a, b) =>
              b.representative.addedAtMs.compareTo(a.representative.addedAtMs),
        );
      case LibrarySort.title:
        groups.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      case LibrarySort.status:
        int rank(LibraryGroup g) => switch (_shapeGroup(g).bucket) {
          LibraryFilter.needsAttention => 0,
          LibraryFilter.inProgress => 1,
          LibraryFilter.ready => 2,
          LibraryFilter.all => 3,
        };
        groups.sort((a, b) => rank(a).compareTo(rank(b)));
    }
    return groups;
  }

  // --- Actions ------------------------------------------------------------

  Future<void> _openFile() async {
    final picked = await const SecureFiles().pickFile();
    if (picked == null) return;
    final entry = await widget.store.add(
      picked.path,
      bookmark: picked.bookmark,
    );
    if (mounted) _play(entry);
  }

  Future<void> _addFolder() async {
    final picked = await const SecureFiles().pickFolder();
    if (picked == null) return;
    final videos = _scan(picked.path);
    for (final v in videos) {
      await widget.store.add(v, bookmark: picked.bookmark);
    }
    if (mounted && videos.isEmpty) {
      showToast(
        context,
        'No video files found in that folder.',
        variant: ToastVariant.attention,
      );
    }
  }

  List<String> _scan(String dir) {
    final out = <String>[];
    try {
      for (final e in Directory(
        dir,
      ).listSync(recursive: true, followLinks: false)) {
        if (e is File) {
          final ext = p.extension(e.path).replaceFirst('.', '').toLowerCase();
          if (_videoExts.contains(ext)) out.add(e.path);
        }
      }
    } catch (_) {
      // Permission/IO issues → skip silently.
    }
    out.sort();
    return out;
  }

  void _play(LibraryEntry entry) {
    final sub = entry.hasSidecar(_lang) ? entry.sidecarPath(_lang) : null;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          videoPath: entry.path,
          subtitlePath: sub,
          title: entry.displayTitle,
          autoPlay: true,
          settings: widget.settings,
        ),
      ),
    );
  }

  void _openDetail(LibraryEntry entry) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TitleDetailPage(
          entry: entry,
          store: widget.store,
          manager: widget.manager,
          metadata: widget.metadata,
          settings: widget.settings,
        ),
      ),
    );
  }

  /// Open a group: series → the season/episode browser; movie → title detail.
  void _openGroup(LibraryGroup g) {
    if (g.isSeries) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SeriesDetailPage(
            seriesKey: g.key,
            store: widget.store,
            manager: widget.manager,
            metadata: widget.metadata,
            settings: widget.settings,
          ),
        ),
      );
    } else {
      _openDetail(g.representative);
    }
  }

  /// Right-click menu for a library card (movie or whole series).
  void _groupMenu(LibraryGroup g, Offset position) {
    showItemMenu(
      context,
      position: position,
      manager: widget.manager,
      metadata: widget.metadata,
      store: widget.store,
      lang: _lang,
      entries: g.entries,
      scopeNoun: g.isSeries ? 'series' : 'movie',
      onPlay: g.isSeries ? null : () => _play(g.representative),
      onOpen: () => _openGroup(g),
      onEdit: g.isSeries ? null : () => _editEntry(g.representative),
    );
  }

  void _editEntry(LibraryEntry e) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SubtitleEditorPage(
        sidecarPath: e.sidecarPath(_lang),
        title: e.displayTitle,
        targetLang: _lang,
        maxCps: widget.settings.readingSpeedCps,
      ),
    ));
  }

  Future<void> _clearLibrary() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear library?'),
        content: const Text(
          'This removes all titles from the list. Your video files and any '
          'generated subtitle files are not deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok ?? false) {
      await widget.store.clear();
      await widget.manager.clearQueue();
      widget.metadata.clear();
      if (mounted) {
        showToast(context, 'Library and translation queue cleared.');
      }
    }
  }

  // --- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final groups = _visibleGroups;
    final isEmptyLibrary = widget.store.entries.isEmpty;

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true):
            const _OpenIntent(),
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true, shift: true):
            const _AddFolderIntent(),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            const _SearchIntent(),
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true):
            const _GridIntent(),
        const SingleActivator(LogicalKeyboardKey.digit2, meta: true):
            const _ListIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenIntent: CallbackAction<_OpenIntent>(
            onInvoke: (_) {
              _openFile();
              return null;
            },
          ),
          _AddFolderIntent: CallbackAction<_AddFolderIntent>(
            onInvoke: (_) {
              _addFolder();
              return null;
            },
          ),
          _SearchIntent: CallbackAction<_SearchIntent>(
            onInvoke: (_) {
              _searchFocus.requestFocus();
              return null;
            },
          ),
          _GridIntent: CallbackAction<_GridIntent>(
            onInvoke: (_) {
              setState(() => _view = LibraryView.grid);
              return null;
            },
          ),
          _ListIntent: CallbackAction<_ListIntent>(
            onInvoke: (_) {
              setState(() => _view = LibraryView.list);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: AppColors.neutral950,
            body: Column(
              children: [
                _toolbar(isEmptyLibrary),
                const Divider(height: 1, color: AppColors.hairline),
                if (!widget.manager.engineOnline)
                  OfflineBanner(onAction: () => widget.manager.reconnect()),
                Expanded(
                  child: isEmptyLibrary
                      ? _emptyLibrary()
                      : groups.isEmpty
                      ? _emptyFilter()
                      : (_view == LibraryView.grid
                            ? _grid(groups)
                            : _listView(groups)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar(bool isEmptyLibrary) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        AppSpacing.x6,
        AppSpacing.x12,
        AppSpacing.x6,
        AppSpacing.x4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Library', style: AppType.titleLg),
              if (widget.metadata.fetchingCount > 0) ...[
                const SizedBox(width: AppSpacing.x3),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppSpacing.x2),
                Text(
                  'Fetching from TMDB…',
                  style: AppType.bodySm.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.x4),
          // Reflows onto multiple lines on narrow windows (no overflow): the
          // search/sort/filter cluster and the action cluster wrap independently.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  spacing: AppSpacing.x2,
                  runSpacing: AppSpacing.x2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 240,
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocus,
                        onChanged: (v) => setState(() => _query = v),
                        style: AppType.body,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Search',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _query = '');
                                  },
                                ),
                        ),
                      ),
                    ),
                    _Dropdown<LibrarySort>(
                      value: _sort,
                      icon: Icons.sort,
                      items: LibrarySort.values,
                      labelOf: (s) => s.label,
                      onChanged: (v) => setState(() => _sort = v),
                    ),
                    _Dropdown<LibraryFilter>(
                      value: _filter,
                      icon: Icons.filter_list,
                      items: LibraryFilter.values,
                      labelOf: (f) => f.label,
                      onChanged: (v) => setState(() => _filter = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.x3),
              Wrap(
                spacing: AppSpacing.x2,
                runSpacing: AppSpacing.x2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _ViewToggle(
                    view: _view,
                    onChanged: (v) => setState(() => _view = v),
                  ),
                  OutlinedButton.icon(
                    onPressed: _addFolder,
                    icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                    label: const Text('Add folder'),
                  ),
                  FilledButton.icon(
                    onPressed: _openFile,
                    icon: const Icon(Icons.video_file_outlined, size: 18),
                    label: const Text('Open video'),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_horiz),
                    onSelected: (v) {
                      if (v == 'clear') _clearLibrary();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'clear',
                        enabled: !isEmptyLibrary,
                        child: const Text('Clear library…'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _grid(List<LibraryGroup> groups) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x6,
        AppSpacing.x4,
        AppSpacing.x6,
        AppSpacing.x12,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: AppSpacing.posterMaxExtent,
        mainAxisSpacing: AppSpacing.posterGap,
        crossAxisSpacing: AppSpacing.posterGap,
        childAspectRatio: 0.54, // poster (~2:3) + two metadata lines below
      ),
      itemCount: groups.length,
      itemBuilder: (context, i) {
        final g = groups[i];
        return RepaintBoundary(
          child: TitleCard(
            data: _shapeGroup(g).card,
            onTap: () => _openGroup(g),
            onContextMenu: (pos) => _groupMenu(g, pos),
          ),
        );
      },
    );
  }

  Widget _listView(List<LibraryGroup> groups) {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: AppSpacing.x12),
      itemCount: groups.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: AppColors.hairline),
      itemBuilder: (context, i) {
        final g = groups[i];
        return GestureDetector(
          onSecondaryTapDown: (d) => _groupMenu(g, d.globalPosition),
          child: TitleRow(
            data: _shapeGroup(g).card,
            onTap: () => _openGroup(g),
            sourceLabel: g.isSeries ? '${g.count} episodes' : null,
            trailing: Builder(
              builder: (btnContext) => IconButton(
                icon: const Icon(Icons.more_horiz, size: 20),
                tooltip: 'More',
                onPressed: () {
                  final box = btnContext.findRenderObject() as RenderBox;
                  final pos = box.localToGlobal(box.size.center(Offset.zero));
                  _groupMenu(g, pos);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _emptyLibrary() => EmptyState(
    icon: Icons.movie_outlined,
    title: 'Your library is empty.',
    message: 'Add a folder of videos or open a single file to get started.',
    actions: [
      FilledButton.icon(
        onPressed: _addFolder,
        icon: const Icon(Icons.create_new_folder_outlined, size: 18),
        label: const Text('Add a folder'),
      ),
      OutlinedButton.icon(
        onPressed: _openFile,
        icon: const Icon(Icons.video_file_outlined, size: 18),
        label: const Text('Open a video'),
      ),
    ],
  );

  Widget _emptyFilter() => const EmptyState(
    icon: Icons.search_off,
    title: 'No matches.',
    message: 'Try a different title, or change the filter.',
  );
}

// --- Toolbar widgets ------------------------------------------------------

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.icon,
    required this.items,
    required this.labelOf,
    required this.onChanged,
  });

  final T value;
  final IconData icon;
  final List<T> items;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsetsDirectional.only(start: AppSpacing.x3),
      decoration: BoxDecoration(
        color: AppColors.neutral800,
        borderRadius: const BorderRadius.all(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.x1),
          Flexible(
            child: DropdownButton<T>(
            value: value,
            isDense: true,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            borderRadius: const BorderRadius.all(AppRadius.md),
            dropdownColor: AppColors.neutral850,
            style: AppType.body,
            items: [
              for (final i in items)
                DropdownMenuItem(value: i, child: Text(labelOf(i))),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.view, required this.onChanged});
  final LibraryView view;
  final ValueChanged<LibraryView> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget seg(LibraryView v, IconData icon, String tip) {
      final on = v == view;
      return Tooltip(
        message: tip,
        child: InkWell(
          onTap: () => onChanged(v),
          borderRadius: const BorderRadius.all(AppRadius.sm),
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.x2),
            decoration: BoxDecoration(
              color: on ? AppColors.amberSubtle : Colors.transparent,
              borderRadius: const BorderRadius.all(AppRadius.sm),
            ),
            child: Icon(
              icon,
              size: 18,
              color: on ? AppColors.amber : AppColors.textSecondary,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.neutral800,
        borderRadius: const BorderRadius.all(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg(LibraryView.grid, Icons.grid_view, 'Grid (⌘1)'),
          seg(LibraryView.list, Icons.view_list, 'List (⌘2)'),
        ],
      ),
    );
  }
}

class _OpenIntent extends Intent {
  const _OpenIntent();
}

class _AddFolderIntent extends Intent {
  const _AddFolderIntent();
}

class _SearchIntent extends Intent {
  const _SearchIntent();
}

class _GridIntent extends Intent {
  const _GridIntent();
}

class _ListIntent extends Intent {
  const _ListIntent();
}
