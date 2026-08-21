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
#   (g) incompatible successful listings fail closed in both modes
#   (h) title truncation never clips the durable ID or separator
#   (i) TOON escapes decode strictly without breaking item or JSON framing
#   (j) truncation is codepoint-safe under a byte-oriented caller locale
#   (k) --check reports secondmate-scoped main-board rows with no local worker
#   (l) --check reports queued rows that already have a local worker
#   (m) --check arms a missed PR watch and auto-closes only an exactly merged PR
#   (n) lifecycle reconciliation requires explicit mutation authority
#   (o) merged closure failures do not retry after metadata teardown
#   (p) each open task's canonical worker verdict is probed only once
#   (q) listing fields match the installed tasks-axi contract
#   (r) skipped arming accepts only exact PR-ready status events
#   (s) GitHub and GitLab primary merge paths each close once
#   (t) direct forge polls are bounded and timeout stays non-merged
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT="$ROOT/bin/fm-todo-project.sh"
TMP_ROOT=$(fm_test_tmproot fm-todo-project)
fm_git_identity fmtest fmtest@example.invalid

# A hermetic home whose board listings are served from fixture files. The fake
# tasks-axi answers only the surface this script uses - the compatibility probes,
# `list --state <s> [--fields ...]`, `ready`, and the exact done lifecycle edge -
# and refuses anything else, so a regression that reaches past that surface
# fails loudly instead of silently reading the live fleet's board.
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
    if [ "$1" = ready ]; then
      printf 'ready: 0 unblocked queued tasks\n'
      printf 'ready_public_followups: 0 delivery-ready obligations\n'
    else
      printf 'tasks: 0 tasks in this backlog\n'
    fi
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
      *'--fields '*repo*|*'--fields '*links*)
        printf '%s\n' 'fake tasks-axi: unsupported reconciliation field request' >&2
        exit 9
        ;;
    esac
    case "$*" in
      *'--state in_flight'*) serve in_flight ;;
      *'--state queued'*) serve queued ;;
      *'--state done'*) serve done ;;
      *) printf '%s\n' "fake tasks-axi: unexpected listing: $*" >&2; exit 9 ;;
    esac
    ;;
  done)
    require_file "$@"
    id=${2:-}
    [ -z "${FM_FAKE_DONE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_DONE_LOG"
    [ -z "${FM_FAKE_LIFECYCLE_LOG:-}" ] || printf 'done %s\n' "$id" >> "$FM_FAKE_LIFECYCLE_LOG"
    [ "${FM_FAKE_DONE_RC:-0}" -eq 0 ] || exit "${FM_FAKE_DONE_RC}"
    exit 0
    ;;
esac
printf '%s\n' "fake tasks-axi: unexpected invocation: $*" >&2
exit 9
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  'axi status') printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
  'runs --limit 200') printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
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
      if [ "$name" = ready ]; then
        printf 'ready: 0 unblocked queued tasks\n'
        printf 'ready_public_followups: 0 delivery-ready obligations\n'
      else
        printf 'tasks: 0 tasks in this backlog\n'
      fi
    fi
  } > "$home/listings/$name"
}

run_project() {  # <home> <arguments>...
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_LISTINGS="$home/listings" \
    "$PROJECT" "$@"
}

# Copy the real reconciler and its sourced libraries into a private executable
# root whose lifecycle edges are observable fakes. The behavior under test still
# runs through the real fm-todo-project.sh executable; only the external guarded
# teardown and PR-watch commands are replaced.
make_lifecycle_project() {  # <home> -> echoes executable path
  local home=$1 root="$1/todo-root"
  mkdir -p "$root/bin"
  cp "$ROOT/bin/fm-todo-project.sh" "$ROOT/bin/fm-tasks-axi-lib.sh" \
    "$ROOT/bin/fm-pr-lib.sh" "$ROOT/bin/fm-secondmate-registry-lib.sh" \
    "$ROOT/bin/fm-pr-poll.sh" "$root/bin/"
  cat > "$root/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_CREW_LOG:-}" ] || printf '%s\n' "$1" >> "$FM_FAKE_CREW_LOG"
printf '%s\n' "${FM_FAKE_CREW_VERDICT:-state: working · source: pane · harness busy}"
SH
  cat > "$root/bin/fm-pr-check.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_PR_CHECK_LOG:?}"
meta="${FM_STATE_OVERRIDE:?}/$1.meta"
tmp="$meta.tmp"
grep -v '^pr=' "$meta" > "$tmp" || true
printf 'pr=%s\n' "$2" >> "$tmp"
mv "$tmp" "$meta"
SH
  cat > "$root/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TEARDOWN_LOG:?}"
[ -z "${FM_FAKE_LIFECYCLE_LOG:-}" ] || printf 'teardown %s\n' "$1" >> "$FM_FAKE_LIFECYCLE_LOG"
[ "${FM_FAKE_TEARDOWN_REFUSE:-0}" -eq 0 ] || exit 1
rm -f "${FM_STATE_OVERRIDE:?}/$1.meta" "${FM_STATE_OVERRIDE:?}/$1.status"
SH
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_GH_SLEEP:-}" ] || sleep "$FM_FAKE_GH_SLEEP"
case " $* " in
  *' --json state -q .state '*) printf '%s\n' "${FM_FAKE_GH_STATE:-OPEN}" ;;
  *) exit 1 ;;
esac
SH
  cat > "$home/fakebin/glab" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_GLAB_SLEEP:-}" ] || sleep "$FM_FAKE_GLAB_SLEEP"
case " $* " in
  *' mr view '*' -R '*) printf 'state: %s\n' "${FM_FAKE_GLAB_STATE:-opened}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$root/bin/"*.sh
  chmod +x "$home/fakebin/gh" "$home/fakebin/glab"
  printf '%s\n' "$root/bin/fm-todo-project.sh"
}

run_lifecycle_project() {  # <home> <executable> <arguments>...
  local home=$1 executable=$2
  shift 2
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_FAKE_LISTINGS="$home/listings" \
    "$executable" "$@"
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

home=$(new_home emit-escapes)
write_listing "$home" in_flight 'id,state,kind,repo,title' \
  'escape-task,in_flight,ship,firstmate,"A\"B\/C\\D\nE\rF\tG\bH\fI\u263A"'
out=$(run_project "$home" --emit) || fail "--emit rejected valid TOON escapes"
printf '%s' "$out" > "$home/escapes.json"
node -e '
  const list = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  const expected = "escape-task - A\"B/C\\D E F G\bH\fI☺";
  if (list[0].items[0] !== expected) {
    throw new Error("escaped title: " + JSON.stringify(list[0].items[0]));
  }
' "$home/escapes.json" || fail "--emit did not decode and safely project valid TOON escapes"
pass "--emit strictly decodes valid TOON escapes into single-line JSON"

home=$(new_home emit-nul)
write_listing "$home" in_flight 'id,state,kind,repo,title' \
  'nul-task,in_flight,ship,firstmate,"A\u0000B"'
out=$(run_project "$home" --emit) || fail "--emit rejected a valid TOON NUL escape"
printf '%s' "$out" > "$home/nul.json"
node -e '
  const text = require("node:fs").readFileSync(process.argv[1], "utf8");
  if (!text.includes("\\u0000")) throw new Error("JSON did not preserve NUL as an escape");
  const list = JSON.parse(text);
  if (list[0].items[0] !== "nul-task - A\u0000B") {
    throw new Error("NUL title: " + JSON.stringify(list[0].items[0]));
  }
' "$home/nul.json" || fail "--emit did not preserve a decoded NUL in valid JSON"
pass "--emit preserves a valid TOON NUL escape as JSON Unicode"

# --- (b) --emit on an empty board is exactly [] ------------------------------

home=$(new_home emit-empty)
out=$(run_project "$home" --emit) || fail "--emit exited non-zero on an empty board"
[ "$out" = '[]' ] || fail "empty board did not emit []: $out"
pass "--emit on an empty board emits []"

# A configured cap smaller than the durable identity is raised just enough to
# keep that identity and truncate only the title.
home=$(new_home emit-tiny-cap)
write_listing "$home" in_flight 'id,state,kind,repo,title' \
  'very-long-durable-task-id,in_flight,ship,firstmate,A title that will not fit'
out=$(FM_TODO_ITEM_MAX=1 run_project "$home" --emit) || fail "--emit exited non-zero with a tiny item cap"
printf '%s' "$out" > "$home/tiny-cap.json"
node -e '
  const list = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (list[0].items[0] !== "very-long-durable-task-id - …") {
    throw new Error("identity was clipped: " + list[0].items[0]);
  }
' "$home/tiny-cap.json" || fail "a tiny item cap clipped the durable task identity"
pass "--emit truncates only titles and preserves a long durable ID"

home=$(new_home emit-byte-locale)
write_listing "$home" in_flight 'id,state,kind,repo,title' \
  'utf8-task,in_flight,ship,firstmate,ééé'
out=$(LC_ALL=C FM_TODO_ITEM_MAX=14 run_project "$home" --emit) \
  || fail "--emit exited non-zero while truncating UTF-8 under LC_ALL=C"
printf '%s' "$out" > "$home/byte-locale.json"
node -e '
  const list = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (list[0].items[0] !== "utf8-task - é…") {
    throw new Error("UTF-8 title: " + JSON.stringify(list[0].items[0]));
  }
' "$home/byte-locale.json" || fail "--emit split a UTF-8 codepoint under LC_ALL=C"
pass "--emit truncates UTF-8 by codepoint independently of caller locale"

# --- (c) --check flags an in-flight task with no worker ----------------------

home=$(new_home check-no-worker)
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until' \
  'ghost-task,in_flight,ship,firstmate,Ship something,"-"'
out=$(run_project "$home" --check) || fail "--check exited non-zero"
assert_contains "$out" "DRIFT inflight-no-worker: ghost-task" \
  "--check did not flag an in-flight task whose worker is gone"
assert_not_contains "$out" "DRIFT hold-expired" "--check invented a hold finding"
pass "--check flags an in-flight task whose worker is absent"

# Missing worker resources are reported through fm-crew-state.sh's canonical
# current-state verdict and reason.
home=$(new_home check-missing-resources)
mkdir -p "$home/live-worktree"
fm_write_meta "$home/state/no-worktree.meta" \
  'window=firstmate:fm-no-worktree' \
  'kind=ship'
fm_write_meta "$home/state/gone-worktree.meta" \
  'window=firstmate:fm-gone-worktree' \
  "worktree=$home/does-not-exist" \
  'kind=ship'
fm_write_meta "$home/state/no-window.meta" \
  "worktree=$home/live-worktree" \
  'kind=ship'
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until' \
  'no-meta,in_flight,ship,firstmate,Missing metadata,"-"' \
  'no-worktree,in_flight,ship,firstmate,Missing worktree field,"-"' \
  'gone-worktree,in_flight,ship,firstmate,Torn down worktree,"-"' \
  'no-window,in_flight,ship,firstmate,Missing window field,"-"'
out=$(run_project "$home" --check) || fail "--check exited non-zero"
assert_contains "$out" "DRIFT inflight-no-worker: no-meta - no metadata for no-meta" \
  "--check did not relay the missing-metadata verdict"
assert_contains "$out" "DRIFT inflight-no-worker: no-worktree - worktree gone" \
  "--check did not relay the missing-worktree verdict"
assert_contains "$out" "DRIFT inflight-no-worker: gone-worktree - worktree gone" \
  "--check did not relay the torn-down-worktree verdict"
assert_contains "$out" "DRIFT inflight-no-worker: no-window - no backend target recorded" \
  "--check did not relay the missing-target verdict"
pass "--check reports missing workers through crew-state verdicts"

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

# A matching run is authoritative even after the endpoint dies, so the drift
# check must accept fm-crew-state.sh's worker verdict instead of re-probing it.
head=$(git -C "$home/wt" rev-parse HEAD)
run=$(cat <<EOF
run:
  id: "01RUN"
  branch: fm/live-task
  status: running
  head: "$head"
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
)
verdict=$(FM_FAKE_AXI_STATUS="$run" FM_FAKE_TMUX_MISSING=1 PATH="$home/fakebin:$PATH" \
  FM_HOME="$home" "$ROOT/bin/fm-crew-state.sh" live-task)
assert_contains "$verdict" "source: run-step" \
  "fixture is vacuous: a matching run must survive the dead endpoint"
out=$(FM_FAKE_AXI_STATUS="$run" FM_FAKE_TMUX_MISSING=1 run_project "$home" --check) \
  || fail "--check exited non-zero for a dead endpoint with an attributed run"
[ -z "$out" ] || fail "--check disagreed with the authoritative run-step verdict: $out"
pass "--check accepts a run-step-backed worker after its endpoint closes"

home=$(new_home check-real-cli-fields)
out=$(FM_HOME="$home" "$PROJECT" --check) \
  || fail "--check failed against the installed tasks-axi list interface"
[ -z "$out" ] || fail "the installed tasks-axi interface produced drift on an empty board: $out"
pass "--check requests only supported extra fields from the real tasks-axi CLI"

# --- (f) --check reports main-board work owned by a secondmate --------------

home=$(new_home check-secondmate-scope)
lifecycle_project=$(make_lifecycle_project "$home")
: > "$home/crew.log"
printf -- '- design - Design domain (home: %s; scope: owns design work; projects: alpha; added 2026-08-21)\n' \
  "$home/secondmate-home" > "$home/data/secondmates.md"
write_listing "$home" queued 'id,state,kind,repo,title,hold_until' \
  'misplaced-domain-task,queued,ship,alpha,Migrate this item,"-"'
out=$(FM_FAKE_CREW_VERDICT='state: unknown · source: none · no metadata for misplaced-domain-task' \
  FM_FAKE_CREW_LOG="$home/crew.log" run_lifecycle_project "$home" "$lifecycle_project" --check) \
  || fail "--check exited non-zero for secondmate-scoped work"
assert_contains "$out" \
  "DRIFT secondmate-scope-on-main: misplaced-domain-task - repo alpha is registered to secondmate design and has no local worker" \
  "--check did not flag a secondmate-scoped main-board task with no local worker"
assert_not_contains "$out" "DRIFT queued-has-worker" \
  "--check invented a live worker for the secondmate-scoped queued task"
[ "$(wc -l < "$home/crew.log" | tr -d ' ')" -eq 1 ] \
  || fail "one queued secondmate-scoped row was probed more than once: $(cat "$home/crew.log")"

fm_git_worktree "$home/repo" "$home/wt" fm/misplaced-domain-task
fm_write_meta "$home/state/misplaced-domain-task.meta" \
  'window=firstmate:fm-misplaced-domain-task' \
  'endpoint_task_id=misplaced-domain-task' \
  "worktree=$home/wt" \
  "project=$home/repo" \
  'harness=claude' \
  'backend=tmux' \
  'kind=ship' \
  'mode=no-mistakes' \
  'yolo=off'
write_listing "$home" queued 'id,state,kind,repo,title,hold_until'
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until' \
  'misplaced-domain-task,in_flight,ship,alpha,Locally owned exception,"-"'
out=$(run_project "$home" --check) || fail "--check exited non-zero for a live local worker"
assert_not_contains "$out" "DRIFT secondmate-scope-on-main" \
  "--check flagged a secondmate-scoped row that has a live local worker"
pass "--check reports secondmate-scoped drift from one canonical worker probe"

# --- (g) --check reports queued work that already has a local worker --------

home=$(new_home check-queued-worker)
fm_git_worktree "$home/repo" "$home/wt" fm/queued-live
fm_write_meta "$home/state/queued-live.meta" \
  'window=firstmate:fm-queued-live' \
  'endpoint_task_id=queued-live' \
  "worktree=$home/wt" \
  "project=$home/repo" \
  'harness=claude' \
  'backend=tmux' \
  'kind=ship' \
  'mode=no-mistakes' \
  'yolo=off'
write_listing "$home" queued 'id,state,kind,repo,title,hold_until' \
  'queued-live,queued,ship,firstmate,Already dispatched,"-"'
out=$(run_project "$home" --check) || fail "--check exited non-zero for queued work with a worker"
assert_contains "$out" \
  "DRIFT queued-has-worker: queued-live - board says queued but a local worker has a current-state source" \
  "--check did not flag a queued item that already has a local worker"

rm -f "$home/state/queued-live.meta"
out=$(run_project "$home" --check) || fail "--check exited non-zero for an ordinary queued item"
assert_not_contains "$out" "DRIFT queued-has-worker" \
  "--check flagged an ordinary queued item with no worker"
pass "--check reports only queued items that already have a local worker"

# --- (h) --check arms PR watches and auto-closes exact merged PRs -----------

home=$(new_home check-pr-lifecycle)
lifecycle_project=$(make_lifecycle_project "$home")
: > "$home/pr-check.log"
: > "$home/teardown.log"
: > "$home/done.log"
: > "$home/lifecycle.log"
fm_write_meta "$home/state/pr-task.meta" \
  'window=firstmate:fm-pr-task' \
  "worktree=$home/wt" \
  'project=firstmate' \
  'kind=ship' \
  'mode=no-mistakes'
printf '%s\n' \
  'working: dependency review at https://github.com/example/repo/pull/40' \
  'done: PR https://github.com/example/repo/pull/41 checks green' \
  > "$home/state/pr-task.status"
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until' \
  'pr-task,in_flight,ship,firstmate,Ready pull request,"-"'
out=$(FM_FAKE_GH_STATE=OPEN FM_FAKE_PR_CHECK_LOG="$home/pr-check.log" \
  FM_FAKE_TEARDOWN_LOG="$home/teardown.log" FM_FAKE_DONE_LOG="$home/done.log" \
  FM_FAKE_LIFECYCLE_LOG="$home/lifecycle.log" \
  run_lifecycle_project "$home" "$lifecycle_project" --check) \
  || fail "report-only --check exited non-zero for a missed PR watch"
assert_contains "$out" \
  "DRIFT-CHECK-SKIPPED: merge watch for pr-task requires verified mutation authority" \
  "report-only --check did not surface the skipped PR-watch repair"
[ ! -s "$home/pr-check.log" ] || fail "report-only --check armed a PR watch"
[ ! -s "$home/teardown.log" ] || fail "report-only --check invoked teardown"
[ ! -s "$home/done.log" ] || fail "report-only --check closed a board item"
assert_not_contains "$(cat "$home/state/pr-task.meta")" 'pr=' \
  "report-only --check changed canonical PR metadata"
out=$(FM_FAKE_GH_STATE=OPEN FM_FAKE_PR_CHECK_LOG="$home/pr-check.log" \
  FM_FAKE_TEARDOWN_LOG="$home/teardown.log" FM_FAKE_DONE_LOG="$home/done.log" \
  FM_FAKE_LIFECYCLE_LOG="$home/lifecycle.log" \
  run_lifecycle_project "$home" "$lifecycle_project" --check --reconcile) \
  || fail "--check exited non-zero while recovering a missed PR watch"
[ -z "$out" ] || fail "an open PR produced drift while its watch was recovered: $out"
assert_grep 'pr-task https://github.com/example/repo/pull/41' "$home/pr-check.log" \
  "--check did not arm the merge watch through fm-pr-check.sh"
assert_grep 'pr=https://github.com/example/repo/pull/41' "$home/state/pr-task.meta" \
  "the recovered merge watch did not record canonical PR metadata"
[ ! -s "$home/teardown.log" ] || fail "an unmerged PR triggered teardown"
[ ! -s "$home/done.log" ] || fail "an unmerged PR closed its board item"

out=$(FM_FAKE_GH_STATE=MERGED FM_FAKE_PR_CHECK_LOG="$home/pr-check.log" \
  FM_FAKE_TEARDOWN_LOG="$home/teardown.log" FM_FAKE_DONE_LOG="$home/done.log" \
  FM_FAKE_LIFECYCLE_LOG="$home/lifecycle.log" \
  run_lifecycle_project "$home" "$lifecycle_project" --check) \
  || fail "report-only --check exited non-zero for an exactly merged recorded PR"
assert_contains "$out" \
  "DRIFT merged-pr-open: pr-task - recorded PR is merged; reconciliation requires verified mutation authority" \
  "report-only --check did not flag an exactly merged recorded PR"
[ ! -s "$home/teardown.log" ] || fail "report-only merged-PR drift invoked teardown"
[ ! -s "$home/done.log" ] || fail "report-only merged-PR drift closed its board item"
[ -f "$home/state/pr-task.meta" ] || fail "report-only merged-PR drift erased canonical task metadata"

out=$(FM_FAKE_GH_STATE=MERGED FM_FAKE_PR_CHECK_LOG="$home/pr-check.log" \
  FM_FAKE_TEARDOWN_LOG="$home/teardown.log" FM_FAKE_DONE_LOG="$home/done.log" \
  FM_FAKE_LIFECYCLE_LOG="$home/lifecycle.log" \
  run_lifecycle_project "$home" "$lifecycle_project" --check --reconcile) \
  || fail "--check exited non-zero for an exactly merged PR"
assert_contains "$out" \
  "DRIFT merged-pr-open: pr-task - merged PR closed and task torn down" \
  "--check did not report its merged-PR auto-close"
[ "$(cat "$home/teardown.log")" = pr-task ] \
  || fail "the merged-PR path did not invoke guarded teardown without force"
assert_contains "$(cat "$home/done.log")" \
  "done pr-task --file $home/data/backlog.md --pr https://github.com/example/repo/pull/41" \
  "the merged-PR path did not close the board item with its recorded PR"
assert_absent "$home/state/pr-task.meta" \
  "the merged-PR path did not tear down the task"
[ "$(cat "$home/lifecycle.log")" = $'teardown pr-task\ndone pr-task' ] \
  || fail "the merged-PR path did not teardown before close: $(cat "$home/lifecycle.log")"
pass "--check recovers missed PR arming and closes only an exactly merged PR after teardown"

home=$(new_home check-unrelated-status-url)
lifecycle_project=$(make_lifecycle_project "$home")
: > "$home/pr-check.log"
: > "$home/teardown.log"
: > "$home/done.log"
fm_write_meta "$home/state/unrelated-url.meta" \
  'window=firstmate:fm-unrelated-url' \
  "worktree=$home/wt" \
  'project=firstmate' \
  'kind=ship' \
  'mode=no-mistakes'
printf '%s\n' \
  'working: dependency https://github.com/example/repo/pull/51 is still open' \
  'done: reviewed https://github.com/example/repo/pull/52' \
  > "$home/state/unrelated-url.status"
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until' \
  'unrelated-url,in_flight,ship,firstmate,Unrelated status links,"-"'
out=$(FM_FAKE_GH_STATE=MERGED FM_FAKE_PR_CHECK_LOG="$home/pr-check.log" \
  FM_FAKE_TEARDOWN_LOG="$home/teardown.log" FM_FAKE_DONE_LOG="$home/done.log" \
  run_lifecycle_project "$home" "$lifecycle_project" --check --reconcile) \
  || fail "unrelated status URLs broke the check contract"
[ -z "$out" ] || fail "unrelated status URLs produced lifecycle drift: $out"
[ ! -s "$home/pr-check.log" ] || fail "an unrelated status URL armed a merge watch"
[ ! -s "$home/teardown.log" ] || fail "an unrelated status URL authorized teardown"
[ ! -s "$home/done.log" ] || fail "an unrelated status URL authorized board closure"
assert_not_contains "$(cat "$home/state/unrelated-url.meta")" 'pr=' \
  "an unrelated status URL became canonical PR metadata"
pass "skipped-arm recovery rejects unrelated URLs in status history"

home=$(new_home check-direct-pr-status)
lifecycle_project=$(make_lifecycle_project "$home")
: > "$home/pr-check.log"
: > "$home/teardown.log"
: > "$home/done.log"
fm_write_meta "$home/state/direct-pr-ready.meta" \
  'window=firstmate:fm-direct-pr-ready' \
  "worktree=$home/wt" \
  'project=firstmate' \
  'kind=ship' \
  'mode=direct-PR'
printf '%s\n' 'done: PR https://github.com/example/repo/pull/53' \
  > "$home/state/direct-pr-ready.status"
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until' \
  'direct-pr-ready,in_flight,ship,firstmate,Direct PR ready,"-"'
out=$(FM_FAKE_GH_STATE=OPEN FM_FAKE_PR_CHECK_LOG="$home/pr-check.log" \
  FM_FAKE_TEARDOWN_LOG="$home/teardown.log" FM_FAKE_DONE_LOG="$home/done.log" \
  run_lifecycle_project "$home" "$lifecycle_project" --check --reconcile) \
  || fail "the exact direct-PR ready event broke skipped-arm recovery"
[ -z "$out" ] || fail "the exact direct-PR ready event produced drift: $out"
assert_grep 'direct-pr-ready https://github.com/example/repo/pull/53' "$home/pr-check.log" \
  "the exact direct-PR ready event did not arm its merge watch"
[ ! -s "$home/teardown.log" ] || fail "an open direct PR triggered teardown"
[ ! -s "$home/done.log" ] || fail "an open direct PR closed its board item"
pass "skipped-arm recovery accepts both exact PR-ready status forms"

home=$(new_home check-merged-teardown-refusal)
lifecycle_project=$(make_lifecycle_project "$home")
: > "$home/pr-check.log"
: > "$home/teardown.log"
: > "$home/done.log"
fm_write_meta "$home/state/dirty-pr.meta" \
  'window=firstmate:fm-dirty-pr' \
  "worktree=$home/wt" \
  'project=firstmate' \
  'kind=ship' \
  'mode=no-mistakes' \
  'pr=https://github.com/example/repo/pull/42'
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until' \
  'dirty-pr,in_flight,ship,firstmate,Merged with local work,"-"'
out=$(FM_FAKE_GH_STATE=MERGED FM_FAKE_TEARDOWN_REFUSE=1 \
  FM_FAKE_PR_CHECK_LOG="$home/pr-check.log" FM_FAKE_TEARDOWN_LOG="$home/teardown.log" \
  FM_FAKE_DONE_LOG="$home/done.log" run_lifecycle_project "$home" "$lifecycle_project" --check --reconcile) \
  || fail "--check lost its report-only exit contract after teardown refusal"
assert_contains "$out" \
  "DRIFT merged-pr-open: dirty-pr - merged PR teardown refused; task and board item preserved" \
  "--check did not report the guarded teardown refusal"
[ "$(cat "$home/teardown.log")" = dirty-pr ] \
  || fail "the refused merged-PR path did not use ordinary teardown"
[ ! -s "$home/done.log" ] || fail "a teardown refusal still closed the board item"
[ -f "$home/state/dirty-pr.meta" ] || fail "a teardown refusal erased task metadata"
pass "the merged-PR auto-close preserves the task and board item when ordinary teardown refuses"

home=$(new_home check-merged-close-retry)
lifecycle_project=$(make_lifecycle_project "$home")
: > "$home/pr-check.log"
: > "$home/teardown.log"
: > "$home/done.log"
: > "$home/lifecycle.log"
fm_write_meta "$home/state/retry-pr.meta" \
  'window=firstmate:fm-retry-pr' \
  "worktree=$home/wt" \
  'project=firstmate' \
  'kind=ship' \
  'mode=no-mistakes' \
  'pr=https://github.com/example/repo/pull/43'
write_listing "$home" queued 'id,state,kind,repo,title,hold_until' \
  'retry-pr,queued,ship,firstmate,Merged close retry,"-"'
out=$(FM_FAKE_GH_STATE=MERGED FM_FAKE_DONE_RC=1 \
  FM_FAKE_PR_CHECK_LOG="$home/pr-check.log" FM_FAKE_TEARDOWN_LOG="$home/teardown.log" \
  FM_FAKE_DONE_LOG="$home/done.log" FM_FAKE_LIFECYCLE_LOG="$home/lifecycle.log" \
  run_lifecycle_project "$home" "$lifecycle_project" --check --reconcile) \
  || fail "--check lost its exit-zero contract after board-close failure"
assert_contains "$out" \
  "DRIFT merged-pr-open: retry-pr - teardown completed but the merged board item could not be closed" \
  "--check did not surface the retryable board-close failure"
assert_not_contains "$out" "DRIFT queued-has-worker: retry-pr" \
  "the close-failure path reused a pre-teardown worker verdict"
assert_absent "$home/state/retry-pr.meta" \
  "the first retry fixture did not complete teardown"
assert_absent "$home/state/retry-pr.status" \
  "the first retry fixture retained status identity unexpectedly"
[ "$(cat "$home/lifecycle.log")" = $'teardown retry-pr\ndone retry-pr' ] \
  || fail "the first close attempt did not teardown before closure: $(cat "$home/lifecycle.log")"

: > "$home/teardown.log"
: > "$home/done.log"
: > "$home/lifecycle.log"
out=$(FM_FAKE_GH_STATE=MERGED \
  FM_FAKE_CREW_VERDICT='state: unknown · source: none · no metadata for retry-pr' \
  FM_FAKE_PR_CHECK_LOG="$home/pr-check.log" \
  FM_FAKE_TEARDOWN_LOG="$home/teardown.log" FM_FAKE_DONE_LOG="$home/done.log" \
  FM_FAKE_LIFECYCLE_LOG="$home/lifecycle.log" \
  run_lifecycle_project "$home" "$lifecycle_project" --check --reconcile) \
  || fail "post-teardown check exited non-zero"
assert_not_contains "$out" "DRIFT merged-pr-open: retry-pr" \
  "post-teardown reconciliation rediscovered merge authority without metadata"
[ ! -s "$home/teardown.log" ] || fail "post-teardown reconciliation reran teardown"
[ ! -s "$home/done.log" ] || fail "post-teardown reconciliation retried board closure"
[ ! -s "$home/lifecycle.log" ] || fail "post-teardown reconciliation mutated lifecycle state"
pass "a failed board close is not retried after metadata teardown"

home=$(new_home check-unrelated-board-links)
lifecycle_project=$(make_lifecycle_project "$home")
: > "$home/pr-check.log"
: > "$home/teardown.log"
: > "$home/done.log"
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until,links' \
  'unrelated-pr-link,in_flight,ship,firstmate,Depends on https://github.com/example/repo/pull/72,"-",pr:https://github.com/example/repo/pull/72'
out=$(FM_FAKE_GH_STATE=MERGED \
  FM_FAKE_CREW_VERDICT='state: unknown · source: none · no metadata' \
  FM_FAKE_PR_CHECK_LOG="$home/pr-check.log" FM_FAKE_TEARDOWN_LOG="$home/teardown.log" \
  FM_FAKE_DONE_LOG="$home/done.log" \
  run_lifecycle_project "$home" "$lifecycle_project" --check --reconcile) \
  || fail "unrelated board links broke the check contract"
assert_not_contains "$out" "DRIFT merged-pr-open" \
  "an unrelated board PR link became automatic-close authority"
[ ! -s "$home/teardown.log" ] || fail "an unrelated board link invoked teardown"
[ ! -s "$home/done.log" ] || fail "an unrelated board link closed a row"
pass "board PR links never supply automatic-close authority"

home=$(new_home check-gitlab-primary-close)
lifecycle_project=$(make_lifecycle_project "$home")
: > "$home/pr-check.log"
: > "$home/teardown.log"
: > "$home/done.log"
fm_write_meta "$home/state/gitlab-merged.meta" \
  'window=firstmate:fm-gitlab-merged' \
  "worktree=$home/wt" \
  'project=firstmate' \
  'kind=ship' \
  'mode=no-mistakes' \
  'pr=https://gitlab.example.com/group/project/-/merge_requests/81'
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until' \
  'gitlab-merged,in_flight,ship,firstmate,Merged GitLab work,"-"'
out=$(FM_FAKE_GLAB_STATE=merged FM_FAKE_PR_CHECK_LOG="$home/pr-check.log" \
  FM_FAKE_TEARDOWN_LOG="$home/teardown.log" FM_FAKE_DONE_LOG="$home/done.log" \
  run_lifecycle_project "$home" "$lifecycle_project" --check --reconcile) \
  || fail "GitLab exact-merge reconciliation exited non-zero"
assert_contains "$out" \
  "DRIFT merged-pr-open: gitlab-merged - merged PR closed and task torn down" \
  "GitLab exact merge did not close its board row"
[ "$(cat "$home/teardown.log")" = gitlab-merged ] \
  || fail "GitLab exact merge did not use ordinary teardown"
assert_contains "$(cat "$home/done.log")" \
  "done gitlab-merged --file $home/data/backlog.md" \
  "GitLab exact merge did not close its board row"
assert_not_contains "$(cat "$home/done.log")" "--pr" \
  "GitLab closure attempted to persist an unsupported MR representation"
pass "GitLab exact merges close once without a board MR artifact"

home=$(new_home check-pr-poll-timeout)
lifecycle_project=$(make_lifecycle_project "$home")
: > "$home/pr-check.log"
: > "$home/teardown.log"
: > "$home/done.log"
fm_write_meta "$home/state/slow-pr.meta" \
  'window=firstmate:fm-slow-pr' \
  "worktree=$home/wt" \
  'project=firstmate' \
  'kind=ship' \
  'mode=no-mistakes' \
  'pr=https://github.com/example/repo/pull/82'
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until' \
  'slow-pr,in_flight,ship,firstmate,Slow forge lookup,"-"'
started=$(date +%s)
out=$(FM_TODO_PR_TIMEOUT=1 FM_FAKE_GH_SLEEP=5 \
  FM_FAKE_PR_CHECK_LOG="$home/pr-check.log" FM_FAKE_TEARDOWN_LOG="$home/teardown.log" \
  FM_FAKE_DONE_LOG="$home/done.log" run_lifecycle_project "$home" "$lifecycle_project" --check) \
  || fail "timed-out report-only PR check exited non-zero"
elapsed=$(($(date +%s) - started))
[ "$elapsed" -le 3 ] || fail "direct PR poll exceeded its configured bound (${elapsed}s)"
assert_not_contains "$out" "DRIFT merged-pr-open" \
  "a timed-out PR poll was interpreted as merged"
[ ! -s "$home/teardown.log" ] || fail "a timed-out PR poll invoked teardown"
[ ! -s "$home/done.log" ] || fail "a timed-out PR poll closed a board row"
pass "direct PR polling is bounded and timeout remains non-merged"

# --- (i) FM_HOME is required fail-closed ------------------------------------

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

# --- (j) incompatible successful listings fail closed ----------------------

home=$(new_home incompatible-emit)
write_listing "$home" in_flight 'state,kind,repo,title' \
  'in_flight,ship,firstmate,Missing the required id field'
set +e
run_project "$home" --emit > "$home/emit.out" 2> "$home/emit.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "--emit accepted an incompatible successful listing"
[ ! -s "$home/emit.out" ] || fail "--emit printed stdout for an incompatible listing"
err=$(<"$home/emit.err")
assert_contains "$err" "unrecognized listing" \
  "--emit did not diagnose an incompatible successful listing"
pass "--emit refuses an incompatible successful board listing without stdout"

home=$(new_home incompatible-check)
write_listing "$home" in_flight 'id,state,kind,repo,title' \
  'missing-hold-field,in_flight,ship,firstmate,Missing hold_until'
out=$(run_project "$home" --check) || fail "--check did not retain its report-only exit contract"
assert_contains "$out" \
  "DRIFT-CHECK-SKIPPED: tasks-axi list --state in_flight returned an unrecognized listing" \
  "--check did not report an incompatible successful listing as skipped"
assert_not_contains "$out" "DRIFT inflight-no-worker" \
  "--check derived findings from an incompatible listing"
pass "--check skips an incompatible successful listing and still exits zero"

home=$(new_home malformed-quote-emit)
write_listing "$home" in_flight 'id,state,kind,repo,title' \
  'bad-quote,in_flight,ship,firstmate,"title"junk'
set +e
run_project "$home" --emit > "$home/emit.out" 2> "$home/emit.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "--emit accepted trailing text after a quoted TOON primitive"
[ ! -s "$home/emit.out" ] || fail "--emit printed stdout for a malformed quoted primitive"
err=$(<"$home/emit.err")
assert_contains "$err" "unrecognized listing" \
  "--emit did not diagnose a malformed quoted primitive"
pass "--emit rejects trailing text after a quoted TOON primitive"

home=$(new_home mid-cell-quote-emit)
write_listing "$home" in_flight 'id,state,kind,repo,title' \
  'bad-quote,in_flight,ship,firstmate,bad"quote"'
set +e
run_project "$home" --emit > "$home/emit.out" 2> "$home/emit.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "--emit accepted a quote inside an unquoted TOON primitive"
[ ! -s "$home/emit.out" ] || fail "--emit printed stdout for a mid-cell quote"
pass "--emit rejects quotes inside unquoted TOON primitives"

home=$(new_home invalid-escape-emit)
write_listing "$home" in_flight 'id,state,kind,repo,title' \
  'bad-escape,in_flight,ship,firstmate,"bad\q"'
set +e
run_project "$home" --emit > "$home/emit.out" 2> "$home/emit.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "--emit accepted an invalid TOON escape"
[ ! -s "$home/emit.out" ] || fail "--emit printed stdout for an invalid TOON escape"
err=$(<"$home/emit.err")
assert_contains "$err" "unrecognized listing" \
  "--emit did not diagnose a listing containing an invalid TOON escape"
pass "--emit fails closed without stdout on an invalid TOON escape"

home=$(new_home invalid-escape-check)
write_listing "$home" in_flight 'id,state,kind,repo,title,hold_until' \
  'bad-escape,in_flight,ship,firstmate,"bad\q","-"'
out=$(run_project "$home" --check) || fail "--check did not retain its report-only exit contract"
assert_contains "$out" \
  "DRIFT-CHECK-SKIPPED: tasks-axi list --state in_flight returned an unrecognized listing" \
  "--check did not skip a listing containing an invalid TOON escape"
assert_not_contains "$out" "DRIFT inflight-no-worker" \
  "--check derived findings from a row containing an invalid TOON escape"
pass "--check skips an invalid TOON escape and still exits zero"
