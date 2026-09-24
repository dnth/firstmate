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
#                check, or a relaunch was just published and the episode
#                stays pending until the record is handled or the ladder
#                re-escalates.
#   escalate   - recovery is unsafe, unproven, exhausted, or the endpoint is
#                LIVE: recovery never interrupts, exits, or relaunches a live
#                worker, so a live-but-non-turning session is detected and
#                escalated for firstmate and nothing is sent to it. Any
#                non-zero exit or missing verdict is also treated as escalate
#                by the caller.
#
# What "safe" means here (every check fails closed to escalate):
#   - The named record is still the oldest UNHANDLED inbox record. Transport
#     receipts (.acked/.unproven/.awaiting-turn under the doorbell request dir)
#   - The endpoint is positively classified: dead/missing takes the
#     missing-endpoint path (no exit is sent; the launch owner recreates the
#     endpoint, and no busy-state proof is required because there is no live
#     worker to interrupt). A live endpoint escalates unconditionally -
#     interrupting or relaunching a session that exists is never recovery's
#     call. Ambiguous, unreadable, or unverified states escalate.
#   - fm-crew-state must show no active validation run: working, parked,
#     blocked, and declared-paused states all escalate (a parked gate, a
#     declared external wait, and a worker-declared blocker are firstmate
#     business, not stall recovery). Terminal done/failed may proceed on the
#     missing-endpoint path; unknown or unreadable crew-state fails closed -
#     missing, unknown, unproven, and stale custody all refuse and escalate.
#   - The recorded worktree must exist and carry the durable fm-<id> lease;
#     uncommitted changes and unpushed commits inside it are PRESERVED, not
#     rejected: the stalled worker's unlanded work is exactly what recovery
#     exists to keep, and the relaunch inherits the same worktree, branch,
#     and commits untouched.
#   - One automatic relaunch per stalled instruction on the missing-endpoint
#     path: the per-record attempt marker under the inbox bounds retries; an
#     emptied inbox resets it, and a well-formed marker naming a record that
#     was since handled starts the new oldest record's own count at zero.
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
# The final custody and inbox-record re-check on the missing-endpoint path
# runs INSIDE fm-control's lifecycle lock (state/.control-<id>.lock), acquired
# by this process and held across the fm-control invocation via
# --lock-preheld: a record handled in the gap can never relaunch, and a
# concurrent invocation or manual lifecycle action can never double-relaunch.
# The per-record attempt bound is checked and recorded under the same lock.
#
# Audit: every verdict appends one line to state/<id>.stall-recovery; the
# relaunch transaction itself journals to state/<id>.control-relaunch, and a
# note: line on state/<id>.status records the published recovery.
#
# Tunables (env):
#   FM_CREW_STATE_BIN          crew-state executable override (tests)
#   FM_STALL_RECOVERY_CONTROL_BIN  lifecycle executable override (tests)
#
# The one-relaunch-per-record bound is a fixed invariant, not a tunable.
set -u

# Release the lifecycle lock on every exit path, including verdict exits.
STALL_LOCK=
STALL_LOCK_HELD=0
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
stall_cleanup() {
  if [ "$STALL_LOCK_HELD" = 1 ]; then
    STALL_LOCK_HELD=0
    fm_lock_release "$STALL_LOCK" 2>/dev/null || true
  fi
}
trap stall_cleanup EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
FM_STALL_RECOVERY_CONTROL_BIN="${FM_STALL_RECOVERY_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"

ID=${1:-}
RECORD=${2:-}
TRIGGER=${3:-}
JOURNAL="$STATE/stall-recovery-invalid"

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
JOURNAL="$STATE/$ID.stall-recovery"
STATUS_FILE="$STATE/$ID.status"
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || verdict escalate "no task metadata"
KIND=$(fm_meta_get "$META" kind)
case "$KIND" in ''|ship|scout) ;; *) verdict escalate "kind=$KIND is not an ordinary direct report" ;; esac
[ -z "$(fm_meta_get "$META" remote_host)" ] || verdict escalate "remote placement; recover on its own host"

# The named record must still be the oldest unhandled instruction. A record
# that moved to handled/ (or an emptied inbox) ends the episode quietly.
dir=$(fm_task_inbox_dir "$STATE" "$ID")
if oldest=$(fm_task_inbox_oldest_unhandled "$STATE" "$ID" 2>/dev/null); then
  :
else
  oldest_rc=$?
  [ "$oldest_rc" -eq 1 ] && verdict recovered "inbox empty; instruction already handled"
  verdict escalate "inbox unreadable; refusing recovery"
fi
if [ "$oldest" != "$RECORD" ]; then
  verdict deferred "record ${RECORD##*/} no longer the oldest unhandled (${oldest##*/} is); late handling cancels this action"
fi

# prove_custody: re-prove every precondition for a lifecycle action against
# CURRENT state - endpoint classification, crew/run state, worktree
# existence, and the durable fm-<id> lease. Called directly (never in a
# command substitution) so its PATH_KIND, WT, PROJ, BACKEND, and TARGET
# bindings reach the caller; the refusal reason is published through the
# CUSTODY_DETAIL global. Returns 1 on any failed or unprovable check -
# including a LIVE endpoint, which escalates because recovery never
# interrupts a session that exists - and 0 only on the missing-endpoint path
# with every custody proof clean. All reads are local: no gh or fetch can
# ever stall the watcher.
#
# Uncommitted changes and unpushed commits are deliberately NOT gates here:
# recovery exists to preserve exactly that unlanded work, and the relaunch
# inherits the same worktree, branch, and commits untouched (fm-control's
# safe_checkpoint records head and dirty state for the journal).
prove_custody() {
  local state crew_line crew_state pool_state lease_holder
  PATH_KIND=
  CUSTODY_DETAIL=
  WT=$(fm_meta_get "$META" worktree)
  PROJ=$(fm_meta_get "$META" project)
  fm_backend_validate_task_endpoint "$META" "$ID" >/dev/null 2>&1 \
    || { CUSTODY_DETAIL='endpoint metadata failed validation'; return 1; }
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  TARGET=$FM_BACKEND_VALIDATED_TARGET
  state=$(fm_backend_agent_state "$BACKEND" "$TARGET" "$META" 2>/dev/null || printf 'unreadable')
  case "$state" in
    alive)
      # A live worker is never interrupted, exited, or relaunched by
      # recovery: the session exists, so the stall is firstmate's call.
      PATH_KIND=live-non-turning
      CUSTODY_DETAIL='endpoint is live; recovery never interrupts a live worker - escalating for firstmate'
      return 1
      ;;
    dead|missing) PATH_KIND=missing-endpoint ;;
    *) CUSTODY_DETAIL="endpoint state '$state' is not positively classified"; return 1 ;;
  esac
  crew_line=$("$FM_CREW_STATE_BIN" "$ID" 2>/dev/null || true)
  crew_state=$(printf '%s' "$crew_line" | sed -n 's/^state: \([a-z-]*\).*/\1/p' | head -1)
  case "$crew_state" in
    working|parked|blocked|paused)
      CUSTODY_DETAIL="crew-state $crew_state needs firstmate, not auto-relaunch"; return 1 ;;
    done|failed) ;;
    *) CUSTODY_DETAIL="crew-state '${crew_state:-unreadable}' cannot prove a clean non-run state"; return 1 ;;
  esac
  [ -n "$WT" ] && [ -d "$WT" ] || { CUSTODY_DETAIL='recorded worktree missing'; return 1; }
  # The durable fm-<id> lease proof mirrors bin/fm-spawn.sh's
  # relaunch_worktree_lease_proven, applied here because the launch owner
  # only re-proves it on the gone-endpoint path.
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

# Gate proof: full custody chain before any lifecycle decision. A live
# endpoint escalates here - recovery never interrupts a session that exists.
prove_custody || verdict escalate "$CUSTODY_DETAIL"

# --- bounded lifecycle action, under fm-control's lifecycle lock ------------
#
# The lock is acquired BEFORE the final re-check and held across the
# fm-control invocation (--lock-preheld proves the caller owns it), so a
# record handled in the gap can never relaunch a now-productive worker and a
# concurrent invocation or manual lifecycle action can never double-relaunch.
# A live holder means another lifecycle action is in flight: defer, and the
# watcher re-evaluates on the next cycle.
STALL_LOCK="$STATE/.control-$ID.lock"
fm_lock_try_acquire "$STALL_LOCK" \
  || verdict deferred "lifecycle lock for $ID is held by pid ${FM_LOCK_HELD_PID:-unknown}; another lifecycle action is in flight"
STALL_LOCK_HELD=1

# Final re-check inside the lock, in strict order: re-prove the full custody
# chain (a worker can come back, enter a run, or lose its worktree between
# the first proof and the relaunch - a resurrected endpoint escalates the
# same way a live one does), then re-prove the record itself LAST so a
# handled move during the custody probe still cancels the action.
prove_custody || verdict escalate "$CUSTODY_DETAIL"
if oldest=$(fm_task_inbox_oldest_unhandled "$STATE" "$ID" 2>/dev/null); then
  :
else
  oldest_rc=$?
  [ "$oldest_rc" -eq 1 ] && verdict recovered "inbox emptied before relaunch; instruction handled"
  verdict escalate "inbox unreadable inside lifecycle lock; refusing recovery"
fi
[ "$oldest" = "$RECORD" ] || verdict deferred "record ${RECORD##*/} handled or superseded before relaunch"

# Bounded retry: exactly one automatic relaunch per stalled instruction
# record on the missing-endpoint path, checked and recorded under the lock
# so concurrent invocations cannot both pass the bound. The bound is a fixed
# invariant - no override.
attempts_file="$dir/.recovery-attempts"
attempts_record='' attempts_count=0
if [ -e "$attempts_file" ] || [ -L "$attempts_file" ]; then
  [ -f "$attempts_file" ] && [ ! -L "$attempts_file" ] \
    || verdict escalate "recovery-attempt marker is not a regular file"
  # The marker is exactly one canonical newline-terminated record: the byte
  # count must equal the first line's length plus its terminator, so a
  # trailing unterminated suffix, a second line, or a missing terminator all
  # fail closed rather than being silently normalized away by read.
  IFS= read -r attempts_content < "$attempts_file" \
    || verdict escalate "cannot read the recovery-attempt bound at $attempts_file"
  attempts_bytes=$(wc -c < "$attempts_file") \
    || verdict escalate "cannot read the recovery-attempt bound at $attempts_file"
  [ "$attempts_bytes" -eq $(( ${#attempts_content} + 1 )) ] \
    || verdict escalate "malformed recovery-attempt marker at $attempts_file"
  IFS=$(printf '\t') read -r attempts_record attempts_count attempts_extra \
    <<< "$attempts_content"
  # Structure is validated separately from record identity: a well-formed
  # marker naming a different record is the spent bound of an instruction that
  # was since handled (the watcher only clears it on an observed empty inbox,
  # which a back-to-back queue never produces), so the current oldest record
  # starts its own count at zero and the marker is replaced atomically below.
  # Only a corrupt marker or a spent bound on THIS record escalates.
  case "$attempts_record" in ''|*[!A-Za-z0-9._-]*) false ;; *) true ;; esac \
    && case "$attempts_count" in ''|*[!0-9]*) false ;; *) true ;; esac \
    && [ -z "$attempts_extra" ] \
    && [ "$attempts_content" = "${attempts_record}$(printf '\t')${attempts_count}" ] \
    || verdict escalate "malformed recovery-attempt marker at $attempts_file"
  [ "$attempts_record" = "${RECORD##*/}" ] || attempts_count=0
fi
[ "$attempts_count" -lt 1 ] \
  || verdict escalate "automatic recovery already attempted for ${RECORD##*/}; escalating per bounded-retry policy"

unhandled=$(cd "$dir" 2>/dev/null && printf '%s ' *.msg 2>/dev/null || true)
note="Stall auto-recovery ($TRIGGER, $PATH_KIND): the previous worker stopped acting on doorbells while instruction(s) ${unhandled:-${RECORD##*/}} stayed unhandled. The worktree, branch, and commits are exactly as that worker left them; nothing was discarded. Read and act on the inbox first."
attempts_tmp=$(mktemp "$dir/.recovery-attempts.XXXXXX" 2>/dev/null) \
  || verdict escalate "cannot allocate the recovery-attempt bound at $attempts_file"
if ! printf '%s\t%s\n' "${RECORD##*/}" "$((attempts_count + 1))" > "$attempts_tmp"; then
  rm -f "$attempts_tmp"
  verdict escalate "cannot persist the recovery-attempt bound at $attempts_file"
fi
if ! mv -f "$attempts_tmp" "$attempts_file" 2>/dev/null; then
  rm -f "$attempts_tmp"
  verdict escalate "cannot publish the recovery-attempt bound at $attempts_file"
fi

# fm-control must run as a direct child so --lock-preheld's owner check
# ($PPID == the lock's recorded owner pid) binds to THIS process; a command
# substitution would interpose a subshell and fail the proof. --stall-record
# hands fm-control the record basename so it re-proves the instruction is
# still the oldest unhandled record inside the lock, immediately before the
# agent is touched - the check above cannot cover the gap to that point.
# Exit 3 is fm-control's "record resolved; nothing to do" code.
FM_CONFIG_OVERRIDE=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
control_out_file=$(mktemp "$STATE/.stall-recovery-control-out.XXXXXX" 2>/dev/null) \
  || verdict escalate "cannot allocate the fm-control output capture"
if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
   FM_CONFIG_OVERRIDE="$FM_CONFIG_OVERRIDE" \
   "$FM_STALL_RECOVERY_CONTROL_BIN" "$ID" relaunch --lock-preheld \
     --stall-record "${RECORD##*/}" --note "$note" \
   > "$control_out_file" 2>&1; then
  control_rc=0
else
  control_rc=$?
fi
control_out=$(cat "$control_out_file" 2>/dev/null || true)
rm -f "$control_out_file"
case "$control_rc" in
  0) ;;
  3) verdict recovered "record ${RECORD##*/} resolved inside the lifecycle lock before the relaunch; instruction handled" ;;
  *) verdict escalate "fm-control relaunch refused or failed: $(printf '%s' "$control_out" | tail -1)" ;;
esac

# The replacement owns the instruction now. Reset the delivery ladder so the
# new incarnation gets the full grace-and-retry budget before the bounded
# escalation fires again; the episode stays pending until the record is
# handled or that escalation lands. A reset failure loses that bookkeeping,
# so it escalates rather than reporting a pending relaunch.
fm_task_inbox_ladder_reset "$STATE" "$ID" \
  || verdict escalate "relaunch published but the re-ring ladder could not be reset; the spent budget would escalate the new worker immediately"
status_note "stall auto-recovery relaunched the worker ($PATH_KIND, trigger $TRIGGER); instruction ${RECORD##*/} still pending until handled"
verdict deferred "relaunch published ($PATH_KIND); episode pending until ${RECORD##*/} is handled or the ladder re-escalates"
