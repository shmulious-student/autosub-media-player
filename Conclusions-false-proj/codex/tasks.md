# AI Subs Player — task breakdown for Codex

Twenty tasks in four phases. Each names the model, the reasoning effort, what "done" means,
and which files it owns. Run them in order. Where tasks are marked parallel, they touch
disjoint files and can run in separate worktrees.

Model shorthand used below and in `run-plan.sh`:

| Shorthand | Model | Rate in/out per MTok |
|---|---|---|
| `astra` | `gpt-6-astra` | 10 / 50 |
| `sol` | `gpt-5.6-sol` | 5 / 30 |
| `terra` | `gpt-5.6-terra` | 2 / 12 |
| `luna` | `gpt-5.6-luna` | 0.20 / 1.20 |

Every task ends with `npm run build` passing. Tasks touching the scheduler also run
`npm run smoke:sched`; tasks touching the player also run `npm run smoke:mpv`.

---

# Phase 1 — foundation and the spike

## 1.1 libmpv render-API native addon spike

**Model** `astra` · **Effort** `xhigh` · **Time-box** one week · **Parallel with** 1.2, 1.3, 1.4

Build a Node native addon that renders mpv into the Electron window, replacing the current
borderless on-top mpv window glued over the stage.

The current design spawns the mpv binary and aligns a separate always-on-top window over a
div (`electron/player/mpv.ts`, `electron/ipc.ts` `applyGeometry`, `src/player/MpvStage.tsx`).
It works but nothing can be drawn over the video, fullscreen is fragile, and fast window
drags lag. The fix is libmpv's render API driving a texture the renderer composites.

**Exit criteria, all three required:**

1. A first video frame renders inside the Electron BrowserWindow, not a separate window.
2. Seek and ASS subtitle reload work through the existing JSON-IPC controller surface.
3. Geometry is correct on a HiDPI display and in fullscreen, with no letterbox drift.

**Notes.** mpv's `--wid` embedding is not usable from Electron on macOS, and mpv.js is
unmaintained, so the render API through N-API is the route; IINA does the equivalent in
Swift. Expect Objective-C++ for the Metal or CAOpenGLLayer surface. The render callback
arrives on mpv's thread, not the main thread; marshal it correctly or you will get
intermittent crashes that look like unrelated bugs.

**Report back either way.** If the spike fails, say which criterion failed and why. A
failed spike is a valid outcome: the plan then keeps the two-window design and puts the
player controls below the stage. Do not partially land a broken addon.

**Owns** a new `electron/player/render/` directory, `binding.gyp`, native sources, and
build scripts in `package.json`.
**Must not touch** `src/`, `electron/session.ts`, `electron/scheduler/`, `electron/engine/`.

---

## 1.2 Setup screen and Engines page

**Model** `sol` · **Effort** `high` · **Parallel with** 1.1, 1.3, 1.4

A first-run screen that detects everything the app needs and offers a fix for each row,
plus the Engines page in Settings that shows the same information permanently.

**Rows:** mpv (required), ffmpeg/ffprobe (required), Ollama (required, the app manages its
own server on port 11435), translation model (required, offer the pull with progress),
Whisper binary and model (optional), OpenSubtitles account (optional), TMDB key (optional),
storage folder.

**Acceptance criteria**

- Each row shows detected/not-detected with the resolved path and version where available.
- Each row has a working fix: Locate… (native file picker), Download (uses the existing `ollamaPull` IPC and its progress event), Paste key…, Choose folder…, Sign in….
- Required rows gate the primary button; optional rows never block it.
- Defaults in `DEFAULT_SETTINGS` no longer point at `/Volumes/EP2TB/StoryBookProject`. They resolve under the app's own support folder. An existing `settings.json` keeps its values.
- The screen appears on first launch and from a "Check setup" action. It is not a modal over the video.
- Test buttons actually run something: `mpv --version`, `ffprobe -version`, an Ollama ping.

**Owns** `src/panels/SetupScreen.tsx`, `src/panels/EnginesPage.tsx`, `electron/config.ts`,
detection helpers in `electron/engine/media.ts`, and the defaults block in
`electron/engine/types.ts`.
**Must not touch** `src/App.tsx` beyond adding the route, `electron/session.ts`,
`electron/scheduler/`.

---

## 1.3 Library persistence and entry points

**Model** `terra` · **Effort** `medium` · **Parallel with** 1.1, 1.2, 1.4

**Acceptance criteria**

- Library folders persist across relaunch and rescan on launch and on demand.
- File → Open File (⌘O) and Add Folder (⇧⌘O) both work; a dropped file or folder anywhere on the window does the same thing.
- Open Recent lists the last ten videos.
- Playback position is stored per video hash, written on pause, on close and every ten seconds, and restored on open.
- A "Continue watching" strip shows in-progress titles with a progress bar, newest first.
- A single dropped file plays immediately and appears under a "Loose files" group.

**Owns** `electron/library.ts`, a new `electron/store.ts` for persisted UI state,
`src/library/`, drop handling in `src/App.tsx`.
**Must not touch** `electron/session.ts`, `electron/scheduler/`, `electron/engine/types.ts`.

---

## 1.4 Rename to AI Subs Player

**Model** `luna` · **Effort** `low` · **Parallel with** 1.1, 1.2, 1.3

Rename throughout: `productName` to `AI Subs Player`, `appId` to
`io.smashgames.aisubsplayer`, the window title, the sidebar brand block, the README title,
and the About box. Keep the npm package name and the directory as they are; only the
product identity changes.

**Acceptance criteria** `npm run build` passes and `npm run pack` produces an app bundle
named "AI Subs Player". No occurrence of the old product name remains in user-visible
strings.

**Owns** `package.json`, `index.html`, `src/library/LibraryPanel.tsx` header, `README.md`.
**Must not touch** anything under `electron/`.

---

## GATE — after 1.1

Decide, with the human, which branch of the plan applies.

- **Spike passed:** Phase 2 draws player controls over the video, and task 2.4 includes hover-to-reveal and auto-hide.
- **Spike failed:** Phase 2 builds the identical controls below the stage, exactly where the current transport bar sits, and the two-window glue stays.

Nothing else in the plan changes.

---

# Phase 2 — the player and the flow

## 2.1 Play first, prepare behind

**Model** `astra` · **Effort** `xhigh` · **Runs alone.** Merge before starting 2.2–2.6.

Today `PlayerSession.open` resolves subtitles, may run Whisper, starts Ollama, calls TMDB
and Wikidata, runs an LLM bible pass and opens the cache before mpv is ever handed the
file. The user waits from ten seconds to several minutes at a blank stage.

Split it into **load** (hash the file, hand it to mpv, select any existing embedded or
sidecar subtitle track — under a second) and **prepare** (everything else, async and
cancellable). When the translation runway covers the playhead plus ten seconds, swap the
ASS track in without interrupting playback.

**Acceptance criteria**

- Time from click to first frame is under one second on a cached or uncached file alike.
- A stage pill shows the current prepare step: Finding subtitles → Building context → Translating ahead. It sits top-left and never covers the picture centre.
- When a cache already exists, the target-language track is selected immediately and no pill appears.
- Seeking during prepare, closing during prepare, and opening a different file during prepare all behave correctly and leave no orphaned work. Verify each explicitly.
- Cancellation propagates: the abort signal reaches Whisper, the bible builder and the scheduler.
- The setting "show the source line until its translation is ready" is honoured.

**This is the race-condition task.** The failure mode is not a compile error, it is a
scheduler still writing cues for a file the user closed. Reason about the state machine
before writing code, and say in your report which interleavings you checked.

**Owns** `electron/session.ts`, `electron/ipc.ts` open/close paths, `electron/player/sub-feeder.ts`,
the `OpenResult` shape in `electron/api-contract.ts`.
**Must not touch** `src/panels/`, `src/library/`, `electron/metadata/`.

---

## 2.2 Online subtitle search

**Model** `sol` · **Effort** `high` · **After** 2.1 · **Parallel with** 2.3, 2.6

Query OpenSubtitles and Subdl for every library file, by file hash and by parsed title.

**Acceptance criteria**

- OpenSubtitles REST integration with the documented file-hash algorithm (first and last 64 KiB plus file size), a free developer key, quota-aware error handling, and optional account sign-in from Setup.
- Subdl as a second free source when OpenSubtitles returns nothing.
- Results are cached on disk next to the other caches, keyed by video hash.
- A hash-matched target-language file becomes the default subtitle track. A non-hash match is offered but never auto-selected. Our own translation is always available in the Subtitles menu as a second entry.
- A source-language match with no target match is used as the translation source instead of running Whisper.
- Library rows gain the "Hebrew online" state; the no-subtitles dialog offers the online result as its first, recommended option.
- Network failure degrades quietly to the existing behaviour and never blocks playback.

**Cost note.** OpenSubtitles has a free tier with a small per-user daily download quota and
a paid VIP tier around 15 USD per year for a much larger quota. Confirm both at build time;
the numbers in the UX report are approximate. Do not hardcode a key.

**Owns** a new `electron/metadata/opensubtitles.ts` and `electron/metadata/subdl.ts`,
subtitle-source selection in `electron/engine/media.ts`.
**Must not touch** `electron/scheduler/`, `src/App.tsx`.

---

## 2.3 Live corrections without losing the cache

**Model** `sol` · **Effort** `high` · **After** 2.1 · **Parallel with** 2.2, 2.6

Today the translation cache header stores one `bibleHash` for the whole file, so correcting
a single character's gender after a full pre-translation silently discards every translated
line on next open. That is the worst bug in the product: it punishes the user for improving
the output.

**Acceptance criteria**

- The bible hash is stored per cue, not per file. An existing cache migrates rather than being thrown away.
- Saving a correction re-translates only the cues whose text mentions the changed character, any of its aliases, or the changed term. It happens live, while the video plays.
- A "Re-translate whole file" action remains available for gender changes that affect lines never naming the character.
- The panel footer shows "Re-translating N lines" and the count is accurate.
- Corrected entries persist to the bible on disk and survive a reopen.
- `npm run smoke:sched` still passes.

**Owns** `electron/scheduler/cache.ts`, `electron/bible.ts`, the re-translate path in
`electron/session.ts`.
**Must not touch** `src/`, `electron/metadata/`.

---

## 2.4 Player controls

**Model** `terra` · **Effort** `medium` · **After** 2.1 · **Before** 2.5

Everything a viewer expects and the app currently lacks. mpv exposes all of it; none of it
is wired.

**Acceptance criteria**

- Keymap exactly as `design-spec.md` specifies, owned by the renderer and forwarded over IPC.
- A native macOS menu bar with the File, Playback, Subtitles, View and Help menus from the spec, shortcuts matching the keymap.
- Fullscreen, volume, mute, audio track selection, subtitle mode (target / both / source / off), subtitle delay in 100 ms steps, ±10 s, speed from 0.5 to 2 in 0.25 steps.
- Three-tone scrub bar: played, translated, not yet translated, plus a timecode tooltip on hover.
- Controls reveal on mouse move and hide after 2.5 s of stillness. Placement depends on the phase-1 gate: over the video if the spike passed, below the stage if it did not.
- The contract in `api-contract.ts` gains `setVolume`, `setMute`, `setFullscreen`, `setAudioTrack`, `setSubMode`, `setSubDelay`, and a track list on open.

**Owns** `src/player/`, the transport and keymap, `electron/player/mpv.ts` property setters,
menu construction in `electron/main.ts`.
**Must not touch** `electron/session.ts`, `electron/scheduler/`.

---

## 2.5 Docked side panel

**Model** `terra` · **Effort** `medium` · **After** 2.3 and 2.4

Replace the Bible drawer and the Settings modal, both of which hide the video today by
dropping mpv's on-top flag.

**Acceptance criteria**

- A 320 px panel docks on the right and shrinks the stage. The video stays visible. `setStageVisible` is no longer used to hide mpv for UI.
- Tabs: Lines, Cast & terms, Info. Toggled with ⌘2 and ⌘3, closed with Escape.
- Lines follows the playhead, scrolls to the active cue, and seeks on click. Pending cues show the source text in a dimmed style.
- A line can be edited inline; the change reaches the ASS file and the cache immediately.
- "Retranslate…" accepts a free-text hint and re-runs that single cue through the express lane.
- Cast & terms shows each character's name, target rendering and gender, with the gender's source labelled. Anything sourced from the model rather than Wikidata is visually flagged.
- Info shows poster, synopsis, the subtitle source and track language, the model in use and the cache size.

**Owns** `src/panels/`, panel layout in `src/App.tsx`.
**Must not touch** `electron/scheduler/`, `electron/bible.ts`.

---

## 2.6 Export subtitles

**Model** `luna` · **Effort** `low` · **After** 2.1 · **Independent**

**Acceptance criteria**

- Export writes a valid SRT or VTT from the translation cache, with correct RTL marking, reusing the approach in the sibling app's `electron/core/srt.ts` at the repository root.
- Reachable from ⌘E, the File menu and the library row context menu.
- A Settings switch, **off by default**, writes `<name>.he.srt` next to the video when a title reaches 100%.
- Exporting a partially translated title is allowed and warns how many lines are missing.

**Owns** a new `electron/export.ts`, the menu item, the settings switch.
**Must not touch** `electron/scheduler/cache.ts` beyond reading it.

---

# Phase 3 — polish and consistency

## 3.1 Source language detection and per-title target override

**Model** `sol` · **Effort** `high` · **First in phase 3**, because it changes cache keys

**Acceptance criteria**

- Source language comes from the subtitle track tag, falling back to detection over the first fifty cues. It is shown in the Subtitles menu and can be overridden.
- Target language has a global default and a per-title override that persists.
- Both participate in the cache key, and changing either does not corrupt or silently discard other titles' caches.
- Embedded-track selection no longer assumes English.

**Owns** `electron/engine/media.ts` track selection, `electron/engine/types.ts` settings and
per-title state, cache key composition.
**Must not touch** `src/panels/SettingsPanel.tsx` layout (that is 3.2).

---

## 3.2 Settings window with presets

**Model** `terra` · **Effort** `medium` · **After** 3.1

**Acceptance criteria**

- Settings opens as its own window on ⌘, and never as a modal over the video.
- Pages: General, Subtitles, Translation, Engines, Metadata, Storage, Advanced.
- Translation offers Fast, Balanced and Quality presets that set model, batch size, concurrency, translate-ahead and idle behaviour together. The mapping table lives in code, documented.
- Advanced exposes every remaining field in `AppSettings`, each with a one-line consequence, and marks which preset a drifted value came from.
- Subtitles page previews size and outline live and pushes changes to mpv immediately.
- Booleans are switches, not two-option selects.

**Owns** `src/panels/SettingsPanel.tsx` and the new settings pages.
**Must not touch** `electron/`.

---

## 3.3 One status vocabulary

**Model** `terra` · **Effort** `medium`

Today the same title reads "100%", "ready", "context…", "ASR 40%", "queued" or "43%
translated" depending on which surface you look at.

**Acceptance criteria**

- One merged status per file path, derived from the session, background queue and title events.
- One `StatusChip` component renders all seven states: Instant, Ready, Preparing, Transcribing, Translating, Queued, Needs attention.
- "Needs attention" opens a popover with the message and at least one action: Open setup, Retry, or Choose subtitle file.
- Engine jargon is gone from user-visible strings. No "bible", "JIT", "ASR", "coverage", "lookahead".

**Owns** a new `src/components/StatusChip.tsx`, status merging, label copy across the renderer.
**Must not touch** `electron/scheduler/`.

---

## 3.4 Queue view and system integration

**Model** `terra` · **Effort** `medium`

**Acceptance criteria**

- Per-item and per-season actions: Translate now, Move to front, Remove from queue.
- A queue panel shows what is running and what is next, with a time estimate from measured throughput.
- Display sleep is prevented while playing, via `powerSaveBlocker`, and released on pause and close.
- A system notification fires when the queue drains; the dock badge shows the number of running items.
- The library sidebar collapses with ⌘1 and optionally auto-hides during playback.

**Owns** `electron/background.ts` queue manipulation, `src/library/QueuePanel.tsx`, power and
notification code in `electron/main.ts`.
**Must not touch** `electron/session.ts`.

---

## 3.5 Icon set

**Model** `luna` · **Effort** `low`

Replace every emoji used as an icon (⚙, ⚡, ⏸, ▶, ❚❚, 🔊) with inline SVG from a
permissively licensed set such as Lucide. Icons take colour from the current text colour so
they participate in state styling.

**Owns** a new `src/components/icons/`, and the call sites.
**Must not touch** `electron/`.

---

# Phase 4 — deferred by decision

Do not start these without the human asking.

## 4.1 Poster grid library view

**Model** `terra` · **Effort** `medium`. A second library view toggled against the row list,
with TMDB lookups at scan time and a thumbnail cache on disk. Rows remain the default.

## 4.2 Idle quality re-pass

**Model** `sol` · **Effort** `high`. Deferred by decision 13. Would need a second cache slot
per title and a clear indicator of which version is on screen.

## 4.3 LAN remote companion

**Model** `sol` · **Effort** `high`. The IPC surface in `api-contract.ts` is already
transport-agnostic; this adds an HTTP/WebSocket server and a thin phone remote.

---

# Review passes

| When | Task | Model | Effort |
|---|---|---|---|
| End of each phase | Review the phase diff for correctness bugs and simplifications; fix what it finds | `sol` | `high` |
| Before any release build | Security review, with attention to the OpenSubtitles key handling, the native addon's memory and thread safety, and anything written outside the app's own folders | `astra` | `xhigh` |
