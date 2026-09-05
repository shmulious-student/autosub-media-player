// TitleCard / TitleRow (docs/design/COMPONENTS.md §TitleCard, §TitleRow).
//
// The library grid + list units. Poster-forward and calm (principle P3): ready
// titles show NO chip; only queued/running/failed/needs-match get one. Artwork
// bleeds to the card edge; metadata sits below (never overlaid — overlays fight
// RTL text). Until TMDB artwork is wired, the poster shows the "no artwork"
// film-strip placeholder state.

import 'dart:io';

import 'package:flutter/material.dart';

import '../bidi.dart';
import '../tokens.dart';
import 'status_chip.dart';

/// View-data for a library unit — decoupled from the app's storage models so the
/// card is a pure, shared (Mac+iOS) display component.
class TitleCardData {
  const TitleCardData({
    required this.title,
    this.subtitle,
    this.posterFile,
    this.status,
    this.statusLabel,
    this.progress,
    this.watchProgress,
    this.watched = false,
  });

  final String title;
  final String? subtitle;

  /// Local path to the cached official poster (TMDB). Null → film-strip placeholder.
  final String? posterFile;

  /// Null = ready/calm (no chip). Otherwise the status drives the overlay chip.
  final StatusStyle? status;
  final String? statusLabel;
  final double? progress;

  /// 0..1 resume position → thin amber bar across the poster bottom.
  final double? watchProgress;
  final bool watched;
}

class TitleCard extends StatefulWidget {
  const TitleCard({
    super.key,
    required this.data,
    required this.onTap,
    this.onContextMenu,
  });

  final TitleCardData data;
  final VoidCallback onTap;

  /// Right-click: invoked with the global pointer position so the caller can
  /// anchor a context menu there.
  final void Function(Offset globalPosition)? onContextMenu;

  @override
  State<TitleCard> createState() => _TitleCardState();
}

class _TitleCardState extends State<TitleCard> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final spoken =
        '${d.title}${d.subtitle != null ? ', ${d.subtitle}' : ''}, ${d.status?.spoken ?? 'Ready'}';

    final ring = _focus
        ? Border.all(color: AppColors.focusRing, width: 2)
        : _hover
            ? Border.all(color: AppColors.neutral700, width: 1)
            : null;

    return Semantics(
      label: spoken,
      button: true,
      child: FocusableActionDetector(
        onShowHoverHighlight: (h) => setState(() => _hover = h),
        onShowFocusHighlight: (f) => setState(() => _focus = f),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapDown: widget.onContextMenu == null
              ? null
              : (d) => widget.onContextMenu!(d.globalPosition),
          child: AnimatedContainer(
            duration: AppMotion.resolve(context, AppMotion.base),
            curve: AppMotion.curveOut,
            transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Poster, radius/lg, bleeds to edge. Flexes to fill the grid
                // cell (the cell aspect ratio keeps it ~2:3) so the card can
                // never overflow when metadata lines or text scaling grow.
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.neutral850,
                      borderRadius: const BorderRadius.all(AppRadius.lg),
                      border: ring,
                      boxShadow: _hover ? AppElevation.e1 : null,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (d.posterFile != null)
                          Image.file(
                            File(d.posterFile!),
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => const _PosterPlaceholder(),
                          )
                        else
                          const _PosterPlaceholder(),
                        if (d.watched)
                          const PositionedDirectional(
                            top: AppSpacing.x2,
                            start: AppSpacing.x2,
                            child: _WatchedPip(),
                          ),
                        if (d.status != null)
                          PositionedDirectional(
                            top: AppSpacing.x2,
                            end: AppSpacing.x2,
                            child: StatusChip(
                              style: d.status!,
                              label: d.statusLabel,
                              progress: d.progress,
                            ),
                          ),
                        if (d.watchProgress != null)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LinearProgressIndicator(
                              value: d.watchProgress,
                              minHeight: 3,
                              backgroundColor: Colors.transparent,
                              valueColor: const AlwaysStoppedAnimation(
                                  AppColors.amber),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.x2),
                AutoDirText(
                  d.title,
                  style: AppType.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (d.subtitle != null)
                  AutoDirText(
                    d.subtitle!,
                    style:
                        AppType.bodySm.copyWith(color: AppColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PosterPlaceholder extends StatelessWidget {
  const _PosterPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: AppColors.neutral850,
        child: Center(
          child: Icon(Icons.movie_outlined,
              size: 40, color: AppColors.neutral500),
        ),
      );
}

class _WatchedPip extends StatelessWidget {
  const _WatchedPip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: const BoxDecoration(
        color: AppColors.scrim,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.check, size: 14, color: AppColors.readyFg),
    );
  }
}

/// The list-view unit — same data, horizontal (COMPONENTS §TitleRow).
class TitleRow extends StatelessWidget {
  const TitleRow({
    super.key,
    required this.data,
    required this.onTap,
    this.trailing,
    this.sourceLabel,
  });

  final TitleCardData data;
  final VoidCallback onTap;
  final Widget? trailing;
  final String? sourceLabel;

  @override
  Widget build(BuildContext context) {
    final d = data;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsetsDirectional.symmetric(
            horizontal: AppSpacing.x4, vertical: AppSpacing.x3),
        decoration: BoxDecoration(
          border: d.status == StatusStyles.failed
              ? const BorderDirectional(
                  start: BorderSide(color: AppColors.failedFg, width: 3))
              : null,
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.all(AppRadius.sm),
              child: SizedBox(
                width: 44,
                height: 64,
                child: d.posterFile != null
                    ? Image.file(
                        File(d.posterFile!),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const _PosterPlaceholder(),
                      )
                    : const _PosterPlaceholder(),
              ),
            ),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AutoDirText(
                    d.title,
                    style: AppType.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (d.subtitle != null || sourceLabel != null)
                    Text(
                      [d.subtitle, sourceLabel]
                          .where((e) => e != null)
                          .join(' · '),
                      style: AppType.bodySm
                          .copyWith(color: AppColors.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.x3),
            if (d.status != null)
              StatusChip(
                style: d.status!,
                label: d.statusLabel,
                progress: d.progress,
                size: StatusChipSize.md,
              )
            else
              const StatusChip(
                  style: StatusStyles.ready, size: StatusChipSize.md),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.x2),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
