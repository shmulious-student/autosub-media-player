// TmdbMatchRow (docs/design/COMPONENTS.md §TmdbMatchRow).
//
// A search result in the "Fix match" flow: poster thumb · title (year) · type ·
// rating, with Select / Current. Used to reassign a title's TMDB match so its
// poster + metadata are the genuine, official ones for the production.

import 'package:flutter/material.dart';

import '../bidi.dart';
import '../tokens.dart';

class TmdbMatchRow extends StatelessWidget {
  const TmdbMatchRow({
    super.key,
    required this.name,
    required this.year,
    required this.mediaType, // 'movie' | 'tv'
    required this.posterUrl,
    required this.voteAverage,
    required this.isCurrent,
    required this.onSelect,
    this.overview,
  });

  final String name;
  final int? year;
  final String mediaType;
  final String? posterUrl;
  final double? voteAverage;
  final bool isCurrent;
  final VoidCallback onSelect;
  final String? overview;

  @override
  Widget build(BuildContext context) {
    final typeLabel = mediaType == 'tv' ? 'TV Series' : 'Movie';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.x3),
      decoration: BoxDecoration(
        color: isCurrent ? AppColors.amberSubtle : Colors.transparent,
        borderRadius: const BorderRadius.all(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.all(AppRadius.sm),
            child: SizedBox(
              width: 40,
              height: 60,
              child: posterUrl != null
                  ? Image.network(posterUrl!,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const _Ph())
                  : const _Ph(),
            ),
          ),
          const SizedBox(width: AppSpacing.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AutoDirText(
                  '$name${year != null ? ' ($year)' : ''}',
                  style: AppType.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.x0_5),
                Row(
                  children: [
                    Text(typeLabel,
                        style: AppType.bodySm
                            .copyWith(color: AppColors.textSecondary)),
                    if (voteAverage != null && voteAverage! > 0) ...[
                      const SizedBox(width: AppSpacing.x2),
                      const Icon(Icons.star,
                          size: 13, color: AppColors.amber),
                      const SizedBox(width: 2),
                      LtrIsland(
                        child: Text(voteAverage!.toStringAsFixed(1),
                            style: AppType.monoTime
                                .copyWith(color: AppColors.textSecondary)),
                      ),
                    ],
                  ],
                ),
                if (overview != null && overview!.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.x1),
                  AutoDirText(
                    overview!,
                    style:
                        AppType.bodySm.copyWith(color: AppColors.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.x3),
          if (isCurrent)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.x2),
              child: Text('Current',
                  style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            )
          else
            OutlinedButton(onPressed: onSelect, child: const Text('Select')),
        ],
      ),
    );
  }
}

class _Ph extends StatelessWidget {
  const _Ph();
  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: AppColors.neutral800,
        child: Icon(Icons.movie_outlined, size: 18, color: AppColors.neutral500),
      );
}
