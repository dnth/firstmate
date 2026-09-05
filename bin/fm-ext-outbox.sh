#!/usr/bin/env bash
# Gateway-facing outbox delivery helpers for the local Communication Officer.
#
# Usage:
#   fm-ext-outbox.sh pending
#   fm-ext-outbox.sh begin --slug <slug> --kind <kind> --generation <n>
#   fm-ext-outbox.sh receipt --slug <slug> --kind <kind> --generation <n>
#     --receipt-file <path>
#
# begin CAS-claims the posting marker. Exit 0 on a new claim, 1 when a receipt
# already exists (idempotent success), 3 on mid-delivery (posting without
# receipt), 2 on validation failure. receipt writes the receipt once.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-ext-lib.sh
. "$SCRIPT_DIR/fm-ext-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-ext-outbox.sh pending
       fm-ext-outbox.sh begin --slug <slug> --kind <kind> --generation <n>
       fm-ext-outbox.sh receipt --slug <slug> --kind <kind> --generation <n> --receipt-file <path>
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --slug) shift; SLUG=${1:-} ;;
    --kind) shift; KIND=${1:-} ;;
    --generation) shift; GENERATION=${1:-} ;;
    --receipt-file) shift; RECEIPT_FILE=${1:-} ;;
    --help|-h) help; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift || true
done

OUTBOX=$(fm_ext_outbox_dir)

case "$cmd" in
  pending)
    fm_ext_active "$FM_HOME" || exit 0
    [ -d "$OUTBOX" ] && [ ! -L "$OUTBOX" ] || exit 0
    for file in "$OUTBOX"/*.json; do
      [ -e "$file" ] || continue
      base=$(basename "$file")
      case "$base" in
        *.receipt.json) continue ;;
      esac
      fm_ext_outbox_schema_valid "$file" || continue
      slug=$(jq -r '.slug' "$file")
      kind=$(jq -r '.kind' "$file")
      generation=$(jq -r '.generation' "$file")
      receipt=$(fm_ext_outbox_receipt_basename "$slug" "$kind" "$generation") || continue
      if fm_ext_private_artifact_file_valid "$OUTBOX" "$receipt" 600; then
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
  *) usage; exit 2 ;;
esac
