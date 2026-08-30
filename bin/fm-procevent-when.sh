#!/usr/bin/env bash
# Condition->action adapter for the generic process-to-event runner: register a
# deterministic condition and a deterministic action once, let the runner's
# blocking child poll the condition tokenlessly, fire the action at most once on
# a stable true, and publish one terminal outcome, re-announced until handled.
#
# Usage:
#   fm-procevent-when.sh arm <name> [options] --condition <argv>... --action <argv>...
#   fm-procevent-when.sh classify <result-file>
#   fm-procevent-when.sh terminal <result-file>
#   fm-procevent-when.sh source-id <name>
#   fm-procevent-when.sh retire <name>
#   fm-procevent-when.sh run <source-id>
#
# arm        Bind a (condition, action) pair as process-event source
#            "when-<name>". The spec is written privately under state/when/ and
#            hash-bound by a trust record the same way fm-check-register.sh
#            binds a custom check. Both executables are resolved and their bytes
#            are hash-bound at registration, then checked again before every
#            condition poll and immediately before the fire is claimed. The
#            runner refuses a mutated spec or executable without executing it.
#            Both argv vectors are executed directly with no shell, so nothing
#            is re-split or interpreted. Protected RunPod and remote lifecycle,
#            PR merge and teardown, X-mode, public-followup, and generic
#            command-carrier entrypoints are not eligible condition or action
#            executables; they keep their existing trusted wake-and-decide paths
#            and side-effect gates.
#            Options, before --condition:
#              --interval <secs>           poll cadence, decimals allowed (default 60)
#              --stable <n>                consecutive true polls required to fire (default 2)
#              --deadline <secs>           give up and wake firstmate if the condition
#                                          never held this long after arming (default 604800)
#              --condition-timeout <secs>  per-poll bound on one condition run (default 60)
#              --action-timeout <secs>     bound on the action run (default 1800)
#              --error-budget <n>          consecutive condition errors tolerated
#                                          before waking firstmate (default 3)
#            The condition argv must exit 0 for true, 1 for a clean false;
#            any other exit (or a per-poll timeout) is an error, never a true.
#            POLICY, only partly enforceable here: both halves must be exact and
#            deterministic, and the action must be safe and reversible. Anything
#            needing judgment, and anything destructive, irreversible, or
#            security-sensitive, keeps the ordinary wake-firstmate-and-decide
#            flow; this primitive only automates the deterministic subset.
#            The registered runner starts on the watcher's next cycle via
#            `fm-procevent.sh reconcile`; arm never blocks on the condition.
# classify   Print the captured outcome class a handler should act on:
#            fired, action-failed, condition-error, never-true, ambiguous,
#            rejected, or unknown.
# terminal   Exit 0 when the captured result ends this source. Every when
#            outcome is terminal because the pair fires at most once; the
#            generic runner then retires the registration itself.
# source-id  Print the canonical source id for <name>.
# retire     Stop the watch: retire the registration and remove the spec, trust
#            record, and fired marker. Idempotent. Captured results and their
#            handled acknowledgements are never touched. Warns when the action
#            had already fired without a captured outcome.
# run        The blocking child the generic runner executes; never run it in a
#            conversational turn. It polls the condition on the registered
#            cadence, requires the stable count of consecutive trues, claims a
#            durable fired marker with an exclusive create BEFORE the action so
#            a restart or re-poll can never fire the action twice, runs the
#            action bounded, and emits exactly one outcome document on stdout
#            for durable capture. Every failure path - mutated spec, condition
#            error, deadline, action failure, or an earlier fire whose outcome
#            was never captured - emits a terminal outcome document instead of
#            retrying silently, so firstmate is always woken with the evidence.
#
# Outcome document (the captured result named by the wake):
#   when: <source-id>
#   status: fired|action-failed|condition-error|never-true|ambiguous|rejected
#   detail: <one line>
#   condition_polls: <n>
#   action_exit: <code>        (fired and action-failed only)
#   output:
#   <bounded tail of the relevant command output>
#
# Ownership, durable capture, publication, restart recovery, and the handled
# acknowledgement all belong to bin/fm-procevent.sh; this adapter owns only the
# condition->action semantics above.
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
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

WHEN_DIR="$STATE/when"
OUTPUT_TAIL_BYTES=${FM_WHEN_OUTPUT_TAIL_BYTES:-8192}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,72p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

spec_file()  { printf '%s/%s.spec\n' "$WHEN_DIR" "$1"; }
trust_file() { printf '%s/%s.trust\n' "$WHEN_DIR" "$1"; }
fired_file() { printf '%s/%s.fired\n' "$WHEN_DIR" "$1"; }

when_name_valid() {
  local name=${1-}
  fm_task_id_path_safe "$name" || return 1
  fm_procevent_source_id_valid "when-$name"
}

cmd_source_id() {
  local name=${1-}
  when_name_valid "$name" || die "name must be path-safe and at most 59 characters: ${name-}"
  printf 'when-%s\n' "$name"
}

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

positive_number() {
  local n=${1-}
  local LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [ "$n" != 0 ] && [[ ! "$n" =~ ^0+(\.0+)?$ ]]
}

command_executable() {  # <argv-zero>: print the executable's absolute path
  local command=$1 found dir base
  case "$command" in
    */*) found=$command ;;
    *) found=$(type -P -- "$command") || return 1 ;;
  esac
  dir=${found%/*}
  base=${found##*/}
  [ "$dir" != "$found" ] || dir=.
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  found="$dir/$base"
  [ -f "$found" ] && [ -x "$found" ] || return 1
  printf '%s\n' "$found"
}

protected_entrypoint_reason() {  # <absolute-path> <sha256>: print rejection reason
  local path=$1 hash=$2 base candidate candidate_hash
  base=${path##*/}
  case "$base" in
    fm-runpod*.sh|fm-on.sh|fm-remote-*.sh)
      printf 'RunPod and remote lifecycle or remote-compute entrypoints stay on their guarded wake-and-decide path\n'
      return 0
      ;;
    fm-pr-merge.sh|fm-teardown.sh)
      printf 'merge and teardown entrypoints require their ordinary captain-authority and landed-work gates\n'
      return 0
      ;;
    fm-x-*.sh|fm-public-followup*.sh)
      printf 'X-mode and public-followup entrypoints stay on their consent-bound public-reply path\n'
      return 0
      ;;
    sh|bash|dash|zsh|ksh|fish|env|xargs|nohup|sudo|ssh|curl|wget|nc|ncat|socat|node|nodejs|deno|bun|python|python[0-9]*|ruby|perl|php|pwsh|powershell|osascript|make|just|npm|npx|pnpm|yarn)
      printf 'generic command carriers cannot prove the eventual executable is eligible\n'
      return 0
      ;;
    rm|rmdir|unlink|shred|dd|mkfs*|fdisk|parted|shutdown|reboot|halt|poweroff|kill|pkill|killall|systemctl|launchctl|docker|podman|kubectl|terraform|tofu|git|gh|gh-axi|glab|hub|scp|rsync)
      printf 'destructive or remote-control entrypoints require their ordinary guarded path\n'
      return 0
      ;;
  esac
  for candidate in "$SCRIPT_DIR"/fm-runpod*.sh "$SCRIPT_DIR"/fm-remote-*.sh \
    "$SCRIPT_DIR"/fm-x-*.sh "$SCRIPT_DIR"/fm-public-followup*.sh \
    "$SCRIPT_DIR"/fm-on.sh "$SCRIPT_DIR"/fm-pr-merge.sh "$SCRIPT_DIR"/fm-teardown.sh; do
    [ -f "$candidate" ] || continue
    candidate_hash=$(fm_pr_sha256 "$candidate") || {
      printf 'the protected-entrypoint identity could not be verified\n'
      return 0
    }
    if [ "$candidate_hash" = "$hash" ]; then
      printf 'a renamed protected lifecycle or public-reply entrypoint is not eligible\n'
      return 0
    fi
  done
  if LC_ALL=C grep -Eq '(^|[^[:alnum:]_.-])(fm-runpod[^[:space:]]*\.sh|fm-on\.sh|fm-remote-[^[:space:]]*\.sh|fm-pr-merge\.sh|fm-teardown\.sh|fm-x-[^[:space:]]*\.sh|fm-public-followup[^[:space:]]*\.sh)([^[:alnum:]_.-]|$)' "$path" 2>/dev/null; then
    printf 'the executable wraps or names a protected lifecycle or public-reply entrypoint\n'
    return 0
  fi
  return 1
}

execution_policy_valid() {  # <condition|action> <absolute-path> <sha256>
  local role=$1 path=$2 hash=$3 reason
  POLICY_ERROR=
  if reason=$(protected_entrypoint_reason "$path" "$hash"); then
    POLICY_ERROR="$role executable is not allowlisted: $reason"
    return 1
  fi
  return 0
}

# --- arm ---------------------------------------------------------------------

cmd_arm() {
  local name=${1-} sid interval=60 stable=2 deadline=604800
  local condition_timeout=60 action_timeout=1800 error_budget=3
  local -a cond=() act=()
  [ -n "$name" ] || usage
  shift
  when_name_valid "$name" || die "name must be path-safe and at most 59 characters: $name"
  sid="when-$name"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)          positive_number "${2-}" || die "--interval needs a positive number of seconds"; interval=$2; shift 2 ;;
      --stable)            positive_int "${2-}" || die "--stable needs a positive integer"; stable=$2; shift 2 ;;
      --deadline)          positive_int "${2-}" || die "--deadline needs a positive integer of seconds"; deadline=$2; shift 2 ;;
      --condition-timeout) positive_int "${2-}" || die "--condition-timeout needs a positive integer of seconds"; condition_timeout=$2; shift 2 ;;
      --action-timeout)    positive_int "${2-}" || die "--action-timeout needs a positive integer of seconds"; action_timeout=$2; shift 2 ;;
      --error-budget)      positive_int "${2-}" || die "--error-budget needs a positive integer"; error_budget=$2; shift 2 ;;
      --condition)
        shift
        while [ "$#" -gt 0 ] && [ "$1" != --action ]; do cond+=("$1"); shift; done
        ;;
      --action)
        shift
        while [ "$#" -gt 0 ]; do act+=("$1"); shift; done
        ;;
      *) die "unknown arm argument: $1" ;;
    esac
  done
  [ "${#cond[@]}" -ge 1 ] || die "arm needs at least one --condition argv element"
  [ "${#act[@]}" -ge 1 ] || die "arm needs at least one --action argv element"
  local arg
  for arg in "${cond[@]}" "${act[@]}"; do
    case "$arg" in *$'\n'*) die "argv elements cannot contain newlines" ;; esac
  done

  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  fm_procevent_source_lock_acquire "$sid" || die "cannot lock the watch source"
  trap 'fm_procevent_source_lock_release "$sid"' EXIT
  local leftover
  for leftover in "$(spec_file "$sid")" "$(trust_file "$sid")" "$(fired_file "$sid")" \
    "$(fm_procevent_registry_dir "$STATE")/$sid.source"; do
    if [ -e "$leftover" ] || [ -L "$leftover" ]; then
      die "watch already exists or left state behind: $leftover (retire it first)"
    fi
  done
  local pending
  pending=$(fm_procevent_pending "$STATE" | grep -c "/$sid\." || true)
  [ "$pending" -eq 0 ] || die "an unhandled captured result exists for $sid; handle it before re-arming"

  (umask 077; mkdir -p "$WHEN_DIR") || die "cannot create the watch directory"
  [ -d "$WHEN_DIR" ] && [ ! -L "$WHEN_DIR" ] || die "watch directory is unavailable"
  local tmp trust_tmp hash device condition_path condition_hash action_path action_hash
  condition_path=$(command_executable "${cond[0]}") || die "condition executable is unavailable: ${cond[0]}"
  condition_hash=$(fm_pr_sha256 "$condition_path") || die "cannot hash the condition executable"
  execution_policy_valid condition "$condition_path" "$condition_hash" || die "$POLICY_ERROR"
  cond[0]=$condition_path
  action_path=$(command_executable "${act[0]}") || die "action executable is unavailable: ${act[0]}"
  action_hash=$(fm_pr_sha256 "$action_path") || die "cannot hash the action executable"
  execution_policy_valid action "$action_path" "$action_hash" || die "$POLICY_ERROR"
  act[0]=$action_path
  device=$(fm_pr_file_device "$WHEN_DIR") || die "cannot inspect the watch directory"
  tmp=$(umask 077; mktemp "$WHEN_DIR/.spec.XXXXXX") || die "cannot stage the spec"
  {
    printf 'fm-when-spec-v2\n'
    printf 'armed=%s\n' "$(date +%s)"
    printf 'interval=%s\n' "$interval"
    printf 'stable=%s\n' "$stable"
    printf 'deadline=%s\n' "$deadline"
    printf 'condition_timeout=%s\n' "$condition_timeout"
    printf 'action_timeout=%s\n' "$action_timeout"
    printf 'error_budget=%s\n' "$error_budget"
    printf 'condition_sha256=%s\n' "$condition_hash"
    printf 'action_sha256=%s\n' "$action_hash"
    printf 'condition_argc=%s\n' "${#cond[@]}"
    printf 'action_argc=%s\n' "${#act[@]}"
    printf 'argv:\n'
    printf '%s\n' "${cond[@]}"
    printf '%s\n' "${act[@]}"
  } > "$tmp" || { rm -f -- "$tmp"; die "cannot write the spec"; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; die "cannot secure the spec"; }
  hash=$(fm_pr_sha256 "$tmp") || { rm -f -- "$tmp"; die "cannot hash the spec"; }
  trust_tmp=$(umask 077; mktemp "$WHEN_DIR/.trust.XXXXXX") || { rm -f -- "$tmp"; die "cannot stage the trust record"; }
  printf 'fm-when-trust-v1\n%s\n' "$hash" > "$trust_tmp" || { rm -f -- "$tmp" "$trust_tmp"; die "cannot write the trust record"; }
  chmod 0600 "$trust_tmp" || { rm -f -- "$tmp" "$trust_tmp"; die "cannot secure the trust record"; }
  mv -f -- "$tmp" "$(spec_file "$sid")" || { rm -f -- "$tmp" "$trust_tmp"; die "cannot publish the spec"; }
  mv -f -- "$trust_tmp" "$(trust_file "$sid")" || { rm -f -- "$(spec_file "$sid")" "$trust_tmp"; die "cannot publish the trust record"; }
  if ! fm_pr_private_file_valid "$(spec_file "$sid")" 600 "$device" \
    || ! fm_pr_private_file_valid "$(trust_file "$sid")" 600 "$device"; then
    rm -f -- "$(spec_file "$sid")" "$(trust_file "$sid")"
    die "published spec failed validation"
  fi

  if ! fm_procevent_registration_publish_locked "$STATE" when "$sid" \
    "$SCRIPT_DIR/fm-procevent-when.sh" run "$sid"; then
    rm -f -- "$(spec_file "$sid")" "$(trust_file "$sid")"
    die "cannot register the watch source"
  fi
  fm_procevent_source_lock_release "$sid"
  trap - EXIT
  printf 'armed: %s\n' "$sid"
  printf 'starts on the watcher'"'"'s next cycle; or run: bin/fm-procevent.sh reconcile\n'
  printf 'reminder: deterministic, safe, reversible actions only; judgment and destructive actions stay on the wake-and-decide path\n'
}

# --- spec load ---------------------------------------------------------------

# spec_load <source-id>: validate the trust binding, then parse the spec into
# SPEC_* variables plus COND_ARGV and ACT_ARGV. Any structural or trust failure
# returns 1 with a reason in SPEC_ERROR; nothing from the spec is executed.
spec_load() {
  local sid=$1 spec trust device hash want version line key value extra
  SPEC_ERROR=
  COND_ARGV=()
  ACT_ARGV=()
  spec=$(spec_file "$sid")
  trust=$(trust_file "$sid")
  [ -d "$WHEN_DIR" ] && [ ! -L "$WHEN_DIR" ] || { SPEC_ERROR="watch directory is unavailable"; return 1; }
  device=$(fm_pr_file_device "$WHEN_DIR") || { SPEC_ERROR="cannot inspect the watch directory"; return 1; }
  fm_pr_private_file_valid "$spec" 600 "$device" || { SPEC_ERROR="spec is missing or not private"; return 1; }
  fm_pr_private_file_valid "$trust" 600 "$device" || { SPEC_ERROR="trust record is missing or not private"; return 1; }
  {
    IFS= read -r version && IFS= read -r want && ! IFS= read -r extra
  } < "$trust" || { SPEC_ERROR="trust record is malformed"; return 1; }
  [ "$version" = fm-when-trust-v1 ] || { SPEC_ERROR="trust record has an unknown version"; return 1; }
  local LC_ALL=C
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { SPEC_ERROR="trust record hash is malformed"; return 1; }
  hash=$(fm_pr_sha256 "$spec") || { SPEC_ERROR="cannot hash the spec"; return 1; }
  [ "$hash" = "$want" ] || { SPEC_ERROR="spec does not match its registered trust binding"; return 1; }

  SPEC_ARMED='' SPEC_INTERVAL='' SPEC_STABLE='' SPEC_DEADLINE=''
  SPEC_CONDITION_TIMEOUT='' SPEC_ACTION_TIMEOUT='' SPEC_ERROR_BUDGET=''
  SPEC_CONDITION_SHA256='' SPEC_ACTION_SHA256=''
  local cond_argc='' act_argc='' in_argv=0 read_cond=0 read_act=0
  {
    IFS= read -r version || { SPEC_ERROR="spec is empty"; return 1; }
    [ "$version" = fm-when-spec-v2 ] || { SPEC_ERROR="spec has an unknown version"; return 1; }
    while IFS= read -r line; do
      if [ "$in_argv" -eq 0 ]; then
        if [ "$line" = "argv:" ]; then in_argv=1; continue; fi
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
          armed)             SPEC_ARMED=$value ;;
          interval)          SPEC_INTERVAL=$value ;;
          stable)            SPEC_STABLE=$value ;;
          deadline)          SPEC_DEADLINE=$value ;;
          condition_timeout) SPEC_CONDITION_TIMEOUT=$value ;;
          action_timeout)    SPEC_ACTION_TIMEOUT=$value ;;
          error_budget)      SPEC_ERROR_BUDGET=$value ;;
          condition_sha256)  SPEC_CONDITION_SHA256=$value ;;
          action_sha256)     SPEC_ACTION_SHA256=$value ;;
          condition_argc)    cond_argc=$value ;;
          action_argc)       act_argc=$value ;;
          *) SPEC_ERROR="spec carries an unknown field: $key"; return 1 ;;
        esac
      elif [ "$read_cond" -lt "${cond_argc:-0}" ]; then
        COND_ARGV+=("$line")
        read_cond=$((read_cond + 1))
      elif [ "$read_act" -lt "${act_argc:-0}" ]; then
        ACT_ARGV+=("$line")
        read_act=$((read_act + 1))
      else
        SPEC_ERROR="spec carries trailing content"
        return 1
      fi
    done
  } < "$spec"
  [ -z "$SPEC_ERROR" ] || return 1
  case "$SPEC_ARMED" in ''|*[!0-9]*) SPEC_ERROR="spec armed epoch is malformed"; return 1 ;; esac
  positive_number "$SPEC_INTERVAL" || { SPEC_ERROR="spec interval is malformed"; return 1; }
  positive_int "$SPEC_STABLE" || { SPEC_ERROR="spec stable count is malformed"; return 1; }
  positive_int "$SPEC_DEADLINE" || { SPEC_ERROR="spec deadline is malformed"; return 1; }
  positive_int "$SPEC_CONDITION_TIMEOUT" || { SPEC_ERROR="spec condition timeout is malformed"; return 1; }
  positive_int "$SPEC_ACTION_TIMEOUT" || { SPEC_ERROR="spec action timeout is malformed"; return 1; }
  positive_int "$SPEC_ERROR_BUDGET" || { SPEC_ERROR="spec error budget is malformed"; return 1; }
  [[ "$SPEC_CONDITION_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || { SPEC_ERROR="spec condition hash is malformed"; return 1; }
  [[ "$SPEC_ACTION_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || { SPEC_ERROR="spec action hash is malformed"; return 1; }
  positive_int "${cond_argc:-}" || { SPEC_ERROR="spec condition argc is malformed"; return 1; }
  positive_int "${act_argc:-}" || { SPEC_ERROR="spec action argc is malformed"; return 1; }
  [ "$read_cond" -eq "$cond_argc" ] && [ "$read_act" -eq "$act_argc" ] \
    || { SPEC_ERROR="spec argv is incomplete"; return 1; }
}

executable_trust_valid() {  # <condition|action> <path> <expected-sha256>
  local role=$1 path=$2 expected=$3 current
  EXECUTABLE_ERROR=
  current=$(fm_pr_sha256 "$path") || {
    EXECUTABLE_ERROR="$role executable is unavailable"
    return 1
  }
  if [ "$current" != "$expected" ]; then
    EXECUTABLE_ERROR="$role executable bytes do not match the registered trust binding"
    return 1
  fi
  if ! execution_policy_valid "$role" "$path" "$current"; then
    EXECUTABLE_ERROR=$POLICY_ERROR
    return 1
  fi
  return 0
}

stage_executable() {  # <role> <path> <expected-sha256>: print immutable run copy
  local role=$1 path=$2 expected=$3 staged current
  staged=$(umask 077; mktemp "$WHEN_DIR/.${role}.XXXXXX") || {
    EXECUTABLE_ERROR="$role executable could not be staged"
    return 1
  }
  if ! cp -- "$path" "$staged" || ! chmod 0700 "$staged"; then
    rm -f -- "$staged"
    EXECUTABLE_ERROR="$role executable could not be staged"
    return 1
  fi
  current=$(fm_pr_sha256 "$staged") || {
    rm -f -- "$staged"
    EXECUTABLE_ERROR="$role executable staging could not be hashed"
    return 1
  }
  if [ "$current" != "$expected" ]; then
    rm -f -- "$staged"
    EXECUTABLE_ERROR="$role executable changed while being staged"
    return 1
  fi
  printf '%s\n' "$staged"
}

# --- run ---------------------------------------------------------------------

# bounded_run <timeout-secs> <output-file> <argv>...
# Run argv directly with combined output captured, bounded by the timeout.
# Returns the command's exit status, or 124 on timeout.
bounded_run() {
  local secs=$1 out=$2 rc
  shift 2
  fm_run_timed "$secs" "$@" 2>&1 | tail -c "$OUTPUT_TAIL_BYTES" > "$out"
  rc=${PIPESTATUS[0]}
  return "$rc"
}

# emit_doc <source-id> <status> <detail> <polls> <action-exit-or-empty> <output-file-or-empty>
# The single stdout writer of `run`: everything the generic runner captures.
emit_doc() {
  local sid=$1 status=$2 detail=$3 polls=$4 action_exit=$5 outfile=$6
  printf 'when: %s\n' "$sid"
  printf 'status: %s\n' "$status"
  printf 'detail: %s\n' "$detail"
  printf 'condition_polls: %s\n' "$polls"
  [ -z "$action_exit" ] || printf 'action_exit: %s\n' "$action_exit"
  printf 'output:\n'
  if [ -n "$outfile" ] && [ -f "$outfile" ]; then
    tail -c "$OUTPUT_TAIL_BYTES" "$outfile" 2>/dev/null || true
  fi
}

cmd_run() {
  local sid=${1-} fired out rc polls=0 consecutive_true=0 consecutive_err=0 now
  fm_procevent_source_id_valid "$sid" || die "source id must be path-safe: $sid"
  fired=$(fired_file "$sid")

  if [ -e "$fired" ] || [ -L "$fired" ]; then
    emit_doc "$sid" ambiguous \
      "the action was already claimed but its outcome was never captured; verify its effect manually before retiring" 0 '' ''
    exit 0
  fi

  if ! positive_int "$OUTPUT_TAIL_BYTES"; then
    emit_doc "$sid" rejected "FM_WHEN_OUTPUT_TAIL_BYTES must be a positive integer; nothing was executed" 0 '' ''
    exit 0
  fi

  if ! spec_load "$sid"; then
    emit_doc "$sid" rejected "refused without executing anything: $SPEC_ERROR" 0 '' ''
    exit 0
  fi
  if ! executable_trust_valid condition "${COND_ARGV[0]}" "$SPEC_CONDITION_SHA256"; then
    emit_doc "$sid" rejected "refused without executing anything: $EXECUTABLE_ERROR" 0 '' ''
    exit 0
  fi
  if ! executable_trust_valid action "${ACT_ARGV[0]}" "$SPEC_ACTION_SHA256"; then
    emit_doc "$sid" rejected "refused without executing anything: $EXECUTABLE_ERROR" 0 '' ''
    exit 0
  fi

  if ! out=$(umask 077; mktemp "$WHEN_DIR/.run-out.XXXXXX"); then
    emit_doc "$sid" rejected "cannot stage command output; nothing was executed" 0 '' ''
    exit 0
  fi
  if ! condition_exec=$(stage_executable condition "${COND_ARGV[0]}" "$SPEC_CONDITION_SHA256"); then
    emit_doc "$sid" rejected "refused without executing the condition: ${EXECUTABLE_ERROR:-executable staging failed}" 0 '' ''
    exit 0
  fi
  trap 'rm -f -- "$out" "$condition_exec"' EXIT

  while :; do
    now=$(date +%s)
    if [ $(( now - SPEC_ARMED )) -ge "$SPEC_DEADLINE" ]; then
      emit_doc "$sid" never-true \
        "the condition never held for $SPEC_STABLE consecutive polls within ${SPEC_DEADLINE}s of arming" "$polls" '' ''
      exit 0
    fi
    if ! spec_load "$sid"; then
      emit_doc "$sid" rejected "refused before the next condition poll: $SPEC_ERROR" "$polls" '' ''
      exit 0
    fi
    if ! executable_trust_valid condition "${COND_ARGV[0]}" "$SPEC_CONDITION_SHA256"; then
      emit_doc "$sid" rejected "refused before the next condition poll: $EXECUTABLE_ERROR" "$polls" '' ''
      exit 0
    fi
    bounded_run "$SPEC_CONDITION_TIMEOUT" "$out" "$condition_exec" "${COND_ARGV[@]:1}"
    rc=$?
    polls=$((polls + 1))
    now=$(date +%s)
    if [ $(( now - SPEC_ARMED )) -ge "$SPEC_DEADLINE" ]; then
      emit_doc "$sid" never-true \
        "the condition never held for $SPEC_STABLE consecutive polls within ${SPEC_DEADLINE}s of arming" "$polls" '' "$out"
      exit 0
    fi
    case "$rc" in
      0)
        consecutive_true=$((consecutive_true + 1))
        consecutive_err=0
        [ "$consecutive_true" -ge "$SPEC_STABLE" ] && break
        ;;
      1)
        consecutive_true=0
        consecutive_err=0
        ;;
      *)
        consecutive_true=0
        consecutive_err=$((consecutive_err + 1))
        if [ "$consecutive_err" -ge "$SPEC_ERROR_BUDGET" ]; then
          emit_doc "$sid" condition-error \
            "the condition exited $rc on $consecutive_err consecutive polls; the action was not run" "$polls" '' "$out"
          exit 0
        fi
        ;;
    esac
    sleep "$SPEC_INTERVAL"
  done

  now=$(date +%s)
  if [ $(( now - SPEC_ARMED )) -ge "$SPEC_DEADLINE" ]; then
    emit_doc "$sid" never-true \
      "the condition never held for $SPEC_STABLE consecutive polls within ${SPEC_DEADLINE}s of arming" "$polls" '' "$out"
    exit 0
  fi

  # Revalidate the complete registered spec and both executable trust bindings
  # immediately before claiming the fire. A changed or newly protected command
  # must never run.
  if ! spec_load "$sid"; then
    emit_doc "$sid" rejected \
      "refused without executing the action: $SPEC_ERROR" "$polls" '' ''
    exit 0
  fi
  if ! executable_trust_valid condition "${COND_ARGV[0]}" "$SPEC_CONDITION_SHA256"; then
    emit_doc "$sid" rejected \
      "refused without executing the action: ${EXECUTABLE_ERROR:-executable staging failed}" "$polls" '' ''
    exit 0
  fi
  if ! executable_trust_valid action "${ACT_ARGV[0]}" "$SPEC_ACTION_SHA256"; then
    emit_doc "$sid" rejected \
      "refused without executing the action: $EXECUTABLE_ERROR" "$polls" '' ''
    exit 0
  fi

  if ! action_exec=$(stage_executable action "${ACT_ARGV[0]}" "$SPEC_ACTION_SHA256"); then
    emit_doc "$sid" rejected \
      "refused without executing the action: $EXECUTABLE_ERROR" "$polls" '' ''
    exit 0
  fi

  # Claim the fire durably and exclusively BEFORE the action, so no restart or
  # concurrent runner can ever run the action a second time.
  if ! (umask 077; set -o noclobber; printf '%s\n' "$(date +%s)" > "$fired") 2>/dev/null; then
    emit_doc "$sid" ambiguous \
      "another run already claimed the fire; verify the action's effect manually" "$polls" '' ''
    exit 0
  fi

  bounded_run "$SPEC_ACTION_TIMEOUT" "$out" "$action_exec" "${ACT_ARGV[@]:1}"
  rc=$?
  rm -f -- "$action_exec"
  if [ "$rc" -eq 0 ]; then
    emit_doc "$sid" fired "the condition held and the action exited 0" "$polls" "$rc" "$out"
  else
    emit_doc "$sid" action-failed "the condition held but the action exited $rc" "$polls" "$rc" "$out"
  fi
  exit 0
}

# --- result classification ---------------------------------------------------

# Read the status field from the document's leading block. The read stops at
# the output: marker, so captured command output can never forge the status.
result_status() {  # <result-file>
  awk '
    $0 == "output:" { exit }
    /^status: / { sub(/^status: /, ""); print; exit }
  ' "$1"
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(result_status "$file")
  case "$status" in
    fired|action-failed|condition-error|never-true|ambiguous|rejected)
      printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" != unknown ]
}

# --- retire ------------------------------------------------------------------

cmd_retire() {
  local name=${1-} sid captured=0 result
  when_name_valid "$name" || die "name must be path-safe and at most 59 characters: ${name-}"
  sid="when-$name"
  if [ -e "$(fired_file "$sid")" ]; then
    for result in "$(fm_procevent_inbox_dir "$STATE")/$sid".*.result; do
      [ -e "$result" ] && captured=1
    done
    if [ "$captured" -eq 0 ]; then
      printf 'warning: the action had fired but no outcome was captured; verify its effect manually\n' >&2
    fi
  fi
  "$SCRIPT_DIR/fm-procevent.sh" retire "$sid" || die "cannot retire the watch source: $sid"
  rm -f -- "$(spec_file "$sid")" "$(trust_file "$sid")" "$(fired_file "$sid")"
  printf 'retired: %s\n' "$sid"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  run)       shift; [ "$#" -eq 1 ] || usage; cmd_run "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
