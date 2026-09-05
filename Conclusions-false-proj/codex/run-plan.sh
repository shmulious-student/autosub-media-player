#!/usr/bin/env bash
# Driver for the AI Subs Player plan in OpenAI Codex.
#
#   ./docs/codex/run-plan.sh phase1          # run a whole phase, stopping at its gate
#   ./docs/codex/run-plan.sh task 2.2        # run one task
#   ./docs/codex/run-plan.sh review 2        # end-of-phase review pass
#   ./docs/codex/run-plan.sh list            # show the task table and exit
#   DRY_RUN=1 ./docs/codex/run-plan.sh phase2   # print the commands, run nothing
#
# Codex CLI is a single agent per process, so parallel tasks are separate
# processes in separate git worktrees. Flags move between Codex releases —
# check `codex --help` if an invocation is rejected.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
BRANCH="claude/video-player-ux-review-rkthpq"
WORKTREE_ROOT="${WORKTREE_ROOT:-$REPO_DIR/../aisubs-worktrees}"
DRY_RUN="${DRY_RUN:-0}"

# id | profile | effort | parallel-group | one-line title
TASKS=(
  "1.1|astra|xhigh|p1|libmpv render-API native addon spike"
  "1.2|sol|high|p1|Setup screen and Engines page"
  "1.3|terra|medium|p1|Library persistence and entry points"
  "1.4|luna|low|p1|Rename to AI Subs Player"
  "2.1|astra|xhigh|solo|Play first, prepare behind"
  "2.2|sol|high|p2|Online subtitle search"
  "2.3|sol|high|p2|Live corrections without losing the cache"
  "2.4|terra|medium|p2a|Player controls"
  "2.5|terra|medium|p2b|Docked side panel"
  "2.6|luna|low|p2|Export subtitles"
  "3.1|sol|high|solo|Source language detection and per-title target override"
  "3.2|terra|medium|p3|Settings window with presets"
  "3.3|terra|medium|p3|One status vocabulary"
  "3.4|terra|medium|p3|Queue view and system integration"
  "3.5|luna|low|p3|Icon set"
  "4.1|terra|medium|p4|Poster grid library view"
  "4.2|sol|high|p4|Idle quality re-pass"
  "4.3|sol|high|p4|LAN remote companion"
)

field() { echo "$1" | cut -d'|' -f"$2"; }

lookup() {
  local id="$1" row
  for row in "${TASKS[@]}"; do
    [ "$(field "$row" 1)" = "$id" ] && { echo "$row"; return 0; }
  done
  echo "unknown task: $id" >&2
  return 1
}

brief() {
  local id="$1" title="$2"
  cat <<EOF
Implement task $id, "$title", from docs/codex/tasks.md in this repository.

Read first, and treat as binding:
  - AGENTS.md               project instructions, conventions and the settled decisions
  - docs/codex/tasks.md     find task $id and follow its acceptance criteria exactly
  - docs/codex/design-spec.md   the UI contract: palette, status vocabulary, keymap, screens
  - docs/ux-review/index.html   the mockups, if the visual intent of a screen is unclear

Scope discipline. Task $id lists the files it owns and the files it must not touch. Stay
inside that boundary. If the work genuinely requires a change outside it, stop and say so
rather than making the change.

Definition of done. Every acceptance criterion in the task is met, and \`npm run build\`
passes from the VideoPlayerAutoSubs directory. Run \`npm run smoke:sched\` if you touched
the scheduler or the cache, and \`npm run smoke:mpv\` if you touched the player. If the
build cannot be made to pass, report why. Do not reach the bar by adding \`any\`, loosening
tsconfig, deleting a check or skipping a test.

Commit your work with an imperative subject and a body that explains why the change was
needed. One commit for this task. Do not open a pull request.

Finish by reporting: what you changed, which acceptance criteria are met, anything you
deliberately left out, and anything you found that belongs in a different task.
EOF
}

run_task() {
  local id="$1" dir="${2:-$APP_DIR}" row profile effort title
  row="$(lookup "$id")"
  profile="$(field "$row" 2)"; effort="$(field "$row" 3)"; title="$(field "$row" 5)"

  echo "── task $id · $title"
  echo "   profile $profile · effort $effort · dir $dir"

  if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry run] codex exec --profile $profile --cd $dir \"<brief for $id>\""
    return 0
  fi

  # --profile picks model + effort from config.toml. If your Codex build does not
  # support profiles, swap for:  -m gpt-5.6-terra -c model_reasoning_effort=medium
  codex exec --profile "$profile" --cd "$dir" "$(brief "$id" "$title")"
}

worktree_for() {
  local id="$1" path="$WORKTREE_ROOT/task-${id//./-}"
  if [ ! -d "$path" ]; then
    git -C "$REPO_DIR" worktree add -b "task/${id}" "$path" "$BRANCH" >/dev/null
  fi
  echo "$path/VideoPlayerAutoSubs"
}

run_parallel() {
  local ids=("$@") id pids=() dir
  echo "▶ running ${#ids[@]} tasks in parallel worktrees under $WORKTREE_ROOT"
  for id in "${ids[@]}"; do
    dir="$(worktree_for "$id")"
    run_task "$id" "$dir" &
    pids+=("$!")
  done
  local failed=0
  for p in "${pids[@]}"; do wait "$p" || failed=1; done
  echo
  echo "Merge each worktree branch back one at a time, resolving conflicts yourself:"
  for id in "${ids[@]}"; do echo "  git merge task/${id}"; done
  return $failed
}

gate() {
  cat <<EOF

═══ GATE ═══
$1

Nothing further runs until you decide. Re-run this script with the next phase
when you are ready.
EOF
}

review() {
  local phase="$1"
  [ "$DRY_RUN" = "1" ] && { echo "[dry run] review of phase $phase on profile sol"; return 0; }
  codex exec --profile sol --cd "$APP_DIR" "Review the diff for phase $phase of the plan in docs/codex/tasks.md against the branch point. Look for correctness bugs first, then reuse and simplification. Check every acceptance criterion in the phase's tasks is actually met, not just claimed. Fix what you find, keep \`npm run build\` passing, and commit. Report anything you chose not to fix and why."
}

case "${1:-}" in
  list)
    printf '%-5s %-7s %-8s %s\n' ID PROFILE EFFORT TITLE
    for row in "${TASKS[@]}"; do
      printf '%-5s %-7s %-8s %s\n' "$(field "$row" 1)" "$(field "$row" 2)" "$(field "$row" 3)" "$(field "$row" 5)"
    done
    ;;
  task)
    run_task "${2:?usage: run-plan.sh task <id>}"
    ;;
  review)
    review "${2:?usage: run-plan.sh review <phase>}"
    ;;
  phase1)
    run_parallel 1.1 1.2 1.3 1.4
    gate "Task 1.1, the libmpv spike, decides how Phase 2 builds the player controls.
Check its three exit criteria:
  1. a first frame rendered inside the Electron BrowserWindow
  2. seek and ASS subtitle reload working through the JSON-IPC controller
  3. correct geometry on HiDPI and in fullscreen

Passed  → Phase 2 draws the controls over the video.
Failed  → Phase 2 builds the same controls below the stage, two-window glue stays.
Record the outcome in docs/codex/tasks.md under the GATE heading before continuing."
    ;;
  phase2)
    run_task 2.1
    echo; echo "Merge 2.1 before continuing. Press Enter when it is on $BRANCH."; read -r _
    run_parallel 2.2 2.3 2.6
    run_task 2.4
    run_task 2.5
    review 2
    gate "Phase 2 complete. The player should now start in under a second, find subtitles
online, correct the cast without losing the cache, and export. Try a cold file and a
cached one before starting Phase 3."
    ;;
  phase3)
    run_task 3.1
    echo; echo "Merge 3.1 before continuing. Press Enter when it is on $BRANCH."; read -r _
    run_parallel 3.2 3.3 3.4 3.5
    review 3
    ;;
  phase4)
    echo "Phase 4 is deferred by decision. Run individual tasks explicitly:"
    echo "  ./docs/codex/run-plan.sh task 4.1"
    ;;
  *)
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
