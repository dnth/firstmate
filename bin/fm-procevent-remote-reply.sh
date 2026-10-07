#!/usr/bin/env bash
# Remote-secondmate reply adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-remote-reply.sh arm <secondmate-id>
#   fm-procevent-remote-reply.sh arm-locked <secondmate-id>
#   fm-procevent-remote-reply.sh ensure-armed
#   fm-procevent-remote-reply.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-remote-reply.sh handled-gate <source-id> <sequence> <result-file>
#   fm-procevent-remote-reply.sh handle <secondmate-id> <sequence> <result-file>
#   fm-procevent-remote-reply.sh ingest <secondmate-id> <result-file>
#   fm-procevent-remote-reply.sh classify <result-file>
#   fm-procevent-remote-reply.sh terminal <result-file>
#   fm-procevent-remote-reply.sh source <secondmate-id>
#   fm-procevent-remote-reply.sh source-id <secondmate-id>
#   fm-procevent-remote-reply.sh retire <secondmate-id> [--force]
#   fm-procevent-remote-reply.sh retire-quiesce-locked <secondmate-id> [--force]
#   fm-procevent-remote-reply.sh retire-finalize-locked <secondmate-id> [--force]
#
# `arm` registers one blocking, non-destructive, cursor-anchored delta source
# for the remote home's state/parent-replies.status log, converging on the
# invariant that a live non-dormant remote route has either an armed source or
# an unhandled capture - never both and never neither. The process-event runner
# owns blocking, capture, publication, and one machine-wide source owner. Its
# `autohandle` seam runs right after every capture and again on every reconcile,
# so each captured delta is ingested, acknowledged, and re-armed without waiting
# for an agent turn; `ensure-armed` repairs a live route that lost its
# registration in the same watcher cycle, with no SSH.
#
# Each captured delta is terminal for that exact registration; `handle` ingests
# it, re-arms the next cursor-anchored source, then acknowledges the captured
# generation. A shortened or changed log prefix is a continuity break: it stops
# the relay, records a durable continuity pin
# (state/remote-replies/<id>.continuity-broken names the sequence, reason, and
# cursor position), and is surfaced once - the route stays pinned until an
# operator rebases the cursor, which deletes the marker.
#
# Ingest validates each payload line independently: malformed UTF-8, controls
# other than TAB, invisible or reordering format characters, Unicode line and
# paragraph separators, over-long lines, and non-lifecycle shapes are each
# rejected. Rejected bytes never reach the status channel - they are kept
# byte-exact under state/remote-replies/<id>.quarantine/ and reported once with
# a parent-authored `blocked` line naming the reason, byte count, and SHA-256 -
# while the cursor still advances past them. Accepted lines need no correlation
# token for autonomous lifecycle reports, but only an explicit exact
# correlation token resolves a matching pending parent request. A data/*.md
# pointer is fetched through the path-confined remote file reader and rewritten
# to its local private copy before append; a failed fetch fails the handle so
# autohandle retries it rather than acknowledging a half-ingested delta. Exact
# lines are appended at most once to the parent's state/<id>.status.
#
# An accepted `done` line that reports `PR <url>`, and the mate's custody line,
# also reach bin/fm-landing.sh, which files a main-owned landing record so the
# merge stays tracked while the remote mate sleeps; a failed registration fails
# the handle like a failed document fetch.
#
# `handled-gate` is the generic runner's acknowledgement gate: a remote-reply
# generation may be marked handled only after its ingest receipt exists, the
# cursor covers its range, or its continuity break is recorded - a never-ingested
# capture is refused, while a cursor-covered stale duplicate stays
# acknowledgeable. `autohandle` takes the reply lifecycle lock without waiting
# (a busy lock means a teardown, sleep, or another handler owns the route this
# cycle and is not a failure), runs `handle`, and counts consecutive failures
# per sequence under state/remote-replies/<id>.<seq>.autohandle-failures; at
# FM_REMOTE_REPLY_AUTOHANDLE_FAILURE_LIMIT (default 3) it appends one named
# `blocked` line and keeps retrying rather than dropping the generation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CURSOR_DIR="$STATE/remote-replies"
REMOTE_LOG='state/parent-replies.status'
WAIT_SECONDS=${FM_REMOTE_REPLY_WAIT_SECONDS:-55}
MAX_LINE_BYTES=${FM_REMOTE_REPLY_MAX_LINE_BYTES:-2048}
MAX_DOC_BYTES=${FM_REMOTE_REPLY_MAX_DOC_BYTES:-262144}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-compute-lib.sh
. "$SCRIPT_DIR/fm-compute-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,71p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "no SHA-256 tool is available"
  fi
}

empty_hash() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-empty-hash.XXXXXX") || return 1
  : > "$tmp"
  sha256_file "$tmp"
  rm -f -- "$tmp"
}

validate_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $1" ;; esac
}

source_id() {
  validate_id "$1"
  printf 'remote-reply-%s\n' "$1"
}

cursor_path() { printf '%s/%s.cursor\n' "$CURSOR_DIR" "$1"; }
ingest_receipt_path() { printf '%s/%s.%s.ingested\n' "$CURSOR_DIR" "$1" "$2"; }
quarantine_dir() { printf '%s/%s.quarantine\n' "$CURSOR_DIR" "$1"; }
continuity_marker_path() { printf '%s/%s.continuity-broken\n' "$CURSOR_DIR" "$1"; }
autohandle_failure_path() { printf '%s/%s.%s.autohandle-failures\n' "$CURSOR_DIR" "$1" "$2"; }

autohandle_failure_limit() {
  local limit=${FM_REMOTE_REPLY_AUTOHANDLE_FAILURE_LIMIT:-3}
  case "$limit" in ''|*[!0-9]*) die "FM_REMOTE_REPLY_AUTOHANDLE_FAILURE_LIMIT must be a positive integer" ;; esac
  [ "$limit" -gt 0 ] || die "FM_REMOTE_REPLY_AUTOHANDLE_FAILURE_LIMIT must be a positive integer"
  printf '%s\n' "$limit"
}

read_cursor() { # <id>; sets CURSOR_OFFSET and CURSOR_HASH
  local path=$1 offset hash schema
  path=$(cursor_path "$path")
  CURSOR_OFFSET=0
  CURSOR_HASH=$(empty_hash) || die "cannot establish the empty cursor hash"
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || die "reply cursor is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path")
  offset=$(sed -n 's/^offset=//p' "$path")
  hash=$(sed -n 's/^prefix_sha256=//p' "$path")
  [ "$schema" = fm-remote-reply-cursor.v1 ] || die "reply cursor has an incompatible schema: $path"
  case "$offset" in ''|*[!0-9]*) die "reply cursor has an invalid offset: $path" ;; esac
  case "$hash" in *[!A-Fa-f0-9]*|'') die "reply cursor has an invalid hash: $path" ;; esac
  [ "${#hash}" -eq 64 ] || die "reply cursor has an invalid hash length: $path"
  CURSOR_OFFSET=$offset
  CURSOR_HASH=$(printf '%s' "$hash" | tr 'A-F' 'a-f')
}

write_cursor() { # <id> <offset> <hash>
  local id=$1 offset=$2 hash=$3 path tmp
  mkdir -p "$CURSOR_DIR" || return 1
  chmod 700 "$CURSOR_DIR" 2>/dev/null || true
  path=$(cursor_path "$id")
  [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "$CURSOR_DIR/.cursor.XXXXXX") || return 1
  {
    printf 'schema=fm-remote-reply-cursor.v1\n'
    printf 'offset=%s\n' "$offset"
    printf 'prefix_sha256=%s\n' "$hash"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

ingest_receipt_matches() { # <id> <sequence> <result>
  local path stored actual count
  path=$(ingest_receipt_path "$1" "$2")
  [ -e "$path" ] || [ -L "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || die "remote reply ingestion receipt is unsafe: $path"
  count=$(grep -c '^result_sha256=' "$path" 2>/dev/null || true)
  [ "$count" -eq 1 ] || die "remote reply ingestion receipt is malformed: $path"
  stored=$(sed -n 's/^result_sha256=//p' "$path")
  case "$stored" in *[!A-Fa-f0-9]*|'') die "remote reply ingestion receipt is malformed: $path" ;; esac
  [ "${#stored}" -eq 64 ] || die "remote reply ingestion receipt is malformed: $path"
  actual=$(sha256_file "$3") || die "cannot hash remote reply result"
  [ "$stored" = "$actual" ] || die "remote reply generation conflicts with its ingestion receipt"
}

write_ingest_receipt() { # <id> <sequence> <result>
  local id=$1 seq=$2 result=$3 path tmp hash
  mkdir -p "$CURSOR_DIR" || return 1
  chmod 700 "$CURSOR_DIR" 2>/dev/null || true
  path=$(ingest_receipt_path "$id" "$seq")
  if [ -e "$path" ] || [ -L "$path" ]; then
    ingest_receipt_matches "$id" "$seq" "$result"
    return $?
  fi
  hash=$(sha256_file "$result") || return 1
  tmp=$(umask 077; mktemp "$CURSOR_DIR/.ingested.XXXXXX") || return 1
  printf 'result_sha256=%s\n' "$hash" > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

result_field() { # <result> <field>
  local count
  # -a because the result body may legally carry arbitrary payload bytes.
  count=$(grep -ac "^$2=" "$1" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  grep -a "^$2=" "$1" | cut -d= -f2-
}

classify_result() {
  local file=$1 schema status
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'malformed\n'; return 0; }
  schema=$(result_field "$file" schema 2>/dev/null || true)
  status=$(result_field "$file" status 2>/dev/null || true)
  [ "$schema" = fm-remote-delta.v1 ] || { printf 'malformed\n'; return 0; }
  case "$status" in
    delta) printf 'delta\n' ;;
    continuity-broken) printf 'continuity-broken\n' ;;
    *) printf 'malformed\n' ;;
  esac
}

remote_route_exists() {
  local id=$1 remote
  remote=$(secondmate_registry_field "$DATA/secondmates.md" "$id" remote 2>/dev/null || true)
  [ "$remote" = 1 ] || die "secondmate $id is not a configured remote route"
}

# Record a continuity break durably. The marker pins the route: `arm` refuses
# while the cursor still equals the recorded break point, and an operator
# rebases by moving the cursor, which deletes the marker on the next arm.
write_continuity_marker() {  # <id> <seq> <reason> <offset> <prefix-hash>
  local id=$1 seq=$2 reason=$3 offset=$4 hash=$5 path tmp
  path=$(continuity_marker_path "$id")
  mkdir -p "$CURSOR_DIR" || return 1
  chmod 700 "$CURSOR_DIR" 2>/dev/null || true
  [ ! -L "$path" ] || return 1
  tmp=$(umask 077; mktemp "$CURSOR_DIR/.continuity.XXXXXX") || return 1
  {
    printf 'seq=%s\n' "$seq"
    printf 'reason=%s\n' "$reason"
    printf 'offset=%s\n' "$offset"
    printf 'prefix_sha256=%s\n' "$hash"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

# The first unhandled captured generation for a source, if any. A secondmate's
# reply route may arm only while no capture waits for ingest - arming from the
# committed cursor while a prior capture is pending would produce a duplicate
# generation of the same bytes.
pending_capture_seq() {  # <source-id> [excluded-seq]
  local sid=$1 except=${2:-} inbox path base seq
  inbox="$STATE/procevent-inbox"
  [ -d "$inbox" ] && [ ! -L "$inbox" ] || return 1
  for path in "$inbox/$sid".*.result; do
    [ -e "$path" ] || continue
    base=${path%.result}
    seq=${base##*.}
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    [ "$seq" = "$except" ] && continue
    [ -e "$base.handled" ] && continue
    printf '%s\n' "$seq"
    return 0
  done
  return 1
}

cmd_arm_locked() {  # <id> [handling-seq]
  local id=${1:-} handling_seq=${2:-} sid marker pending_seq moffset mhash
  validate_id "$id"
  remote_route_exists "$id"
  sid=$(source_id "$id")
  # The source long-polls the remote log over SSH, so a scale-to-zero route in a
  # recognized no-host lifecycle state has nothing to poll and must never be
  # woken just to arm it. The cursor is untouched, so the next wake re-arms from
  # exactly this offset.
  if fm_compute_is_dormant "$DATA" "$id"; then
    printf 'skipped: %s suspended\n' "$sid"
    return 0
  fi
  # A continuity-broken route stays pinned at the recorded break point until an
  # operator rebases it; a cursor that no longer equals the marker's own offset
  # and hash is that rebase, so the pin clears and arming proceeds.
  marker=$(continuity_marker_path "$id")
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    moffset=$(sed -n 's/^offset=//p' "$marker" | head -1)
    mhash=$(sed -n 's/^prefix_sha256=//p' "$marker" | head -1)
    read_cursor "$id"
    if [ "$CURSOR_OFFSET" = "$moffset" ] && [ "$CURSOR_HASH" = "$mhash" ]; then
      printf 'skipped: %s continuity broken at sequence %s\n' \
        "$sid" "$(sed -n 's/^seq=//p' "$marker" | head -1)"
      return 0
    fi
    rm -f -- "$marker" || return 1
  fi
  # An unhandled capture already covers this route's invariant; arming a second
  # source from the same cursor would capture a duplicate generation. The
  # capture this adapter is currently handling is the one exception.
  if pending_seq=$(pending_capture_seq "$sid" "$handling_seq"); then
    printf 'skipped: %s capture pending (sequence %s)\n' "$sid" "$pending_seq"
    return 0
  fi
  read_cursor "$id"
  if [ -f "$STATE/procevent/$sid.source" ] && [ ! -L "$STATE/procevent/$sid.source" ]; then
    printf 'already-armed: %s offset=%s\n' "$sid" "$CURSOR_OFFSET"
    return 0
  fi
  "$SCRIPT_DIR/fm-procevent.sh" register remote-reply "$sid" -- \
    "$SCRIPT_DIR/fm-procevent-remote-reply.sh" source "$id" || return 1
  printf 'armed: %s offset=%s\n' "$sid" "$CURSOR_OFFSET"
}

cmd_arm() {
  local id=${1:-} lock
  validate_id "$id"
  lock=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock remote reply lifecycle for $id"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_arm_locked "$id"
  )
}

cmd_source() {
  local id=${1:-}
  validate_id "$id"
  read_cursor "$id"
  exec "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-delta-read.sh \
    "$REMOTE_LOG" "$CURSOR_OFFSET" "$CURSOR_HASH" "$WAIT_SECONDS" < /dev/null
}

safe_doc_path() {
  case "$1" in
    data/*.md) ;;
    *) return 1 ;;
  esac
  case "/$1/" in */../*|*/./*) return 1 ;; esac
  case "$1" in *'//'*) return 1 ;; esac
  return 0
}

fetch_document() { # <id> <remote-relative> <result-var>
  local id=$1 rel=$2 result_var=$3 base destination parent parent_real tmp local_rel
  safe_doc_path "$rel" || return 1
  base="$DATA/remote-secondmates/$id"
  destination="$base/$rel"
  parent=$(dirname "$destination")
  mkdir -p "$parent" || return 1
  [ ! -L "$base" ] && [ ! -L "$parent" ] || return 1
  parent_real=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P) || return 1
  case "$parent_real" in "$base"|"$base"/*) ;; *) return 1 ;; esac
  [ ! -L "$destination" ] || return 1
  tmp=$(umask 077; mktemp "$parent/.remote-doc.XXXXXX") || return 1
  if ! "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-file.sh get "$rel" "$MAX_DOC_BYTES" < /dev/null > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$destination" || { rm -f -- "$tmp"; return 1; }
  local_rel="data/remote-secondmates/$id/$rel"
  printf -v "$result_var" '%s' "$local_rel"
}

# Classify one payload line's rejection reason, or print nothing and exit 1
# when the line is acceptable. Reasons: invalid-utf8, forbidden-character,
# too-long, not-a-status-line. The byte count is measured BEFORE the strict
# UTF-8 decode, because Encode::decode consumes the byte scalar; the character
# classes match the old whole-payload rule (C0/C1 controls except TAB, DEL via
# \p{Cc}, format \p{Cf}, and Unicode line/paragraph separators \p{Zl} \p{Zp}).
line_reject_reason() {  # <line-file>
  perl -MEncode -e '
    local $/;
    my $bytes = <STDIN>;
    exit 1 if !defined $bytes || !length $bytes;
    my $blen = length($bytes);
    my $text = eval { Encode::decode("UTF-8", $bytes, Encode::FB_CROAK) };
    if ($@) { print "invalid-utf8\n"; exit 0; }
    $text =~ tr/\t//d;
    if ($text =~ /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/) { print "forbidden-character\n"; exit 0; }
    my $max = $ARGV[0];
    if ($blen > $max) { print "too-long\n"; exit 0; }
    exit 1;
  ' "$MAX_LINE_BYTES" < "$1"
}

# Split a payload byte-exactly into per-line files under $1/lines and write the
# ordered file list to $1/manifest. bash `read` drops NUL bytes, so it cannot be
# used to judge raw bytes; perl preserves them exactly.
split_payload_lines() {  # <payload> <out-dir>
  local payload=$1 out=$2
  mkdir -p "$out/lines" || return 1
  perl -e '
    my ($payload, $out) = @ARGV;
    open(my $in, "<", $payload) or exit 1;
    binmode($in);
    local $/;
    my $data = <$in>;
    close($in);
    $data = "" unless defined $data;
    my @lines = split(/\n/, $data, -1);
    pop @lines if @lines && $lines[-1] eq "";
    open(my $m, ">", "$out/manifest") or exit 1;
    binmode($m);
    my $i = 0;
    for my $line (@lines) {
      my $f = "$out/lines/$i.line";
      open(my $lf, ">", $f) or exit 1;
      binmode($lf);
      print $lf $line;
      close($lf);
      print $m "$f\n";
      $i++;
    }
    close($m);
  ' "$payload" "$out"
}

# Move a rejected line's exact bytes into the private quarantine and print the
# status-channel notice. The quarantine file carries the line bytes with no
# trailing newline, so the stored bytes equal the rejected bytes.
quarantine_line() {  # <id> <qseq> <index> <line-file>
  local id=$1 qseq=$2 index=$3 line_file=$4 dir dest tmp hash bytes
  dir=$(quarantine_dir "$id")
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  dest="$dir/$qseq.$index.line"
  hash=$(sha256_file "$line_file") || return 1
  bytes=$(LC_ALL=C wc -c < "$line_file" | tr -d ' ')
  tmp=$(umask 077; mktemp "$dir/.quarantine.XXXXXX") || return 1
  cat "$line_file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
  printf '%s %s\n' "$hash" "$bytes"
}

cmd_ingest() {
  local id=${1:-} result=${2:-} seq=${3:-} class blank payload schema status path from to from_hash to_hash payload_hash payload_bytes reason
  local actual_bytes actual_hash line doc local_doc rewritten appended=0 cursor_already=0 lock status_file tmp
  local qseq line_file line_reason qhash qbytes index
  validate_id "$id"
  [ -f "$result" ] && [ ! -L "$result" ] || die "result file is unavailable or unsafe: $result"
  class=$(classify_result "$result")
  [ "$class" != malformed ] || die "remote reply result is malformed"
  schema=$(result_field "$result" schema) || die "result schema is ambiguous"
  status=$(result_field "$result" status) || die "result status is ambiguous"
  path=$(result_field "$result" path) || die "result path is ambiguous"
  from=$(result_field "$result" from_offset) || die "result start offset is ambiguous"
  to=$(result_field "$result" to_offset) || die "result end offset is ambiguous"
  from_hash=$(result_field "$result" from_prefix_sha256) || die "result start hash is ambiguous"
  to_hash=$(result_field "$result" to_prefix_sha256) || die "result end hash is ambiguous"
  payload_hash=$(result_field "$result" payload_sha256) || die "result payload hash is ambiguous"
  payload_bytes=$(result_field "$result" payload_bytes) || die "result payload size is ambiguous"
  reason=$(result_field "$result" reason) || die "result reason is ambiguous"
  [ "$schema" = fm-remote-delta.v1 ] && [ "$path" = "$REMOTE_LOG" ] || die "result identifies the wrong source"
  case "$from$to$payload_bytes" in *[!0-9]*) die "result carries a nonnumeric size or offset" ;; esac
  for hash in "$from_hash" "$to_hash" "$payload_hash"; do
    case "$hash" in *[!A-Fa-f0-9]*|'') die "result carries an invalid SHA-256 value" ;; esac
    [ "${#hash}" -eq 64 ] || die "result carries an invalid SHA-256 length"
  done
  blank=$(grep -an -m 1 '^$' "$result" | cut -d: -f1)
  case "$blank" in ''|*[!0-9]*) die "result has no payload boundary" ;; esac
  # Quarantine objects and escalation keys name the captured generation; an
  # adhoc ingest has none, so it names the result's own digest instead.
  if [ -n "$seq" ]; then
    qseq=$seq
  else
    qseq="adhoc-$(sha256_file "$result" | cut -c1-12)" || die "cannot derive the adhoc quarantine key"
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-reply-ingest.XXXXXX") || die "cannot create ingest staging directory"
  trap 'rm -rf -- "$tmp"' EXIT
  payload="$tmp/payload"
  tail -n "+$((blank + 1))" "$result" > "$payload"
  actual_bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  actual_hash=$(sha256_file "$payload")
  [ "$actual_bytes" -eq "$payload_bytes" ] && [ "$actual_hash" = "$payload_hash" ] \
    || die "result payload bytes do not match its committed digest"
  status_file="$STATE/$id.status"
  mkdir -p "$STATE" || die "cannot create parent state directory"
  [ ! -L "$status_file" ] || die "parent status log is a symlink"
  lock="$STATE/.remote-reply-ingest-$id.lock"
  fm_lock_acquire_wait "$lock" || die "cannot lock remote reply ingest for $id"
  read_cursor "$id"
  if [ "$CURSOR_OFFSET" -eq "$to" ] && [ "$CURSOR_HASH" = "$to_hash" ]; then
    cursor_already=1
  elif [ "$CURSOR_OFFSET" -ne "$from" ] || [ "$CURSOR_HASH" != "$from_hash" ]; then
    die "result does not continue the current cursor for $id"
  fi
  if [ "$class" = continuity-broken ]; then
    # Pin the route at this break point until an operator rebases the cursor,
    # and dedupe on the break point itself: a replay of the same break (the
    # same committed cursor state) neither rewrites the marker nor re-escalates,
    # while a NEW break after a rebase records a new marker and escalates with
    # its own sequence.
    marker=$(continuity_marker_path "$id")
    if [ -f "$marker" ] && [ ! -L "$marker" ] \
      && [ "$(sed -n 's/^offset=//p' "$marker" | head -1)" = "$CURSOR_OFFSET" ] \
      && [ "$(sed -n 's/^prefix_sha256=//p' "$marker" | head -1)" = "$CURSOR_HASH" ]; then
      fm_lock_release "$lock"
      printf 'continuity-broken: %s (%s)\n' "$id" "$reason"
      return 3
    fi
    write_continuity_marker "$id" "$qseq" "$reason" "$CURSOR_OFFSET" "$CURSOR_HASH" \
      || { fm_lock_release "$lock"; die "cannot record the continuity break"; }
    line="blocked [key=remote-reply-continuity-$id]: remote reply continuity broke for $id at sequence $qseq ($reason)"
    if ! grep -Fqx -- "$line" "$status_file" 2>/dev/null; then
      printf '%s\n' "$line" >> "$status_file" || { fm_lock_release "$lock"; die "cannot append continuity escalation"; }
    fi
    fm_lock_release "$lock"
    printf 'continuity-broken: %s (%s)\n' "$id" "$reason"
    return 3
  fi
  [ "$status" = delta ] && [ "$payload_bytes" -gt 0 ] || { fm_lock_release "$lock"; die "delta result has no payload"; }
  # Each line is judged on its own bytes: a rejected line is quarantined
  # byte-exactly and reported once in line order, while accepted lines keep the
  # document rewrite and dedupe append. Zero-length lines are neither ingested
  # nor quarantined.
  split_payload_lines "$payload" "$tmp" || { fm_lock_release "$lock"; die "cannot split the delta payload into lines"; }
  index=1
  while IFS= read -r line_file; do
    [ -n "$line_file" ] || continue
    # Test the file's size, not the shell string: bash drops NUL bytes when
    # reading a line, so a line made only of NULs must reach quarantine as
    # forbidden bytes rather than reading as zero-length.
    if [ ! -s "$line_file" ]; then index=$((index + 1)); continue; fi
    line_reason=$(line_reject_reason "$line_file") && {
      read -r qhash qbytes < <(quarantine_line "$id" "$qseq" "$index" "$line_file") \
        || { fm_lock_release "$lock"; die "cannot quarantine a remote reply line"; }
      line="blocked [key=remote-reply-quarantine-$id-$qseq]: remote reply line rejected ($line_reason, sha256=$qhash, bytes=$qbytes)"
      if ! grep -Fqx -- "$line" "$status_file" 2>/dev/null; then
        printf '%s\n' "$line" >> "$status_file" || { fm_lock_release "$lock"; die "cannot append remote reply quarantine notice"; }
      fi
      index=$((index + 1))
      continue
    }
    # Read the shell string only after the byte-level checks passed.
    line=$(cat "$line_file")
    if ! printf '%s' "$line" | grep -Eq '^(working|needs-decision|blocked|paused|done|failed|resolved)([[:space:]]+(\[key=[^][:space:]:]*\]|\[corr=[^][:space:]:]*\]))*:'; then
      read -r qhash qbytes < <(quarantine_line "$id" "$qseq" "$index" "$line_file") \
        || { fm_lock_release "$lock"; die "cannot quarantine a remote reply line"; }
      line="blocked [key=remote-reply-quarantine-$id-$qseq]: remote reply line rejected (not-a-status-line, sha256=$qhash, bytes=$qbytes)"
      if ! grep -Fqx -- "$line" "$status_file" 2>/dev/null; then
        printf '%s\n' "$line" >> "$status_file" || { fm_lock_release "$lock"; die "cannot append remote reply quarantine notice"; }
      fi
      index=$((index + 1))
      continue
    fi
    printf '%s\n' "$line" >> "$tmp/accepted"
    rewritten=$line
    while IFS= read -r doc; do
      [ -n "$doc" ] || continue
      fetch_document "$id" "$doc" local_doc || { fm_lock_release "$lock"; die "could not fetch referenced remote document: $doc"; }
      rewritten=${rewritten//"$doc"/"$local_doc"}
    done < <(printf '%s\n' "$line" | grep -Eo 'data/[A-Za-z0-9._/-]+\.md' | awk '!seen[$0]++')
    if ! grep -Fqx -- "$rewritten" "$status_file" 2>/dev/null; then
      printf '%s\n' "$rewritten" >> "$status_file" || { fm_lock_release "$lock"; die "cannot append remote reply"; }
      appended=$((appended + 1))
    fi
    index=$((index + 1))
  done < "$tmp/manifest"
  # A mate's PR-ready report gets a main-owned landing record, and its custody
  # report records what the merge guards need, so the merge stays tracked while the
  # mate sleeps. A failure fails the handle, like a failed document fetch, so
  # autohandle retries instead of acknowledging an untracked PR.
  if [ -f "$tmp/accepted" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      "$SCRIPT_DIR/fm-landing.sh" ingest "$id" "$line" >/dev/null \
        || { fm_lock_release "$lock"; die "could not record a landing for: $line"; }
    done < "$tmp/accepted"
  fi
  # Only accepted lines may resolve a pending parent request: a rejected line's
  # correlation token is never trusted.
  while IFS= read -r corr; do
    [ -n "$corr" ] || continue
    fm_pending_reply_try_resolve "$STATE" "$corr" "$status_file" >/dev/null 2>&1 || true
  done < <(
    if [ -f "$tmp/accepted" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        fm_pending_reply_extract_status_corrs "$line"
      done < "$tmp/accepted"
    fi | awk '!seen[$0]++'
  )
  if [ -n "$seq" ]; then
    write_ingest_receipt "$id" "$seq" "$result" \
      || { fm_lock_release "$lock"; die "cannot commit remote reply ingestion receipt"; }
  fi
  if [ "$cursor_already" -eq 0 ]; then
    write_cursor "$id" "$to" "$to_hash" || { fm_lock_release "$lock"; die "cannot commit remote reply cursor"; }
  fi
  fm_lock_release "$lock"
  trap - EXIT
  rm -rf -- "$tmp"
  printf 'ingested: %s appended=%s offset=%s\n' "$id" "$appended" "$to"
}

cmd_handle_locked() {
  local id=${1:-} seq=${2:-} result=${3:-} sid class rc=0 to bfrom bfrom_hash
  validate_id "$id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  sid=$(source_id "$id")
  class=$(classify_result "$result")
  [ "$class" != malformed ] || die "remote reply result is malformed"
  if ingest_receipt_matches "$id" "$seq" "$result"; then
    to=$(result_field "$result" to_offset) || die "result end offset is ambiguous"
    printf 'ingested: %s appended=0 offset=%s\n' "$id" "$to"
  else
    # Stale generations are skipped rather than ingested or refused: a delta
    # whose whole range the committed cursor already passed (the to_offset ==
    # cursor same-hash case stays inside cmd_ingest's cursor_already path), or
    # a continuity break recorded for a cursor state an operator already
    # rebased away from, which must not re-escalate.
    read_cursor "$id"
    to=$(result_field "$result" to_offset) || die "result end offset is ambiguous"
    case "$to" in ''|*[!0-9]*) die "result carries a nonnumeric size or offset" ;; esac
    if [ "$class" = delta ] && [ "$to" -lt "$CURSOR_OFFSET" ]; then
      printf 'superseded: %s seq=%s offset=%s\n' "$id" "$seq" "$CURSOR_OFFSET"
    elif [ "$class" = continuity-broken ]; then
      bfrom=$(result_field "$result" from_offset) || die "result start offset is ambiguous"
      bfrom_hash=$(result_field "$result" from_prefix_sha256) || die "result start hash is ambiguous"
      if [ "$bfrom" = "$CURSOR_OFFSET" ] && [ "$bfrom_hash" = "$CURSOR_HASH" ]; then
        cmd_ingest "$id" "$result" "$seq" || rc=$?
      else
        printf 'superseded: %s seq=%s offset=%s\n' "$id" "$seq" "$CURSOR_OFFSET"
      fi
    else
      cmd_ingest "$id" "$result" "$seq" || rc=$?
    fi
  fi
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    return "$rc"
  fi
  fm_pending_reply_reconcile_task "$STATE" "$id" "$STATE/$id.status" >/dev/null 2>&1 || true
  if [ "$class" = delta ]; then
    cmd_arm_locked "$id" "$seq" || return 1
  fi
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" || return 1
  rm -f -- "$(autohandle_failure_path "$id" "$seq")"
  return "$rc"
}

cmd_handle() {
  local id=${1:-} lock
  validate_id "$id"
  lock=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock remote reply lifecycle for $id"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_handle_locked "$@"
  )
}

retirement_capture_scan() {
  local id=$1 sid inbox path base seq pending=0
  sid=$(source_id "$id")
  inbox="$STATE/procevent-inbox"
  [ -e "$inbox" ] || return 1
  [ -d "$inbox" ] && [ ! -L "$inbox" ] || die "remote reply inbox is unsafe"
  for path in "$inbox/$sid".*.result "$inbox/$sid".*.adapter "$inbox/$sid".*.handled; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] || die "remote reply capture is unsafe: $path"
  done
  for path in "$inbox/$sid".*.result; do
    [ -e "$path" ] || continue
    base=${path%.result}
    seq=${base##*.}
    case "$seq" in ''|*[!0-9]*) die "remote reply capture has an invalid generation: $path" ;; esac
    [ -f "$base.adapter" ] && [ ! -L "$base.adapter" ] \
      || die "remote reply capture has no safe adapter record: $path"
    [ -e "$base.handled" ] || pending=$((pending + 1))
  done
  RETIREMENT_PENDING=$pending
  RETIREMENT_INBOX=$inbox
  return 0
}

cmd_retire_quiesce_locked() {
  local id=${1:-} force=${2:-} sid
  validate_id "$id"
  [ -z "$force" ] || [ "$force" = --force ] || die "invalid retirement option: $force"
  sid=$(source_id "$id")
  "$SCRIPT_DIR/fm-procevent.sh" retire "$sid" || return 1
  RETIREMENT_PENDING=0
  retirement_capture_scan "$id" || true
  if [ "$force" != --force ] && [ "$RETIREMENT_PENDING" -gt 0 ]; then
    die "remote reply retirement refused with $RETIREMENT_PENDING unhandled captured result(s)"
  fi
}

cmd_retire_finalize_locked() {
  local id=${1:-} force=${2:-} sid path
  validate_id "$id"
  [ -z "$force" ] || [ "$force" = --force ] || die "invalid retirement option: $force"
  sid=$(source_id "$id")
  RETIREMENT_PENDING=0
  if retirement_capture_scan "$id"; then
    if [ "$force" != --force ] && [ "$RETIREMENT_PENDING" -gt 0 ]; then
      die "remote reply retirement refused with $RETIREMENT_PENDING unhandled captured result(s)"
    fi
    if [ "$force" = --force ]; then
      for path in "$RETIREMENT_INBOX/$sid".*.result "$RETIREMENT_INBOX/$sid".*.adapter "$RETIREMENT_INBOX/$sid".*.handled; do
        [ -e "$path" ] || continue
        rm -f -- "$path" || die "cannot discard remote reply capture: $path"
      done
    fi
  fi
  rm -f -- "$(cursor_path "$id")"
  rm -f -- "$CURSOR_DIR/$id".*.ingested
}

cmd_retire() {
  local id=${1:-} force=${2:-} lock
  validate_id "$id"
  lock=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock remote reply lifecycle for $id"
    trap 'fm_lock_release "$lock"' EXIT
    cmd_retire_quiesce_locked "$id" "$force" || return 1
    cmd_retire_finalize_locked "$id" "$force"
  )
}

# The generic runner's autohandle seam: handle one captured delta with no
# agent turn. A busy lifecycle lock (a teardown, a RunPod sleep, or another
# handler owns it this cycle) exits 75 without counting a failure - the result
# stays pending for the next reconcile. Real failures count up under
# state/remote-replies/<id>.<seq>.autohandle-failures, and the counter's
# reaching FM_REMOTE_REPLY_AUTOHANDLE_FAILURE_LIMIT appends exactly one named
# blocked line; later retries continue and never give up on the generation.
cmd_autohandle() {
  local source=${1:-} seq=${2:-} result=${3:-} id lock out rc=0 count limit status_file line reason
  id=${source#remote-reply-}
  [ "$source" = "remote-reply-$id" ] || die "invalid remote reply source id: $source"
  validate_id "$id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  lock=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
  out=$(
    fm_lock_try_acquire "$lock" || exit 75
    trap 'fm_lock_release "$lock"' EXIT
    cmd_handle_locked "$id" "$seq" "$result" 2>&1
  ) || rc=$?
  # A busy lifecycle lock defers to the next cycle; it is not a handling
  # failure and never counts toward the escalation limit.
  if [ "$rc" -eq 75 ]; then
    return 75
  fi
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
    return 0
  fi
  reason=$(printf '%s\n' "$out" | sed -n 's/^error: //p' | head -1)
  reason=$(printf '%s' "$reason" | tr -cd '[:print:]' | cut -c1-200)
  [ -n "$reason" ] || reason="handle exited $rc"
  count=$(autohandle_failure_record "$id" "$seq" "$reason") || return 1
  limit=$(autohandle_failure_limit)
  if [ "$count" -eq "$limit" ]; then
    status_file="$STATE/$id.status"
    line="blocked [key=remote-reply-autohandle-$id-$seq]: remote reply sequence $seq for $id failed automatic handling $limit consecutive times ($reason)"
    if ! grep -Fqx -- "$line" "$status_file" 2>/dev/null; then
      mkdir -p "$STATE" 2>/dev/null || true
      printf '%s\n' "$line" >> "$status_file" 2>/dev/null || true
    fi
  fi
  return 1
}

# Append or bump the per-sequence autohandle failure counter (mode 600) and
# print the new count.
autohandle_failure_record() {  # <id> <seq> <reason>
  local id=$1 seq=$2 reason=$3 path count=0 tmp
  path=$(autohandle_failure_path "$id" "$seq")
  [ ! -L "$path" ] || return 1
  mkdir -p "$CURSOR_DIR" || return 1
  chmod 700 "$CURSOR_DIR" 2>/dev/null || true
  if [ -f "$path" ]; then
    count=$(sed -n 's/^count=//p' "$path" | head -1)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
  fi
  count=$((count + 1))
  tmp=$(umask 077; mktemp "$CURSOR_DIR/.autohandle-failures.XXXXXX") || return 1
  {
    printf 'count=%s\n' "$count"
    printf 'reason=%s\n' "$reason"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$count"
}

# The generic runner's handled-gate: allow a NEW acknowledgement only when the
# generation was durably dealt with - an ingest receipt matching this exact
# result, a cursor already covering the result's range, or a recorded
# continuity break naming this sequence. Anything else refuses so a captured
# delta cannot be marked handled before it was ingested.
cmd_handled_gate() {
  local source=${1:-} seq=${2:-} result=${3:-} id class to marker mseq
  id=${source#remote-reply-}
  [ "$source" = "remote-reply-$id" ] || die "invalid remote reply source id: $source"
  validate_id "$id"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer" ;; esac
  if ingest_receipt_matches "$id" "$seq" "$result" 2>/dev/null; then
    return 0
  fi
  class=$(classify_result "$result")
  read_cursor "$id"
  to=$(result_field "$result" to_offset 2>/dev/null || true)
  case "$to" in ''|*[!0-9]*) to=-1 ;; esac
  if [ "$class" = delta ] && [ "$to" -ge 0 ] \
    && { [ "$to" -lt "$CURSOR_OFFSET" ] \
      || { [ "$to" -eq "$CURSOR_OFFSET" ] \
        && [ "$(result_field "$result" to_prefix_sha256 2>/dev/null || true)" = "$CURSOR_HASH" ]; }; }; then
    return 0
  fi
  if [ "$class" = continuity-broken ]; then
    # A break recorded by its marker names this sequence, and a break whose
    # starting position no longer equals the cursor was superseded by an
    # operator rebase - it can never apply again, so it is acknowledgeable.
    local bfrom bfrom_hash
    bfrom=$(result_field "$result" from_offset 2>/dev/null || true)
    bfrom_hash=$(result_field "$result" from_prefix_sha256 2>/dev/null || true)
    if [ -n "$bfrom" ] && [ -n "$bfrom_hash" ] \
      && { [ "$bfrom" != "$CURSOR_OFFSET" ] || [ "$bfrom_hash" != "$CURSOR_HASH" ]; }; then
      return 0
    fi
    marker=$(continuity_marker_path "$id")
    if [ -f "$marker" ] && [ ! -L "$marker" ]; then
      mseq=$(sed -n 's/^seq=//p' "$marker" | head -1)
      [ "$mseq" = "$seq" ] && return 0
    fi
  fi
  printf 'error: remote reply sequence %s for %s has no ingest receipt; handle it with fm-procevent-remote-reply.sh handle %s %s %s\n' \
    "$seq" "$id" "$id" "$seq" "$result" >&2
  return 1
}

# Converge every live remote route onto the arming invariant without SSH: each
# route whose lifecycle lock is free this cycle gets the same ordered checks as
# `arm`. A route whose lock is held (teardown, a RunPod sleep, or a handler) is
# skipped this cycle and converged later.
cmd_ensure_armed() {
  local meta id _home _window remote_host lock out rc=0
  while IFS='|' read -r id _home _window meta; do
    [ -n "$id" ] || continue
    remote_host=$(grep '^remote_host=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "$remote_host" ] || continue
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    lock=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
    if ! fm_lock_try_acquire "$lock"; then
      continue
    fi
    out=$(cmd_arm_locked "$id" 2>&1) || rc=1
    printf '%s\n' "$out"
    fm_lock_release "$lock"
  done < <(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")
  return "$rc"
}

require_parent_lifecycle_lock() {
  local id=$1 lock owner pid
  lock=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
  if [ -L "$lock" ]; then
    owner=$(fm_lock_link_owner "$lock" 2>/dev/null || true)
    [ -n "$owner" ] || die "remote reply lifecycle lock ownership is invalid"
  else
    owner=$lock
  fi
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  [ "$pid" = "$PPID" ] || die "remote reply lifecycle lock is not held by the caller"
}

case "${1:-}" in
  arm) shift; [ "$#" -eq 1 ] || usage; cmd_arm "$@" ;;
  arm-locked) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; require_parent_lifecycle_lock "$1"; cmd_arm_locked "$@" ;;
  ensure-armed) shift; [ "$#" -eq 0 ] || usage; cmd_ensure_armed ;;
  autohandle) shift; [ "$#" -eq 3 ] || usage; cmd_autohandle "$@" ;;
  handled-gate) shift; [ "$#" -eq 3 ] || usage; cmd_handled_gate "$@" ;;
  source) shift; [ "$#" -eq 1 ] || usage; cmd_source "$@" ;;
  handle) shift; [ "$#" -eq 3 ] || usage; cmd_handle "$@" ;;
  ingest) shift; [ "$#" -eq 2 ] || usage; cmd_ingest "$@" ;;
  classify) shift; [ "$#" -eq 1 ] || usage; classify_result "$1" ;;
  terminal) shift; [ "$#" -eq 1 ] || usage; [ -s "$1" ] ;;
  source-id) shift; [ "$#" -eq 1 ] || usage; source_id "$1" ;;
  retire) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
  retire-quiesce-locked) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; require_parent_lifecycle_lock "$1"; cmd_retire_quiesce_locked "$@" ;;
  retire-finalize-locked) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; require_parent_lifecycle_lock "$1"; cmd_retire_finalize_locked "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
