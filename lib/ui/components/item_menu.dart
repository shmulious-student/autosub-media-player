// Item context menu — the right-click menu shared by library cards and the
// season/episode rows (SPEC §4 queue control). Actions are scoped to a set of
// entries: a single movie/episode, a whole season, or an entire series.
//
//  - Translate next  → prioritize: the selection jumps to the front of the queue.
//  - Translate now   → preempt: stop whatever's running and start the selection.
//  - Generate        → enqueue the selection (re-generate if already done).
//  - Play / Open / Remove as applicable.

import 'package:flutter/material.dart';

import '../../library/library_store.dart';
import '../../library/processing_manager.dart';
import '../../metadata/metadata_store.dart';
import '../tokens.dart';
import 'toast.dart';

/// Show the item menu at [position] (global coordinates) for [entries].
/// [scopeNoun] is "movie" | "series" | "season" | "episode" for the labels.
Future<void> showItemMenu(
  BuildContext context, {
  required Offset position,
  required ProcessingManager manager,
  required MetadataStore metadata,
  required LibraryStore store,
  required String lang,
  required List<LibraryEntry> entries,
  required String scopeNoun,
  VoidCallback? onPlay,
  VoidCallback? onOpen,
  VoidCallback? onEdit,
}) async {
  if (entries.isEmpty) return;
  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  final allReady = entries.every((e) => e.hasSidecar(lang));
  final pendingCount = entries.where((e) => !e.hasSidecar(lang)).length;

  final selected = await showMenu<String>(
    context: context,
    color: AppColors.neutral850,
    position: RelativeRect.fromRect(
      position & const Size(40, 40),
      Offset.zero & overlay.size,
    ),
    items: [
      if (onPlay != null)
        const PopupMenuItem(value: 'play', child: _MenuItem(Icons.play_arrow, 'Play')),
      if (onOpen != null)
        const PopupMenuItem(value: 'open', child: _MenuItem(Icons.info_outline, 'Open details')),
      if (onEdit != null && allReady)
        const PopupMenuItem(
            value: 'edit', child: _MenuItem(Icons.edit_outlined, 'Edit subtitles')),
      if (onPlay != null || onOpen != null || (onEdit != null && allReady))
        const PopupMenuDivider(),
      PopupMenuItem(
        value: 'next',
        child: _MenuItem(Icons.vertical_align_top, 'Translate $scopeNoun next'),
      ),
      PopupMenuItem(
        value: 'now',
        child:
            _MenuItem(Icons.bolt, 'Translate $scopeNoun now (stop others)'),
      ),
      PopupMenuItem(
        value: 'gen',
        child: _MenuItem(allReady ? Icons.refresh : Icons.subtitles_outlined,
            allReady ? 'Re-generate subtitles' : 'Generate subtitles'),
      ),
      const PopupMenuDivider(),
      if (metadata.hasApiKey)
        PopupMenuItem(
          value: 'refetch',
          child: _MenuItem(Icons.cloud_sync_outlined, 'Refetch metadata'),
        ),
      PopupMenuItem(
        value: 'remove',
        child: _MenuItem(Icons.delete_outline, 'Remove from library'),
      ),
    ],
  );

  if (selected == null || !context.mounted) return;
  final paths = entries.map((e) => e.path).toList();

  switch (selected) {
    case 'play':
      onPlay?.call();
    case 'open':
      onOpen?.call();
    case 'edit':
      onEdit?.call();
    case 'next':
      if (!manager.engineOnline) {
        showToast(context, 'Engine offline — can\'t reprioritize now.',
            variant: ToastVariant.attention);
        return;
      }
      // All already done → user wants a re-translation; force a fresh run.
      await manager.prioritize(paths, force: allReady);
      if (context.mounted) {
        showToast(context, 'Moved to the front of the queue.',
            variant: ToastVariant.success);
      }
    case 'now':
      if (!manager.engineOnline) {
        showToast(context, 'Engine offline — can\'t start translation now.',
            variant: ToastVariant.attention);
        return;
      }
      await manager.prioritize(paths, preempt: true, force: allReady);
      if (context.mounted) {
        showToast(context, 'Translating now — other jobs paused.',
            variant: ToastVariant.success);
      }
    case 'gen':
      if (!manager.engineOnline) {
        showToast(context, 'Engine offline — translation is paused.',
            variant: ToastVariant.attention);
        return;
      }
      // Re-generate when everything's already done; otherwise fill in the gaps.
      await manager.generateAll(paths, force: allReady);
      if (context.mounted) {
        final n = allReady ? paths.length : pendingCount;
        showToast(context, 'Added $n to the queue.',
            variant: ToastVariant.success);
      }
    case 'refetch':
      if (context.mounted) {
        showToast(context, 'Refetching metadata for $scopeNoun…');
      }
      await metadata.refetchAll(paths);
      if (context.mounted) {
        showToast(context, 'Metadata refetched.', variant: ToastVariant.success);
      }
    case 'remove':
      for (final p in paths) {
        await store.remove(p);
        metadata.forget(p);
      }
      if (context.mounted) showToast(context, 'Removed from library.');
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: AppColors.textSecondary),
        const SizedBox(width: AppSpacing.x3),
        Text(label, style: AppType.body),
      ],
    );
  }
}
