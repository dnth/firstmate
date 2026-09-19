#!/usr/bin/env bash
# Trusted-local, durable notes for the Firstmate orchestrator.
# The note is the doorbell; a referenced file should contain the full brief.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$BIN_DIR/fm-wake-lib.sh"

INBOX_DIR="$STATE/inbox"
HANDLED_DIR="$INBOX_DIR/handled"

# The note is the doorbell, not the brief: messages stay bounded and the full
# handoff lives in the file the note references.
FM_INBOX_NOTE_MAX_BYTES=4096

usage() {
  cat >&2 <<'EOF'
usage: fm-inbox.sh note <message>
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
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
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
  local message=$* tmp suffix id note
  [ -n "$message" ] || usage
  # The note is the doorbell, not the brief: a bounded message keeps the
  # durable queue and its presentation cheap, and anything longer belongs in
  # the referenced file the note points at.
  [ "$(printf '%s' "$message" | wc -c | tr -d ' ')" -le "$FM_INBOX_NOTE_MAX_BYTES" ] \
    || die "note message exceeds $FM_INBOX_NOTE_MAX_BYTES bytes; put the full brief in a file and note its path"
  ensure_inbox_dirs
  tmp=$(mktemp "$INBOX_DIR/.incoming.XXXXXX") || die "cannot create note"
  suffix=${tmp##*.incoming.}
  id="$(date +%s)-$$-$suffix"
  note="$INBOX_DIR/$id.note"
  if ! printf '%s\n' "$message" > "$tmp" || ! chmod 0600 "$tmp" || ! mv "$tmp" "$note"; then
    rm -f -- "$tmp"
    die "cannot persist note"
  fi
  if ! fm_wake_append check "inbox-$id" \
    "captain inbox note $id: run bin/fm-inbox.sh drain; acknowledge after handling with bin/fm-inbox.sh drain --ack $id"; then
    die "note $id persisted, but wake append failed"
  fi
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
    IFS= read -r first < "$note" || true
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
    note="$INBOX_DIR/$id.note"
    if [ -L "$note" ]; then
      die "note must not be a symlink: $id"
    fi
    if [ -f "$note" ]; then
      [ ! -e "$HANDLED_DIR/$id.note" ] && [ ! -L "$HANDLED_DIR/$id.note" ] \
        || die "handled note already exists: $id"
      if mv "$note" "$HANDLED_DIR/$id.note"; then
        # Atomic reconciliation: acknowledgement IS the handling of this
        # note's wake, so its queue rows retire here rather than replaying
        # until a separate fm-wake-drain --ack-through.
        fm_wake_consume_key check "inbox-$id" >/dev/null \
          || die "note $id handled, but its wake row could not be consumed; re-run drain --ack $id"
        printf 'acked %s\n' "$id"
        return 0
      fi
    fi
    if [ -f "$HANDLED_DIR/$id.note" ] && [ ! -L "$HANDLED_DIR/$id.note" ]; then
      # A note handled before atomic reconciliation (or left behind by a
      # failed consume) still retires its wake row here.
      fm_wake_consume_key check "inbox-$id" >/dev/null \
        || die "note $id is handled, but its wake row could not be consumed; re-run drain --ack $id"
      printf 'already-acked %s\n' "$id"
      return 0
    fi
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
    cat "$note"
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
