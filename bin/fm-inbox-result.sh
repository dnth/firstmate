#!/usr/bin/env bash
# Durable terminal result envelopes for trusted-local Firstmate inbox notes.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$BIN_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-inbox-result-lib.sh
. "$BIN_DIR/fm-inbox-result-lib.sh"

# shellcheck disable=SC2153 # STATE is assigned by fm-wake-lib.sh.
INBOX_DIR="$STATE/inbox"
HANDLED_DIR="$INBOX_DIR/handled"
RESULT_DIR="$STATE/inbox-results"
ADAPTER=${FM_INBOX_RESULT_ADAPTER:-$BIN_DIR/fm-inbox-hermes-adapter.sh}

usage() {
  cat >&2 <<'EOF'
usage: fm-inbox-result.sh publish --note-id <id> --status <completed|failed|needs-input> --summary-file <path> [--artifact <absolute-path>]... [--no-deliver]
       fm-inbox-result.sh deliver --note-id <id>
       fm-inbox-result.sh retry --note-id <id> [--confirm-ambiguous] [--force]
       fm-inbox-result.sh status [--note-id <id>]
EOF
  exit 2
}

die() {
  printf 'fm-inbox-result: %s\n' "$*" >&2
  exit 1
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

ensure_result_dir() {
  [ ! -L "$RESULT_DIR" ] || die "result directory must not be a symlink"
  [ ! -e "$RESULT_DIR" ] || [ -d "$RESULT_DIR" ] \
    || die "result path must be a directory"
  mkdir -p "$RESULT_DIR"
  chmod 0700 "$RESULT_DIR"
}

validate_result_dir() {
  [ ! -L "$RESULT_DIR" ] || die "result directory must not be a symlink"
  [ ! -e "$RESULT_DIR" ] || [ -d "$RESULT_DIR" ] \
    || die "result path must be a directory"
}

validate_inbox_dirs() {
  [ ! -L "$INBOX_DIR" ] || die "inbox directory must not be a symlink"
  [ ! -e "$INBOX_DIR" ] || [ -d "$INBOX_DIR" ] \
    || die "inbox path must be a directory"
  [ ! -L "$HANDLED_DIR" ] || die "handled inbox directory must not be a symlink"
  [ ! -e "$HANDLED_DIR" ] || [ -d "$HANDLED_DIR" ] \
    || die "handled inbox path must be a directory"
}

result_path() { printf '%s/%s.result.json\n' "$RESULT_DIR" "$1"; }
receipt_path() { printf '%s/%s.receipt.json\n' "$RESULT_DIR" "$1"; }
failed_path() { printf '%s/%s.failed.json\n' "$RESULT_DIR" "$1"; }
posting_path() { printf '%s/%s.posting\n' "$RESULT_DIR" "$1"; }
lock_path() { printf '%s/%s.delivery.lock\n' "$RESULT_DIR" "$1"; }
publish_lock_path() { printf '%s/%s.publish.lock\n' "$RESULT_DIR" "$1"; }

validate_owned_file_or_absent() {
  local path=$1 label=$2
  [ ! -L "$path" ] || die "$label must not be a symlink"
  [ ! -e "$path" ] || [ -f "$path" ] || die "$label must be a regular file"
}

atomic_json_private() { # <destination>; JSON on stdin
  local destination=$1 tmp
  tmp=$(mktemp "$RESULT_DIR/.record.XXXXXX") || return 1
  if ! cat > "$tmp" || ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1 \
      || ! chmod 0600 "$tmp" || ! mv "$tmp" "$destination"; then
    rm -f -- "$tmp"
    return 1
  fi
}

find_note() {
  local id=$1 pending handled
  pending="$INBOX_DIR/$id.note"
  handled="$HANDLED_DIR/$id.note"
  validate_owned_file_or_absent "$pending" "pending note"
  validate_owned_file_or_absent "$handled" "handled note"
  if [ -f "$pending" ] && [ -f "$handled" ]; then
    die "note exists in both pending and handled state: $id"
  fi
  if [ -f "$pending" ]; then
    printf '%s\n' "$pending"
  elif [ -f "$handled" ]; then
    printf '%s\n' "$handled"
  else
    die "note not found: $id"
  fi
}

validate_result_envelope() {
  local path=$1 id=$2
  validate_owned_file_or_absent "$path" "result record"
  [ -f "$path" ] || die "result not found: $id"
  jq -e --arg id "$id" \
    '.schema == "firstmate.inbox-result.v1" and .note_id == $id and
     (.request_note_id | type == "string") and
     (.correlation_id | type == "string") and
     (.reply_target | type == "string") and
     (.status == "completed" or .status == "failed" or .status == "needs-input") and
     (.summary | type == "string") and (.artifacts | type == "array")' \
    "$path" >/dev/null || die "invalid result envelope: $id"
}

validate_receipt_envelope() {
  local path=$1 id=$2
  [ -f "$path" ] || return 0
  jq -e --arg id "$id" \
    '.schema == "firstmate.inbox-result-receipt.v1" and .note_id == $id and
     (.delivered_at | type == "string") and
     (.adapter_receipt | type == "object") and .adapter_receipt.ok == true' \
    "$path" >/dev/null || die "invalid delivery receipt: $id"
}

validate_failure_envelope() {
  local path=$1 id=$2
  [ -f "$path" ] || return 0
  jq -e --arg id "$id" \
    '.schema == "firstmate.inbox-result-failure.v1" and .note_id == $id and
     (.classification == "transient" or .classification == "permanent" or
      .classification == "ambiguous") and
     (.reason | type == "string") and (.failed_at | type == "string")' \
    "$path" >/dev/null || die "invalid delivery failure: $id"
}

write_failure() { # <id> <classification> <reason>
  local id=$1 classification=$2 reason=$3 failed now
  failed=$(failed_path "$id")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg id "$id" --arg classification "$classification" --arg reason "$reason" --arg at "$now" \
    '{schema:"firstmate.inbox-result-failure.v1", note_id:$id, classification:$classification,
      reason:$reason, failed_at:$at}' | atomic_json_private "$failed" \
    || die "cannot persist delivery failure"
}

publish_command() {
  local id='' status='' summary_file='' no_deliver=0 note target correlation request_id
  local result tmp artifacts_file created existing_cmp new_cmp artifact
  local summary_fd summary_size
  local -a artifacts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note-id) [ "$#" -ge 2 ] || usage; id=$2; shift 2 ;;
      --status) [ "$#" -ge 2 ] || usage; status=$2; shift 2 ;;
      --summary-file) [ "$#" -ge 2 ] || usage; summary_file=$2; shift 2 ;;
      --artifact) [ "$#" -ge 2 ] || usage; artifacts+=("$2"); shift 2 ;;
      --no-deliver) no_deliver=1; shift ;;
      *) usage ;;
    esac
  done
  fm_inbox_valid_note_id "$id" || die "invalid note id"
  case "$status" in completed|failed|needs-input) ;; *) die "invalid result status" ;; esac
  [ -n "$summary_file" ] || usage
  fm_inbox_artifact_safe "$summary_file" \
    || die "summary file must be a regular non-symlink file"
  exec {summary_fd}<"$summary_file" \
    || die "summary file must be a regular non-symlink file"
  fm_inbox_artifact_safe "$summary_file" \
    || { exec {summary_fd}<&-; die "summary file must be a regular non-symlink file"; }
  if [ "$(uname)" = Darwin ]; then
    summary_size=$(stat -L -f %z "/dev/fd/$summary_fd")
  else
    summary_size=$(stat -L -c %s "/proc/$$/fd/$summary_fd")
  fi
  [ "$summary_size" -le 16384 ] \
    || { exec {summary_fd}<&-; die "summary must not exceed 16384 bytes"; }
  [ "${#artifacts[@]}" -le 20 ] || die "at most 20 artifacts are supported"
  for artifact in "${artifacts[@]}"; do
    fm_inbox_artifact_safe "$artifact" || {
      [ -L "$artifact" ] && die "artifact must not be a symlink: $artifact"
      die "unsafe artifact path: $artifact"
    }
  done

  require_jq
  validate_inbox_dirs
  note=$(find_note "$id")
  fm_inbox_note_is_envelope "$note" \
    || die "note has no supported reply metadata: $id"
  jq -e --arg id "$id" '.note_id == $id and .request_note_id == $id' "$note" >/dev/null \
    || die "note identity does not match its filename: $id"
  target=$(jq -r '.reply_target' "$note")
  correlation=$(jq -r '.correlation_id' "$note")
  request_id=$(jq -r '.request_note_id' "$note")
  fm_inbox_valid_reply_target "$target" || die "invalid reply target in note"
  fm_inbox_valid_correlation_id "$correlation" || die "invalid correlation id in note"

  ensure_result_dir
  acquire_owned_lock "$(publish_lock_path "$id")" "publication" "$id"
  result=$(result_path "$id")
  validate_owned_file_or_absent "$result" "result record"
  tmp=$(mktemp "$RESULT_DIR/.result.XXXXXX") || die "cannot create result"
  artifacts_file=$(mktemp "$RESULT_DIR/.artifacts.XXXXXX") || {
    rm -f -- "$tmp"
    die "cannot create artifact list"
  }
  if [ "${#artifacts[@]}" -gt 0 ]; then
    printf '%s\n' "${artifacts[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))' > "$artifacts_file"
  else
    printf '[]\n' > "$artifacts_file"
  fi
  created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! jq -n --arg id "$id" --arg request "$request_id" --arg correlation "$correlation" \
      --arg target "$target" --arg status "$status" --rawfile summary "/dev/fd/$summary_fd" \
      --arg created "$created" --slurpfile artifacts "$artifacts_file" \
      '{schema:"firstmate.inbox-result.v1", note_id:$id, request_note_id:$request,
        correlation_id:$correlation, reply_target:$target, status:$status,
        summary:($summary | sub("\\n$"; "")), artifacts:$artifacts[0], created_at:$created}' \
      > "$tmp"; then
    exec {summary_fd}<&-
    rm -f -- "$tmp" "$artifacts_file"
    die "cannot encode result"
  fi
  exec {summary_fd}<&-
  rm -f -- "$artifacts_file"
  chmod 0600 "$tmp"

  if [ -f "$result" ]; then
    validate_result_envelope "$result" "$id"
    existing_cmp=$(jq -S -c 'del(.created_at)' "$result")
    new_cmp=$(jq -S -c 'del(.created_at)' "$tmp")
    rm -f -- "$tmp"
    [ "$existing_cmp" = "$new_cmp" ] \
      || die "result already published with different content: $id"
    printf 'already-published %s\n' "$id"
  else
    if ! mv "$tmp" "$result"; then
      rm -f -- "$tmp"
      die "cannot persist result"
    fi
    printf 'published %s\n' "$id"
  fi

  release_owned_lock "$(publish_lock_path "$id")"

  [ "$no_deliver" -eq 1 ] || deliver_one "$id"
}

# Do not use command substitution for fm_current_pid: BASHPID would then name
# the short-lived substitution process rather than this result publisher.
RESULT_LOCK_PID=${BASHPID:-$$}
RESULT_LOCK_IDENTITY=$(fm_pid_identity "$RESULT_LOCK_PID") \
  || die "cannot determine result publisher process identity"
declare -a RESULT_ACTIVE_LOCKS=()

owned_lock_contents_safe() {
  local lock=$1 entry
  for entry in "$lock"/* "$lock"/.[!.]* "$lock"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ "$entry" = "$lock/owner" ] || return 1
    [ -f "$entry" ] && [ ! -L "$entry" ] || return 1
  done
}

owned_lock_owner() { # <lock>; sets LOCK_OWNER_PID and LOCK_OWNER_IDENTITY
  local lock=$1 owner="$1/owner"
  LOCK_OWNER_PID=
  LOCK_OWNER_IDENTITY=
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
  {
    IFS= read -r LOCK_OWNER_PID || true
    IFS= read -r LOCK_OWNER_IDENTITY || true
  } < "$owner"
  case "$LOCK_OWNER_PID" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$LOCK_OWNER_IDENTITY" ]
}

owned_lock_is_live() {
  local lock=$1 current
  owned_lock_owner "$lock" || return 1
  fm_pid_alive "$LOCK_OWNER_PID" || return 1
  current=$(fm_pid_identity "$LOCK_OWNER_PID") || return 0
  [ "$current" = "$LOCK_OWNER_IDENTITY" ]
}

reclaim_owned_lock() {
  local lock=$1 grave owner
  owned_lock_contents_safe "$lock" || die "lock contains unexpected entries: $lock"
  grave="$lock.reclaim.$RESULT_LOCK_PID.$RANDOM"
  if ! mv "$lock" "$grave" 2>/dev/null; then
    return 1
  fi
  owner="$grave/owner"
  [ ! -e "$owner" ] || rm -f -- "$owner"
  if ! rmdir "$grave" 2>/dev/null; then
    die "cannot remove reclaimed lock: $grave"
  fi
}

acquire_owned_lock() { # <lock> <label> <id>
  local lock=$1 label=$2 id=$3 owner_tmp attempts=0
  while :; do
    [ ! -L "$lock" ] || die "$label lock must not be a symlink"
    if mkdir "$lock" 2>/dev/null; then
      chmod 0700 "$lock"
      RESULT_ACTIVE_LOCKS+=("$lock")
      owner_tmp=$(mktemp "$lock/.owner.XXXXXX") || die "cannot create $label lock owner"
      if ! printf '%s\n%s\n' "$RESULT_LOCK_PID" "$RESULT_LOCK_IDENTITY" > "$owner_tmp" \
          || ! chmod 0600 "$owner_tmp" || ! mv "$owner_tmp" "$lock/owner"; then
        rm -f -- "$owner_tmp"
        die "cannot persist $label lock owner"
      fi
      return 0
    fi

    [ -d "$lock" ] || die "$label lock path is not a directory"
    if owned_lock_is_live "$lock"; then
      die "$label is already in progress: $id"
    fi
    # An ownerless lock is not provably stale: its creator may be between
    # mkdir and the atomic owner rename. Never reclaim it automatically,
    # because doing so could let two delivery processes send the same result.
    owned_lock_owner "$lock" \
      || die "$label lock owner is missing or malformed: $id"
    reclaim_owned_lock "$lock" || {
      attempts=$((attempts + 1))
      [ "$attempts" -lt 3 ] || die "cannot reclaim stale $label lock: $id"
      continue
    }
  done
}

release_owned_lock() {
  local lock=$1
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 0
  owned_lock_owner "$lock" || return 0
  [ "$LOCK_OWNER_PID" = "$RESULT_LOCK_PID" ] \
    && [ "$LOCK_OWNER_IDENTITY" = "$RESULT_LOCK_IDENTITY" ] || return 0
  rm -f -- "$lock/owner"
  rmdir "$lock" 2>/dev/null || true
}

cleanup_owned_locks() {
  local lock
  for lock in "${RESULT_ACTIVE_LOCKS[@]}"; do
    release_owned_lock "$lock"
  done
}
trap cleanup_owned_locks EXIT

acquire_delivery_lock() {
  local id=$1
  acquire_owned_lock "$(lock_path "$id")" "delivery" "$id"
}

release_delivery_lock() {
  release_owned_lock "$(lock_path "$1")"
}

deliver_one() {
  local id=$1 result receipt failed posting target output errfile rc classification reason
  fm_inbox_valid_note_id "$id" || die "invalid note id"
  require_jq
  validate_result_dir
  result=$(result_path "$id")
  receipt=$(receipt_path "$id")
  failed=$(failed_path "$id")
  posting=$(posting_path "$id")
  validate_result_envelope "$result" "$id"
  validate_owned_file_or_absent "$receipt" "delivery receipt"
  validate_owned_file_or_absent "$failed" "delivery failure"
  validate_owned_file_or_absent "$posting" "posting marker"
  validate_receipt_envelope "$receipt" "$id"
  validate_failure_envelope "$failed" "$id"
  ensure_result_dir
  acquire_delivery_lock "$id"

  if [ -f "$receipt" ]; then
    printf 'already-delivered %s\n' "$id"
    release_delivery_lock "$id"
    return 0
  fi
  if [ -f "$posting" ]; then
    release_delivery_lock "$id"
    die "ambiguous prior delivery for $id; use retry --confirm-ambiguous after checking the target"
  fi
  if [ -f "$failed" ]; then
    release_delivery_lock "$id"
    die "delivery failed for $id; use retry"
  fi

  target=$(jq -r '.reply_target' "$result")
  fm_inbox_valid_reply_target "$target" || {
    write_failure "$id" permanent "invalid reply target"
    release_delivery_lock "$id"
    die "invalid reply target"
  }
  fm_inbox_reply_target_authorized "$target" || {
    write_failure "$id" permanent "reply target is not authorized"
    release_delivery_lock "$id"
    die "reply target is not authorized"
  }
  [ -f "$ADAPTER" ] && [ ! -L "$ADAPTER" ] && [ -x "$ADAPTER" ] || {
    write_failure "$id" permanent "result adapter is unavailable"
    release_delivery_lock "$id"
    die "result adapter is unavailable"
  }

  if ! (umask 077; printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$posting"); then
    release_delivery_lock "$id"
    die "cannot persist posting marker"
  fi
  errfile=$(mktemp "$RESULT_DIR/.adapter-error.XXXXXX") || {
    release_delivery_lock "$id"
    die "cannot capture adapter failure"
  }
  set +e
  output=$(
    "$ADAPTER" --target "$target" --idempotency-key "$id" --payload-file "$result" \
      2>"$errfile"
  )
  rc=$?
  set -e
  reason=$(cat "$errfile")
  rm -f -- "$errfile"

  if [ "$rc" -eq 0 ] && printf '%s\n' "$output" | jq -e \
      'type == "object" and .ok == true' >/dev/null 2>&1; then
    printf '%s\n' "$output" | jq --arg id "$id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{schema:"firstmate.inbox-result-receipt.v1", note_id:$id,
        delivered_at:$at, adapter_receipt:.}' | atomic_json_private "$receipt" \
      || {
        release_delivery_lock "$id"
        die "delivery may have succeeded but receipt persistence failed"
      }
    rm -f -- "$failed"
    printf 'delivered %s\n' "$id"
    release_delivery_lock "$id"
    return 0
  fi

  [ -n "$reason" ] || reason="adapter exited $rc"
  case "$rc" in
    75) classification=transient; rm -f -- "$posting" ;;
    64) classification=permanent; rm -f -- "$posting" ;;
    *) classification=ambiguous ;;
  esac
  write_failure "$id" "$classification" "$reason"
  release_delivery_lock "$id"
  die "delivery failed ($classification): $id"
}

deliver_command() {
  [ "$#" -eq 2 ] && [ "$1" = --note-id ] || usage
  deliver_one "$2"
}

retry_command() {
  local id='' confirm=0 force=0 failed posting receipt classification
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note-id) [ "$#" -ge 2 ] || usage; id=$2; shift 2 ;;
      --confirm-ambiguous) confirm=1; shift ;;
      --force) force=1; shift ;;
      *) usage ;;
    esac
  done
  fm_inbox_valid_note_id "$id" || die "invalid note id"
  require_jq
  ensure_result_dir
  validate_result_envelope "$(result_path "$id")" "$id"
  failed=$(failed_path "$id")
  posting=$(posting_path "$id")
  receipt=$(receipt_path "$id")
  validate_owned_file_or_absent "$failed" "delivery failure"
  validate_owned_file_or_absent "$posting" "posting marker"
  validate_owned_file_or_absent "$receipt" "delivery receipt"
  validate_receipt_envelope "$receipt" "$id"
  validate_failure_envelope "$failed" "$id"
  [ ! -f "$receipt" ] || { printf 'already-delivered %s\n' "$id"; return 0; }
  if [ -f "$failed" ]; then
    classification=$(jq -r '.classification // "ambiguous"' "$failed")
  elif [ -f "$posting" ]; then
    # A process may have exited after writing the pre-send marker but before it
    # could persist either a receipt or a failure. Treat that durable gap as an
    # ambiguous delivery, never as a safe automatic retry.
    classification=ambiguous
  else
    die "no failed delivery to retry: $id"
  fi
  case "$classification" in
    transient) ;;
    permanent) [ "$force" -eq 1 ] || die "permanent failure requires retry --force" ;;
    ambiguous) [ "$confirm" -eq 1 ] || die "ambiguous delivery requires retry --confirm-ambiguous" ;;
    *) die "invalid failure classification: $classification" ;;
  esac
  acquire_delivery_lock "$id"
  rm -f -- "$failed" "$posting"
  release_delivery_lock "$id"
  deliver_one "$id"
}

status_one() {
  local id=$1 result receipt failed posting state status summary classification
  result=$(result_path "$id")
  receipt=$(receipt_path "$id")
  failed=$(failed_path "$id")
  posting=$(posting_path "$id")
  validate_result_envelope "$result" "$id"
  validate_owned_file_or_absent "$receipt" "delivery receipt"
  validate_owned_file_or_absent "$failed" "delivery failure"
  validate_owned_file_or_absent "$posting" "posting marker"
  validate_receipt_envelope "$receipt" "$id"
  validate_failure_envelope "$failed" "$id"
  if [ -f "$receipt" ]; then
    state=delivered
  elif [ -f "$failed" ]; then
    classification=$(jq -r '.classification // "failed"' "$failed")
    [ "$classification" = ambiguous ] && state=ambiguous || state=failed
  elif [ -f "$posting" ]; then
    state=ambiguous
  else
    state=pending
  fi
  status=$(jq -r '.status' "$result")
  summary=$(jq -r '.summary | split("\n")[0]' "$result")
  printf '%s\t%s\t%s\t%s\n' "$id" "$state" "$status" "$summary"
}

status_command() {
  local path id found=0
  require_jq
  validate_result_dir
  if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = --note-id ] || usage
    fm_inbox_valid_note_id "$2" || die "invalid note id"
    status_one "$2"
    return
  fi
  [ -d "$RESULT_DIR" ] || { printf '(no inbox results)\n'; return; }
  for path in "$RESULT_DIR"/*.result.json; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] || die "invalid result record: ${path##*/}"
    found=1
    id=${path##*/}
    id=${id%.result.json}
    status_one "$id"
  done
  [ "$found" -eq 1 ] || printf '(no inbox results)\n'
}

case "${1:-}" in
  publish) shift; publish_command "$@" ;;
  deliver) shift; deliver_command "$@" ;;
  retry) shift; retry_command "$@" ;;
  status) shift; status_command "$@" ;;
  *) usage ;;
esac
