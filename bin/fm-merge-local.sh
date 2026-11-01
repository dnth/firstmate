#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the exact local_done_head= recorded when the
# accepted ready report was read by bin/fm-crew-state.sh.
# Missing or malformed heads, or a moved branch, refuse landing.
# In-flight local-only tasks without a recorded head must report ready again before approval.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - a diverged branch needs a
# rebase and a new approval. See AGENTS.md prime directives, project management,
# and task lifecycle.
#
# A ship task with any accepted-blocked acceptance criterion is refused before
# the fast-forward, naming the criteria and --captain-instruction, the only
# override; bin/fm-merge-guard-lib.sh owns that guard and the override's
# validation and durable record. Local-only work has no forge checks to read.
# Usage: fm-merge-local.sh <task-id> [--captain-instruction <words>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# The supervision branch never lands local-only work: it reports a clean ready
# branch and leaves the landing to main (role partition:
# docs/omp-supervision-branch.md; no-op in homes without a branch actor -
# contract: bin/fm-lease-lib.sh).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-merge-guard-lib.sh
. "$SCRIPT_DIR/fm-merge-guard-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id> [--captain-instruction <words>]}
shift
CAPTAIN_INSTRUCTION=
case "$#:${1:-}" in
  2:--captain-instruction) CAPTAIN_INSTRUCTION=$2 ;;
esac
if [ "$#" -gt 0 ] && ! fm_merge_guard_instruction_valid "$CAPTAIN_INSTRUCTION"; then
  echo "error: usage: fm-merge-local.sh <task-id> [--captain-instruction <words>], with the captain's exact words on one non-blank line" >&2
  exit 2
fi
fm_pr_task_id_valid "$ID" || { echo "error: invalid task id: $ID" >&2; exit 2; }
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

CONTROL_LOCK="$STATE/.control-$ID.lock"
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
PROJECT_LOCK=
cleanup_locks() {
  [ -z "$PROJECT_LOCK" ] || fm_lock_release "$PROJECT_LOCK" || true
  [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK" || true
  [ -z "$CONTROL_LOCK" ] || fm_lock_release "$CONTROL_LOCK" || true
}
trap cleanup_locks EXIT
fm_lock_acquire_wait "$CONTROL_LOCK"
fm_lock_acquire_wait "$META_LOCK"

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

local_done_head_count=$(awk -F= '$1 == "local_done_head" { n++ } END { print n+0 }' "$META")
local_done_head=$(grep '^local_done_head=' "$META" | cut -d= -f2- || true)
case ${#local_done_head} in
  40|64) ;;
  *)
    echo "error: missing or malformed local done head for task $ID; refusing; task must report ready again before approval" >&2
    exit 1
    ;;
esac
case "$local_done_head" in
  *[!0-9a-f]*)
    echo "error: missing or malformed local done head for task $ID; refusing; task must report ready again before approval" >&2
    exit 1
    ;;
esac
[ "$local_done_head_count" -eq 1 ] || {
  echo "error: missing or malformed local done head for task $ID; refusing; task must report ready again before approval" >&2
  exit 1
}

BRANCH="fm/$ID"
project_git_dir=$(git -C "$PROJ" rev-parse --absolute-git-dir) || {
  echo "error: cannot determine the project checkout's Git directory" >&2
  exit 1
}
PROJECT_LOCK="$project_git_dir/fm-local-landing.lock"
fm_lock_acquire_wait "$PROJECT_LOCK"

DEFAULT=$("$FM_ROOT/bin/fm-local-default.sh" "$PROJ") \
  || { echo "error: cannot determine default branch for $PROJ; expected a local origin/HEAD branch, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

branch_head=$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}" 2>/dev/null || true)
[ -n "$branch_head" ] || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }
[ "$branch_head" = "$local_done_head" ] || {
  echo "error: branch $BRANCH differs from the recorded local done head; refusing; task $ID must report ready again before landing" >&2
  exit 1
}

# Clean fast-forward only: DEFAULT must be an ancestor of the accepted commit.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$local_done_head"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then report ready again." >&2
  exit 1
fi

FM_MERGE_GUARD_DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
fm_merge_guard_check_accepted_blocked "$ID" "$META"
fm_merge_guard_resolve "$ID" fm-merge-local "$BRANCH" "$CAPTAIN_INSTRUCTION" || exit 1

# Recheck after approval guards, then land the immutable accepted object rather
# than resolving the mutable branch name again.
branch_head=$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}" 2>/dev/null || true)
[ "$branch_head" = "$local_done_head" ] || {
  echo "error: branch $BRANCH differs from the recorded local done head; refusing; task $ID must report ready again before landing" >&2
  exit 1
}
before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$local_done_head" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
