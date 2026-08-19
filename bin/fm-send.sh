#!/usr/bin/env bash
# Send one line of literal text to a crewmate endpoint, then Enter.
# Usage: fm-send.sh <target> [--resolve-key <key>]... <text...>
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit well-formed backend
#   target. fm-send refuses unresolved guesses rather than falling back to a
#   tmux window search, because a "successful" send to the wrong endpoint is
#   worse than a loud failure.
# Special keys instead of text: fm-send.sh <target> --key Enter
# Key support is backend-specific: tmux/herdr support Escape, Enter, and C-c;
# Orca currently supports Enter and C-c only, and rejects Escape.
#
# Text submission is verified: the line is typed ONCE, then Enter is sent and
# retried (Enter only, never retyped) until the target backend confirms a
# submit or reports an inconclusive send. If a swallowed Enter is positively
# confirmed, fm-send exits NON-ZERO so the caller knows the steer did not land
# instead of silently leaving an unsubmitted instruction.
# For an OMP target, a confirmed idle submit must also start a real turn within
# FM_SEND_TURNSTART_TIMEOUT (default 1 second, maximum 3 seconds), sampled every
# FM_SEND_TURNSTART_POLL (default 0.1 second). The proof is the existing backend
# busy reader or advancement of the generated OMP turn-start marker. A confirmed
# submit with no turn returns `delivered-no-turn` on stderr and exits 4. A
# task-bound target also receives an actionable status event and durable watcher
# wake so supervised recovery starts promptly without an automatic terminate or
# relaunch.
# An already-busy OMP pane has one narrow exception: a successfully transported
# Enter may return `queued-unconfirmed`, which fm-send accepts as queued delivery
# while preserving failures for transport errors and non-busy pending input.
# Submission dispatches through the target's recorded backend; the tmux adapter
# shares its composer/submit core with the away-mode daemon via bin/fm-tmux-lib.sh.
# Tune submit confirmation with FM_SEND_RETRIES (default 3) / FM_SEND_SLEEP
# (0.4).
# Slash commands, and codex `$...` skill invocations resolved through harness
# meta, get a longer pre-Enter settle so completion popups do not swallow Enter.
#
# From-firstmate marker: when the resolved target is a task selector whose meta
# records kind=secondmate, the text uses the live-charter-compatible
# from-firstmate carrier owned by bin/fm-operational-input.sh so the secondmate
# routes its reply via its status file or a status-pointed doc instead of
# stranding it in chat the main firstmate never reads. A crewmate/scout target,
# an explicit backend-target escape-hatch target, and the --key path are never
# marked - their behavior is unchanged.
# Decision closure (answerer-closes): pass --resolve-key <key> (repeatable,
# before the message) when this send answers an open keyed needs-decision: or
# blocked: record in the target task's state/<id>.status. After delivery is
# confirmed and any required OMP turn-start verification succeeds, fm-send
# itself appends the closing
# "resolved [key=<key>]: answered: <capped excerpt>" line to that status file,
# so the captain-facing OPEN DECISIONS record closes at answer time and never
# depends on the busy worker writing a matching resolved line. The close is a
# LOCAL append for every target kind - crewmate, scout, local secondmate, and
# remote secondmate alike - because the open-decision ledger fm-wake-drain
# folds lives in this home's own state dir (a remote mate's escalations reach
# it through the parent-replies ingest); only the answer message crosses the
# backend or remote transport. Each named key must currently be open in that
# ledger per status_open_decisions (bin/fm-classify-lib.sh) or fm-send refuses
# before sending, so a mistyped key cannot deliver an answer while silently
# orphaning the decision. A failed or unconfirmed send never closes a key; a
# delivered answer whose closing append fails exits nonzero with the exact
# manual close command, leaving the decision open to re-surface (the safe
# direction). A send without the flag never closes anything: a routine steer,
# working:, or done: event still cannot clear a captain decision. The flag is
# refused with --key, with an explicit backend target (no task ledger in this
# home), and with an empty message.
#
# Parent-owned pending-reply expectation: every newly marked secondmate request
# also receives a privacy-safe correlation id and a durable parent record under
# state/pending-replies/ before delivery (bin/fm-pending-reply-lib.sh). Delivery
# success and reply success are separate facts: a successful submit never
# resolves the expectation. Set FM_PENDING_REPLY_EXISTING_CORR=<id> when
# re-sending a recovery request for an already-open expectation so a second
# record is not created. Direct unmarked captain input never creates one.
#
# After a successful text submit fm-send pauses FM_SEND_SETTLE seconds (default 1,
# 0 disables) before returning: submit confirmation only proves the text was
# accepted, but the harness needs a beat to spin up the turn before its busy
# footer appears, so an immediate peek would otherwise see the stale idle pane.
# The pause is fm-send-only; the shared submit core (used by the away-mode daemon,
# which only needs "submitted") does not pay it, and the --key path is unaffected.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never steer
# a crewmate (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-send refuses to resolve targets without an explicit firstmate home" >&2
  exit 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory; fm-send cannot resolve this home's state" >&2
  exit 1
fi
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-send cannot resolve targets for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-runpod-lib.sh
. "$SCRIPT_DIR/fm-runpod-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

RUNPOD_DELIVERY_LOCK=
TARGET_OMP_TURNSTART_REFERENCE=
release_runpod_delivery_lock() {
  [ -n "$RUNPOD_DELIVERY_LOCK" ] || return 0
  fm_lock_release "$RUNPOD_DELIVERY_LOCK"
  RUNPOD_DELIVERY_LOCK=
}
fm_send_cleanup() {
  release_runpod_delivery_lock
  [ -z "$TARGET_OMP_TURNSTART_REFERENCE" ] || rm -f -- "$TARGET_OMP_TURNSTART_REFERENCE"
}
trap fm_send_cleanup EXIT
# Answer notes use the same bounded status-line shape as the OPEN DECISIONS
# renderer without adding a second shared helper to this fork.
fm_send_resolved_line() {  # <key> <note>
  local key=$1 note=$2 prefix suffix=' [truncated]' max=220 keep
  prefix="resolved [key=$key]: answered: "
  keep=$((max - ${#prefix}))
  [ "$keep" -ge 0 ] || keep=0
  if [ "${#note}" -gt "$keep" ]; then
    if [ "$keep" -ge "${#suffix}" ]; then
      note="${note:0:$((keep - ${#suffix}))}$suffix"
    else
      note=
    fi
  fi
  FM_SEND_RESOLVED_LINE="$prefix$note"
}

FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the requested message WILL still be sent.' "$SCRIPT_DIR/fm-guard.sh" || true

fm_send_id_from_meta() {  # <meta-file>
  local base
  base=${1##*/}
  printf '%s' "${base%.meta}"
}

fm_send_record_interrupt() {  # <key>
  local key=$1 id gen
  [ "$key" = Escape ] || return 0
  case "$TARGET_HARNESS" in claude*) : ;; *) return 0 ;; esac
  [ -n "$TARGET_META" ] || return 0
  id=$(fm_send_id_from_meta "$TARGET_META")
  [ -f "$STATE/$id.busy-gen" ] || return 0
  gen=$(fm_meta_get "$TARGET_META" busy_gen)
  if [ -n "$gen" ]; then
    "$FM_ROOT/bin/fm-busy-event.sh" apply "$STATE" "$id" idle \
      --gen "$gen" --source fm-interrupt --event interrupt
  else
    "$FM_ROOT/bin/fm-busy-event.sh" apply "$STATE" "$id" idle \
      --current-gen --source fm-interrupt --event interrupt
  fi || {
    echo "error: key '$key' reached $T, but the Claude interrupt state could not be recorded for $id" >&2
    return 1
  }
}

fm_send_meta_for_key_value() {  # <state-dir> <key> <value>
  local state=$1 key=$2 value=$3 meta got
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    got=$(fm_meta_get "$meta" "$key")
    [ "$got" = "$value" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_send_count_colons() {  # <string>
  local s=$1 no_colons
  no_colons=${s//:/}
  printf '%s' $(( ${#s} - ${#no_colons} ))
}

fm_send_validate_turnstart_config() {
  FM_SEND_TURNSTART_TIMEOUT_VALUE=${FM_SEND_TURNSTART_TIMEOUT:-1}
  FM_SEND_TURNSTART_POLL_VALUE=${FM_SEND_TURNSTART_POLL:-0.1}
  if ! awk -v timeout="$FM_SEND_TURNSTART_TIMEOUT_VALUE" \
    -v poll="$FM_SEND_TURNSTART_POLL_VALUE" \
    'BEGIN {
      number = "^([0-9]+([.][0-9]*)?|[.][0-9]+)$"
      exit !(timeout ~ number && poll ~ number && timeout >= 0.1 && timeout <= 3 && poll >= 0.02 && poll <= timeout)
    }'; then
    echo "error: FM_SEND_TURNSTART_TIMEOUT must be 0.1..3 seconds and FM_SEND_TURNSTART_POLL must be 0.02..timeout" >&2
    return 1
  fi
}

fm_send_omp_is_busy() {
  case "$TARGET_BACKEND" in
    herdr)
      [ "$(fm_backend_busy_state herdr "$T")" = busy ]
      ;;
    tmux)
      fm_backend_source tmux || return 1
      fm_pane_is_busy "$T" omp
      ;;
    *)
      return 1
      ;;
  esac
}

fm_send_wait_for_omp_turn_start() {
  local elapsed=0 interval
  # Herdr's exact `empty` submit verdict already means its native agent-state
  # reader observed a submit-active state after Enter. A remote control call
  # runs this same verifier beside the endpoint and propagates its exact result.
  case "$TARGET_BACKEND" in herdr|remote) return 0 ;; esac
  while :; do
    fm_send_omp_is_busy && return 0
    if [ -n "$TARGET_OMP_TURNSTART_REFERENCE" ] \
      && [ "$TARGET_OMP_TURNSTART_MARKER" -nt "$TARGET_OMP_TURNSTART_REFERENCE" ]; then
      return 0
    fi
    interval=$(awk -v elapsed="$elapsed" -v timeout="$FM_SEND_TURNSTART_TIMEOUT_VALUE" \
      -v poll="$FM_SEND_TURNSTART_POLL_VALUE" \
      'BEGIN { remaining = timeout - elapsed; if (remaining <= 0) exit 1; if (poll < remaining) remaining = poll; printf "%.6f", remaining }') \
      || break
    sleep "$interval"
    elapsed=$(awk -v elapsed="$elapsed" -v interval="$interval" \
      'BEGIN { printf "%.6f", elapsed + interval }')
  done
  return 1
}

fm_send_prepare_omp_turnstart_reference() {
  TARGET_OMP_TURNSTART_MARKER=
  [ -n "$TARGET_TASK_ID" ] || return 0
  TARGET_OMP_TURNSTART_MARKER="$STATE/$TARGET_TASK_ID.omp-started"
  [ -f "$TARGET_OMP_TURNSTART_MARKER" ] && [ ! -L "$TARGET_OMP_TURNSTART_MARKER" ] || return 0
  TARGET_OMP_TURNSTART_REFERENCE=$(mktemp "${TMPDIR:-/tmp}/fm-send-turnstart.XXXXXXXX") || {
    echo "error: cannot create OMP turn-start activity reference" >&2
    return 1
  }
}

fm_send_record_delivered_no_turn() {
  local status_file line wake_key
  [ -n "$TARGET_TASK_ID" ] || {
    echo "warning: delivered-no-turn has no task-bound status ledger; supervised recovery must be started manually" >&2
    return 0
  }
  status_file="$STATE/$TARGET_TASK_ID.status"
  wake_key="$TARGET_TASK_ID.status"
  line='failed: delivered-no-turn: confirmed OMP steer did not start a turn; do not resend; supervised recovery must preserve the existing worktree'
  if [ -L "$status_file" ] || { [ -e "$status_file" ] && [ ! -f "$status_file" ]; }; then
    echo "warning: delivered-no-turn refuses a non-ordinary recovery marker at $status_file" >&2
  elif ! printf '%s\n' "$line" >> "$status_file"; then
    echo "warning: delivered-no-turn could not append its recovery marker to $status_file" >&2
  fi
  if ! fm_wake_append signal "$wake_key" "delivered-no-turn: $TARGET_TASK_ID"; then
    echo "warning: delivered-no-turn could not enqueue its watcher wake for $TARGET_TASK_ID" >&2
  fi
}

fm_send_resolve_target() {  # <raw-target>
  local raw=$1 meta pane_meta target backend assumed colons id session hint

  RESOLVED_TARGET=""
  TARGET_BACKEND=""
  TARGET_HARNESS=""
  EXPECTED_LABEL=""
  TARGET_META=""
  TARGET_SELECTOR=""
  TARGET_REMOTE_ID=""
  RESOLUTION_TRIED=""

  meta=$(fm_backend_meta_for_selector "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
      id=$(fm_send_id_from_meta "$meta")
      RESOLVED_TARGET="remote:$id"
      TARGET_BACKEND=remote
      TARGET_META=$meta
      TARGET_HARNESS=$(fm_meta_get "$meta" harness)
      EXPECTED_LABEL="fm-$id"
      TARGET_SELECTOR=1
      TARGET_REMOTE_ID=$id
      RESOLUTION_TRIED="meta=$meta; placement=remote"
      return 0
    fi
    RESOLUTION_TRIED="meta=$meta; backend=from-meta"
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried $RESOLUTION_TRIED)" >&2
      return 1
    fi
    backend=$(fm_backend_of_meta "$meta")
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$backend
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$raw" "$STATE")
    TARGET_SELECTOR=1
    return 0
  fi

  case "$raw" in
    fm-*:*)
      # A named Herdr session may itself begin with "fm-". Keep that explicit
      # session:pane target on the validated backend-target path below rather
      # than mistaking it for an unresolved task selector.
      ;;
    fm-*)
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; legacy-meta=$STATE/${raw#fm-}.meta; backend=none"
      echo "error: no metadata for $raw in $STATE (tried $RESOLUTION_TRIED); pass a well-formed explicit backend target only when targeting outside this firstmate home" >&2
      return 1
      ;;
  esac

  pane_meta=$(fm_send_meta_for_key_value "$STATE" herdr_pane_id "$raw" 2>/dev/null || true)
  if [ -n "$pane_meta" ]; then
    session=$(fm_meta_get "$pane_meta" herdr_session)
    hint="${session:-<herdr-session>}:$raw"
    id=$(fm_send_id_from_meta "$pane_meta")
    echo "error: target '$raw' matches herdr_pane_id in $pane_meta but is missing its herdr session prefix; expected <herdr-session>:<pane-id> such as '$hint' or use 'fm-$id' (tried meta=$STATE/$raw.meta; backend=herdr)" >&2
    return 1
  fi

  meta=$(fm_backend_meta_for_window "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried explicit target '$raw' via recorded window/terminal; backend=from-meta)" >&2
      return 1
    fi
    RESOLVED_TARGET=$target

    TARGET_BACKEND=$(fm_backend_of_meta "$meta")
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    RESOLUTION_TRIED="explicit target '$raw' matched $meta; backend=$TARGET_BACKEND"
    return 0
  fi

  case "$raw" in
    *:*)
      colons=$(fm_send_count_colons "$raw")
      if [ "$colons" -ge 2 ]; then
        assumed=herdr
      else
        assumed=tmux
      fi
      if ! fm_backend_target_exists "$assumed" "$raw"; then
        echo "error: explicit target '$raw' is not a live $assumed endpoint (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed). Use fm-<id> for a recorded task/lane, or pass a target whose backend endpoint can be verified." >&2
        return 1
      fi
      RESOLVED_TARGET=$raw
      TARGET_BACKEND=$assumed
      RESOLUTION_TRIED="meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed; endpoint=verified"
      return 0
      ;;
  esac

  echo "error: target '$raw' is not resolvable (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=none). Use fm-$raw for a recorded task/lane, or pass a well-formed explicit backend target such as session:window." >&2
  return 1
}

RAW_TARGET=$1
fm_send_resolve_target "$RAW_TARGET" || exit 1
T=$RESOLVED_TARGET
shift
# Collect --resolve-key flags (answerer-closes; see the header contract). They
# must precede --key or the message text; everything after the last flag is the
# message exactly as before, so ordinary sends are byte-identical.
RESOLVE_KEYS=
fm_send_add_resolve_key() {  # <key>
  local k=$1
  case "$k" in
    ''|*[!A-Za-z0-9._-]*)
      echo "error: --resolve-key '$k' is not a valid decision key (allowed: A-Z a-z 0-9 . _ -)" >&2
      return 1
      ;;
  esac
  case " $RESOLVE_KEYS " in
    *" $k "*)
      echo "error: duplicate --resolve-key '$k'" >&2
      return 1
      ;;
  esac
  RESOLVE_KEYS="${RESOLVE_KEYS}${RESOLVE_KEYS:+ }$k"
}
while :; do
  case "${1:-}" in
    --resolve-key)
      [ $# -ge 2 ] || { echo "error: --resolve-key requires a key" >&2; exit 1; }
      fm_send_add_resolve_key "$2" || exit 1
      shift 2
      ;;
    --resolve-key=*)
      fm_send_add_resolve_key "${1#--resolve-key=}" || exit 1
      shift
      ;;
    *) break ;;
  esac
done

if [ "$TARGET_BACKEND" != remote ]; then
  fm_backend_validate "$TARGET_BACKEND" || exit 1
fi

if [ "$TARGET_BACKEND" = remote ] && fm_runpod_is_managed "$DATA" "$TARGET_REMOTE_ID"; then
  RUNPOD_DELIVERY_LOCK=$(secondmate_handoff_lock_path "$STATE" "$TARGET_REMOTE_ID")
  fm_lock_acquire_wait "$RUNPOD_DELIVERY_LOCK" \
    || { echo "error: cannot lock delivery to RunPod secondmate $TARGET_REMOTE_ID" >&2; exit 1; }
fi

# Wake-before-deliver: a scale-to-zero compute route has no host until its
# provider brings one back. The wake is idempotent, takes its own
# per-secondmate lifecycle lock, and happens strictly BEFORE anything is
# delivered, so retrying it can never duplicate a request. Once delivery starts,
# the existing unknown-completion contract below is untouched: an SSH status of
# 255 still means unknown completion with no retry and no failover.
if [ "$TARGET_BACKEND" = remote ] && fm_runpod_is_dormant "$DATA" "$TARGET_REMOTE_ID"; then
  if ! wake_out=$("$SCRIPT_DIR/fm-runpod.sh" wake "$TARGET_REMOTE_ID" 2>&1); then
    [ -z "$wake_out" ] || printf '%s\n' "$wake_out" >&2
    echo "error: remote secondmate $TARGET_REMOTE_ID could not be woken on its compute provider; nothing was delivered" >&2
    exit 1
  fi
fi

TARGET_OMP_BUN=
if [ "$TARGET_HARNESS" = omp ]; then
  if [ "$TARGET_BACKEND" != remote ]; then
    if [ -z "$TARGET_META" ] \
       || ! fm_backend_agent_record_identity "$TARGET_BACKEND" "$T" "$TARGET_META"; then
      echo "error: OMP target '$RAW_TARGET' lacks a valid task-bound Bun/OMP identity; refusing composer inspection and delivery" >&2
      exit 1
    fi
    TARGET_OMP_STATE=$(fm_backend_agent_state "$TARGET_BACKEND" "$T" "$TARGET_META" 2>/dev/null)
    if [ "$TARGET_OMP_STATE" != alive ]; then
      echo "error: OMP target '$RAW_TARGET' does not match a live task-bound Bun/OMP process (state=${TARGET_OMP_STATE:-unreadable}); refusing delivery" >&2
      exit 1
    fi
    TARGET_OMP_BUN=$FM_BACKEND_AGENT_OMP_BUN
  fi
fi

# Classify a from-firstmate -> secondmate request. Only a task selector resolved
# through this home's meta whose authoritative kind is secondmate is marked: the
# secondmate then routes its reply via the status path (see fm-marker-lib.sh).
# An explicit backend target (the escape hatch for endpoints outside this home)
# and any crewmate/scout target are left unmarked, and so is the --key path.
MARK_FROM_FIRSTMATE=0
PENDING_REPLY_CORR=
PENDING_REPLY_CREATED=0
TARGET_TASK_ID=
if [ -n "$TARGET_META" ]; then
  TARGET_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
  if [ -n "$TARGET_SELECTOR" ] && [ "$(fm_meta_get "$TARGET_META" kind)" = secondmate ]; then
    MARK_FROM_FIRSTMATE=1
  fi
fi
if [ "$TARGET_HARNESS" = omp ] && [ "${1:-}" != "--key" ]; then
  fm_send_validate_turnstart_config || exit 1
  fm_send_prepare_omp_turnstart_reference || exit 1
fi
# Validate the answerer-closes request before any durable mutation or send: the
# target must have a task ledger in THIS home, the send must carry an answer
# message, and every named key must be open right now in that ledger per the
# ONE authoritative fold (status_open_decisions). Refusing here, before the
# send, is what keeps a mistyped key loud instead of delivering an answer that
# silently leaves its decision open.
RESOLVE_STATUS_FILE=
if [ -n "$RESOLVE_KEYS" ]; then
  if [ -z "$TARGET_SELECTOR" ] || [ -z "$TARGET_META" ]; then
    echo "error: --resolve-key needs a task selector resolved through this home's metadata; an explicit backend target has no decision ledger here" >&2
    exit 1
  fi
  if [ "${1:-}" = "--key" ]; then
    echo "error: --resolve-key cannot accompany --key; answering a decision requires a text answer" >&2
    exit 1
  fi
  if [ -z "$*" ]; then
    echo "error: --resolve-key requires a nonempty answer message" >&2
    exit 1
  fi
  RESOLVE_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
  RESOLVE_STATUS_FILE="$STATE/$RESOLVE_TASK_ID.status"
  resolve_open_set=$(status_open_decisions "$RESOLVE_STATUS_FILE")
  for k in $RESOLVE_KEYS; do
    case "$resolve_open_set" in
      "$k"$'\t'*|*$'\n'"$k"$'\t'*) ;;
      *)
        echo "error: --resolve-key '$k': no open decision or blocker with that key in $RESOLVE_STATUS_FILE (already closed, mistyped, or transferred). Re-check the OPEN DECISIONS listing, then resend without that key or with the right one; nothing was sent." >&2
        exit 1
        ;;
    esac
  done
fi
# Close each answered decision in this home's ledger, only after delivery is
# fully confirmed. An append failure exits nonzero with the manual close
# command; the decision then stays open and re-surfaces, never silently lost.
fm_send_close_resolved_keys() {  # <answer-text>
  local note=$1 k quoted_line quoted_status failed=0
  note=$(printf '%s' "$note" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  for k in $RESOLVE_KEYS; do
    fm_send_resolved_line "$k" "$note"
    if ! printf '%s\n' "$FM_SEND_RESOLVED_LINE" >> "$RESOLVE_STATUS_FILE"; then
      printf -v quoted_line '%q' "$FM_SEND_RESOLVED_LINE"
      printf -v quoted_status '%q' "$RESOLVE_STATUS_FILE"
      echo "error: the answer was delivered to $T, but decision key '$k' could not be closed in $RESOLVE_STATUS_FILE." >&2
      printf '%s\n' "manual close: printf '%s\\n' $quoted_line >> $quoted_status" >&2
      failed=1
    fi
  done
  if [ "$failed" -ne 0 ]; then
    echo "error: close every listed key manually; do not resend the answer." >&2
    return 1
  fi
}



# Resolve the target's harness from its meta (recorded by fm-spawn), used only to
# scope the codex `$<skill>` popup-settle below. A task selector carries
# meta; an explicit backend-target escape hatch has none, so its harness is
# unknown and treated as non-codex (the safe default that keeps the fast path).
# The target's BACKEND comes from selector meta, from matching an explicit target
# back to recorded meta, or from strict explicit-target shape validation.
# Do not add a separate passive liveness preflight here. Active send paths own
# backend readiness: herdr, for example, must route through its session-aware
# target_ready path before sending, while zellij verifies pane labels in its
# send implementation. A failed backend send is still surfaced below as a hard
# error with the attempted resolution attached.

if [ "${1:-}" = "--key" ]; then
  case "$*" in
    *--resolve-key*)
      echo "error: --resolve-key cannot accompany --key; answering a decision requires a text answer" >&2
      exit 1
      ;;
  esac
  if [ "$TARGET_BACKEND" = remote ]; then
    if ! "$SCRIPT_DIR/fm-on.sh" "$TARGET_REMOTE_ID" fm-remote-secondmate-control.sh key "$TARGET_REMOTE_ID" "$2" < /dev/null; then
      echo "error: key '$2' not sent to remote secondmate $TARGET_REMOTE_ID; completion may be unknown" >&2
      exit 1
    fi
  elif ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$2" "$EXPECTED_LABEL"; then
    echo "error: key '$2' not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  fm_send_record_interrupt "$2" || exit 1
else
  MESSAGE=$*
  RESOLVE_ANSWER_TEXT=$MESSAGE
  if [ "$MARK_FROM_FIRSTMATE" = 1 ]; then
    # Reuse an existing correlation id for recovery resends; otherwise create a
    # durable parent expectation before delivery. Transport success never
    # resolves that expectation (see fm-pending-reply-lib.sh).
    existing_corr=${FM_PENDING_REPLY_EXISTING_CORR:-$(fm_pending_reply_extract_corr "$MESSAGE")}
    if [ -n "$existing_corr" ] \
      && fm_pending_reply_corr_reusable "$STATE" "$existing_corr" "$TARGET_TASK_ID"; then
      PENDING_REPLY_CORR=$existing_corr
    else
      if [ -z "$TARGET_TASK_ID" ]; then
        echo "error: cannot create pending-reply expectation without a resolvable secondmate task id" >&2
        exit 1
      fi
      PENDING_REPLY_CORR=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$TARGET_TASK_ID" "$MESSAGE") \
        || { echo "error: failed to create parent pending-reply expectation for $TARGET_TASK_ID" >&2; exit 1; }
      PENDING_REPLY_CREATED=1
    fi
    fm_pending_reply_embed_corr "$MESSAGE" "$PENDING_REPLY_CORR" MESSAGE
    if [ "$PENDING_REPLY_CREATED" = 1 ] \
      && ! fm_pending_reply_prepare_delivery "$STATE" "$PENDING_REPLY_CORR"; then
      fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      echo "error: failed to durably prepare pending-reply delivery for $TARGET_TASK_ID" >&2
      exit 1
    fi
  fi
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing, so give the popup time to settle before
  # the (retried) Enter. Codex opens the same kind of popup for a `$<skill>`
  # invocation, so a `$...` message to a codex target gets the same settle. That
  # `$` case is scoped to codex on purpose: unlike `/`, a leading `$` commonly
  # starts ordinary text ("$5/month", "$HOME"), so a universal `$` rule would
  # needlessly slow plain text to claude/opencode/pi. The target backend's
  # verified submit retry still backs the settle up either way.
  case "$*" in
    /*) settle=1.2 ;;
    \$*)
      if [ "$TARGET_HARNESS" = codex ]; then settle=1.2; else settle=0.3; fi
      ;;
    *) settle=0.3 ;;
  esac
  retries=${FM_SEND_RETRIES:-3}
  sleep_s=${FM_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Exact empty confirms delivery; queued-unconfirmed
  # permits only the narrow already-busy OMP queue decision.
  send_rc=0
  if [ "$TARGET_BACKEND" = remote ]; then
    if "$SCRIPT_DIR/fm-on.sh" "$TARGET_REMOTE_ID" fm-remote-secondmate-control.sh send "$TARGET_REMOTE_ID" "$MESSAGE" < /dev/null >/dev/null; then
      verdict=empty
    else
      send_rc=$?
      if [ "$send_rc" -eq 4 ] && [ "$TARGET_HARNESS" = omp ]; then
        verdict='delivered-no-turn'
        send_rc=0
      else
        verdict=send-failed
      fi
    fi
  elif verdict=$(fm_backend_send_text_submit "$TARGET_BACKEND" "$T" "$MESSAGE" "$retries" "$sleep_s" "$settle" "$EXPECTED_LABEL" "$TARGET_HARNESS" "$TARGET_OMP_BUN"); then
    :
  else
    send_rc=$?
  fi
  if [ "$send_rc" -ne 0 ]; then
    if [ "$TARGET_BACKEND" = remote ] && [ "$send_rc" -eq 255 ] && [ -n "$PENDING_REPLY_CORR" ]; then
      fm_pending_reply_mark_delivery_unknown "$STATE" "$PENDING_REPLY_CORR" || true
      echo "error: text delivery to remote secondmate $TARGET_REMOTE_ID is unknown; do not resend - same-host reconciliation is required" >&2
      exit 1
    fi
    if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
      fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
    fi
    echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  if [ "$verdict" != empty ] && [ "$TARGET_HARNESS" = omp ] && [ "$MESSAGE" = /exit ] \
     && [ -n "$TARGET_META" ] \
     && [ "$(fm_backend_agent_state "$TARGET_BACKEND" "$T" "$TARGET_META" 2>/dev/null)" = dead ]; then
    verdict=empty
  fi
  if [ "$verdict" = empty ] && [ "$TARGET_HARNESS" = omp ] && [ "$MESSAGE" != /exit ] \
     && ! fm_send_wait_for_omp_turn_start; then
    verdict='delivered-no-turn'
  fi
  post_delivery_failed=0
  case "$verdict" in
    empty)
      if [ -n "$RESOLVE_KEYS" ]; then
        fm_send_close_resolved_keys "$RESOLVE_ANSWER_TEXT" || post_delivery_failed=1
      fi
      ;;
    queued-unconfirmed)
      # The backend transported Enter to busy OMP without a native proof event.
      # Continue through the common delivery-confirmation path.
      ;;
    delivered-no-turn)
      # Submission is durable, so pending-reply bookkeeping below still records
      # delivery, but an answer cannot close its decision until a turn acts on it.
      ;;
    send-failed)
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
    *)
      if [ "$PENDING_REPLY_CREATED" = 1 ] && [ -n "$PENDING_REPLY_CORR" ]; then
        fm_pending_reply_discard_undelivered "$STATE" "$PENDING_REPLY_CORR" || true
      fi
      echo "error: text not submitted to $T (delivery unconfirmed; verdict=${verdict:-unknown}; tried $RESOLUTION_TRIED)" >&2
      exit 1
      ;;
  esac
  # Mark the pending expectation delivered without resolving it: only a
  # correlated parent report acknowledges the request.
  if [ -n "$PENDING_REPLY_CORR" ]; then
    if fm_pending_reply_confirm_delivery "$STATE" "$PENDING_REPLY_CORR"; then
      :
    else
      delivery_commit_status=$?
      if [ "$delivery_commit_status" = 2 ]; then
        echo "error: text was delivered to $T, but its pending-reply delivery commit failed; a durable recovery marker was stored and the watcher will reconcile it. Do not resend." >&2
      else
        echo "error: text was delivered to $T, but its pending-reply delivery commit and recovery marker both failed. Do not resend; inspect $STATE manually." >&2
      fi
      post_delivery_failed=1
    fi
  fi
  if [ "$verdict" = delivered-no-turn ]; then
    fm_send_record_delivered_no_turn
    echo "error: delivered-no-turn: text was submitted to $T, but OMP did not start a turn within ${FM_SEND_TURNSTART_TIMEOUT_VALUE}s; do not resend; supervised recovery is required" >&2
    exit 4
  fi
  [ "$post_delivery_failed" -eq 0 ] || exit 1
  # The submit was confirmed or accepted through the narrow busy-OMP queue
  # verdict. The harness still needs a beat to spin up the
  # turn before its busy footer shows. Pause so an immediate peek catches the
  # crewmate actually working instead of the stale idle pane. FM_SEND_SETTLE=0
  # disables it. Scoped to this path only, never the shared submit core.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
