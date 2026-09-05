# VideoPlayerAutoSubs — remaining work (kickstart spec)

Phase 1 landed in `a97c017`: streaming ASR, pluggable LLM backends, M1-tuned defaults.
This document is the brief for everything still open. It is written to be handed
directly to an implementer (human or agent) without further context.

Machine this is tuned for: **Mac mini M1, 8 GPU cores, 16 GB unified memory, macOS 15.7.3.**
Every number below was measured on it. Re-measure before trusting any of it elsewhere.

---

## 1. `forceAsr` setting  ✅ (landed with this doc)

The canonical test fixture (`/Volumes/EP2TB/vpas-test/backrooms-41m40-90s.mkv`) carries an
embedded English subtitle track, and the app prefers embedded subs over ASR — so testing the
ASR path previously required a subtitle-stripped copy of the file. `forceAsr` makes one file
drive both paths: when set, `PlayerSession.open()` skips sidecar/embedded resolution entirely
and goes straight to chunked ASR.

---

## 2. Gender correctness — resolve the addressee, stop guessing it

**The defect.** Hebrew inflects the second person: `אתה/את`, `תזוז/תזוזי`, `שמח/שמחה`. Getting
those right requires knowing **who is being spoken to**. Today `prompts.ts` says:

> "When a line has a SPEAKER tag … infer the addressee from context."

The addressee is therefore a guess made by a 4B model from a 12-line window. Observed in real
output: a male character addressing a female character with masculine forms, and the hedge
`את/אתה` where the model could not decide.

**The fix — a real resolver, not a better hint.** Annotate every cue with a resolved addressee
before it ever reaches the model, using evidence in this order (highest confidence first):

1. **Vocative in the line.** The line contains a known character name or alias from the bible
   (`"Danny, move!"`, `"Careful, Maya."`). That name is the addressee. Handle leading/trailing
   vocatives and `"Name, ..."` / `"..., Name"` / `"..., Name?"` forms.
2. **Direct reply.** The previous cue had a different speaker and the gap is short (< ~4 s):
   in dialogue, a reply addresses the previous speaker.
3. **Two-hander scene.** Within the current scene (§3), exactly two characters speak: the
   addressee is whichever of the two is not the speaker.
4. **Group address.** The line contains a plural marker (`"everyone"`, `"team"`, `"guys"`) or
   the scene has ≥3 active speakers with no other evidence → addressee is a **group**, which in
   Hebrew takes masculine plural by convention. This case must be explicit, not accidental.
5. **Unknown.** No evidence. The prompt must then be told to prefer a **gender-neutral
   phrasing** rather than pick a form at random — a neutral rendering is a small stylistic
   cost, a wrong gender is an error a Hebrew speaker notices instantly.

Each cue carries `{ addressee?: string; addresseeGender?: Gender; addresseeSource: ... ; addresseeConfidence: number }`.
Only pass an addressee into the prompt when confidence clears a threshold; below it, pass
"unknown" and let the neutral-phrasing rule apply. **A confident wrong answer is worse than an
admitted unknown** — the model cannot recover from being told the wrong gender, but it can
handle "unknown".

**Prompt side.** Replace "infer the addressee" with an explicit per-line block, e.g.
`12: [SPEAKER: Maya (F)] [TO: Danny (M)] Danny, move!`, plus hard rules: second-person forms
must agree with `TO`, first-person with `SPEAKER`, and when `TO` is unknown use a neutral
construction instead of guessing. Never emit `את/אתה`-style double forms.

**This must be measured, not asserted** — see §4.

---

## 3. Scene-aware translation — replace the flat sliding window

**The defect.** Every batch sees only `recentPairs` translated lines plus `contextWindow`
upcoming source lines. There is no notion of *where we are in the film*. The result is
locally-fluent but contextually flat translation: the register drifts, recurring situational
terms get re-invented per batch, and a line whose meaning depends on the scene ("It's open."
— what is?) is translated literally.

**The fix — segment into scenes, summarise each once, inject the summary.**

1. **Segment** the cue list into scenes. Signals: silence gaps (a gap ≳ 8–10 s is a strong
   scene boundary), a change in the set of speakers, and large jumps in cue density. Keep
   scenes in the 10–120 s range; merge runts.
2. **Summarise** each scene once with the LLM — 1–2 sentences of *situation* (who is present,
   where, what is happening, emotional register), plus any scene-local terms. Cache it in the
   bible file keyed by scene index + `sourceSubsHash`. This is one cheap call per scene, not
   per batch, so it costs little and is reused across re-watches.
3. **Inject** the current scene's summary into the batch system prompt, and state that the
   register and terminology must be consistent within a scene.
4. **Ordering constraint:** with streaming ASR, later scenes do not exist yet. Summarise the
   scene containing the batch, on demand, from whatever cues that scene currently has; refresh
   it if the scene later grows substantially. Never block a JIT batch on a scene summary —
   translate without it and let the next batch benefit.

This is the "smart synopsis-driven translation" from the original brief: the title-level
synopsis is already in the bible; this adds the scene-level layer beneath it.

---

## 4. Measurement — a Hebrew quality eval (do this FIRST)

§2 and §3 are quality claims, and quality claims without measurement are decoration. Extend
`scripts/llm-bench.ts` with a graded Hebrew fixture so improvements are provable:

- **Gender agreement:** a hand-built set of ~20 lines whose correct Hebrew form is
  unambiguous given a known speaker and addressee (male→female, female→male, male→group, …).
  Grade by regex over the expected inflected forms — e.g. a line addressed to a woman must
  contain `תזוזי` and must not contain `תזוז`. Report **gender accuracy %** per model.
- **Context sensitivity:** a handful of lines that are ambiguous in isolation and
  disambiguated by the scene ("It's open." / "Take it." / "She's gone."). Grade by whether the
  chosen Hebrew word matches the scene-appropriate sense.
- **No-hedge check:** flag any output containing `את/אתה`, `נכנס/נכנסת` style double forms —
  these are the model refusing to commit and must count as failures.
- Report these **alongside** the existing speed/memory table, and re-run before/after §2–§3 so
  the improvement (or lack of it) is a number, not an impression.

Acceptance: gender accuracy ≥ 90% on the graded set for the chosen JIT model, zero hedges.

---

## 5. Phase 2 — HE↔EN in both directions

- `prompts.ts`: generalise the hard-coded "English → target" wording to `sourceLang → targetLang`;
  add an English target profile (English is *not* gendered, so the addressee machinery becomes a
  no-op — make that explicit rather than accidental).
- `bible.ts`: the `CharacterEntry.en` field becomes source-language; bump `schemaVersion` to 2
  and keep old cached bibles readable.
- Router already handles Hebrew audio (ivrit.ai model, language force-pinned to `he`); wire
  `sourceLang` through the settings UI and verify a Hebrew clip → English subtitles end to end.

---

## 6. Phase 3 — sync existing subtitles to audio

- `engine/sync/alass.ts`: shell out to `alass` (installed, 2.0.0) for global offset, drift and
  ad-split correction.
- `engine/sync/refine.ts`: DTW-align the sub text against ASR word timestamps (Parakeet gives
  these natively) and snap cue edges — alass fixes the global alignment, this fixes per-cue.
- Trigger automatically when a sidecar's first-cue offset vs ASR of the opening minutes exceeds
  ~300 ms; expose a manual "Sync subtitles" action too.
- Acceptance: take a correct SRT, shift +2.3 s and stretch 0.5%, re-sync → median cue error
  < 100 ms.

---

## 7. Quality-tier bake-off (COMPLETED)

Empirically measured via `scripts/llm-bench.ts` on Mac mini M1 (16 GB unified memory, 40-line dialogue set):

| Model | Backend | Gen tok/s | Resident GB | Valid % | Status | Verdict |
|-------|---------|-----------|-------------|---------|--------|---------|
| `qwen3.5:9b` | Ollama | **8.1** | **5.12 GB** | **100.0%** | PASS | **Selected `qualityModel`** (fastest, lightest, 0 hallucinated tags) |
| `translategemma:12b` | Ollama | 6.0 | 7.50 GB | 100.0% | PASS | High quality, but slower and 2.38 GB heavier |
| `gemma3:12b` | Ollama | 6.2 | 7.49 GB | 92.5% | FAIL | Fails valid line threshold (injects speaker vocatives) |
| Llama.cpp speculative pairs (`Qwen3.5-9B` + `0.8B`, `gemma-3-12b` + `1b`, `gemma-4-12b` + `E2B`) | llama-server | N/A | >10 GB | 0% | FAIL | **Metal buffer OOM** (`kIOGPUCommandBufferCallbackErrorOutOfMemory`). Target + draft + dual KV caches exceeds single-process Metal allocation ceiling on 16 GB Apple Silicon. Cannot run on 16 GB hardware. |

**Final Recommendation**: `qualityModel = 'qwen3.5:9b'` (background pass). `model = 'translategemma:4b'` remains the live JIT model (19.2 tok/s, 2.70 GB).

---

## Standing constraints

- **16 GB is the binding limit.** macOS ~3 GB + Electron/mpv ~1 GB + ASR 0.7–1.6 GB + LLM.
  A 6-minute clip test OOM-crashed the app with an IDE and Chrome open. Anything that raises
  the resident working set must be justified against this.
- ASR and the LLM share one GPU: keep everything behind `gpuLock` (`engine/resources.ts`).
- Test against the canonical fixture `/Volumes/EP2TB/vpas-test/backrooms-41m40-90s.mkv`
  (91.6 s, real film, English audio + embedded English subs as ground truth). Use `forceAsr`
  to exercise the ASR path on the same file.
- Never claim a quality improvement without a measurement from §4.
