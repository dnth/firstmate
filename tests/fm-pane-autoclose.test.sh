#!/usr/bin/env bash
# shellcheck disable=SC2031 # Fixture globals are assigned by setup_home in this shell; the backgrounded and substituted calls above are read-only consumers.
# tests/fm-pane-autoclose.test.sh - behavior tests for
# bin/fm-pane-autoclose.sh and its wiring into bin/fm-branch-outcome.sh
# deliver, driven against a stateful fake `herdr` and a stub `tasks-axi`.
#
# The suite proves the four decisions the contract owns: close after a terminal
# done: receipt whose board row is still In flight, keep the pane for every
# follow-on-work signal, keep it for a failed: receipt or a superseded claim,
# and refuse loudly on a missing or ambiguous endpoint. It also pins that only
# the exact pane closes: no `workspace close`, no `session stop`, and never the
# captain's active tab.
#
# The real-binary lab coverage (transcripts surviving a close, the active-tab
# refusal against real Herdr) lives in
# tests/fm-pane-autoclose-herdr-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

REAL_TASKS_AXI=$(command -v tasks-axi || true)
TMP_ROOT=$(fm_test_tmproot fm-pane-autoclose-tests)
AUTOCLOSE="$ROOT/bin/fm-pane-autoclose.sh"
DELIVER="$ROOT/bin/fm-branch-outcome.sh"

# A live fake fleet: one session, two workspaces, the target pane alone in the
# second tab of the first workspace so the workspace is never emptied.
make_fake_herdr() { # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  printf '%s\n' '{
  "workspaces":[
    {"workspace_id":"w1","focused":true,"active_tab_id":"w1:t1"},
    {"workspace_id":"w2","focused":false,"active_tab_id":"w2:t1"}
  ],
  "tabs":[
    {"tab_id":"w1:t1","workspace_id":"w1","pane_id":"w1:p1","focused":true},
    {"tab_id":"w1:t2","workspace_id":"w1","pane_id":"w1:p2","focused":false},
    {"tab_id":"w2:t1","workspace_id":"w2","pane_id":"w2:p1","focused":false}
  ]}' > "$dir/state.json"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_HERDR_STATE:?}"
{
  printf 'CALL'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "${FM_FAKE_HERDR_LOG:?}"
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }
arg_after() { local want=$1 i; shift; for ((i = 1; i <= $#; i++)); do [ "${!i}" = "$want" ] && { i=$((i + 1)); printf '%s' "${!i}"; return 0; }; done; return 1; }
cmd=${1:-}; sub=${2:-}
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n'
    ;;
  "session list")
    printf '{"sessions":[{"name":"%s","running":true,"default":false,"socket_path":"/tmp/%s.sock"}]}\n' \
      "${HERDR_SESSION:-default}" "${HERDR_SESSION:-default}"
    ;;
  "workspace list")
    jq -c '{result:{workspaces:.workspaces}}' "$STATE"
    ;;
  "tab list")
    ws=$(arg_after --workspace "$@") || ws=
    jq -c --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}' "$STATE"
    ;;
  "tab get")
    tab=${3:-}
    jq -c --arg t "$tab" '.tabs[]|select(.tab_id==$t)|{result:{tab:{tab_id:.tab_id,workspace_id:.workspace_id}}}' "$STATE"
    ;;
  "pane list")
    ws=$(arg_after --workspace "$@") || ws=
    jq -c --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id,tab_id:.tab_id}]}}' "$STATE"
    ;;
  "pane get")
    pane=${3:-}
    if jq -e --arg p "$pane" '.tabs[]|select(.pane_id==$p)' "$STATE" >/dev/null 2>&1; then
      jq -c --arg p "$pane" '.tabs[]|select(.pane_id==$p)|{result:{pane:{pane_id:.pane_id,tab_id:.tab_id,workspace_id:.workspace_id}}}' "$STATE"
    else
      printf '{"error":{"code":"pane_not_found"}}\n'
    fi
    ;;
  "pane close")
    pane=${3:-}
    jq --arg p "$pane" '.tabs |= [.[]|select(.pane_id != $p)]' "$STATE" | save
    ;;
  "agent get")
    printf '{"error":{"code":"agent_not_found"}}\n'
    ;;
  *)
    :
    ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# A stub tasks-axi: `show` prints $FM_FAKE_BOARD_ROW verbatim (or fails with
# $FM_FAKE_BOARD_ERROR), every other invocation succeeds.
make_fake_tasks_axi() { # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  '--version ') printf 'tasks-axi 0.2.4\n'; exit 0 ;;
  'update --help') printf '%s\n' '--archive-body'; exit 0 ;;
  'mv --help') printf '%s\n' '[<id>...]'; exit 0 ;;
esac
if [ "${1:-}" = hold ] && [ "${2:-}" = --help ]; then
  printf '%s\n' '--kind captain'
  exit 0
fi
if [ "${1:-}" = show ]; then
  if [ "${2:-}" = linked-call ]; then
    printf '%s\n' "${FM_FAKE_LINKED_ROW:?}"
    exit 0
  fi
  if [ -n "${FM_FAKE_BOARD_ERROR:-}" ]; then
    printf '%s\n' "$FM_FAKE_BOARD_ERROR"
    exit 1
  fi
  printf '%s\n' "${FM_FAKE_BOARD_ROW:-}"
  exit 0
fi
exit 0
SH
  chmod +x "$fb/tasks-axi"
  printf '%s\n' "$fb"
}

# setup_home <name>: a fixture home with a markdown backlog and one In flight
# row, plus fake `herdr`/`tasks-axi` on PATH.
setup_home() { # <name>
  HOME_DIR="$TMP_ROOT/$1"
  STATE="$HOME_DIR/state"
  DATA="$HOME_DIR/data"
  CONFIG="$HOME_DIR/config"
  mkdir -p "$STATE" "$DATA" "$CONFIG"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$HOME_DIR/.tasks.toml"
  printf -- '- [ ] demo - fixture row\n' > "$DATA/backlog.md"
  FB=$(make_fake_herdr "$HOME_DIR")
  FAKE_TASKS=$(make_fake_tasks_axi "$HOME_DIR")
  PATH="$FB:$FAKE_TASKS:$PATH"
  export PATH
  export FM_FAKE_HERDR_STATE="$HOME_DIR/state.json"
  export FM_FAKE_HERDR_LOG="$HOME_DIR/herdr.log"
  : > "$FM_FAKE_HERDR_LOG"
  export FM_TASKS_AXI_COMPATIBLE=1
  unset FM_FAKE_BOARD_ROW FM_FAKE_BOARD_ERROR
  export FM_FAKE_BOARD_ROW='task:
  id: demo
  state: in_flight
  blocked: no
  held: no'
  export HOME_DIR STATE DATA CONFIG
}

# write_herdr_meta <task> <session> <workspace> <tab> <pane> [kind] [mode]
write_herdr_meta() {
  local task=$1 session=$2 ws=$3 tab=$4 pane=$5 kind=${6:-scout} mode=${7:-no-mistakes}
  fm_write_meta "$STATE/$task.meta" \
    "window=$session:$pane" \
    "backend=herdr" \
    "endpoint_task_id=$task" \
    "kind=$kind" \
    "mode=$mode" \
    "decision_keys=" \
    "worktree=$HOME_DIR/wt" \
    "project=$HOME_DIR/proj" \
    "herdr_session=$session" \
    "herdr_workspace_id=$ws" \
    "herdr_tab_id=$tab" \
    "herdr_pane_id=$pane"
}

status_ident() { # <status-file>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%d:%i' "$1" 2>/dev/null
  else
    LC_ALL=C stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

run_autoclose() { # <task> <endpoint> [extra args...]
  local task=$1 endpoint=$2 ident
  shift 2
  ident=$(status_ident "$STATE/$task.status")
  FM_HOME="$HOME_DIR" bash "$AUTOCLOSE" "$task" --endpoint "$endpoint" --status-ident "$ident" "$@" 2>&1
}

run_deliver() { # <task> <endpoint>
  local task=$1 endpoint=$2 ident
  ident=$(status_ident "$STATE/$task.status")
  FM_HOME="$HOME_DIR" bash "$DELIVER" deliver --task "$task" --status-ident "$ident" --endpoint "$endpoint" 2>&1
}

# How many recorded CLI calls match "<verb> <sub> <arg>" exactly, built with a
# real unit separator so no shell quoting can turn it into a literal backslash.
call_count() { # <verb> <sub> [arg]
  local needle
  needle=$(printf '\037%s\037%s\037%s' "$1" "$2" "${3:-}")
  grep -cF -- "$needle" "$FM_FAKE_HERDR_LOG" 2>/dev/null || true
}

pane_closed_count() { # <pane-id>
  call_count pane close "$1"
}

pane_present() { # <pane-id>
  jq -e --arg p "$1" '.tabs[] | select(.pane_id == $p)' "$FM_FAKE_HERDR_STATE" >/dev/null 2>&1
}

# The scenario the inbox correction asked for: a completed scout whose receipt
# lands on its done: line while the board row is still In flight.
test_scout_done_receipt_with_row_in_flight_closes() {
  local out rc size
  setup_home scout-done
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  mkdir -p "$DATA/demo"
  printf 'report\n' > "$DATA/demo/report.md"
  printf 'working: scouting\n' > "$STATE/demo.status"
  printf 'done: report ready at data/demo/report.md\n' >> "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_deliver demo "$size"); rc=$?
  expect_code 0 "$rc" "deliver should succeed for a scout done receipt"
  assert_contains "$out" "closed: demo pane lab-sess:w1:p2" "the finished scout pane should close"
  [ "$(pane_closed_count w1:p2)" = 1 ] || fail "expected exactly one pane close call for w1:p2"
  pane_present w1:p2 && fail "the target pane should be gone"
  [ "$(call_count workspace close)" = 0 ] || fail "autoclose must never call workspace close"
  [ "$(call_count session stop)" = 0 ] || fail "autoclose must never stop the Herdr session"
  assert_present "$STATE/demo.meta" "autoclose removes no durable task record"
  pass "closes the pane after a scout done: receipt while the board row is In flight"
}

test_ship_pr_receipt_without_inventory_closes() {
  local out rc size
  setup_home ship-pr
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 ship no-mistakes
  printf 'working: implementing\n' > "$STATE/demo.status"
  printf 'done: PR https://github.com/dnth/firstmate/pull/999\n' >> "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_deliver demo "$size"); rc=$?
  expect_code 0 "$rc" "deliver should succeed for a ship PR receipt"
  assert_contains "$out" "closed: demo pane lab-sess:w1:p2" "a ship task with no captain-call inventory should close"
  pane_present w1:p2 && fail "a ship PR completion without an inventory should close its pane"
  pass "closes a ship PR completion's pane when no captain-call inventory exists"
}

test_failure_receipt_keeps_pane() {
  local out rc size
  setup_home failure
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  printf 'working: scouting\n' > "$STATE/demo.status"
  printf 'failed: the corpus could not be read\n' >> "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_deliver demo "$size"); rc=$?
  expect_code 0 "$rc" "deliver should still record a failure receipt"
  assert_contains "$out" "kept: demo" "a failure receipt must keep the pane"
  assert_contains "$out" "not a done: claim" "the keep reason should name the verb"
  pane_present w1:p2 || fail "a failure receipt must never close the pane"
  pass "keeps the pane for a failed: receipt"
}

test_open_decision_keeps_pane() {
  local out rc size
  setup_home open-decision
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 ship no-mistakes
  {
    printf 'working: implementing\n'
    printf 'needs-decision [key=api-shape]: choose the route\n'
    printf 'done: PR https://github.com/dnth/firstmate/pull/999\n'
  } > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 0 "$rc" "an open decision is a keep, not an error"
  assert_contains "$out" "follow-on work remains: open keyed decision" "the keep reason should name the open decision"
  pane_present w1:p2 || fail "an open keyed decision must keep the pane"
  pass "keeps the pane while a keyed decision is open"
}

test_later_event_keeps_pane() {
  local out rc size
  setup_home superseded
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  printf 'working: follow-up check\ndone: report ready at data/demo/report.md\n' >> "$STATE/demo.status"
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 0 "$rc" "a superseded claim is a keep, not an error"
  assert_contains "$out" "later status event supersedes" "the keep reason should name the superseding event"
  pane_present w1:p2 || fail "a superseded done: claim must not close the pane"
  pass "keeps the pane when a later status event supersedes the receipt"
}

test_done_without_artifact_keeps_pane() {
  local out rc size
  setup_home bare-done
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  printf 'done: finished\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 0 "$rc" "a bare done: is a keep, not an error"
  assert_contains "$out" "carries no delivery artifact" "the keep reason should name the missing artifact"
  pane_present w1:p2 || fail "a bare done: must not close the pane"
  pass "keeps the pane for a done: without its delivery artifact"
}

test_active_tab_is_never_closed() {
  local out rc size
  setup_home active-tab
  # The target pane's tab is the focused tab of the focused workspace.
  jq '.tabs |= map(if .pane_id == "w1:p2" then .focused = true else .focused = false end)
      | .workspaces |= map(if .workspace_id == "w1" then .active_tab_id = "w1:t2" else . end)' \
    "$FM_FAKE_HERDR_STATE" > "$FM_FAKE_HERDR_STATE.tmp" && mv "$FM_FAKE_HERDR_STATE.tmp" "$FM_FAKE_HERDR_STATE"
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 0 "$rc" "an active-tab refusal is a keep, not an error"
  assert_contains "$out" "pane close was refused" "the keep reason should name the refusal"
  pane_present w1:p2 || fail "the captain's active tab must never be closed"
  [ "$(pane_closed_count w1:p2)" = 0 ] || fail "no close call may be issued for the active tab"
  pass "never closes the captain's active tab"
}

test_rotated_status_identity_keeps_replacement_pane() {
  local out rc size old_ident
  setup_home rotated
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  old_ident=$(status_ident "$STATE/demo.status")
  # A re-spawn replaced the status record: same task id, same bytes at the same
  # offset, a different inode. Create the replacement while the old record still
  # exists so the two inodes are provably distinct, then swap it in.
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status.new"
  rm -f "$STATE/demo.status"
  mv "$STATE/demo.status.new" "$STATE/demo.status"
  out=$(FM_HOME="$HOME_DIR" bash "$AUTOCLOSE" demo --endpoint "$size" --status-ident "$old_ident" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a stale receipt is a keep, not an error"
  assert_contains "$out" "status identity no longer matches" "the keep reason should name the rotated identity"
  pane_present w1:p2 || fail "a stale receipt must not close a replacement task's pane"
  [ "$(pane_closed_count w1:p2)" = 0 ] || fail "no close call may be issued for a rotated status identity"
  pass "keeps a replacement pane when the receipt's status identity rotated"
}

test_missing_endpoint_metadata_keeps() {
  local out rc size
  setup_home no-meta
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 0 "$rc" "a task with no endpoint metadata is a keep, not an error"
  assert_contains "$out" "no task endpoint metadata" "the keep reason should name the missing metadata"
  pass "keeps the pane when the task has no endpoint metadata"
}

test_ambiguous_endpoint_refuses_loudly() {
  local out rc size
  setup_home ambiguous
  # window and herdr_pane_id disagree: the endpoint cannot be resolved.
  fm_write_meta "$STATE/demo.meta" \
    "window=lab-sess:w1:p9" \
    "backend=herdr" \
    "endpoint_task_id=demo" \
    "kind=scout" \
    "mode=no-mistakes" \
    "decision_keys=" \
    "worktree=$HOME_DIR/wt" \
    "project=$HOME_DIR/proj" \
    "herdr_session=lab-sess" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" \
    "herdr_pane_id=w1:p2"
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 2 "$rc" "an ambiguous endpoint must refuse loudly"
  assert_contains "$out" "REFUSED" "the refusal should be explicit"
  [ "$(pane_closed_count w1:p2)" = 0 ] || fail "an ambiguous endpoint must never close a pane"
  pass "refuses loudly on an ambiguous endpoint"
}

test_pending_reply_keeps_pane() {
  local out rc size
  setup_home pending-reply
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  mkdir -p "$STATE/pending-replies"
  fm_write_meta "$STATE/pending-replies/corr-1" "task_id=demo" "phase=awaiting_report"
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 0 "$rc" "an open routed reply is a keep"
  assert_contains "$out" "open routed reply" "the keep reason should name the pending reply"
  pane_present w1:p2 || fail "an open routed reply must keep the pane"
  pass "keeps the pane while a routed reply is open"
}

test_armed_check_keeps_pane() {
  local out rc size
  setup_home armed-check
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STATE/demo.check.sh"
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 0 "$rc" "a custom check is a keep"
  assert_contains "$out" "armed or intended custom check" "the keep reason should name the check"
  pane_present w1:p2 || fail "a custom check must keep the pane"
  pass "keeps the pane while a custom watcher check is armed"
}

test_ext_link_keeps_pane() {
  local out rc size
  setup_home ext-link
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  printf 'ext_request=ext-abc123\next_followups=0\n' >> "$STATE/demo.meta"
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 0 "$rc" "a linked external request is a keep"
  assert_contains "$out" "linked external request" "the keep reason should name the link"
  pane_present w1:p2 || fail "an ext link must keep the pane"
  pass "keeps the pane while an external request is linked"
}

test_held_board_row_keeps_pane() {
  local out rc size
  setup_home held-row
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  export FM_FAKE_BOARD_ROW='task:
  id: demo
  state: queued
  blocked: no
  held: yes
  hold_kind: captain'
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 0 "$rc" "a held board row is a keep"
  assert_contains "$out" "blocked or held backlog row" "the keep reason should name the row state"
  pane_present w1:p2 || fail "a held board row must keep the pane"
  pass "keeps the pane while the board row is held"
}

test_unreadable_board_refuses() {
  local out rc size
  setup_home board-error
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  export FM_FAKE_BOARD_ERROR='code: BACKEND_DOWN'
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 2 "$rc" "an unreadable board must refuse rather than guess"
  assert_contains "$out" "cannot prove follow-on state is clear" "the refusal should name the unprovable state"
  pane_present w1:p2 || fail "an unreadable board must never close a pane"
  pass "refuses loudly when the board row state cannot be read"
}

test_secondmate_keeps_pane() {
  local out rc size
  setup_home secondmate
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 secondmate secondmate
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 0 "$rc" "a secondmate record is a keep"
  assert_contains "$out" "secondmate home keeps its pane" "the keep reason should name the persistent home"
  pane_present w1:p2 || fail "a secondmate pane must never autoclose"
  pass "keeps a secondmate home's pane"
}

test_already_gone_is_idempotent() {
  local out rc size
  setup_home already-gone
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  jq '.tabs |= [.[]|select(.pane_id != "w1:p2")]' "$FM_FAKE_HERDR_STATE" > "$FM_FAKE_HERDR_STATE.tmp" \
    && mv "$FM_FAKE_HERDR_STATE.tmp" "$FM_FAKE_HERDR_STATE"
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size"); rc=$?
  expect_code 0 "$rc" "an already-closed pane must be an idempotent success"
  assert_contains "$out" "was already gone" "the result should report the pane already gone"
  pass "reports an already-closed pane without issuing another close"
}

test_local_only_keeps_pane() {
  local out size
  setup_home local-only
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 ship local-only
  printf 'done: ready in branch fm/demo\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  out=$(run_autoclose demo "$size") || fail "local-only should keep successfully: $out"
  assert_contains "$out" "local-only completion never autocloses" "local-only is excluded"
  pane_present w1:p2 || fail "local-only completion must keep its pane"
  pass "keeps local-only completions"
}

test_linked_captain_call_keeps_pane() {
  local out size
  setup_home linked-call
  write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
  printf 'decisions_reviewed=1\ndecision_keys=linked-call\n' >> "$STATE/demo.meta"
  export FM_FAKE_LINKED_ROW='task:
  id: linked-call
  state: queued
  held: yes
  blocked: no
  hold_kind: captain
  body: waiting for a choice'
  printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
  size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
  FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-captain-hold.sh" verify demo >/dev/null \
    || fail "the ordinary inventory gate must accept a durably held call"
  out=$(run_autoclose demo "$size") || fail "linked captain call should keep successfully: $out"
  assert_contains "$out" "linked captain-call inventory" "linked held work keeps the pane"
  pane_present w1:p2 || fail "linked captain-held work must keep its pane"
  local body
  body=$(printf 'Captain hold set: 2026-10-29T00:00:00Z\n\nResolution recorded by fm-captain-hold.\nHold stamp: 2026-10-29T00:00:00Z\n\nCaptain decision:\nUse the corpus.\n' | jq -Rs .)
  export FM_FAKE_LINKED_ROW="task:
  id: linked-call
  state: queued
  held: no
  blocked: no
  hold_kind: captain
  body: $body"
  FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-captain-hold.sh" verify demo --require-answered >/dev/null \
    || fail "a current released answer must satisfy inventory verification"
  body=$(printf 'Captain hold set: 2026-10-29T00:00:01Z\n\nResolution recorded by fm-captain-hold.\nHold stamp: 2026-10-29T00:00:00Z\n\nCaptain decision:\nUse the corpus.\n' | jq -Rs .)
  export FM_FAKE_LINKED_ROW="task:
  id: linked-call
  state: queued
  held: yes
  blocked: no
  hold_kind: captain
  body: $body"
  FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-captain-hold.sh" verify demo >/dev/null \
    || fail "a renewed hold must remain valid for ordinary teardown inventory"
  out=$(run_autoclose demo "$size") || fail "a renewed hold should keep successfully: $out"
  assert_contains "$out" "linked captain-call inventory" "an old answer cannot settle a renewed hold"
  pane_present w1:p2 || fail "a renewed unanswered hold must keep its pane"
  export FM_FAKE_LINKED_ROW='task:
  id: linked-call
  state: done
  held: no
  blocked: no
  hold_kind: captain
  body: Resolution recorded by fm-captain-hold. Captain decision: use the corpus'
  out=$(run_autoclose demo "$size") || fail "answered linked call should permit closure: $out"
  assert_contains "$out" "closed: demo" "a recorded answer clears linked work"
  pane_present w1:p2 && fail "answered linked call should allow the pane to close"
  pass "keeps linked held calls and closes after their recorded answer"
}

test_revalidates_after_presentation_wait() {
  local mutation lock size runner out attempt ready
  for mutation in working blocker repeated; do
    setup_home "wait-$mutation"
    write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
    printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
    size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
    lock=$(FM_HOME="$HOME_DIR" bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path lab-sess' _ "$ROOT") \
      || fail "could not resolve the fixture presentation lock"
    ready="$HOME_DIR/lock-ready"
    (
      . "$ROOT/bin/fm-wake-lib.sh"
      fm_lock_try_acquire "$lock" || exit 1
      touch "$ready"
      while [ ! -e "$HOME_DIR/release-lock" ]; do sleep 0.02; done
      fm_lock_release "$lock"
    ) &
    local holder=$!
    for ((attempt=0; attempt<100; attempt++)); do
      [ ! -e "$ready" ] || break
      sleep 0.02
    done
    [ -e "$ready" ] || fail "presentation lock was not acquired"
    : > "$FM_FAKE_HERDR_LOG"
    run_autoclose demo "$size" > "$HOME_DIR/result" &
    runner=$!
    for ((attempt=0; attempt<150; attempt++)); do
      [ "$(call_count session list --json)" -lt 1 ] || break
      sleep 0.02
    done
    [ "$attempt" -lt 150 ] || fail "autoclose did not reach the presentation lock"
    case "$mutation" in
      working) printf 'working: resumed investigation\n' >> "$STATE/demo.status" ;;
      repeated) printf 'working: resumed investigation\ndone: report ready at data/demo/report.md\n' >> "$STATE/demo.status" ;;
      blocker) printf 'blocked [key=scope]: need scope\ndone: report ready at data/demo/report.md\n' >> "$STATE/demo.status" ;;
    esac
    touch "$HOME_DIR/release-lock"
    wait "$holder" || fail "lock holder failed"
    wait "$runner" || fail "autoclose failed after waiting"
    out=$(cat "$HOME_DIR/result")
    assert_contains "$out" "kept: demo" "new $mutation state must keep the pane"
    pane_present w1:p2 || fail "a $mutation appended during lock contention must keep its pane"
    [ "$(pane_closed_count w1:p2)" = 0 ] || fail "no close may occur after a $mutation arrives"
  done
  pass "revalidates completion and keyed work after the presentation lock wait"
}

test_public_commitment_owner_keeps_pane() {
  [ -n "$REAL_TASKS_AXI" ] || { echo "skip: tasks-axi not found for public commitment ownership coverage"; return; }
  local route parent owner work_home size out rc
  for route in main durable legacy; do
    setup_home "promise-$route"
    ln -sf "$REAL_TASKS_AXI" "$FB/tasks-axi"
    parent="$HOME_DIR/primary"
    owner=$HOME_DIR
    work_home=main
    if [ "$route" != main ]; then
      mkdir -p "$parent/state" "$parent/data" "$parent/config"
      cp "$HOME_DIR/.tasks.toml" "$parent/.tasks.toml"
      printf 'alice\n' > "$HOME_DIR/.fm-secondmate-home"
      fm_write_meta "$parent/state/alice.meta" "kind=secondmate" "home=$HOME_DIR"
      printf -- '- alice - fixture (home: %s; scope: fixture; projects: ; added 2026-10-29)\n' \
        "$HOME_DIR" > "$parent/data/secondmates.md"
      if [ "$route" = durable ]; then
        printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
          > "$HOME_DIR/.fm-secondmate-parent"
      fi
      owner=$parent
      work_home=secondmate:alice
    fi
    printf 'FMX_PAIRING_TOKEN=fixture-token\n' > "$owner/.env"
    jq -n '{request_id:"req-promise", platform:"x", context_binding:{version:"ctx1", value:"ctx1_req-promise"},
      public_safe_summary:"report the scout result", received_at:"2026-10-29T00:00:00Z",
      followup_expires_at:"2099-01-01T00:00:00Z", reservation_expires_at:"2099-01-01T00:00:00Z"}' \
      > "$owner/request.json"
    jq -n '{type:"report-ready", project:"firstmate", required_deliverables:["report_path"], completion_policy:"all-required"}' \
      > "$owner/expected.json"
    jq -n --arg home "$work_home" \
      '{relation_id:"rel-report", work_ref:{home_id:$home, task_id:"demo"}, role:"fulfills", required:true, generation:1}' \
      > "$owner/relation.json"
    out=$(FM_HOME="$owner" bash "$ROOT/bin/fm-tasks-axi.sh" public-followup add promise \
      --request-context-file "$owner/request.json" --purpose promised-final \
      --expected-final-file "$owner/expected.json" --expires-at 2099-01-01T00:00:00Z 2>&1) \
      || fail "could not create the $route public commitment: $out"
    FM_HOME="$owner" bash "$ROOT/bin/fm-tasks-axi.sh" public-followup bind-work promise \
      --relation-file "$owner/relation.json" >/dev/null || fail "could not bind the $route public commitment"
    FM_HOME="$owner" bash "$ROOT/bin/fm-public-followup.sh" register promise \
      --relation rel-report --work-home "$work_home" --work-id demo --generation 1 >/dev/null \
      || fail "could not register the $route public commitment"
    write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
    printf 'done: report ready at data/demo/report.md\n' > "$STATE/demo.status"
    size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
    out=$(FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$parent" run_deliver demo "$size") \
      || fail "the $route completion receipt should be delivered: $out"
    assert_contains "$out" "unresolved public commitment" "the $route owner must guard its promise"
    pane_present w1:p2 || fail "the $route public commitment must keep the pane"
    [ "$(pane_closed_count w1:p2)" = 0 ] || fail "the $route promise must prevent a close call"
    if [ "$route" = durable ]; then
      printf 'home=%s\n' "$parent" >> "$parent/state/alice.meta"
      out=$(run_autoclose demo "$size"); rc=$?
      expect_code 2 "$rc" "an unverified primary binding must refuse closure"
      pane_present w1:p2 || fail "an unverified primary binding must keep the pane"
      printf 'home=%s\n' "$HOME_DIR" >> "$parent/state/alice.meta"
    fi
    write_herdr_meta unbound lab-sess w1 w1:t2 w1:p2 scout no-mistakes
    printf 'done: report ready at data/unbound/report.md\n' > "$STATE/unbound.status"
    size=$(wc -c < "$STATE/unbound.status" | tr -d ' ')
    out=$(FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$parent" run_deliver unbound "$size") \
      || fail "the unrelated $route completion should be delivered: $out"
    assert_contains "$out" "closed: unbound" "a promise must guard only its bound work"
    pane_present w1:p2 && fail "the unbound $route task should close its pane"
  done
  pass "resolves main, durable, and legacy promise ownership before closing only unbound panes"
}

test_standing_event_byte_boundaries() {
  local variant size out
  for variant in blank-tail unterminated; do
    setup_home "byte-$variant"
    write_herdr_meta demo lab-sess w1 w1:t2 w1:p2 scout no-mistakes
    printf 'done: café report ready at data/demo/report.md' > "$STATE/demo.status"
    [ "$variant" = unterminated ] || printf '\n' >> "$STATE/demo.status"
    size=$(wc -c < "$STATE/demo.status" | tr -d ' ')
    [ "$variant" = unterminated ] || printf ' \n\t\n' >> "$STATE/demo.status"
    out=$(run_autoclose demo "$size") || fail "the standing event should close: $out"
    assert_contains "$out" "closed: demo" "the $variant event byte endpoint must match"
    pane_present w1:p2 && fail "the $variant standing event should close its pane"
  done
  pass "compares standing event endpoints in bytes across newline and UTF-8 boundaries"
}

test_public_commitment_owner_keeps_pane
test_standing_event_byte_boundaries
test_local_only_keeps_pane
test_linked_captain_call_keeps_pane
test_revalidates_after_presentation_wait
test_scout_done_receipt_with_row_in_flight_closes
test_ship_pr_receipt_without_inventory_closes
test_failure_receipt_keeps_pane
test_open_decision_keeps_pane
test_later_event_keeps_pane
test_done_without_artifact_keeps_pane
test_active_tab_is_never_closed
test_rotated_status_identity_keeps_replacement_pane
test_missing_endpoint_metadata_keeps
test_ambiguous_endpoint_refuses_loudly
test_pending_reply_keeps_pane
test_armed_check_keeps_pane
test_ext_link_keeps_pane
test_held_board_row_keeps_pane
test_unreadable_board_refuses
test_secondmate_keeps_pane
test_already_gone_is_idempotent
