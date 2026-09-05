# Project Handoff & Knowledge Transfer: Lessons & Proven Solutions from `VideoPlayerAutoSubs`

> **To the Handling Agent on `autosub-media-player`:**
> This folder (`Conclusions-false-proj/`) contains the architectural research, empirical benchmarks, hardware stress tests, UX specifications, and algorithmic solutions developed and battle-tested on **VideoPlayerAutoSubs** (an Electron/Node/mpv sister project).
>
> Although that project had a different UI/wrapper layer (Electron/TypeScript vs. Flutter/Dart + Swift engine), **the core media processing, AI inference constraints, Hebrew linguistic problems, subtitle alignment, and M1 hardware realities are 100% identical**.
>
> Your mission is to **extract, adapt, and implement these proven algorithms, benchmark conclusions, and architectural patterns into `autosub-media-player`**.

---

## 📂 Inventory of Transferred Documents

| Document / Subfolder | Core Contents & Focus |
|:---|:---|
| **[`findings-and-benchmarks.md`](findings-and-benchmarks.md)** | **Empirical Hardware Benchmarks & Algorithmic Solutions:** Real measurements on Mac mini M1 (16 GB unified RAM), Metal GPU buffer OOM post-mortems for speculative decoding, Hebrew gender resolution ladder, scene-aware segmentation, bidirectional HE↔EN translation, and DTW + Theil-Sen subtitle synchronisation (<26 ms error). |
| **[`remaining-work.md`](remaining-work.md)** | **Kickstart Technical Spec:** Implementation blueprint covering the `forceAsr` testing bypass, the Hebrew quality grading suite, schema versioning for Character Bibles, and the 16 GB unified memory budget. |
| **[`ux-review/index.html`](ux-review/index.html)** | **Interactive UI/UX Review & Decision Record:** Full design audit, 14 architectural product decisions, stage geometry (single-window libmpv vs overlay), interactive mockups, docked side panels, and phase roadmaps. |
| **[`ux-review/orchestration.md`](ux-review/orchestration.md)** | **Subagent Orchestration & Parallelism Guidelines:** Dependency graphs, state-machine synchronization rules, model-to-task tiering, and prompt structures. |
| **[`codex/design-spec.md`](codex/design-spec.md)** | **UI Design System Contract:** Color tokens, typography, 4pt spacing grid, 7-state status vocabulary (`StatusChip`), and keyboard shortcuts. |
| **[`codex/tasks.md`](codex/tasks.md)** & **[`run-plan.sh`](codex/run-plan.sh)** | **Granular Task Breakdown:** Phase-by-phase implementation tasks with acceptance criteria, exit gates, and validation routines. |

---

## 🎯 Top High-Value Takeaways to Port to `autosub-media-player`

### 1. Apple Silicon (M1 16GB) Memory & Metal GPU Allocations
- **Speculative Decoding is Incompatible with 16GB Apple Silicon:**
  - Attempting to run dual models (e.g. Qwen 9B/12B target + 0.8B draft + dual KV caches + Metal graph scratchpads) in `llama-server` causes `kIOGPUCommandBufferCallbackErrorOutOfMemory`. macOS rejects contiguous shared GPU allocations over ~10 GB in a single process.
  - **Action for `autosub-media-player`:** Do not attempt multi-model speculative decoding on 16GB unified memory devices. Rely on single-model execution or discrete lightweight quantization (e.g. `translategemma:4b` for live JIT, `qwen3.5:9b` for offline background quality pass).
- **GPU Concurrency Lock (`gpuLock`):**
  - ASR (WhisperKit) and LLM inference share the same 8-core Apple Silicon GPU. Simultaneous execution causes severe frame drops, thermal throttling, or kernel memory pressure. Always gate ASR and LLM through a serial GPU mutex/lock.

### 2. Hebrew Gender & Dialogue Addressee Resolution Ladder
- **The Core Problem:**
  - Hebrew inflects second-person verbs, pronouns, and adjectives by gender (`אתה/את`, `תזוז/תזוזי`, `בטוח/בטוחה`).
  - Giving a 4B/9B LLM raw dialogue cues results in severe misgendering or cowardly hedges (`את/אתה`, `רוצה/רוצה`).
- **The Proven Solution:**
  - Pre-resolve addressees deterministically before prompting via a 5-step ladder:
    1. **Vocative Parsing in Cue** (`"Danny, move!"` → Danny [M], confidence: 0.95).
    2. **Direct Reply** (Previous cue had a different speaker, gap < 4.0s, confidence: 0.85).
    3. **Two-Hander Scene** (Process of elimination if only 2 speakers are in the scene, confidence: 0.75).
    4. **Group Address** (`"everyone"`, `"guys"` → explicit masculine plural in Hebrew, confidence: 0.90).
    5. **Unknown** (Confidence 0.00 → instruct the model to use **gender-neutral phrasing**; never pick randomly, strictly forbid `את/אתה` slashes).
  - Format prompts with explicit bindings: `[SPEAKER: Maya (F)] [TO: Danny (M)] Danny, move!`.
- **Action for `autosub-media-player`:** Port this resolver into `engine/Sources/` (Swift) or Dart dialogue pre-processing pipeline.

### 3. Scene-Aware Context Segmentation
- **The Problem:** A naive sliding window (e.g. 10–12 lines) loses situational context. Words like *"It's open"* are translated blindly without knowing if the characters are referring to a door, a container, or an open schedule.
- **The Solution:**
  - Segment cues into narrative scenes based on: (a) silence gaps $\ge 8\text{ s}$, (b) character speaker population shifts, and (c) cue density jumps. Clamped between 10s and 120s.
  - Generate a 1–2 sentence situational synopsis per scene (cached in the Character Bible).
  - Inject this synopsis into the translation prompt for all batches within that scene.

### 4. Subtitle Synchronization Engine (alass + DTW/Theil-Sen Refinement)
- **The Limitation of `alass` Alone:**
  - `alass` only tests standard discrete framerate ratios ($24/23.976$, etc.). When a subtitle file has an arbitrary drift/stretch (e.g. $+0.5\%$), `alass` only applies a global offset, leaving >150 ms residual drift.
  - `alass` split-detection often breaks short clips into nonsensical chunks unless `--no-split` (`-l`) is passed.
- **The 2-Stage Hybrid Solution (Proven <26 ms median error):**
  - **Stage 1 (Macro Alignment):** Run `alass` with `--no-split` to correct large global timeline offsets.
  - **Stage 2 (Acoustic DTW Alignment & Theil-Sen Robust Regression):**
    - Align subtitle cue tokens against acoustic word timestamps from ASR (WhisperKit word-level timestamps).
    - Use regex tokenizer splitting on `[\s\-—–]+` to prevent hyphenated stutter (`I-I-I`) from breaking alignment.
    - Extract speech onset anchors (`tokenIdx <= 1`).
    - Apply **Theil-Sen robust linear regression** across pairwise anchors separated by $\ge 15\text{ s}$ to determine true continuous drift and slope.
    - Calibrate intercept with $+100\text{ ms}$ lead-in time (standard human reading buffer).
    - Snap cue start/end bounds to speech boundaries with monotonicity enforcement and minimum 20 ms gaps.

### 5. Automated Hebrew Quality Evaluation Suite
- Quality claims must be measured, not asserted.
- Port the evaluation test harness from `findings-and-benchmarks.md` / `scripts/llm-bench.ts` into Flutter/Dart/Swift test suites:
  - Gender agreement test matrix (M→F, F→M, M→Group).
  - Polysemous context disambiguation tests.
  - Regex hedge detector (`את/אתה`, `יודע/ת` flags).

### 6. UX & Architecture Insights
- **Live Playback vs. Background Processing:**
  - Play video immediately with embedded/online subtitles if present.
  - Do not block the player on ASR. Run background preparation and hot-swap the subtitle track when runway is established.
- **Online Subtitle Deduplication:**
  - Check OpenSubtitles / Subdl hashes first. If an accurate Hebrew subtitle already exists, avoid running expensive local ASR + LLM translation.
- **Incremental Cache & Invalidation:**
  - Cache translations per cue hash (incorporating source text + resolved speaker + resolved addressee + scene summary).
  - When user edits a character name/gender in the Bible, invalidate and re-translate **only affected cues**, rather than the entire file.

---

## 🚀 How the Handling Agent Should Proceed

1. **Read this `HANDOFF.md` and `findings-and-benchmarks.md` first.**
2. **Review the existing `autosub-media-player` implementation** in `lib/` (Flutter) and `engine/Sources/` (Swift).
3. **Map the missing features/optimizations** against the proven solutions listed above.
4. **Prioritize implementation:**
   - **Step 1:** Implement the Addressee Resolution Ladder & Prompt Template formatting in the engine.
   - **Step 2:** Implement Scene Segmentation and Synopsis injection.
   - **Step 3:** Implement DTW + Theil-Sen per-cue subtitle sync refinement.
   - **Step 4:** Wire the automated quality benchmark / test suite to prevent regressions.
