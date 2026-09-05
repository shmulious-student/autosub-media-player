// AppShell — the persistent macOS chrome (docs/design/SCREENS.md "Global chrome").
//
// A quiet left rail (Library · Queue · Settings) + content pane, with an engine
// health dot at the bottom. The rail is CHROME → LTR, *Directional insets
// (RTL.md §0). Queue carries a badge = active job count. Content is an IndexedStack
// so each destination keeps its scroll/state when you switch.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/engine_supervisor.dart';
import '../library/library_page.dart';
import '../library/library_store.dart';
import '../library/processing_manager.dart';
import '../metadata/metadata_store.dart';
import '../queue/queue_page.dart';
import '../settings/app_settings.dart';
import '../settings/settings_page.dart';
import '../ui/components/shortcuts_sheet.dart';
import '../ui/tokens.dart';

enum ShellDestination { library, queue, settings }

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.store,
    required this.manager,
    required this.metadata,
    required this.settings,
    required this.engine,
  });

  final LibraryStore store;
  final ProcessingManager manager;
  final MetadataStore metadata;
  final AppSettings settings;
  final EngineSupervisor engine;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  ShellDestination _selected = ShellDestination.library;

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  int get _activeJobs =>
      widget.manager.jobs.where((j) => j.isActive).length;

  void _go(ShellDestination d) => setState(() => _selected = d);

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            const _GoSettingsIntent(),
        const SingleActivator(LogicalKeyboardKey.slash, meta: true):
            const _ShortcutsIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _GoSettingsIntent: CallbackAction<_GoSettingsIntent>(
            onInvoke: (_) {
              _go(ShellDestination.settings);
              return null;
            },
          ),
          _ShortcutsIntent: CallbackAction<_ShortcutsIntent>(
            onInvoke: (_) {
              showShortcutsSheet(context);
              return null;
            },
          ),
        },
        child: Scaffold(
          body: Row(
            children: [
              _Rail(
                selected: _selected,
                activeJobs: _activeJobs,
                engineOnline: widget.manager.engineOnline,
                onSelect: _go,
              ),
              const VerticalDivider(width: 1, color: AppColors.hairline),
              Expanded(
                child: IndexedStack(
                  index: _selected.index,
                  children: [
                    LibraryPage(
                      store: widget.store,
                      manager: widget.manager,
                      metadata: widget.metadata,
                      settings: widget.settings,
                    ),
                    QueuePage(store: widget.store, manager: widget.manager),
                    SettingsPage(
                      store: widget.store,
                      manager: widget.manager,
                      settings: widget.settings,
                      metadata: widget.metadata,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoSettingsIntent extends Intent {
  const _GoSettingsIntent();
}

class _ShortcutsIntent extends Intent {
  const _ShortcutsIntent();
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.selected,
    required this.activeJobs,
    required this.engineOnline,
    required this.onSelect,
  });

  final ShellDestination selected;
  final int activeJobs;
  final bool engineOnline;
  final ValueChanged<ShellDestination> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      color: AppColors.neutral900,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppSpacing.x12), // clear the native title bar
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpacing.x5, AppSpacing.x2, AppSpacing.x5, AppSpacing.x6),
            child: Text('AutoSub',
                style: AppType.title.copyWith(color: AppColors.textHighEmphasis)),
          ),
          _RailItem(
            icon: Icons.video_library_outlined,
            selectedIcon: Icons.video_library,
            label: 'Library',
            selected: selected == ShellDestination.library,
            onTap: () => onSelect(ShellDestination.library),
          ),
          _RailItem(
            icon: Icons.playlist_play_outlined,
            selectedIcon: Icons.playlist_play,
            label: 'Queue',
            badge: activeJobs > 0 ? '$activeJobs' : null,
            selected: selected == ShellDestination.queue,
            onTap: () => onSelect(ShellDestination.queue),
          ),
          _RailItem(
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            label: 'Settings',
            selected: selected == ShellDestination.settings,
            onTap: () => onSelect(ShellDestination.settings),
          ),
          const Spacer(),
          const Divider(height: 1, color: AppColors.hairline),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.x4),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: engineOnline
                        ? AppColors.readyFg
                        : AppColors.attentionFg,
                  ),
                ),
                const SizedBox(width: AppSpacing.x2),
                Text(
                  engineOnline ? 'Engine online' : 'Engine offline',
                  style: AppType.bodySm.copyWith(color: AppColors.textSecondary),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Keyboard shortcuts (⌘/)',
                  onPressed: () => showShortcutsSheet(context),
                  icon: const Icon(Icons.keyboard_outlined, size: 18),
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.amber : AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(
          horizontal: AppSpacing.x3, vertical: AppSpacing.x0_5),
      child: Material(
        color: selected ? AppColors.amberSubtle : Colors.transparent,
        borderRadius: const BorderRadius.all(AppRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: const BorderRadius.all(AppRadius.md),
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(
                horizontal: AppSpacing.x3, vertical: AppSpacing.x3),
            child: Row(
              children: [
                Icon(selected ? selectedIcon : icon, size: 20, color: fg),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: Text(
                    label,
                    style: AppType.body.copyWith(
                      color: selected ? AppColors.textHighEmphasis : fg,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (badge != null) _Badge(badge!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.symmetric(
          horizontal: AppSpacing.x2, vertical: 1),
      decoration: const BoxDecoration(
        color: AppColors.runningTint,
        borderRadius: BorderRadius.all(AppRadius.full),
      ),
      child: Text(text,
          style: AppType.label.copyWith(color: AppColors.runningFg)),
    );
  }
}
