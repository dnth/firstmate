#!/usr/bin/env bash
# Trusted-local, durable notes for the Firstmate orchestrator.
# The note is the doorbell; a referenced file should contain the full brief.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$BIN_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-inbox-result-lib.sh
. "$BIN_DIR/fm-inbox-result-lib.sh"

INBOX_DIR="$STATE/inbox"
HANDLED_DIR="$INBOX_DIR/handled"

# The note is the doorbell, not the brief: messages stay bounded and the full
# handoff lives in the file the note references.
FM_INBOX_NOTE_MAX_BYTES=4096

usage() {
  cat >&2 <<'EOF'
usage: fm-inbox.sh note [--reply-target <hermes:platform:chat[:thread]> --correlation-id <id>] <message>
       fm-inbox.sh list
       fm-inbox.sh drain [--ack <id>]
       fm-inbox.sh status
EOF
  exit 2
}

die() {
  printf 'fm-inbox: %s\n' "$*" >&2
  exit 1
}

ensure_inbox_dirs() {
  if [ -L "$INBOX_DIR" ] || [ -L "$HANDLED_DIR" ]; then
    die "inbox paths must not be symlinks"
  fi
  mkdir -p "$INBOX_DIR" "$HANDLED_DIR"
  chmod 0700 "$INBOX_DIR" "$HANDLED_DIR"
}

valid_note_id() {
  fm_inbox_valid_note_id "$1"
}

validate_note_dir() {
  local dir=$1
  [ ! -L "$dir" ] || die "inbox path must not be a symlink: ${dir##*/}"
  [ ! -e "$dir" ] || [ -d "$dir" ] || die "inbox path must be a directory: ${dir##*/}"
}

count_note_files() {
  local dir=$1 note count=0
  validate_note_dir "$dir"
  [ -d "$dir" ] || { printf '0\n'; return; }
  for note in "$dir"/*.note; do
    [ -e "$note" ] || [ -L "$note" ] || continue
    [ -f "$note" ] && [ ! -L "$note" ] || die "invalid note: ${note##*/}"
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

validate_inbox_dir() {
  validate_note_dir "$INBOX_DIR"
}

note_command() {
  local reply_target='' correlation_id='' message tmp suffix id note created metadata=0 candidate_target candidate_correlation
  if [ "$#" -ge 4 ]; then
    if { [ "$1" = --reply-target ] && [ "$3" = --correlation-id ]; } \
        || { [ "$1" = --correlation-id ] && [ "$3" = --reply-target ]; }; then
      if [ "$1" = --reply-target ]; then
        candidate_target=$2
        candidate_correlation=$4
      else
        candidate_correlation=$2
        candidate_target=$4
      fi
      if fm_inbox_valid_reply_target "$candidate_target" \
          && fm_inbox_valid_correlation_id "$candidate_correlation" \
          && fm_inbox_reply_target_authorized "$candidate_target"; then
        metadata=1
      fi
    fi
  fi
  if [ "$metadata" -eq 1 ]; then
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reply-target) reply_target=$2; shift 2 ;;
        --correlation-id) correlation_id=$2; shift 2 ;;
        *) break ;;
      esac
    done
  elif [ "${1:-}" = -- ]; then
    shift
  fi
  message=$*
  [ -n "$message" ] || usage
  # The note is the doorbell, not the brief: a bounded message keeps the
  # durable queue and its presentation cheap, and anything longer belongs in
  # the referenced file the note points at.
  [ "$(printf '%s' "$message" | wc -c | tr -d ' ')" -le "$FM_INBOX_NOTE_MAX_BYTES" ] \
    || die "note message exceeds $FM_INBOX_NOTE_MAX_BYTES bytes; put the full brief in a file and note its path"
  if [ -n "$reply_target" ] || [ -n "$correlation_id" ]; then
    [ -n "$reply_target" ] && [ -n "$correlation_id" ] \
      || die "reply target and correlation id must be provided together"
    fm_inbox_valid_reply_target "$reply_target" || die "invalid reply target"
    fm_inbox_valid_correlation_id "$correlation_id" || die "invalid correlation id"
    fm_inbox_reply_target_authorized "$reply_target" \
      || die "reply target is not authorized"
    command -v jq >/dev/null 2>&1 || die "jq is required for reply metadata"
  fi
  ensure_inbox_dirs
  tmp=$(mktemp "$INBOX_DIR/.incoming.XXXXXX") || die "cannot create note"
  suffix=${tmp##*.incoming.}
  id="$(date +%s)-$$-$suffix"
  note="$INBOX_DIR/$id.note"
  if [ -n "$reply_target" ]; then
    created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if ! jq -n --arg id "$id" --arg correlation "$correlation_id" \
        --arg target "$reply_target" --arg message "$message" --arg created "$created" \
        '{schema:"firstmate.inbox-note.v1", note_id:$id,
          request_note_id:$id, correlation_id:$correlation,
          reply_target:$target, message:$message, created_at:$created}' > "$tmp"; then
      rm -f -- "$tmp"
      die "cannot encode note"
    fi
  elif ! printf '%s\n' "$message" > "$tmp"; then
    rm -f -- "$tmp"
    die "cannot encode note"
  fi
  elif ! printf '%s\n' "$message" > "$tmp"; then
    rm -f -- "$tmp"
    die "cannot encode note"
  fi
  if ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    die "cannot persist note"
  fi
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || {
    rm -f -- "$tmp"
    die "cannot lock wake queue"
  }
  if ! mv "$tmp" "$note"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    rm -f -- "$tmp"
    die "cannot persist note"
  fi
  if ! fm_wake_append_locked check "inbox-$id" \
    "captain inbox note $id: run bin/fm-inbox.sh drain; acknowledge after handling with bin/fm-inbox.sh drain --ack $id"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    die "note $id persisted, but wake append failed"
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  printf 'noted %s\n' "$id"
}

list_command() {
  local note id first found=0
  validate_inbox_dir
  [ -d "$INBOX_DIR" ] || { printf '(inbox empty)\n'; return; }
  for note in "$INBOX_DIR"/*.note; do
    [ -e "$note" ] || [ -L "$note" ] || continue
    [ -f "$note" ] && [ ! -L "$note" ] || die "invalid pending note: ${note##*/}"
    found=1
    id=${note##*/}
    id=${id%.note}
    first=
    if fm_inbox_note_is_structured "$note"; then
      fm_inbox_validate_note_envelope "$note" "$id" \
        || die "invalid pending note: ${note##*/}"
      first=$(jq -r '.message | split("\n")[0]' "$note") \
        || die "cannot read note: $id"
    else
      IFS= read -r first < "$note" || true
    fi
    printf '%s\t%s\n' "$id" "$first"
  done
  [ "$found" -eq 1 ] || printf '(inbox empty)\n'
}

drain_command() {
  local note id found=0
  if [ "${1:-}" = --ack ]; then
    [ "$#" -eq 2 ] || usage
    id=$2
    valid_note_id "$id" || die "invalid note id"
    ensure_inbox_dirs
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || die "cannot lock wake queue"
    note="$INBOX_DIR/$id.note"
    if [ -L "$note" ]; then
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      die "note must not be a symlink: $id"
    fi
    if [ -f "$note" ]; then
      if fm_inbox_note_is_structured "$note"; then
        fm_inbox_validate_note_envelope "$note" "$id" \
          || die "invalid pending note: ${note##*/}"
      fi
      [ ! -e "$HANDLED_DIR/$id.note" ] && [ ! -L "$HANDLED_DIR/$id.note" ] \
        || { fm_lock_release "$FM_WAKE_QUEUE_LOCK"; die "handled note already exists: $id"; }
      if mv "$note" "$HANDLED_DIR/$id.note"; then
        if ! fm_wake_consume_key_locked check "inbox-$id" >/dev/null; then
          fm_lock_release "$FM_WAKE_QUEUE_LOCK"
          die "note $id handled, but its wake row could not be consumed; re-run drain --ack $id"
        fi
        fm_lock_release "$FM_WAKE_QUEUE_LOCK"
        printf 'acked %s\n' "$id"
        return 0
      fi
    fi
    if [ -f "$HANDLED_DIR/$id.note" ] && [ ! -L "$HANDLED_DIR/$id.note" ]; then
      if ! fm_wake_consume_key_locked check "inbox-$id" >/dev/null; then
        fm_lock_release "$FM_WAKE_QUEUE_LOCK"
        die "note $id is handled, but its wake row could not be consumed; re-run drain --ack $id"
      fi
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      printf 'already-acked %s\n' "$id"
      return 0
    fi
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    die "note not found: $id"
  fi
  [ "$#" -eq 0 ] || usage
  validate_inbox_dir
  [ -d "$INBOX_DIR" ] || { printf '(inbox empty)\n'; return; }
  for note in "$INBOX_DIR"/*.note; do
    [ -e "$note" ] || [ -L "$note" ] || continue
    [ -f "$note" ] && [ ! -L "$note" ] || die "invalid pending note: ${note##*/}"
    found=1
    id=${note##*/}
    id=${id%.note}
    printf '%s\n' "--- $id ---"
    if fm_inbox_note_is_structured "$note"; then
      fm_inbox_validate_note_envelope "$note" "$id" \
        || die "invalid pending note: ${note##*/}"
      printf 'correlation: %s\n' "$(jq -r '.correlation_id' "$note")"
      printf 'reply-target: %s\n' "$(jq -r '.reply_target' "$note")"
      jq -r '.message' "$note"
    else
      cat "$note"
    fi
  done
  [ "$found" -eq 1 ] || printf '(inbox empty)\n'
}

status_command() {
  local pending handled wakes=0
  pending=$(count_note_files "$INBOX_DIR")
  handled=$(count_note_files "$HANDLED_DIR")
  [ ! -L "$FM_WAKE_QUEUE" ] || die "wake queue must not be a symlink"
  [ ! -e "$FM_WAKE_QUEUE" ] || [ -f "$FM_WAKE_QUEUE" ] || die "wake queue must be a regular file"
  if [ -f "$FM_WAKE_QUEUE" ]; then
    wakes=$(awk 'END { print NR + 0 }' "$FM_WAKE_QUEUE")
  fi
  printf 'inbox pending: %s\n' "$pending"
  printf 'inbox handled: %s\n' "$handled"
  printf 'wake queued: %s\n' "$wakes"
}

case "${1:-}" in
  note)
    shift
    note_command "$@"
    ;;
  list)
    [ "$#" -eq 1 ] || usage
    list_command
    ;;
  drain)
    shift
    drain_command "$@"
    ;;
  status)
    [ "$#" -eq 1 ] || usage
    status_command
    ;;
  *)
    usage
    ;;
esac
