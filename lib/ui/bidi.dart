// AutoSub Media Player — RTL / bidi helpers (docs/design/RTL.md §6).
//
// The one mental model: "Chrome is LTR. Content is RTL. Time is always LTR.
// Mixed strings isolate their runs." This file is the single, well-tested utility
// so no screen re-implements bidi logic.
//
//  - Any CONTENT string (title, character name, subtitle text, bible field) →
//    render with [AutoDirText] (auto-picks direction from the value).
//  - Any Latin/number fragment inside an RTL template string → wrap with
//    [isolateLtr] before composing so digits/names don't reorder wrongly.
//  - Any time/transport widget → wrap subtree in [LtrIsland] (pinned LTR forever).
//  - Chrome labels → plain Text + TextAlign.start (inherits app locale).

import 'package:flutter/widgets.dart';

const String _lri = '\u{2066}'; // LEFT-TO-RIGHT ISOLATE
const String _rli = '\u{2067}'; // RIGHT-TO-LEFT ISOLATE
const String _pdi = '\u{2069}'; // POP DIRECTIONAL ISOLATE

/// Direction inferred from the first strong character of [s] (Unicode Bidi).
/// Falls back to [fallback] for digit-only / neutral strings.
TextDirection directionOf(String s, {TextDirection fallback = TextDirection.ltr}) {
  for (final r in s.runes) {
    // Hebrew block U+0590–05FF, plus Arabic ranges if other RTL targets appear.
    if (r >= 0x0590 && r <= 0x05FF) return TextDirection.rtl;
    if (r >= 0x0600 && r <= 0x06FF) return TextDirection.rtl;
    if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
      return TextDirection.ltr;
    }
  }
  return fallback;
}

/// Wrap a known-LTR fragment (name, number, path) for safe embedding in RTL text.
String isolateLtr(String s) => '$_lri$s$_pdi';

/// Wrap a known-RTL fragment for safe embedding in LTR text.
String isolateRtl(String s) => '$_rli$s$_pdi';

/// A [Text] that auto-picks its direction from the content's first strong char.
/// Use for every CONTENT string (RTL.md §6 usage contract).
class AutoDirText extends StatelessWidget {
  const AutoDirText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign = TextAlign.start,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: directionOf(text),
        child: Text(
          text,
          style: style,
          textAlign: textAlign,
          maxLines: maxLines,
          overflow: overflow,
        ),
      );
}

/// A subtree pinned to LTR regardless of app/UI locale — for time/transport,
/// progress, timecodes, CPS meters, seek bars (RTL.md §2/§3 — these NEVER mirror).
class LtrIsland extends StatelessWidget {
  const LtrIsland({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Directionality(textDirection: TextDirection.ltr, child: child);
}
