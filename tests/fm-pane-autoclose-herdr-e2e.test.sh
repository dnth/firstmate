#!/usr/bin/env bash
# tests/fm-pane-autoclose-herdr-e2e.test.sh - real-binary Herdr lab coverage for
# bin/fm-pane-autoclose.sh and its wiring into bin/fm-branch-outcome.sh deliver.
#
# Everything here runs in one named, non-default lab session provisioned and
# torn down only through bin/fm-herdr-lab.sh, which appends --session to every
# call, refuses a destructive call against the default session, and verifies the
# captain's fleet state is unchanged after teardown.
# The production scripts under test call the adapter, and the adapter calls the
# `herdr` executable with an explicit --session; a PATH shim named `herdr`
# validates that requested session and delegates every such call to
# bin/fm-herdr-lab.sh run, so no probe reaches the real binary directly.
#
# Cases, all against a real Herdr server:
#   - a completed scout's receipt-then-board sequence: the receipt lands on its
#     done: line while the board row is still In flight, and the exact pane
#     closes;
#   - a failed: receipt, local-only completion, and follow-on-work exclusions
#     (open keyed decision or blocker, blocked or held board row, linked captain
#     call, external request, open routed reply, armed check),
#     which all keep the pane a supervisor still needs;
#   - the captain's active tab, which is never closed;
#   - closure is a view operation: the session keeps running, a sibling pane
#     still reads, Herdr's persisted session history retains the transcript,
#     and the closed pane's process-owned file stays on disk;
#
# FM_PANE_AUTOCLOSE_ARTIFACT_DIR, when set, receives the captured transcript for
# a caller that needs a reviewable artifact outside this scratch root.
#   - an ambiguous endpoint refuses loudly (exit 2) and closes nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (needed for the board-row fixture)"; exit 0; }

herdr_forget_inherited_pane
unset TASKS_AXI_BACKEND TASKS_AXI_FILE

LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
LAB_SESSION=$("$LAB_HELPER" name fm-pane-autoclose) || { echo "skip: cannot generate a lab session name"; exit 0; }
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-pane-autoclose-e2e.XXXXXX") || exit 1

# Teardown diagnostics are never swallowed: the helper verifies the captain's
# default fleet state is byte-identical after the lab session retires, so a
# failed teardown or tripwire fails this suite and keeps its scratch evidence.
cleanup_all() {
  local rc
  if "$LAB_HELPER" teardown "$LAB_SESSION"; then
    :
  else
    rc=$?
    printf 'not ok - LAB TEARDOWN FAILED (rc=%s): the default-session tripwire or session cleanup did not verify\n' "$rc" >&2
    printf 'scratch evidence preserved at %s\n' "$SCRATCH" >&2
    trap - EXIT
    exit "$rc"
  fi
  rm -rf "$SCRATCH"
}
trap cleanup_all EXIT

lab() { # <herdr arguments...>
  "$LAB_HELPER" run "$LAB_SESSION" "$@"
}

"$LAB_HELPER" provision "$LAB_SESSION" || fail "could not provision the isolated Herdr lab session"

# herdr-session shim: every call the production scripts make to the adapter's
# `herdr` executable must name exactly the lab session. It strips that flag and
# delegates to the mandated lab helper, which re-adds it through the guarded
# `run` path.
SHIM="$SCRATCH/fakebin"
mkdir -p "$SHIM"
cat > "$SHIM/herdr" <<'SH'
#!/usr/bin/env bash
set -u
want=${FM_LAB_SESSION:?}
helper=${FM_LAB_HELPER:?}
seen=''
args=()
helper_path=${FM_LAB_ORIGINAL_PATH:?}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) shift; seen=${1:-} ;;
    --session=*) seen=${1#--session=} ;;
    *) args+=("$1") ;;
  esac
  shift
done
[ "$seen" = "$want" ] || {
  echo "herdr shim: refusing a call outside lab session $want (got ${seen:-none})" >&2
  exit 64
}
PATH=$helper_path exec "$helper" run "$want" ${args[@]+"${args[@]}"}
SH
chmod +x "$SHIM/herdr"
export FM_LAB_SESSION="$LAB_SESSION"
export FM_LAB_HELPER="$LAB_HELPER"
# The shim's own delegating call must not resolve `herdr` back to the shim.
export FM_LAB_ORIGINAL_PATH="$PATH"

FIX="$SCRATCH/home"
STATE="$FIX/state"
DATA="$FIX/data"
CONFIG="$FIX/config"
WORK="$SCRATCH/work"
mkdir -p "$STATE" "$DATA" "$CONFIG" "$WORK"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$FIX/.tasks.toml"
printf -- '- [ ] fixture\n' > "$DATA/backlog.md"

AUTOCLOSE="$ROOT/bin/fm-pane-autoclose.sh"
DELIVER="$ROOT/bin/fm-branch-outcome.sh"

# --- lab topology -----------------------------------------------------------
WS_JSON=$(lab workspace create --cwd "$WORK" --label fm-pane-autoclose --no-focus) \
  || fail "workspace create failed in the lab session"
WS=$(printf '%s' "$WS_JSON" | jq -r '.result.workspace.workspace_id // empty')
SIBLING_PANE=$(printf '%s' "$WS_JSON" | jq -r '.result.root_pane.pane_id // empty')
SIBLING_TAB=$(printf '%s' "$WS_JSON" | jq -r '.result.tab.tab_id // empty')
[ -n "$WS" ] && [ -n "$SIBLING_PANE" ] && [ -n "$SIBLING_TAB" ] \
  || fail "the lab workspace did not report its exact ids"

# create_tab <label> -> echoes "<tab-id> <pane-id>"
create_tab() {
  local out
  out=$(lab tab create --workspace "$WS" --cwd "$WORK" --label "$1" --no-focus) \
    || fail "tab create failed for $1"
  printf '%s %s\n' \
    "$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')" \
    "$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')"
}

focus_tab() { # <tab-id>
  lab tab focus "$1" >/dev/null || fail "tab focus failed for $1"
}

# herdr writes a not-found response to stderr, so both streams are captured and
# classified: only a structured pane body naming this exact pane counts as
# present, and anything else (not-found or unparseable) is not.
pane_present() { # <pane-id>
  local raw
  raw=$(lab pane get "$1" 2>&1) || true
  printf '%s' "$raw" | jq -e --arg p "$1" '.result.pane.pane_id == $p' >/dev/null 2>&1
}

status_ident() { # <status-file>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C stat -f '%d:%i' "$1" 2>/dev/null
  else
    LC_ALL=C stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

write_herdr_meta() { # <task> <workspace> <tab> <pane> [kind] [session-override]
  local task=$1 ws=$2 tab=$3 pane=$4 kind=${5:-scout} session=${6:-$LAB_SESSION}
  fm_write_meta "$STATE/$task.meta" \
    "window=$session:$pane" \
    "backend=herdr" \
    "endpoint_task_id=$task" \
    "kind=$kind" \
    "mode=no-mistakes" \
    "decisions_reviewed=1" \
    "decision_keys=" \
    "worktree=$WORK" \
    "project=$WORK" \
    "herdr_session=$session" \
    "herdr_workspace_id=$ws" \
    "herdr_tab_id=$tab" \
    "herdr_pane_id=$pane"
}

# add_in_flight_row <task>: a real backlog row left In flight, exactly as a
# delivered scout's row looks before its own close step.
add_in_flight_row() { # <task>
  local task=$1
  FM_HOME="$FIX" bash "$ROOT/bin/fm-tasks-axi.sh" add "$task" "fixture work" >/dev/null 2>&1 \
    || fail "could not add the $task board row"
  FM_HOME="$FIX" bash "$ROOT/bin/fm-tasks-axi.sh" start "$task" >/dev/null 2>&1 \
    || fail "could not start the $task board row"
  FM_HOME="$FIX" bash "$ROOT/bin/fm-tasks-axi.sh" show "$task" 2>/dev/null \
    | grep -F 'state: in_flight' >/dev/null \
    || fail "the $task board row is not In flight"
}

deliver() { # <task> <endpoint>
  PATH="$SHIM:$PATH" FM_HOME="$FIX" bash "$DELIVER" deliver --task "$1" \
    --status-ident "$(status_ident "$STATE/$1.status")" --endpoint "$2" 2>&1
}

autoclose() { # <task> <endpoint> [ident]
  PATH="$SHIM:$PATH" FM_HOME="$FIX" bash "$AUTOCLOSE" "$1" --endpoint "$2" \
    --status-ident "${3:-$(status_ident "$STATE/$1.status")}" 2>&1
}

# --- 1. completed scout: receipt on done:, row still In flight --------------
TASK=scout-finished
TAB_AND_PANE=$(create_tab target)
TARGET_TAB=${TAB_AND_PANE%% *}
TARGET_PANE=${TAB_AND_PANE##* }
[ -n "$TARGET_TAB" ] && [ -n "$TARGET_PANE" ] || fail "the target tab did not report its exact ids"
MARKER="$SCRATCH/closed-pane-process-file.txt"
lab pane run "$TARGET_PANE" "printf 'transcript-marker-alpha\n'; printf 'kept-on-disk\n' > $MARKER" >/dev/null \
  || fail "pane run failed in the target pane"
sleep 1
TRANSCRIPT="$SCRATCH/transcript-before-close.txt"
lab pane read "$TARGET_PANE" --source recent --lines 20 > "$TRANSCRIPT" 2>/dev/null || true
grep -F 'transcript-marker-alpha' "$TRANSCRIPT" >/dev/null \
  || fail "could not capture the target pane transcript before the close"
# A sibling marker proves the surviving session's own persisted history is not
# what closure touches.
SIBLING_MARKER='transcript-marker-beta'
lab pane run "$SIBLING_PANE" "printf '$SIBLING_MARKER\\n'" >/dev/null \
  || fail "pane run failed in the sibling pane"
sleep 1
SESSION_DIR=$(lab session list --json | jq -er --arg s "$LAB_SESSION" \
  '.sessions[] | select(.name == $s and .default == false) | .session_dir') \
  || fail "the lab session storage directory is unavailable"
HISTORY="$SESSION_DIR/session-history.json"
# Herdr persists a session history on its own cadence; wait for its own capture
# of both panes before the close, so the post-close assertions are about
# closure rather than about how soon Herdr flushed.
HISTORY_CAPTURED=0
for ((attempt = 0; attempt < 45; attempt++)); do
  if [ -f "$HISTORY" ] \
    && grep -Fq 'transcript-marker-alpha' "$HISTORY" \
    && grep -Fq "$SIBLING_MARKER" "$HISTORY"; then
    HISTORY_CAPTURED=1
    break
  fi
  sleep 2
done
[ "$HISTORY_CAPTURED" = 1 ] \
  || fail "Herdr persisted history did not capture both panes before the close"
focus_tab "$SIBLING_TAB"
write_herdr_meta "$TASK" "$WS" "$TARGET_TAB" "$TARGET_PANE" scout
mkdir -p "$DATA/$TASK"
printf 'report body\n' > "$DATA/$TASK/report.md"
printf 'working: scouting\n' > "$STATE/$TASK.status"
printf 'done: report ready at data/%s/report.md\n' "$TASK" >> "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
add_in_flight_row "$TASK"
OUT=$(deliver "$TASK" "$ENDPOINT") || fail "deliver failed for $TASK: $OUT"
assert_contains "$OUT" "closed: $TASK pane $LAB_SESSION:$TARGET_PANE" "the finished scout pane should close"
pane_present "$TARGET_PANE" && fail "the target pane should be gone after the close: $OUT"
pass "closes the pane after a scout done: receipt while its board row is In flight"

# --- 2. closure is a view operation: the session and transcripts survive ----
SESSION_JSON=$(lab session list --json)
printf '%s' "$SESSION_JSON" | jq -e --arg s "$LAB_SESSION" \
  '.sessions[] | select(.name == $s) | select(.running == true)' >/dev/null \
  || fail "the lab session must still be running after a pane close"
pane_present "$SIBLING_PANE" || fail "a sibling pane must survive the close"
SIBLING_READ=$(lab pane read "$SIBLING_PANE" --source recent --lines 5 2>&1)
case "$SIBLING_READ" in
  *"pane_not_found"*) fail "a sibling pane must still be readable after the close" ;;
esac
[ -f "$MARKER" ] || fail "the closed pane's process-owned file must persist"
grep -F 'kept-on-disk' "$MARKER" >/dev/null || fail "the closed pane's file content must persist"
# Closure must not destroy the persisted history at the moment it closes: both
# pane texts are still in Herdr's own file immediately after the close.
grep -Fq 'transcript-marker-alpha' "$HISTORY" \
  || fail "the close must not drop the closed pane's persisted text"
grep -Fq "$SIBLING_MARKER" "$HISTORY" \
  || fail "the close must not drop the surviving pane's persisted text"
IMMEDIATE_HISTORY="$SCRATCH/history-after-close.json"
cp "$HISTORY" "$IMMEDIATE_HISTORY"
# Herdr 0.9.3 rewrites this file on its next flush with the live panes only, so
# a closed pane leaves the persisted history then. That rewrite is Herdr's own
# behaviour, measured here, not something this close path controls; the test
# waits for one flush to prove the surviving pane's history is what durability
# covers.
history_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}
BEFORE_MTIME=$(history_mtime "$HISTORY") || fail "cannot read Herdr history mtime"
FLUSHED=0
for ((attempt = 0; attempt < 60; attempt++)); do
  sleep 2
  CURRENT_MTIME=$(history_mtime "$HISTORY") || continue
  if [ "$CURRENT_MTIME" != "$BEFORE_MTIME" ]; then
    FLUSHED=1
    break
  fi
done
[ "$FLUSHED" = 1 ] || fail "Herdr did not flush its persisted history within 120s"
grep -Fq "$SIBLING_MARKER" "$HISTORY" \
  || fail "a surviving pane's persisted history must survive Herdr's next flush"
printf '%s' "$(lab session list --json)" | jq -e --arg s "$LAB_SESSION" \
  '.sessions[] | select(.name == $s) | select(.running == true)' >/dev/null \
  || fail "the lab session must still be running after Herdr's next flush"
if [ -n "${FM_PANE_AUTOCLOSE_ARTIFACT_DIR:-}" ]; then
  mkdir -p "$FM_PANE_AUTOCLOSE_ARTIFACT_DIR"
  cp "$TRANSCRIPT" "$FM_PANE_AUTOCLOSE_ARTIFACT_DIR/herdr-lab-transcript-before-close.txt"
  cp "$IMMEDIATE_HISTORY" \
    "$FM_PANE_AUTOCLOSE_ARTIFACT_DIR/herdr-lab-history-immediately-after-close.json"
  cp "$HISTORY" "$FM_PANE_AUTOCLOSE_ARTIFACT_DIR/herdr-lab-history-after-next-flush.json"
fi
pass "closure keeps Herdr's persisted history intact; the session survives the next flush"

# --- 3. a failed: receipt keeps the pane -------------------------------------
TASK=scout-failed
TAB_AND_PANE=$(create_tab failed)
FAILED_TAB=${TAB_AND_PANE%% *}
FAILED_PANE=${TAB_AND_PANE##* }
focus_tab "$SIBLING_TAB"
write_herdr_meta "$TASK" "$WS" "$FAILED_TAB" "$FAILED_PANE" scout
printf 'working: scouting\n' > "$STATE/$TASK.status"
printf 'failed: the corpus could not be read\n' >> "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
add_in_flight_row "$TASK"
OUT=$(deliver "$TASK" "$ENDPOINT") || fail "deliver failed for $TASK: $OUT"
assert_contains "$OUT" "kept: $TASK" "a failure receipt must keep the pane"
assert_contains "$OUT" "not a done: claim" "the keep reason should name the verb"
pane_present "$FAILED_PANE" || fail "a failed: receipt must keep the pane a supervisor needs"
pass "keeps the pane for a failed: receipt"

# expect_keep <task> <pane> <reason-substring> <label>: deliver the recorded
# ENDPOINT and assert the pane survives for the named reason.
expect_keep() { # <task> <pane> <reason-substring> <label>
  local task=$1 pane=$2 needle=$3 label=$4 out
  out=$(deliver "$task" "$ENDPOINT") || fail "deliver failed for $task: $out"
  assert_contains "$out" "kept: $task" "$label: the pane must be kept"
  assert_contains "$out" "$needle" "$label: the keep reason should name '$needle'"
  pane_present "$pane" || fail "$label: the pane must still be present"
}

# --- 4. every follow-on-work exclusion keeps the pane ------------------------
# A keyed decision or blocker still open in the status fold.
TASK=scout-open-decision
TAB_AND_PANE=$(create_tab open-decision)
OD_TAB=${TAB_AND_PANE%% *}
OD_PANE=${TAB_AND_PANE##* }
focus_tab "$SIBLING_TAB"
write_herdr_meta "$TASK" "$WS" "$OD_TAB" "$OD_PANE" scout
{
  printf 'working: scouting\n'
  printf 'needs-decision [key=corpus-scope]: include the annex?\n'
  printf 'done: report ready at data/%s/report.md\n' "$TASK"
} > "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
expect_keep "$TASK" "$OD_PANE" "open keyed decision" "an open keyed decision"
pass "keeps the pane while a keyed decision is still open"

TASK=scout-open-blocker
TAB_AND_PANE=$(create_tab open-blocker)
OB_TAB=${TAB_AND_PANE%% *}
OB_PANE=${TAB_AND_PANE##* }
focus_tab "$SIBLING_TAB"
write_herdr_meta "$TASK" "$WS" "$OB_TAB" "$OB_PANE" scout
{
  printf 'working: scouting\n'
  printf 'blocked [key=corpus-access]: waiting for access\n'
  printf 'done: report ready at data/%s/report.md\n' "$TASK"
} > "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
expect_keep "$TASK" "$OB_PANE" "open keyed decision or blocker" "an open keyed blocker"
pass "keeps the pane while a keyed blocker is still open"

TASK=scout-blocked-row
TAB_AND_PANE=$(create_tab blocked-row)
BR_TAB=${TAB_AND_PANE%% *}
BR_PANE=${TAB_AND_PANE##* }
focus_tab "$SIBLING_TAB"
write_herdr_meta "$TASK" "$WS" "$BR_TAB" "$BR_PANE" scout
printf 'done: report ready at data/%s/report.md\n' "$TASK" > "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
add_in_flight_row "$TASK"
FM_HOME="$FIX" bash "$ROOT/bin/fm-tasks-axi.sh" add corpus-access "fixture dependency" >/dev/null 2>&1 \
  || fail "could not add the blocking dependency"
FM_HOME="$FIX" bash "$ROOT/bin/fm-tasks-axi.sh" block "$TASK" --by corpus-access >/dev/null 2>&1 \
  || fail "could not block the $TASK board row"
expect_keep "$TASK" "$BR_PANE" "blocked or held backlog row" "a blocked board row"
pass "keeps the pane while the board row is blocked"

TASK=ship-local-only
TAB_AND_PANE=$(create_tab local-only)
LO_TAB=${TAB_AND_PANE%% *}
LO_PANE=${TAB_AND_PANE##* }
focus_tab "$SIBLING_TAB"
write_herdr_meta "$TASK" "$WS" "$LO_TAB" "$LO_PANE" ship
printf 'mode=local-only\n' >> "$STATE/$TASK.meta"
printf 'done: ready in branch fm/%s\n' "$TASK" > "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
expect_keep "$TASK" "$LO_PANE" "local-only completion never autocloses" "a local-only completion"
pass "keeps local-only completions in the guarded lab"

TASK=scout-linked-hold
TAB_AND_PANE=$(create_tab linked-hold)
LH_TAB=${TAB_AND_PANE%% *}
LH_PANE=${TAB_AND_PANE##* }
focus_tab "$SIBLING_TAB"
write_herdr_meta "$TASK" "$WS" "$LH_TAB" "$LH_PANE" scout
FM_HOME="$FIX" bash "$ROOT/bin/fm-captain-hold.sh" hold linked-call --title "Choose corpus" \
  --reason "scope needs captain" >/dev/null || fail "could not create the linked captain call"
FM_HOME="$FIX" bash "$ROOT/bin/fm-captain-hold.sh" complete "$TASK" linked-call >/dev/null \
  || fail "could not inventory the linked captain call"
printf 'done: report ready at data/%s/report.md\n' "$TASK" > "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
expect_keep "$TASK" "$LH_PANE" "linked captain-call inventory" "a linked captain-held task"
pass "keeps the pane while a linked captain call awaits an answer"

# A linked external request.
TASK=scout-ext-link
TAB_AND_PANE=$(create_tab ext-link)
EXT_TAB=${TAB_AND_PANE%% *}
EXT_PANE=${TAB_AND_PANE##* }
focus_tab "$SIBLING_TAB"
write_herdr_meta "$TASK" "$WS" "$EXT_TAB" "$EXT_PANE" scout
printf 'ext_request=ext-fixture\next_followups=0\n' >> "$STATE/$TASK.meta"
printf 'done: report ready at data/%s/report.md\n' "$TASK" > "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
expect_keep "$TASK" "$EXT_PANE" "linked external request" "a linked external request"
pass "keeps the pane while an external request is linked"

# An open routed reply.
TASK=scout-pending-reply
TAB_AND_PANE=$(create_tab pending-reply)
PR_TAB=${TAB_AND_PANE%% *}
PR_PANE=${TAB_AND_PANE##* }
focus_tab "$SIBLING_TAB"
write_herdr_meta "$TASK" "$WS" "$PR_TAB" "$PR_PANE" scout
mkdir -p "$STATE/pending-replies"
fm_write_meta "$STATE/pending-replies/corr-fixture" "task_id=$TASK" "phase=awaiting_report"
printf 'done: report ready at data/%s/report.md\n' "$TASK" > "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
expect_keep "$TASK" "$PR_PANE" "open routed reply" "an open routed reply"
pass "keeps the pane while a routed reply is open"

# An armed custom watcher check.
TASK=scout-armed-check
TAB_AND_PANE=$(create_tab armed-check)
AC_TAB=${TAB_AND_PANE%% *}
AC_PANE=${TAB_AND_PANE##* }
focus_tab "$SIBLING_TAB"
write_herdr_meta "$TASK" "$WS" "$AC_TAB" "$AC_PANE" scout
printf '#!/usr/bin/env bash\nexit 0\n' > "$STATE/$TASK.check.sh"
printf 'done: report ready at data/%s/report.md\n' "$TASK" > "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
expect_keep "$TASK" "$AC_PANE" "armed or intended custom check" "an armed check"
pass "keeps the pane while a custom watcher check is armed"

# A held board row.
TASK=scout-held-row
TAB_AND_PANE=$(create_tab held-row)
HR_TAB=${TAB_AND_PANE%% *}
HR_PANE=${TAB_AND_PANE##* }
focus_tab "$SIBLING_TAB"
write_herdr_meta "$TASK" "$WS" "$HR_TAB" "$HR_PANE" scout
printf 'done: report ready at data/%s/report.md\n' "$TASK" > "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
FM_HOME="$FIX" bash "$ROOT/bin/fm-tasks-axi.sh" add "$TASK" "fixture work" >/dev/null 2>&1 \
  || fail "could not add the $TASK board row"
FM_HOME="$FIX" bash "$ROOT/bin/fm-tasks-axi.sh" start "$TASK" >/dev/null 2>&1 \
  || fail "could not start the $TASK board row"
FM_HOME="$FIX" bash "$ROOT/bin/fm-tasks-axi.sh" hold "$TASK" --reason "captain decision pending" \
  --kind captain >/dev/null 2>&1 || fail "could not hold the $TASK board row"
expect_keep "$TASK" "$HR_PANE" "blocked or held backlog row" "a held board row"
pass "keeps the pane while the board row is held"

# --- 5. the captain's active tab is never closed -----------------------------
TASK=scout-active-tab
TAB_AND_PANE=$(create_tab active)
ACTIVE_TAB=${TAB_AND_PANE%% *}
ACTIVE_PANE=${TAB_AND_PANE##* }
focus_tab "$ACTIVE_TAB"
write_herdr_meta "$TASK" "$WS" "$ACTIVE_TAB" "$ACTIVE_PANE" scout
printf 'done: report ready at data/%s/report.md\n' "$TASK" > "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
OUT=$(deliver "$TASK" "$ENDPOINT") || fail "deliver failed for $TASK: $OUT"
assert_contains "$OUT" "kept: $TASK" "an active-tab refusal is a keep"
assert_contains "$OUT" "pane close was refused" "the keep reason should name the refusal"
pane_present "$ACTIVE_PANE" || fail "the captain's active tab must never be closed"
pass "never closes the captain's active tab"

# --- 6. a delegated primary-home promise keeps the pane ---------------------
# The promise is registered in the PARENT home for secondmate:alice/<task>, the
# shape a secondmate home's own delivery must still honour. This runs against
# real tasks-axi, so it is skipped when the binary is unavailable.
REAL_TASKS_AXI=$(command -v tasks-axi || true)
if [ -z "$REAL_TASKS_AXI" ]; then
  echo "skip: tasks-axi not found for delegated public-commitment lab coverage"
else
  TASK=scout-delegated
  TAB_AND_PANE=$(create_tab delegated)
  DELEG_TAB=${TAB_AND_PANE%% *}
  DELEG_PANE=${TAB_AND_PANE##* }
  focus_tab "$SIBLING_TAB"
  PARENT="$SCRATCH/primary"
  mkdir -p "$PARENT/state" "$PARENT/data" "$PARENT/config"
  cp "$FIX/.tasks.toml" "$PARENT/.tasks.toml"
  printf -- '- [ ] fixture\n' > "$PARENT/data/backlog.md"
  printf 'alice\n' > "$FIX/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" \
    > "$FIX/.fm-secondmate-parent"
  fm_write_meta "$PARENT/state/alice.meta" "kind=secondmate" "home=$FIX"
  printf -- '- alice - fixture (home: %s; scope: fixture; projects: ; added 2026-10-29)\n' "$FIX" \
    > "$PARENT/data/secondmates.md"
  printf 'FMX_PAIRING_TOKEN=fixture-token\n' > "$PARENT/.env"
  jq -n '{request_id:"req-delegated", platform:"x", context_binding:{version:"ctx1", value:"ctx1_req-delegated"},
    public_safe_summary:"report the delegated scout result", received_at:"2026-10-29T00:00:00Z",
    followup_expires_at:"2099-01-01T00:00:00Z", reservation_expires_at:"2099-01-01T00:00:00Z"}' \
    > "$SCRATCH/request.json"
  jq -n '{type:"report-ready", project:"firstmate", required_deliverables:["report_path"], completion_policy:"all-required"}' \
    > "$SCRATCH/expected.json"
  jq -n '{relation_id:"rel-delegated", work_ref:{home_id:"secondmate:alice", task_id:"scout-delegated"}, role:"fulfills", required:true, generation:1}' \
    > "$SCRATCH/relation.json"
  FM_HOME="$PARENT" bash "$ROOT/bin/fm-tasks-axi.sh" public-followup add promise-delegated \
    --request-context-file "$SCRATCH/request.json" --purpose promised-final \
    --expected-final-file "$SCRATCH/expected.json" --expires-at 2099-01-01T00:00:00Z >/dev/null 2>&1 \
    || fail "could not create the delegated public commitment"
  FM_HOME="$PARENT" bash "$ROOT/bin/fm-tasks-axi.sh" public-followup bind-work promise-delegated \
    --relation-file "$SCRATCH/relation.json" >/dev/null 2>&1 \
    || fail "could not bind the delegated public commitment"
  FM_HOME="$PARENT" bash "$ROOT/bin/fm-public-followup.sh" register promise-delegated \
    --relation rel-delegated --work-home secondmate:alice --work-id "$TASK" --generation 1 >/dev/null 2>&1 \
    || fail "could not register the delegated public commitment"
  write_herdr_meta "$TASK" "$WS" "$DELEG_TAB" "$DELEG_PANE" scout
  printf 'done: report ready at data/%s/report.md\n' "$TASK" > "$STATE/$TASK.status"
  ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
  OUT=$(FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$PARENT" deliver "$TASK" "$ENDPOINT") \
    || fail "deliver failed for $TASK: $OUT"
  assert_contains "$OUT" "kept: $TASK" "a delegated promise must keep the pane"
  assert_contains "$OUT" "unresolved public commitment" "the keep reason should name the promise"
  pane_present "$DELEG_PANE" || fail "a promise registered in the primary home must keep this pane"
  pass "keeps the pane for a promise the primary home holds for a secondmate task"
fi

# --- 7. an ambiguous endpoint refuses loudly --------------------------------
TASK=scout-ambiguous
TAB_AND_PANE=$(create_tab ambiguous)
AMBIG_TAB=${TAB_AND_PANE%% *}
AMBIG_PANE=${TAB_AND_PANE##* }
focus_tab "$SIBLING_TAB"
# The recorded window and the recorded pane id disagree, so the exact endpoint
# cannot be resolved and the walk must refuse rather than guess.
fm_write_meta "$STATE/$TASK.meta" \
  "window=$LAB_SESSION:999:p999" \
  "backend=herdr" \
  "endpoint_task_id=$TASK" \
  "kind=scout" \
  "mode=no-mistakes" \
  "decisions_reviewed=1" \
  "decision_keys=" \
  "worktree=$WORK" \
  "project=$WORK" \
  "herdr_session=$LAB_SESSION" \
  "herdr_workspace_id=$WS" \
  "herdr_tab_id=$AMBIG_TAB" \
  "herdr_pane_id=$AMBIG_PANE"
printf 'done: report ready at data/%s/report.md\n' "$TASK" > "$STATE/$TASK.status"
ENDPOINT=$(wc -c < "$STATE/$TASK.status" | tr -d ' ')
if OUT=$(autoclose "$TASK" "$ENDPOINT" 2>&1); then RC=0; else RC=$?; fi
[ "$RC" = 2 ] || fail "an ambiguous endpoint must refuse with exit 2 (got $RC): $OUT"
assert_contains "$OUT" "REFUSED" "the refusal should be explicit"
pane_present "$AMBIG_PANE" || fail "an ambiguous endpoint must never close a pane"
pass "refuses loudly on an ambiguous endpoint and closes nothing"
