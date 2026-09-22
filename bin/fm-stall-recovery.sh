#!/usr/bin/env bash
# fm-stall-recovery.sh - custody-checked bounded auto-recovery for a stalled
# worker, invoked by bin/fm-watch.sh at the two points where a durable steering
# instruction has provably outlived its delivery budget: a spent re-ring ladder
# on an idle pane, or a positively dead/missing endpoint that bypasses the
# ladder.
#
# Usage: fm-stall-recovery.sh <task-id> <record-path> <trigger>
#   <trigger> is endpoint-unavailable (dead/missing endpoint) or
#   ladder-exhausted (delivery attempts spent on an idle pane).
#
# Output contract: exactly one line, "verdict=<v> detail=<one-line reason>".
#   recovered  - the instruction was already handled; nothing to do.
#   deferred   - no lifecycle action taken and none needed right now: the
#                record was handled between the watcher's decision and this
#                check, the worker is provably busy, or a relaunch was just
#                published and the episode stays pending until the record is
#                handled or the ladder re-escalates.
#   escalate   - recovery is unsafe, unproven, or exhausted; the caller keeps
#                the ordinary stale wake. Any non-zero exit or missing verdict
#                is also treated as escalate by the caller.
#
# What "safe" means here (every check fails closed to escalate):
#   - The named record is still the oldest UNHANDLED inbox record. Transport
#     receipts (.acked/.unproven/.awaiting-turn under the doorbell request dir)
#     are never consulted: a stale receipt neither triggers nor suppresses
#     recovery, and a record moved to handled/ at any point cancels the action.
#   - The endpoint is positively classified: dead/missing takes the
#     missing-endpoint path (no exit is sent; the launch owner recreates the
#     endpoint), alive takes the live-non-turning path (the old agent is
#     exited first). Ambiguous, unreadable, or unverified states escalate.
#   - A live endpoint must also read an explicit idle busy verdict; busy
#     defers (the worker may be mid-turn on the instruction) and unknown
#     escalates (a probe failure is not custody proof).
#   - fm-crew-state must show no active validation run: working, parked,
#     blocked, and declared-paused states all escalate (a parked gate, a
#     declared external wait, and a worker-declared blocker are firstmate
#     business, not stall recovery). Terminal done/failed may proceed, and
#     unknown may proceed only on the missing-endpoint path.
#   - The recorded worktree must be clean AND hold no commit absent from every
#     remote-tracking ref (local-only mode instead requires every commit
#     merged into the local default branch). Unlanded work blocks automatic
#     action and escalates; the check is local-only - no gh or fetch - so the
#     watcher can never hang on a remote.
#   - One automatic relaunch per stalled instruction: the per-record attempt
#     marker under the inbox bounds retries, and an emptied inbox resets it.
#   - The durable fm-<id> worktree lease, same-worktree/branch/commits
#     preservation, and the no-shared-daemon boundary are enforced by
#     bin/fm-control.sh relaunch itself; this script never moves inbox
#     records, never writes new inbox records, and never touches the
#     no-mistakes daemon.
#
# A published relaunch is deliberately NOT reported as recovered: it is a
# pending episode. The durable instruction's terminal outcome is either its
# handled/ move (quiet) or the bounded re-escalation the reset ladder produces
# when the replacement also fails to act.
#
# Audit: every verdict appends one line to state/<id>.stall-recovery; the
# relaunch transaction itself journals to state/<id>.control-relaunch, and a
# note: line on state/<id>.status records the published recovery.
#
# Tunables (env):
#   FM_STALL_RECOVERY_MAX      automatic relaunches per stalled record (1)
#   FM_CREW_STATE_BIN          crew-state executable override (tests)
#   FM_STALL_RECOVERY_CONTROL_BIN  lifecycle executable override (tests)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-worktree-clean-lib.sh
. "$SCRIPT_DIR/fm-worktree-clean-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
FM_STALL_RECOVERY_CONTROL_BIN="${FM_STALL_RECOVERY_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"

ID=${1:-}
RECORD=${2:-}
TRIGGER=${3:-}
JOURNAL="$STATE/$ID.stall-recovery"
STATUS_FILE="$STATE/$ID.status"

journal() {  # <detail...>
  {
    printf 'ts=%s id=%s trigger=%s record=%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ID" "$TRIGGER" "${RECORD##*/}"
    printf ' %s\n' "$*"
  } >> "$JOURNAL" 2>/dev/null || true
}

verdict() {  # <verdict> <detail>
  journal "verdict=$1 detail=$2"
  printf 'verdict=%s detail=%s\n' "$1" "$2"
  exit 0
}

status_note() {  # <line>
  [ -f "$STATUS_FILE" ] || [ -d "$STATE" ] || return 0
  printf 'note: %s\n' "$1" >> "$STATUS_FILE" 2>/dev/null || true
}

# --- eligibility gates ------------------------------------------------------
case "$ID" in ''|*[!A-Za-z0-9._-]*) verdict escalate "invalid task id" ;; esac
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || verdict escalate "no task metadata"
KIND=$(fm_meta_get "$META" kind)
case "$KIND" in ''|ship|scout) ;; *) verdict escalate "kind=$KIND is not an ordinary direct report" ;; esac
[ -z "$(fm_meta_get "$META" remote_host)" ] || verdict escalate "remote placement; recover on its own host"

# The named record must still be the oldest unhandled instruction. A record
# that moved to handled/ (or an emptied inbox) ends the episode quietly.
dir=$(fm_task_inbox_dir "$STATE" "$ID")
oldest=$(fm_task_inbox_oldest_unhandled "$STATE" "$ID" 2>/dev/null || true)
if [ -z "$oldest" ]; then
  verdict recovered "inbox empty; instruction already handled"
fi
if [ "$oldest" != "$RECORD" ]; then
  verdict deferred "record ${RECORD##*/} no longer the oldest unhandled (${oldest##*/} is); late handling cancels this action"
fi

# prove_custody: re-prove every precondition for a lifecycle action against
# CURRENT state - endpoint classification, busy verdict, crew/run state,
# worktree cleanliness, landed work, and the durable fm-<id> lease. Called
# directly (never in a command substitution) so its PATH_KIND, WT, MODE,
# PROJ, BACKEND, and TARGET bindings reach the caller; the refusal reason is
# published through the CUSTODY_DETAIL global. Returns 1 on any failed or
# unprovable check, 2 when the worker is provably busy (a defer, not an
# escalation), 0 on success. All reads are local: no gh or fetch can ever
# stall the watcher.
prove_custody() {
  local state busy crew_line crew_state unpushed unmerged default_ref cand pool_state lease_holder
  PATH_KIND=
  CUSTODY_DETAIL=
  WT=$(fm_meta_get "$META" worktree)
  MODE=$(fm_meta_get "$META" mode)
  PROJ=$(fm_meta_get "$META" project)
  fm_backend_validate_task_endpoint "$META" "$ID" >/dev/null 2>&1 \
    || { CUSTODY_DETAIL='endpoint metadata failed validation'; return 1; }
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  TARGET=$FM_BACKEND_VALIDATED_TARGET
  state=$(fm_backend_agent_state "$BACKEND" "$TARGET" "$META" 2>/dev/null || printf 'unreadable')
  case "$state" in
    alive)        PATH_KIND=live-non-turning ;;
    dead|missing) PATH_KIND=missing-endpoint ;;
    *) CUSTODY_DETAIL="endpoint state '$state' is not positively classified"; return 1 ;;
  esac
  if [ "$PATH_KIND" = live-non-turning ]; then
    busy=$(fm_busy_classify_meta "$META" "$ID" "$STATE" 2>/dev/null || printf 'unknown')
    case "${busy%% *}" in
      idle) ;;
      busy) CUSTODY_DETAIL="worker is busy ($busy); it may be mid-turn on the instruction"; return 2 ;;
      *)    CUSTODY_DETAIL="busy verdict '$busy' is not a custody proof"; return 1 ;;
    esac
  fi
  crew_line=$("$FM_CREW_STATE_BIN" "$ID" 2>/dev/null || true)
  crew_state=$(printf '%s' "$crew_line" | sed -n 's/^state: \([a-z-]*\).*/\1/p' | head -1)
  case "$crew_state" in
    working|parked|blocked|paused)
      CUSTODY_DETAIL="crew-state $crew_state needs firstmate, not auto-relaunch"; return 1 ;;
    done|failed) ;;
    unknown)
      [ "$PATH_KIND" = missing-endpoint ] \
        || { CUSTODY_DETAIL='crew-state unknown with a live endpoint is ambiguous'; return 1; } ;;
    *) CUSTODY_DETAIL="crew-state '${crew_state:-unreadable}' is not a clean non-run state"; return 1 ;;
  esac
  [ -n "$WT" ] && [ -d "$WT" ] || { CUSTODY_DETAIL='recorded worktree missing'; return 1; }
  fm_worktree_is_clean "$WT" || { CUSTODY_DETAIL='worktree has uncommitted changes'; return 1; }
  if [ "$MODE" = local-only ]; then
    default_ref=
    for cand in main master; do
      if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$cand" 2>/dev/null; then
        default_ref=$cand
        break
      fi
    done
    [ -n "$default_ref" ] || { CUSTODY_DETAIL='local-only task has no resolvable default branch'; return 1; }
    unmerged=$(git -C "$WT" log --format=%H HEAD --not "$default_ref" -- 2>/dev/null) \
      || { CUSTODY_DETAIL="cannot inspect worktree commits against $default_ref"; return 1; }
    [ -z "$unmerged" ] || { CUSTODY_DETAIL="local-only worktree has commits not merged into $default_ref"; return 1; }
  else
    unpushed=$(git -C "$WT" log --format=%H HEAD --not --remotes -- 2>/dev/null) \
      || { CUSTODY_DETAIL='cannot inspect worktree commits against remotes'; return 1; }
    [ -z "$unpushed" ] || { CUSTODY_DETAIL='worktree has commits not on any remote-tracking ref'; return 1; }
  fi
  # The durable fm-<id> lease proof mirrors bin/fm-spawn.sh's
  # relaunch_worktree_lease_proven, applied to BOTH paths here because the
  # launch owner only re-proves it on the gone-endpoint path.
  fm_treehouse_pool_slot "$PROJ" "$WT" \
    || { CUSTODY_DETAIL='recorded worktree is not a Treehouse pool slot of the recorded project'; return 1; }
  fm_treehouse_slot_owner_state "$WT" "$ID"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    mine|absent) ;;
    other) CUSTODY_DETAIL="pool slot is claimed by task ${FM_TREEHOUSE_SLOT_OWNER_ID:-unknown}"; return 1 ;;
    *)     CUSTODY_DETAIL='slot-owner claim cannot be read safely'; return 1 ;;
  esac
  command -v jq >/dev/null 2>&1 \
    || { CUSTODY_DETAIL='jq is required to verify the durable worktree lease'; return 1; }
  pool_state="$(dirname "$(dirname "$(cd "$WT" && pwd -P)")")/treehouse-state.json"
  lease_holder=$(jq -r --arg p "$(cd "$WT" && pwd -P)" \
    '.worktrees[]? | select(.path == $p and .leased == true) | .lease_holder // empty' \
    "$pool_state" 2>/dev/null || true)
  [ "$lease_holder" = "fm-$ID" ] \
    || { CUSTODY_DETAIL="recorded worktree has no durable Treehouse lease held by fm-$ID"; return 1; }
  return 0
}

# Gate proof: full custody chain before any lifecycle decision.
prove_custody || case $? in
  2) verdict deferred "$CUSTODY_DETAIL" ;;
  *) verdict escalate "$CUSTODY_DETAIL" ;;
esac

# Bounded retry: one automatic relaunch per stalled instruction record.
max_attempts=${FM_STALL_RECOVERY_MAX:-1}
case "$max_attempts" in ''|*[!0-9]*) max_attempts=1 ;; esac
attempts_file="$dir/.recovery-attempts"
attempts_record= attempts_count=0
IFS=$(printf '\t') read -r attempts_record attempts_count <<EOF
$(cat "$attempts_file" 2>/dev/null || true)
EOF
[ "$attempts_record" = "${RECORD##*/}" ] || attempts_count=0
case "$attempts_count" in ''|*[!0-9]*) attempts_count=0 ;; esac
[ "$attempts_count" -lt "$max_attempts" ] \
  || verdict escalate "automatic recovery already attempted for ${RECORD##*/}; escalating per bounded-retry policy"

# Final re-check immediately before the lifecycle action, in strict order:
# re-prove the full custody chain (a worker can become busy, enter a run, or
# lose its worktree between the first proof and the relaunch), then re-prove
# the record itself LAST so a handled move during the custody probe still
# cancels the action.
prove_custody || case $? in
  2) verdict deferred "$CUSTODY_DETAIL" ;;
  *) verdict escalate "$CUSTODY_DETAIL" ;;
esac
oldest=$(fm_task_inbox_oldest_unhandled "$STATE" "$ID" 2>/dev/null || true)
[ -n "$oldest" ] || verdict recovered "inbox emptied before relaunch; instruction handled"
[ "$oldest" = "$RECORD" ] || verdict deferred "record ${RECORD##*/} handled or superseded before relaunch"

# --- bounded lifecycle action ------------------------------------------------

unhandled=$(cd "$dir" 2>/dev/null && printf '%s ' *.msg 2>/dev/null || true)
note="Stall auto-recovery ($TRIGGER, $PATH_KIND): the previous worker stopped acting on doorbells while instruction(s) ${unhandled:-${RECORD##*/}} stayed unhandled. The worktree, branch, and commits are exactly as that worker left them; nothing was discarded. Read and act on the inbox first."
printf '%s\t%s\n' "${RECORD##*/}" "$((attempts_count + 1))" > "$attempts_file" 2>/dev/null \
  || verdict escalate "cannot persist the recovery-attempt bound at $attempts_file"

control_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" \
  "$FM_STALL_RECOVERY_CONTROL_BIN" "$ID" relaunch --note "$note" 2>&1) \
  || verdict escalate "fm-control relaunch refused or failed: $(printf '%s' "$control_out" | tail -1)"

# The replacement owns the instruction now. Reset the delivery ladder so the
# new incarnation gets the full grace-and-retry budget before the bounded
# escalation fires again; the episode stays pending until the record is
# handled or that escalation lands. A reset failure loses that bookkeeping,
# so it escalates rather than reporting a pending relaunch.
fm_task_inbox_ladder_reset "$STATE" "$ID" \
  || verdict escalate "relaunch published but the re-ring ladder could not be reset; the spent budget would escalate the new worker immediately"
status_note "stall auto-recovery relaunched the worker ($PATH_KIND, trigger $TRIGGER); instruction ${RECORD##*/} still pending until handled"
verdict deferred "relaunch published ($PATH_KIND); episode pending until ${RECORD##*/} is handled or the ladder re-escalates"
