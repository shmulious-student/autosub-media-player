# AutoSub Media Player — Design System

> **Status:** v1 source of truth for all UI work. Authored as the design lead;
> implemented by engineering (Flutter, macOS-first → iOS companion).
> **Scope:** everything in SPEC §7 phases v1–v3. **Owner of truth:** this file +
> the four supporting docs under [`docs/design/`](design/).

This is the entry point. It defines the *north star, identity, tokens,
accessibility, copy, platform rules, and the build roadmap*. The heavy detail
lives in four linked companion docs so this file stays navigable:

| Doc | What's in it |
|---|---|
| **[design/RTL.md](design/RTL.md)** | The bidi/RTL system — directionality rules, mirroring, mixed-direction strings, subtitle-editor input. **Read this before building any screen.** |
| **[design/COMPONENTS.md](design/COMPONENTS.md)** | The component library — every reusable widget, its anatomy, all states, variants, and the Flutter widgets to build it from. |
| **[design/SCREENS.md](design/SCREENS.md)** | Annotated wireframes + layout notes for every v1 screen, with empty/error/edge states. |
| **[design/TOKENS.dart](design/TOKENS.dart)** | The tokens as ready-to-paste Dart (`AppColors`, `AppTypography`, `AppSpacing`, `AppMotion`, `appTheme()`). |

Everything here is **opinionated with real values**. Where a choice is a judgment
call (an accent hue, a font), it's marked **`[REC]`** with one line of rationale
so you can override it without re-deriving the system.

---

## 0. TL;DR for the implementer

If you read nothing else:

1. **RTL is not a setting, it's the substrate.** Chrome (nav, toolbars, transport)
   is LTR on a Hebrew system; *content* (titles, subtitle text, character names)
   is RTL and must use bidi isolates. The two are interleaved constantly. The
   rules that keep you from guessing are in [RTL.md](design/RTL.md).
2. **The visual language is "calm library, legible work."** The library is a quiet,
   poster-forward dark hub. Status, progress, AI confidence, and job state are the
   *only* places that earn saturated color. Don't let chrome compete with posters.
3. **Trust is a UI deliverable.** Model downloads, drive-missing, AI proposals, and
   "this edit re-queues subtitles" are the moments the product is won or lost. They
   get dedicated components and dedicated copy — see §7 and [COMPONENTS.md](design/COMPONENTS.md).

---

## 1. Design principles (north star)

Six principles, each resolving a *real* tradeoff in this product. When two
guidelines conflict, the earlier principle wins.

### P1 — Translation quality is visible and trustworthy
The killer feature is invisible by nature (a subtitle that's *correct*). So the
product must continuously *show its work*: source of each subtitle (embedded /
ASR / sidecar), the model and bible version used, AI confidence on every
proposal, and a clear, reversible path to correct anything. Never present an AI
guess as a fact. **Tradeoff resolved:** we favor honest provenance over a
frictionless "it just works" illusion — because the moment a Hebrew gender is
wrong, trust is gone, and the user needs to already know where to fix it.

### P2 — RTL is native, not flipped
Hebrew is the default target, not a localization afterthought. We design the
content layer RTL-first and treat mixed-direction strings (Hebrew with Latin
character names and Latin/Arabic numerals) as the *common* case, not the edge.
We never "mirror the whole app" — media transport, timelines, and progress stay
LTR because they map to time, which flows left→right universally. **Tradeoff
resolved:** correctness of bidi over the simplicity of a single global flip.

### P3 — The library is calm; the work is legible
The browse experience is a quiet, cinematic, poster-forward space — low chrome,
deep neutrals, art does the talking. The *work* (queue progress, job stages,
failures, things that need attention) is where information density and color
live. We never let processing chatter clutter the calm browse surface, and we
never bury a failure in calm grey. **Tradeoff resolved:** ambient processing
status must be *available* without being *loud*.

### P4 — Local-first reads as trust, not surveillance
No account, no cloud lock-in, media never leaves the device. The UI must *feel*
that way: no "sign in," no growth-hacky nags, diagnostics off by default and
behind a plain-language toggle. Network activity (TMDB, model downloads) is named
explicitly when it happens. **Tradeoff resolved:** we accept a more manual setup
(mount a drive, download models) in exchange for a product that's obviously the
user's own.

### P5 — Desktop is the workshop; phone is the remote
macOS is the dense, keyboard-driven hub where all creation happens (bibles,
editing, queue control). iOS is a light, touch-first player + browser. We share
*tokens and data-display components* across both, but diverge on *interaction
density and navigation* — sheets and Now Playing on iOS, panes and menus on Mac.
**Tradeoff resolved:** one design system, two interaction grammars; never force
desktop density onto a thumb, never strip the Mac to phone-simplicity.

### P6 — Progress over perfection, but never silent failure
Subtitles auto-publish as `ready` (no blocking review gate). The system keeps
moving. But anything the user must know about — a failed job, a low-confidence
TMDB match, a missing drive, a re-queue triggered by their edit — surfaces
*immediately and legibly* with a clear next action. **Tradeoff resolved:** we
optimize for flow, but a `failed` or `needs-attention` state is never allowed to
hide.

---

## 2. Visual identity & tone

### Direction: **"Quiet Cinema."** `[REC]`
A deep, near-black, cool-neutral dark theme — the canonical media-hub idiom
(Plex / Apple TV / Letterboxd) because the content *is* cinematic artwork and the
user's eye should go to posters, not chrome. Rationale: dark reduces eye fatigue
in the dim rooms where people watch, it makes poster art pop, and it gives the
saturated status palette (§3) somewhere to glow against. This is the obvious and
correct anchor for the product.

**Mood words:** calm · cinematic · precise · trustworthy · *not* flashy, *not*
playful, *not* clinical.

**What makes it *ours* (so it isn't generic dark-mode):**
- **Warm-amber accent over a cool-neutral base.** The single brand accent is a
  warm amber (`#E8A33D`), used sparingly for primary actions and the "ready/your
  attention" feeling. It reads as a projector bulb / film warmth against cool
  graphite — a deliberate temperature contrast that most dark media apps (which
  go blue or red) don't use. `[REC]` — override the hue, keep the *warm-on-cool*
  relationship.
- **Poster-first cards with minimal frames.** Artwork bleeds to the card edge;
  metadata sits *below* the poster, never overlaid (overlays fight RTL text and
  reduce legibility). Selection/hover is a soft ring + lift, not a heavy border.
- **Hairline structure.** Dividers and panel edges are 1px hairlines at low
  opacity, not filled bars. Structure is implied, not drawn.

### Light mode stance `[REC]`
**Ship v1 dark-only.** A media player lives in dark rooms and the whole status
palette is tuned for a dark base. Build all tokens through a semantic layer
(§3, [TOKENS.dart](design/TOKENS.dart)) so a light theme is a *token swap later*,
not a refactor — but do not spend v1 effort on it. macOS "Auto appearance" should
pin to dark until a real light theme exists.

---

## 3. Foundations — design tokens

All values are **dark-theme**. They map 1:1 to Flutter `ThemeData` /
`ColorScheme` via [TOKENS.dart](design/TOKENS.dart). **Never hardcode a hex in a
widget** — reference the semantic token. Raw "ramp" values exist only to *define*
semantic roles.

### 3.1 Color

#### Neutral ramp (the cinematic base)
Cool graphite, not pure grey-black, so warm accents read correctly.

| Token | Hex | Use |
|---|---|---|
| `neutral/950` | `#0B0D10` | App background (the "room") |
| `neutral/900` | `#111418` | Surface / cards at rest |
| `neutral/850` | `#171B20` | Raised surface (panels, sheets, menus) |
| `neutral/800` | `#1E232A` | Hover surface / input fields |
| `neutral/700` | `#2A313A` | Hairline dividers, card borders (use at ~60% α) |
| `neutral/500` | `#5A6573` | Disabled text, tertiary icons |
| `neutral/300` | `#9AA4B2` | Secondary text, metadata |
| `neutral/100` | `#D7DCE3` | Primary text (not pure white — softer on dark) |
| `neutral/0`   | `#F4F6F9` | High-emphasis text, active labels |

#### Brand / accent
| Token | Hex | Use | Contrast note |
|---|---|---|---|
| `accent/amber` | `#E8A33D` | Primary buttons, active selection, focus on dark | 7.0:1 on `neutral/950` — AA for text, AAA for UI |
| `accent/amber-hover` | `#F2B45A` | Hover/pressed of primary |  |
| `accent/amber-press` | `#CE8C29` | Pressed |  |
| `accent/amber-subtle` | `#3A2E18` | Tinted fill behind amber (selected row bg) | text on it: use `neutral/0` |
| `accent/onAmber` | `#1A1205` | Text/icon *on* an amber fill | 9.8:1 on `accent/amber` |

> **Why amber and not the inherited indigo:** the current shell seeds Material
> from `Colors.indigo`. Indigo is cold and generic; it competes with poster blues
> and disappears against the dark base. Amber gives a warm, ownable accent with
> strong contrast. **Action:** replace `ColorScheme.fromSeed(seedColor: Colors.indigo)`.

#### Semantic status palette — job & artifact states
This is the most important color decision in the app. Each `JobState` /
title-status has a **distinct hue + a non-color cue (icon + label)** so it's
never color-only (P-accessibility). All chips use a tinted fill + saturated
foreground for AA on dark.

| Status (maps to) | Role token | Foreground | Tint fill | Icon | Contrast (fg on tint) |
|---|---|---|---|---|---|
| **Ready** (`hasSidecar`, artifact `ready`) | `status/ready` | `#4ADE80` | `#10231A` | `check_circle` | 8.1:1 |
| **Translating / running** (`JobState.running`) | `status/running` | `#5BB8F5` | `#0E2030` | `autorenew` (spin) | 7.4:1 |
| **Queued** (`JobState.queued`) | `status/queued` | `#C9D1DA` | `#1A1F26` | `schedule` | 6.8:1 |
| **Paused** (`JobState.paused`) | `status/paused` | `#A6B0BD` | `#181C22` | `pause_circle` | 6.1:1 |
| **Failed** (`JobState.failed`) | `status/failed` | `#FF6B6B` | `#2A1416` | `error` | 6.6:1 |
| **Needs attention** (low-confidence match, drive missing, conflict) | `status/attention` | `#F2B45A` | `#2A2010` | `warning_amber` | 7.2:1 |

> `status/attention` deliberately *shares the amber family* with the brand accent
> — "needs you" and "primary action" are the same warm pull. `failed` is the only
> true red; reserve red for genuine failure so it keeps its meaning (P6).

#### AI-confidence palette (for bible proposals & low-confidence matches)
Confidence is a *gradient of trust*, shown as a 3-band scale (never a bare
percentage alone — pair the band with the number). See the confidence-meter
component in [COMPONENTS.md](design/COMPONENTS.md).

| Band | Range | Token | Color | Meaning in copy |
|---|---|---|---|---|
| High | ≥ 0.85 | `confidence/high` | `#4ADE80` (= ready green) | "Confident" |
| Medium | 0.6–0.85 | `confidence/med` | `#F2B45A` (= attention amber) | "Worth a check" |
| Low | < 0.6 | `confidence/low` | `#FF8A5B` (warm orange, *not* red) | "Please review" |

> Low confidence is **orange, not red** — an AI guess that needs review is not a
> *failure*. Red is reserved for things that broke. This protects the emotional
> register: reviewing a bible should feel like collaboration, not error-fixing (P1).

#### Functional / focus
| Token | Hex | Use |
|---|---|---|
| `focus/ring` | `#F2B45A` | 2px keyboard-focus ring (amber, +1px offset) — AA non-text |
| `overlay/scrim` | `#000000` @ 60% | Modal/dialog scrim |
| `player/scrim-top` | gradient `#000` 70%→0% | Top gradient behind player chrome |
| `player/scrim-bottom` | gradient `#000` 85%→0% | Bottom gradient behind transport |

### 3.2 Typography

#### Font pairing `[REC]` — **Inter + Noto Sans Hebrew**
- **Latin / UI chrome:** **Inter** (SIL OFL, free, ships in Flutter ecosystems).
  Excellent at small sizes, tabular figures for timecodes, broad weight range.
- **Hebrew / RTL content + UI:** **Noto Sans Hebrew** (SIL OFL). Designed as a
  Noto sibling to harmonize metrics with Inter, full Hebrew coverage incl.
  nikud, multiple weights.
- **Pairing rationale:** both are humanist sans, OFL-licensed (commercial-safe —
  matches the project's licensing constraint), and metrically compatible so a
  mixed Hebrew/Latin line doesn't jump in x-height. Set Noto Sans Hebrew as the
  **fallback font** in the Inter `TextStyle` `fontFamilyFallback` so Hebrew
  glyphs resolve automatically inside mixed strings — see [RTL.md](design/RTL.md) §typography.

> **Subtitle rendering font is separate** (see 3.2.4). Subtitles are rendered by
> libmpv, not Flutter, so the chrome font choice does not govern them.

#### 3.2.2 Type scale (Major-Third-ish, tuned for desktop density)
Names map to Flutter `TextTheme` slots. Line-height in px. Hebrew gets slightly
*looser* line-height because of nikud/ascender density.

| Token | Slot | Size / Line | Weight | Use |
|---|---|---|---|---|
| `display` | `displaySmall` | 32 / 40 | 600 | First-run wizard headlines, empty-state titles |
| `title-lg` | `headlineSmall` | 24 / 32 | 600 | Title-detail name, section headers |
| `title` | `titleLarge` | 20 / 28 | 600 | Dialog titles, panel headers |
| `subtitle` | `titleMedium` | 16 / 24 | 500 | Card titles, list-row primary |
| `body` | `bodyMedium` | 14 / 22 | 400 | Default body, metadata, settings |
| `body-sm` | `bodySmall` | 13 / 20 | 400 | Secondary metadata, captions |
| `label` | `labelMedium` | 12 / 16 | 600 | Status chips, badges, tags (slight letter-spacing) |
| `mono-time` | — (custom) | 13 / 16 | 500 | Timecodes, CPS values — **tabular figures, Inter `fontFeatures: [tnum]`** |

#### 3.2.3 Dynamic Type
- **iOS:** subscribe to `MediaQuery.textScaler`; honor the OS setting. Cap UI
  chrome scaling at **1.35×** to protect dense desktop-derived layouts (use
  `TextScaler.clamp`), but let **subtitle text and reading-content scale
  unbounded** — legibility wins there.
- **macOS:** no system Dynamic Type; expose a **UI text-size control in Settings**
  (S / M / L / XL → scale 0.9 / 1.0 / 1.15 / 1.3) so the desktop user isn't
  stuck. Persist as `SubtitleStylePref`-adjacent app pref.
- Every layout must reflow at 1.3× without truncating an actionable label. Test
  the wizard, settings rows, and bible form at max scale.

#### 3.2.4 Subtitle rendering type (rendered by libmpv, not Flutter)
Defaults for the generated `.srt`/`.ass` and the player's restyle overlay:
- **Font:** **Noto Sans Hebrew** (or user's pick), **weight 600** — subtitles need
  more weight than UI body to survive over bright video.
- **Default size:** 4.6% of video height (libmpv `sub-font-size` ~46 at 1080p).
- **Outline:** 2.4px black outline + soft shadow (the single most important
  legibility lever over video). **On by default.**
- **Background:** optional semi-opaque box `#000` @ 55% (user toggle; off by
  default — outline alone is the tasteful default per SPEC).
- **Position:** bottom, 5% margin. RTL alignment = center (subtitles center by
  convention regardless of script).
- These map to `SubtitleStylePref` and the restyle overlay component.

### 3.3 Spacing & grid
**4pt base.** Use the scale; no arbitrary values.

| Token | px | Typical use |
|---|---|---|
| `space/0.5` | 2 | Icon-label gap (chips) |
| `space/1` | 4 | Tight inner padding |
| `space/2` | 8 | Chip padding, compact gaps |
| `space/3` | 12 | List-row vertical padding |
| `space/4` | 16 | **Default gutter / card padding** |
| `space/5` | 20 | Section inner spacing |
| `space/6` | 24 | Between cards, panel padding |
| `space/8` | 32 | Section spacing |
| `space/12` | 48 | Page margins (desktop), major blocks |

**Library grid:** poster cards on a flexible grid. Target **poster width 160–200px**
(2:3 ratio → 240–300 tall), **24px gap**, min 2 cols / no max (virtualized). Use
`SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 200)` so it reflows
across window widths. **Always virtualize** (`GridView.builder` / slivers) —
designed for tens of thousands of titles.

**Desktop content max-width:** detail/settings/wizard content columns cap at
**720px** for readability; the library grid uses full width.

### 3.4 Radii
| Token | px | Use |
|---|---|---|
| `radius/sm` | 6 | Chips, badges, inputs |
| `radius/md` | 10 | Buttons, list rows, small cards |
| `radius/lg` | 14 | **Poster cards, panels, sheets** |
| `radius/xl` | 20 | Dialogs, the restyle overlay |
| `radius/full` | 999 | Pills, progress tracks, avatar |

### 3.5 Elevation & shadow
Dark UI uses **surface lightness + a soft shadow**, not heavy drop shadows.

| Level | Surface token | Shadow | Use |
|---|---|---|---|
| `e0` | `neutral/900` | none | Cards at rest, list |
| `e1` | `neutral/850` | `0 1 3 #000 @ 30%` | Hover card, raised panel |
| `e2` | `neutral/850` | `0 6 16 #000 @ 40%` | Menus, popovers, the restyle overlay |
| `e3` | `neutral/850` | `0 12 32 #000 @ 50%` | Dialogs, sheets, wizard modal |

Hover lift on poster cards: translateY -2px + grow shadow e0→e1 + amber focus ring
on keyboard focus.

### 3.6 Motion
Calm and quick. Nothing bounces. **All durations halve / disable under
reduced-motion** (§6.6).

| Token | Duration | Curve | Use |
|---|---|---|---|
| `motion/instant` | 80ms | `easeOut` | Hover tint, chip state |
| `motion/fast` | 140ms | `easeOutCubic` | Buttons, selection, focus ring |
| `motion/base` | 220ms | `easeOutCubic` | Card lift, sheet/overlay slide |
| `motion/slow` | 320ms | `easeInOutCubic` | Page/route transitions, dialog in |
| `motion/progress` | continuous | `linear` | Progress fills, the `running` spinner |

- Progress bars animate value changes over `motion/fast`; **indeterminate** only
  before first progress event, then switch to determinate.
- The `running` status icon (`autorenew`) rotates at 1 rev / 1.4s, **paused under
  reduced-motion** (show static icon + label instead).

### 3.7 Iconography
- **Set:** Material Symbols (Rounded, weight 400) — already in the Flutter stack,
  consistent metrics, huge coverage. `[REC]`
- **Sizes:** 18 (inline/chips), 20 (buttons/rows), 24 (toolbar/transport), 28
  (player primary). Touch targets stay ≥44px regardless of icon size.
- **Directional icons mirror** under RTL (back/forward chevrons, next/prev in
  *lists*); **media-transport and time icons do NOT mirror** (play, skip ±10s,
  seek) — see [RTL.md](design/RTL.md) §mirroring for the exact list.
- Status icons are fixed per status (table in 3.1) so they're learnable.

---

## 4. RTL / bidi system

This foundation is large and load-bearing enough to live in its own doc:
**→ [design/RTL.md](design/RTL.md)**. It is **required reading before building any
screen.** It covers: chrome-LTR vs content-RTL, what mirrors and what never does,
mixed Hebrew+Latin+numeral strings with bidi isolates, alignment rules, the
subtitle-editor RTL input model, and the exact Flutter mechanics
(`Directionality`, `TextDirection`, `Unicode.RLI/PDI`, `Intl.bidi`).

---

## 5. Component library

The full inventory — every reusable component, its anatomy, all states
(default / hover / focus / disabled / loading / error), variants, data-model
mapping, and the Flutter widgets to build each from — lives in:
**→ [design/COMPONENTS.md](design/COMPONENTS.md)**.

Quick index of what's specified there: StatusChip · ProgressBar/Ring ·
TitleCard (grid) · TitleRow (list) · JobQueueRow · CharacterCard ·
CharacterEditForm (with Gender selector) · SubtitleLineRow + CPSMeter ·
TransportBar · RestyleOverlay · WizardStep · ModelDownloadRow · SettingsRow ·
TmdbMatchRow · SourcePicker · ConfidenceMeter · EmptyState · ConfirmDialog ·
Toast/Snackbar · OfflineBanner.

---

## 6. Accessibility spec

Target: **WCAG 2.1 AA**, plus first-class VoiceOver and full keyboard operation
on macOS. (A standalone audit lives alongside this section; values below are
binding.)

### 6.1 Contrast
- All token pairings in §3 are pre-checked to **AA** (≥4.5:1 text, ≥3:1 UI/large).
  The status & confidence tables list measured ratios.
- **Body text** uses `neutral/100` on `neutral/900` → 9.6:1. **Secondary**
  (`neutral/300`) → 5.2:1 (AA). Never put body text on `neutral/700` or lighter.
- **Subtitles over video:** legibility comes from outline+shadow, not contrast of
  a fixed pairing (video is arbitrary). Default white text + 2.4px black outline
  is the floor; the restyle overlay must keep outline available.

### 6.2 Semantics / VoiceOver
- Every status chip exposes a `Semantics(label:)` that reads the **state in
  words**, not just color: e.g. *"Translating, 62 percent, stage transcribe."*
- Poster cards: `Semantics(label: "<title>, <year>, <status>", button: true)`;
  the poster image itself is `excludeSemantics` (decorative) — the label carries it.
- Confidence meters announce the **band word + number**: "Confidence: please
  review, 41 percent."
- Progress: use `Semantics(value:)` with live updates; throttle announcements to
  ~once / 5s so VoiceOver isn't spammed during a long job.
- Gender selector announces full words ("Female", "Non-binary", "Unknown"), never
  just "f/nb".

### 6.3 Focus order & visibility
- Logical focus order follows **reading order of the active `TextDirection`** —
  in an RTL pane, focus moves right→left. Use `FocusTraversalGroup` per pane so
  an RTL content pane and LTR toolbar each traverse correctly.
- Focus ring: `focus/ring` (amber) 2px + 1px offset, **always visible on keyboard
  focus** (never `focusColor`-only). Don't suppress focus rings on mouse — dim
  them, per platform convention, but keyboard focus is always shown.
- Dialogs/sheets trap focus; `Esc` closes; focus returns to the invoking control.

### 6.4 macOS keyboard-shortcut map
Implement with `Shortcuts` + `Actions` (Flutter) / `PlatformMenuBar`. **Bold = also
in the menu bar.**

**Global / Library**
| Keys | Action |
|---|---|
| **⌘O** | Open file |
| **⌘⇧O** | Add folder / scan |
| **⌘F** | Focus search/filter |
| ⌘1 / ⌘2 | Grid view / List view |
| **⌘,** | Settings |
| ⌘⌫ | Remove selected title (with confirm) |
| Space (on card) | Quick-look / play |
| Return | Open title detail |
| Arrows | Navigate grid/list (RTL-aware horizontal) |

**Player (transport — never mirrored)**
| Keys | Action |
|---|---|
| Space / K | Play / pause |
| ← / → | Seek ∓10s (these keys do **not** flip under RTL — ← is always *back in time*) |
| J / L | Seek ∓10s (alt) |
| ↑ / ↓ | Volume up / down |
| , / . | Frame step back / forward (paused) |
| S | Toggle subtitles |
| ⇧ +/− | Subtitle size − / + |
| ⌥↑ / ⌥↓ | Subtitle vertical position |
| ⌘⇧S | Open restyle overlay |
| F | Toggle fullscreen |
| Esc | Exit fullscreen / close overlay |
| 0–9 | Seek to 0–90% |
| [ / ] | Playback speed − / + |

**Editing (subtitle editor / bible)**
| Keys | Action |
|---|---|
| ⌘S | Save edits |
| ⌘Z / ⌘⇧Z | Undo / redo |
| ⌘R | Re-translate current line (bible-aware) |
| ⌘↵ | Commit line, go to next |
| Tab / ⇧Tab | Next / prev field (direction-correct) |
| ⌥← / ⌥→ | Nudge cue −/+ (time, not mirrored) |

> The full table also belongs in an in-app **"Keyboard Shortcuts" (⌘/)** help
> sheet — see ShortcutsSheet in COMPONENTS.

### 6.5 Dynamic Type — see §3.2.3. Reflow at 1.3× is a hard requirement.

### 6.6 Reduced motion
- Honor `MediaQuery.disableAnimations` (set by macOS "Reduce Motion" / iOS).
- When on: route transitions become cross-fades ≤120ms; the `running` spinner
  becomes a static icon + animated *text* percentage only; card lift becomes a
  border-color change; progress bars jump rather than tween.

### 6.7 Subtitle legibility defaults — see §3.2.4. Outline-on is the AA floor.

---

## 7. UX copy guidance

### Voice & tone
**Calm, precise, second-person, plain.** We're a trustworthy tool, not a hype
brand. No exclamation marks except genuine success. No anthropomorphizing the AI
("I think…") — say "AutoSub" or passive voice. Name network activity plainly.
Hebrew UI copy is written *natively*, never machine-translated from these English
strings — these are the English source + intent.

| Do | Don't |
|---|---|
| "Translating — 62%" | "Hang tight, magic happening ✨" |
| "Couldn't reach the engine." | "Oops! Something went wrong." |
| "AutoSub suggests this character is female." | "I'm pretty sure she's a girl!" |
| "Editing this re-translates 3 episodes." | "Are you sure???" |

### Trust-sensitive strings (use verbatim or close)

**Drive missing (first-run blocker)**
> **Model drive not found**
> AutoSub keeps its AI models on your external drive so they never fill up your
> Mac. Connect the drive named **EP2TB** (or choose a new location) to continue.
> `[Choose location…]` `[Try again]`
> *Footnote, neutral/300:* Nothing else is blocked — your library is safe.

**Model download**
> **Downloading models — 1 of 2**
> Whisper Large v3 · 1.5 GB · 340 MB/s · ~4s left
> *Subline:* These download once, to your external drive. AutoSub never bundles
> models or uses your system disk.
> On verify: "Verifying checksum…" → on done: "Ready." (status/ready)
> On mismatch: "Checksum didn't match — re-downloading this file." (status/attention, auto-retry, not a hard error)

**AI proposal confidence**
- High: "Confident" · Med: "Worth a check" · Low: "Please review"
- Empty bible: "AutoSub will suggest characters after the first episode is
  processed. You can review and correct everything here."

**Edit re-queues subtitles (the critical consent moment)**
> **This affects subtitles already made**
> Changing **Yael**'s gender to *female* will re-translate her lines across
> **the Foundation series (3 titles, ~410 lines)**. Lines you edited yourself are
> kept. `[Re-translate]` `[Save name only]` `[Cancel]`
> *On confirm toast:* "Re-translating affected lines — track it in the queue."

**Failure states (always: what + why + next step)**
- Job failed: "Translation failed — the audio track couldn't be decoded. `[Retry]` `[Choose another track]` `[Details]`"
- TMDB low match: "We're not sure this is the right title. `[Fix match]`"
- Engine offline: "Engine offline — background translation is paused." `[Reconnect]`

**Source picker (smart default + override)**
> "AutoSub will **transcribe the audio** (no subtitle track found)." /
> "Found an embedded **English** subtitle — translate that (fastest)." /
> "Found a sidecar **movie.en.srt** — use it as the source?"
> Each option line names the *speed/quality tradeoff* in one phrase.

Full per-component microcopy is inlined in [COMPONENTS.md](design/COMPONENTS.md)
and per-screen copy in [SCREENS.md](design/SCREENS.md).

---

## 8. Platform adaptation (macOS vs iOS)

| Dimension | macOS (hub / workshop) | iOS (companion / remote) |
|---|---|---|
| Navigation | Persistent left rail/sidebar (Library, Queue, Settings) + content pane | Bottom tab bar (Library, Now Playing, Settings); push nav |
| Density | Compact, multi-column, hover affordances, right-click menus | Roomy, single-column, no hover; long-press for secondary |
| Creation surfaces | Bible review, subtitle editor, queue control — **all here** | **Read-only** for bibles in v2 (editable in v3 via merge); no editor |
| Secondary actions | `PopupMenuButton` / context menu | `showModalBottomSheet` action sheets |
| Dialogs | Centered `Dialog` (radius/xl, e3) | Bottom sheets; `.pageSheet` for big flows |
| Window chrome | Native title bar; `PlatformMenuBar` (File/Edit/View/Playback/Window/Help) | Status bar + safe areas; no menu bar |
| Player chrome | Hover-reveal transport + keyboard shortcuts | Tap-reveal transport, large touch targets, **Now Playing + lock-screen remote** |
| Touch targets | ≥28px clickable (mouse) | **≥44×44pt** everywhere |
| Sync UI | Authoritative; shows "serving to N devices" | Shows "synced from Mac", LAN/SMB status, offline-pin toggle |
| Text size | Settings control (§3.2.3) | OS Dynamic Type |

**Shared (build once, theme via tokens):** StatusChip, ProgressBar/Ring,
ConfidenceMeter, TitleCard, all status/copy logic, the entire token layer. The
*data display* is identical; only the *interaction grammar* (sheets vs menus,
tabs vs rail) diverges. See [COMPONENTS.md](design/COMPONENTS.md) "platform notes"
per component.

**iOS-specific screens to design at system level (v2):** light player with
Now Playing, library browse (same TitleCard), LAN/Bonjour sync-status surface,
SMB streaming state, offline pin/download affordance. Tokens + shared components
already cover ~80%; the deltas are navigation chrome and the sync/offline
surfaces.

---

## 9. Phase-by-phase implementation roadmap

Build order respects dependencies: **tokens → primitives → shells → flows**.
"Dep" = what must exist first.

### Foundation (do first — unblocks everything)
| # | Item | Dep | Notes |
|---|---|---|---|
| F1 | Token layer → `appTheme()` (replace indigo seed) | — | [TOKENS.dart](design/TOKENS.dart); wire into `main.dart` `MaterialApp.theme` |
| F2 | RTL plumbing: app `Directionality`, bidi helpers, mixed-string isolate util | F1 | [RTL.md](design/RTL.md) |
| F3 | Fonts bundled (Inter + Noto Sans Hebrew), `TextTheme`, fallback chain | F1 | |
| F4 | Primitives: StatusChip, ProgressBar/Ring, ConfidenceMeter, EmptyState, ConfirmDialog, Toast | F1–F3 | Shared Mac+iOS |

### v1 — usable Mac product
| # | Screen / component | Dep | Priority |
|---|---|---|---|
| 1 | **App shell**: left rail (Library / Queue / Settings), window/menu bar | F1–F4 | First |
| 2 | **Library grid + list** (virtualized, lazy artwork, TitleCard/TitleRow, filter/sort, empty state) | 1, F4 | First |
| 3 | **First-run wizard** (drive check → model list → download w/ checksum) | F4, ModelDownloadRow | First (gate) |
| 4 | **Title detail** (metadata, audio-track picker, SourcePicker, target-lang, generate/regenerate, watch state) | 2 | High |
| 5 | **Processing/queue view** (JobQueueRow, pause/resume/reprioritize, retry, auto-yield state) | 1, F4 | High |
| 6 | **Player enhancements** (TransportBar, sub quick-toggle, RestyleOverlay, shortcuts) | existing player | High |
| 7 | **Character bible review** (CharacterCard, CharacterEditForm + Gender, re-queue consent dialog) | 4, ConfirmDialog | High |
| 8 | **Subtitle editor** (SubtitleLineRow, CPSMeter, per-line re-translate, RTL input) | 4, 7 | Medium |
| 9 | **TMDB fix-match** (search → TmdbMatchRow → reassign) | 4 | Medium |
| 10 | **Settings** (target lang, quality tier, subtitle styling, model location, diagnostics, folders) | 1, F4 | Medium |

### v2 — iOS companion
| # | Item | Dep |
|---|---|---|
| 11 | iOS nav shell (tab bar) + reuse shared components | F-layer |
| 12 | iOS library browse + light player + Now Playing | 11, 2, 6 |
| 13 | Sync-status surface (Bonjour/LAN), SMB streaming state, offline pin/download | 11 |

### v3+ — scale & sync
| # | Item | Dep |
|---|---|---|
| 14 | iCloud sync status + **conflict-merge prompt** (bible last-writer-wins UI) | 13 |
| 15 | Multi-target-language switching (per-title lang chips, on-demand generate) | 4, 10 |
| 16 | Light theme (token swap) | F1 |

---

## 10. Governance / how to extend this system
- **Never hardcode** a color, size, radius, or duration — add or reuse a token.
- New component? Document it in [COMPONENTS.md](design/COMPONENTS.md) with all
  six states *before* building, and add it to the roadmap table.
- Touching RTL behavior? Update [RTL.md](design/RTL.md) — it must stay the single
  unambiguous source so engineering never guesses bidi.
- A "judgment call" `[REC]` may be overridden — when you do, update the token
  value here so the doc stays the source of truth.
