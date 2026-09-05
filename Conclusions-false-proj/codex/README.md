# Running the AI Subs Player plan in OpenAI Codex

This directory is the Codex port of the plan in `docs/ux-review/index.html`. It carries
the same tasks, the same order and the same design, with OpenAI models chosen to match
the original Claude assignment on price and on strength.

| File | Purpose |
|---|---|
| `../../AGENTS.md` | Project instructions Codex loads before any task |
| `tasks.md` | The 20 numbered tasks: model, effort, acceptance criteria, file ownership |
| `design-spec.md` | The UI system in plain markdown, so no task has to parse the HTML report |
| `config.toml` | Codex profiles, one per model tier |
| `run-plan.sh` | Driver that runs the phases in order with the right model per task |

---

## Model mapping

Prices are per million tokens, gathered September 2026 from public pricing pages. OpenAI's
own docs were unreachable from the machine that wrote this, so **verify the two rates you
care about before you budget against them.**

| Original (Claude) | Rate in/out | Codex model | Rate in/out | Why this is the match |
|---|---|---|---|---|
| Fable 5.1 | 10 / 50 | **GPT-6 Astra** | 10 / 50 | Identical price, and the same role in its lineup: top tier, sold on long-horizon agentic and software engineering work. The one-for-one swap. |
| Opus 5 | 5 / 25 | **GPT-5.6 Sol** | 5 / 30 | Input matches exactly, output is 20% higher. Flagship-minus-one on both sides. Use GPT-5.5 instead if your account has it and Sol does not; it is the same 5 / 30 rate. |
| Sonnet 5 | 2 / 10 | **GPT-5.6 Terra** | 2 / 12 | Input matches exactly, output 20% higher. Terra is the Codex workhorse that replaced GPT-5.4, which is the same position Sonnet holds. |
| Haiku 4.5 | 1 / 5 | **GPT-5.6 Luna** | 0.20 / 1.20 | The cheap tier on both sides. Luna is substantially cheaper than Haiku, so the mechanical tasks cost less here than in the original plan. |

Two caveats on those numbers. GPT-5.6 Sol took a temporary cut of more than 20% on
21 August 2026, stated as running for three months, so the real rate today may be below
5 / 30. GPT-5.3 Codex Spark, the low-latency Cerebras-backed preview on the Pro plan, is
not used in this plan: its pricing is unconfirmed and its strength is latency rather than
depth, which is the opposite of what the two hard tasks need.

Retired models to avoid: GPT-5.4 and GPT-5.4-mini left Codex on 31 August 2026, replaced
by Terra and Luna respectively.

---

## What changes when you run this in Codex instead of Claude Code

**There are no subagents.** The Claude Code version delegated each task to a subagent with
its own model and, where tasks ran in parallel, its own git worktree. Codex CLI is a single
agent per process. The equivalent is one `codex exec` invocation per task, with `-m` naming
the model and `-c model_reasoning_effort=` naming the depth. `run-plan.sh` does exactly
that, and uses real git worktrees plus concurrent processes where the original used
parallel subagents.

**Instructions live in AGENTS.md**, which Codex loads automatically, rather than in a long
orchestrator prompt. That is why `AGENTS.md` at the app root carries the decisions, the
build commands and the conventions: every task inherits them without being told.

**Effort is a config key, not a model choice.** `model_reasoning_effort` takes `minimal`,
`low`, `medium`, `high` or `xhigh`. The task table sets it per task. The two hardest tasks
run at `xhigh`; mechanical tasks run at `low` and save real money.

**The gate is manual.** Codex will not stop and ask you at a phase boundary the way an
orchestrator does. `run-plan.sh` stops after the spike and after each phase, prints what to
check, and waits for you.

---

## Quick start

```bash
cd VideoPlayerAutoSubs
cp docs/codex/config.toml ~/.codex/config.toml    # or merge the [profiles] blocks in
npm install
./docs/codex/run-plan.sh phase1
```

To run a single task instead of a whole phase:

```bash
./docs/codex/run-plan.sh task 2.2
```

To see what would run without running it:

```bash
DRY_RUN=1 ./docs/codex/run-plan.sh phase2
```

---

## Order and gates

```
1.1 spike (astra, xhigh) ──────────────┐ GATE: 3 exit criteria
1.2 setup   (sol)   ─┐                 │
1.3 library (terra) ─┼─ parallel        │
1.4 rename  (luna)  ─┘  worktrees       │
                                        ▼
                  2.1 play-first (astra, xhigh)  ← alone, merge before fan-out
                          │
      ┌───────────────────┼───────────────────┐
   2.2 online subs   2.3 corrections      2.6 export
      (sol)              (sol)              (luna)
          └──────┬────────┘
          2.4 controls (terra) → 2.5 panel (terra)
                                        ▼
        3.1 language (sol) → 3.2–3.5 in parallel (terra/luna)
                                        ▼
                       Phase 4, deferred by decision
```

The gate after 1.1 decides one thing only: whether Phase 2 draws the player controls over
the video or below the stage. Everything else in the plan is identical either way.

Collision rules, because these are real processes on real files:

- Tasks 1.1 to 1.4 touch disjoint files and can run at once, in worktrees.
- Every Phase 2 task touches `ipc.ts`, `session.ts` or `App.tsx`. Run 2.1 alone and merge it first.
- 2.4 and 2.5 both edit `App.tsx`. Sequence them.
- Only one task at a time may change `electron/engine/types.ts`.

---

## Sources

- [GPT-6 Astra pricing and access, MindStudio](https://www.mindstudio.ai/blog/gpt-6-astra-pricing-access)
- [GPT-5.6 pricing: Sol, Terra and Luna tiers explained, Finout](https://www.finout.io/blog/gpt-5.6-pricing-2026-sol-terra-and-luna-tiers-explained)
- [GPT-5.6 pricing, CloudZero](https://www.cloudzero.com/blog/gpt-5-6-pricing/)
- [OpenAI API pricing 2026, Morph](https://www.morphllm.com/openai-api-pricing)
- [Codex CLI model routing, May 2026](https://codex.danielvaughan.com/2026/05/07/codex-cli-model-routing-may-2026-gpt55-gpt54-spark-decision-framework/)
- [Codex CLI config.toml guide 2026, Majestic Labs](https://majesticlabs.dev/blog/202607/codex-cli-configuration-guide)
- [Codex CLI cheatsheet, Shipyard](https://shipyard.build/blog/codex-cli-cheat-sheet/)
- [GPT-5.3 Codex Spark vs GPT-5.6 Sol, OrcaRouter](https://www.orcarouter.ai/blog/gpt-5-3-codex-spark)
