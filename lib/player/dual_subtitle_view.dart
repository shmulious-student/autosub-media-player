// DualSubtitleView — the original-language line, above the translation.
//
// Two audiences want the same thing for different reasons: language learners want
// to read the English while hearing it, and anyone checking a machine translation
// wants the source line in view to judge it. Both need the two languages on screen
// at once, with the Hebrew still the primary read.
//
// media_kit draws the primary (Hebrew) track itself from the mpv subtitle stream,
// so this widget draws only the secondary line, from cues we parsed ourselves. It
// sits above the primary by a measured-out gap rather than in a shared column,
// because the two overlays live in different subtrees — a two-line Hebrew cue can
// therefore crowd the English one, which is why the gap is generous.
//
// Direction: the secondary line is Latin source text and is isolated LTR
// (RTL.md §2) — it must not inherit the RTL of the Hebrew overlay beneath it.

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../subtitle/subtitle_appearance.dart';
import '../ui/tokens.dart';
import 'cue_track.dart';

class DualSubtitleView extends StatelessWidget {
  const DualSubtitleView({
    super.key,
    required this.player,
    required this.track,
    required this.appearance,
    this.offset = Duration.zero,
  });

  final Player player;
  final CueTrack track;
  final SubtitleAppearance appearance;

  /// The player's current subtitle delay, so the secondary line moves with the
  /// primary one when the viewer nudges the timing.
  final Duration offset;

  /// How far above the primary subtitle the secondary line sits: two primary
  /// lines plus a breathing gap.
  double get _bottomInset => appearance.bottomPadding + appearance.fontSize * 2.9;

  @override
  Widget build(BuildContext context) {
    if (track.isEmpty) return const SizedBox.shrink();
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      builder: (context, snap) {
        final cue = track.cueAt(
          snap.data ?? player.state.position,
          offset: offset,
        );
        if (cue == null) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: _bottomInset,
            ),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                cue.text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: AppType.latin,
                  fontFamilyFallback: AppType.fallback,
                  // Secondary by design: smaller and muted so the eye still lands
                  // on the Hebrew first.
                  fontSize: (appearance.fontSize * 0.58).clamp(14.0, 32.0),
                  height: 1.25,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFD4D4D8),
                  backgroundColor: Colors.black.withValues(
                    alpha: appearance.backgroundOpacity * 0.9,
                  ),
                  shadows: appearance.shadow
                      ? const [
                          Shadow(
                            color: Color(0xE6000000),
                            offset: Offset(0, 2),
                            blurRadius: 4,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
