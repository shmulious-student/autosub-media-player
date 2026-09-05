// SubtitleLineRow + CPSMeter (docs/design/COMPONENTS.md §SubtitleLineRow, RTL.md §7).
//
// One cue in the subtitle editor: a pinned-LTR timecode/CPS strip beside an RTL
// text field whose direction follows the value. The CPSMeter gauges reading speed
// against the Hebrew-tuned target — green within budget, amber near the limit, red
// over (too fast to read). Editing marks the line; timecode + CPS never mirror.

import 'package:flutter/material.dart';

import '../bidi.dart';
import '../tokens.dart';
import 'progress.dart';

class CPSMeter extends StatelessWidget {
  const CPSMeter({super.key, required this.cps, required this.max});

  final double cps;
  final int max;

  @override
  Widget build(BuildContext context) {
    final ratio = max == 0 ? 0.0 : (cps / max);
    final over = cps > max;
    final near = !over && ratio >= 0.85;
    final color = over
        ? AppColors.failedFg
        : near
            ? AppColors.attentionFg
            : AppColors.readyFg;

    return LtrIsland(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(over ? Icons.speed : Icons.timer_outlined,
              size: 14, color: color),
          const SizedBox(width: AppSpacing.x1),
          SizedBox(
            width: 56,
            child: AppProgressBar(
              value: ratio.clamp(0.0, 1.0),
              height: 4,
              fillColor: color,
            ),
          ),
          const SizedBox(width: AppSpacing.x2),
          Text('${cps.round()}/$max',
              style: AppType.monoTime.copyWith(color: color)),
        ],
      ),
    );
  }
}

class SubtitleLineRow extends StatelessWidget {
  const SubtitleLineRow({
    super.key,
    required this.index,
    required this.start,
    required this.end,
    required this.controller,
    required this.cps,
    required this.maxCps,
    required this.edited,
    required this.onChanged,
    this.onRetranslate,
    this.onFixTiming,
  });

  final int index;
  final String start;
  final String end;
  final TextEditingController controller;
  final double cps;
  final int maxCps;
  final bool edited;
  final ValueChanged<String> onChanged;

  /// Per-line AI re-translate. Null → the control renders disabled (the engine
  /// endpoint isn't wired yet — honest affordance, principle P6).
  final VoidCallback? onRetranslate;

  /// Apply the suggested timing fix (extend the cue to read within budget). Only
  /// offered when the line is over-CPS and a fix is possible.
  final VoidCallback? onFixTiming;

  @override
  Widget build(BuildContext context) {
    final overCps = cps > maxCps;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.x4, vertical: AppSpacing.x3),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pinned-LTR strip: index · timecode · CPS.
          LtrIsland(
            child: Row(
              children: [
                Text('#$index',
                    style: AppType.monoTime
                        .copyWith(color: AppColors.neutral500)),
                const SizedBox(width: AppSpacing.x3),
                Text('$start → $end',
                    style: AppType.monoTime
                        .copyWith(color: AppColors.textSecondary)),
                const Spacer(),
                CPSMeter(cps: cps, max: maxCps),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // RTL text field — direction follows the value (RTL.md §7.1).
              Expanded(
                child: _DirAwareField(
                  controller: controller,
                  onChanged: onChanged,
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              if (edited)
                const Padding(
                  padding: EdgeInsets.only(top: AppSpacing.x2),
                  child: Tooltip(
                    message: 'Edited',
                    child: Icon(Icons.edit, size: 14, color: AppColors.amber),
                  ),
                ),
              Tooltip(
                message: onRetranslate == null
                    ? 'Re-translate needs the engine'
                    : 'Re-translate this line (⌘R)',
                child: IconButton(
                  onPressed: onRetranslate,
                  icon: const Icon(Icons.autorenew, size: 18),
                  color: AppColors.textSecondary,
                  disabledColor: AppColors.neutral700,
                ),
              ),
            ],
          ),
          if (overCps) ...[
            const SizedBox(height: AppSpacing.x1),
            Row(
              children: [
                const Icon(Icons.warning_amber,
                    size: 14, color: AppColors.failedFg),
                const SizedBox(width: AppSpacing.x1),
                Text('Reads too fast — shorten text or extend timing',
                    style: AppType.bodySm.copyWith(color: AppColors.failedFg)),
                if (onFixTiming != null) ...[
                  const SizedBox(width: AppSpacing.x2),
                  _FixTimingButton(onTap: onFixTiming!),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A compact "extend timing to fit" action shown beside the over-CPS warning.
class _FixTimingButton extends StatelessWidget {
  const _FixTimingButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(AppRadius.sm),
      child: Container(
        padding: const EdgeInsetsDirectional.symmetric(
            horizontal: AppSpacing.x2, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.attentionTint,
          borderRadius: const BorderRadius.all(AppRadius.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_fix_high,
                size: 13, color: AppColors.attentionFg),
            const SizedBox(width: AppSpacing.x1),
            Text('Fix timing',
                style: AppType.label.copyWith(color: AppColors.attentionFg)),
          ],
        ),
      ),
    );
  }
}

/// A text field whose direction tracks the first strong char of its value, with
/// a small debounce so the caret doesn't jump on the first keystroke (RTL.md §7.1).
class _DirAwareField extends StatelessWidget {
  const _DirAwareField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final dir = directionOf(controller.text, fallback: TextDirection.rtl);
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textDirection: dir,
      textAlign: dir == TextDirection.rtl ? TextAlign.right : TextAlign.left,
      maxLines: null,
      style: AppType.body,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(
            horizontal: AppSpacing.x3, vertical: AppSpacing.x2),
      ),
    );
  }
}
