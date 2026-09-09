#!/usr/bin/env bash
# fm-task-inbox-lib.sh - the per-task steering inbox: durable records plus a
# constant doorbell.
#
# ONE owner of the steering-inbox contract: the record format, sequence
# allocation, the handled/ acknowledgement, the self-describing doorbell line,
# and the watcher's re-ring ladder policy. bin/fm-send.sh writes and rings,
# bin/fm-watch.sh polls and re-rings, and the brief scaffold (bin/fm-brief.sh)
# tells the worker how to read and acknowledge; none of them restates the
# format.
#
# Design: the durable inbox record and its handled-file move are the processing
# boundary; doorbell transport is at-least-once and carries no instruction state.
# OMP always uses its task-bound native receive adapter and never the composer:
# the terminal is not a receipt mechanism for a session that may already be
# streaming, so an unavailable adapter returns 3 and an unacknowledged request
# returns 4 rather than typing anything. Both verdicts leave the named inbox
# record intact. Every other harness keeps the advisory composer pre-check and
# backend submit fallback. A claimed programmatic request that may already have
# sent is anchored as ambiguous and is never sent again; session recovery
# reconciles the instruction from the durable inbox. Other swallowed doorbells
# are re-rung on a bounded schedule while the endpoint remains available, and a
# worker that never acknowledges surfaces through the ordinary stale wake into
# stuck-crewmate-recovery. A positively dead or missing endpoint bypasses that
# schedule without being typed into - the doorbell line itself is a shell
# no-op, so even a lost liveness race runs nothing in a bare shell - and its
# unhandled record surfaces through the same stale wake into recovery.
#
# Inbox paths containing bytes outside printable ASCII are unsupported. The
# doorbell refuses them rather than sending terminal control bytes to a pane.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder: "<msg>\t<count>\t<epoch>"
#   <task>.inbox/.escalated    oldest-message name already surfaced as stale,
#                              so later polls suppress another escalation
#
# Record format (fm_task_inbox_write / fm_task_inbox_body):
#   schema=fm-task-inbox.v1
#   at=<utc timestamp>
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# Sequence numbers are never reused within a task: allocation scans both the
# inbox root and handled/, so duplicate doorbells continue to name one stable
# record rather than reassigning its sequence to another message. Concurrent
# writers serialize on .seq.lock; the worst racing outcome is ordering, never
# loss.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect proven pending composer text. After
# FM_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates. The
# caller owns the busy and recovery-grade endpoint checks: a busy pane waits,
# while a positively dead or missing endpoint skips delivery and the ladder and
# escalates directly. This library owns only the schedule and escalation
# marker. If attempt bookkeeping cannot be persisted while the record
# remains unhandled, the caller surfaces that failure instead of retrying
# silently; a concurrently removed inbox is a quiet no-op. Escalation
# deliberately queues the wake before writing the
# deduplication marker: normal polls surface a message once, while a crash or
# marker failure may produce a rare duplicate rather than silently lose a wake.
#
# fm_task_inbox_ring requires bin/fm-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/fm-send.sh, bin/fm-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   FM_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   FM_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=5

fm_task_inbox_grace_secs() {
  local g=${FM_TASK_INBOX_GRACE_SECS:-$FM_TASK_INBOX_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$FM_TASK_INBOX_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

fm_task_inbox_ring_max() {
  local m=${FM_TASK_INBOX_RING_MAX:-$FM_TASK_INBOX_RING_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_RING_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

fm_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

# Numeric sequence of one record basename, or fail for a non-record name.
fm_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root AND handled/ so an
# acknowledged sequence is never reissued. Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled"; do
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  printf '%03d' "$((max + 1))"
}

fm_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${FM_TASK_INBOX_LOCK_WAIT_SECS:-$FM_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe
  case "$wait" in ''|*[!0-9]*) wait=$FM_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    fm_lock_try_create "$lock" && return 0
    [ -e "$lock" ] || [ -L "$lock" ] || return 1
  fi
  deadline=$(( $(date +%s) + wait ))
  while ! fm_lock_try_acquire "$lock"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-id]
  local state=$1 task=$2 text=$3 delivery_id=${4:-} dir lock seq tmp rec status=0 existing
  case "$delivery_id" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if [ -n "$delivery_id" ]; then
    existing=
    for candidate in "$dir"/*.msg "$dir/handled"/*.msg; do
      [ -f "$candidate" ] || continue
      if awk -v want="$delivery_id" '$0 == "delivery_id=" want { found=1; exit } END { exit !found }' "$candidate"; then
        existing=$candidate
        break
      fi
    done
    if [ -n "$existing" ]; then
      fm_lock_release "$lock"
      printf '%s' "$existing"
      return 0
    fi
  fi
  seq=$(fm_task_inbox_next_seq "$dir")
  rec="$dir/$seq.msg"
  if tmp=$(mktemp "$dir/.staging.XXXXXX"); then
    {
      printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
      printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      [ -z "$delivery_id" ] || printf 'delivery_id=%s\n' "$delivery_id"
      printf -- '--\n'
      printf '%s' "$text"
    } > "$tmp" && mv "$tmp" "$rec" || status=1
    [ "$status" -eq 0 ] || rm -f "$tmp"
  else
    status=1
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# The exact enqueued text back out of a record.
fm_task_inbox_body() {  # <record-path>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = -- ]; then
      cat
      return 0
    fi
  done < "$1"
  return 1
}

# The constant self-describing doorbell line for the inbox containing a record.
# Self-describing on purpose: a worker whose brief predates the inbox contract
# still receives the complete instruction in the line itself. The leading `: `
# is the POSIX shell no-op, so the same line typed into a pane whose agent has
# exited (a bare shell) runs nothing; see the dead-pane note in the header.
# A non-printable path fails without output so terminal controls never reach
# the pane's line discipline.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs quoted LC_ALL=C
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  case "$abs" in
    *[![:print:]]*) return 1 ;;
  esac
  quoted=$(printf '%s' "$abs" | sed "s/'/'\\\\''/g")
  printf ": Firstmate instruction waiting: list '%s'/*.msg and, in numeric order, read and act on each, then mv each handled file to '%s'/handled/." \
    "$quoted" "$quoted"
}

# The one path of the per-task Hermes delivery lock. Hermes serializes its
# typed plane (bin/fm-send.sh) and this doorbell ring through this single lock,
# so both callers derive the path here instead of composing it a second time.
fm_task_inbox_hermes_delivery_lock_path() {  # <state-dir> <task-id>
  printf '%s/.%s.hermes-delivery.lock' "$1" "$2"
}

# Deliver one doorbell. Callers go through fm_task_inbox_ring, which owns the
# Hermes delivery-lock critical section; this helper is the unserialized body.
# A positively dead or missing endpoint returns 6 without typing anything -
# the caller routes the durable record to recovery instead of the ladder.
fm_task_inbox_ring_deliver() {  # <backend> <target> <record-path> [expected-label] [harness] [omp-runtime] [omp-bin]
  local backend=$1 target=$2 rec=$3 label=${4:-}
  local harness=${5:-} omp_runtime=${6:-} omp_bin=${7:-} line cstate verdict ready_marker request_id programmatic_rc
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 6 ;;
  esac
  if ! line=$(fm_task_inbox_doorbell_line "$rec"); then
    return 2
  fi
  if [ "$harness" = omp ]; then
    ready_marker="${rec%/*}"
    ready_marker="${ready_marker%.inbox}.omp-doorbell-ready"
    request_id=${rec##*/}
    # shellcheck disable=SC2034 # Public outcome binding read by the caller after sourcing (bin/fm-send.sh).
    FM_TASK_INBOX_RING_OMP_REQUEST="$ready_marker.requests/request.$request_id"
    FM_TASK_INBOX_RING_OMP_PID=
    FM_OMP_TASK_DOORBELL_BOUND_PID=
    programmatic_rc=0
    fm_backend_omp_trigger_turn "$backend" "$target" "$ready_marker" "$omp_runtime" "$omp_bin" "$request_id" "$line" \
      || programmatic_rc=$?
    case "$programmatic_rc" in
      0|2)
        # shellcheck disable=SC2034 # Public outcome binding read by the caller after sourcing (bin/fm-send.sh).
        FM_TASK_INBOX_RING_OMP_PID=${FM_OMP_TASK_DOORBELL_BOUND_PID:-}
        [ "$programmatic_rc" = 0 ] && return 0
        return 4
        ;;
      *) return 3 ;;
    esac
  fi
  cstate=$(fm_backend_composer_state "$backend" "$target" "$harness" "$omp_runtime" "$omp_bin" 2>/dev/null) || cstate=unknown
  case "$cstate" in
    pending) return 1 ;;
  esac
  if ! verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 1 0.4 0.3 "$label" \
    "$harness" "$omp_runtime" "$omp_bin" 2>/dev/null); then
    return 2
  fi
  # The verdict is read only to report a failed keystroke; every other value
  # (empty, pending, unknown, ...) is deliberately ignored, never proof.
  [ "$verdict" != send-failed ] || return 2
  return 0
}

# Ring the doorbell, best-effort. OMP asks its task-bound extension to deliver
# the line as a programmatic steer with triggerTurn, and stops there: an
# unavailable adapter returns 3 and an unacknowledged request returns 4, neither
# of which touches the composer. Every non-OMP harness keeps the advisory
# composer pre-check and backend submit machinery as its transport.
# Returns 0 rang, 1 skipped because the composer PROVENLY holds pending text,
# 2 the backend send failed, 3 the OMP native adapter refused or was
# unavailable, 4 the OMP native request is queued without an acknowledgement,
# 5 skipped because a concurrent Hermes delivery still holds the shared
# delivery lock, or 6 skipped because the endpoint is positively dead or
# missing (nothing typed; recovery owns the record). On an OMP target the call also publishes
# FM_TASK_INBOX_RING_OMP_REQUEST (the named native queue entry for this record)
# and FM_TASK_INBOX_RING_OMP_PID (the proven acknowledging session process) so
# the caller can report the exact binding it acted on. A native success without
# that proof is refused; the acknowledgement move remains the only proof the
# worker acted.
#
# Hermes is the one harness whose ordinary-text doorbell and typed slash
# commands reach the SAME terminal, so both must cross one critical section or
# their bytes interleave into a single corrupted line. This ring boundary is
# where every doorbell-caused Hermes terminal write happens (bin/fm-send.sh's
# first ring and bin/fm-watch.sh's re-ring both land here), so taking the typed
# plane's lock here serializes both callers without a second lock owner.
# The wait is bounded and the record stays durable, so a refusal (5) is an
# ordinary skip the retry ladder re-rings, never a block: the watcher can never
# be parked behind a long Hermes turn. Ordering is one-directional (the watcher
# singleton lock, then this lock, and the inbox sequence and metadata locks are
# both released before the ring), and fm_lock_try_acquire reclaims the lock from
# a holder that exited, so no cycle and no stuck holder is reachable.
# The subshell releases the lock on signal paths and exits after doing so, and
# installs that trap only AFTER a proven acquisition so a refusal never releases
# another owner's lock.
fm_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label] [harness] [omp-runtime] [omp-bin]
  local rec=$3 harness=${5:-} inbox stem lock
  if [ "$harness" != hermes ]; then
    fm_task_inbox_ring_deliver "$@"
    return $?
  fi
  inbox=${rec%/*}
  stem=${inbox%.inbox}
  lock=$(fm_task_inbox_hermes_delivery_lock_path "${stem%/*}" "${stem##*/}")
  (
    fm_task_inbox_lock_acquire "$lock" || exit 5
    trap 'fm_lock_release "$lock" || true' EXIT
    trap 'fm_lock_release "$lock" || true; exit 2' HUP INT TERM
    fm_task_inbox_ring_deliver "$@"
  )
}

# Oldest unhandled record by sequence, or fail when the inbox is empty.
fm_task_inbox_oldest_unhandled() {  # <state-dir> <task-id>
  local dir best='' best_n=0 f n
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated for the current oldest)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  if ! oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" 2>/dev/null || true
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  grace=$(fm_task_inbox_grace_secs)
  if [ "$(fm_path_age "$oldest")" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  if [ -n "$rec_base" ] && [ "$rec_base" != "$base" ]; then
    # A different oldest message: the previous ladder is stale. An absent
    # ladder is left alone so a dead-pane escalation, which never rings and so
    # never writes one, keeps its marker (the marker check below still ignores
    # a marker naming some other message).
    count=0
    last=0
    rm -f "$dir/.escalated" 2>/dev/null || true
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "$base" ]; then
    printf 'quiet'
    return 0
  fi
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}

# Advance the ladder after a delivery attempt. A failed ring or a composer-
# protected skip still consumes budget so neither an unreadable pane nor a
# permanently blocked composer can retry silently forever. A positively dead or
# missing endpoint never enters the ladder: the watcher escalates it directly.
# A concurrently removed inbox is
# a successful no-op; otherwise failure means the caller must surface the
# unwritable ladder while the record remains unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path>
  local dir base ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  [ "$rec_base" = "$base" ] || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ -d "$dir" ] || return 0
  if ! { printf '%s\t%s\t%s\n' "$base" "$((count + 1))" "$(date +%s)" > "$dir/.ring-state"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# Mark the current oldest as escalated after its stale wake is durably queued,
# suppressing another wake on later polls. Wake-before-marker ordering favors
# at-least-once recovery: a crash or marker failure can cause a rare duplicate;
# stuck-crewmate-recovery owns the message from here.
fm_task_inbox_record_escalated() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${3##*/}" > "$dir/.escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}
