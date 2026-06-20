# Screen Layouts (v1 — macOS)

> Part of the [Design System](../DESIGN_SYSTEM.md). Annotated wireframes +
> layout/hierarchy/actions/edge-state notes for every v1 screen (SPEC §7). Built
> from the [components](COMPONENTS.md); all bidi behavior per [RTL.md](RTL.md).
> Wireframes are LTR-chrome (default English UI); content cells hold RTL Hebrew.

**Global chrome (all screens):** native macOS title bar + `PlatformMenuBar`
(File / Edit / View / Playback / Window / Help) + a persistent **left rail**:

```
┌────────────────────────────────────────────────────────────────────┐
│ ●●●   AutoSub Media Player                                          │ title bar
├──────────┬─────────────────────────────────────────────────────────┤
│ ▣ Library│                                                         │
│ ☰ Queue 3│                  ( active screen content )              │
│ ⚙ Settings│                                                        │
│          │                                                         │
│ ───────  │                                                         │
│ ◐ Engine │  ← engine status dot (online/offline) at rail bottom    │
└──────────┴─────────────────────────────────────────────────────────┘
```
Rail items: Library · Queue (badge = active job count) · Settings; bottom = engine
health dot (green/amber). Rail is chrome → LTR, `*Directional` insets.

---

## 1. First-run setup wizard (SPEC §11)

Blocking-but-friendly. Three steps; cannot pass a hard failure (missing drive).

### 1a. Drive check — found
```
                ┌──────────────────────────────────┐
                │            ● ● ●   (step 1 of 3)  │
                │                                   │
                │     Set up AutoSub                │  display
                │                                   │
                │  AutoSub keeps its AI models on   │  body / neutral-300
                │  your external drive, so they     │
                │  never fill up your Mac.          │
                │                                   │
                │  ┌─────────────────────────────┐  │
                │  │ ✓ Ready  Drive “EP2TB” found │  │  status/ready chip
                │  │   /Volumes/EP2TB/autosub-…   │  │  mono path, isolated
                │  └─────────────────────────────┘  │
                │                                   │
                │            [ Continue ]           │  primary (amber)
                └──────────────────────────────────┘
```

### 1b. Drive check — MISSING (blocking)
```
                │  ┌─────────────────────────────┐  │
                │  │ ⚠ Model drive not found      │  │  status/attention
                │  │ Connect the drive “EP2TB”,   │  │
                │  │ or choose a new location.    │  │
                │  └─────────────────────────────┘  │
                │  [ Choose location… ]  [ Try again ]
                │  Nothing else is blocked —        │  reassurance, neutral-300
                │  your library is safe.            │
                │            [ Continue ]  ← disabled until resolved
```

### 1c. Models — list + download
```
│  Required models                          Total 4.1 GB      │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Whisper Large v3      1.5 GB   ▓▓▓▓▓░ 340 MB/s ~4s  ⟳   │ │ ModelDownloadRow
│  │ DictaLM 3.0 (12B)     2.6 GB   ▓▓░░░░ queued        ◷   │ │
│  └────────────────────────────────────────────────────────┘ │
│  These download once, to your external drive. AutoSub        │ trust subline (P4)
│  never bundles models or uses your system disk.              │
│                              [ Download ]  ← disabled→ "You're set" → [Open library]
```
**Edge/error:** offline → "No internet — model downloads need a connection.
`[Try again]`"; checksum mismatch → auto re-download (`attention`, not error);
partial drive space → "Not enough space on EP2TB (need 4.1 GB, 2.0 free)."
**Components:** WizardStep, ModelDownloadRow, StatusChip, EmptyState(drive).

---

## 2. Library (the hub)

Default screen. Calm, poster-forward, virtualized for tens of thousands.

### Grid view (default)
```
┌─ Library ─────────────────────────────────────────────────────────┐
│ [⌕ Search]   Sort: Recently added ▾   Filter: All ▾   ▣grid ☰list  │ toolbar (chrome)
│ [+ Add folder] [+ Open video]                          [⋯]         │
├───────────────────────────────────────────────────────────────────┤
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐                        │
│  │post│ │post│ │ ⟳62│ │post│ │ ◷  │ │ ⚠  │   ← StatusChip overlay   │
│  │er  │ │er ✓│ │%   │ │er  │ │que │ │match│      only if not ready  │
│  └────┘ └────┘ └────┘ └────┘ └────┘ └────┘                        │
│  Title  Title  Title  Title  Title  Title                          │
│  2023   S2·E4  2019   2021   2020   ????                           │
│  ▔▔▔▔ (watch-progress bar on resumed)                              │
│  … (virtualized; scrolls to tens of thousands) …                   │
└───────────────────────────────────────────────────────────────────┘
```
- **Toolbar = chrome (LTR):** search (⌘F), sort (Recently added / Title / Year /
  Status / Recently watched), filter (All / Ready / In progress / Needs attention /
  Watched / Unwatched), grid/list toggle (⌘1/⌘2), add affordances.
- **Cards = TitleCard.** Ready titles show **no chip** (calm, P3); only
  queued/running/failed/needs-match show a chip. Watch progress = amber bar.
- **Continue-watching strip** (optional, top) = landscape TitleCards from
  `WatchState`.
- **Hierarchy:** posters dominate; chrome recedes; the only color is status.

### List view (⌘2)
TitleRow table: `Title · Status · Source · Updated · ⋯`. Sortable headers.
Denser; for power users managing big libraries.

### States
- **Empty:** EmptyState "Your library is empty." `[Add a folder] [Open a video]`
  (existing `_empty()` restyled).
- **Scanning:** thin indeterminate bar under toolbar + "Scanning… 1,204 files"
  (incremental/hash-based, SPEC §11) — non-blocking.
- **Engine offline:** OfflineBanner above grid (existing, retokenized to amber).
- **Artwork loading:** shimmer poster placeholders; never block scroll.
- **No artwork / low match:** film-strip placeholder + `attention` "Needs match".

**Components:** TitleCard, TitleRow, StatusChip, OfflineBanner, EmptyState,
search/sort/filter toolbar.

---

## 3. Title detail

Opened from a card. Metadata + the per-title processing controls.

```
┌─ ‹ Library ───────────────────────────────────────────────────────┐
│  ┌──────┐   Foundation  (2021–) · Series                           │ title-lg, mixed-dir
│  │poster│   ⁦8.3⁩ ★ · Sci-Fi · 2 seasons                            │ meta, isolated nums
│  │      │   ── overview text (TMDB) ──────────                     │
│  │      │   [ ▶ Resume 12:40 ]  [ Mark watched ]   [ Fix match ]   │ primary actions
│  └──────┘                                                          │
│ ──────────────────────────────────────────────────────────────────│
│  Subtitles                                                         │
│   Target language:  [ Hebrew ▾ ]   Quality: [ Auto (12B) ▾ ]       │
│   Source:  SourcePicker ─────────────────────────────────────────  │
│     (•) Transcribe audio (ASR)            [Recommended]            │
│     ( ) Translate embedded sub  [English]  — fastest               │
│     ( ) Use sidecar  movie.en.srt                                  │
│   Audio track: [ Track 1 · English · 5.1 ▾ ]                       │
│   [ Generate subtitles ]   [ Edit subtitles ]  [ Re-generate ]     │
│ ──────────────────────────────────────────────────────────────────│
│  Episodes (series)            ▣ Bible: Foundation ›                │ → bible review
│   ☰ S2·E1  ✓ Ready     ASR · he · v3        ▶                      │ TitleRows
│   ☰ S2·E2  ⟳ 62% transcribe                  ⋯                      │
│   ☰ S2·E3  ⚠ Failed — audio decode  [Retry]                        │
└───────────────────────────────────────────────────────────────────┘
```
- **Hierarchy:** poster + identity → primary watch action → subtitle controls →
  episode list (series) / single-file controls (movie).
- **Subtitle source** = SourcePicker (smart default). **Target language** dropdown
  (he default; "Generate" creates a per-lang artifact — multi-lang v3). **Audio
  track** picker only when >1 track.
- **Watch state:** Resume(position) / Continue / Mark watched (`WatchState`).
- **Bible link** present when title has a `ContextualParent` with a bible.

### States
- **Not yet processed:** "Generate subtitles" primary; no Edit link yet.
- **Processing:** inline StatusChip + progress; "Generate" → "View in queue."
- **Failed:** `status/failed` summary + `[Retry] [Choose another track] [Details]`.
- **Low TMDB confidence:** `attention` "Fix match" prominent; metadata marked
  "Unconfirmed."
- **No TMDB match at all:** filename-parsed title shown; "Fix match" primary.

**Components:** TitleRow, SourcePicker, StatusChip, ConfidenceMeter (match),
audio/lang dropdowns, watch buttons, TmdbMatchRow (via Fix match).

---

## 4. Character bible review & correction

Scoped to a `ContextualParent` (series/franchise). AI proposes; user corrects;
edits re-queue. Two-pane on macOS.

```
┌─ ‹ Foundation · Character bible ───────────────────────────────────┐
│  12 characters · bible v3 · [🔒 Lock bible]      [⌕ filter]        │
├──────────────────────────────┬────────────────────────────────────┤
│  CharacterCards (list/grid)  │   CharacterEditForm (selected)      │
│ ┌──────────────────────────┐ │  Canonical: [ Yael        ]         │
│ │ Hari ⁦·⁩ הארי              │ │  Hebrew:    [ יעל          ] (RTL) │
│ │ ♂ Male   ✓ corrected      │ │  Gender:  GenderSelector            │
│ ├──────────────────────────┤ │    [♂][●♀][⚥][?]                    │
│ │ Yael ⁦·⁩ יעל   ◀ selected  │ │  Aliases: [Yaeli ×][רב-סרן ×][+]   │
│ │ ♀ Female  Please review 41%│ │  Relations:[daughter of Hari ×]    │
│ ├──────────────────────────┤ │ ┌────────────────────────────────┐ │
│ │ Gaal ⁦·⁩ גאל               │ │ │⚠ Saving re-translates 3 titles,│ │ impact banner
│ │ ? Unknown  ⚠ set gender    │ │ │  ~410 lines. Your edits kept.  │ │
│ └──────────────────────────┘ │ └────────────────────────────────┘ │
│                              │  [ Re-translate ] [Save name] [Cancel]│
└──────────────────────────────┴────────────────────────────────────┘
```
- **Left pane:** CharacterCards. `proposed` show ConfidenceMeter; `unknown`
  gender flagged with `attention` "set gender" (the top cause of wrong Hebrew).
- **Right pane:** CharacterEditForm for the selected character. GenderSelector is
  the headline control. **Impact banner** recomputes live as fields change.
- **Save = consent moment:** ConfirmDialog "re-queue" variant; "Save name only"
  avoids re-translation when only a non-grammatical field changed.
- **Lock bible** (`lockedByUser`) freezes AI from proposing changes.

### States
- **Empty bible:** EmptyState "No characters yet. AutoSub suggests characters
  after the first episode is processed." (P1 honesty).
- **Editing dirty:** save enabled, impact banner shown.
- **Saving:** primary spinner; on success toast "Re-translating affected lines —
  track it in the queue." → Queue badge increments.
- **Save error:** inline "Couldn't save — engine offline. Retry."
- **Re-queue storm guard:** franchise-wide edits debounce + the dialog states the
  full scope before committing (SPEC risk #6).

**Components:** CharacterCard, CharacterEditForm, GenderSelector, ConfidenceMeter,
ConfirmDialog(re-queue), Toast.

---

## 5. Subtitle editor

Per-line edit · timing nudge · per-line AI re-translate · CPS feedback. RTL
editing central (RTL.md §7).

```
┌─ ‹ Foundation S2·E2 · Subtitles (Hebrew) ─────────────────────────┐
│  [▶ preview]  filter: [All ▾]  ⚠ 3 over-CPS   [Save ⌘S] [edited 5] │ toolbar
├───────────────────────────────────────────────────────────────────┤
│ #127  00:01:08,100 → 00:01:11,000   2.9s   CPS ▓▓▓▓░ 12/17        │ ← LTR strip
│       ────────────────────── ⁦Yael⁩, מה קרה? ──────  [✎][edited●]  │ ← RTL field
│ ─────────────────────────────────────────────────────────────────│
│ #128  00:01:12,300 → 00:01:14,800   2.5s   CPS ▓▓▓▓▓▓ 19/17 ⚠    │ over-limit
│       ───── שלום, יעל. מה שלומך היום, חברה? ─────  [✎ re-translate] │
│       ⚠ Reads too fast — shorten text or extend timing            │ CPS warning
│ ─────────────────────────────────────────────────────────────────│
│ #129  …                                                            │
└───────────────────────────────────────────────────────────────────┘
```
- Each row = **SubtitleLineRow**: LTR timecode/CPS strip + RTL text field.
- **CPSMeter** per line; over-limit → amber/red + inline warning.
- **Per-line re-translate** (`⌘R` / ✎ button) re-runs through the bible-aware LLM
  → row enters `re-translating` spinner, then updates.
- Editing a line sets `has_user_edits` (badge ●); user edits are protected from
  future AI overwrite (SPEC).
- **Timing nudge:** `⌥←/⌥→` on the focused row (time = pinned LTR).
- **Preview** plays from the selected cue so the editor sees the real render.

### States
- **Clean / dirty** (Save enabled, "edited N" count) / **saving** / **save
  error**.
- **Re-translating line:** field disabled + spinner; error → "Re-translate failed
  — retry."
- **CPS over limit:** non-blocking warning (auto-publish model, P6) but visible.
- **Empty / not generated:** "No subtitles yet. Generate them from the title."

**Components:** SubtitleLineRow, CPSMeter, Toast, ConfirmDialog(discard unsaved).

---

## 6. Player (enhanced)

libmpv video + revealable transport. **Transport pinned LTR** (RTL.md §2/§8);
subtitle text rendered RTL by libmpv. Remove the screen-level RTL wrapper that's
in the current `player_page.dart`.

```
┌───────────────────────────────────────────────────────────────────┐
│                                                                   │
│                        ( video fills )                            │
│                                                                   │
│        שלום, יעל. מה שלומך?     ← libmpv subtitle (RTL, centered)  │
│ ░░░░░░░░░░░░░░░░░░ scrim ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│  ▶  ⏪10 ⏩10  ──────●────────────  01:12 / 48:30  1.0×  CC  ⤢    │ TransportBar (LTR)
└───────────────────────────────────────────────────────────────────┘
            ▲ ⌘⇧S → RestyleOverlay (font/size/pos/color/outline)
```
- **Transport:** play/pause, ±10s, seek bar, time (`mono-time`), speed, **subtitle
  quick-toggle (CC / `S`)**, fullscreen. Hover-reveal, auto-hide 2.5s.
- **RestyleOverlay** (`⌘⇧S`): live subtitle restyle popover, RTL-aware.
- **Keyboard:** full DS §6.4 map; `←/→` are *always* seek (never mirrored).
- **Resume:** opens at `WatchState.position_sec`; updates watch state on close.

### States
- Loading/buffering (spinner over play) · no subtitle ("No subtitles for this
  title" caption — existing `_subStatus`) · scrubbing · fullscreen · controls
  hidden. Subtitle toggle disabled+captioned when no track.

**Components:** TransportBar, RestyleOverlay, StatusChip(buffering optional).

---

## 7. Processing / job queue

The persistent queue with full control (SPEC: auto-queue, pause/resume,
reprioritize, retry, auto-yield).

```
┌─ Queue ───────────────────────────────────────────────────────────┐
│  3 active · 2 queued · 1 failed     [⏸ Pause all] [▶ Resume all]    │ summary + bulk
│  ⓘ Paused while you're watching “Foundation S2E1”.                 │ auto-yield note
├───────────────────────────────────────────────────────────────────┤
│ ≡ Foundation S2·E2   Translate  ▓▓▓▓▓░ 62%   he · v3   [⏸][▲][⋯]   │ JobQueueRow running
│ ≡ Foundation S2·E5   ◷ Queued                          [▲][⋯]      │ queued (drag)
│ ≡ The Expanse 1·01   ⚠ Failed — audio decode  [Retry][Details]     │ failed
│ ──── Recently finished ────                                        │
│   Dune (2021)        ✓ Ready   ASR · he · v3                       │
└───────────────────────────────────────────────────────────────────┘
```
- **Rows = JobQueueRow:** stage + live progress + pause/resume + reprioritize
  (drag ≡ or ▲/▼ keys) + retry.
- **Auto-yield** surfaces as a calm info note (P3) — "Paused while you're
  watching," resumes automatically; not a failure.
- **Bulk controls:** Pause all / Resume all; failed group has "Retry all."
- **Stages** shown per SPEC §4 (Scan…Sync).

### States
- **Empty:** "Nothing in the queue. New titles are translated automatically."
- **All paused / auto-yielded** (note explains why).
- **Failed jobs grouped** with retry; engine offline → OfflineBanner + queue
  frozen with explanation.

**Components:** JobQueueRow, ProgressBar, StatusChip, OfflineBanner, EmptyState.

---

## 8. TMDB "fix match"

Low-confidence match → search → reassign. Dialog or pushed pane.

```
┌─ Fix match ───────────────────────────────────────────────────────┐
│  Current guess:  “Foundation 2021”  Please review 47%             │ ConfidenceMeter
│  [⌕ Search TMDB:  foundation 2021                    ] Searching… │
├───────────────────────────────────────────────────────────────────┤
│  [poster] Foundation (2021) · TV Series   ★8.3   [Current] [Select]│ TmdbMatchRow
│  [poster] Foundation (1973) · Movie               [Select]        │
│  [poster] The Foundation … · Movie                [Select]        │
└───────────────────────────────────────────────────────────────────┘
```
- Pre-filled query from filename parse; debounced TMDB search (name the network
  call). Select → reassigns `tmdbId` + re-pulls metadata/cast → may re-seed bible
  names (confirm if bible exists).
- **For series:** second step maps season/episode if the file's S/E parse is
  ambiguous.

### States
- Loading (skeleton) · empty ("No results — refine your search") · error
  ("Couldn't reach TMDB. Retry.") · reassigned (toast "Match updated.").

**Components:** TmdbMatchRow, ConfidenceMeter, search field, Toast.

---

## 9. Settings / preferences

Plain, grouped, calm (P4). Diagnostics OFF by default.

```
┌─ Settings ────────────────────────────────────────────────────────┐
│  Language & quality                                               │
│    Target language          [ Hebrew ▾ ]                          │
│    Quality tier             [ Auto · 12B ▾ ]  Auto-picked for M-Pro│
│  Subtitles                                                        │
│    Default styling          [ Customize… ]  → restyle panel       │
│    Reading speed (CPS)      [ 17 chars/s ▾ ]                       │
│  Library                                                          │
│    Folders                  /Movies  /Volumes/NAS/TV   [+ Add]     │
│  Storage                                                          │
│    Model location           /Volumes/EP2TB/…  ✓ mounted  [Change] │
│  Privacy                                                          │
│    Diagnostics              ( ●OFF )  Sends anonymized crash &     │
│                              usage data. Never your media,         │
│                              subtitles, or library.               │
│  Appearance                                                       │
│    UI text size             [ S  M  L  XL ]                        │
│  ─────────────────────────────────────────                        │
│    [ Clear library… ]  (media & sidecars kept)                    │
└───────────────────────────────────────────────────────────────────┘
```
- **SettingsRows** grouped under section headers; autosave with inline "Saved."
- **Diagnostics switch OFF default** is a hard requirement with the plain
  disclosure (P4).
- **Model location** shows mount status; changing it re-checks the drive.
- **UI text size** = the macOS Dynamic-Type substitute (DS §3.2.3).
- **Clear library** = existing ConfirmDialog.

**Components:** SettingsRow (all variants), ConfirmDialog, RestyleOverlay (styling),
path picker, StatusChip(mounted).

---

## v2 iOS — system-level deltas (not pixel-detailed)

Same tokens + shared components; different navigation grammar (DS §8).
- **Tab bar:** Library · Now Playing · Settings.
- **Library browse:** same TitleCard grid, touch targets ≥44pt, long-press →
  action sheet (instead of hover/⋯).
- **Light player + Now Playing:** large tap-reveal transport, lock-screen remote,
  `AVAudioSession` background audio; RestyleOverlay as a bottom sheet.
- **Sync status surface:** Bonjour/LAN state ("Synced from Mac · on Wi-Fi"), SMB
  streaming indicator, **offline pin/download** toggle per title (downloads video
  for on-the-go; `SyncRecord`/`SyncState`).
- Bibles are **read-only** on iOS in v2 (editable in v3 via merge prompt).

## v3+ — note only (don't over-design)
- **iCloud sync status + conflict-merge prompt:** when a bible edited on two
  devices conflicts (last-writer-wins + merge), a ConfirmDialog-style merge
  surface showing both versions field-by-field.
- **Multi-target-language switching:** per-title language chips; "Generate
  Hebrew / Spanish / …" on demand (artifacts keyed by lang).
