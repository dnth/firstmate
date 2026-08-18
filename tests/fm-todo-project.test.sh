#!/usr/bin/env bash
# Behavior tests for bin/fm-todo-project.sh - the board-to-todo projection and
# the board-vs-reality drift check.
#
# The board is the single source of truth and the session todo is a projection
# of it, so both modes are pinned end to end over a hermetic FM_HOME with its own
# board fixtures and a fake `tasks-axi` that serves the real tool's listing
# format verbatim (header line naming the columns, then quoted-CSV rows):
#   (a) --emit projects in-flight work as "Active" and dispatchable queued work
#       as "Ready", as valid todo-init JSON
#   (b) --emit on an empty board is exactly []
#   (c) --check flags an in-flight task whose worker is gone
#   (d) --check flags a held task whose hold_until deadline has passed
#   (e) --check is silent when the board matches reality (live worker, unexpired
#       hold), so it composes into the digest and a heartbeat without noise
#   (f) FM_HOME is required fail-closed, like bin/fm-send.sh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/bin/fm-todo-project.sh"
TMP_ROOT=$(fm_test_tmproot fm-todo-project)
fm_git_identity fmtest fmtest@example.invalid

# A hermetic home whose board listings are served from fixture files. The fake
# tasks-axi answers only the surface this script uses - the compatibility probes,
# `list --state <s> [--fields ...]`, and `ready` - and refuses anything else, so
# a regression that reaches past that surface fails loudly instead of silently
# reading the live fleet's board.
new_home() {  # <name> -> echoes home dir
  local name=$1 home fakebin
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/listings"
  : > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
listings=${FM_FAKE_LISTINGS:?fake tasks-axi needs FM_FAKE_LISTINGS}
serve() {
  if [ -f "$listings/$1" ]; then cat "$listings/$1"; else
    printf 'count: 0\n'
    printf 'tasks: 0 tasks in this backlog\n'
  fi
  printf 'help[1]:\n'
  printf '%s\n' '  - Run `tasks-axi show <id>` for full notes on a task'
  exit 0
}
require_file() {
  case "$*" in *'--file '*) return 0 ;; esac
  printf '%s\n' 'fake tasks-axi: every read must name an explicit --file board' >&2
  exit 9
}
case "${1:-}" in
  --version|-v|-V) printf '%s\n' "${FM_FAKE_TASKS_AXI_VERSION:-0.2.4}"; exit 0 ;;
  update) [ "${2:-}" = --help ] && { printf '%s\n' 'usage: tasks-axi update <id> [--archive-body]'; exit 0; } ;;
  mv) [ "${2:-}" = --help ] && { printf '%s\n' 'usage: tasks-axi mv <dest> [<id>...]'; exit 0; } ;;
  ready)
    require_file "$@"
    serve ready
    ;;
  list)
    require_file "$@"
    case "$*" in
      *'--state in_flight'*) serve in_flight ;;
      *'--state queued'*) serve queued ;;
      *) printf '%s\n' "fake tasks-axi: unexpected listing: $*" >&2; exit 9 ;;
    esac
    ;;
esac
printf '%s\n' "fake tasks-axi: unexpected invocation: $*" >&2
exit 9
SH
  chmod +x "$fakebin/tasks-axi"
  # fm-crew-state.sh reads a no-mistakes run and, failing that, the pane. No
  # fixture here advertises a run, so every case falls through to the pane.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux"
  printf '%s\n' "$home"
}

# One tasks-axi listing fixture, in the tool's own rendering.
write_listing() {  # <home> <name> <header-fields> <row>...
  local home=$1 name=$2 fields=$3 count
  shift 3
  count=$#
  {
    printf 'count: %s\n' "$count"
    if [ "$count" -gt 0 ]; then
      if [ "$name" = ready ]; then
        printf 'ready[%s]{%s}:\n' "$count" "$fields"
      else
        printf 'tasks[%s]{%s}:\n' "$count" "$fields"
      fi
      printf '  %s\n' "$@"
    else
      printf 'tasks: 0 tasks in this backlog\n'
    fi
  } > "$home/listings/$name"
}

run_project() {  # <home> <mode>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_FAKE_LISTINGS="$1/listings" "$PROJECT" "$2"
}

# --- (a) --emit projects Active and Ready from the board ---------------------

home=$(new_home emit-phases)
write_listing "$home" in_flight 'id,state,kind,repo,title' \
  'alpha-one,in_flight,ship,firstmate,"First task, with a comma"'
write_listing "$home" ready 'id,state,kind,repo,title' \
  'beta-two,queued,ship,firstmate,Second task' \
  'gamma-three,queued,scout,"-",Third task'
out=$(run_project "$home" --emit) || fail "--emit exited non-zero"

printf '%s' "$out" > "$home/emit.json"
node -e '
  const list = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  const phases = list.map((p) => p.phase).join(",");
  if (phases !== "Active,Ready") throw new Error("phases: " + phases);
  if (list[0].items.length !== 1) throw new Error("Active items: " + list[0].items.length);
  if (list[0].items[0] !== "alpha-one - First task, with a comma") {
    throw new Error("Active item text: " + list[0].items[0]);
  }
  if (list[1].items.join("|") !== "beta-two - Second task|gamma-three - Third task") {
    throw new Error("Ready items: " + list[1].items.join("|"));
  }
' "$home/emit.json" || fail "--emit did not project the board as todo-init JSON"
pass "--emit projects in-flight work as Active and dispatchable queued work as Ready"

# --- (b) --emit on an empty board is exactly [] ------------------------------

home=$(new_home emit-empty)
out=$(run_project "$home" --emit) || fail "--emit exited non-zero on an empty board"
[ "$out" = '[]' ] || fail "empty board did not emit []: $out"
pass "--emit on an empty board emits []"

# --- (c) --check flags an in-flight task with no worker ----------------------

home=$(new_home check-no-worker)
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until' \
  'ghost-task,in_flight,ship,firstmate,Ship something,"-"'
out=$(run_project "$home" --check) || fail "--check exited non-zero"
assert_contains "$out" "DRIFT inflight-no-worker: ghost-task" \
  "--check did not flag an in-flight task whose worker is gone"
assert_not_contains "$out" "DRIFT hold-expired" "--check invented a hold finding"
pass "--check flags an in-flight task whose worker is absent"

# --- (d) --check flags a hold whose deadline has passed ----------------------

home=$(new_home check-hold-expired)
write_listing "$home" queued 'id,state,kind,repo,title,hold_until' \
  'lapsed-hold,queued,ship,firstmate,Waited on something,2020-01-01' \
  'future-hold,queued,ship,firstmate,Waits on something else,2099-01-01' \
  'no-hold,queued,ship,firstmate,Never held,"-"'
out=$(run_project "$home" --check) || fail "--check exited non-zero"
assert_contains "$out" "DRIFT hold-expired: lapsed-hold - hold_until 2020-01-01 passed" \
  "--check did not flag a hold whose deadline has passed"
assert_not_contains "$out" "future-hold" "--check flagged a hold that has not lapsed"
assert_not_contains "$out" "no-hold" "--check flagged a task carrying no hold date"
pass "--check flags a held task past its hold_until date"

# --- (e) --check is silent when the board matches reality --------------------

home=$(new_home check-clean)
fm_git_worktree "$home/repo" "$home/wt" fm/live-task
fm_write_meta "$home/state/live-task.meta" \
  'window=firstmate:fm-live-task' \
  'endpoint_task_id=live-task' \
  "worktree=$home/wt" \
  "project=$home/repo" \
  'harness=claude' \
  'backend=tmux' \
  'kind=ship' \
  'mode=no-mistakes' \
  'yolo=off'
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until' \
  'live-task,in_flight,ship,firstmate,Work under way,"-"'
write_listing "$home" queued 'id,state,kind,repo,title,hold_until' \
  'future-hold,queued,ship,firstmate,Waits on something,2099-01-01'

verdict=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-crew-state.sh" live-task)
assert_contains "$verdict" "source: pane" \
  "fixture is vacuous: the live worker must resolve through its recorded endpoint"

out=$(run_project "$home" --check) || fail "--check exited non-zero on a clean board"
[ -z "$out" ] || fail "--check was not silent on a clean board: $out"

# Same board, same metadata, endpoint gone: the silence above must come from the
# live endpoint, not from a check that can no longer flag anything.
out=$(FM_FAKE_TMUX_MISSING=1 run_project "$home" --check) || fail "--check exited non-zero"
assert_contains "$out" "DRIFT inflight-no-worker: live-task" \
  "--check stayed silent after the same task's endpoint disappeared"
pass "--check prints nothing when the board matches reality, and flags the same task once its endpoint is gone"

# --- (f) FM_HOME is required fail-closed ------------------------------------

home=$(new_home no-home)
set +e
out=$(env -u FM_HOME PATH="$home/fakebin:$PATH" FM_FAKE_LISTINGS="$home/listings" \
  "$PROJECT" --emit 2>&1)
rc=$?
set -e
expect_code 1 "$rc" "--emit without FM_HOME"
assert_contains "$out" "FM_HOME is not set" "--emit did not refuse an unset FM_HOME"
assert_not_contains "$out" "[]" "--emit printed a projection despite refusing"
pass "FM_HOME is required fail-closed"
