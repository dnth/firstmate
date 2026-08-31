#!/usr/bin/env bash
# Relaunch one missing committed ship task into a new clean worktree.
#
# Usage: fm-clean-commit-relaunch.sh <source-task-id> <destination-task-id>
#
# This explicit operator command is the sole owner of clean-commit relaunch.
# It admits one missing local codex/tmux ship task, allocates a normal clean
# Treehouse worktree, creates a new branch at the admitted source commit,
# publishes one evidence-only handoff, launches and acknowledges a fresh task,
# and cleans only destination-owned state on failure.
#
# It never resumes, closes, alters, or cleans the source task.
# No watcher, bootstrap, recovery, or generic-spawn path invokes this command.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}

resolve_dir() {  # <label> <path>
  local label=$1 path=$2
  [ -d "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] && [ -x "$path" ] || {
    echo "error: $label must be a readable ordinary directory: $path" >&2
    return 1
  }
  (CDPATH='' cd -- "$path" && pwd -P)
}

FM_HOME=$(resolve_dir FM_HOME "$FM_HOME") || exit 1
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=$(resolve_dir state "$STATE") || exit 1
DATA=$(resolve_dir data "$DATA") || exit 1
[ "$STATE" = "$FM_HOME/state" ] && [ "$DATA" = "$FM_HOME/data" ] || {
  echo "error: clean-commit relaunch refuses cross-home state or data overrides" >&2
  exit 1
}

# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pool-lib.sh
. "$SCRIPT_DIR/fm-pool-lib.sh"
# shellcheck source=bin/fm-clean-commit-relaunch-launch-lib.sh
. "$SCRIPT_DIR/fm-clean-commit-relaunch-launch-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

valid_id() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*|[._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

sha256_text() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

meta_exact() {  # <meta> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(sed -n "s/^$key=//p" "$meta")
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

meta_optional_exact() {  # <meta> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  case "$count" in
    0) return 0 ;;
    1)
      value=$(sed -n "s/^$key=//p" "$meta")
      [ -n "$value" ] || return 1
      printf '%s' "$value"
      ;;
    *) return 1 ;;
  esac
}

path_has_git_operation() {  # <worktree>
  local worktree=$1 operation operation_path
  for operation in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD BISECT_START BISECT_LOG sequencer rebase-apply rebase-merge; do
    operation_path=$(git -C "$worktree" rev-parse --git-path "$operation" 2>/dev/null || true)
    [ -z "$operation_path" ] && continue
    [ ! -e "$operation_path" ] && [ ! -L "$operation_path" ] || return 0
  done
  return 1
}

worktree_is_registered() {  # <repository> <worktree>
  local repository=$1 worktree=$2 record candidate
  while IFS= read -r record; do
    case "$record" in
      "worktree "*)
        candidate=${record#worktree }
        candidate=$(resolve_dir registered-worktree "$candidate" 2>/dev/null || true)
        [ "$candidate" != "$worktree" ] || return 0
        ;;
    esac
  done < <(git -C "$repository" worktree list --porcelain 2>/dev/null)
  return 1
}

worktree_is_task_owned() {  # <worktree>
  local worktree=$1 meta recorded
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 2
    recorded=$(meta_exact "$meta" worktree 2>/dev/null) || return 2
    recorded=$(resolve_dir recorded-task-worktree "$recorded" 2>/dev/null) || return 2
    [ "$recorded" != "$worktree" ] || return 0
  done
  return 1
}

task_worktrees_are_well_formed() {
  local meta recorded
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 1
    recorded=$(meta_exact "$meta" worktree 2>/dev/null) || return 1
    resolve_dir recorded-task-worktree "$recorded" >/dev/null 2>&1 || return 1
  done
}

destination_tmux_window_absent() {  # <destination>
  local destination=$1 session windows
  if [ -n "${TMUX:-}" ]; then
    session=$(tmux display-message -p '#S' 2>/dev/null) || return 1
  elif tmux has-session -t firstmate 2>/dev/null; then
    session=firstmate
  else
    return 0
  fi
  windows=$(tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null) || return 1
  ! grep -Fxq "fm-$destination" <<< "$windows"
}

destination_artifact_exists() {  # <destination>
  local destination=$1 artifact
  for artifact in \
    "$STATE/$destination.inbox" "$STATE/$destination.status" \
    "$STATE/$destination.turn-ended" "$STATE/$destination.meta" \
    "$STATE/$destination.pi-ext.ts" "$STATE/$destination.omp-ext.ts" \
    "$STATE/$destination.omp-ready" "$STATE/$destination.omp-started" \
    "$STATE/$destination.omp-doorbell-ready" "$STATE/$destination.omp-doorbell-ready.requests" \
    "$STATE/$destination.grok-turnend-token" \
    "$STATE/$destination.kimi-turnend-token" "$STATE/$destination.hermes-turnend-token" \
    "$STATE/$destination.hermes-session" "$STATE/$destination.hermes-started" \
    "$STATE/$destination.busy-state" "$STATE/$destination.busy-gen" \
    "$STATE/$destination.herdr-presentation" "$STATE/.$destination.open-decisions-cursor" \
    "$STATE/$destination.check.sh" "$STATE/$destination.pr-poll" \
    "$STATE/$destination.pr-poll-registration" "$STATE/$destination.pr-poll-retirement" \
    "$STATE/$destination.check-trust" "$DATA/$destination/relaunch-handoff.json" \
    "${TMPDIR:-/tmp}/fm-$destination"; do
    if [ -e "$artifact" ] || [ -L "$artifact" ]; then
      printf '%s' "$artifact"
      return 0
    fi
  done
  return 1
}

no_mistakes_custody() {  # <source-worktree> <source-branch>
  local worktree=$1 branch=$2 output status trimmed run_id run_branch run_head run_status run_outcome
  set +e
  output=$(fm_nm_run_bounded "$worktree" "${FM_CLEAN_COMMIT_RELAUNCH_NM_TIMEOUT:-10}" axi status 2>&1)
  status=$?
  set -e
  trimmed=$(fm_nm_trim "$output")
  case "$trimmed" in
    '')
      [ "$status" -eq 0 ] || { printf 'unreadable'; return 0; }
      printf 'none'
      return 0
      ;;
    'no active run')
      printf 'none'
      return 0
      ;;
  esac
  [ "$status" -eq 0 ] || { printf 'unreadable'; return 0; }
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$output" id)")
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$output" branch)")
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$output" head)")
  run_status=$(fm_nm_strip_quotes "$(fm_nm_field "$output" status)")
  run_outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$output" outcome)")
  [ -n "$run_id" ] && [ "$run_branch" = "$branch" ] \
    && fm_nm_head_matches_worktree "$worktree" "$run_head" && [ -z "$run_outcome" ] || {
    printf 'unreadable'
    return 0
  }
  case "$run_status" in
    running|fixing|ci) printf 'active' ;;
    awaiting_approval|fix_review) printf 'parked' ;;
    *) printf 'unreadable' ;;
  esac
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -eq 2 ] || { usage >&2; exit 2; }
SOURCE=$1
DESTINATION=$2
if ! valid_id "$SOURCE" || ! valid_id "$DESTINATION"; then
  echo "error: source and destination task ids must be valid task ids" >&2
  exit 2
fi
[ "$SOURCE" != "$DESTINATION" ] || {
  echo "error: source and destination task ids must differ" >&2
  exit 1
}

SOURCE_META=$STATE/$SOURCE.meta
SOURCE_BRIEF=$DATA/$SOURCE/brief.md
DESTINATION_BRIEF=$DATA/$DESTINATION/brief.md
DESTINATION_HANDOFF=$DATA/$DESTINATION/relaunch-handoff.json
SOURCE_LOCK=$STATE/.spawn-$SOURCE.lock
DESTINATION_LOCK=$STATE/.spawn-$DESTINATION.lock
SOURCE_LOCK_HELD=0
DESTINATION_LOCK_HELD=0
DESTINATION_WORKTREE=
DESTINATION_WORKTREE_OWNED=0
DESTINATION_BRANCH=
DESTINATION_BRANCH_CREATED=0
DESTINATION_PUBLISHED=0
DESTINATION_CHECKOUT_INTERRUPTED=0
DESTINATION_HANDOFF_OWNED=0
DESTINATION_HANDOFF_INTERRUPTED=0
DESTINATION_ALLOCATION_INTERRUPTED=0

defer_destination_checkout_signal() {
  DESTINATION_CHECKOUT_INTERRUPTED=1
}

defer_destination_handoff_signal() {
  DESTINATION_HANDOFF_INTERRUPTED=1
}

defer_destination_allocation_signal() {
  DESTINATION_ALLOCATION_INTERRUPTED=1
}

cleanup_destination() {
  [ "$DESTINATION_WORKTREE_OWNED" -eq 1 ] || return 0
  fm_clean_relaunch_launch_cleanup "$DESTINATION" || true
  if ! (cd "$PROJECT" && "$SCRIPT_DIR/fm-treehouse-command.sh" return --if-lease-holder "fm-$DESTINATION" "$DESTINATION_WORKTREE"); then
    echo "error: could not return destination worktree $DESTINATION_WORKTREE" >&2
    return 1
  fi
  if [ "$DESTINATION_BRANCH_CREATED" -eq 1 ]; then
    if ! git -C "$PROJECT" branch -D "$DESTINATION_BRANCH" >/dev/null; then
      echo "error: could not delete destination branch $DESTINATION_BRANCH" >&2
      return 1
    fi
  fi
  [ "$DESTINATION_HANDOFF_OWNED" -eq 0 ] || rm -f -- "$DESTINATION_HANDOFF"
}

cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    cleanup_destination || echo "error: destination cleanup is incomplete" >&2
  fi
  [ "$DESTINATION_LOCK_HELD" -eq 0 ] || fm_lock_release "$DESTINATION_LOCK" || true
  [ "$SOURCE_LOCK_HELD" -eq 0 ] || fm_lock_release "$SOURCE_LOCK" || true
  return "$status"
}
interrupted() {
  exit 1
}
trap cleanup EXIT
trap interrupted HUP INT TERM

fm_lock_try_acquire "$SOURCE_LOCK" || {
  echo "error: source task $SOURCE is already under an exclusive lifecycle operation" >&2
  exit 1
}
SOURCE_LOCK_HELD=1
fm_lock_try_acquire "$DESTINATION_LOCK" || {
  echo "error: destination task $DESTINATION is already under an exclusive lifecycle operation" >&2
  exit 1
}
DESTINATION_LOCK_HELD=1

[ -f "$SOURCE_META" ] && [ ! -L "$SOURCE_META" ] && [ -r "$SOURCE_META" ] || {
  echo "error: source task $SOURCE has no readable regular metadata" >&2
  exit 1
}
[ -f "$SOURCE_BRIEF" ] && [ ! -L "$SOURCE_BRIEF" ] && [ -r "$SOURCE_BRIEF" ] || {
  echo "error: source task $SOURCE has no readable regular brief" >&2
  exit 1
}
[ -f "$DESTINATION_BRIEF" ] && [ ! -L "$DESTINATION_BRIEF" ] && [ -r "$DESTINATION_BRIEF" ] || {
  echo "error: destination task $DESTINATION needs a pre-existing complete ship brief" >&2
  exit 1
}
DESTINATION_DATA_DIR=$(resolve_dir destination-task-data "$DATA/$DESTINATION") || exit 1
if [ "$DESTINATION_DATA_DIR" != "$DATA/$DESTINATION" ] || [ ! -w "$DESTINATION_DATA_DIR" ]; then
  echo "error: destination task $DESTINATION data directory is not writable in this home" >&2
  exit 1
fi
grep -Fq '{TASK}' "$DESTINATION_BRIEF" && {
  echo "error: destination task $DESTINATION brief still contains a task placeholder" >&2
  exit 1
}
"$SCRIPT_DIR/fm-receipt-check.sh" --parse-criteria "$DESTINATION_BRIEF" >/dev/null 2>&1 || {
  echo "error: destination task $DESTINATION needs a complete ship brief with concrete acceptance criteria" >&2
  exit 1
}
DESTINATION_ARTIFACT=$(destination_artifact_exists "$DESTINATION" || true)
[ -z "$DESTINATION_ARTIFACT" ] || {
  echo "error: destination task $DESTINATION already has durable state at $DESTINATION_ARTIFACT" >&2
  exit 1
}

KIND=$(meta_exact "$SOURCE_META" kind) || { echo "error: source task $SOURCE has malformed kind metadata" >&2; exit 1; }
[ "$KIND" = ship ] || { echo "error: clean-commit relaunch accepts only ordinary ship tasks" >&2; exit 1; }
[ "$(grep -c '^home=' "$SOURCE_META" 2>/dev/null || true)" -eq 0 ] || {
  echo "error: source task $SOURCE belongs to a secondmate or another home" >&2
  exit 1
}
ENDPOINT_TASK=$(meta_exact "$SOURCE_META" endpoint_task_id) || { echo "error: source task $SOURCE has malformed endpoint identity" >&2; exit 1; }
[ "$ENDPOINT_TASK" = "$SOURCE" ] || { echo "error: source task $SOURCE endpoint identity does not match its task id" >&2; exit 1; }
SOURCE_WORKTREE=$(meta_exact "$SOURCE_META" worktree) || { echo "error: source task $SOURCE has malformed worktree metadata" >&2; exit 1; }
PROJECT=$(meta_exact "$SOURCE_META" project) || { echo "error: source task $SOURCE has malformed project metadata" >&2; exit 1; }
HARNESS=$(meta_exact "$SOURCE_META" harness) || { echo "error: source task $SOURCE has malformed harness metadata" >&2; exit 1; }
BACKEND=$(meta_optional_exact "$SOURCE_META" backend) || { echo "error: source task $SOURCE has malformed backend metadata" >&2; exit 1; }
BACKEND=${BACKEND:-tmux}
MODE=$(meta_exact "$SOURCE_META" mode) || { echo "error: source task $SOURCE has malformed delivery metadata" >&2; exit 1; }
YOLO=$(meta_exact "$SOURCE_META" yolo) || { echo "error: source task $SOURCE has malformed merge posture metadata" >&2; exit 1; }
MODEL=$(meta_optional_exact "$SOURCE_META" model) || { echo "error: source task $SOURCE has malformed model metadata" >&2; exit 1; }
EFFORT=$(meta_optional_exact "$SOURCE_META" effort) || { echo "error: source task $SOURCE has malformed effort metadata" >&2; exit 1; }
if [ "$(grep -c '^prewalk_into=' "$SOURCE_META" 2>/dev/null || true)" -ne 0 ] \
  || [ "$(grep -c '^allow_project_omp_extensions=' "$SOURCE_META" 2>/dev/null || true)" -ne 0 ]; then
  echo "error: source task $SOURCE has unsupported OMP-only metadata" >&2
  exit 1
fi
case "$MODE:$YOLO" in
  no-mistakes:on|no-mistakes:off|direct-PR:on|direct-PR:off|local-only:on|local-only:off) ;;
  *) echo "error: source task $SOURCE has invalid delivery or merge posture" >&2; exit 1 ;;
esac
case "$MODEL" in
  *[!A-Za-z0-9._:/@+-]*) echo "error: source task $SOURCE has invalid model metadata" >&2; exit 1 ;;
esac
case "$EFFORT" in ''|default|low|medium|high|xhigh|max) ;; *) echo "error: source task $SOURCE has invalid effort metadata" >&2; exit 1 ;; esac
[ "$HARNESS:$BACKEND" = codex:tmux ] || {
  echo "error: clean-commit relaunch currently supports only verified codex/tmux source tasks" >&2
  exit 1
}
grep -Fxq "Delivery contract: mode=$MODE" "$DESTINATION_BRIEF" || {
  echo "error: destination brief delivery contract does not match source mode=$MODE" >&2
  exit 1
}
PR=$(meta_optional_exact "$SOURCE_META" pr) || { echo "error: source task $SOURCE has malformed PR metadata" >&2; exit 1; }
if [ -n "$PR" ]; then
  fm_pr_url_parse "$PR" && [ "$FM_PR_URL" = "$PR" ] || {
    echo "error: source task $SOURCE has non-canonical PR metadata" >&2
    exit 1
  }
  PR=$FM_PR_URL
fi

SOURCE_WORKTREE=$(resolve_dir source-worktree "$SOURCE_WORKTREE") || exit 1
PROJECT=$(resolve_dir recorded-project "$PROJECT") || exit 1
SOURCE_TOP=$(git -C "$SOURCE_WORKTREE" rev-parse --show-toplevel 2>/dev/null || true)
SOURCE_TOP=$(resolve_dir source-repository-root "$SOURCE_TOP") || exit 1
[ "$SOURCE_TOP" = "$SOURCE_WORKTREE" ] || {
  echo "error: source task $SOURCE worktree is not its recorded repository root" >&2
  exit 1
}
PROJECT_TOP=$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null || true)
PROJECT_TOP=$(resolve_dir project-repository-root "$PROJECT_TOP") || exit 1
[ "$PROJECT_TOP" = "$PROJECT" ] || {
  echo "error: source task $SOURCE project is not a repository root" >&2
  exit 1
}
SOURCE_COMMON=$(git -C "$SOURCE_WORKTREE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
PROJECT_COMMON=$(git -C "$PROJECT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
SOURCE_COMMON=$(resolve_dir source-physical-repository "$SOURCE_COMMON") || exit 1
PROJECT_COMMON=$(resolve_dir project-physical-repository "$PROJECT_COMMON") || exit 1
[ "$SOURCE_COMMON" = "$PROJECT_COMMON" ] || {
  echo "error: source task $SOURCE is not attached to its recorded physical repository" >&2
  exit 1
}
worktree_is_registered "$PROJECT" "$SOURCE_WORKTREE" || {
  echo "error: source task $SOURCE worktree is not a registered physical worktree" >&2
  exit 1
}
SOURCE_STATUS=$(git -C "$SOURCE_WORKTREE" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) || {
  echo "error: source task $SOURCE worktree status is unreadable" >&2
  exit 1
}
[ -z "$SOURCE_STATUS" ] || {
  echo "error: source task $SOURCE worktree is not completely clean" >&2
  exit 1
}
path_has_git_operation "$SOURCE_WORKTREE" && {
  echo "error: source task $SOURCE has a Git operation in progress" >&2
  exit 1
}
SOURCE_COMMIT=$(git -C "$SOURCE_WORKTREE" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)
[ -n "$SOURCE_COMMIT" ] || { echo "error: source task $SOURCE has no readable HEAD commit" >&2; exit 1; }
SOURCE_BRANCH=$(git -C "$SOURCE_WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$SOURCE_BRANCH" ] || { echo "error: source task $SOURCE is detached" >&2; exit 1; }
SOURCE_BRANCH_HEAD=$(git -C "$SOURCE_WORKTREE" rev-parse --verify --quiet "refs/heads/$SOURCE_BRANCH^{commit}" 2>/dev/null || true)
[ "$SOURCE_BRANCH_HEAD" = "$SOURCE_COMMIT" ] || {
  echo "error: source task $SOURCE branch does not bind its exact HEAD commit" >&2
  exit 1
}
git -C "$PROJECT" cat-file -e "$SOURCE_COMMIT^{commit}" 2>/dev/null || {
  echo "error: source task $SOURCE commit is not reachable from its recorded repository" >&2
  exit 1
}

fm_backend_validate_task_endpoint "$SOURCE_META" "$SOURCE" >/dev/null || exit 1
fm_backend_source "$BACKEND" || exit 1
case "$(fm_backend_agent_state "$BACKEND" "$FM_BACKEND_VALIDATED_TARGET" "$SOURCE_META" 2>/dev/null || true)" in
  missing) ;;
  *) echo "error: source task $SOURCE endpoint is not authoritatively missing" >&2; exit 1 ;;
esac
destination_tmux_window_absent "$DESTINATION" || {
  echo "error: destination task $DESTINATION already has a tmux endpoint or tmux is unreadable" >&2
  exit 1
}
CUSTODY=$(no_mistakes_custody "$SOURCE_WORKTREE" "$SOURCE_BRANCH")
case "$CUSTODY" in
  none) ;;
  active|parked) echo "error: source task $SOURCE has active or parked No-Mistakes custody" >&2; exit 1 ;;
  *) echo "error: source task $SOURCE No-Mistakes custody is unreadable or malformed" >&2; exit 1 ;;
esac
task_worktrees_are_well_formed || {
  echo "error: a local task metadata record has a malformed worktree identity" >&2
  exit 1
}

DESTINATION_BRANCH="fm/$DESTINATION"
[ "$SOURCE_BRANCH" != "$DESTINATION_BRANCH" ] || {
  echo "error: source and destination branch identities would collide" >&2
  exit 1
}
git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$DESTINATION_BRANCH" && {
  echo "error: destination task $DESTINATION already has branch $DESTINATION_BRANCH" >&2
  exit 1
}

trap defer_destination_allocation_signal HUP INT TERM
ALLOCATED_WORKTREE=$(cd "$PROJECT" && "$SCRIPT_DIR/fm-treehouse-get.sh" --lease --lease-holder "fm-$DESTINATION") || {
  trap interrupted HUP INT TERM
  echo "error: normal allocator did not supply a destination worktree" >&2
  exit 1
}
DESTINATION_WORKTREE=$ALLOCATED_WORKTREE
ALLOCATED_WORKTREE=$(resolve_dir destination-worktree "$ALLOCATED_WORKTREE") || exit 1
DESTINATION_WORKTREE=$ALLOCATED_WORKTREE
[ "$ALLOCATED_WORKTREE" != "$SOURCE_WORKTREE" ] || {
  echo "error: normal allocator reused the source worktree" >&2
  exit 1
}
DESTINATION_TOP=$(git -C "$DESTINATION_WORKTREE" rev-parse --show-toplevel 2>/dev/null || true)
DESTINATION_TOP=$(resolve_dir destination-repository-root "$DESTINATION_TOP") || exit 1
[ "$DESTINATION_TOP" = "$DESTINATION_WORKTREE" ] || {
  echo "error: normal allocator returned a non-root destination worktree" >&2
  exit 1
}
DESTINATION_COMMON=$(git -C "$DESTINATION_WORKTREE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
DESTINATION_COMMON=$(resolve_dir destination-physical-repository "$DESTINATION_COMMON") || exit 1
[ "$DESTINATION_COMMON" = "$PROJECT_COMMON" ] || {
  echo "error: normal allocator returned a destination from another physical repository" >&2
  exit 1
}
[ "$DESTINATION_WORKTREE" != "$PROJECT" ] || {
  echo "error: normal allocator returned the primary project worktree" >&2
  exit 1
}
worktree_is_registered "$PROJECT" "$DESTINATION_WORKTREE" || {
  echo "error: normal allocator returned an unregistered destination worktree" >&2
  exit 1
}
if worktree_is_task_owned "$DESTINATION_WORKTREE"; then
  echo "error: normal allocator returned an existing task worktree" >&2
  exit 1
else
  case "$?" in
    1) ;;
    *) echo "error: could not establish local task worktree ownership" >&2; exit 1 ;;
  esac
fi
if ! fm_pool_worktree_clean "$DESTINATION_WORKTREE" || path_has_git_operation "$DESTINATION_WORKTREE"; then
  echo "error: normal allocator returned an occupied destination worktree" >&2
  exit 1
fi
DESTINATION_WORKTREE_OWNED=1
trap interrupted HUP INT TERM
[ "$DESTINATION_ALLOCATION_INTERRUPTED" -eq 0 ] || exit 1
trap defer_destination_checkout_signal HUP INT TERM
if git -C "$DESTINATION_WORKTREE" checkout -b "$DESTINATION_BRANCH" "$SOURCE_COMMIT" >/dev/null; then
  DESTINATION_BRANCH_CREATED=1
else
  trap interrupted HUP INT TERM
  echo "error: could not create the destination branch at the admitted source commit" >&2
  exit 1
fi
trap interrupted HUP INT TERM
[ "$DESTINATION_CHECKOUT_INTERRUPTED" -eq 0 ] || exit 1
DESTINATION_HEAD=$(git -C "$DESTINATION_WORKTREE" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)
DESTINATION_ATTACHED_BRANCH=$(git -C "$DESTINATION_WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ "$DESTINATION_HEAD" = "$SOURCE_COMMIT" ] && [ "$DESTINATION_ATTACHED_BRANCH" = "$DESTINATION_BRANCH" ] || {
  echo "error: destination checkout did not retain the admitted branch and commit" >&2
  exit 1
}

REPOSITORY_IDENTITY=$(sha256_text "$PROJECT_COMMON")
SOURCE_BRIEF_IDENTITY=$(sha256_file "$SOURCE_BRIEF") || exit 1
DESTINATION_BRIEF_IDENTITY=$(sha256_file "$DESTINATION_BRIEF") || exit 1
HANDOFF_TMP=$(mktemp "$DATA/$DESTINATION/.relaunch-handoff.XXXXXX") || exit 1
jq -n \
  --arg schema fm-clean-commit-relaunch.v1 \
  --arg source "$SOURCE" \
  --arg destination "$DESTINATION" \
  --arg repository_identity "$REPOSITORY_IDENTITY" \
  --arg source_commit "$SOURCE_COMMIT" \
  --arg source_branch "$SOURCE_BRANCH" \
  --arg destination_branch "$DESTINATION_BRANCH" \
  --arg mode "$MODE" \
  --arg yolo "$YOLO" \
  --arg source_brief_identity "$SOURCE_BRIEF_IDENTITY" \
  --arg destination_brief_identity "$DESTINATION_BRIEF_IDENTITY" \
  --arg custody "$CUSTODY" \
  --arg pr "$PR" \
  '{schema:$schema,source:$source,destination:$destination,repository_identity:$repository_identity,source_commit:$source_commit,source_branch:$source_branch,destination_branch:$destination_branch,delivery:{mode:$mode,yolo:$yolo},source_brief_identity:$source_brief_identity,destination_brief_identity:$destination_brief_identity,no_mistakes_custody:{state:$custody,next_action:"proceed"}} + (if $pr == "" then {} else {pr:$pr} end)' \
  > "$HANDOFF_TMP" || exit 1
trap defer_destination_handoff_signal HUP INT TERM
if ln "$HANDOFF_TMP" "$DESTINATION_HANDOFF"; then
  DESTINATION_HANDOFF_OWNED=1
  rm -f -- "$HANDOFF_TMP"
else
  rm -f -- "$HANDOFF_TMP"
  trap interrupted HUP INT TERM
  echo "error: destination task $DESTINATION already has a durable handoff" >&2
  exit 1
fi
trap interrupted HUP INT TERM
[ "$DESTINATION_HANDOFF_INTERRUPTED" -eq 0 ] || exit 1

fm_clean_relaunch_launch_allocated \
  "$DESTINATION" "$PROJECT" "$DESTINATION_WORKTREE" "$DESTINATION_BRIEF" \
  "$HARNESS" "$BACKEND" "$MODE" "$YOLO" "${MODEL:-default}" "${EFFORT:-default}" || {
  echo "error: destination launch or acknowledgement failed" >&2
  exit 1
}
DESTINATION_PUBLISHED=1
printf 'relaunched %s as %s at %s\n' "$SOURCE" "$DESTINATION" "$SOURCE_COMMIT"
