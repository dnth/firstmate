#!/usr/bin/env bash
# Generic process-to-event runner: supervise a registered long-polling child
# outside the agent's foreground turn and turn completed results into normalized
# durable wakes.
#
# Usage:
#   fm-procevent.sh register <adapter> <source-id> -- <argv>...
#   fm-procevent.sh start <source-id>
#   fm-procevent.sh reconcile
#   fm-procevent.sh handled <source-id> <sequence>
#   fm-procevent.sh retire <source-id>
#   fm-procevent.sh sweep-home [--preflight]
#   fm-procevent.sh list
#
# register   Record a source: its adapter, its canonical id, and the exact argv
#            to execute. argv is stored one argument per line and executed
#            directly, so there is no shell surface and no argument splitting.
#            Adapters register sources; nothing here parses user text.
# start      Claim the source, run its child to completion, durably capture the
#            output, publish normalized wakes for pending results, then release
#            the claim. It blocks for as long as the source blocks and is meant
#            to run as a supervised background process, never in a conversational
#            turn. After publishing, it asks the source's own adapter whether the
#            captured result ends the source and retires the registration when it
#            says so, so a source that has ended stops being restarted.
# reconcile  Idempotent liveness entry the watcher calls on its ordinary cycle:
#            republish every durably captured result with no handled
#            acknowledgement yet - regardless of any earlier publication - and
#            start a runner for any registered source that has no live owner.
#            This is liveness repair only - it never discovers results by
#            polling the source, because the child blocks on the source itself.
# handled    Durably and idempotently record that a captured result has been
#            fully handled: <source-id> <sequence>. Prints "handled: id seq"
#            the first time for that exact source-and-sequence generation and
#            "already-handled: id seq" on every repeat call, atomically
#            deduplicated so a paired external effect is never authorized
#            twice. Until this is called, the result stays eligible for
#            bounded re-announcement on every reconcile. Marking a result
#            handled does not retire its source registration or claim.
# retire     Drop a registration, stop a runner this home owns, release the claim.
#            Idempotent, and still the supported explicit path after a source has
#            already retired itself on its adapter's terminal verdict.
# sweep-home Retire a bounded snapshot of this home's registrations and owned
#            claims, then refuse unless no registration, runner record, or owned
#            claim remains. Used by supported Firstmate home retirement.
# list       Show registered sources, owners, and pending captured results.
#
# Terminal knowledge is adapter-owned. This runner never inspects a result and
# never names an adapter-specific status: it calls
# `bin/fm-procevent-<adapter>.sh terminal <result-file>` and treats exit 0 as the
# only terminal verdict. A missing command, an error, or any other exit keeps the
# registration armed, so an adapter that has no notion of ending needs no change.
#
# Keyed captain answers are adapter-owned through one more seam of the same kind,
# and this runner still decides nothing about them. Some sources carry the
# captain's answer to a durable decision. What such an answer MEANS is owned once,
# by bin/fm-decision-hold.sh's keyed-answer intake, and reaching it must not
# depend on an agent remembering. So after capture, a source that has been bound
# to a decision origin has its result passed to
# `bin/fm-procevent-<adapter>.sh answers <result-file>`, and whatever that prints
# is piped straight into that one intake. The adapter reports only what the
# captain chose; the intake owns every rule about what happens next. This runner
# names no adapter, parses no result, and knows no decision rule, so a future
# source needs nothing here beyond an `answers` command and a binding.
#
# Feeding is deliberately independent of handling: it never acknowledges a result
# and never suppresses a wake. Recording the captain's answer is transcription,
# while ACTING on it is firstmate's judgement, so the capture stays unacknowledged
# and its `check` wake reaches the handler exactly as it would have anyway.
#
# Ownership is machine-wide per canonical source, because separate Firstmate
# homes can share one underlying source store. A live owner is never displaced;
# only a claim whose whole generation is gone is reclaimed. A runner leads its
# own process group, so a crashed leader whose group still has members is not
# stale: reconcile keeps that claim owned and uncertain rather than signalling a
# group it cannot prove is this generation's or starting a replacement.
#
# Detachment can also outlive a whole firstmate home: once reparented, the
# runner would poll forever. Each runner therefore carries an owner guard that
# reads a lease on the claim's recorded physical state root - refreshed by
# owner-presence operations like reconcile, handled, and an attached start -
# and stops the runner's process group after two consecutive checks can prove
# neither the root identity nor a fresh lease. The guard and the runner lead
# separate process groups so the signal never reaches the guard itself, and the
# runner marker stays inside `FM_PROCEVENT_IN_RUNNER`, which the guard does not
# get. Nothing here scans for script names or command lines, which are shared
# across homes.
#
# Durability boundary: see bin/fm-procevent-lib.sh. This runner proves capture
# before publication and bounded re-announcement until handled, and nothing
# about the source side of the handoff.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

# Claims record the physical state root, so resolve the caller's spelling once
# here; every lease touch, ownership comparison, and guard identity check then
# speaks about the same directory. An absent or unverifiable state root keeps
# the caller's spelling, which can only under-match recorded identities.
STATE=$(fm_procevent_state_root_resolve "$STATE" 2>/dev/null || printf '%s\n' "$STATE")
REG=$(fm_procevent_registry_dir "$STATE")
MAX_OUTPUT_BYTES=${FM_PROCEVENT_MAX_OUTPUT_BYTES:-1048576}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,92p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

adapter_script() { printf '%s/bin/fm-procevent-%s.sh\n' "$FM_ROOT" "$1"; }

# Ask the source's own adapter whether a captured result ends the source. Exit 0
# is the only terminal verdict; everything else - including a missing adapter
# command - keeps the registration armed. See the terminal-knowledge note in the
# header: no adapter-specific condition may appear in this runner.
adapter_result_is_terminal() {  # <adapter> <result-file>
  local script
  script=$(adapter_script "$1")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  "$script" terminal "$2" >/dev/null 2>&1
}

source_file()  { printf '%s/%s.source\n' "$REG" "$1"; }
runner_file()  { printf '%s/%s.runner\n' "$REG" "$1"; }
staging_file() { printf '%s/.%s.%s.output\n' "$REG" "$1" "$2"; }

# Pass a bound source's captured result to the one keyed-answer intake. The
# adapter turns its own format into keyed lines; the intake owns everything those
# lines mean. Silenced and best-effort exactly like the terminal seam above: an
# unbound source, an adapter with no `answers` command, and a failure on either
# side all leave the capture untouched and still announced, because this never
# acknowledges anything (see the keyed-answer note in the header).
feed_keyed_answers() {  # <adapter> <source-id> <result-file>
  local adapter=$1 id=$2 result=$3 script origin seq
  script=$(adapter_script "$adapter")
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  origin=$("$SCRIPT_DIR/fm-decision-hold.sh" binding "$id" 2>/dev/null) || return 1
  [ -n "$origin" ] || return 1
  seq=$(fm_procevent_result_sequence "$result") || return 1
  "$script" answers "$result" 2>/dev/null \
    | "$SCRIPT_DIR/fm-decision-hold.sh" answers "$origin" \
        --source "the captured result $id sequence $seq" >/dev/null 2>&1
}

read_adapter() {  # <source-id>
  local f; f=$(source_file "$1")
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  sed -n 's/^adapter=//p' "$f" | head -1
}

# Read the stored argv into the ARGV array. One argument per line after the
# argv= count, so an argument containing spaces is not re-split.
read_argv() {  # <source-id>
  local f n; f=$(source_file "$1")
  ARGV=()
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  n=$(sed -n 's/^argc=//p' "$f" | head -1)
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  local i=0 line
  while IFS= read -r line; do
    i=$((i + 1))
    [ "$i" -le "$n" ] && ARGV+=("$line")
  done < <(sed -n '/^argv:$/,$p' "$f" | tail -n +2)
  [ "${#ARGV[@]}" -eq "$n" ]
}

cmd_register() {
  local adapter=${1-} id=${2-} sep=${3-}
  shift 3 2>/dev/null || usage
  owner_lease_refresh
  fm_procevent_adapter_valid "$adapter" || die "adapter name must be lowercase alphanumeric or dash: $adapter"
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe and at most 64 characters: $id"
  [ "$sep" = -- ] || usage
  [ "$#" -ge 1 ] || die "register needs at least one argv element after --"
  local arg
  for arg in "$@"; do
    case "$arg" in *$'\n'*) die "argv elements cannot contain newlines" ;; esac
  done
  [ -f "$(adapter_script "$adapter")" ] || die "no installed adapter for: $adapter"
  fm_procevent_source_lock_acquire "$id" || die "cannot lock the source"
  if ! fm_procevent_registration_publish_locked "$STATE" "$adapter" "$id" "$@"; then
    fm_procevent_source_lock_release "$id"
    die "cannot publish the registration"
  fi
  fm_procevent_source_lock_release "$id"
  printf 'registered: %s (%s)\n' "$id" "$adapter"
}

# Publish every durably captured result with no handled acknowledgement yet.
# Capture already happened, so this only turns durable state into durable
# events - and it republishes on every call regardless of any earlier
# publication, so a result stays eligible for re-announcement across restarts
# and drains until `fm_procevent_mark_handled` records it.
publish_pending() {
  local result id seq adapter line published=0
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    id=$(fm_procevent_result_source_id "$result")
    seq=$(fm_procevent_result_sequence "$result")
    fm_procevent_source_id_valid "$id" || continue
    adapter=$(fm_procevent_result_adapter "$result" 2>/dev/null || true)
    [ -n "$adapter" ] || continue
    line=$(fm_procevent_event_line "$adapter" "$id" "$seq") || continue
    fm_procevent_source_lock_acquire "$id" || continue
    if ! fm_procevent_is_handled "$STATE" "$id" "$seq" \
      && fm_wake_append check "procevent:$id:$seq" "check: $line"; then
      published=$((published + 1))
    fi
    fm_procevent_source_lock_release "$id"
  done < <(fm_procevent_pending "$STATE")
  printf '%s\n' "$published"
}

# Start one command as the leader of a fresh process group, either waiting for
# it (the public `start` boundary) or detaching from it (reconcile's restart and
# the runner's own owner guard). The guard deliberately gets its OWN group
# rather than joining the runner's: it has to survive the group signal it sends,
# and a member of the runner's group would also make that group read as alive
# after the runner itself is gone.
isolate_process() {  # <wait|detach> <command> [argv...]
  local mode=$1 program
  shift
  # shellcheck disable=SC2016 # Perl owns every $ expression in this literal program.
  program='my $mode = shift @ARGV;
    defined(my $pid = fork) or exit 125;
    if ($pid == 0) {
      setpgrp(0, 0) or exit 125;
      $ENV{FM_PROCEVENT_RUNNER_GROUP} = $$;
      exec @ARGV;
      exit 125;
    }
    exit 0 if $mode eq "detach";
    waitpid($pid, 0) == $pid or exit 125;
    my $status = $?;
    exit(128 + ($status & 127)) if $status & 127;
    exit($status >> 8);'
  if [ "$mode" = wait ]; then
    perl -e "$program" "$mode" "$@"
    return $?
  fi
  perl -e "$program" "$mode" "$@" >/dev/null 2>&1 &
}

isolate_runner() {  # <wait|detach> <source-id>
  isolate_process "$1" "$SCRIPT_DIR/fm-procevent.sh" _start "$2"
}

require_isolated_group() {  # <role>
  local role=$1 pgid
  [ "${FM_PROCEVENT_RUNNER_GROUP:-}" = "$$" ] \
    || die "$role process group was not isolated"
  pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]') \
    || die "cannot inspect $role process group"
  [ -n "$pgid" ] || die "cannot inspect $role process group"
  [ "$pgid" = "$$" ] || die "$role does not lead its process group"
  unset FM_PROCEVENT_RUNNER_GROUP
}

require_runner_group() { require_isolated_group runner; }

# Record owner-presence activity for this home. Skipped under the inherited
# FM_PROCEVENT_IN_RUNNER marker, so a runner and its ordinary children do not
# keep refreshing their own lease after the home goes away.
# Confused-agent-grade: a source that deliberately unsets the marker can still
# refresh, and that is out of scope (see docs/configuration.md).
owner_lease_refresh() {
  [ "${FM_PROCEVENT_IN_RUNNER:-0}" = 1 ] && return 0
  fm_procevent_owner_lease_touch "$STATE" 2>/dev/null || true
}

owner_lease_keepalive() {  # <parent-pid> <parent-identity>
  local parent=$1 identity=$2 state
  while :; do
    sleep 1
    fm_procevent_pid_state "$parent" "$identity"
    state=$?
    case "$state" in
      0) owner_lease_refresh ;;
      2) ;;
      *) return 0 ;;
    esac
  done
}

cmd_start_public() {
  local id=${1-} identity keeper status
  [ "$#" -eq 1 ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  owner_lease_refresh
  identity=$(fm_pid_identity "$$" 2>/dev/null) || die "cannot identify the attached owner"
  owner_lease_keepalive "$$" "$identity" &
  keeper=$!
  isolate_runner wait "$id"
  status=$?
  kill "$keeper" 2>/dev/null || true
  wait "$keeper" 2>/dev/null || true
  return "$status"
}

cmd_start() {
  local id=${1-} adapter out rc claimed bound_rc
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  require_runner_group
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  if [ ! -f "$(source_file "$id")" ] || [ -L "$(source_file "$id")" ]; then
    fm_procevent_source_lock_release "$id"
    die "source is not registered: $id"
  fi
  if ! adapter=$(read_adapter "$id"); then
    fm_procevent_source_lock_release "$id"
    die "registration is unreadable: $id"
  fi
  if ! fm_procevent_adapter_valid "$adapter"; then
    fm_procevent_source_lock_release "$id"
    die "registration names an invalid adapter"
  fi
  if ! read_argv "$id"; then
    fm_procevent_source_lock_release "$id"
    die "registration argv is unreadable: $id"
  fi
  fm_procevent_claim_acquire_locked "$id" "$FM_HOME" "$$" "$(source_file "$id")" "$STATE"
  claimed=$?
  fm_procevent_source_lock_release "$id"
  case "$claimed" in
    0) ;;
    2) printf 'already owned: %s\n' "$id"; exit 0 ;;
    *) die "cannot claim source: $id" ;;
  esac
  CLAIM_ID=$id
  CLAIM_HOME=$FM_HOME
  CLAIM_PID=$$
  CLAIM_TOKEN=$FM_PROCEVENT_CLAIM_TOKEN
  CLAIM_REG_IDENTITY=$FM_PROCEVENT_CLAIM_REG_IDENTITY
  CLAIM_STATE_DEVICE=$FM_PROCEVENT_CLAIM_STATE_DEVICE
  CLAIM_STATE_INODE=$FM_PROCEVENT_CLAIM_STATE_INODE
  STAGED_OUTPUT=
  release_start_claim() {
    [ -z "$STAGED_OUTPUT" ] || rm -f -- "$STAGED_OUTPUT"
    fm_procevent_source_lock_acquire "$CLAIM_ID" 2>/dev/null || return 0
    if fm_procevent_claim_load_locked "$CLAIM_ID" 2>/dev/null \
      && [ "$FM_PROCEVENT_CLAIM_HOME" = "$CLAIM_HOME" ] \
      && [ "$FM_PROCEVENT_CLAIM_PID" = "$CLAIM_PID" ] \
      && [ "$FM_PROCEVENT_CLAIM_TOKEN" = "$CLAIM_TOKEN" ] \
      && [ "$FM_PROCEVENT_CLAIM_TERMINAL" = terminal ]; then
      fm_procevent_source_lock_release "$CLAIM_ID" 2>/dev/null || true
      return 0
    fi
    # If registration disappeared while this generation was running, keep
    # the claim for reconcile/sweep to retire as a claim-only source.
    if [ ! -f "$(source_file "$CLAIM_ID")" ] || [ -L "$(source_file "$CLAIM_ID")" ]; then
      fm_procevent_source_lock_release "$CLAIM_ID" 2>/dev/null || true
      return 0
    fi
    fm_procevent_claim_release_locked "$CLAIM_ID" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN" 2>/dev/null || true
    fm_procevent_source_lock_release "$CLAIM_ID" 2>/dev/null || true
  }
  trap release_start_claim EXIT
  # The inherited marker keeps the runner and its ordinary children from
  # accidentally refreshing the owner lease. A source that deliberately strips
  # it is outside this confused-agent-grade boundary.
  export FM_PROCEVENT_IN_RUNNER=1
  start_owner_guard "$id" || die "cannot start the runner's owner guard: $id"
  printf '%s\n' "$$" > "$(runner_file "$id")" 2>/dev/null || true
  chmod 0600 "$(runner_file "$id")" 2>/dev/null || true

  local launch_floor
  launch_floor=$(fm_procevent_launch_floor_seconds) \
    || die "FM_PROCEVENT_LAUNCH_FLOOR_SECONDS must be whole seconds from $FM_PROCEVENT_LAUNCH_FLOOR_MIN_SECONDS to $FM_PROCEVENT_LAUNCH_FLOOR_MAX_SECONDS"
  case "$MAX_OUTPUT_BYTES" in ''|*[!0-9]*) die "FM_PROCEVENT_MAX_OUTPUT_BYTES must be a nonnegative integer" ;; esac
  # The launch floor bounds how fast a crash-looping source can be relaunched;
  # a superseded registration means a newer generation owns pacing, so exit
  # quietly and remove the runner marker a home sweep counts as incomplete.
  fm_procevent_launch_floor_wait "$STATE" "$id" "$CLAIM_REG_IDENTITY" "$launch_floor"
  case "$?" in
    0) ;;
    2) rm -f -- "$(runner_file "$id")"; exit 0 ;;
    *) die "cannot enforce the source launch floor: $id" ;;
  esac
  out=$(staging_file "$id" "$CLAIM_TOKEN")
  [ ! -e "$out" ] && [ ! -L "$out" ] || die "cannot safely stage output"
  (umask 077; : > "$out") || die "cannot stage output"
  STAGED_OUTPUT=$out
  "${ARGV[@]}" 2>/dev/null | perl -e '
    use strict;
    use warnings;
    my $limit = shift;
    my ($written, $truncated) = (0, 0);
    while (1) {
      my $count = sysread(STDIN, my $buffer, 65536);
      exit 2 unless defined $count;
      last if $count == 0;
      my $take = $written < $limit ? $limit - $written : 0;
      $take = $count if $take > $count;
      if ($take > 0) {
        my $offset = 0;
        while ($offset < $take) {
          my $count_written = syswrite(STDOUT, $buffer, $take - $offset, $offset);
          exit 2 unless defined $count_written;
          $offset += $count_written;
        }
        $written += $take;
      }
      $truncated = 1 if $take < $count;
    }
    exit($truncated ? 3 : 0);
  ' "$MAX_OUTPUT_BYTES" > "$out"
  local pipe_status=("${PIPESTATUS[@]}") truncated=0
  rc=${pipe_status[0]}
  bound_rc=${pipe_status[1]}
  case "$bound_rc" in
    0) ;;
    3) truncated=1 ;;
    *) die "cannot bound source output" ;;
  esac

  if [ "$rc" -ne 0 ] && [ ! -s "$out" ]; then
    # No usable result. Leave the registration armed; the adapter decides
    # whether a nonzero exit is terminal when it handles the next result.
    rm -f -- "$out" "$(runner_file "$id")"
    printf 'no-result: %s (exit %s)\n' "$id" "$rc"
    exit 0
  fi

  local durable
  durable=$(fm_procevent_capture "$STATE" "$id" "$adapter" "$out") || { rm -f -- "$out"; die "cannot durably capture the result"; }
  rm -f -- "$out"
  STAGED_OUTPUT=
  [ "$truncated" -eq 1 ] && printf 'truncated: %s at %s bytes\n' "$id" "$MAX_OUTPUT_BYTES" >&2

  # Independent of publication and acknowledgement, so it runs once per capture
  # for every adapter and cannot change what the handler receives.
  if feed_keyed_answers "$adapter" "$id" "$durable"; then
    printf 'answers-fed: %s\n' "$id"
  fi

  publish_pending >/dev/null
  rm -f -- "$(runner_file "$id")"
  # Publication is already durable, so retiring an ended source here can never
  # cost the result or its wake; leaving it armed, by contrast, lets every later
  # reconcile restart a source that will only return empty ended results.
  if adapter_result_is_terminal "$adapter" "$durable"; then
    if retire_owned_terminal_source "$id"; then
      printf 'retired: %s (adapter classified the captured result terminal)\n' "$id"
    else
      printf 'cannot retire terminal source; it remains registered: %s\n' "$id" >&2
    fi
  fi
  printf 'captured: %s\n' "$durable"
}

# Retire a source this runner owns because its adapter classified the captured
# result terminal. Ownership is re-proved, the registration is dropped, and this
# runner's own claim is released under ONE source-lock hold, so no concurrent
# reconcile can observe a registered source with no owner (and start a
# replacement) or an owned claim with no registration (and signal this runner
# mid-exit), and a generation this runner no longer owns is never unregistered.
# The EXIT trap's own release then no-ops, because the generation is already gone.
retire_owned_terminal_source() {  # <source-id>
  local id=$1 status=0 registration current_identity
  registration=$(source_file "$id")
  fm_procevent_source_lock_acquire "$id" || return 1
  if fm_procevent_claim_load_locked "$id" 2>/dev/null \
    && [ "$FM_PROCEVENT_CLAIM_HOME" = "$CLAIM_HOME" ] \
    && [ "$FM_PROCEVENT_CLAIM_PID" = "$CLAIM_PID" ] \
    && [ "$FM_PROCEVENT_CLAIM_TOKEN" = "$CLAIM_TOKEN" ] \
    && [ "$FM_PROCEVENT_CLAIM_REG_IDENTITY" = "$CLAIM_REG_IDENTITY" ] \
    && current_identity=$(fm_pr_file_identity "$registration" 2>/dev/null) \
    && [ "$current_identity" = "$CLAIM_REG_IDENTITY" ] \
    && fm_procevent_claim_mark_terminal_locked "$id" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN"; then
    if rm -f -- "$registration" && [ ! -e "$registration" ] && [ ! -L "$registration" ]; then
      fm_procevent_claim_release_locked "$id" "$CLAIM_HOME" "$CLAIM_PID" "$CLAIM_TOKEN" || status=1
    else
      status=1
    fi
  else
    status=1
  fi
  fm_procevent_source_lock_release "$id"
  return "$status"
}

# Bind this runner's lifetime to the home that owns it. Started once the
# claim is held, so the guard names the exact generation it protects, and
# detached into its OWN process group so the group signal it may later send
# reaches the runner and every descendant without killing the guard first.
# If signalling cannot be proved safe or does not finish, the guard remains
# alive and retries on its normal check cadence rather than abandoning cleanup.
start_owner_guard() {  # <source-id>
  local identity ready value
  identity=$(fm_pid_identity "$$" 2>/dev/null) || return 1
  ready=$(umask 077; mktemp "$REG/.owner-guard-ready.XXXXXX") || return 1
  if ! isolate_process detach "$SCRIPT_DIR/fm-procevent.sh" _owner-watchdog \
      "$1" "$$" "$identity" "$ready" "$CLAIM_STATE_DEVICE" "$CLAIM_STATE_INODE"; then
    rm -f -- "$ready"
    return 1
  fi
  for _ in $(seq 1 50); do
    if [ -s "$ready" ]; then
      IFS= read -r value < "$ready" || value=
      rm -f -- "$ready"
      [ "$value" = ready ]
      return $?
    fi
    sleep 0.1
  done
  rm -f -- "$ready"
  return 1
}

# The runner's owner guard, which bounds an accidentally orphaned detached
# runner after its home ends. It revalidates the recorded physical state root
# and its lease on a bounded cadence and, after two consecutive checks cannot prove
# both, invokes the identity-gated stop for the runner's whole process group -
# which is what reaches the blocking child and everything that child spawned,
# exactly as retirement does. A failed verified stop stays on the retry cadence;
# an absent leader ends the guard without signalling an ambiguous group.
#
# Scope is the owning state root and this one runner generation. It never
# matches on a script name, a command line, or a process name: those are shared
# by every home running the same adapter, and a live source in another home
# proves its own owner through that home's own lease.
cmd_owner_watchdog() {  # <source-id> <runner-pid> <runner-identity> <ready-file> <state-device> <state-inode>
  local id=${1-} pid=${2-} identity=${3-} ready=${4-} state_device=${5-} state_inode=${6-}
  local lease tick misses=0 pid_state state_identity current_device current_inode
  [ "$#" -eq 6 ] || usage
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  case "$pid" in ''|*[!0-9]*) die "runner pid must be a positive integer: $pid" ;; esac
  [ -n "$identity" ] || die "runner identity is required"
  case "$state_device" in ''|*[!0-9]*) die "state device must be an integer" ;; esac
  case "$state_inode" in ''|*[!0-9]*) die "state inode must be an integer" ;; esac
  [ "${ready%/*}" = "$REG" ] && [ -f "$ready" ] && [ ! -L "$ready" ] \
    || die "owner guard readiness boundary is invalid"
  trap 'printf "failed\n" > "$ready" 2>/dev/null || true' EXIT
  require_isolated_group guard
  lease=$(fm_procevent_owner_lease_seconds) \
    || die "FM_PROCEVENT_OWNER_LEASE_SECONDS must be whole seconds from $FM_PROCEVENT_OWNER_LEASE_MIN_SECONDS to $FM_PROCEVENT_OWNER_LEASE_MAX_SECONDS"
  tick=$(fm_procevent_owner_check_seconds) \
    || die "FM_PROCEVENT_OWNER_CHECK_SECONDS must be whole seconds from $FM_PROCEVENT_OWNER_CHECK_MIN_SECONDS to $FM_PROCEVENT_OWNER_CHECK_MAX_SECONDS"
  fm_procevent_pid_state "$pid" "$identity"
  pid_state=$?
  [ "$pid_state" -eq 0 ] || die "runner identity changed before owner guard initialization"
  state_identity=$(fm_procevent_claim_state_root_identity "$STATE") \
    || die "owning state root identity is unreadable at owner guard initialization"
  IFS=$'\t' read -r _ current_device current_inode _ _ <<< "$state_identity"
  [ "$current_device" = "$state_device" ] && [ "$current_inode" = "$state_inode" ] \
    || die "owning state root identity changed before owner guard initialization"
  fm_procevent_owner_alive "$STATE" "$lease" \
    || die "owning home lease is not fresh at owner guard initialization"
  printf 'ready\n' > "$ready" || die "cannot confirm owner guard initialization"
  trap - EXIT
  while :; do
    sleep "$tick"
    fm_procevent_pid_state "$pid" "$identity"
    pid_state=$?
    case "$pid_state" in
      1|3) exit 0 ;;
      0) ;;
      *) continue ;;
    esac
    state_identity=$(fm_procevent_claim_state_root_identity "$STATE" 2>/dev/null || true)
    current_device=
    current_inode=
    [ -z "$state_identity" ] \
      || IFS=$'\t' read -r _ current_device current_inode _ _ <<< "$state_identity"
    if [ "$current_device" = "$state_device" ] \
      && [ "$current_inode" = "$state_inode" ] \
      && fm_procevent_owner_alive "$STATE" "$lease"; then
      misses=0
      continue
    fi
    # Two consecutive misses, so one unreadable read cannot end a live runner.
    misses=$((misses + 1))
    [ "$misses" -ge 2 ] || continue
    if stop_runner_pid "$pid" "$identity"; then
      exit 0
    fi
    # Identity/group inspection and signalling can fail transiently. Keep the
    # guard alive so the next normal tick retries the same generation cleanup.
  done
}

# Start a runner outside the watcher cycle that noticed it was missing. The
# public start boundary establishes its own process group before claiming.
detach_runner() {  # <source-id>
  isolate_runner detach "$1"
}

cmd_reconcile() {
  local rec id published started=0 stopped=0 uncertain=0 claim owner pid token identity claim_state stop_state
  owner_lease_refresh
  published=$(publish_pending)

  # Stop a runner this home owns whose source is no longer registered. Without
  # this, unregistering a source that never completes leaves its child blocked
  # forever with nothing left to reap it.
  for claim in "$(fm_procevent_claim_root)"/*.claim; do
    [ -e "$claim" ] || continue
    id=${claim##*/}; id=${id%.claim}
    fm_procevent_source_id_valid "$id" || continue
    fm_procevent_source_lock_acquire "$id" || continue
    if [ -f "$(source_file "$id")" ] && [ ! -L "$(source_file "$id")" ]; then
      fm_procevent_source_lock_release "$id"
      continue
    fi
    if ! fm_procevent_claim_load_locked "$id" 2>/dev/null; then
      uncertain=$((uncertain + 1))
      fm_procevent_source_lock_release "$id"
      continue
    fi
    owner=$FM_PROCEVENT_CLAIM_HOME
    pid=$FM_PROCEVENT_CLAIM_PID
    token=$FM_PROCEVENT_CLAIM_TOKEN
    identity=$FM_PROCEVENT_CLAIM_IDENTITY
    if ! fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME"; then
      fm_procevent_source_lock_release "$id"
      continue
    fi
    stop_runner_pid "$pid" "$identity"
    stop_state=$?
    case "$stop_state" in
      0|1)
        if fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token" 2>/dev/null; then
          rm -f -- "$(staging_file "$id" "$token")"
          rm -f -- "$(runner_file "$id")"
          stopped=$((stopped + 1))
        else
          uncertain=$((uncertain + 1))
        fi
        ;;
      *) uncertain=$((uncertain + 1)) ;;
    esac
    fm_procevent_source_lock_release "$id"
  done

  if [ -d "$REG" ]; then
    for rec in "$REG"/*.source; do
      [ -e "$rec" ] || continue
      id=${rec##*/}; id=${id%.source}
      fm_procevent_source_id_valid "$id" || continue
      fm_procevent_source_lock_acquire "$id" || continue
      if [ -f "$(source_file "$id")" ] && [ ! -L "$(source_file "$id")" ]; then
        fm_procevent_claim_state_locked "$id"
        claim_state=$?
        if [ "$claim_state" -eq 1 ]; then
          fm_procevent_source_lock_release "$id"
          detach_runner "$id"
          started=$((started + 1))
          continue
        elif [ "$claim_state" -eq 4 ]; then
          owner=$FM_PROCEVENT_CLAIM_HOME
          pid=$FM_PROCEVENT_CLAIM_PID
          token=$FM_PROCEVENT_CLAIM_TOKEN
          if fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME" \
            && rm -f -- "$(source_file "$id")" \
            && [ ! -e "$(source_file "$id")" ] \
            && [ ! -L "$(source_file "$id")" ] \
            && fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token" 2>/dev/null; then
            stopped=$((stopped + 1))
          else
            uncertain=$((uncertain + 1))
          fi
        elif [ "$claim_state" -eq 3 ]; then
          # The runner leader is gone, but a process group with its numeric id
          # is still alive. That group may be this generation's or a leaderless
          # group created after PID/PGID reuse, and reconcile cannot tell which,
          # so it neither signals the group nor starts a replacement. The claim
          # stays owned; a later cycle re-evaluates it.
          uncertain=$((uncertain + 1))
        elif [ "$claim_state" -eq 2 ]; then
          uncertain=$((uncertain + 1))
        fi
      fi
      fm_procevent_source_lock_release "$id"
    done
  fi
  printf 'reconciled: published=%s started=%s stopped=%s uncertain=%s\n' "$published" "$started" "$stopped" "$uncertain"
}

# Signal the process group a live runner leads. The group signal is what
# actually reaches a blocking source child - signalling only the runner would
# leave that child alive and reparented, which is exactly how a source that
# never completes leaks. Only a live, identity-matched, group-leading pid may
# take a signal: state 3 cannot tell this generation's leaderless group from a
# reused PGID, so an absent leader preserves the claim without signalling.
runner_group_signal() {  # <pid> <identity>
  local pid=${1-} identity=${2-} state pgid
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  [ -n "$identity" ] || return 2
  fm_procevent_pid_state "$pid" "$identity"
  state=$?
  case "$state" in
    0)
      # A live identity-matched leader still owns its group, so prove the group
      # really is the one this pid leads before signalling it.
      pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 2
      [ "$pgid" = "$pid" ] || return 2
      ;;
    *) return "$state" ;;
  esac
  kill -TERM -"$pid" 2>/dev/null || return 2
  local i=0
  while [ "$i" -lt 20 ]; do
    kill -0 -"$pid" 2>/dev/null || return 0
    if kill -0 "$pid" 2>/dev/null; then
      fm_procevent_pid_state "$pid" "$identity"
      state=$?
      [ "$state" -eq 2 ] && return 2
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL -"$pid" 2>/dev/null || return 2
  i=0
  while [ "$i" -lt 20 ]; do
    kill -0 -"$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Stop a runner and its blocking child. Kept as the named call site for
# retirement, reconcile, and the owner guard, so every path goes through the
# same identity-gated group signal.
stop_runner_pid() {  # <pid> <identity>
  runner_group_signal "$@"
}

# The owned handling interface: durably and idempotently record that a
# captured result has been fully handled, keyed by the exact source id and
# sequence generation. Serialized under the same per-source boundary as every
# other mutation here, on top of the marker's own atomic O_EXCL create, so a
# caller can trust the reported first-time/repeat distinction to authorize a
# paired external effect at most once.
cmd_handled() {
  local id=${1-} seq=${2-} status
  owner_lease_refresh
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer: $seq" ;; esac
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  fm_procevent_mark_handled "$STATE" "$id" "$seq"
  status=$?
  fm_procevent_source_lock_release "$id"
  case "$status" in
    0) printf 'handled: %s %s\n' "$id" "$seq" ;;
    1) printf 'already-handled: %s %s\n' "$id" "$seq" ;;
    *) die "cannot durably record handling: $id $seq" ;;
  esac
}

cmd_retire() {
  local id=${1-} owner='' pid='' token='' identity='' stop_state
  fm_procevent_source_id_valid "$id" || die "source id must be path-safe: $id"
  fm_procevent_source_lock_acquire "$id" || die "cannot lock source: $id"
  if [ -e "$(fm_procevent_claim_path "$id")" ]; then
    if ! fm_procevent_claim_load_locked "$id" 2>/dev/null; then
      fm_procevent_source_lock_release "$id"
      die "cannot safely read source ownership: $id"
    fi
    if fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME"; then
      owner=$FM_PROCEVENT_CLAIM_HOME
      pid=$FM_PROCEVENT_CLAIM_PID
      token=$FM_PROCEVENT_CLAIM_TOKEN
      identity=$FM_PROCEVENT_CLAIM_IDENTITY
      stop_runner_pid "$pid" "$identity"
      stop_state=$?
      if [ "$stop_state" -eq 2 ]; then
        fm_procevent_source_lock_release "$id"
        die "cannot confirm runner identity; source remains registered: $id"
      fi
      if ! fm_procevent_claim_release_locked "$id" "$owner" "$pid" "$token"; then
        fm_procevent_source_lock_release "$id"
        die "cannot release source ownership: $id"
      fi
      rm -f -- "$(staging_file "$id" "$token")"
      rm -f -- "$(runner_file "$id")"
    fi
  fi
  rm -f -- "$(source_file "$id")"
  rm -f -- "$(runner_file "$id")"
  fm_procevent_source_lock_release "$id"
  # A retired source produces no further answer, so drop any decision binding it
  # carried. Generic and idempotent: the binding owner is asked to forget this
  # source id, and an unbound source is unaffected.
  "$SCRIPT_DIR/fm-decision-hold.sh" unbind "$id" >/dev/null 2>&1 || true
  printf 'retired: %s\n' "$id"
}

sweep_add_id() {
  local id=$1
  case "$SWEEP_IDS" in
    *$'\n'"$id"$'\n'*) ;;
    *) SWEEP_IDS+="$id"$'\n' ;;
  esac
}

sweep_relevant_state() {
  local path owner
  for path in "$REG"/*.source "$REG"/*.runner; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      return 0
    fi
  done
  for path in "$(fm_procevent_claim_root)"/*.claim; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    IFS= read -r owner < "$path" 2>/dev/null || continue
    [ "$owner" = "$FM_HOME" ] && return 0
  done
  return 1
}

sweep_source_preflight() {
  local id=$1 state
  fm_procevent_source_lock_acquire "$id" || return 1
  if [ -e "$(fm_procevent_claim_path "$id")" ] || [ -L "$(fm_procevent_claim_path "$id")" ]; then
    if ! fm_procevent_claim_load_locked "$id" 2>/dev/null; then
      fm_procevent_source_lock_release "$id"
      return 1
    fi
    if fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME"; then
      fm_procevent_pid_state "$FM_PROCEVENT_CLAIM_PID" "$FM_PROCEVENT_CLAIM_IDENTITY"
      state=$?
      if [ "$state" -eq 2 ]; then
        fm_procevent_source_lock_release "$id"
        return 1
      fi
    fi
  fi
  fm_procevent_source_lock_release "$id"
}

cmd_sweep_home() {
  local preflight_only=${1-} path id owner attempted=0 failed=0
  [ -z "$preflight_only" ] || [ "$preflight_only" = --preflight ] || usage
  owner_lease_refresh
  SWEEP_IDS=$'\n'
  for path in "$REG"/*.source; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      id=${path##*/}; id=${id%.source}
      if fm_procevent_source_id_valid "$id"; then
        sweep_add_id "$id"
      else
        failed=$((failed + 1))
      fi
    fi
  done
  for path in "$(fm_procevent_claim_root)"/*.claim; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    id=${path##*/}; id=${id%.claim}
    fm_procevent_source_id_valid "$id" || { failed=$((failed + 1)); continue; }
    # Claims store canonical ownership metadata; load it under the source
    # boundary so symlinked/aliased homes are compared by physical state root.
    fm_procevent_source_lock_acquire "$id" || { failed=$((failed + 1)); continue; }
    if fm_procevent_claim_load_locked "$id" 2>/dev/null \
      && fm_procevent_claim_owned_by_state "$STATE" "$FM_HOME"; then
      sweep_add_id "$id"
    fi
    fm_procevent_source_lock_release "$id"
  done
  for path in "$REG"/*.runner; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      id=${path##*/}; id=${id%.runner}
      if ! fm_procevent_source_id_valid "$id"; then
        failed=$((failed + 1))
      else
        case "$SWEEP_IDS" in
          *$'\n'"$id"$'\n'*) ;;
          *) failed=$((failed + 1)) ;;
        esac
      fi
    fi
  done
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    sweep_source_preflight "$id" || failed=$((failed + 1))
  done <<< "$SWEEP_IDS"
  if [ "$failed" -ne 0 ]; then
    printf 'error: process-event home sweep preflight failed: attempted=0 failed=%s\n' "$failed" >&2
    return 1
  fi
  if [ "$preflight_only" = --preflight ]; then
    printf 'sweep preflight: ready\n'
    return 0
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    attempted=$((attempted + 1))
    if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/fm-procevent.sh" retire "$id"; then
      failed=$((failed + 1))
    fi
  done <<< "$SWEEP_IDS"
  if [ "$failed" -ne 0 ] || sweep_relevant_state; then
    printf 'error: process-event home sweep incomplete: attempted=%s failed=%s\n' "$attempted" "$failed" >&2
    return 1
  fi
  printf 'swept: attempted=%s\n' "$attempted"
}

cmd_list() {
  local rec id adapter owner pending
  if ! fm_procevent_any_registered "$STATE"; then
    printf 'no sources registered\n'
    return 0
  fi
  printf '%-28s %-12s %-10s %s\n' SOURCE ADAPTER OWNER PENDING
  for rec in "$REG"/*.source; do
    [ -e "$rec" ] || continue
    id=${rec##*/}; id=${id%.source}
    adapter=$(read_adapter "$id" 2>/dev/null || echo '?')
    fm_procevent_source_lock_acquire "$id" || continue
    fm_procevent_claim_state_locked "$id"
    case "$?" in 0) owner=live ;; 1) owner=none ;; 3) owner=orphaned ;; *) owner=uncertain ;; esac
    fm_procevent_source_lock_release "$id"
    pending=$(fm_procevent_pending "$STATE" | grep -c "/$id\." || true)
    printf '%-28s %-12s %-10s %s\n' "$id" "$adapter" "$owner" "$pending"
  done
}

case "${1-}" in
  register)  shift; cmd_register "$@" ;;
  start)     shift; cmd_start_public "$@" ;;
  _start)    shift; cmd_start "$@" ;;
  _owner-watchdog) shift; cmd_owner_watchdog "$@" ;;
  reconcile) shift; cmd_reconcile "$@" ;;
  handled)   shift; cmd_handled "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  sweep-home) shift; cmd_sweep_home "$@" ;;
  list)      shift; cmd_list "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
