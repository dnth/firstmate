#!/usr/bin/env bash
# Deterministic behavior tests for the explicit clean-commit relaunch owner.
#
# The fixture uses linked Git worktrees plus fake Treehouse and Herdr adapters.
# no-mistakes adapters. No test creates, stops, or interrogates a live Herdr
# process. Every refusal asserts that allocation was never requested and that
# source task records and branch identity remain unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAL_GIT=$(command -v git)
REAL_LN=$(command -v ln)
REAL_JQ=$(command -v jq)

TMP_ROOT=$(fm_test_tmproot fm-clean-commit-relaunch)
fm_git_identity fmtest fmtest@example.invalid

copy_runtime() {  # <fixture>
  local fixture=$1 file
  mkdir -p "$fixture/bin/backends"
  for file in \
    fm-clean-commit-relaunch.sh fm-clean-commit-relaunch-launch-lib.sh \
    fm-lock-lib.sh fm-nm-run-lib.sh fm-pr-lib.sh fm-task-inbox-lib.sh \
    fm-wake-lib.sh fm-backend.sh fm-omp-process-lib.sh fm-tmux-lib.sh \
    fm-session-lock-lib.sh fm-pool-lib.sh fm-treehouse-root-lib.sh; do
    cp "$ROOT/bin/$file" "$fixture/bin/$file"
  done
  cat > "$fixture/bin/backends/herdr.sh" <<'SH'
fm_backend_herdr_agent_state() {
  case "${FM_TEST_ENDPOINT:-missing}" in
    missing) printf missing ;;
    live) printf alive ;;
    dead) printf dead ;;
    *) printf unreadable ;;
  esac
}
fm_backend_herdr_container_ensure() { printf 'firstmate:workspace\tseeded'; }
fm_backend_herdr_create_task() {
  printf 'create-task %s\n' "$*" >> "$FM_TEST_HERDR_LOG"
  [ -z "${FM_TEST_LAUNCH_DELAY:-}" ] || sleep "$FM_TEST_LAUNCH_DELAY"
  [ "${FM_TEST_LAUNCH_FAIL:-0}" != 1 ] || return 1
  printf 'tab-destination pane-destination'
}
fm_backend_herdr_send_text_line() { printf 'send-text %s\n' "$*" >> "$FM_TEST_HERDR_LOG"; }
fm_backend_herdr_send_literal() { printf 'send-literal %s\n' "$*" >> "$FM_TEST_HERDR_LOG"; }
fm_backend_herdr_send_key() { printf 'send-key %s\n' "$*" >> "$FM_TEST_HERDR_LOG"; }
fm_backend_herdr_send_text_submit() {
  printf 'submit %s\n' "$*" >> "$FM_TEST_HERDR_LOG"
  for message in "$FM_TEST_HOME/state/$FM_TEST_DESTINATION_ID.inbox"/*.msg; do
    [ -e "$message" ] || continue
    [ "${FM_TEST_ACK_MODE:-success}" = success ] && mv "$message" "$FM_TEST_HOME/state/$FM_TEST_DESTINATION_ID.inbox/handled/"
  done
  printf empty
}
fm_backend_herdr_composer_state() { printf empty; }
fm_backend_herdr_kill() { printf 'kill %s\n' "$*" >> "$FM_TEST_HERDR_LOG"; }
SH
  cat > "$fixture/bin/fm-receipt-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fixture/bin/fm-treehouse-get.sh" <<'SH'
#!/usr/bin/env bash
set -eu
case "${FM_TEST_ALLOCATOR_MODE:-success}" in
  success) ;;
  source) printf '%s\n' "$FM_TEST_SOURCE_WORKTREE"; exit 0 ;;
  project) printf '%s\n' "$FM_TEST_PROJECT"; exit 0 ;;
  task) printf '%s\n' "$FM_TEST_TASK_WORKTREE"; exit 0 ;;
  *) exit 1 ;;
esac
[ -z "${FM_TEST_ALLOCATOR_DELAY:-}" ] || sleep "$FM_TEST_ALLOCATOR_DELAY"
[ -z "${FM_TEST_ALLOCATOR_DIRTY:-}" ] || : > "$FM_TEST_DESTINATION/allocator-dirty"
[ "${FM_TEST_ALLOCATOR_TREEHOUSE_CONFIG:-0}" != 1 ] || : > "$FM_TEST_DESTINATION/treehouse.toml"
printf '%s\n' "$FM_TEST_DESTINATION"
SH
  cat > "$fixture/bin/fm-treehouse-command.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_TEST_ALLOCATOR_LOG"
if [ "${1:-}" = return ]; then
  [ "${FM_TEST_RETURN_FAIL:-0}" != 1 ] || exit 1
  path=${!#}
  [ "${2:-}" = --if-lease-holder ] && [ "${3:-}" = "fm-$FM_TEST_DESTINATION_ID" ] \
    && [ "$path" = "$FM_TEST_DESTINATION" ] || exit 1
  git -C "$FM_TEST_PROJECT" worktree remove --force "$path" >/dev/null 2>&1 || true
fi
SH
  chmod +x "$fixture/bin"/*.sh "$fixture/bin/backends/herdr.sh"
}

make_fakebin() {  # <fixture>
  local fixture fakebin
  fixture=$1
  fakebin="$fixture/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${FM_TEST_CUSTODY:-none}" in
  none) printf 'no active run\n'; exit 1 ;;
  active) printf 'id: run-active\nbranch: %s\nhead: %s\nstatus: running\n' "$FM_TEST_SOURCE_BRANCH" "$FM_TEST_SOURCE_HEAD" ;;
  parked) printf 'id: run-parked\nbranch: %s\nhead: %s\nstatus: awaiting_approval\n' "$FM_TEST_SOURCE_BRANCH" "$FM_TEST_SOURCE_HEAD" ;;
  unreadable) printf 'status: unknown\n' ;;
esac
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log() { printf '%s\n' "$*" >> "$FM_TEST_TMUX_LOG"; }
command=${1:-}
shift || true
case "$command" in
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  list-windows)
    case "${FM_TEST_ENDPOINT:-missing}" in
      unreadable) printf 'error connecting to fixture\n' >&2; exit 1 ;;
    esac
    case "${FM_TEST_ENDPOINT:-missing}" in
      live|dead|ambiguous) printf 'fm-source\n' ;;
    esac
    [ ! -f "$FM_TEST_WINDOWS" ] || cat "$FM_TEST_WINDOWS"
    ;;
  new-window)
    log "new-window $*"
    if [ "${FM_TEST_FOREIGN_WINDOW_RACE:-0}" = 1 ]; then
      printf 'fm-%s\n' "$FM_TEST_DESTINATION_ID" >> "$FM_TEST_WINDOWS"
      exit 1
    fi
    [ "${FM_TEST_DUPLICATE_WINDOW_RACE:-0}" != 1 ] || printf 'fm-%s\n' "$FM_TEST_DESTINATION_ID" >> "$FM_TEST_WINDOWS"
    [ -z "${FM_TEST_LAUNCH_DELAY:-}" ] || sleep "$FM_TEST_LAUNCH_DELAY"
    [ "${FM_TEST_LAUNCH_FAIL:-0}" != 1 ] || exit 1
    printf 'fm-%s\n' "$FM_TEST_DESTINATION_ID" >> "$FM_TEST_WINDOWS"
    printf '%%42\n'
    ;;
  set-window-option) exit 0 ;;
  display-message)
    case "$*" in
      *'#{pane_current_command}'*)
        case "${FM_TEST_ENDPOINT:-missing}" in
          dead) printf 'bash\n' ;;
          ambiguous) printf 'unknown-agent\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *'#{pane_id}'*) printf '%%9\n' ;;
      *'#{pane_current_path}'*) printf '%s\n' "$FM_TEST_DESTINATION" ;;
      *) printf 'firstmate\n' ;;
    esac
    ;;
  capture-pane) printf '> \n' ;;
  send-keys)
    log "send-keys $*"
    case "$*" in
      *codex*) [ "${FM_TEST_LAUNCH_COMMAND_FAIL:-0}" != 1 ] || exit 1 ;;
    esac
    case "$*" in
      *'Firstmate instruction waiting:'*)
        [ "${FM_TEST_ACK_MODE:-success}" = success ] || exit 0
        for message in "$FM_TEST_HOME/state/$FM_TEST_DESTINATION_ID.inbox"/*.msg; do
          [ -e "$message" ] || continue
          mv "$message" "$FM_TEST_HOME/state/$FM_TEST_DESTINATION_ID.inbox/handled/"
        done
        ;;
    esac
    ;;
  kill-window) log "kill-window $*" ;;
esac
SH
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$1" = -C ] && [ "${3:-}" = checkout ] && [ "${4:-}" = -b ]; then
  if [ "${FM_TEST_CHECKOUT_RACE:-0}" = 1 ]; then
    "${FM_TEST_REAL_GIT}" -C "$2" branch "$5" "$6"
    exit 1
  fi
  [ "${FM_TEST_CHECKOUT_FAIL:-0}" != 1 ] || exit 1
fi
exec "${FM_TEST_REAL_GIT}" "$@"
SH
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
destination=${!#}
case "$destination" in
  */relaunch-handoff.json)
    [ "${FM_TEST_HANDOFF_RACE:-0}" != 1 ] || printf 'foreign handoff\n' > "$destination"
    ;;
  */destination.meta)
    [ "${FM_TEST_META_RACE:-0}" != 1 ] || printf 'foreign metadata\n' > "$destination"
    ;;
esac
exec "$FM_TEST_REAL_LN" "$@"
SH
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_TEST_JQ_FAIL:-0}" != 1 ] || exit 1
exec "$FM_TEST_REAL_JQ" "$@"
SH
  chmod +x "$fakebin"/*
}

write_brief() {  # <path> <mode>
  local path=$1 mode=$2
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
# Task
Exercise the relaunch fixture.

# Acceptance criteria
- AC1: The fixture exposes its destination behavior.

# Definition of done
Delivery contract: mode=$mode
EOF
}

new_case() {  # <name>
  local name fixture project source destination other home
  name=$1
  fixture="$TMP_ROOT/$name"
  project="$fixture/project"
  source="$fixture/source"
  destination="$fixture/destination"
  other="$fixture/other"
  home="$fixture/home"
  mkdir -p "$fixture" "$fixture/tmp" "$home/state" "$home/data" "$home/config" "$project"
  git -C "$project" init -q
  printf '%s\n' initial > "$project/tracked.txt"
  git -C "$project" add tracked.txt
  git -C "$project" commit -qm initial
  git -C "$project" branch -M main
  git -C "$project" worktree add -q -b fm/source "$source" main
  printf '%s\n' committed > "$source/committed.txt"
  git -C "$source" add committed.txt
  git -C "$source" commit -qm committed-source
  git -C "$project" worktree add -q -b pool/destination "$destination" main
  git -C "$project" worktree add -q -b fm/other "$other" main
  copy_runtime "$fixture"
  make_fakebin "$fixture"
  write_brief "$home/data/source/brief.md" no-mistakes
  write_brief "$home/data/destination/brief.md" no-mistakes
  cat > "$home/state/source.meta" <<EOF
endpoint_task_id=source
worktree=$source
project=$project
harness=codex
backend=herdr
herdr_session=firstmate
herdr_workspace_id=workspace-source
herdr_tab_id=tab-source
herdr_pane_id=pane-source
window=firstmate:pane-source
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
tasktmp=$fixture/tmp/fm-source
pr=https://github.com/example/repo/pull/1
EOF
: > "$home/state/source.status"
mkdir -p "$home/state/source.inbox/handled" "$fixture/tmp/fm-source"
printf '%s\n' source-session > "$home/state/source.hermes-session"
printf '%s\n' source-presentation > "$home/state/source.herdr-presentation"
printf '%s\n' source-validation > "$home/state/source.pr-poll"
printf '%s\n' source-inbox > "$home/state/source.inbox/001.msg"
printf '%s\n' source-temp > "$fixture/tmp/fm-source/session"
printf '%s\n' source-receipt > "$home/data/source/evidence.jsonl"
printf 'worktree=%s\n' "$other" > "$home/state/other.meta"
  : > "$fixture/windows"
  : > "$fixture/allocator.log"
  : > "$fixture/tmux.log"
  printf '%s\n' "$fixture"
}

run_owner() {  # <fixture> [source] [destination]
  local fixture=$1 source=${2:-source} destination=${3:-destination} source_branch source_head
  source_branch=$(git -C "$fixture/source" symbolic-ref --short HEAD)
  source_head=$(git -C "$fixture/source" rev-parse HEAD)
  PATH="$fixture/fakebin:$PATH" \
    FM_TEST_REAL_GIT="$REAL_GIT" \
    FM_TEST_REAL_LN="$REAL_LN" \
    FM_TEST_REAL_JQ="$REAL_JQ" \
    FM_TEST_HOME="$fixture/home" \
    FM_TEST_PROJECT="$fixture/project" \
    FM_TEST_SOURCE_WORKTREE="$fixture/source" \
    FM_TEST_SOURCE_BRANCH="$source_branch" \
    FM_TEST_SOURCE_HEAD="$source_head" \
    FM_TEST_TASK_WORKTREE="$fixture/other" \
    FM_TEST_DESTINATION="$fixture/destination" \
    FM_TEST_DESTINATION_ID="$destination" \
    FM_TEST_WINDOWS="$fixture/windows" \
    FM_TEST_ALLOCATOR_LOG="$fixture/allocator.log" \
    FM_TEST_HERDR_LOG="$fixture/tmux.log" \
    TMPDIR="$fixture/tmp" FM_HOME="$fixture/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$fixture/bin/fm-clean-commit-relaunch.sh" "$source" "$destination"
}

source_snapshot() {  # <fixture>
  local fixture source home
  fixture=$1
  source="$fixture/source"
  home="$fixture/home"
  {
    git -C "$source" status --porcelain --untracked-files=all
    git -C "$source" rev-parse HEAD
    git -C "$source" rev-parse refs/heads/fm/source
    sha256sum "$home/state/source.meta" "$home/state/source.status" \
      "$home/state/source.hermes-session" "$home/state/source.herdr-presentation" \
      "$home/state/source.pr-poll" "$home/state/source.inbox/001.msg" \
      "$home/data/source/brief.md" "$home/data/source/evidence.jsonl" \
      "$fixture/tmp/fm-source/session"
  } | sha256sum | awk '{print $1}'
}

assert_refused_before_allocation() {  # <fixture> <output> <label>
  local fixture=$1 output=$2 label=$3
  [ -z "$(cat "$fixture/allocator.log")" ] || fail "$label allocated a destination before refusing"
  assert_contains "$output" 'error:' "$label did not explain its refusal"
}

# Success accepts linked worktrees sharing a common directory, creates the exact
# destination branch, records only stable handoff fields, and leaves every
# source-owned record and ref unchanged.
fixture=$(new_case success)
before=$(source_snapshot "$fixture")
out=$(run_owner "$fixture" 2>&1)
expect_code 0 $? "linked-worktree relaunch should succeed"
assert_contains "$out" 'relaunched source as destination' "success output omitted source and destination"
source_head=$(git -C "$fixture/source" rev-parse HEAD)
[ "$(git -C "$fixture/destination" rev-parse HEAD)" = "$source_head" ] || fail "destination did not retain the admitted source commit"
[ "$(git -C "$fixture/destination" symbolic-ref --short HEAD)" = fm/destination ] || fail "destination did not receive its fresh branch"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "success mutated source-owned branch or records"
assert_present "$fixture/home/state/destination.meta" "success did not publish destination metadata"
assert_present "$fixture/home/data/destination/relaunch-handoff.json" "success did not publish handoff"
jq -e --arg commit "$source_head" '
  .schema == "fm-clean-commit-relaunch.v1" and .source == "source" and .destination == "destination" and
  .source_commit == $commit and .source_branch == "fm/source" and .destination_branch == "fm/destination" and
  .delivery == {mode:"no-mistakes",yolo:"off"} and .no_mistakes_custody == {state:"none",next_action:"proceed"} and
  .pr == "https://github.com/example/repo/pull/1" and (.repository_identity | type == "string" and length == 64)
' "$fixture/home/data/destination/relaunch-handoff.json" >/dev/null || fail "handoff omitted stable admitted identities"
assert_no_grep "$fixture/source" "$fixture/home/data/destination/relaunch-handoff.json" "handoff captured mutable source path"
assert_no_grep 'FM_CLEAN' "$fixture/home/data/destination/relaunch-handoff.json" "handoff captured caller environment"
pass "clean relaunch: linked worktree success preserves source and binds exact destination identity"

# The pool's untracked root configuration is normal allocator state, not work.
fixture=$(new_case treehouse-config)
before=$(source_snapshot "$fixture")
out=$(FM_TEST_ALLOCATOR_TREEHOUSE_CONFIG=1 run_owner "$fixture" 2>&1)
expect_code 0 $? "Treehouse-configured destination should succeed"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "Treehouse-configured destination mutated source"
[ -f "$fixture/destination/treehouse.toml" ] || fail "Treehouse-configured destination lost its pool configuration"
pass "clean relaunch: lone Treehouse pool configuration remains admissible"

# Endpoint state is admission, never a recovery guess.
for endpoint in live dead ambiguous unreadable; do
  fixture=$(new_case "endpoint-$endpoint")
  before=$(source_snapshot "$fixture")
  out=$(FM_TEST_ENDPOINT="$endpoint" run_owner "$fixture" 2>&1)
  expect_code 1 $? "endpoint $endpoint should refuse"
  assert_refused_before_allocation "$fixture" "$out" "endpoint $endpoint"
  [ "$(source_snapshot "$fixture")" = "$before" ] || fail "endpoint $endpoint mutated source"
done
pass "clean relaunch: only an authoritatively missing endpoint passes admission"

# Metadata identity, role, home, and durable occupancy all refuse before the
# allocator can create a destination.
for mutation in malformed wrong-kind secondmate endpoint-mismatch destination-occupied destination-doorbell-requests duplicate-pr noncanonical-pr branch-collision; do
  fixture=$(new_case "admission-$mutation")
  case "$mutation" in
    malformed) printf 'worktree=%s\n' "$fixture/source" >> "$fixture/home/state/source.meta" ;;
    wrong-kind) sed -i 's/^kind=ship$/kind=scout/' "$fixture/home/state/source.meta" ;;
    secondmate) printf 'home=%s\n' "$fixture/home" >> "$fixture/home/state/source.meta" ;;
    endpoint-mismatch) sed -i 's/^endpoint_task_id=source$/endpoint_task_id=other/' "$fixture/home/state/source.meta" ;;
    destination-occupied) : > "$fixture/home/state/destination.status" ;;
    destination-doorbell-requests) : > "$fixture/home/state/destination.omp-doorbell-ready.requests" ;;
    duplicate-pr) printf 'pr=https://github.com/example/repo/pull/2\n' >> "$fixture/home/state/source.meta" ;;
    noncanonical-pr) sed -i 's#^pr=.*#pr=https://github.com/example/repo/pull/not-a-number#' "$fixture/home/state/source.meta" ;;
    branch-collision) git -C "$fixture/project" branch fm/destination main ;;
  esac
  before=$(source_snapshot "$fixture")
  out=$(run_owner "$fixture" 2>&1)
  expect_code 1 $? "$mutation should refuse"
  assert_refused_before_allocation "$fixture" "$out" "$mutation"
  [ "$(source_snapshot "$fixture")" = "$before" ] || fail "$mutation mutated source"
done
pass "clean relaunch: malformed, foreign, occupied, and colliding admission cases refuse"

# Dirty source states and every active Git operation marker are never salvaged.
for mutation in staged untracked deleted detached missing-branch unreachable; do
  fixture=$(new_case "git-$mutation")
  case "$mutation" in
    staged) printf '%s\n' staged > "$fixture/source/staged.txt"; git -C "$fixture/source" add staged.txt ;;
    untracked) printf '%s\n' untracked > "$fixture/source/untracked.txt" ;;
    deleted) rm "$fixture/source/tracked.txt" ;;
    detached) git -C "$fixture/source" checkout -q --detach ;;
    missing-branch) git -C "$fixture/source" update-ref -d refs/heads/fm/source ;;
    unreachable) git -C "$fixture/source" commit-tree "HEAD^{tree}" -m unreachable >/dev/null; git -C "$fixture/project" update-ref -d refs/heads/fm/source ;;
  esac
  out=$(run_owner "$fixture" 2>&1)
  expect_code 1 $? "git state $mutation should refuse"
  assert_refused_before_allocation "$fixture" "$out" "git state $mutation"
done
for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD BISECT_START BISECT_LOG sequencer rebase-apply rebase-merge; do
  fixture=$(new_case "marker-$marker")
  path=$(git -C "$fixture/source" rev-parse --git-path "$marker")
  if [ "$marker" = sequencer ] || [ "$marker" = rebase-apply ] || [ "$marker" = rebase-merge ]; then mkdir -p "$path"; else : > "$path"; fi
  out=$(run_owner "$fixture" 2>&1)
  expect_code 1 $? "Git marker $marker should refuse"
  assert_refused_before_allocation "$fixture" "$out" "Git marker $marker"
done
pass "clean relaunch: dirty, detached, unreachable, and Git-operation sources refuse"

# Custody is an admission boundary, including malformed data.
for custody in active parked unreadable; do
  fixture=$(new_case "custody-$custody")
  before=$(source_snapshot "$fixture")
  out=$(FM_TEST_CUSTODY="$custody" run_owner "$fixture" 2>&1)
  expect_code 1 $? "custody $custody should refuse"
  assert_refused_before_allocation "$fixture" "$out" "custody $custody"
  case "$custody" in
    active|parked) assert_contains "$out" 'active or parked No-Mistakes custody' "$custody custody was not parsed" ;;
    unreadable) assert_contains "$out" 'custody is unreadable or malformed' "unreadable custody was not parsed" ;;
  esac
  [ "$(source_snapshot "$fixture")" = "$before" ] || fail "custody $custody mutated source"
done
pass "clean relaunch: active, parked, and unreadable No-Mistakes custody refuses"

fixture=$(new_case malformed-other-worktree)
printf 'worktree=%s\n' "$fixture/destination" >> "$fixture/home/state/other.meta"
before=$(source_snapshot "$fixture")
out=$(run_owner "$fixture" 2>&1)
expect_code 1 $? "malformed foreign worktree metadata should refuse"
assert_refused_before_allocation "$fixture" "$out" "malformed foreign worktree metadata"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "malformed foreign worktree metadata mutated source"
pass "clean relaunch: malformed foreign worktree metadata refuses"

fixture=$(new_case symlinked-other-worktree)
rm -f -- "$fixture/home/state/other.meta"
ln -s "$fixture/other" "$fixture/home/state/other.meta"
before=$(source_snapshot "$fixture")
out=$(run_owner "$fixture" 2>&1)
expect_code 1 $? "symlinked foreign worktree metadata should refuse"
assert_refused_before_allocation "$fixture" "$out" "symlinked foreign worktree metadata"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "symlinked foreign worktree metadata mutated source"
pass "clean relaunch: symlinked foreign worktree metadata refuses"

# Failure after allocation leaves no source change and cleans only the new
# destination's branch, endpoint, task data, and leased worktree.
for failure in allocator checkout launch acknowledgement; do
  fixture=$(new_case "failure-$failure")
  before=$(source_snapshot "$fixture")
  case "$failure" in
    allocator)
      out=$(FM_TEST_ALLOCATOR_MODE=fail run_owner "$fixture" 2>&1)
      status=$?
      ;;
    checkout)
      out=$(FM_TEST_CHECKOUT_FAIL=1 run_owner "$fixture" 2>&1)
      status=$?
      ;;
    launch)
      out=$(FM_TEST_LAUNCH_FAIL=1 run_owner "$fixture" 2>&1)
      status=$?
      ;;
    acknowledgement)
      out=$(FM_TEST_ACK_MODE=timeout FM_CLEAN_COMMIT_RELAUNCH_ACK_POLLS=2 FM_CLEAN_COMMIT_RELAUNCH_ACK_INTERVAL=0.01 run_owner "$fixture" 2>&1)
      status=$?
      ;;
  esac
  expect_code 1 "$status" "$failure should fail"
  assert_contains "$out" 'error:' "$failure did not report failure"
  [ "$(source_snapshot "$fixture")" = "$before" ] || fail "$failure mutated source"
  assert_absent "$fixture/home/state/destination.meta" "$failure retained destination metadata"
  assert_absent "$fixture/home/data/destination/relaunch-handoff.json" "$failure retained destination handoff"
  git -C "$fixture/project" show-ref --verify --quiet refs/heads/fm/destination && fail "$failure retained destination branch"
done
pass "clean relaunch: allocator, checkout, launch, and acknowledgement failure preserve source"

fixture=$(new_case allocator-dirty-destination)
before=$(source_snapshot "$fixture")
out=$(FM_TEST_ALLOCATOR_DIRTY=1 run_owner "$fixture" 2>&1)
expect_code 1 $? "dirty allocated destination should fail"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "dirty allocated destination mutated source"
assert_absent "$fixture/destination" "dirty allocated destination retained its lease"
assert_contains "$(cat "$fixture/allocator.log")" 'return --if-lease-holder fm-destination' "dirty allocated destination was not returned"
git -C "$fixture/project" show-ref --verify --quiet refs/heads/fm/destination && fail "dirty allocated destination retained destination branch"
pass "clean relaunch: rejected allocated destination returns its lease"

fixture=$(new_case handoff-staging-failure)
before=$(source_snapshot "$fixture")
out=$(FM_TEST_JQ_FAIL=1 run_owner "$fixture" 2>&1)
expect_code 1 $? "handoff rendering failure should fail"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "handoff rendering failure mutated source"
[ -z "$(find "$fixture/home/data/destination" -maxdepth 1 -name '.relaunch-handoff.*' -print -quit)" ] || fail "handoff rendering failure retained staging file"
assert_absent "$fixture/home/data/destination/relaunch-handoff.json" "handoff rendering failure published handoff"
git -C "$fixture/project" show-ref --verify --quiet refs/heads/fm/destination && fail "handoff rendering failure retained destination branch"
pass "clean relaunch: handoff rendering failure removes staging state"

# A malicious or faulty allocator cannot turn source preservation into cleanup.
fixture=$(new_case allocator-reuses-source)
before=$(source_snapshot "$fixture")
out=$(FM_TEST_ALLOCATOR_MODE=source run_owner "$fixture" 2>&1)
expect_code 1 $? "source-reusing allocator should refuse"
assert_contains "$out" 'reused the source worktree' "source-reusing allocator did not explain its refusal"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "source-reusing allocator cleaned or mutated source"
[ -d "$fixture/source" ] || fail "source-reusing allocator removed the source worktree"
assert_not_contains "$(cat "$fixture/allocator.log")" '--force' "source-reusing allocator used unsafe cleanup"
pass "clean relaunch: source-reusing allocator cannot clean the source"

# Only an unclaimed pool worktree may become cleanup-owned destination state.
for allocator in project task; do
  fixture=$(new_case "allocator-reuses-$allocator")
  before=$(source_snapshot "$fixture")
  out=$(FM_TEST_ALLOCATOR_MODE="$allocator" run_owner "$fixture" 2>&1)
  expect_code 1 $? "$allocator-reusing allocator should refuse"
  assert_contains "$out" 'error:' "$allocator-reusing allocator did not explain its refusal"
  [ "$(source_snapshot "$fixture")" = "$before" ] || fail "$allocator-reusing allocator mutated source"
  assert_not_contains "$(cat "$fixture/allocator.log")" '--force' "$allocator-reusing allocator used unsafe cleanup"
  git -C "$fixture/project" show-ref --verify --quiet refs/heads/fm/destination && fail "$allocator-reusing allocator created a destination branch"
done
pass "clean relaunch: allocator must not reuse existing project worktrees"

# A return failure stays visible and leaves the lease-bound destination intact.
fixture=$(new_case return-failure)
before=$(source_snapshot "$fixture")
out=$(FM_TEST_LAUNCH_FAIL=1 FM_TEST_RETURN_FAIL=1 run_owner "$fixture" 2>&1)
expect_code 1 $? "return failure should fail"
assert_contains "$out" 'destination cleanup is incomplete' "return failure was suppressed"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "return failure mutated source"
assert_present "$fixture/destination" "return failure removed the destination worktree"
git -C "$fixture/project" show-ref --verify --quiet refs/heads/fm/destination || fail "return failure removed attached destination branch"
pass "clean relaunch: failed destination return remains actionable"

fixture=$(new_case handoff-race)
before=$(source_snapshot "$fixture")
out=$(FM_TEST_HANDOFF_RACE=1 run_owner "$fixture" 2>&1)
expect_code 1 $? "concurrent handoff creation should fail"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "concurrent handoff creation mutated source"
[ "$(cat "$fixture/home/data/destination/relaunch-handoff.json")" = 'foreign handoff' ] || fail "concurrent handoff was overwritten or removed"
pass "clean relaunch: concurrent handoff remains foreign"

fixture=$(new_case metadata-race)
before=$(source_snapshot "$fixture")
out=$(FM_TEST_META_RACE=1 run_owner "$fixture" 2>&1)
expect_code 1 $? "concurrent metadata creation should fail"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "concurrent metadata creation mutated source"
[ "$(cat "$fixture/home/state/destination.meta")" = 'foreign metadata' ] || fail "concurrent metadata was overwritten or removed"
pass "clean relaunch: concurrent metadata remains foreign"

fixture=$(new_case published-output-failure)
before=$(source_snapshot "$fixture")
run_owner "$fixture" >/dev/full 2>"$fixture/published-output-failure.out"
status=$?
expect_code 1 "$status" "published output failure should fail"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "published output failure mutated source"
assert_absent "$fixture/home/state/destination.meta" "published output failure retained destination metadata"
assert_absent "$fixture/home/data/destination/relaunch-handoff.json" "published output failure retained destination handoff"
git -C "$fixture/project" show-ref --verify --quiet refs/heads/fm/destination && fail "published output failure retained destination branch"
pass "clean relaunch: published output failure cleans destination"

# A concurrent branch creation never becomes this relaunch's cleanup target.
fixture=$(new_case branch-race)
before=$(source_snapshot "$fixture")
out=$(FM_TEST_CHECKOUT_RACE=1 run_owner "$fixture" 2>&1)
expect_code 1 $? "concurrent branch creation should fail"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "concurrent branch creation mutated source"
git -C "$fixture/project" show-ref --verify --quiet refs/heads/fm/destination || fail "concurrent branch creation was deleted"
pass "clean relaunch: concurrent destination branch remains foreign"

# An interrupt after handoff publication exits through destination-only cleanup.
fixture=$(new_case interrupted-publication)
before=$(source_snapshot "$fixture")
FM_TEST_LAUNCH_DELAY=5 run_owner "$fixture" >"$fixture/interrupted.out" 2>&1 &
pid=$!
# Wait for both the published handoff and the delayed endpoint creation. The
# latter is the fixture's observable barrier that the owner has entered the
# post-publication launch window before this test interrupts it.
for _ in $(seq 1 400); do
  [ -f "$fixture/home/data/destination/relaunch-handoff.json" ] \
    && grep -Fq 'create-task ' "$fixture/tmux.log" && break
  sleep 0.01
done
assert_present "$fixture/home/data/destination/relaunch-handoff.json" "interrupt fixture did not reach destination publication"
grep -Fq 'create-task ' "$fixture/tmux.log" \
  || fail "interrupt fixture did not enter the delayed destination launch"
kill -HUP "$pid"
wait "$pid"
status=$?
expect_code 1 "$status" "interrupted publication should fail"
[ "$(source_snapshot "$fixture")" = "$before" ] || fail "interrupted publication mutated source"
assert_absent "$fixture/home/state/destination.meta" "interrupted publication retained destination metadata"
assert_absent "$fixture/home/data/destination/relaunch-handoff.json" "interrupted publication retained handoff"
git -C "$fixture/project" show-ref --verify --quiet refs/heads/fm/destination && fail "interrupted publication retained destination branch"
pass "clean relaunch: interrupted destination publication preserves source"

# The destination lock serializes two simultaneous attempts before a second
# endpoint or branch can be created.
fixture=$(new_case concurrency)
FM_TEST_ALLOCATOR_DELAY=0.2 run_owner "$fixture" >"$fixture/first.out" 2>&1 &
pid=$!
sleep 0.05
out=$(run_owner "$fixture" 2>&1)
status=$?
wait "$pid"
first_status=$?
[ "$first_status" -eq 0 ] || fail "first concurrent relaunch did not succeed: $(cat "$fixture/first.out")"
[ "$status" -ne 0 ] || fail "second concurrent relaunch unexpectedly succeeded"
[ "$(grep -c '^create-task ' "$fixture/tmux.log")" -eq 1 ] || fail "concurrent relaunch created duplicate endpoints"
pass "clean relaunch: destination lock serializes concurrent requests"

# Generic spawn retains its public fresh-task interface; legacy relaunch flags
help=$("$ROOT/bin/fm-spawn.sh" --help)
assert_not_contains "$help" 'accepted-clean-commit' "generic spawn still exposes a relaunch commit flag"
assert_not_contains "$help" 'relaunch-handoff' "generic spawn still exposes handoff authority"
assert_not_contains "$help" 'allocated-worktree' "generic spawn still exposes an allocated-worktree mode"
pass "clean relaunch: generic spawn exposes no relaunch carrier"
