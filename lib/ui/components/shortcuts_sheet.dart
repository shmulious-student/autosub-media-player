// ShortcutsSheet (docs/design/COMPONENTS.md §ShortcutsSheet, DESIGN_SYSTEM §6.4).
//
// The in-app ⌘/ keyboard-shortcut reference: grouped (Global · Player · Editing),
// keycaps + action. Keycaps are small neutral/800 radius/sm chips.

import 'package:flutter/material.dart';

import '../tokens.dart';

class _Shortcut {
  const _Shortcut(this.keys, this.action);
  final List<String> keys;
  final String action;
}

const _global = [
  _Shortcut(['⌘O'], 'Open a video'),
  _Shortcut(['⌘⇧O'], 'Add a folder'),
  _Shortcut(['⌘F'], 'Search the library'),
  _Shortcut(['⌘1', '⌘2'], 'Grid / list view'),
  _Shortcut(['⌘,'], 'Settings'),
  _Shortcut(['⌘/'], 'This shortcuts sheet'),
];

const _player = [
  _Shortcut(['Space', 'K'], 'Play / pause'),
  _Shortcut(['←', '→'], 'Seek ∓10s (never mirrored)'),
  _Shortcut(['↑', '↓'], 'Volume up / down'),
  _Shortcut(['S'], 'Toggle subtitles'),
  _Shortcut(['F'], 'Toggle fullscreen'),
  _Shortcut(['Esc'], 'Exit fullscreen'),
  _Shortcut(['Z', 'X'], 'Subtitle sync ∓50ms (precision)'),
  _Shortcut([',', '.'], 'Subtitle delay ∓100ms'),
  _Shortcut(['/'], 'Reset subtitle delay'),
  _Shortcut(['D'], 'Dual-language subtitles'),
  _Shortcut(['A'], 'Loop the current line'),
  _Shortcut(['⇧A'], 'Replay the current line once'),
];

const _editing = [
  _Shortcut(['⌘S'], 'Save edits'),
  _Shortcut(['⌘Z', '⌘⇧Z'], 'Undo / redo'),
  _Shortcut(['⌘R'], 'Re-translate current line'),
  _Shortcut(['⌘↵'], 'Commit line, go to next'),
];

Future<void> showShortcutsSheet(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: AppColors.neutral850,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.x6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: const [
              Text('Keyboard shortcuts', style: AppType.title),
              SizedBox(height: AppSpacing.x5),
              _Group('Global', _global),
              SizedBox(height: AppSpacing.x5),
              _Group('Player', _player),
              SizedBox(height: AppSpacing.x5),
              _Group('Editing', _editing),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Group extends StatelessWidget {
  const _Group(this.title, this.items);
  final String title;
  final List<_Shortcut> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(),
            style: AppType.label.copyWith(color: AppColors.textSecondary)),
        const SizedBox(height: AppSpacing.x2),
        for (final s in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
            child: Row(
              children: [
                Expanded(child: Text(s.action, style: AppType.body)),
                for (final k in s.keys) ...[
                  _Keycap(k),
                  if (k != s.keys.last)
                    Text('  ',
                        style: AppType.bodySm
                            .copyWith(color: AppColors.neutral500)),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _Keycap extends StatelessWidget {
  const _Keycap(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsetsDirectional.only(start: AppSpacing.x1),
      padding: const EdgeInsetsDirectional.symmetric(
          horizontal: AppSpacing.x2, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.neutral800,
        borderRadius: const BorderRadius.all(AppRadius.sm),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Text(text,
          style: AppType.monoTime.copyWith(color: AppColors.textPrimary)),
    );
  }
}
