#!/usr/bin/env bash
# Gateway-facing outbox delivery helpers for the local Communication Officer.
#
# Usage:
#   fm-ext-outbox.sh pending
#   fm-ext-outbox.sh begin --slug <slug> --kind <kind> --generation <n>
#   fm-ext-outbox.sh receipt --slug <slug> --kind <kind> --generation <n>
#     --receipt-file <path>
#   fm-ext-outbox.sh abort --slug <slug> --kind <kind> --generation <n>
#   fm-ext-outbox.sh fail --slug <slug> --kind <kind> --generation <n>
#     --reason-file <path>
#   fm-ext-outbox.sh progress --slug <slug> --kind <kind> --generation <n>
#     --progress-file <path>
#   fm-ext-outbox.sh release --slug <slug> --kind <kind> --generation <n>
#   fm-ext-outbox.sh split [--max <n>] [--cap <n>]
#
# pending lists only generations that are still genuinely pending: a payload
# whose generation has reached a receipt or a terminal failed marker is retired
# on sight, so the scan cost stays flat as delivered replies accumulate instead
# of growing with every reply ever sent.
# begin CAS-claims the posting marker, then CAS-claims an exclusive inflight
# send marker (recording owner pid and recorded_at) before returning a send
# right. Exit 0 on a new claim, a resumable split this caller exclusively
# claimed, or a steal of a dead-owner claim older than
# FM_EXT_INFLIGHT_TTL_SECS (default 30). Exit 1 when a receipt already
# exists (idempotent success), 3 on mid-delivery (posting without this
# caller owning the next send, including a live owner inside or past the
# TTL), 4 when a terminal failed marker exists, 2 on validation failure.
# Exit 5 when a generation left in-flight by an ambiguous send stayed stuck
# past FM_EXT_MIDDELIVERY_RECOVERY_SECS (default 300) for more than
# FM_EXT_MIDDELIVERY_RECOVERY_MAX (default 3) recovery attempts: begin records
# the terminal failure and wakes firstmate rather than refusing forever. Inside
# that budget begin reopens the ambiguous chunk for one more attempt, so an
# ordinary network timeout costs at most a repeated chunk, never a silently
# truncated reply.
# Two concurrent live posters cannot both get the send right for the same
# generation and chunk. Steal serialization keeps a 1-second floor so
# FM_EXT_INFLIGHT_TTL_SECS=0 cannot let two stealers both win. receipt
# writes the receipt once and releases a leftover inflight marker.
# abort releases the exclusive inflight send marker first, then deletes the
# posting marker and chunk progress, after a transient definite send failure
# (HTTP 429 or 5xx) before any chunk succeeded so that generation can retry.
# It refuses when a receipt or terminal failed marker already exists. An
# ambiguous crash or transport error after a chunk post started keeps the
# posting and inflight markers.
# fail records a terminal failed marker after a permanent 4xx so pending
# stops retrying that generation, and drops posting plus inflight.
# progress replaces the durable per-chunk progress artifact.
# release drops the exclusive inflight send marker after a later-chunk
# transient failure so another poster may resume remaining chunks. The
# posting marker and progress stay in place.
# split reads reply text on stdin and prints {limit,cap,texts} using
# FM_EXT_DISCORD_REPLY_MAX_CHARS (default 1900) and FM_EXT_DISCORD_THREAD_MAX
# (default 25). It does not require FMX_PAIRING_TOKEN or the hosted relay.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-ext-lib.sh
. "$SCRIPT_DIR/fm-ext-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-ext-outbox.sh pending
       fm-ext-outbox.sh begin --slug <slug> --kind <kind> --generation <n>
       fm-ext-outbox.sh receipt --slug <slug> --kind <kind> --generation <n> --receipt-file <path>
       fm-ext-outbox.sh abort --slug <slug> --kind <kind> --generation <n>
       fm-ext-outbox.sh fail --slug <slug> --kind <kind> --generation <n> --reason-file <path>
       fm-ext-outbox.sh progress --slug <slug> --kind <kind> --generation <n> --progress-file <path>
       fm-ext-outbox.sh release --slug <slug> --kind <kind> --generation <n>
       fm-ext-outbox.sh split [--max <n>] [--cap <n>]
EOF
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-ext-outbox: %s\n' "$1" >&2; exit "${2:-2}"; }

cmd=${1:-}
case "$cmd" in
  --help|-h) help; exit 0 ;;
  '') usage; exit 2 ;;
esac
shift || true

SLUG=
KIND=
GENERATION=
RECEIPT_FILE=
REASON_FILE=
PROGRESS_FILE=
MAX_CHARS=
THREAD_CAP=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --slug) shift; SLUG=${1:-} ;;
    --kind) shift; KIND=${1:-} ;;
    --generation) shift; GENERATION=${1:-} ;;
    --receipt-file) shift; RECEIPT_FILE=${1:-} ;;
    --reason-file) shift; REASON_FILE=${1:-} ;;
    --progress-file) shift; PROGRESS_FILE=${1:-} ;;
    --max) shift; MAX_CHARS=${1:-} ;;
    --cap) shift; THREAD_CAP=${1:-} ;;
    --help|-h) help; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift || true
done

case "$cmd" in
  split)
    command -v jq >/dev/null 2>&1 || die "jq is required" 1
    max=$(fm_ext_discord_reply_max_chars "$MAX_CHARS")
    cap=$(fm_ext_discord_thread_max "$THREAD_CAP")
    texts=$(fm_ext_split_thread "$max" "$cap") || die "could not split the reply" 2
    jq -cn --argjson limit "$max" --argjson cap "$cap" --argjson texts "$texts" \
      '{limit:$limit, cap:$cap, texts:$texts}' \
      || die "could not encode the split result" 2
    exit 0
    ;;
esac

OUTBOX=$(fm_ext_outbox_dir)

# Every subcommand below writes or reads state/ext-outbox, so all of them are
# gated on the same activation the intake, emit, and poll paths use. Only
# `split` runs ungated, because it is a pure text function over stdin.
case "$cmd" in
  pending) ;;
  *) fm_ext_active "$FM_HOME" || die "local ext-bridge is not active" 1 ;;
esac

case "$cmd" in
  pending)
    fm_ext_active "$FM_HOME" || exit 0
    [ -d "$OUTBOX" ] && [ ! -L "$OUTBOX" ] || exit 0
    for file in "$OUTBOX"/*.json; do
      [ -e "$file" ] || continue
      # Marker names are matched with parameter expansion, not basename: this
      # loop runs on every poll, and one process per marker is what made the
      # scan cost grow with the number of replies already delivered.
      base=${file##*/}
      case "$base" in
        *.receipt.json|*.failed.json|*.progress.json) continue ;;
      esac
      fm_ext_outbox_schema_valid "$file" || continue
      slug=$(jq -r '.slug' "$file")
      kind=$(jq -r '.kind' "$file")
      generation=$(jq -r '.generation' "$file")
      receipt=$(fm_ext_outbox_receipt_basename "$slug" "$kind" "$generation") || continue
      failed=$(fm_ext_outbox_failed_basename "$slug" "$kind" "$generation") || continue
      if fm_ext_private_artifact_file_valid "$OUTBOX" "$receipt" 600 \
        || fm_ext_private_artifact_file_valid "$OUTBOX" "$failed" 600; then
        # Terminal: retire the payload so later polls never re-scan it. A
        # generation whose payload predates retirement is caught here too.
        fm_ext_outbox_retire "$OUTBOX" "$slug" "$kind" "$generation" || true
        continue
      fi
      printf '%s\n' "$file"
    done
    ;;
  begin)
    fm_ext_slug_valid "$SLUG" || die "unsafe slug"
    fm_ext_kind_valid "$KIND" || die "invalid kind"
    fm_ext_generation_valid "$GENERATION" || die "invalid generation"
    fm_ext_outbox_begin "$OUTBOX" "$SLUG" "$KIND" "$GENERATION"
    rc=$?
    case "$rc" in
      0) printf 'claimed %s %s %s\n' "$SLUG" "$KIND" "$GENERATION" ;;
      1) printf 'already-receipted %s %s %s\n' "$SLUG" "$KIND" "$GENERATION" ;;
      3) die "mid-delivery: $KIND generation $GENERATION is posting and has no receipt" 3 ;;
      4) printf 'terminal-failed %s %s %s\n' "$SLUG" "$KIND" "$GENERATION" ;;
      5)
        printf 'recovery-exhausted %s %s %s\n' "$SLUG" "$KIND" "$GENERATION"
        # The terminal failure is already durable; this wake is what makes it
        # visible to firstmate instead of leaving a silently undelivered reply.
        if ! fm_wake_append check "$FM_EXT_WATCH_SHIM" "ext-delivery-failed $SLUG"; then
          printf 'fm-ext-outbox: recorded the terminal failure for %s but could not append its wake\n' \
            "$SLUG" >&2
        fi
        ;;
      *) die "could not begin delivery" 2 ;;
    esac
    exit "$rc"
    ;;
  receipt)
    fm_ext_slug_valid "$SLUG" || die "unsafe slug"
    fm_ext_kind_valid "$KIND" || die "invalid kind"
    fm_ext_generation_valid "$GENERATION" || die "invalid generation"
    [ -f "$RECEIPT_FILE" ] || die "receipt file not found: $RECEIPT_FILE"
    body=$(cat -- "$RECEIPT_FILE")
    [ -n "$body" ] || die "receipt file is empty"
    fm_ext_outbox_receipt "$OUTBOX" "$SLUG" "$KIND" "$GENERATION" "$body"
    rc=$?
    case "$rc" in
      0) printf 'receipted %s %s %s\n' "$SLUG" "$KIND" "$GENERATION" ;;
      1) printf 'already-receipted %s %s %s\n' "$SLUG" "$KIND" "$GENERATION" ;;
      *) die "could not record the receipt" 2 ;;
    esac
    exit "$rc"
    ;;
  abort)
    fm_ext_slug_valid "$SLUG" || die "unsafe slug"
    fm_ext_kind_valid "$KIND" || die "invalid kind"
    fm_ext_generation_valid "$GENERATION" || die "invalid generation"
    fm_ext_outbox_abort "$OUTBOX" "$SLUG" "$KIND" "$GENERATION"
    rc=$?
    case "$rc" in
      0) printf 'aborted %s %s %s\n' "$SLUG" "$KIND" "$GENERATION" ;;
      1) printf 'already-receipted %s %s %s\n' "$SLUG" "$KIND" "$GENERATION" ;;
      *) die "could not abort delivery" 2 ;;
    esac
    exit "$rc"
    ;;
  fail)
    fm_ext_slug_valid "$SLUG" || die "unsafe slug"
    fm_ext_kind_valid "$KIND" || die "invalid kind"
    fm_ext_generation_valid "$GENERATION" || die "invalid generation"
    [ -f "$REASON_FILE" ] || die "reason file not found: $REASON_FILE"
    body=$(cat -- "$REASON_FILE")
    [ -n "$body" ] || die "reason file is empty"
    fm_ext_outbox_fail "$OUTBOX" "$SLUG" "$KIND" "$GENERATION" "$body"
    rc=$?
    case "$rc" in
      0) printf 'failed %s %s %s\n' "$SLUG" "$KIND" "$GENERATION" ;;
      1) printf 'already-receipted %s %s %s\n' "$SLUG" "$KIND" "$GENERATION" ;;
      4) printf 'already-failed %s %s %s\n' "$SLUG" "$KIND" "$GENERATION" ;;
      *) die "could not record the terminal failure" 2 ;;
    esac
    exit "$rc"
    ;;
  progress)
    fm_ext_slug_valid "$SLUG" || die "unsafe slug"
    fm_ext_kind_valid "$KIND" || die "invalid kind"
    fm_ext_generation_valid "$GENERATION" || die "invalid generation"
    [ -f "$PROGRESS_FILE" ] || die "progress file not found: $PROGRESS_FILE"
    body=$(cat -- "$PROGRESS_FILE")
    [ -n "$body" ] || die "progress file is empty"
    fm_ext_outbox_progress "$OUTBOX" "$SLUG" "$KIND" "$GENERATION" "$body" \
      || die "could not record chunk progress" 2
    printf 'progress %s %s %s\n' "$SLUG" "$KIND" "$GENERATION"
    ;;
  release)
    fm_ext_slug_valid "$SLUG" || die "unsafe slug"
    fm_ext_kind_valid "$KIND" || die "invalid kind"
    fm_ext_generation_valid "$GENERATION" || die "invalid generation"
    fm_ext_outbox_inflight_release "$OUTBOX" "$SLUG" "$KIND" "$GENERATION" \
      || die "could not release the inflight send marker" 2
    printf 'released %s %s %s\n' "$SLUG" "$KIND" "$GENERATION"
    ;;
  *) usage; exit 2 ;;
esac
