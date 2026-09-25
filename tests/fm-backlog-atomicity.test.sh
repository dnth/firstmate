#!/usr/bin/env bash
# Behavior tests for the backlog<->record pairing invariant:
# `state/<id>.meta` exists <=> this home's backlog row for that id is In flight.
#
# bin/fm-backlog-transition-lib.sh states the contract; the three scripts that
# own a task's physical record enforce it. These tests drive those real scripts
# against a real backlog file and the real tasks-axi CLI, and assert the
# resulting RECORD STATE - never the wording of a reminder a later turn was
# expected to act on, which is exactly what let the two records drift before.
#
#   dispatch    bin/fm-spawn.sh moves the row In flight in the same run that
#               publishes the record, so a live worker the backlog does not own
#               cannot arise on the ordinary path.
#   completion  bin/fm-teardown.sh closes the row before it reports success, so
#               a finished task cannot be left showing as running.
#   recovery    bin/fm-bootstrap.sh reconciles THIS home's own books at session
#               start, covering the millisecond crash window inside those two
#               scripts and any drift a home was already carrying.
#
# The invariant is single-host: a home's backlog and its records live together,
# so a persistent secondmate keeps its own books through its own copies of these
# scripts. A parent's view of a mate lagging is a freshness question and is
# deliberately not asserted here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# An exported TASKS_AXI_BACKEND would outrank each case's .tasks.toml fixture
# in fm_tasks_axi_backend, so the backend cases must start from a clean slate.
unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-atomicity)

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; the fused transitions are inert without it)\n'
  exit 0
}

# --- fixture ----------------------------------------------------------------

# fm_tasks_axi_backend reads <addressing-root>/.tasks.toml and otherwise falls
# through to the developer's ambient ~/.tasks-axi/config.toml. make_home pins
# the home itself; a case that relocates its data directory is addressed from
# that directory's own parent instead, so it pins that root too.
pin_markdown_backend() {  # <addressing-root>
  printf '%s\n' 'backend = "markdown"' > "$1/.tasks.toml"
}

# A home with a real backlog, a real project clone with an origin, a pooled
# worktree, and stubs for every tool the spawn path shells out to.
make_home() {  # <name> [task-id...]
  local name=$1 case_dir home fakebin id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' claude > "$home/config/crew-harness"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  # Pin the adapter per case: without it fm_tasks_axi_backend would fall through
  # to the developer's ambient tasks-axi config and silently exercise a
  # different transition path.
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise backlog dispatch for $id.

## Firstmate spec
Verify the atomic backlog transition.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  done

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *pane_current_path*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *pane_current_command*) printf 'bash\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_path*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
      *pane_pid*) printf '4242\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0 ;;
  list-windows) [ -n "${FM_FAKE_LIST_WINDOWS:-}" ] && printf '%s\n' "$FM_FAKE_LIST_WINDOWS"; exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_SEND_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_SEND_LOG"
    fi
    for arg in "$@"; do
      case "$arg" in
        *'--ready-file '*)
          ready_file=${arg##*--ready-file }
          ready_file=${ready_file%% *}
          printf '%s\n' "${FM_FAKE_READY_PATH:-${FM_FAKE_PANE_PATH:-}}" > "$ready_file"
          break
          ;;
      esac
    done
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-o tpgid="*) printf '4242\n' ;;
  *"-p 4242 -o comm="*) printf 'bash\n' ;;
  *"-p 4242 -o args="*) printf 'bash\n' ;;
  *"-axo pid=,pgid=,ppid="*) printf '4242 4242 1\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes

  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  git -C "$case_dir/project" worktree add --quiet -b pooled "$case_dir/wt"

  printf '%s\n' "$case_dir"
}

home_of() { printf '%s/home\n' "$1"; }
backlog_of() { printf '%s/home/data/backlog.md\n' "$1"; }

add_item() {  # <case-dir> <id> [kind]
  tasks-axi add "$2" "item for $2" --kind "${3:-ship}" --file "$(backlog_of "$1")" >/dev/null
}

start_item() {  # <case-dir> <id>
  tasks-axi start "$2" --file "$(backlog_of "$1")" >/dev/null
}

row_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$(backlog_of "$1")" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Shadow tasks-axi with a wrapper that fails one verb and delegates every other
# verb to the real binary, so a test can drive a genuine mid-transition failure
# without faking the reads around it.
require_show_cwd() {  # <case-dir> <expected-dir>
  local case_dir=$1 expected=$2 real
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  show|start|done)
    if [ "\$PWD" != "$expected" ]; then
      echo "error: wrong tasks root: \$PWD" >&2
      exit 1
    fi
    ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

record_tasks_axi_calls() {  # <case-dir>
  local case_dir=$1 real
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tasks-axi-calls"
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

make_tasks_axi_incompatible() {  # <case-dir>
  local case_dir=$1 real
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != --version ] || exit 1
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

break_verb() {  # <case-dir> <verb>
  local case_dir=$1 verb=$2 real
  real=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "$verb" ]; then
  echo 'error: "backlog is unwritable"' >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

break_meta_removal() {  # <case-dir> <meta-path>
  local case_dir=$1 meta=$2 real
  real=$(command -v rm)
  cat > "$case_dir/fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != "$meta" ] || exit 1
done
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/rm"
}

break_busy_removal() {  # <case-dir> <id>
  local case_dir=$1 id=$2 real state
  real=$(command -v rm)
  state="$(home_of "$case_dir")/state"
  cat > "$case_dir/fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    "$state/$id.busy-state"|"$state/$id.busy-gen") exit 1 ;;
  esac
done
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/rm"
}

break_launch_delivery() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys) exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

interrupt_teardown_during_treehouse_return() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = return ] && [ ! -f "$case_dir/teardown-interrupted" ]; then
  : > "$case_dir/teardown-interrupted"
  teardown_pid=\$(ps -o ppid= -p "\$PPID" | tr -d ' ')
  case "\$teardown_pid" in ''|*[!0-9]*) exit 1 ;; esac
  kill -TERM "\$teardown_pid"
  kill -TERM "\$\$"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

write_task_meta() {  # <case-dir> <id> <kind> <mode> [extra-line...]
  local case_dir=$1 id=$2 kind=$3 mode=$4
  shift 4
  fm_write_meta "$(home_of "$case_dir")/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/absent-worktree" \
    "project=$case_dir/absent-project" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$mode" \
    "yolo=off" \
    "$@"
}

run_spawn() {  # <case-dir> <args...>
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$case_dir/wt" TMUX="fake,1,0" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {  # <case-dir> <id>
  local case_dir=$1 id=$2
  run_spawn "$case_dir" "$id" "$case_dir/project" --mode no-mistakes --yolo off
}

# Teardown against a recorded worktree that no longer exists: the landed-work and
# worktree-return steps are then no-ops, which keeps these cases about the
# backlog transition rather than re-testing tests/fm-teardown.test.sh's matrix.
run_teardown() {  # <case-dir> <id> [args...]
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$@" 2>&1
}

run_bootstrap() {  # <case-dir>
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    PATH="$case_dir/fakebin:$PATH" \
    "$BOOTSTRAP" 2>&1
}

# --- dispatch ---------------------------------------------------------------

test_dispatch_moves_the_item_in_flight_in_the_same_run() {
  local case_dir id out
  id=atomic-dispatch-b1
  case_dir=$(make_home dispatch-ok "$id")
  add_item "$case_dir" "$id"
  record_tasks_axi_calls "$case_dir"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "spawn failed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_present "$(home_of "$case_dir")/state/$id.meta" "spawn published no record"
  assert_grep "show $id --file $(backlog_of "$case_dir")" \
    "$case_dir/tasks-axi-calls" \
    "markdown dispatch did not pass the backlog file to show"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "spawn reported success with its backlog item still $(row_state "$case_dir" "$id")"
  pass "dispatch publishes the record and moves the backlog item In flight in one run"
}

test_dispatch_refuses_a_pending_authoritative_close() {
  local case_dir id marker out rc=0
  id=atomic-dispatch-pending-close-b1
  case_dir=$(make_home dispatch-pending-close "$id")
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-closing\narg=--pr\narg=https://github.com/example/repo/pull/12\n' \
    "$id" "$(home_of "$case_dir")/data" > "$marker"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *new-window*) : > "$case_dir/task-endpoint-created" ;;
  *treehouse\\ get*) : > "$case_dir/local-copy-requested" ;;
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted work with an authoritative close still pending"
  assert_contains "$out" "pending authoritative backlog close" \
    "spawn did not explain why the pending close blocks dispatch"
  assert_present "$marker" "spawn discarded the pending authoritative close"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "spawn published a new worker over a pending close"
  assert_absent "$case_dir/task-endpoint-created" \
    "spawn created an unowned endpoint before refusing the pending close"
  assert_absent "$case_dir/local-copy-requested" \
    "spawn requested an unowned local copy before refusing the pending close"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "refused dispatch changed the pending close's backlog row"
  pass "dispatch refuses to supersede a pending authoritative close"
}

test_dispatch_refuses_a_held_row_before_creating_resources() {
  local case_dir id out rc=0
  id=atomic-dispatch-held-b1
  case_dir=$(make_home dispatch-held "$id")
  add_item "$case_dir" "$id"
  tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
    --file "$(backlog_of "$case_dir")" >/dev/null
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *new-window*) : > "$case_dir/task-endpoint-created" ;;
  *treehouse\\ get*) : > "$case_dir/local-copy-requested" ;;
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted a held backlog row"
  assert_contains "$out" "state queued yes" \
    "held-row refusal did not name the actual ineligible state"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "held-row refusal published a task record"
  assert_absent "$case_dir/task-endpoint-created" \
    "held-row refusal created an unowned endpoint"
  assert_absent "$case_dir/local-copy-requested" \
    "held-row refusal requested an unowned local copy"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "held-row refusal changed the backlog state"
  pass "dispatch refuses held rows before creating resources"
}

test_dispatch_refuses_a_blocked_row_before_creating_resources() {
  local case_dir id blocker out rc=0
  id=atomic-dispatch-blocked-b16
  blocker=atomic-dispatch-blocker-b16
  case_dir=$(make_home dispatch-blocked "$id" "$blocker")
  add_item "$case_dir" "$blocker"
  tasks-axi add "$id" "item for $id" --kind ship --blocked-by "$blocker" \
    --file "$(backlog_of "$case_dir")" >/dev/null
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *new-window*) : > "$case_dir/task-endpoint-created" ;;
  *treehouse\\ get*) : > "$case_dir/local-copy-requested" ;;
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted a dependency-blocked backlog row"
  assert_contains "$out" "state queued no yes" \
    "blocked-row refusal did not name the actual ineligible state"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "blocked-row refusal published a task record"
  assert_absent "$case_dir/task-endpoint-created" \
    "blocked-row refusal created an unowned endpoint"
  assert_absent "$case_dir/local-copy-requested" \
    "blocked-row refusal requested an unowned local copy"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "blocked-row refusal changed the backlog state"
  pass "dispatch refuses dependency-blocked rows before creating resources"
}

test_dispatch_reads_the_row_from_the_backlog_root() {
  local case_dir id out
  id=atomic-dispatch-root-b2
  case_dir=$(make_home dispatch-root "$id")
  add_item "$case_dir" "$id"
  require_show_cwd "$case_dir" "$(cd "$(home_of "$case_dir")" && pwd -P)"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "spawn read outside the backlog root: $out"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "root-addressed dispatch left the backlog row queued"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "root-addressed dispatch did not publish its task record"
  pass "dispatch reads backlog rows from the backlog addressing root"
}

test_automatic_backend_refuses_incompatible_tasks_axi_before_mutation() {
  local spawn_case teardown_case id out rc=0
  id=atomic-incompatible-tasks-axi-b2
  spawn_case=$(make_home incompatible-tasks-axi-spawn "$id")
  add_item "$spawn_case" "$id"
  make_tasks_axi_incompatible "$spawn_case"

  out=$(run_ship_spawn "$spawn_case" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "automatic spawn succeeded without compatible tasks-axi"
  assert_contains "$out" "automatic backlog transitions require tasks-axi" \
    "automatic spawn did not report its unavailable transition tool"
  assert_absent "$(home_of "$spawn_case")/state/$id.meta" \
    "automatic spawn published a record without transition tooling"
  rm -f "$spawn_case/fakebin/tasks-axi"
  [ "$(row_state "$spawn_case" "$id")" = queued ] \
    || fail "automatic spawn changed the row without transition tooling"

  teardown_case=$(make_home incompatible-tasks-axi-teardown)
  add_item "$teardown_case" "$id"
  start_item "$teardown_case" "$id"
  write_task_meta "$teardown_case" "$id" ship local-only "spawn_gen=spawn-incompatible"
  make_tasks_axi_incompatible "$teardown_case"
  rc=0
  out=$(run_teardown "$teardown_case" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "automatic teardown succeeded without compatible tasks-axi"
  assert_contains "$out" "automatic backlog transitions require tasks-axi" \
    "automatic teardown did not report its unavailable transition tool"
  assert_present "$(home_of "$teardown_case")/state/$id.meta" \
    "automatic teardown removed its record without transition tooling"
  rm -f "$teardown_case/fakebin/tasks-axi"
  [ "$(row_state "$teardown_case" "$id")" = in_flight ] \
    || fail "automatic teardown changed the row without transition tooling"
  pass "automatic homes refuse lifecycle mutation without compatible tasks-axi"
}

test_dispatch_refuses_an_unresolvable_data_directory() {
  local case_dir id saved out rc=0
  id=atomic-dispatch-missing-data-b2
  case_dir=$(make_home dispatch-missing-data "$id")
  add_item "$case_dir" "$id"
  saved="$case_dir/backlog-data"
  mv "$(home_of "$case_dir")/data" "$saved"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded with an unresolvable data directory"
  assert_contains "$out" "task $id" \
    "spawn did not identify the task blocked by fatal backlog addressing"
  assert_contains "$out" "$(home_of "$case_dir")/data" \
    "spawn did not identify the inaccessible data directory"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "fatal backlog addressing created a task record"
  [ "$(tasks-axi show "$id" --file "$saved/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = queued ] \
    || fail "fatal backlog addressing changed the queued row"
  pass "dispatch refuses an unresolvable backlog data directory"
}

test_completion_refuses_an_unresolvable_data_directory() {
  local case_dir id saved meta out rc=0
  id=atomic-close-missing-data-b2
  case_dir=$(make_home close-missing-data)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-missing-data"
  meta="$(home_of "$case_dir")/state/$id.meta"
  saved="$case_dir/backlog-data"
  mv "$(home_of "$case_dir")/data" "$saved"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown succeeded with an unresolvable data directory"
  assert_contains "$out" "task $id cannot be torn down" \
    "teardown did not identify the task blocked by fatal backlog addressing"
  assert_present "$meta" "fatal backlog addressing removed the task record"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "fatal backlog addressing wrote a close marker"
  [ "$(tasks-axi show "$id" --file "$saved/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1)" = in_flight ] \
    || fail "fatal backlog addressing changed the In-flight row"
  pass "completion refuses before mutation when backlog data is unresolvable"
}

test_dispatch_refuses_an_id_this_home_has_no_item_for() {
  local case_dir id out rc=0
  id=atomic-dispatch-b2
  case_dir=$(make_home dispatch-no-item "$id")

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn dispatched work no backlog item owns"
  assert_contains "$out" "no backlog item in this home" \
    "spawn refused without naming the missing backlog item"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "refused dispatch still left a record behind"
  pass "dispatch refuses, before creating anything, when the home has no item for the id"
}

test_dispatch_reports_a_backlog_read_failure() {
  local case_dir id out rc=0
  id=atomic-dispatch-read-failure-b3
  case_dir=$(make_home dispatch-read-failure "$id")
  add_item "$case_dir" "$id"
  break_verb "$case_dir" show

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded though backlog preflight could not read its item"
  assert_contains "$out" "backlog item could not be read before dispatch" \
    "spawn misreported a backlog read failure"
  assert_contains "$out" "backlog is unwritable" \
    "spawn discarded the backlog reader's diagnostic"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "failed backlog preflight created a task record"
  pass "dispatch distinguishes backlog read failures from missing items"
}

test_dispatch_refuses_a_closed_item() {
  local case_dir id out rc=0
  id=atomic-dispatch-b3
  case_dir=$(make_home dispatch-closed "$id")
  add_item "$case_dir" "$id"
  tasks-axi "done" "$id" --file "$(backlog_of "$case_dir")" >/dev/null

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn dispatched onto an item the backlog already closed"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "refused dispatch silently reopened a closed item"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "refused dispatch onto a closed item still left a record behind"
  pass "dispatch refuses a closed item instead of silently reopening it"
}

test_dispatch_leaves_no_record_when_the_transition_fails() {
  local case_dir id out rc=0
  id=atomic-dispatch-b4
  case_dir=$(make_home dispatch-transition-fails "$id")
  add_item "$case_dir" "$id"
  break_verb "$case_dir" start

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn reported success though the backlog transition failed"
  assert_contains "$out" "could not be moved to In flight" \
    "spawn failed without explaining the backlog transition failure"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "a failed backlog transition left an orphaned record behind"
  assert_absent "$(home_of "$case_dir")/state/$id.busy-state" \
    "a failed backlog transition left the task's armed busy generation behind"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "a failed dispatch left the backlog item in $(row_state "$case_dir" "$id")"
  pass "a failed backlog transition fails the dispatch loudly and leaves no record"
}

test_dispatch_reports_an_incomplete_record_rollback() {
  local case_dir id meta out rc=0
  id=atomic-dispatch-remove-failure-b5
  case_dir=$(make_home dispatch-remove-failure "$id")
  add_item "$case_dir" "$id"
  meta="$(home_of "$case_dir")/state/$id.meta"
  break_verb "$case_dir" start
  break_meta_removal "$case_dir" "$meta"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn reported success though transition and rollback failed"
  assert_contains "$out" "failed-dispatch cleanup is incomplete" \
    "spawn did not report that its provisional record remained"
  assert_present "$meta" "failed record removal was reported as successful"
  assert_absent "$(home_of "$case_dir")/state/$id.busy-state" \
    "record-removal failure prevented busy-state rollback"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "failed rollback changed the backlog row"
  pass "dispatch reports when failed-transition rollback cannot remove its record"
}

test_dispatch_reports_an_incomplete_busy_rollback() {
  local case_dir id out rc=0
  id=atomic-dispatch-busy-remove-failure-b5
  case_dir=$(make_home dispatch-busy-remove-failure "$id")
  add_item "$case_dir" "$id"
  break_verb "$case_dir" start
  break_busy_removal "$case_dir" "$id"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn succeeded though busy rollback failed"
  assert_contains "$out" "did not remove both task and busy records" \
    "spawn did not report incomplete busy rollback"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "busy rollback failure retained the provisional task record"
  assert_present "$(home_of "$case_dir")/state/$id.busy-state" \
    "busy removal failure was reported as successful"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "failed busy rollback changed the backlog row"
  pass "dispatch verifies both task and busy records during rollback"
}

test_dispatch_rolls_back_before_a_failed_launch_delivery() {
  local case_dir id out rc=0
  id=atomic-dispatch-delivery-fails-b5
  case_dir=$(make_home dispatch-delivery-fails "$id")
  add_item "$case_dir" "$id"
  break_launch_delivery "$case_dir"

  out=$(run_ship_spawn "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn reported success though launch delivery failed"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "a failed launch delivery left its provisional record behind"
  assert_absent "$(home_of "$case_dir")/state/$id.busy-state" \
    "a failed launch delivery left its provisional busy generation behind"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "launch delivery failed after committing backlog state $(row_state "$case_dir" "$id")"
  pass "dispatch commits neither record nor backlog state before launch delivery succeeds"
}

# --- completion -------------------------------------------------------------

test_completion_closes_a_local_only_ship_before_reporting_success() {
  local case_dir id out
  id=atomic-close-b5
  case_dir=$(make_home close-local-only)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-close-local"

  out=$(run_teardown "$case_dir" "$id") || fail "teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "teardown reported success with the item still $(row_state "$case_dir" "$id")"
  assert_grep 'local main' "$(backlog_of "$case_dir")" \
    "a local-only landing was closed without its local-main note"
  pass "completion closes a local-only ship, with its landing note, before reporting success"
}

test_completion_closes_a_scout_with_its_report() {
  local case_dir id out
  id=atomic-close-b6
  case_dir=$(make_home close-scout)
  add_item "$case_dir" "$id" scout
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" scout '' "spawn_gen=spawn-close-scout"
  # A scout's deliverable is its report, and teardown also enforces the shared
  # unresolved-decision completion gate; satisfy both the way a real scout does.
  mkdir -p "$(home_of "$case_dir")/data/$id"
  printf 'findings\n' > "$(home_of "$case_dir")/data/$id/report.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-decision-hold.sh" complete "$id" --none >/dev/null \
    || fail "could not record the scout's completed decision inventory"

  out=$(run_teardown "$case_dir" "$id") || fail "teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "teardown reported success with the scout item still $(row_state "$case_dir" "$id")"
  assert_grep "data/$id/report.md" "$(backlog_of "$case_dir")" \
    "a closed scout item did not record its report"
  pass "completion closes a scout item against its report"
}

test_completion_refuses_a_legacy_record_without_an_incarnation() {
  local case_dir id meta out rc=0
  id=atomic-close-legacy-no-incarnation-b7
  case_dir=$(make_home close-legacy-no-incarnation)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only
  meta="$(home_of "$case_dir")/state/$id.meta"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown accepted a record with no durable incarnation"
  assert_contains "$out" "record has no spawn_gen" \
    "teardown did not explain why the legacy record cannot close automatically"
  assert_present "$meta" "legacy-record refusal removed the task record"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "legacy-record refusal wrote an unrecoverable close marker"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "legacy-record refusal changed the backlog row"
  pass "completion leaves legacy records open when no incarnation can be recorded"
}

test_completion_retains_a_captain_held_item() {
  local case_dir id out
  id=atomic-close-captain-b7
  case_dir=$(make_home close-captain-held)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
    --file "$(backlog_of "$case_dir")" >/dev/null
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-captain-held"

  out=$(run_teardown "$case_dir" "$id") || fail "teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "teardown closed a captain-held item instead of retaining it: $(row_state "$case_dir" "$id")"
  tasks-axi show "$id" --file "$(backlog_of "$case_dir")" --full 2>/dev/null |
    grep -F 'hold_kind: captain' >/dev/null \
    || fail "the retained item lost its captain hold"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "a retained captain call kept its finished task record"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "a landed retain left its pending-close record behind"
  assert_contains "$out" "still held for the captain" \
    "teardown did not report the retained captain call"
  pass "completion retains a captain-held item instead of closing the captain's question"
}

test_completion_preserves_records_when_meta_removal_fails() {
  local case_dir id meta marker out rc=0
  id=atomic-close-meta-remove-failure-b7
  case_dir=$(make_home close-meta-remove-failure)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-one"
  meta="$(home_of "$case_dir")/state/$id.meta"
  marker="$(home_of "$case_dir")/state/$id.backlog-close"
  break_meta_removal "$case_dir" "$meta"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown succeeded though task-record removal failed"
  assert_contains "$out" "task record could not be removed" \
    "teardown did not report task-record removal failure"
  assert_present "$meta" "teardown lost meta after its removal failed"
  assert_present "$marker" "teardown discarded recovery after meta removal failed"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "teardown closed the row before verifying meta removal"
  pass "completion preserves recovery state when task-record removal fails"
}

test_completion_fails_loudly_and_records_the_close_it_still_owes() {
  local case_dir id out rc=0
  id=atomic-close-b7
  case_dir=$(make_home close-fails)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-close-fails"
  break_verb "$case_dir" "done"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown reported success while its item was still In flight"
  assert_contains "$out" "could not be closed" \
    "teardown failed without explaining the unclosed backlog item"
  assert_present "$(home_of "$case_dir")/state/$id.backlog-close" \
    "teardown lost the close it still owes"
  pass "completion refuses to report success while its item is still open, and records what it owes"
}

test_interrupted_destructive_cleanup_leaves_a_recoverable_close() {
  local case_dir home id marker out rc=0
  id=atomic-close-destructive-interrupt-b8
  case_dir=$(make_home close-destructive-interrupt "$id")
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"
  out=$(run_ship_spawn "$case_dir" "$id") || fail "spawn failed: $out"
  marker="$home/state/$id.backlog-close"
  interrupt_teardown_during_treehouse_return "$case_dir"

  out=$(run_teardown "$case_dir" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted destructive cleanup reported success"
  assert_present "$marker" \
    "destructive cleanup began before recording its authoritative close"
  assert_present "$home/state/$id.meta" \
    "interrupted destructive cleanup lost the task incarnation"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "interrupted cleanup changed the backlog before recovery"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "restart left interrupted cleanup In flight: $out"
  assert_absent "$marker" "restart retained the recovered close marker"
  assert_absent "$home/state/$id.meta" "restart retained the interrupted task record"
  assert_contains "$out" "endpoint or local copy may remain" \
    "restart silently hid potentially incomplete physical cleanup"
  pass "restart recovers closes recorded before destructive cleanup"
}

# --- same-home recovery -----------------------------------------------------

test_recovery_marks_an_owned_record_in_flight() {
  local case_dir id out
  id=atomic-heal-b8
  case_dir=$(make_home heal-queued)
  add_item "$case_dir" "$id"
  write_task_meta "$case_dir" "$id" ship no-mistakes

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "session start left an owned record's item at $(row_state "$case_dir" "$id"): $out"
  pass "session start marks an item In flight when this home already owns a worker for it"
}

test_recovery_replays_a_close_an_interrupted_cleanup_left_open() {
  local case_dir id out
  id=atomic-heal-b9
  case_dir=$(make_home heal-pending-close)
  add_item "$case_dir" "$id"
  start_item "$case_dir" "$id"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-heal-pr\narg=--pr\narg=https://github.com/example/repo/pull/11\n' \
    "$id" "$(home_of "$case_dir")/data" \
    > "$(home_of "$case_dir")/state/$id.backlog-close"

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "session start left an interrupted cleanup's item at $(row_state "$case_dir" "$id"): $out"
  assert_grep 'https://github.com/example/repo/pull/11' "$(backlog_of "$case_dir")" \
    "the replayed close dropped the completion link the cleanup had recorded"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "a replayed close left its record behind"
  assert_not_contains "$out" "endpoint or local copy may remain" \
    "recovery claimed incomplete cleanup without task metadata"
  pass "session start finishes a close an interrupted cleanup recorded but never landed"
}

test_recovery_leaves_a_captain_held_item_alone() {
  local case_dir id out
  id=atomic-heal-b11
  case_dir=$(make_home heal-held)
  add_item "$case_dir" "$id"
  tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
    --file "$(backlog_of "$case_dir")" >/dev/null
  write_task_meta "$case_dir" "$id" ship no-mistakes

  out=$(run_bootstrap "$case_dir")
  [ "$(row_state "$case_dir" "$id")" = queued ] \
    || fail "session start moved a captain-held item to $(row_state "$case_dir" "$id"): $out"
  pass "session start leaves a captain-held item where the captain put it"
}

# --- home-addressed wrapper --------------------------------------------------

test_fm_tasks_axi_addresses_the_home_from_any_directory() {
  local case_dir home id out
  id=atomic-wrapper-b1
  case_dir=$(make_home wrapper-cwd "$id")
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"

  # From the code root - the exact cwd that used to fork the queue - the
  # wrapper must still read and write the home's own backlog.
  out=$(cd "$ROOT" && FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show "$id" 2>&1) \
    || fail "wrapper could not read the home backlog from the code root: $out"
  assert_contains "$out" "$id" "wrapper show did not return the home's row"
  out=$(cd "$ROOT" && FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" start "$id" 2>&1) \
    || fail "wrapper could not write the home backlog from the code root: $out"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "wrapper wrote a different backlog than the home's"
  [ ! -e "$ROOT/data/backlog.md" ] \
    || fail "wrapper wrote the code root's data directory"
  pass "bin/fm-tasks-axi.sh addresses the home's backlog from any directory"
}

test_fm_tasks_axi_refuses_a_caller_file_override() {
  local case_dir home id out rc=0
  id=atomic-wrapper-b2
  case_dir=$(make_home wrapper-file "$id")
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show "$id" --file /tmp/other.md 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "wrapper accepted a caller --file that would divert the backlog"
  assert_contains "$out" "drop --file" \
    "wrapper did not explain the refused --file"
  pass "bin/fm-tasks-axi.sh refuses a caller --file override"
}

# --- backend selection and secondmate scope ---------------------------------

test_home_without_a_backlog_dispatches_and_completes() {
  local case_dir id out
  id=atomic-no-backlog-b12
  case_dir=$(make_home no-backlog "$id")
  rm -f "$(backlog_of "$case_dir")"
  cat > "$(home_of "$case_dir")/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  make_tasks_axi_incompatible "$case_dir"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "no-backlog spawn failed: $out"
  assert_present "$(home_of "$case_dir")/state/$id.meta" \
    "no-backlog spawn did not publish its task record"
  out=$(run_teardown "$case_dir" "$id") || fail "no-backlog teardown failed: $out"
  assert_absent "$(home_of "$case_dir")/state/$id.meta" \
    "no-backlog teardown retained its task record"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "no-backlog teardown recorded a close marker"
  pass "a home with no backlog remains exempt from lifecycle transitions"
}

test_dispatch_and_completion_are_structural() {
  local case_dir home id meta out pr
  id=fm-structural-b15
  pr=https://github.com/example/firstmate/pull/15
  case_dir=$(make_home structural "$id")
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"

  out=$(run_ship_spawn "$case_dir" "$id") \
    || fail "structural spawn failed: $out"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "spawn left the backlog item outside In flight"

  # Recovery may claim an already-live row repeatedly; the transition remains
  # idempotent and does not reopen or duplicate the item.
  run_bootstrap "$case_dir" >/dev/null \
    || fail "first idempotent reconciliation failed"
  run_bootstrap "$case_dir" >/dev/null \
    || fail "second idempotent reconciliation failed"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "repeated claims changed the live backlog state"

  meta="$home/state/$id.meta"
  printf 'pr=%s\n' "$pr" >> "$meta"
  out=$(run_teardown "$case_dir" "$id") \
    || fail "structural teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "teardown left the backlog item outside Done"
  assert_grep "$pr" "$(backlog_of "$case_dir")" \
    "teardown closed the item without its recorded PR evidence"
  pass "dispatch and completion transition structurally with evidence"
}

test_refused_teardown_leaves_the_item_live() {
  local case_dir home id out rc=0
  id=fm-structural-refusal-b15
  case_dir=$(make_home structural-refusal "$id")
  home=$(home_of "$case_dir")
  add_item "$case_dir" "$id"
  out=$(run_ship_spawn "$case_dir" "$id") \
    || fail "refusal setup spawn failed: $out"

  printf '%s\n' unlanded > "$case_dir/wt/unlanded.txt"
  git -C "$case_dir/wt" add unlanded.txt
  git -C "$case_dir/wt" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q -m "unlanded fixture work"
  out=$(run_teardown "$case_dir" "$id") || rc=$?

  [ "$rc" -ne 0 ] || fail "teardown accepted unlanded work"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "refused teardown changed the live backlog state"
  assert_present "$home/state/$id.meta" \
    "refused teardown removed the live task record"
  pass "refused teardown leaves the backlog item in flight"
}

test_manual_backend_home_dispatches_and_completes_without_touching_the_backlog() {
  local case_dir id data data_resolved out
  id=atomic-manual-b12
  case_dir=$(make_home manual-backend "$id")
  printf '%s\n' manual > "$(home_of "$case_dir")/config/backlog-backend"
  pin_markdown_backend "$case_dir"
  data="$case_dir/manual-data"
  mv "$(home_of "$case_dir")/data" "$data"
  data_resolved=$(cd "$data" && pwd -P)
  make_tasks_axi_incompatible "$case_dir"
  # Deliberately no backlog item: on a manual home the operator owns the file,
  # so neither half of the lifecycle may hard-fail over its contents.
  out=$(FM_DATA_OVERRIDE="$data" run_ship_spawn "$case_dir" "$id") \
    || fail "manual-backend spawn failed: $out"
  assert_contains "$out" "spawned $id" "manual-backend spawn did not report success"

  out=$(FM_DATA_OVERRIDE="$data" run_teardown "$case_dir" "$id") \
    || fail "manual-backend teardown failed: $out"
  assert_contains "$out" "Update $data_resolved/backlog.md" \
    "manual-backend teardown did not name its configured backlog path"
  assert_absent "$(home_of "$case_dir")/state/$id.backlog-close" \
    "manual-backend teardown recorded a close it never owed"
  pass "a manual-backlog home dispatches and completes without a hard failure"
}

test_a_secondmate_home_keeps_its_own_books() {
  local case_dir id out
  id=atomic-mate-b13
  case_dir=$(make_home mate-own-books "$id")
  # The mate's home is a firstmate home in its own right; the invariant is
  # single-host, so its own dispatch and completion keep its own two records
  # paired with no parent involved.
  printf '%s\n' mate-h1 > "$(home_of "$case_dir")/.fm-secondmate-home"
  add_item "$case_dir" "$id"

  out=$(run_ship_spawn "$case_dir" "$id") || fail "mate-home spawn failed: $out"
  [ "$(row_state "$case_dir" "$id")" = in_flight ] \
    || fail "a mate's own dispatch left its item at $(row_state "$case_dir" "$id")"

  rm -f "$(home_of "$case_dir")/state/$id.meta"
  write_task_meta "$case_dir" "$id" ship local-only "spawn_gen=spawn-mate-close"
  out=$(run_teardown "$case_dir" "$id") || fail "mate-home teardown failed: $out"
  [ "$(row_state "$case_dir" "$id")" = "done" ] \
    || fail "a mate's own completion left its item at $(row_state "$case_dir" "$id")"
  pass "a secondmate home keeps its own books paired through dispatch and completion"
}

test_a_persistent_secondmate_is_never_a_backlog_item() {
  local case_dir id out mate
  id=atomic-mate-b14
  case_dir=$(make_home mate-not-an-item)
  mate="$case_dir/mate-home"
  mkdir -p "$mate/bin" "$mate/data"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$mate/data/charter.md"

  # No backlog item exists for the mate, and none should be required: agents are
  # not work items. The dispatch must succeed anyway.
  out=$(run_spawn "$case_dir" "$id" "$mate" --secondmate) \
    || fail "secondmate spawn failed: $out"
  assert_contains "$out" "spawned $id" "secondmate spawn did not report success"
  assert_present "$(home_of "$case_dir")/state/$id.meta" "secondmate spawn published no record"
  pass "dispatching a persistent secondmate needs no backlog item"
}

# --- runner -----------------------------------------------------------------

test_dispatch_moves_the_item_in_flight_in_the_same_run
test_dispatch_refuses_a_pending_authoritative_close
test_dispatch_refuses_a_held_row_before_creating_resources
test_dispatch_refuses_a_blocked_row_before_creating_resources
test_dispatch_reads_the_row_from_the_backlog_root
test_automatic_backend_refuses_incompatible_tasks_axi_before_mutation
test_dispatch_refuses_an_unresolvable_data_directory
test_completion_refuses_an_unresolvable_data_directory
test_dispatch_refuses_an_id_this_home_has_no_item_for
test_dispatch_reports_a_backlog_read_failure
test_dispatch_refuses_a_closed_item
test_dispatch_leaves_no_record_when_the_transition_fails
test_dispatch_reports_an_incomplete_record_rollback
test_dispatch_reports_an_incomplete_busy_rollback
test_dispatch_rolls_back_before_a_failed_launch_delivery
test_completion_closes_a_local_only_ship_before_reporting_success
test_completion_closes_a_scout_with_its_report
test_completion_refuses_a_legacy_record_without_an_incarnation
test_completion_retains_a_captain_held_item
test_completion_preserves_records_when_meta_removal_fails
test_completion_fails_loudly_and_records_the_close_it_still_owes
test_interrupted_destructive_cleanup_leaves_a_recoverable_close
test_recovery_marks_an_owned_record_in_flight
test_recovery_replays_a_close_an_interrupted_cleanup_left_open
test_recovery_leaves_a_captain_held_item_alone
test_fm_tasks_axi_addresses_the_home_from_any_directory
test_fm_tasks_axi_refuses_a_caller_file_override
test_home_without_a_backlog_dispatches_and_completes
test_dispatch_and_completion_are_structural
test_refused_teardown_leaves_the_item_live
test_manual_backend_home_dispatches_and_completes_without_touching_the_backlog
test_a_secondmate_home_keeps_its_own_books
test_a_persistent_secondmate_is_never_a_backlog_item

printf 'ok - fm-backlog-atomicity: all cases passed\n'
