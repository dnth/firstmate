#!/usr/bin/env bash
# fm-control.sh - the CONTROL PLANE for a firstmate-owned agent: allowlisted
# lifecycle verbs addressed to an exact task id.
#
# Usage: fm-control.sh <task-id> interrupt
#        fm-control.sh <task-id> exit
#        fm-control.sh <task-id> relaunch [--harness <name>] [--model <name>]
#                                         [--effort <level>] [--backend <name>]
#                                         [--lock-preheld]
#                                         (--note <text> | --note-file <path>)
#        fm-control.sh <task-id> switch-model --model <provider/id>
#                                             [--effort <level>] [--wait <seconds>]
#        fm-control.sh <task-id> switch-model --status
#
# Why this exists, and how it differs from fm-send.sh. bin/fm-send.sh is the
# DATA plane: conversational text for the agent to read, always routing-marked
# for a kind=secondmate target so the reply returns through the status path.
# That marking is right for a message and wrong for a lifecycle command - a
# marked "/quit" arrives as ordinary chat the agent reasons ABOUT instead of
# executing. This script is the control plane: semantic process control with a
# closed verb list, per-harness mechanics owned by an executable adapter
# (bin/fm-control-lib.sh) rather than improvised in agent prose, and a verified
# postcondition for every action. There is deliberately NO arbitrary-text and
# NO generic raw-key entry point here; fm-send remains the only way to send an
# agent something to read.
#
#   interrupt  Deliver the harness's verified interrupt sequence. The agent
#              keeps running. Postcondition: delivery succeeded, the endpoint
#              still exists, and the agent is still alive where the backend can
#              classify that. Cancellation is confirmed only from an adapter-
#              owned acknowledgement and otherwise reported unconfirmed. Busy
#              state is never rewritten as proof of the action.
#   exit       Stop the agent without explicitly closing its terminal endpoint,
#              preserving its worktree and every uncommitted change.
#              Interrupts first when the task reads
#              busy, then submits the harness's exit command. Postcondition:
#              the backend's recovery-grade classifier reports the agent gone.
#              Already-stopped is success (idempotent). A stopped incarnation's
#              busy generation is retired with it, sidecar and task-record line
#              together.
#   relaunch   Transactionally replace the running agent with a new one, in the
#              SAME endpoint and SAME worktree, on the same or a newly chosen
#              harness/model/effort - so switching harness is one ordinary use
#              of this verb. An explicit `default` model or effort clears that
#              axis for the replacement. With no explicit axis, a secondmate
#              re-resolves its durable config/secondmate-harness pin (harness
#              plus its optional model and effort tokens) exactly as any other
#              respawn does, while a ship or scout keeps the exact adapter
#              already recorded for it.
#              A prefixed raw-command basename cannot reconstruct its launch
#              command, so relaunch requires an explicit --harness for it.
#              --note is required for a ship or scout, whose replacement
#              inherits the local copy but none of the conversation; a
#              secondmate reconciles its own home's records at startup, so its
#              standing charter is never rewritten.
#              --backend pins the replacement's runtime backend instead of
#              letting the launch owner resolve it from this home's config; a
#              task whose recorded endpoint sits on a different backend is
#              refused before a journal write, agent touch, or replacement
#              launch.
#              --lock-preheld is the supervised-recovery handshake: the caller
#              (bin/fm-stall-recovery.sh) already holds this task's lifecycle
#              lock, so fm-control verifies the lock's recorded owner is its
#              own parent process instead of acquiring it. The flag never
#              bypasses the lock - without a live parent holding it, the
#              command refuses.
#              --stall-record <basename> rides the same handshake: inside the
#              lock, immediately before the agent is touched, fm-control
#              re-proves the named inbox record is still the oldest unhandled
#              instruction and cancels with exit 3 when it was handled or
#              superseded in flight. It requires --lock-preheld.
#              Records a durable checkpoint and that note, exits the old agent,
#              then delegates the launch to its single owner,
#              bin/fm-spawn.sh --relaunch. A failure before publication keeps
#              the prior durable record in place and reports the concrete
#              state; it never leaves a half-transitioned task claiming to be
#              running.
#              A recorded endpoint the recovery-grade classifier proves
#              MISSING counts as already stopped: there is no agent to exit,
#              the transaction continues, and the launch owner recreates the
#              endpoint inside the checkpointed worktree. `exit` on a missing
#              endpoint still refuses - an absent agent is a reconciliation
#              finding, not a stopped one.
#
#   switch-model  Change a LIVE OMP worker's model, and optionally its thinking
#              level, inside its current session. The request is files, never
#              keystrokes: it does not touch the composer and never arrives as
#              chat. The worker's own extension resolves the target, switches
#              through OMP's documented session-only extension API (global
#              modelRoles are untouched and the session records the change, so
#              a resume keeps it), and reads the live model back. The wire
#              contract is owned by .omp/extensions/lib/fm-task-model-switch.ts.
#              The switch applies at once, like OMP's own /switch picker. A
#              request already in flight uses the old model, and subsequent
#              requests use the new one, even mid-task. On a Responses-WebSocket
#              model a reply already streaming can be cut by the switch.
#              --model is provider/id exactly as `omp models` lists it. --effort
#              is low|medium|high|xhigh|max and must be supported by the target
#              model. With no --effort the extension leaves thinking to OMP.
#              Flags take separate values. The acknowledgement wait uses one
#              monotonic deadline (--wait, default 15 seconds), with a final
#              receipt check before attempting withdrawal. A verified success
#              requires the live model and any requested effort to match.
#              Task meta records the native thinking readback verbatim, with
#              an empty effort when OMP reports none. A relaunch on the same
#              adapter inherits an OMP worker's recorded effort only if it
#              is in the launch vocabulary.
#              A typed switch result starts with one of these words.
#              `switched` exits 0, and the other results exit 1.
#                switched         the live model (and effort) read back as the
#                                 target; meta updated.
#                refused          the request failed or its result could not be
#                                 verified. reason= includes unknown-model,
#                                 no-credentials, model-mismatch,
#                                 effort-unsupported, stale-incarnation,
#                                 set-model-failed, invalid-request, internal-error,
#                                 and readback-mismatch. A post-switch refusal
#                                 can report a live model that differs from meta.
#                partial          the model switched but the thinking level did
#                                 not land. Both values are reported, nothing
#                                 is claimed rolled back, and meta follows the
#                                 live state.
#                superseded       a newer request replaced it before it ran.
#                cancelled        the wait ended and the request was withdrawn
#                                 by an atomic rename before the worker claimed
#                                 it, so it can never apply. Nothing changed.
#                pending-unknown  no receipt was visible and withdrawal could
#                                 not be proved. The switch may still land.
#                                 The output names the request id.
#                meta-stale       the live state is as reported but task meta
#                                 could not be reconciled. An acknowledgement
#                                 cannot rewrite a different worker generation.
#              `switch-model --status` tries to reconcile outstanding receipts,
#              including late ones. It reports the latest acknowledgement by
#              ackSequence and exits 1 if the channel is unavailable or requests
#              remain unresolved. Other verbs also try to reconcile outstanding
#              receipts for supported OMP workers before acting.
#              Only OMP ships and scouts have this channel. Any other harness,
#              a secondmate (its OMP runs the primary adapter, which has no
#              request channel), and a worker launched before the verb existed
#              are refused with that reason; relaunch with --model and
#              --effort to change those instead.
#
# Teardown and discard are NOT verbs here and never will be. `exit` stops an
# agent and preserves everything else; removing a worktree, killing an
# endpoint, or discarding work stays with bin/fm-teardown.sh, which owns the
# landed-work test.
#
# `resume` is not a verb: it is not deterministic across the verified adapters
# (bin/fm-control-lib.sh's header owns that reasoning). `relaunch` covers the
# same need for every adapter because the brief on disk, not a harness-private
# session, is the durable instruction.
#
# Targeting is EXACT: only a bare task id with a state/<id>.meta record in
# THIS home is accepted, and the record must pass the shared endpoint-identity
# validation (bin/fm-backend.sh's fm_backend_validate_task_endpoint). A legacy
# fm-<id> label, an explicit session:window endpoint, and a bare window name
# are all refused - a lifecycle command delivered to the wrong endpoint is far
# worse than a loud refusal.
#
# A remotely placed secondmate is refused by name: its agent runs on another
# host, so no postcondition this plane verifies could be read for it here.
#
# Fail-closed boundaries:
#   - An unverified harness, or a harness whose control mechanics are unknown,
#     is refused rather than guessed at.
#   - A backend that cannot deliver the harness's interrupt key is refused
#     (Orca's terminal API has no Escape).
#   - `exit` and `relaunch` require a backend with a recovery-grade agent-state
#     classifier (tmux, herdr), because without one the "the agent stopped"
#     postcondition cannot be proven. zellij, orca, and cmux are refused rather
#     than reported as successful blind.
#   - An ambiguous or unreadable endpoint state refuses; only a positively
#     classified state acts.
#   - `switch-model` sends no key, so it needs no recovery-grade classifier: it
#     refuses a positively dead or missing endpoint, and requires the worker's
#     extension to prove itself live through its ready marker.
#
# Environment knobs (all bounded waits, seconds):
#   FM_CONTROL_POLL              poll interval for postcondition waits (0.5)
#   FM_CONTROL_SETTLE_WAIT       adapter acknowledgement wait after interrupt (5)
#   FM_CONTROL_EXIT_WAIT         alive->stopped wait after the exit command (30)
#   FM_CONTROL_LAUNCH_WAIT       dead->alive wait after a relaunch (90)
#   FM_CONTROL_EXIT_RETRIES      Enter retries for the exit command (3)
# These wait knobs apply to lifecycle operations. switch-model uses --wait.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a crewmate's lifecycle (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-control refuses to resolve a task without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-control cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 1
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-secondmate-charter-lib.sh
. "$SCRIPT_DIR/fm-secondmate-charter-lib.sh"

POLL=${FM_CONTROL_POLL:-0.5}
SETTLE_WAIT=${FM_CONTROL_SETTLE_WAIT:-5}
EXIT_WAIT=${FM_CONTROL_EXIT_WAIT:-30}
LAUNCH_WAIT=${FM_CONTROL_LAUNCH_WAIT:-90}
EXIT_RETRIES=${FM_CONTROL_EXIT_RETRIES:-3}

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
RELAUNCH_ACTIVE=0
RELAUNCH_PHASE=start

control_cleanup() {
  local status=$?
  if [ "$RELAUNCH_ACTIVE" = 1 ] \
     && declare -F relaunch_rollback >/dev/null 2>&1; then
    relaunch_rollback || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  if declare -F fm_lease_guard_release >/dev/null 2>&1; then
    fm_lease_guard_release || true
  fi
  return "$status"
}

# --- argument parsing -------------------------------------------------------

RAW_ID=${1:-}
VERB=${2:-}
[ -n "$RAW_ID" ] && [ -n "$VERB" ] || { usage >&2; exit 2; }
shift 2

if ! fm_control_verb_allowed "$VERB"; then
  {
    if [ "$VERB" = resume ]; then
      echo "error: 'resume' is not a control verb: resuming an exited agent is not deterministic across the verified adapters (codex and grok need a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, and kimi have no verified pane-resume contract). Use 'relaunch', which carries the brief plus a progress note into a fresh agent on any adapter."
    else
      echo "error: '$VERB' is not a control verb"
    fi
    echo "allowed verbs:"
    fm_control_verbs | sed 's/^/  /'
  } >&2
  exit 2
fi

NEW_HARNESS=
NEW_MODEL=
NEW_EFFORT=
PIN_BACKEND=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
BACKEND_SET=0
NOTE=
NOTE_SET=0
LOCK_PREHELD=0
STALL_RECORD=
STATUS_SET=0
WAIT_ARG=15
WAIT_SET=0
control_want_value=
for control_arg in "$@"; do
  if [ -n "$control_want_value" ]; then
    case "$control_arg" in
      --*) die "--$control_want_value requires a value" ;;
    esac
    case "$control_want_value" in
      harness) NEW_HARNESS=$control_arg; HARNESS_SET=1 ;;
      model) NEW_MODEL=$control_arg; MODEL_SET=1 ;;
      effort) NEW_EFFORT=$control_arg; EFFORT_SET=1 ;;
      backend) PIN_BACKEND=$control_arg; BACKEND_SET=1 ;;
      note) NOTE=$control_arg; NOTE_SET=1 ;;
      stall_record) STALL_RECORD=$control_arg ;;
      wait) WAIT_ARG=$control_arg; WAIT_SET=1 ;;
      note_file)
        [ -f "$control_arg" ] || die "--note-file '$control_arg' is not a readable file"
        NOTE=$(cat "$control_arg")
        NOTE_SET=1
        ;;
    esac
    control_want_value=
    continue
  fi
  if [ "$VERB" = switch-model ]; then
    case "${control_arg%%=*}" in
      --harness|--backend|--note|--note-file|--lock-preheld|--stall-record)
        die "${control_arg%%=*} applies to 'relaunch' only"
        ;;
    esac
  fi
  case "$control_arg" in
    --harness) control_want_value=harness ;;
    --harness=*) NEW_HARNESS=${control_arg#--harness=}; HARNESS_SET=1 ;;
    --model) control_want_value=model ;;
    --model=*) [ "$VERB" != switch-model ] || die "switch-model takes --model <provider/id> as a separate argument"
               NEW_MODEL=${control_arg#--model=}; MODEL_SET=1 ;;
    --effort) control_want_value=effort ;;
    --effort=*) [ "$VERB" != switch-model ] || die "switch-model takes --effort <level> as a separate argument"
                NEW_EFFORT=${control_arg#--effort=}; EFFORT_SET=1 ;;
    --backend) control_want_value=backend ;;
    --backend=*) PIN_BACKEND=${control_arg#--backend=}; BACKEND_SET=1 ;;
    --note) control_want_value=note ;;
    --note=*) NOTE=${control_arg#--note=}; NOTE_SET=1 ;;
    --note-file) control_want_value=note_file ;;
    --note-file=*)
      [ -f "${control_arg#--note-file=}" ] || die "--note-file '${control_arg#--note-file=}' is not a readable file"
      NOTE=$(cat "${control_arg#--note-file=}")
      NOTE_SET=1
      ;;
    --lock-preheld) LOCK_PREHELD=1 ;;
    --stall-record) control_want_value=stall_record ;;
    --stall-record=*) STALL_RECORD=${control_arg#--stall-record=} ;;
    --wait) control_want_value='wait' ;;
    --status) STATUS_SET=1 ;;
    *) die "unexpected argument '$control_arg'" ;;
  esac
done
if [ -n "$control_want_value" ]; then
  [ "$control_want_value" = note_file ] && die "--note-file requires a value"
  die "--$control_want_value requires a value"
fi

case "$VERB" in
  relaunch|switch-model) ;;
  *)
    [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$BACKEND_SET" = 0 ] && [ "$NOTE_SET" = 0 ] && [ "$LOCK_PREHELD" = 0 ] && [ -z "$STALL_RECORD" ] \
      || die "--harness, --model, --effort, --backend, --note, --lock-preheld, and --stall-record apply to 'relaunch' only (--model and --effort also apply to 'switch-model')"
    ;;
esac
if [ "$VERB" != switch-model ]; then
  [ "$STATUS_SET" = 0 ] && [ "$WAIT_SET" = 0 ] \
    || die "--status and --wait apply to 'switch-model' only"
fi
# The stall-record re-check is only meaningful inside the supervised-recovery
# handshake: without --lock-preheld there is no proof the caller serialized
# its own custody checks with this invocation.
[ -z "$STALL_RECORD" ] || [ "$LOCK_PREHELD" = 1 ] \
  || die "--stall-record requires --lock-preheld"
[ "$HARNESS_SET" = 0 ] || [ -n "$NEW_HARNESS" ] || die "--harness requires a non-empty value"
[ "$MODEL_SET" = 0 ] || [ -n "$NEW_MODEL" ] || die "--model requires a non-empty value"
[ "$EFFORT_SET" = 0 ] || [ -n "$NEW_EFFORT" ] || die "--effort requires a non-empty value"
[ "$BACKEND_SET" = 0 ] || [ -n "$PIN_BACKEND" ] || die "--backend requires a non-empty value"
case "$NEW_EFFORT" in
  ''|default|low|medium|high|xhigh|max) ;;
  *) die "--effort must be one of default, low, medium, high, xhigh, max" ;;
esac
if [ "$VERB" = switch-model ]; then
  if [ "$STATUS_SET" = 1 ]; then
    [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$WAIT_SET" = 0 ] \
      || die "--status takes no other option"
  else
    [ "$MODEL_SET" = 1 ] || die "switch-model requires --model <provider/id>, or --status"
    case "$NEW_MODEL" in
      */*) ;;
      *) die "--model must be written provider/id, exactly as 'omp models' lists it" ;;
    esac
    case "$NEW_MODEL" in
      /*|*/|*[[:space:][:cntrl:]]*) die "--model must be one provider/id token with no whitespace and no leading or trailing slash" ;;
    esac
    case "$NEW_EFFORT" in
      ''|low|medium|high|xhigh|max) ;;
      *) die "--effort for switch-model must be one of low, medium, high, xhigh, max" ;;
    esac
  fi
  case "$WAIT_ARG" in
    ''|*[!0-9]*) die "--wait must be a whole number of seconds from 1 to 3600" ;;
  esac
  MODEL_WAIT=${WAIT_ARG#"${WAIT_ARG%%[!0]*}"}
  [ -n "$MODEL_WAIT" ] && [ "${#MODEL_WAIT}" -le 4 ] && [ "$MODEL_WAIT" -le 3600 ] \
    || die "--wait must be a whole number of seconds from 1 to 3600"
fi

# --- exact task-id resolution ----------------------------------------------

case "$RAW_ID" in
  *:*) die "'$RAW_ID' is an explicit backend endpoint; fm-control accepts an exact task id only, so a lifecycle command can never land on an endpoint this home does not own" ;;
esac
if ! fm_task_id_creation_valid "$RAW_ID"; then
  die "'$RAW_ID' is not a valid task id"
fi
ID=$RAW_ID
# Supervision lease guard: lifecycle control is overlap territory between the
# two Pi supervision actors; refuse while the OTHER actor holds this task's
# live lease (contract: bin/fm-lease-lib.sh; no-op in homes without leases).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_guard "$ID" "lifecycle control (fm-control)"
CONTROL_LOCK="$STATE/.control-$ID.lock"
trap control_cleanup EXIT
if [ "$LOCK_PREHELD" = 1 ]; then
  # Supervised-recovery handshake: the direct parent (bin/fm-stall-recovery.sh)
  # holds this task's lifecycle lock across this invocation, so its custody and
  # inbox-record re-checks are serialized with the relaunch itself. The flag
  # never bypasses the lock: it is honored only when the lock exists, its
  # recorded owner pid is this process's own parent, and that parent is alive.
  # CONTROL_LOCK_HELD stays 0 so the cleanup trap never releases a lock this
  # process does not own.
  lock_owner_pid=$(cat "$CONTROL_LOCK/pid" 2>/dev/null || true)
  if [ -z "$lock_owner_pid" ] || [ "$lock_owner_pid" != "$PPID" ] || ! fm_pid_alive "$lock_owner_pid"; then
    die "--lock-preheld requires the caller to hold $CONTROL_LOCK as this process's live parent (owner: ${lock_owner_pid:-none}, parent: $PPID)"
  fi
else
  fm_lock_try_acquire "$CONTROL_LOCK" \
    || die "another lifecycle action is already running for task $ID"
  CONTROL_LOCK_HELD=1
fi
META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  case "$RAW_ID" in
    fm-*)
      if [ -f "$STATE/${RAW_ID#fm-}.meta" ]; then
        die "'$RAW_ID' is a window label, not a task id; pass the exact task id '${RAW_ID#fm-}'"
      fi
      ;;
  esac
  die "no task '$ID' in $STATE (fm-control resolves an exact task id only)"
fi

# A remotely placed secondmate records its endpoint on ANOTHER host, so every
# postcondition this plane verifies - the agent-state classification, the busy
# verdict, the endpoint's existence - would be read here for an endpoint that
# does not live here. Endpoint validation already refuses such a record, since
# `window=remote:<id>` can never match a local backend's required shape, so
# nothing can be delivered to a wrong endpoint either way. What that refusal
# cannot say is WHY, and "malformed metadata" is the wrong thing to tell an
# operator about a correctly configured remote route. Name the placement
# instead, using the same `remote_host` signal bin/fm-send.sh routes on.
if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
  die "task $ID is a remotely placed secondmate on $(fm_meta_get "$META" remote_host); its agent runs outside this home, so no lifecycle action here could verify that it interrupted, stopped, or came back. Drive its lifecycle on that host, and reconcile it through the secondmate recovery path rather than this plane"
fi

fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
LABEL="fm-$ID"
RECORDED_HARNESS=$(fm_meta_get "$META" harness)
TASK_SPAWN_GEN=$(fm_meta_get "$META" spawn_gen)
KIND=$(fm_meta_get "$META" kind)
WT=$(fm_meta_get "$META" worktree)
[ -n "$KIND" ] || KIND=ship

HARNESS=$(fm_control_harness_family "$RECORDED_HARNESS") \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"
fm_control_harness_supported "$HARNESS" \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"
if [ "$VERB" = switch-model ]; then
  fm_control_model_switch_supported "$HARNESS" "$KIND" \
    || die "task $ID (harness ${RECORDED_HARNESS:-none}, kind $KIND) has no in-session model-switch channel: only OMP ships and scouts load the per-task extension that applies it, and an OMP secondmate runs the primary adapter instead. Relaunch it with --model and --effort to change them"
fi

fm_backend_validate "$BACKEND" || exit 1

# A pinned replacement backend must be the backend the recorded endpoint
# already lives on: refusing here, before any journal write or agent touch,
# keeps a mismatched pin from silently migrating the task onto another backend.
if [ "$VERB" = relaunch ] && [ "$BACKEND_SET" = 1 ] && [ "$PIN_BACKEND" != "$BACKEND" ]; then
  die "task $ID's endpoint is recorded on backend '$BACKEND', not the pinned '$PIN_BACKEND'; refusing to relaunch it onto another backend"
fi

# --- shared helpers ---------------------------------------------------------

# The durable record is part of the question for an adapter whose liveness is
# proven from its own process identity: without it an OMP or Hermes endpoint
# cannot be attributed and reads ambiguous, which would refuse every lifecycle
# verb on a perfectly healthy agent. fm-control has already validated this
# record, so passing it costs every other adapter nothing.
agent_state() {
  fm_backend_agent_state "$BACKEND" "$T" "$META"
}

busy_verdict() {
  fm_busy_classify_meta "$META" "$ID" "$STATE"
}

# wait_agent_state <wanted...> <timeout>: poll until agent_state prints one of
# the wanted values. Prints the final observed state; returns 0 on a match.
wait_agent_state() {  # <timeout> <wanted>...
  local timeout=$1 state want elapsed=0
  shift
  while :; do
    state=$(agent_state)
    for want in "$@"; do
      if [ "$state" = "$want" ]; then
        printf '%s' "$state"
        return 0
      fi
    done
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf '%s' "$state"
  return 1
}

require_state_verified_backend() {  # <verb>
  fm_control_backend_state_verified "$BACKEND" && return 0
  die "task $ID runs on the $BACKEND backend, which has no recovery-grade agent-state classifier, so '$1' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done"
}

# send_interrupt_keys: deliver the harness's interrupt key the verified number
# of times, then the composer-clear key when the adapter needs one. Refuses
# before sending anything when the backend cannot deliver either key, because
# an interrupt that cancels the turn but leaves the restored prompt in the
# composer would make the next submitted line concatenate onto it.
send_interrupt_keys() {
  local key repeat clear i=0
  key=$(fm_control_interrupt_key "$HARNESS")
  repeat=$(fm_control_interrupt_repeat "$HARNESS")
  clear=$(fm_control_interrupt_clear_key "$HARNESS")
  fm_control_backend_supports_key "$BACKEND" "$key" \
    || die "harness $HARNESS interrupts with $key, which the $BACKEND backend cannot deliver; refusing to send a different key"
  [ -z "$clear" ] || fm_control_backend_supports_key "$BACKEND" "$clear" \
    || die "harness $HARNESS needs $clear to clear its composer after an interrupt, which the $BACKEND backend cannot deliver; refusing to leave the cancelled prompt where the next submitted line would concatenate onto it"
  while [ "$i" -lt "$repeat" ]; do
    fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
      || die "interrupt key $key was not delivered to task $ID on $BACKEND"
    i=$((i + 1))
    [ "$i" -ge "$repeat" ] || sleep 0.2
  done
  [ -z "$clear" ] || fm_backend_send_key "$BACKEND" "$T" "$clear" "$LABEL" \
    || die "interrupt key $key reached task $ID, but $clear did not, so its composer still holds the cancelled prompt; clear it before the next lifecycle action"
}

prepare_interrupt_ack() {
  INTERRUPT_ACK_SOURCE=$(fm_control_interrupt_ack_source "$HARNESS")
  INTERRUPT_ACK_LOG=
  INTERRUPT_ACK_RUN=
  case "$INTERRUPT_ACK_SOURCE" in
    muse-session-terminal)
      INTERRUPT_ACK_LOG=$(fm_busy_muse_session_log "$STATE" "$ID" 2>/dev/null || true)
      [ -n "$INTERRUPT_ACK_LOG" ] || return 0
      INTERRUPT_ACK_RUN=$(fm_busy_muse_active_run_id "$INTERRUPT_ACK_LOG" 2>/dev/null || true)
      ;;
  esac
}

interrupt_cancel_claim() {
  local elapsed=0 terminal=
  case "$INTERRUPT_ACK_SOURCE:$INTERRUPT_ACK_RUN" in
    muse-session-terminal:?*) ;;
    *) printf 'unconfirmed'; return 0 ;;
  esac
  while :; do
    terminal=$(fm_busy_muse_run_terminal "$INTERRUPT_ACK_LOG" "$INTERRUPT_ACK_RUN" 2>/dev/null || true)
    case "$terminal" in
      cancelled) printf 'confirmed'; return 0 ;;
      ?*) printf 'unconfirmed'; return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$SETTLE_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf 'unconfirmed'
}

# deliver_interrupt: deliver and observe the strongest adapter-owned
# cancellation claim available after delivery.
deliver_interrupt() {
  local cancel
  prepare_interrupt_ack
  send_interrupt_keys
  cancel=$(interrupt_cancel_claim)
  printf '%s' "$cancel"
}

verify_interrupt_running() {
  local proof after
  fm_backend_target_exists "$BACKEND" "$T" "$LABEL" \
    || die "task $ID's endpoint disappeared while interrupting it; no further control action is safe"
  proof=endpoint
  if fm_control_backend_state_verified "$BACKEND"; then
    # An interrupt cancels a turn; it must never have stopped the agent. This
    # is the postcondition that separates a landed interrupt from an accident.
    after=$(agent_state)
    [ "$after" = alive ] \
      || die "task $ID's agent is '$after' after its interrupt key; an interrupt must leave the agent running"
    proof=agent-alive
  fi
  printf '%s' "$proof"
}

do_interrupt() {
  local proof cancel
  cancel=$(deliver_interrupt) || return $?
  proof=$(verify_interrupt_running) || return $?
  printf '%s cancel=%s' "$proof" "$cancel"
}

retire_busy_incarnation() {
  fm_busy_retire_incarnation "$STATE" "$ID" "$TASK_SPAWN_GEN" && return 0
  if [ "$VERB" = exit ]; then
    die "could not retire task $ID's busy generation; retry 'fm-control.sh $ID exit' if the endpoint remains, or use 'fm-control.sh $ID relaunch' if it is gone (ships and scouts require --note or --note-file)"
  fi
  die "could not retire task $ID's busy generation"
}

# do_exit: stop the running agent, preserving its worktree. Prints
# `already-stopped` or `stopped`.
do_exit() {
  local state cmd verdict cancel interrupt_result=not-needed
  require_state_verified_backend exit
  state=$(agent_state)
  case "$state" in
    dead)
      printf 'already-stopped'
      return 0
      ;;
    alive) ;;
    missing) die "task $ID's recorded endpoint is gone, so there is no agent to stop; use 'fm-control.sh $ID relaunch' to reconcile it (ships and scouts require --note or --note-file)" ;;
    *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle command into an unattributed endpoint" ;;
  esac
  # A busy agent is interrupted first before the exit command is submitted.
  case "$(busy_verdict)" in
    busy*)
      cancel=$(deliver_interrupt) || return $?
      state=$(agent_state)
      case "$state" in
        dead)
          printf 'stopped'
          return 0
          ;;
        alive) interrupt_result="delivered verified=agent-alive cancel=$cancel" ;;
        missing) die "task $ID's recorded endpoint disappeared after interrupt delivery, so exit cannot prove whether the agent stopped" ;;
        *) die "task $ID's endpoint reads '$state' after interrupt delivery rather than a positively classified state; exit cannot prove whether the agent stopped" ;;
      esac
      ;;
  esac
  cmd=$(fm_control_exit_command "$HARNESS")
  # The submit verdict is NOT the postcondition here: a successful exit command
  # destroys the composer the verdict is read from, so a post-exit read can
  # legitimately report anything. Only a hard transport failure aborts; the
  # authoritative proof is the agent-state wait below. The retried Enter still
  # matters, because a slash command opens a completion popup on some TUIs that
  # swallows the first Enter. An endpoint that vanishes under the delivered
  # exit command is stopped too: the endpoint was validated and owned before
  # anything was sent, and nothing can still be running there.
  verdict=$(fm_backend_send_text_submit "$BACKEND" "$T" "$cmd" "$EXIT_RETRIES" "$POLL" 1.2 "$LABEL") \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  [ "$verdict" != send-failed ] \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  state=$(wait_agent_state "$EXIT_WAIT" dead missing) || {
    die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s"
  }
  printf 'stopped'
}

# --- in-session model switch ------------------------------------------------
#
# The verb's contract is in this file's header; the wire contract (file names,
# request and acknowledgement JSON) is owned by
# .omp/extensions/lib/fm-task-model-switch.ts. This section only speaks it.

MS_REQUEST_SCHEMA=fm-model-switch.request.v1
MS_ACK_SCHEMA=fm-model-switch.ack.v1
MS_READY_SCHEMA=fm-model-switch.ready.v1
MS_DIR="$STATE/$ID.omp-doorbell-ready.requests"
MS_META_LOCK=$(fm_meta_lock_path "$META" 2>/dev/null || true)
MS_CHANNEL_WHY=
MS_RECONCILED=0
MS_FOLD_UPDATED=0
MS_A_ID=
MS_A_GEN=
MS_A_OUTCOME=
MS_A_REASON=
MS_A_DETAIL=
MS_A_TARGET_MODEL=
MS_A_TARGET_EFFORT=
MS_A_BEFORE_MODEL=
MS_A_BEFORE_THINKING=
MS_A_AFTER_MODEL=
MS_A_AFTER_THINKING=

ms_path() {  # <request-id> <suffix>
  printf '%s/model-switch.%s.%s' "$MS_DIR" "$1" "$2"
}

ms_mono_us() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%d", clock_gettime(CLOCK_MONOTONIC) * 1000000' 2>/dev/null
}

# Bounded acquisition of this task's metadata lock: a reconcile that rides on an
# unrelated verb must never hang that verb behind a wedged lock holder.
ms_lock_meta() {
  local tries=0 status
  [ -n "$MS_META_LOCK" ] || return 1
  while :; do
    status=0
    fm_lock_try_acquire "$MS_META_LOCK" || status=$?
    [ "$status" -ne 0 ] || return 0
    [ "$status" -ne 2 ] || return 1
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || return 1
    sleep 0.1
  done
}

# ms_meta_apply <model> <effort|empty>: replace the model= and effort=
# records atomically under the metadata lock. A record whose worker generation
# changed since this verb began is never rewritten.
ms_meta_apply() {
  local tmp rc=0
  ms_lock_meta || { echo "error: task $ID's metadata lock could not be acquired" >&2; return 1; }
  if [ -f "$META" ] && [ ! -L "$META" ] \
     && [ "$(fm_meta_get "$META" spawn_gen)" = "$TASK_SPAWN_GEN" ] \
     && tmp=$(mktemp "$STATE/.model-switch-$ID.XXXXXX"); then
    if FM_SWITCH_READBACK_MODEL="$1" FM_SWITCH_READBACK_EFFORT="$2" awk '
         /^(model|effort)=/ { next }
         { print }
         END { print "model=" ENVIRON["FM_SWITCH_READBACK_MODEL"]; print "effort=" ENVIRON["FM_SWITCH_READBACK_EFFORT"] }
       ' "$META" > "$tmp" && mv -f -- "$tmp" "$META"; then
      rc=0
    else
      rm -f -- "$tmp"
      rc=1
    fi
  else
    rc=1
  fi
  fm_lock_release "$MS_META_LOCK" || true
  return "$rc"
}

# ms_read_ack <ack-file>: parse one acknowledgement into the MS_A_* variables.
# Non-zero when the file is not a model-switch acknowledgement.
ms_read_ack() {
  local rec
  MS_A_ID=
  MS_A_GEN=
  MS_A_OUTCOME=
  MS_A_REASON=
  MS_A_DETAIL=
  MS_A_TARGET_MODEL=
  MS_A_TARGET_EFFORT=
  MS_A_BEFORE_MODEL=
  MS_A_BEFORE_THINKING=
  MS_A_AFTER_MODEL=
  MS_A_AFTER_THINKING=
    rec=$(jq -j --arg schema "$MS_ACK_SCHEMA" '
      select(type == "object" and .schema == $schema and (.ackSequence | type) == "number")
      | [.id, .spawnGen, .outcome, .reason, .detail,
         .target.model, .target.effort, .before.model, .before.thinking,
         .after.model, .after.thinking]
      | map(if . == null then "" else (tostring | gsub("[\u001f\n\r]"; " ")) end)
      | join("\u001f")' "$1" 2>/dev/null) || return 1
  [ -n "$rec" ] || return 1
  IFS=$'\037' read -r MS_A_ID MS_A_GEN MS_A_OUTCOME MS_A_REASON MS_A_DETAIL \
    MS_A_TARGET_MODEL MS_A_TARGET_EFFORT MS_A_BEFORE_MODEL MS_A_BEFORE_THINKING \
    MS_A_AFTER_MODEL MS_A_AFTER_THINKING <<< "$rec" || true
  [ -n "$MS_A_ID" ] && [ -n "$MS_A_OUTCOME" ]
}

# The Herdr pane label mirrors the model and effort recorded in meta
# (docs/herdr-backend.md "Pane display-agent label"), so a change to meta
# republishes it. Best effort by that contract: a failed publication costs one
# warning in the home's log and never fails the verb.
ms_refresh_pane_label() {
  [ "$BACKEND" = herdr ] || return 0
  fm_backend_source herdr >/dev/null 2>&1 || return 0
  fm_backend_herdr_report_agent_label_ordered "$T" "$RECORDED_HARNESS" \
    "$(fm_meta_get "$META" model)" "$(fm_meta_get "$META" effort)" || true
}

ms_verify_ack() {
  case "$MS_A_OUTCOME" in
    applied|partial)
      if [ -z "$MS_A_TARGET_MODEL" ] || [ "$MS_A_AFTER_MODEL" != "$MS_A_TARGET_MODEL" ] \
         || { [ "$MS_A_OUTCOME" = applied ] && [ -n "$MS_A_TARGET_EFFORT" ] \
              && [ "$MS_A_AFTER_THINKING" != "$MS_A_TARGET_EFFORT" ]; }; then
        MS_A_OUTCOME=refused
        MS_A_REASON=readback-mismatch
        MS_A_DETAIL="the live readback does not verify the requested target"
      fi
      ;;
  esac
}

ms_fold_ack() {
  local ack=$1 order=$2 high_water=$3
  MS_FOLD_UPDATED=0
  ms_read_ack "$ack" || return 1
  [ "$MS_A_GEN" = "$TASK_SPAWN_GEN" ] || return 2
  [ "$(fm_meta_get "$META" spawn_gen)" = "$TASK_SPAWN_GEN" ] || return 3
  ms_verify_ack
  case "$MS_A_OUTCOME" in
    applied|partial)
      if [ "$order" -gt "$high_water" ]; then
        if [ "$MS_A_AFTER_MODEL" != "$(fm_meta_get "$META" model)" ] \
           || [ "$MS_A_AFTER_THINKING" != "$(fm_meta_get "$META" effort)" ]; then
          ms_meta_apply "$MS_A_AFTER_MODEL" "$MS_A_AFTER_THINKING" || return 3
          MS_FOLD_UPDATED=1
        fi
        # Always republished for the newest verified receipt: a fold that
        # stopped after the metadata write left the label on the old model.
        ms_refresh_pane_label
      fi
      ;;
  esac
  mv -f -- "$ack" "$ack.folded" 2>/dev/null || return 3
}

ms_unfolded_acks() {
  local f order
  for f in "$MS_DIR"/model-switch.*.ack.json; do
    [ -f "$f" ] || continue
    order=$(jq -r 'select((.ackSequence | type) == "number") | .ackSequence' "$f" 2>/dev/null) || order=
    [ -n "$order" ] || continue
    printf '%s\t%s\n' "$order" "$f"
  done | LC_ALL=C sort -n
}

reconcile_model_switch() {
  local through=${1:-} at ack rc high_water=-1 folded=() f
  MS_RECONCILED=0
  [ -d "$MS_DIR" ] && [ ! -L "$MS_DIR" ] || return 0
  for f in "$MS_DIR"/model-switch.*.ack.json.folded; do
    [ ! -f "$f" ] || folded+=("$f")
  done
  if [ -n "${folded[0]:-}" ]; then
    high_water=$(jq -s --arg gen "$TASK_SPAWN_GEN" --arg schema "$MS_ACK_SCHEMA" '
      map(select(.schema == $schema and .spawnGen == $gen and (.outcome == "applied" or .outcome == "partial")
        and (.ackSequence | type) == "number"
        and (.target.model != null and .target.model != "" and .after.model == .target.model)
        and (.outcome == "partial" or (.target.effort // "") == "" or .after.thinking == .target.effort))
        | .ackSequence) | max // -1
      ' "${folded[@]}") || return 1
  fi
  while IFS=$'\t' read -r at ack; do
    [ -n "$ack" ] || continue
    rc=0
    ms_fold_ack "$ack" "$at" "$high_water" || rc=$?
    [ "$ack" != "$through" ] || return "$rc"
    case "$rc" in
      0)
        MS_RECONCILED=$((MS_RECONCILED + 1))
        printf 'model-switch-reconciled %s request=%s outcome=%s reason=%s live-model=%s live-effort=%s meta-model=%s meta-effort=%s\n' \
          "$ID" "$MS_A_ID" "$MS_A_OUTCOME" "${MS_A_REASON:--}" "${MS_A_AFTER_MODEL:--}" "${MS_A_AFTER_THINKING:--}" \
          "$(fm_meta_get "$META" model)" "$(fm_meta_get "$META" effort)" >&2
        ;;
      2)
        printf 'meta-stale %s request=%s reason=worker-generation-changed\n' "$ID" "$MS_A_ID" >&2
        ;;
      *)
        echo "warning: model-switch acknowledgement $ack could not be folded into task $ID's meta (status $rc); it stays unfolded" >&2
        return "$rc"
        ;;
    esac
  done <<EOF
$(ms_unfolded_acks)
EOF
  [ -z "$through" ]
}

# ms_channel_ready: the worker's extension must have activated this very
# incarnation and still be running. Sets MS_CHANNEL_WHY when it is not.
ms_channel_ready() {
  local state ready pid gen
  MS_CHANNEL_WHY=
  state=$(agent_state)
  case "$state" in
    alive|unverified) ;;
    dead|missing) MS_CHANNEL_WHY="no agent is running at its recorded endpoint (state: $state)"; return 1 ;;
    *) MS_CHANNEL_WHY="its endpoint reads '$state' rather than a positively attributed worker"; return 1 ;;
  esac
  ready="$MS_DIR/model-switch.ready"
  if [ ! -d "$MS_DIR" ] || [ -L "$MS_DIR" ] || [ ! -f "$ready" ] || [ -L "$ready" ]; then
    if [ -f "$MS_DIR/model-switch.failed" ]; then
      MS_CHANNEL_WHY="its extension could not activate the channel: $(head -c 300 "$MS_DIR/model-switch.failed" 2>/dev/null | tr '\n' ' ')"
    else
      MS_CHANNEL_WHY="it has no model-switch channel (it was launched before the verb existed, or its extension has not activated); relaunch it to load the current extension"
    fi
    return 1
  fi
  pid=$(jq -r --arg schema "$MS_READY_SCHEMA" 'select(.schema == $schema) | .pid // empty' "$ready" 2>/dev/null || true)
  gen=$(jq -r --arg schema "$MS_READY_SCHEMA" 'select(.schema == $schema) | .spawnGen // empty' "$ready" 2>/dev/null || true)
  if [ -z "$pid" ] || [ -z "$gen" ]; then
    MS_CHANNEL_WHY="its model-switch ready marker is unreadable"
    return 1
  fi
  if [ "$gen" != "$TASK_SPAWN_GEN" ]; then
    MS_CHANNEL_WHY="its ready marker belongs to worker generation $gen, not the recorded $TASK_SPAWN_GEN"
    return 1
  fi
  if ! fm_pid_alive "$pid"; then
    MS_CHANNEL_WHY="the extension process $pid that published its ready marker is not running"
    return 1
  fi
  return 0
}

ms_report_ack() {
  local ack=$1 rid=$2 fold_rc=0 verdict reason detail meta_state
  ms_read_ack "$ack" \
    || die "the acknowledgement for request $rid is unreadable ($ack); the live model is unknown"
  [ "$MS_A_ID" = "$rid" ] || die "the acknowledgement at $ack names request $MS_A_ID, not $rid"
  if [ "$MS_A_GEN" = "$TASK_SPAWN_GEN" ]; then
    case "$MS_A_OUTCOME:$MS_A_REASON" in
      refused:invalid-request) ;;
      *)
        [ "$MS_A_TARGET_MODEL" = "$NEW_MODEL" ] && [ "$MS_A_TARGET_EFFORT" = "$NEW_EFFORT" ] \
          || die "the acknowledgement for request $rid names a different target"
        ;;
    esac
  fi
  reconcile_model_switch "$ack" || fold_rc=$?
  if [ "$fold_rc" -ne 0 ]; then
    ms_read_ack "$ack" || return 1
    ms_verify_ack
    printf 'meta-stale %s request=%s live-model=%s live-effort=%s reason=fold-failed(status-%s) next="fm-control.sh %s switch-model --status"\n' \
      "$ID" "$rid" "${MS_A_AFTER_MODEL:--}" "${MS_A_AFTER_THINKING:--}" "$fold_rc" "$ID"
    return 1
  fi
  verdict=$MS_A_OUTCOME
  reason=$MS_A_REASON
  detail=$MS_A_DETAIL
  if [ "$MS_FOLD_UPDATED" = 1 ]; then
    meta_state="updated(model=$(fm_meta_get "$META" model) effort=$(fm_meta_get "$META" effort))"
  elif [ "$verdict" = applied ]; then
    meta_state=already-current
  else
    meta_state=unchanged
  fi
  detail=${detail//\"/\'}
  case "$verdict" in
    applied)
      printf 'switched %s request=%s model=%s->%s effort=%s->%s verified=extension-readback meta=%s backend=%s endpoint=%s\n' \
        "$ID" "$rid" "${MS_A_BEFORE_MODEL:--}" "$MS_A_AFTER_MODEL" "${MS_A_BEFORE_THINKING:--}" "${MS_A_AFTER_THINKING:--}" \
        "$meta_state" "$BACKEND" "$T"
      return 0
      ;;
    partial)
      printf 'partial %s request=%s target=%s model=%s->%s effort-requested=%s effort-live=%s reason=%s detail="%s" rolled-back=no meta=%s\n' \
        "$ID" "$rid" "$MS_A_TARGET_MODEL" "${MS_A_BEFORE_MODEL:--}" "$MS_A_AFTER_MODEL" "${NEW_EFFORT:--}" "${MS_A_AFTER_THINKING:--}" \
        "$reason" "$detail" "$meta_state"
      return 1
      ;;
    superseded)
      printf 'superseded %s request=%s reason=%s detail="%s" meta=%s\n' "$ID" "$rid" "$reason" "$detail" "$meta_state"
      return 1
      ;;
    *)
      printf 'refused %s request=%s target=%s reason=%s detail="%s" live-model=%s meta=%s\n' \
        "$ID" "$rid" "${MS_A_TARGET_MODEL:-$NEW_MODEL}" "${reason:-unspecified}" "$detail" "${MS_A_AFTER_MODEL:--}" "$meta_state"
      return 1
      ;;
  esac
}

do_switch_model() {
  local rid req ack staged started now_us remaining reason=deadline-before-claim
  reconcile_model_switch || true
  ms_channel_ready || die "task $ID's worker cannot take a model switch: $MS_CHANNEL_WHY"
  if ! started=$(ms_mono_us) || [[ ! "$started" =~ ^[0-9]+$ ]]; then
    die "the Perl Time::HiRes monotonic clock is unavailable; no model-switch request was published"
  fi
  printf -v rid 'ms-%016d-%04x%04x' "$started" "$RANDOM" "$RANDOM"
  req=$(ms_path "$rid" request.json)
  ack=$(ms_path "$rid" ack.json)
  staged="$MS_DIR/.model-switch.$rid.staging.${BASHPID:-$$}"
  if ! ( umask 077
         jq -n --arg schema "$MS_REQUEST_SCHEMA" --arg id "$rid" --arg gen "$TASK_SPAWN_GEN" \
           --arg model "$NEW_MODEL" --arg effort "$NEW_EFFORT" --argjson at "$started" \
           '{schema: $schema, id: $id, spawnGen: $gen, model: $model,
             effort: (if $effort == "" then null else $effort end), requestedAtMonotonicUs: $at}' > "$staged" ) \
  then
    rm -f -- "$staged"
    die "the model-switch request could not be written under $MS_DIR"
  fi
  if ! mv -f -- "$staged" "$req"; then
    rm -f -- "$staged"
    die "the model-switch request could not be published under $MS_DIR"
  fi
  while :; do
    if ! now_us=$(ms_mono_us) || [[ ! "$now_us" =~ ^[0-9]+$ ]]; then
      reason=monotonic-clock-unavailable
      break
    fi
    remaining=$(( MODEL_WAIT * 1000000 - (now_us - started) ))
    [ "$remaining" -gt 0 ] || break
    if [ -f "$ack" ]; then
      ms_report_ack "$ack" "$rid"
      return $?
    fi
    sleep "$(awk -v left="$remaining" 'BEGIN { nap = left / 1000000; if (nap > 0.25) nap = 0.25; printf "%.6f", nap }')"
  done
  # One non-waiting look before the outcome is called unknown: a receipt that
  # landed during the last nap is a result, not a pending request.
  if [ -f "$ack" ]; then
    ms_report_ack "$ack" "$rid"
    return $?
  fi
  if mv -- "$req" "$(ms_path "$rid" cancelled)" 2>/dev/null; then
    printf 'cancelled %s request=%s target=%s reason=%s waited=%ss proof=request-withdrawn-before-claim meta=unchanged\n' \
      "$ID" "$rid" "$NEW_MODEL" "$reason" "$MODEL_WAIT"
    return 1
  fi
  printf 'pending-unknown %s request=%s target=%s state=claimed-unacknowledged reason=%s waited=%ss live-model=unknown meta=not-updated next="fm-control.sh %s switch-model --status"\n' \
    "$ID" "$rid" "$NEW_MODEL" "$reason" "$MODEL_WAIT" "$ID"
  return 1
}

# Every request id the directory holds a file for, oldest first.
ms_request_ids() {
  local f base
  for f in "$MS_DIR"/model-switch.*; do
    [ -f "$f" ] || continue
    base=${f##*/model-switch.}
    case "$base" in
      *.request.json) printf '%s\n' "${base%.request.json}" ;;
      *.processing) printf '%s\n' "${base%.processing}" ;;
      *.cancelled) printf '%s\n' "${base%.cancelled}" ;;
      *.ack.json) printf '%s\n' "${base%.ack.json}" ;;
      *.ack.json.folded) printf '%s\n' "${base%.ack.json.folded}" ;;
    esac
  done | LC_ALL=C sort -u
}

# The id of the newest acknowledgement by its emitted sequence.
ms_latest_ack_id() {
  local f order
  for f in "$MS_DIR"/model-switch.*.ack.json "$MS_DIR"/model-switch.*.ack.json.folded; do
    [ -f "$f" ] || continue
    order=$(jq -r 'select((.ackSequence | type) == "number") | .ackSequence' "$f" 2>/dev/null) || order=
    [ -n "$order" ] || continue
    printf '%s\t%s\n' "$order" "$f"
  done | LC_ALL=C sort -n | tail -1 | cut -f2 | sed 's|.*/model-switch\.||; s|\.ack\.json.*$||'
}

# The state of one request, with acknowledgement and reconciliation distinct.
ms_request_state() {  # <request-id>
  local ack
  ack=$(ms_path "$1" ack.json.folded)
  if [ -f "$(ms_path "$1" ack.json)" ]; then
    echo acknowledged-unfolded
  elif ms_read_ack "$ack"; then
    # A validated folded receipt is the terminal result even when a crash left
    # the claim file behind.
    ms_verify_ack
    echo "$MS_A_OUTCOME"
  elif [ -f "$(ms_path "$1" processing)" ]; then
    echo claimed-unacknowledged
  elif [ -f "$(ms_path "$1" request.json)" ]; then
    echo queued
  elif [ -f "$(ms_path "$1" cancelled)" ]; then
    echo cancelled
  else
    echo unknown
  fi
}

do_switch_status() {
  local channel=ready id state unresolved=0 last_id=none last_state=none latest
  ms_channel_ready || channel="not-ready($MS_CHANNEL_WHY)"
  reconcile_model_switch || true
  if [ -d "$MS_DIR" ] && [ ! -L "$MS_DIR" ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      state=$(ms_request_state "$id")
      case "$state" in
        queued|claimed-unacknowledged|acknowledged-unfolded|unknown)
          unresolved=$((unresolved + 1))
          echo "unresolved $ID request=$id state=$state"
          ;;
      esac
      last_id=$id
      last_state=$state
    done <<EOF
$(ms_request_ids)
EOF
  fi
  latest=$(ms_latest_ack_id)
  if [ -n "$latest" ]; then
    last_id=$latest
    last_state=$(ms_request_state "$latest")
  fi
  printf 'model-switch-status %s meta-model=%s meta-effort=%s channel=%s reconciled=%s unresolved=%s last-request=%s last-state=%s\n' \
    "$ID" "$(fm_meta_get "$META" model)" "$(fm_meta_get "$META" effort)" "$channel" \
    "$MS_RECONCILED" "$unresolved" "$last_id" "$last_state"
  [ "$channel" = ready ] && [ "$unresolved" -eq 0 ]
}

# --- transactional relaunch -------------------------------------------------
#
# The transaction's durable record is state/<id>.control-relaunch, with the
# prior metadata and brief preserved beside it. Every failure path runs through
# relaunch_rollback (an EXIT trap, so a refusal raised deep inside a shared
# helper is covered too) and leaves either the pre-relaunch durable record or a
# concrete, named partial state - never a task whose record claims an agent
# that is not running.

JOURNAL="$STATE/$ID.control-relaunch"
META_PRIOR="$JOURNAL.meta-prior"
BRIEF_PRIOR="$JOURNAL.brief-prior"
NOTE_FILE="$JOURNAL.note"
RELAUNCH_META_PUBLISHED=0
RELAUNCH_AGENT_CONFIRMED=0
RELAUNCH_TX=
RELAUNCH_BRIEF=
PRIOR_HARNESS=$HARNESS
PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
CONFIG_HARNESS=
CONFIG_MODEL=
CONFIG_EFFORT=
PRIOR_MODEL=
PRIOR_EFFORT=
TARGET_HARNESS=$HARNESS
TARGET_MODEL=
TARGET_EFFORT=

# stall_relaunch_cancel: cancel the supervised --stall-record relaunch cleanly
# after the checkpoint/note work has run. Restores the worker's instructions
# byte-exact (record_note appended the progress note), journals the named
# cancellation phase, and exits with <code> for the supervised caller. Reads
# do_relaunch's note_line through bash's dynamic scope; only ever called from
# inside it. A restore failure is a hard error, not a clean cancel.
stall_relaunch_cancel() {  # <phase> <message> <code>
  local phase=$1 message=$2 code=$3
  if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
    if ! cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null; then
      RELAUNCH_ACTIVE=0
      journal_write "failed:$phase" "rollback=instructions-restore-failed" "${CHECKPOINT_LINES[@]}" "$note_line" || true
      die "relaunch cancelled ($phase), but restoring the original instructions failed"
    fi
  fi
  journal_write "cancelled:$phase" "${CHECKPOINT_LINES[@]}" "$note_line" || true
  echo "relaunch cancelled: $message" >&2
  exit "$code"
}

journal_write() {  # <phase> [extra-line]...
  local phase=$1
  shift
  if {
    echo "v1"
    echo "task=$ID"
    echo "phase=$phase"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "backend=$BACKEND"
    echo "endpoint=$T"
    echo "worktree=$WT"
    echo "kind=$KIND"
    echo "from_harness=$PRIOR_RECORDED_HARNESS"
    echo "from_model=$PRIOR_MODEL"
    echo "from_effort=$PRIOR_EFFORT"
    echo "to_harness=$TARGET_HARNESS"
    echo "to_model=$TARGET_MODEL"
    echo "to_effort=$TARGET_EFFORT"
    local line
    for line in "$@"; do
      echo "$line"
    done
  } > "$JOURNAL.tmp" && mv -f "$JOURNAL.tmp" "$JOURNAL"; then
    RELAUNCH_PHASE=$phase
    return 0
  fi
  return 1
}

relaunch_rollback() {
  local state
  [ "$RELAUNCH_ACTIVE" = 1 ] || return 0
  [ "$RELAUNCH_PHASE" != complete ] || return 0
  RELAUNCH_ACTIVE=0
  case "$RELAUNCH_PHASE" in
    checkpoint|noted)
      # The old agent was never touched. Restore the instructions byte-exact so
      # a refused relaunch leaves nothing behind.
      if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
        cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
      fi
      journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored" || true
      echo "error: relaunch of $ID was refused before its agent was touched; nothing changed" >&2
      ;;
    stopping)
      state=$(agent_state 2>/dev/null || printf unknown)
      case "$state" in
        alive)
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-alive" || true
          echo "error: relaunch of $ID failed while stopping the old agent, which is still running; its original instructions were restored" >&2
          ;;
        dead)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept-agent-dead" || true
          echo "error: $ID's agent stopped but relaunch did not reach replacement launch; no agent is running, and its work plus progress note are preserved at $WT" >&2
          ;;
        *)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=none-agent-state-$state" || true
          echo "error: relaunch of $ID failed while stopping the old agent and its state is '$state'; the durable record and progress note were retained for recovery" >&2
          ;;
      esac
      ;;
    exited|launching)
      if [ "$RELAUNCH_AGENT_CONFIRMED" = 1 ]; then
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-agent-confirmed" || true
        echo "error: $ID's replacement is running on $TARGET_HARNESS, but transaction completion could not be persisted; its published record was retained for reconciliation" >&2
      elif [ "$RELAUNCH_META_PUBLISHED" = 1 ] \
         || { [ -n "$RELAUNCH_TX" ] \
              && [ "$(fm_meta_get "$META" control_relaunch_tx)" = "$RELAUNCH_TX" ]; }; then
        # The launch owner published the new incarnation's record. Leaving it
        # in place is the honest state: the task is now recorded on the new
        # harness with no agent confirmed, which is exactly what recovery
        # reconciles. Rewriting it back to the old harness would be a second,
        # worse inaccuracy.
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-record-kept" || true
        echo "error: $ID was relaunched on $TARGET_HARNESS but no running agent could be confirmed; its work is preserved at $WT" >&2
      else
        journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept" || true
        echo "error: $ID's agent was stopped but the replacement did not launch; no agent is running, and its work plus the recorded progress note are preserved at $WT" >&2
      fi
      ;;
  esac
  return 0
}

resolve_relaunch_profile() {
  PRIOR_HARNESS=$HARNESS
  PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
  PRIOR_MODEL=$(fm_meta_get "$META" model)
  PRIOR_EFFORT=$(fm_meta_get "$META" effort)
  [ -n "$PRIOR_MODEL" ] || PRIOR_MODEL=default
  [ -n "$PRIOR_EFFORT" ] || PRIOR_EFFORT=default
  if [ "$HARNESS_SET" = 0 ] \
     && [ "$PRIOR_RECORDED_HARNESS" != "$PRIOR_HARNESS" ]; then
    die "task $ID records harness '$PRIOR_RECORDED_HARNESS', whose original launch command cannot be reconstructed from its recorded basename; relaunching without --harness would substitute the canonical adapter '$PRIOR_HARNESS' for the command actually running. Pass an explicit --harness to choose the replacement runtime deliberately"
  fi
  CONFIG_HARNESS=
  CONFIG_MODEL=
  CONFIG_EFFORT=
  if [ "$KIND" = secondmate ]; then
    # A secondmate's harness, model, and effort are a durable configured pin
    # that every respawn re-resolves (the secondmate-provisioning contract), so
    # a relaunch with no explicit harness picks up a newly configured one
    # instead of freezing whatever this incarnation happens to run. Crewmates
    # and scouts deliberately do NOT resolve config here: their harness comes
    # from firstmate's own dispatch-profile judgment at intake, and silently
    # re-resolving it would bypass that consultation.
    CONFIG_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" secondmate 2>/dev/null || true)
    CONFIG_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model 2>/dev/null || true)
    CONFIG_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort 2>/dev/null || true)
    case "$CONFIG_EFFORT" in
      ''|low|medium|high|xhigh|max) ;;
      *)
        echo "warning: config/secondmate-harness effort token '$CONFIG_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2
        CONFIG_EFFORT=
        ;;
    esac
  fi
  if [ "$HARNESS_SET" = 1 ]; then
    fm_control_harness_supported "$NEW_HARNESS" \
      || die "'$NEW_HARNESS' is not a verified harness; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$NEW_HARNESS
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    fm_control_harness_supported "$CONFIG_HARNESS" \
      || die "the configured secondmate harness '$CONFIG_HARNESS' is not verified; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$CONFIG_HARNESS
  else
    TARGET_HARNESS=$PRIOR_HARNESS
  fi
  # The launch owner refuses an adapter that cannot run this task's kind, but it
  # is only reached after the old agent has been stopped. Asking the same
  # capability table here keeps that refusal on the pre-stop side of the
  # transaction, where nothing has changed yet.
  fm_control_harness_supports_kind "$TARGET_HARNESS" "$KIND" \
    || die "'$TARGET_HARNESS' is not verified to run a $KIND task, so relaunching $ID onto it would stop the running agent for a launch that must be refused; choose an adapter verified for this kind"
  # A model or effort chosen for the previous harness does not transfer to a
  # different one, so an explicit harness change resets both axes unless the
  # caller names them too.
  if [ "$MODEL_SET" = 1 ]; then
    TARGET_MODEL=$NEW_MODEL
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_MODEL=${CONFIG_MODEL:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_MODEL=$PRIOR_MODEL
  else
    TARGET_MODEL=default
  fi
  if [ "$EFFORT_SET" = 1 ]; then
    TARGET_EFFORT=$NEW_EFFORT
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_EFFORT=${CONFIG_EFFORT:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_EFFORT=$PRIOR_EFFORT
    if fm_control_model_switch_supported "$PRIOR_HARNESS" "$KIND"; then
      case "$TARGET_EFFORT" in
        low|medium|high|xhigh|max) ;;
        *) TARGET_EFFORT=default ;;
      esac
    fi
  else
    TARGET_EFFORT=default
  fi
}

# safe_checkpoint: prove, before anything is stopped, that the work a relaunch
# must preserve is actually there and recoverable afterwards. Fills
# CHECKPOINT_LINES with the journal lines describing what it proved, and
# refuses outright when any of it cannot be established.
CHECKPOINT_LINES=()
safe_checkpoint() {
  local wt_real wt_top wt_top_real head head_ref head_ref_status status_output dirty children marker child_meta
  CHECKPOINT_LINES=()
  [ -n "$WT" ] || die "task $ID has no recorded worktree; refusing to relaunch without a recorded local copy to preserve"
  [ -d "$WT" ] || die "task $ID's recorded worktree $WT is missing; refusing to relaunch and lose track of its work"
  wt_real=$(cd "$WT" 2>/dev/null && pwd -P) || die "task $ID's recorded worktree $WT cannot be resolved"
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) \
    || die "task $ID's recorded worktree $WT is not a git worktree; refusing to relaunch without a checkout whose unlanded work can be accounted for"
  wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P) || wt_top_real=$wt_top
  [ "$wt_real" = "$wt_top_real" ] \
    || die "task $ID's recorded worktree $WT is not a worktree root (root is $wt_top); refusing to relaunch against an ambiguous checkout"
  if head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null); then
    :
  elif head_ref=$(git -C "$WT" symbolic-ref -q HEAD 2>/dev/null); then
    if git -C "$WT" show-ref --verify --quiet "$head_ref" 2>/dev/null; then
      die "task $ID's worktree HEAD exists but cannot be resolved; refusing to relaunch from an unreadable checkout"
    else
      head_ref_status=$?
      [ "$head_ref_status" -eq 1 ] \
        || die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
      head=unborn
    fi
  else
    die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
  fi
  status_output=$(git -C "$WT" status --porcelain 2>/dev/null) \
    || die "task $ID's worktree status cannot be inspected; refusing to relaunch without accounting for local changes"
  if [ -n "$status_output" ]; then
    dirty=yes
  else
    dirty=no
  fi
  CHECKPOINT_LINES+=("worktree_head=$head" "worktree_dirty=$dirty")
  if [ "$KIND" = secondmate ]; then
    # A secondmate's own crewmates outlive its relaunch: they run in their own
    # endpoints, and the relaunched secondmate reconciles them from its home's
    # durable records at startup. The checkpoint proves those records are
    # readable BEFORE the agent stops, so a relaunch can never strand child
    # work behind an unreadable home.
    marker=$(cat "$WT/.fm-secondmate-home" 2>/dev/null || true)
    [ "$marker" = "$ID" ] \
      || die "task $ID's home $WT is not marked as its own seeded secondmate home (marker: ${marker:-none}); refusing to relaunch"
    # Do not walk state/ with find(1): watcher scratch files can vanish
    # mid-scan and make find fail even when every child *.meta is readable.
    [ -d "$WT/state" ] && [ -r "$WT/state" ] && [ -x "$WT/state" ] \
      || die "secondmate $ID's home has no readable state directory, so its child work cannot be accounted for; refusing to relaunch"
    children=0
    for child_meta in "$WT/state"/*.meta; do
      if [ ! -e "$child_meta" ] && [ ! -L "$child_meta" ]; then
        continue
      fi
      if [ ! -f "$child_meta" ] || [ -L "$child_meta" ] \
         || ! cat "$child_meta" >/dev/null 2>&1; then
        die "secondmate $ID's child record $child_meta is not a readable regular file; refusing to relaunch"
      fi
      children=$((children + 1))
    done
    CHECKPOINT_LINES+=("children=$children")
  fi
}

# record_note: put the required progress note somewhere durable, and - for a
# ship or scout, whose only record of the interrupted reasoning is the
# conversation about to be discarded - into the instructions the replacement
# actually reads. A secondmate's charter is a durable standing document and is
# never rewritten: a secondmate reconciles its own home's records at startup,
# so the note stays parent-side audit evidence.
record_note() {
  local stamp
  [ -n "$NOTE" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$NOTE" > "$NOTE_FILE"
  case "$KIND" in
    ship|scout)
      cp -p "$RELAUNCH_BRIEF" "$BRIEF_PRIOR" \
        || die "could not preserve task $ID's instructions before recording the progress note"
      {
        echo
        echo "## Progress note ($stamp)"
        echo
        echo "This task was relaunched. Continue from here; the local copy and every"
        echo "uncommitted change are exactly as the previous worker left them."
        echo
        echo "First, check your instruction inbox: list $STATE/$ID.inbox/*.msg, act on"
        echo "each message in numeric order, then mv each handled file into"
        echo "$STATE/$ID.inbox/handled/. A steer sent before the relaunch survives there."
        echo
        printf '%s\n' "$NOTE"
      } >> "$RELAUNCH_BRIEF" \
        || die "could not append the progress note to task $ID's instructions"
      ;;
  esac
}

do_relaunch() {
  local exit_result state note_line stall_oldest
  local -a spawn_args

  stall_relaunch_absence_guard() {
    state=$(agent_state)
    [ -n "$STALL_RECORD" ] || return 0
    case "$state" in
      dead|missing) ;;
      *) die "supervised relaunch refused: endpoint state '$state' is not positively absent" ;;
    esac
  }

  require_state_verified_backend relaunch
  resolve_relaunch_profile

  case "$KIND" in
    ship|scout)
      RELAUNCH_BRIEF="$DATA/$ID/brief.md"
      [ -f "$RELAUNCH_BRIEF" ] \
        || die "task $ID has no instructions at $RELAUNCH_BRIEF; refusing to relaunch a worker with nothing to work from"
      [ "$NOTE_SET" = 1 ] && [ -n "$NOTE" ] \
        || die "relaunch of a $KIND task requires --note (or --note-file): the replacement worker inherits the local copy but none of the conversation, so it must be told what happened"
      ;;
    secondmate)
      # The charter in the secondmate's own home is its instruction source and
      # stays untouched.
      RELAUNCH_BRIEF=
      ;;
    *)
      die "task $ID records kind '$KIND', which has no defined relaunch shape"
      ;;
  esac

  if [ "$KIND" = scout ]; then
    if grep -F '{TASK}' "$RELAUNCH_BRIEF" >/dev/null 2>&1 \
       || [[ "$NOTE" == *'{TASK}'* ]]; then
      die "scout brief or progress note still contains {TASK}; replace every scaffold placeholder before relaunch"
    fi
  fi

  if [ -n "$NOTE" ]; then
    note_line="note_file=$NOTE_FILE"
  else
    note_line="note=none"
  fi
  safe_checkpoint
  if [ "$KIND" = secondmate ]; then
    secondmate_spawn_brief "$WT" "$DATA/$ID/brief.md" >/dev/null || exit 1
  fi
  cp -p "$META" "$META_PRIOR" || die "could not preserve task $ID's durable record before relaunching"
  RELAUNCH_ACTIVE=1
  journal_write checkpoint "${CHECKPOINT_LINES[@]}" "$note_line"

  record_note
  journal_write noted "${CHECKPOINT_LINES[@]}" "$note_line"

  # Final stall-record re-check, inside the lifecycle lock and immediately
  # before the agent is touched: the caller's own pre-invocation proof cannot
  # cover the gap to this point, so a record handled or superseded in flight
  # must still cancel the relaunch here. Exit 3 is the dedicated "instruction
  # resolved; nothing to do" code the supervised caller maps to recovered. The
  # brief is restored byte-exact before the cancelled journal write so the
  # rollback trap has nothing left to do and the worker's instructions stay
  # untouched when no relaunch happened.
  if [ -n "$STALL_RECORD" ]; then
    if stall_oldest=$(fm_task_inbox_oldest_unhandled "$STATE" "$ID" 2>/dev/null); then
      :
    else
      stall_oldest_rc=$?
      [ "$stall_oldest_rc" -eq 1 ] \
        && stall_relaunch_cancel record-resolved "stall record resolved (inbox empty; instruction handled)" 3
      die "relaunch refused: stall inbox is unreadable inside the lifecycle lock"
    fi
    if [ -z "$stall_oldest" ]; then
      stall_relaunch_cancel record-resolved "stall record resolved (inbox empty; instruction handled)" 3
    elif [ "${stall_oldest##*/}" != "$STALL_RECORD" ]; then
      stall_relaunch_cancel record-resolved "stall record $STALL_RECORD handled or superseded (${stall_oldest##*/} is now oldest)" 3
    fi
  fi

  journal_write stopping "${CHECKPOINT_LINES[@]}" "$note_line"
  stall_relaunch_absence_guard
  if [ "$state" = dead ] || [ "$state" = missing ]; then
    # The recorded endpoint is authoritatively absent, so there is no agent to
    # stop: the exit phase is already complete and the launch below recreates
    # the endpoint in the checkpointed worktree. Only a proven-missing endpoint
    # skips do_exit - every other state still has a live or unprovable pane
    # behind it, and `fm-control exit` on a missing endpoint still refuses.
    exit_result=already-stopped
  else
    exit_result=$(do_exit)
  fi
  retire_busy_incarnation
  if fm_control_model_switch_supported "$PRIOR_HARNESS" "$KIND"; then
    reconcile_model_switch || die "could not reconcile the stopped worker's model switch"
    cp -p "$META" "$META_PRIOR" || die "could not preserve the reconciled task record"
    resolve_relaunch_profile
  fi
  journal_write exited "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"

  if [ "$KIND" = secondmate ] && [ "$PRIOR_HARNESS" = omp ]; then
    fm_control_omp_secondmate_prepare_relaunch "$STATE" "$ID" "$WT" "$BACKEND" "$T" "$META" \
      || die "the OMP secondmate endpoint is not authoritatively absent after graceful exit"
  fi

  # The launch owner clears the previous incarnation's per-task harness wiring
  # before arming the new one, so nothing to do here.
  RELAUNCH_TX="${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  journal_write launching "${CHECKPOINT_LINES[@]}" "$note_line" "relaunch_tx=$RELAUNCH_TX"
  stall_relaunch_absence_guard
  if [ "$KIND" = secondmate ] && [ "$PRIOR_HARNESS" = omp ]; then
    spawn_args=("$ID" --secondmate --harness "$TARGET_HARNESS")
  else
    spawn_args=("$ID" --relaunch --harness "$TARGET_HARNESS")
  fi
  [ "$BACKEND_SET" = 0 ] || spawn_args+=(--backend "$PIN_BACKEND")
  [ "$TARGET_MODEL" = default ] || spawn_args+=(--model "$TARGET_MODEL")
  [ "$TARGET_EFFORT" = default ] || spawn_args+=(--effort "$TARGET_EFFORT")
  # FM_RESTART_SPAWN_CMD replaces the launch owner (default: bin/fm-spawn.sh) so
  # tests/fm-secondmate-restart.test.sh can drive a relaunch without starting a
  # real agent; unset, this is the ordinary launch and the behavior is unchanged.
  if FM_CONTROL_RELAUNCH_TX="$RELAUNCH_TX" \
      FM_CONTROL_RELAUNCH_LOCK_OWNER="$(cat "$CONTROL_LOCK/pid")" \
      "${FM_RESTART_SPAWN_CMD:-$SCRIPT_DIR/fm-spawn.sh}" "${spawn_args[@]}" >/dev/null; then
    RELAUNCH_META_PUBLISHED=1
  else
    [ "$(fm_meta_get "$META" control_relaunch_tx)" != "$RELAUNCH_TX" ] \
      || RELAUNCH_META_PUBLISHED=1
    die "the replacement agent for $ID could not be launched on $TARGET_HARNESS"
  fi

  # The launch owner republished the endpoint record; a relaunch that
  # recreated a proven-missing endpoint carries fresh endpoint ids, and the
  # aliveness wait below must poll the endpoint that actually exists now.
  fm_backend_validate_task_endpoint "$META" "$ID" \
    || die "the replacement agent for $ID published unusable endpoint metadata"
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  T=$FM_BACKEND_VALIDATED_TARGET

  state=$(wait_agent_state "$LAUNCH_WAIT" alive) || {
    die "the replacement agent for $ID did not come up within ${LAUNCH_WAIT}s (endpoint reads '$state')"
  }
  RELAUNCH_AGENT_CONFIRMED=1

  journal_write complete "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result" "relaunch_tx=$RELAUNCH_TX"
  RELAUNCH_ACTIVE=0
  echo "relaunched $ID harness=$TARGET_HARNESS from=$PRIOR_RECORDED_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT"
}

# --- verbs ------------------------------------------------------------------

# Fold any model-switch acknowledgement not yet applied to meta - including one
# that arrived after its own verb stopped waiting - before any other verb acts,
# so every verb, relaunch most of all, sees the live model. switch-model does
# its own reconcile so it can report the count.
if [ "$VERB" != switch-model ] && fm_control_model_switch_supported "$HARNESS" "$KIND"; then
  reconcile_model_switch || true
fi

case "$VERB" in
  interrupt)
    state=$(agent_state)
    case "$state" in
      alive) ;;
      unverified)
        # No recovery-grade classifier on this backend. Interrupt is
        # non-destructive and its endpoint-existence postcondition is still
        # real, so it proceeds - the printed proof names exactly what was
        # verified rather than implying more.
        ;;
      dead|missing) die "no agent is running at task $ID's recorded endpoint (state: $state); there is nothing to interrupt" ;;
      *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle key into an unattributed endpoint" ;;
    esac
    proof=$(do_interrupt)
    if fm_control_model_switch_supported "$HARNESS" "$KIND"; then reconcile_model_switch || true; fi
    echo "interrupt-delivered $ID harness=$HARNESS backend=$BACKEND verified=$proof"
    ;;
  exit)
    result=$(do_exit)
    retire_busy_incarnation
    if fm_control_model_switch_supported "$HARNESS" "$KIND"; then reconcile_model_switch || true; fi
    echo "$result $ID harness=$HARNESS backend=$BACKEND endpoint=$T worktree=$WT"
    ;;
  relaunch)
    do_relaunch
    ;;
  switch-model)
    switch_rc=0
    if [ "$STATUS_SET" = 1 ]; then
      do_switch_status || switch_rc=$?
    else
      do_switch_model || switch_rc=$?
    fi
    exit "$switch_rc"
    ;;
esac
