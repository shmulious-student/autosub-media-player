// ModelDownloadRow (docs/design/COMPONENTS.md §ModelDownloadRow).
//
// One model file's status — the highest-trust moment (DS §7). Supports the full
// lifecycle (downloading/verifying/ready) for when the in-app downloader lands;
// the first-run wizard currently drives it with present/missing (a real local
// check). Progress is pinned LTR.

import 'package:flutter/material.dart';

import '../bidi.dart';
import '../tokens.dart';
import 'progress.dart';
import 'status_chip.dart';

enum ModelRowState { present, missing, downloading, verifying, ready, failed }

class ModelDownloadRow extends StatelessWidget {
  const ModelDownloadRow({
    super.key,
    required this.name,
    required this.size,
    required this.purpose,
    required this.state,
    this.progress,
    this.detail,
  });

  final String name;
  final String size;
  final String purpose;
  final ModelRowState state;
  final double? progress;

  /// Speed/ETA line while downloading, e.g. "340 MB/s · ~4s".
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x4, vertical: AppSpacing.x3),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(name, style: AppType.body),
                    Text('  ·  ',
                        style: AppType.bodySm
                            .copyWith(color: AppColors.neutral500)),
                    LtrIsland(
                      child: Text(size,
                          style: AppType.bodySm
                              .copyWith(color: AppColors.textSecondary)),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.x0_5),
                if (state == ModelRowState.downloading) ...[
                  SizedBox(
                    width: 220,
                    child: AppProgressBar(
                      value: progress,
                      height: 4,
                      fillColor: AppColors.amber,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: AppSpacing.x0_5),
                    LtrIsland(
                      child: Text(detail!,
                          style: AppType.bodySm
                              .copyWith(color: AppColors.textSecondary)),
                    ),
                  ],
                ] else
                  Text(purpose,
                      style: AppType.bodySm
                          .copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.x3),
          _chip(),
        ],
      ),
    );
  }

  Widget _chip() {
    switch (state) {
      case ModelRowState.present:
        return const StatusChip(
            style: StatusStyles.ready,
            label: 'Downloaded',
            size: StatusChipSize.md);
      case ModelRowState.ready:
        return const StatusChip(
            style: StatusStyles.ready, size: StatusChipSize.md);
      case ModelRowState.missing:
        return const StatusChip(
            style: StatusStyles.queued,
            label: 'Not downloaded',
            size: StatusChipSize.md);
      case ModelRowState.downloading:
        return const StatusChip(
            style: StatusStyles.running,
            label: 'Downloading',
            size: StatusChipSize.md);
      case ModelRowState.verifying:
        return const StatusChip(
            style: StatusStyles.running,
            label: 'Verifying checksum',
            size: StatusChipSize.md);
      case ModelRowState.failed:
        return const StatusChip(
            style: StatusStyles.failed, size: StatusChipSize.md);
    }
  }
}
