# RTL / Bidi System

> **Required reading before building any screen.** Hebrew is the default target
> language; mixed Hebrew/Latin/numeral content is the *common* case. This doc is
> the single, unambiguous source for directionality so engineering never guesses.
> Part of the [Design System](../DESIGN_SYSTEM.md) (principle **P2 — RTL is native,
> not flipped**).

The current shell already does the right *instinct* — `player_page.dart` wraps the
player in `Directionality(textDirection: TextDirection.rtl)`. But a blanket
top-level RTL flip is **wrong** for the app as a whole. This doc replaces "flip
everything" with precise rules.

---

## 0. The one mental model

> **Chrome is LTR. Content is RTL. Time is always LTR. Mixed strings isolate
> their runs.**

- **Chrome** = the app's structural shell: left rail, toolbars, menus, settings
  layout, buttons-as-furniture. On a Hebrew system this stays **LTR** (the user's
  OS locale decides; for a Hebrew *UI locale* the chrome would mirror, but the
  *content target language* — Hebrew subtitles — does **not** by itself flip the
  chrome).
- **Content** = the user's media world: title names, character names, subtitle
  text, bible fields, anything translated into the target language. This is
  **RTL** whenever the value is Hebrew (or any RTL target).
- **Time** = transport, timeline, progress, seek, ±10s, CPS bars. **Always LTR.**
  Time flows left→right for everyone; mirroring it is a bug.
- **Mixed strings** (Hebrew text containing a Latin name or a number) must wrap
  each foreign run in a **bidi isolate** so the OS bidi algorithm doesn't reorder
  it wrongly.

Everything below is the precise application of these four rules.

---

## 1. Two directionalities, decided per-locale and per-value

### 1.1 App UI locale vs. content language — keep them separate
- **App UI locale** (the chrome's `TextDirection`) follows the *user's chosen
  interface language*, exposed in Settings. Default v1: **English UI → LTR
  chrome**, even though the default *subtitle target* is Hebrew. (A Hebrew *UI*
  is a later option; when chosen, chrome mirrors and this doc's "chrome = LTR"
  becomes "chrome = RTL" wholesale — the component rules still hold.)
- **Content language** is per-value. A title named "Foundation" is LTR; its
  Hebrew subtitle line is RTL; they can sit in the same card.

**Implementation:**
- Set the app-level direction from the UI locale at the `MaterialApp`/`WidgetsApp`
  level (`locale` + `Directionality` flows from it). Do **not** hardcode a global
  `TextDirection.rtl`.
- For any *content* string, decide direction **from the string's first strong
  character**, not from the app locale. Use the helper in §6.

### 1.2 Never force a whole screen to one direction
The current `Directionality(textDirection: TextDirection.rtl)` wrapper in
`player_page.dart` should be **removed** at the screen level. The player chrome is
time-based (LTR); only the *subtitle overlay text* is RTL, and libmpv handles that
render. Replace screen-level forcing with per-region `Directionality` (see §3).

---

## 2. What mirrors and what NEVER mirrors

When the **UI locale is RTL** (Hebrew interface, later phase), the chrome mirrors.
This table says what flips and what is *pinned* regardless of locale because its
meaning is spatial-temporal, not reading-order.

### Mirrors with RTL UI locale ✅
- Page layout: left rail moves to the **right**; content pane to the left.
- Reading-order navigation chevrons: "back" points **right**, "forward" **left**.
- List disclosure arrows, breadcrumb separators, submenu flyout direction.
- Text alignment of UI labels → right-aligned.
- Tab order / focus traversal → right-to-left (see §5).
- Sliders whose value is a *quantity* with no temporal meaning (e.g. volume *may*
  mirror — but see exception below; we pin volume too for muscle-memory).

### NEVER mirrors — pinned LTR regardless of locale 🔒
These are **time / spatial-physical**, and mirroring them is always a bug:

| Element | Why pinned |
|---|---|
| **Playback timeline / seek bar** | Left = start of film, right = end. Universal. |
| **Progress bars** (jobs, downloads, model fetch) | Fill grows left→right = "more done." |
| **Transport buttons** play ▶ / ⏸ | Play glyph points right = "forward in time" everywhere. |
| **Skip ±10s** (⏪ ⏩) | ⏪ is *back in time*; left arrow key = back, regardless of locale. |
| **Frame step `,` / `.`** | Temporal. |
| **Volume slider/icon** | Pin LTR for muscle memory (low-left, high-right). |
| **CPS / reading-speed meter** | It's a gauge of a quantity; keep one consistent fill direction. |
| **Waveform / scrubber thumbnails** | Time axis. |
| **Playback-speed control** | Slower-left, faster-right. |

> **Hard rule for the player:** the transport bar is built in a
> `Directionality(textDirection: TextDirection.ltr)` island *even on a Hebrew UI*,
> so it never mirrors. Subtitle text rendered by libmpv is the only RTL thing in
> the player. Keyboard: `←` is **always** seek-back, `→` always seek-forward —
> do **not** swap them under RTL.

### Icons: mirror set
Use Flutter's automatic mirroring (`Icons.arrow_back` etc. mirror under RTL via
`matchTextDirection`/`Transform`), but **explicitly opt media/time icons OUT**:
play, pause, skip±10, fast-forward/rewind, next/prev *track*, fullscreen. Build
these with `Transform`-free fixed glyphs or `textDirection: TextDirection.ltr`
around them.

---

## 3. Per-region directionality recipe (Flutter)

Wrap *content regions* in their own `Directionality`; keep chrome at the app
locale's direction. Three island types:

```dart
// (a) A CONTENT region that should follow the value's script:
Directionality(
  textDirection: directionOf(text),          // §6 helper: strong-first-char
  child: Text(text, textAlign: TextAlign.start),
)

// (b) A TIME/transport island — pinned LTR forever:
Directionality(
  textDirection: TextDirection.ltr,
  child: TransportBar(...),
)

// (c) Chrome — inherits app locale direction, do nothing special.
Text('Settings')   // follows MaterialApp locale
```

**Rules:**
- Use `TextAlign.start`/`end` and `EdgeInsetsDirectional` / `AlignmentDirectional`
  **everywhere in chrome** so a future RTL UI locale flips for free. **Never** use
  `TextAlign.left`/`right` or `EdgeInsets.only(left:)` in chrome.
- Use **explicit** `TextAlign.left`/`right` and `EdgeInsets` (non-directional)
  **only** inside pinned-LTR time islands, where you *want* it fixed.

---

## 4. Mixed-direction strings (the everyday case)

Hebrew subtitle/metadata text routinely embeds Latin names ("Yael", "TARDIS"),
numbers ("פרק 12"), timecodes, and file names. Without isolation the Unicode Bidi
Algorithm reorders these wrongly (a number after Hebrew can jump; a Latin name in
a Hebrew sentence can detach punctuation).

### 4.1 Rule
**Every foreign-script or numeric run embedded in target-language text must be
wrapped in a bidi isolate** (`U+2066 LRI` … `U+2069 PDI` for an LTR run inside
RTL; `U+2067 RLI`…`PDI` for RTL inside LTR). Prefer **isolates** over the older
LRE/RLE embeddings — isolates don't leak direction into surrounding text.

### 4.2 Where it matters most
- **Character names in Hebrew dialogue** — the bible's `nameTranslations` Hebrew
  value is RTL, but a *Latin* canonical name shown alongside (e.g. "Yael · יעל")
  needs each side isolated.
- **Episode/number strings**: "Foundation — עונה 2, פרק 5" mixes Latin title,
  Hebrew words, and Western numerals.
- **File paths & timecodes** shown next to Hebrew labels.
- **The subtitle editor**: the line being edited is RTL Hebrew but may contain an
  isolated Latin name the LLM kept verbatim. See §7.

### 4.3 Flutter mechanics
- For *display*, build the string with isolate controls or use
  `Text.rich`/`TextSpan` with per-span `TextDirection`. Helper in §6 (`isolate()`,
  `bidiSpan()`).
- `Intl.bidi`'s `Bidi.enforceDirectionInText` / `guardBracketInText` from package
  `intl` can wrap runs; or insert `⁦…⁩` manually around known-LTR
  fragments (names, numbers, paths).
- Let `Text` do bidi reordering; **never** pre-reverse strings yourself.

### 4.4 Numbers
- **Percentages, counts, timecodes, CPS, file sizes** render with **Western
  digits** and are **isolated LTR** when inside RTL text ("הושלמו ⁦62%⁩"). Use
  `mono-time` tabular figures (DESIGN_SYSTEM §3.2.2) so they don't shift.
- Do not localize digits to Hebrew/Arabic forms in v1.

---

## 5. Alignment, focus, and traversal

| Concern | Chrome (app locale) | Content region | Time island |
|---|---|---|---|
| Text align | `TextAlign.start` (flips w/ locale) | `start` w/ value's direction | fixed `left`/as-designed |
| Padding/margin | `EdgeInsetsDirectional` | `EdgeInsetsDirectional` w/ region dir | `EdgeInsets` (fixed) |
| Icon side | leading/trailing (auto) | leading/trailing | fixed |
| Focus traversal | follows locale (RTL→ right-to-left) | follows region dir | fixed L→R |

- Wrap each pane in a `FocusTraversalGroup` so an RTL content pane traverses
  right→left while the LTR toolbar in the same window traverses left→right.
  Tab order must match the **visual** reading order of that region.
- **Arrow-key grid nav (library):** under RTL UI, `→`/`←` move in *reading* order
  (→ goes to the previous item visually-right). Under LTR, standard. Always test
  with both.

---

## 6. Helper API (build this in `lib/ui/bidi.dart`)

A tiny, well-tested utility so no screen re-implements bidi logic:

```dart
import 'package:flutter/widgets.dart';

const _lri = '⁦'; // LEFT-TO-RIGHT ISOLATE
const _rli = '⁧'; // RIGHT-TO-LEFT ISOLATE
const _pdi = '⁩'; // POP DIRECTIONAL ISOLATE

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

/// A Text that auto-picks direction from its content.
class AutoDirText extends StatelessWidget {
  const AutoDirText(this.text, {super.key, this.style, this.maxLines, this.overflow});
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: directionOf(text),
        child: Text(text,
            style: style,
            textAlign: TextAlign.start,
            maxLines: maxLines,
            overflow: overflow),
      );
}
```

**Usage contract for engineering:**
- Any **content** string (title, character name, subtitle text, bible field,
  search result) → render with `AutoDirText` (or `Directionality(directionOf…)`).
- Any **Latin/number fragment inside an RTL template string** → wrap with
  `isolateLtr(...)` before composing.
- Any **time/transport** widget → wrap subtree in `Directionality(TextDirection.ltr)`.
- Chrome labels → plain `Text` + `TextAlign.start` (inherits locale).

---

## 7. The subtitle editor — RTL input model (the hardest surface)

The per-line editor (SCREENS §subtitle-editor, COMPONENTS §SubtitleLineRow) is
where RTL editing is *central*. Rules:

1. **Field direction follows the text being edited.** Hebrew line → the
   `TextField` is `textDirection: TextDirection.rtl`, `textAlign: TextAlign.right`,
   cursor starts at the right. Bind direction to the value (re-evaluate on change
   so a line that becomes all-Latin flips correctly), but **debounce** so the
   caret doesn't jump while typing the first character.
2. **Caret & selection** must behave RTL-natively — rely on the platform text
   engine (`EditableText`); never reposition the caret manually.
3. **Embedded Latin names** the LLM preserved stay LTR within the RTL field via
   the bidi algorithm automatically; do **not** insert isolate controls *into the
   stored .srt text* (that would pollute the portable sidecar). Isolates are a
   *display* concern for surrounding chrome, not the artifact. The artifact stores
   clean Hebrew + the SrtAssembler's RTL embedding marks already (per existing
   engine code).
4. **Punctuation & quotation** flip naturally; show the rendered line live
   (preview row) so the editor sees exactly what libmpv will draw.
5. **Timecode + CPS** for the line render in a **pinned-LTR** strip beside the
   RTL text field — never inside it.
6. **Mark as edited:** on commit, set the artifact `has_user_edits` (model field);
   the row shows the "edited" badge (COMPONENTS §SubtitleLineRow).

```
  ┌──────────────────────────────────────────────────────────┐
  │ [LTR strip · pinned]            [RTL text field]          │
  │  00:01:12,300 → 00:01:14,800     ⁦…⁩ שלום, יעל. מה שלומך?   │  ← caret at right
  │  CPS 14  ▓▓▓▓▓░ ok                (typing extends leftward)│
  └──────────────────────────────────────────────────────────┘
```

---

## 8. Subtitle *rendering* (libmpv) vs Flutter

- The on-screen subtitle during playback is drawn by **libmpv**, not Flutter. The
  engine's `SrtAssembler` already writes UTF-8 with RTL embedding controls, so
  Hebrew renders right-to-left in the player without Flutter involvement.
- The Flutter side only controls libmpv **styling** (font, size, position, color,
  outline, background) via the RestyleOverlay → `SubtitleStylePref`. Alignment for
  RTL subtitles = **center** by convention (don't right-align subtitle lines).
- Do **not** wrap the `Video` widget in a forced RTL `Directionality` (remove the
  current wrapper) — it has no effect on libmpv's sub rendering and risks flipping
  the transport chrome you overlay.

---

## 9. QA checklist (every screen must pass)

- [ ] Chrome uses `*Directional` insets + `TextAlign.start`; flips cleanly if UI
      locale set to RTL.
- [ ] No screen-level `Directionality(rtl)` forcing; content uses per-value dir.
- [ ] Transport/timeline/progress/CPS are in pinned-LTR islands; play/skip icons
      and ←/→ keys do not mirror.
- [ ] Mixed Hebrew+Latin+number strings render correctly (names attach, numbers
      don't jump) — tested with "Foundation — עונה 2, פרק 5".
- [ ] Subtitle editor: caret/selection RTL-native; timecode strip pinned LTR;
      stored .srt has no stray isolate chars from the UI.
- [ ] Focus traversal matches visual reading order per region.
- [ ] Numbers use Western digits, tabular figures, isolated inside RTL.
