# AI Subs Player — implementation orchestration

How to run the plan from `docs/ux-review/index.html`: which model does which task, in
what order, and the prompt that drives it.

Repository: `shmulious-student/subtitles-creator`, app under `VideoPlayerAutoSubs/`.
Branch: `claude/video-player-ux-review-rkthpq`.

---

## Model lineup and rates

| Model | ID | Context | Input $/MTok | Output $/MTok |
|---|---|---|---|---|
| Claude Fable 5.1 | `claude-fable-5-1` | 1M | 10.00 | 50.00 |
| Claude Opus 5 | `claude-opus-5` | 1M | 5.00 | 25.00 |
| Claude Sonnet 5 | `claude-sonnet-5` | 1M | 2.00 | 10.00 |
| Claude Haiku 4.5 | `claude-haiku-4-5` | 200K | 1.00 | 5.00 |

In Claude Code the subagent selector takes the short names `fable`, `opus`, `sonnet`,
`haiku`. Those are what the prompt below uses.

**How the tiers were assigned.** Fable 5.1 goes only where a wrong answer is expensive
to discover: native code and the async state machine around playback. Opus 5 takes work
that spans several files and has invariants to preserve (cache keys, IPC contracts,
third-party APIs). Sonnet 5 takes well-specified UI and wiring, which is most of the
plan by volume. Haiku 4.5 takes mechanical edits with an obvious pass/fail.

---

## Task → model

### Phase 1 — foundation and the spike (week 1–2)

| # | Task | Model | Why this tier |
|---|---|---|---|
| 1.1 | libmpv render-API native addon spike (N-API, `mpv_render_context`, Metal/OpenGL, HiDPI, fullscreen) | **fable** | C++/Objective-C++ against an unfamiliar C API, GPU callbacks on the wrong thread, HiDPI scaling. The one task where a plausible-but-wrong implementation costs days. Run at max effort. |
| 1.2 | Setup screen + Engines page: detection, Browse pickers, Test buttons, model pull with progress, defaults moved off the external drive | **opus** | Touches `config.ts`, `types.ts` defaults, `ipc.ts`, new React screens, and the existing `ollamaPull` progress event. Several files, real product judgment about what blocks the primary button. |
| 1.3 | Library persistence: remembered folders, rescan, Open File, drag and drop, recents, resume position store, Continue watching strip | **sonnet** | Well-specified CRUD plus standard Electron dialogs and a small JSON store. No hidden invariants. |
| 1.4 | Rename to AI Subs Player: `productName`, `appId` `io.smashgames.aisubsplayer`, window title, About, README | **haiku** | Mechanical, and the build either produces the renamed app or it does not. |

**Gate after 1.1.** One week, three exit criteria: first frame rendered inside the
BrowserWindow, seek plus ASS subtitle reload working, HiDPI and fullscreen geometry
correct. Pass means Phase 2 draws controls over the video. Fail means Phase 2 builds the
identical controls below the stage and the two-window glue stays. Nothing else in the
plan changes either way.

### Phase 2 — the player and the flow (week 3–4)

| # | Task | Model | Why this tier |
|---|---|---|---|
| 2.1 | Play first, prepare behind: split `PlayerSession.open` into load and prepare, cancellable, hot-swap the subtitle track when the runway covers the playhead | **fable** | An async state machine over mpv, the JIT scheduler and an abort signal. Seek during prepare, close during Whisper, and open-another-file mid-prepare are all real races. |
| 2.2 | Online subtitle search: OpenSubtitles REST plus Subdl, file-hash and title lookup, download into the cache, "Hebrew online" state, hash-matched Hebrew as default track | **opus** | Third-party API contracts, the OpenSubtitles hash algorithm, quota and error handling, and a new source-of-truth for which track plays. |
| 2.3 | Live corrections: per-cue bible hash, re-translate only affected lines, keep the cache, "Re-translate whole file" escape hatch | **opus** | Changes the cache key design in `scheduler/cache.ts`. Getting invalidation wrong silently discards work, which is exactly the bug this task exists to fix. |
| 2.4 | Player controls: keymap, native menu bar, fullscreen, volume, mute, audio track, subtitle mode, sub-delay, ±10 s, three-tone scrub bar, stage pills | **sonnet** | Broad but shallow. Each control is one mpv property and one button, against a contract task 2.1 already extended. |
| 2.5 | Docked side panel: Lines / Cast & terms / Info, follow-playback, click-to-seek, inline edit, retranslate with hint | **sonnet** | React panel over events that already exist. The hard half of corrections is 2.3. |
| 2.6 | Export subtitles: SRT and VTT from the cache, ⌘E, context menu, off-by-default auto-sidecar | **haiku** | A serializer with a reference implementation in the sibling app, plus one menu item. |

### Phase 3 — polish and consistency (week 5)

| # | Task | Model | Why this tier |
|---|---|---|---|
| 3.1 | Source-language detection and per-title target language override | **opus** | Both feed the translation cache key and the Bible. Cross-cutting. |
| 3.2 | Settings window: pages, Fast / Balanced / Quality presets mapped onto existing settings, Advanced with consequences | **sonnet** | Layout and a preset-to-settings mapping table. |
| 3.3 | One status vocabulary: merged per-path status, `StatusChip`, Needs-attention popover with actions | **sonnet** | A refactor with a clear target shape, touching three surfaces. |
| 3.4 | Queue view: per-item translate now / move to front / cancel, estimates, completion notification, dock badge, display-sleep prevention, collapsible library | **sonnet** | Queue manipulation over the existing `BackgroundTranslator`, plus small Electron APIs. |
| 3.5 | Replace emoji with an SVG icon set | **haiku** | Mechanical swap. |

### Phase 4 — deferred by decision

| # | Task | Model | Why this tier |
|---|---|---|---|
| 4.1 | Poster grid as the second library view, TMDB at scan time, thumbnail cache | **sonnet** | UI plus a cache, once rows are settled. |
| 4.2 | Idle Quality re-pass with `gemma3:12b` (D12: not now) | **opus** | Second cache slot and a version indicator. |
| 4.3 | LAN remote / mobile companion over the existing contract | **opus** | New transport for `api-contract.ts`. |

### Review passes

| When | Task | Model |
|---|---|---|
| End of each phase | `/code-review` at high effort over the phase diff | **opus** |
| Before any release build | `/security-review`, with attention to the OpenSubtitles key handling and the native addon | **fable** |

---

## Dependencies and what can run in parallel

```
1.1 spike ─────────────────────────────┐ (gate)
1.2 setup ──┐                          │
1.3 library ┼── parallel, worktrees    │
1.4 rename ─┘                          │
                                       ▼
                       2.1 play-first ──┬── 2.4 controls
                                        ├── 2.5 panel
                       2.2 online subs ─┘
                       2.3 corrections ──── 2.5 panel
                       2.6 export (independent)
                                       ▼
                       3.1 … 3.5 (3.1 first, rest parallel)
```

Rules that keep parallel work from colliding:

- Tasks 1.1 through 1.4 touch disjoint files, so run them as worktree-isolated agents.
- Everything in Phase 2 touches `ipc.ts`, `session.ts` or `App.tsx`. Run 2.1 alone first,
  merge it, then fan out 2.2 through 2.6.
- 2.4 and 2.5 both edit `App.tsx`. Run them in sequence, or in worktrees with 2.4 merged
  first.
- Never let two agents edit `electron/engine/types.ts` at the same time. Every settings
  addition lands through the agent that owns the phase.

---

## The orchestration prompt

Paste this into a fresh Claude Code session on the repository. It assumes the report at
`VideoPlayerAutoSubs/docs/ux-review/index.html` is present, which is where the decisions
and the mockups live.

```text
You are the orchestrator for the AI Subs Player implementation. The app is the Electron
player under VideoPlayerAutoSubs/ in this repository. Work on branch
claude/video-player-ux-review-rkthpq.

Read these first and treat them as the specification:
  - VideoPlayerAutoSubs/docs/ux-review/index.html   (audit, flow, UI system, mockups,
    the 14 recorded decisions, and the four-phase plan)
  - VideoPlayerAutoSubs/docs/ux-review/orchestration.md  (this task-to-model mapping)
  - VideoPlayerAutoSubs/README.md and the code under VideoPlayerAutoSubs/electron and
    VideoPlayerAutoSubs/src

The decisions are settled. Do not reopen them. In short: play immediately and prepare
subtitles behind the video; search OpenSubtitles and Subdl for every file and prefer a
hash-matched Hebrew file over our own translation; ask before running Whisper, with a
measured estimate; dock the Lines and Cast panels beside the video instead of over it;
library gets both a row list and a poster grid, rows first; corrections re-translate only
affected lines and keep the cache; Fast/Balanced/Quality presets with the raw knobs under
Advanced; single-window playback via a libmpv render-API addon comes first as a
time-boxed spike; global target language with a per-title override; the product is named
AI Subs Player with bundle id io.smashgames.aisubsplayer; export is manual with an
off-by-default auto-sidecar; no idle quality re-pass for now.

How to run the work:

Delegate each numbered task to a subagent with the model named in orchestration.md. Use
the general-purpose agent type, pass model: "fable" | "opus" | "sonnet" | "haiku" exactly
as the table says, and do not substitute a cheaper model to save budget. Run tasks in the
stated order and respect the parallelism rules. Where the table marks tasks as parallel,
launch them in one message with isolation: "worktree" so they do not fight over the same
files, then merge them one at a time and resolve conflicts yourself.

Every subagent brief must contain: the task number and title, the exact acceptance
criteria from the plan, the files it is expected to touch, the files it must not touch,
and the instruction to run `npm run build` in VideoPlayerAutoSubs (which runs tsc
--noEmit and vite build) plus the relevant smoke script (npm run smoke:sched, npm run
smoke:mpv) before reporting done. A subagent that cannot make the build pass reports the
failure rather than weakening types or deleting a check.

Start with task 1.1, the libmpv render-API native addon spike, on the fable model at max
effort. Time-box it. Its three exit criteria are: a first frame rendered inside the
Electron BrowserWindow, seek plus ASS subtitle reload working through the existing JSON
IPC controller, and correct geometry under HiDPI and fullscreen. While it runs, launch
1.2, 1.3 and 1.4 in parallel worktrees on opus, sonnet and haiku respectively.

When the spike reports back, tell me the outcome and which branch of the plan we are on
before starting Phase 2. If it passed, Phase 2 draws the player controls over the video.
If it failed, Phase 2 builds the same controls below the stage and we keep the two-window
mpv glue. Do not make that call silently.

After each phase: run /code-review at high effort over the phase diff on the opus model,
fix what it finds, then commit and push. Commit messages describe the change and its
reason, one commit per task, no model names in the message. Do not open a pull request
unless I ask.

Report to me at each phase boundary and at every gate. Between those points, keep going
without asking permission for work the plan already specifies.
```

---

## Running the phases separately

If you would rather drive one phase at a time, replace the last three paragraphs of the
prompt with the phase you want, keeping the specification and delegation paragraphs. The
model assignment does not change.

For a single task, the shortest useful form is:

```text
Implement task 2.2 from VideoPlayerAutoSubs/docs/ux-review/orchestration.md. Read the
report at VideoPlayerAutoSubs/docs/ux-review/index.html for the flow, the dialog and the
library states it has to produce. Delegate it to a general-purpose subagent on the opus
model. Build must pass before you report done.
```

---

## Cost expectation

The plan is roughly five weeks of one developer's work. Spend is dominated by Phase 1's
spike and Phase 2, because those are the Fable and Opus tasks; Phase 3 is mostly Sonnet
and is comparatively cheap. Two levers if the bill matters more than wall-clock: run the
Sonnet tasks at lower effort, and let the Haiku tasks run unattended. Do not move task
1.1 or 2.1 down a tier. Those are the two places where a wrong answer is discovered days
later, in a native crash log or a race that only shows up on a cold file.
