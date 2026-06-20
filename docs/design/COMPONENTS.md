# Component Library

> Part of the [Design System](../DESIGN_SYSTEM.md). Every reusable component the
> v1 screens need, with **purpose · anatomy · states · variants · data-model
> mapping · Flutter build**. States covered for interactive components:
> **default / hover / focus / disabled / loading / error**. Token names refer to
> [DESIGN_SYSTEM.md §3](../DESIGN_SYSTEM.md#3-foundations--design-tokens); bidi
> rules to [RTL.md](RTL.md).

**Conventions for every component below**
- Colors/sizes are **tokens**, never hex literals in widgets.
- Content text uses `AutoDirText` (RTL helper); chrome uses `*Directional` insets.
- Min hit target: macOS ≥28px, iOS ≥44pt.
- Every status/confidence visual carries an **icon + text label**, never color
  alone (a11y).

Index: [StatusChip](#statuschip) · [ProgressBar / ProgressRing](#progressbar--progressring) ·
[ConfidenceMeter](#confidencemeter) · [TitleCard](#titlecard) · [TitleRow](#titlerow) ·
[JobQueueRow](#jobqueuerow) · [SourcePicker](#sourcepicker) · [CharacterCard](#charactercard) ·
[CharacterEditForm](#charactereditform) · [GenderSelector](#genderselector) ·
[SubtitleLineRow + CPSMeter](#subtitlelinerow--cpsmeter) · [TransportBar](#transportbar) ·
[RestyleOverlay](#restyleoverlay) · [WizardStep](#wizardstep) · [ModelDownloadRow](#modeldownloadrow) ·
[SettingsRow](#settingsrow) · [TmdbMatchRow](#tmdbmatchrow) · [EmptyState](#emptystate) ·
[ConfirmDialog](#confirmdialog) · [Toast / Snackbar](#toast--snackbar) · [OfflineBanner](#offlinebanner) ·
[ShortcutsSheet](#shortcutssheet)

---

## StatusChip

**Purpose:** the universal state badge for a `JobState` / title status / artifact
state. The single most-reused component — appears on cards, rows, detail, queue.

**Anatomy:** `[icon] [label] (optional: · detail)` — pill, `radius/full`, tinted
fill + saturated foreground from the status table (DS §3.1). `label-12/600`.

**Variants (map to status palette):**
| Variant | Source enum/state | Icon | Example label |
|---|---|---|---|
| `ready` | `hasSidecar` / artifact ready | `check_circle` | "Ready" |
| `running` | `JobState.running` | `autorenew` (spins) | "Translating · 62%" |
| `queued` | `JobState.queued` | `schedule` | "Queued" |
| `paused` | `JobState.paused` | `pause_circle` | "Paused" |
| `failed` | `JobState.failed` | `error` | "Failed" |
| `attention` | low-confidence / drive / conflict | `warning_amber` | "Needs match" |

**States:** chips are non-interactive by default (display). Optional `onTap`
(e.g. failed → opens details): then add hover tint (`neutral/800`) + focus ring.
**Loading** = the `running` variant itself. **Disabled** n/a.

**Sizes:** `sm` (h20, icon18) inline on cards; `md` (h28, icon20) on detail/queue.

**Flutter:** `Container`(decoration: tint + `radius/full`) → `Row`(`Icon`, `Text`).
`running` icon = `RotationTransition` (paused under reduced-motion → static icon).
Wrap label in `Semantics(label: spokenState)` (DS §6.2).

```dart
StatusChip(status: JobState.running, progress: 0.62, stage: 'transcribe')
// → "Translating · 62%", spoken: "Translating, 62 percent, stage transcribe"
```

---

## ProgressBar / ProgressRing

**Purpose:** show determinate job/download progress; indeterminate only pre-first-event.

**Anatomy:** track (`neutral/800`, `radius/full`) + fill (`status/running` for jobs,
`accent/amber` for downloads). **Always LTR-pinned** (RTL.md §2). Ring variant for
compact card corners / iOS Now Playing.

**States:** `indeterminate` (shimmer/sweep) → `determinate` (fill, value tween
`motion/fast`) → on 100% morph to `ready` color briefly. `error` → track turns
`status/failed` tint, fill stops. `paused` → fill dims to `status/paused`.

**Variants:** `bar/sm` (h4, in cards), `bar/md` (h6, queue), `ring` (24/40px),
`labeled` (bar + right `mono-time` "62%").

**Flutter:** `LinearProgressIndicator` / `CircularProgressIndicator` themed, or a
custom `CustomPaint` for the rounded track. `Semantics(value: '62%')`, throttle
announcements (DS §6.2). Wrap in `Directionality(ltr)`.

---

## ConfidenceMeter

**Purpose:** show AI confidence for a bible proposal or TMDB match as a *band of
trust*, never a bare number. Realizes principle P1.

**Anatomy:** 3-segment bar (low/med/high zones) with a marker at the value, +
band word + isolated `mono` percent: `Please review · ⁦41%⁩`. Color = confidence
palette (DS §3.1): high=green, med=amber, low=warm-orange (**not red**).

**Variants:** `inline` (dot + word, on cards), `bar` (full, on edit form),
`badge` (just the word, smallest).

**States:** static display; `onTap` optional → scrolls to the field to review.
No disabled/error.

**Data:** `BibleCharacter.confidence` (0..1); TMDB match score.

**Flutter:** `CustomPaint` 3-zone bar + marker; `Semantics(label: 'Confidence:
please review, 41 percent')`. Pin LTR.

---

## TitleCard

**Purpose:** the library grid unit. Poster-forward, calm (principle P3). Designed
for tens of thousands → cheap to build, lazy artwork.

**Anatomy (vertical):**
```
┌────────────┐
│            │  ← poster (2:3), radius/lg, bleeds to edge
│  poster    │     top-right corner: StatusChip(sm) overlay only if NOT ready
│            │     (ready = no chip; calm). bottom: thin watch-progress bar.
├────────────┤
│ Title 14/500│  ← AutoDirText, 1 line ellipsis (start-aligned by value dir)
│ 2023 · S2   │  ← body-sm/neutral-300, isolated numerals
└────────────┘
```

**States:**
- `default`: e0, no border.
- `hover`: lift -2px, shadow e0→e1, 1px `neutral/700` ring (`motion/base`).
- `focus` (keyboard): `focus/ring` 2px amber + offset.
- `selected`: amber ring + `accent/amber-subtle` wash.
- `loading` (artwork): poster = shimmer placeholder (`neutral/850`→`800`).
- `error` (no artwork / TMDB miss): film-strip glyph on `neutral/850` + the title
  text still shown; if match is low-confidence, `attention` chip = "Needs match".
- `processing`: status chip overlay (`queued`/`running %`/`failed`).

**Watch state:** thin `accent/amber` bar across poster bottom = resume position;
`check` pip top-left = watched (`WatchState.watched`).

**Variants:** `poster` (default), `landscape` (16:9 for episodes/Continue row),
`compact` (denser grid at small window).

**Data:** `Title` + TMDB artwork + `ProcessingJob`/sidecar status + `WatchState`.

**Flutter:** `GridView.builder`/slivers item. Poster = `Image`(cacheWidth set,
`FadeInImage` w/ shimmer placeholder) wrapped in `RepaintBoundary`. Card =
`InkWell`(focus + hover via `FocusableActionDetector`) → `Column`. `Semantics(
label: '<title>, <year>, <statusWord>', button: true)`, poster `excludeSemantics`.
**Artwork lazy-loaded + memory-capped**; never decode full-res posters.

---

## TitleRow

**Purpose:** the library **list** view unit (sortable table-ish density) and the
detail-screen "episodes" list. Same data as TitleCard, horizontal.

**Anatomy:** `[thumb 48×72] [title + meta (AutoDirText)] … [StatusChip] [⋯ menu]`
Columns in list mode: Title · Status · Source · Updated · (overflow menu).

**States:** default / hover (`neutral/800` row) / focus ring / selected (amber
wash) / processing (chip) / failed (chip + subtle `status/failed` left edge).

**Flutter:** `ListView.builder` row (replaces the current plain `ListTile`).
Keep `PopupMenuButton` for the ⋯ menu (already used). Use
`EdgeInsetsDirectional`. Row height 56 (compact) / 64 (comfortable).

> **Migration note:** this replaces the current `_list()` `ListTile` in
> `library_page.dart`. Keep the Play / generate / remove menu items; restyle with
> tokens + StatusChip instead of colored subtitle text.

---

## JobQueueRow

**Purpose:** one job in the Processing/Queue view. Shows stage, live progress,
and the controls SPEC requires: pause/resume, reprioritize, retry.

**Anatomy:**
```
[≡ drag]  [title 14/500]               [stage label] [ProgressBar(md)] 62%
          [SourceChip] [model · bible v3]            [⏸][▲reprioritize][⋯]
```
The 12 pipeline stages (SPEC §4) show as the `stage` label: Scan · Metadata ·
Group · Bible · Source · Demux · ASR · Segment · Translate · Assemble · Store · Sync.

**States:**
- `queued`: `schedule` chip, no progress, drag handle active.
- `running`: live ProgressBar + stage; `⏸` pause control.
- `paused`: dimmed, `▶` resume; auto-yield variant shows a distinct note
  (see below).
- `failed`: `status/failed` left edge + error summary + `[Retry] [Details]`.
- `done`: collapses / moves to a "Recently finished" group with `ready` chip.
- **auto-yield** (SPEC: throttle while a video plays): row shows an *info* note
  "Paused while you're watching" with `pause_circle` in `status/paused` — **not**
  a failure; resumes automatically. Copy is reassuring, not alarming.

**Interactions:** drag to reorder = reprioritize (`priority` field); `▲`/`▼`
buttons as a keyboard-accessible alternative (DS §6.4). Pause/resume = `JobState`
transitions. Reduced-motion: progress jumps.

**Data:** `ProcessingJob` (stage, state, priority, progress, attempts, error) +
`Title` + `SubtitleArtifact` (model/bible_version for the sub-label).

**Flutter:** `ReorderableListView` for drag-reprioritize; row = `Row` of the
above; pinned-LTR `Directionality` around the progress segment (RTL.md §2).

---

## SourcePicker

**Purpose:** the "smart default + override" subtitle-source choice (SPEC locked
decision). Maps to `SourcePreference {embedded, asr, auto}` and per-title
`SubtitleSource`.

**Anatomy:** a radio group of option cards, the recommended one pre-selected with
a "Recommended" tag:
```
( ) Translate embedded subtitle   [English]   — fastest, best timing
(•) Transcribe the audio (ASR)                 — when no subtitle track  [Recommended]
( ) Use existing sidecar          movie.en.srt — translate this file
```
Each option states its **speed/quality tradeoff** in one phrase (DS §7 copy).
Options that don't apply (no embedded track / no sidecar) are **disabled with a
reason**, not hidden — so the user understands *why* ASR is the default.

**States:** option default / hover / focus / selected (amber ring + subtle wash) /
disabled (`neutral/500` + reason caption: "No embedded subtitles found").

**Data:** `Title.sourcePreference`, available embedded tracks, sidecar presence.

**Flutter:** `RadioListTile`-style custom cards in a `Column`; `Semantics`
announces option + tradeoff + recommended.

---

## CharacterCard

**Purpose:** display one AI-proposed `BibleCharacter` in the bible review grid/list.

**Anatomy:**
```
┌───────────────────────────────────────────┐
│ [avatar]  Yael ⁦·⁩ יעל            [✎ edit]  │  canonical (LTR) · translation (RTL), isolated
│           ♀ Female   ConfidenceMeter(inline) │
│           aka: Yaeli · רב-סרן                │  aliases (mixed dir, each isolated)
│           daughter of Hari · ally of Gaal    │  relationships, body-sm
│           [user-corrected ✓]  (if set)       │
└───────────────────────────────────────────┘
```

**States:** default / hover (e1) / focus / `proposed` (AI, shows ConfidenceMeter)
/ `user-corrected` (green check, confidence hidden, `userCorrected=true`) /
`low-confidence` (`confidence/low` accent + "Please review" — gently nudges).

**Data:** `BibleCharacter` (canonicalName, gender, nameTranslations[lang],
aliases, relationships, confidence, userCorrected).

**Flutter:** `Card`(e0/e1) → mixed-dir `Text.rich` for "Yael · יעל" with
`isolateLtr`/`isolateRtl`. Gender shown as glyph + word (GenderSelector readonly).

---

## CharacterEditForm

**Purpose:** review & correct a character. **Editing here can re-queue subtitles**
— this consequence must be visible *before* save (principle P1/P6).

**Anatomy (panel or dialog):**
- Canonical name (LTR field) · Target-language name (RTL field, AutoDir).
- **GenderSelector** (see below) — the highest-stakes field for Hebrew grammar.
- Aliases (chip input, each chip auto-dir).
- Relationships (chip/text input).
- Read-only: confidence (until edited → becomes `userCorrected`), bible version.
- **Impact banner** (live): "Saving re-translates **N lines across M titles**.
  Your edited lines are kept." — recomputed as fields change.
- Actions: `[Re-translate] [Save name only] [Cancel]` (the consent dialog, see
  ConfirmDialog "re-queue" variant).

**States:** clean / dirty (enables save, shows impact banner) / saving (spinner
on primary) / error (inline: "Couldn't save — engine offline. Retry."). Setting
any field flips the card to `userCorrected` and **pins it from AI overwrite**
(SPEC: `user_corrected` never AI-overwritten).

**Data:** mutates `BibleCharacter`; on save bumps `CharacterBible.version` →
triggers invalidation/re-queue of artifacts with older `bibleVersionUsed`.

**Flutter:** `Form` + `TextFormField`s (RTL-aware per RTL.md §7), chip inputs,
the impact banner as a `status/attention` `Container`. Save → ConfirmDialog.

---

## GenderSelector

**Purpose:** set `Gender {m, f, nb, unknown}` — *the* field that drives Hebrew
gender/grammar correctness. Deserves a first-class control, not a buried dropdown.

**Anatomy:** segmented control, 4 segments, each **glyph + full word**:
`♂ Male` · `♀ Female` · `⚥ Non-binary` · `? Unknown`. `unknown` styled as the
"needs your input" state (`status/attention` outline) because an unknown gender is
the most likely cause of a wrong Hebrew line.

**States:** default / hover / focus (ring on segment) / selected (amber fill,
`accent/onAmber` text) / disabled. `unknown` selected = subtle attention outline +
caption "Gender affects Hebrew grammar — set this for better results."

**Data:** `Gender` enum. **Accessibility:** announces full words (DS §6.2),
never "f/nb".

**Flutter:** custom `ToggleButtons`/segmented control; `Semantics` per segment.

---

## SubtitleLineRow + CPSMeter

**Purpose:** one cue line in the subtitle editor — edit text, nudge timing,
per-line AI re-translate, with reading-speed (CPS) feedback. RTL editing is
central (RTL.md §7).

**Anatomy:**
```
┌──────────────────────────────────────────────────────────────┐
│ [LTR strip · pinned]              [RTL text field, AutoDir]   │
│  #128                              שלום, ⁦Yael⁩. מה שלומך?      │
│  00:01:12,300 → 00:01:14,800                                  │
│  ⏱ 2.50s   CPSMeter ▓▓▓▓▓░ 14/17   [✎ re-translate] [edited●] │
└──────────────────────────────────────────────────────────────┘
```

**CPSMeter:** chars-per-second gauge vs the Hebrew-tuned target (SPEC: Hebrew CPS
lower than English). Green ≤ target, amber near limit, `status/failed`-tint over
limit (too-fast-to-read). Pinned LTR. Label "14/17" = current/max.

**States:**
- `default` (AI text) / `editing` (field focused, caret RTL) / `dirty` /
  `user-edited` (sets `has_user_edits`, badge ●) / `re-translating` (per-line
  spinner, field disabled) / `error` ("Re-translate failed — retry").
- CPS warning state surfaces inline (over-limit → amber/red meter + tooltip
  "Reads too fast — shorten or extend timing").

**Interactions:** `⌘R` re-translate this line through bible-aware LLM; `⌥←/→`
nudge cue (time, pinned LTR); `⌘↵` commit + next.

**Data:** a cue within a `SubtitleArtifact`; commit sets `has_user_edits`.

**Flutter:** `ListView.builder` of rows; `TextField`(direction bound to value,
debounced — RTL.md §7); CPSMeter = small `CustomPaint`. Timecode strip in
`Directionality(ltr)`.

---

## TransportBar

**Purpose:** player controls. **Entirely pinned LTR** (RTL.md §2) — time flows
left→right; play/skip never mirror.

**Anatomy:**
```
 ▶/⏸   ⏪10   ⏩10   ──────●──────────  01:12 / 48:30   1.0×   CC   ⤢
                     (seek bar, LTR)    (mono-time)    speed  subs  fullscreen
```
- Quick subtitle toggle (`CC`/`S` key) and quick-restyle (`⌘⇧S` → RestyleOverlay).
- Hover-reveal on macOS (auto-hide after 2.5s idle); tap-reveal on iOS.

**States:** hidden (idle) / revealed / scrubbing (thumbnail preview optional) /
buffering (spinner over play) / disabled controls when no media. Subtitle toggle:
on/off reflects whether a track is loaded; disabled+caption if none.

**Flutter:** overlay `Stack` on `Video`; **wrap whole bar in
`Directionality(ltr)`**; gradient scrim (`player/scrim-bottom`); `Shortcuts`/
`Actions` for the keymap (DS §6.4). `Semantics` on each control.

> **Migration note:** replaces the lone `FloatingActionButton` play button in the
> current `player_page.dart`, and the screen-level RTL wrapper there should be
> removed (RTL.md §1.2/§8).

---

## RestyleOverlay

**Purpose:** quick subtitle restyle while watching — font, size, vertical
position, color, background, outline. Writes `SubtitleStylePref`, applies live to
libmpv. RTL-aware (DS §3.2.4).

**Anatomy:** a `radius/xl`, e2 popover/sheet anchored from the transport:
- Font (dropdown, defaults Noto Sans Hebrew) · Size (slider, **LTR**, live %) ·
  Vertical position (slider) · Text color (swatches) · Background (toggle +
  opacity) · Outline (toggle + width). Live **preview line** of Hebrew over a
  dimmed frame so the user sees the actual render.

**States:** open/closed (`motion/base` slide) / live-applying (instant feedback) /
reset ("Restore defaults" link). Sliders pinned LTR. Reduced-motion: fade.

**Data:** `SubtitleStylePref` (app-level). Changes apply immediately + persist.

**Flutter:** macOS = anchored `OverlayEntry`/popover; iOS = `showModalBottomSheet`.
Sliders in `Directionality(ltr)`. Preview = a styled `Text` mimicking libmpv
output (best-effort), or a small libmpv-rendered still.

---

## WizardStep

**Purpose:** one step of the first-run setup (drive check → models → download).
Friendly, blocking-where-it-must-be (SPEC §11).

**Anatomy:** centered ≤720px column: step indicator (1·2·3) · `display` headline ·
explanatory body (`neutral/300`) · the step body (drive status / model list /
download progress) · primary + secondary actions. Calm, lots of space.

**States per step:**
- **Drive check:** `checking` (spinner) → `found` (`ready` chip + path, primary
  "Continue") → `missing` (the drive-missing copy DS §7, `[Choose location…]
  [Try again]`, **blocks Continue**). Reassurance line: "Your library is safe."
- **Model list:** table of ModelDownloadRow (name · size · status); total size;
  primary "Download" / "Use existing" if already present.
- **Download:** ModelDownloadRows live; per-file progress + checksum; primary
  disabled until all `ready`; on done → "You're set" + "Open library."

**Flutter:** `PageView`/stepper; can't advance past a blocking failure. Centered
constrained column.

---

## ModelDownloadRow

**Purpose:** one model file's download with progress + checksum verify (the
highest-trust moment — DS §7).

**Anatomy:** `[model name] [size] ──progress── [speed · ETA] [StatusChip]`
e.g. `Whisper Large v3 · 1.5 GB ▓▓▓▓▓░ 340 MB/s · ~4s · Downloading`
then `Verifying checksum…` → `Ready` (ready chip).

**States:** `pending` / `downloading` (ProgressBar amber + speed/ETA) /
`verifying` (indeterminate, "Verifying checksum…") / `ready` (green) /
`checksum-mismatch` → **auto re-download** with `attention` chip "Re-downloading"
(not a hard error — DS §7) / `failed` (network) with `[Retry]`. / `present`
(already on drive → "Already downloaded", skip).

**Copy:** subline once per screen: "These download once, to your external drive.
AutoSub never bundles models or uses your system disk." (privacy trust, P4).

**Data:** model manifest (name, size, sha256). Pin progress LTR.

**Flutter:** row with `LinearProgressIndicator` + StatusChip; ETA via `mono-time`.

---

## SettingsRow

**Purpose:** one preference. Settings is plain, scannable, grouped (P4 — calm,
not surveillance-y).

**Anatomy:** `[label + helper caption] ……… [control]` — control = switch /
segmented / dropdown / path-picker / slider.

**Variants by setting (SPEC §9):** target language (dropdown) · quality tier
(segmented: Auto / 12B Fast / 24B Quality, with a "Auto picked 12B for your Mac"
caption) · subtitle styling defaults (→ opens RestyleOverlay-style panel) · model
storage location (path picker, shows mount status) · **opt-in diagnostics (switch,
OFF by default**, with plain disclosure: "Sends anonymized crash & usage data.
Never your media, subtitles, or library.") · library folders (list + add/remove).

**States:** default / hover / focus / disabled (with reason) / changed (autosave;
brief "Saved" inline) / dangerous (diagnostics, clear-library → ConfirmDialog).

**Flutter:** `Column` of rows grouped under `title` section headers;
`SwitchListTile`/`DropdownButton`/custom. Diagnostics OFF default is a **hard
requirement** (P4).

---

## TmdbMatchRow

**Purpose:** a search result in the "Fix match" flow (low-confidence auto-match →
search TMDB → reassign). SPEC locked decision.

**Anatomy:** `[poster 40×60] [Title (year) · type] [overview snippet] [Select]`
The currently-assigned match is marked; results ranked; each shows its match
confidence (ConfidenceMeter inline) when relevant.

**States:** default / hover / focus / selected (amber wash) / current (badge
"Current match") / loading (skeleton rows) / empty ("No results — refine your
search") / error ("Couldn't reach TMDB. Retry.").

**Flow context:** entered from a `attention` "Needs match" chip or detail action;
selecting reassigns `Title.tmdbId` / episode mapping and re-pulls metadata.

**Flutter:** search field + `ListView.builder` of rows; debounced TMDB query;
network state surfaced (P4: name the network call — "Searching TMDB…").

---

## EmptyState

**Purpose:** calm, helpful zero-data states (library, queue, bible, search).

**Anatomy:** centered glyph (outline, `neutral/500`) · `display`/`title` line ·
one-line guidance · primary action (+ optional secondary).

**Variants & copy:**
| Where | Title | Action |
|---|---|---|
| Library empty | "Your library is empty." | `[Add a folder]` `[Open a video]` |
| Queue empty | "Nothing in the queue." | (info) "New titles are translated automatically." |
| Bible empty | "No characters yet." | "AutoSub suggests characters after the first episode is processed." |
| Search empty | "No matches." | "Try a different title or year." |
| Drive missing (inline) | "Model drive not found." | `[Choose location…]` |

**Flutter:** reuses the current `_empty()` pattern in `library_page.dart`,
restyled with tokens. Keep it the *only* place big illustrations appear.

---

## ConfirmDialog

**Purpose:** consent for consequential/destructive actions. Special **re-queue
variant** is the most important dialog in the app (principle P1).

**Anatomy:** `radius/xl`, e3, scrim. Title · body (states *what + impact*) ·
actions (destructive/primary right per platform). Always names the concrete
consequence with numbers.

**Variants:**
- **Re-queue (bible edit):** "This affects subtitles already made. Changing
  **Yael**'s gender re-translates **3 titles, ~410 lines**. Lines you edited are
  kept. `[Re-translate] [Save name only] [Cancel]`" (DS §7 verbatim).
- **Clear library:** existing copy (media/sidecars not deleted) — keep, restyle.
- **Remove title / Reset bible:** what's lost + what's kept.

**States:** default / primary-loading (spinner) / error (inline). Focus trapped,
`Esc` cancels, focus returns to invoker (DS §6.3).

**Flutter:** `showDialog` + `AlertDialog`/custom (existing `_clearLibrary` is the
baseline). Re-queue variant gets the 3-action layout.

---

## Toast / Snackbar

**Purpose:** transient confirmation/status. Quiet, non-blocking (P3).

**Anatomy:** `[icon] message [optional action]`, e2, auto-dismiss ~4s, bottom
(macOS bottom-trailing / iOS bottom-safe).

**Variants:** `info` (neutral) · `success` (`ready` accent, e.g. "Re-translating
affected lines — track it in the queue.") · `attention` · `error` (persists until
dismissed, has action). No success spam — only for non-obvious outcomes.

**Flutter:** `ScaffoldMessenger` (already used via `_snack`); add an icon +
variant color; errors get an action + no auto-dismiss.

---

## OfflineBanner

**Purpose:** engine-daemon-offline state (background translation paused). Already
exists; restyle as a first-class inline banner.

**Anatomy:** `status/attention` tint bar: `[info] "Engine offline — background
translation is paused." [Reconnect]`. Non-blocking; library still browsable/
playable.

**States:** offline (shown) / reconnecting (spinner on action) / online (auto-
dismiss). Distinguish from per-job failure — this is *infrastructure*, amber not red.

**Flutter:** the existing `_offlineBanner()` in `library_page.dart`, retokenized
(amber tint, not `Colors.amber.shade100`); action triggers reconnect rather than
copying a CLI command once in-app engine launch exists.

---

## ShortcutsSheet

**Purpose:** the in-app `⌘/` keyboard-shortcut reference (DS §6.4).

**Anatomy:** grouped two-column sheet (Global · Player · Editing), keycaps +
action. Searchable optional.

**Flutter:** `showDialog`/sheet rendering the DS §6.4 tables; keycaps as small
`neutral/800` `radius/sm` chips.

---

## Component → data-model quick map

| Component | Primary model (lib/data/models.dart) |
|---|---|
| StatusChip, JobQueueRow | `ProcessingJob` (`JobState`, stage, progress, priority, error) |
| TitleCard, TitleRow | `Title`, `WatchState`, sidecar/`SubtitleArtifact` |
| SourcePicker | `Title.sourcePreference` (`SourcePreference`), `SubtitleSource` |
| CharacterCard, CharacterEditForm | `BibleCharacter`, `CharacterBible.version` |
| GenderSelector | `Gender` |
| SubtitleLineRow, CPSMeter | `SubtitleArtifact` (`cpsStats`, `has_user_edits`) |
| RestyleOverlay, SettingsRow(styling) | `SubtitleStylePref` |
| ModelDownloadRow, WizardStep | model manifest (engine) |
| TmdbMatchRow | `Title.tmdbId`, `ContextualParent.tmdbId` |
| ConfidenceMeter | `BibleCharacter.confidence`, TMDB match score |
| OfflineBanner | engine health (`ProcessingManager.engineOnline`) |
| Sync surfaces (v2) | `SyncRecord` (`SyncState`, `SyncTransport`) |
