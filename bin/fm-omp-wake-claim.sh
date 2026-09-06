#!/usr/bin/env bash
# Command-line face of the durable OMP primary wake-notification claim.
# bin/fm-omp-wake-claim-lib.sh owns the format, the invariants, and every
# mutation; this script only holds the durable wake-queue lock around one of
# them so the OMP adapter can drive the claim without linking that lock into
# its own process.
#
# Usage:
#   fm-omp-wake-claim.sh publish --instance <id> --session <id>   # body on stdin
#   fm-omp-wake-claim.sh replay  --instance <id> --session <id>   # body on stdout
#   fm-omp-wake-claim.sh show
#
# publish binds one outstanding notification to this OMP process and session.
# replay hands an outstanding claim to a new owner exactly once and prints the
# exact body to re-present; a claim already bound to the given owner is a
# same-session extension reload and prints nothing.
# show prints "<id>\t<instance>\t<session>\t<cutoff>\t<content-base64>".
#
# Exit codes: 0 done, 1 failed, 2 usage, 3 nothing to replay or show,
# 4 the durable wake-queue lock stayed busy for the whole bounded wait
# (FM_OMP_WAKE_CLAIM_LOCK_ATTEMPTS attempts, 0.05s apart, default 200).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-omp-wake-claim-lib.sh
. "$SCRIPT_DIR/fm-omp-wake-claim-lib.sh"

LOCK_HELD=false
CLAIM_TMP=

usage() {
  echo "usage: fm-omp-wake-claim.sh (publish|replay) --instance <id> --session <id> | show" >&2
  exit 2
}

# shellcheck disable=SC2317,SC2329 # Invoked by the trap handlers below.
cleanup() {
  local status=$?
  [ -z "$CLAIM_TMP" ] || rm -f -- "$CLAIM_TMP" 2>/dev/null || true
  if [ "$LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

# Portable decode: GNU coreutils spells it --decode, BSD base64 spells it -D.
# Decode into a file rather than straight to stdout so a rejected first attempt
# can never leave a partial body behind for the second one to append to.
decode_base64_to() {  # <content-base64> <destination>
  if printf '%s' "$1" | base64 --decode > "$2" 2>/dev/null; then return 0; fi
  printf '%s' "$1" | base64 -D > "$2" 2>/dev/null
}

acquire_queue_lock() {
  local attempts=${FM_OMP_WAKE_CLAIM_LOCK_ATTEMPTS:-200} attempt=0
  case "$attempts" in
    ''|*[!0-9]*|0) attempts=200 ;;
  esac
  while ! fm_lock_try_acquire "$FM_WAKE_QUEUE_LOCK"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$attempts" ]; then
      echo "fm-omp-wake-claim: durable wake queue lock stayed busy" >&2
      exit 4
    fi
    sleep 0.05
  done
  LOCK_HELD=true
}

COMMAND=${1:-}
[ -n "$COMMAND" ] || usage
shift || true

INSTANCE=
SESSION=
case "$COMMAND" in
  publish|replay)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --instance) INSTANCE=${2:-}; shift 2 || usage ;;
        --session) SESSION=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    fm_omp_wake_claim_token_ok "$INSTANCE" || usage
    fm_omp_wake_claim_token_ok "$SESSION" || usage
    ;;
  show)
    [ "$#" -eq 0 ] || usage
    ;;
  *) usage ;;
esac

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$COMMAND" in
  publish)
    CLAIM_CONTENT=$(base64 | tr -d '\n') || exit 1
    [ -n "$CLAIM_CONTENT" ] || { echo "fm-omp-wake-claim: refusing to claim an empty notification" >&2; exit 1; }
    acquire_queue_lock
    fm_omp_wake_claim_publish_locked "$INSTANCE" "$SESSION" "$CLAIM_CONTENT" || exit 1
    ;;
  replay)
    acquire_queue_lock
    fm_omp_wake_claim_replay_pending_locked "$INSTANCE" "$SESSION" || exit "$?"
    CLAIM_TMP=$(mktemp "$STATE/.omp-wake-claim.replay.XXXXXX") || exit 1
    decode_base64_to "$FM_OMP_WAKE_CLAIM_CONTENT_B64" "$CLAIM_TMP" || exit 1
    # Hand the body over first and rebind last: an interruption before the
    # rebind leaves the claim with its previous owner, so the next replay
    # attempt re-presents the same batch instead of losing it.
    command cat "$CLAIM_TMP" || exit 1
    fm_omp_wake_claim_rebind_locked "$INSTANCE" "$SESSION" || exit 1
    ;;
  show)
    acquire_queue_lock
    fm_omp_wake_claim_read_locked || exit 3
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$FM_OMP_WAKE_CLAIM_ID" "$FM_OMP_WAKE_CLAIM_INSTANCE" "$FM_OMP_WAKE_CLAIM_SESSION" \
      "$FM_OMP_WAKE_CLAIM_CUTOFF" "$FM_OMP_WAKE_CLAIM_CONTENT_B64" || exit 1
    ;;
esac

exit 0
