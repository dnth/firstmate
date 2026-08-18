#!/usr/bin/env bash
# fm-todo-project.sh - project the durable board into the session todo, and
# report where the board has drifted from reality.
#
# The board (data/backlog.md, read only through tasks-axi) is the single source
# of truth for fleet work. The harness todo list is a pure PROJECTION of it: it
# is session-scoped, resets on restart, and is never hand-diverged, so it is
# rebuilt from the board rather than maintained by hand. This script owns both
# halves of keeping those two in step.
#
# Usage:
#   fm-todo-project.sh --emit     print the board as todo `init` list JSON
#   fm-todo-project.sh --check    print board-vs-reality drift (default)
#   fm-todo-project.sh --help
#
# FM_HOME must be set explicitly, exactly as bin/fm-send.sh requires it: a
# projection or drift report silently resolved against the wrong home is worse
# than a loud refusal. FM_STATE_OVERRIDE / FM_DATA_OVERRIDE / FM_CONFIG_OVERRIDE
# retarget the individual directories the same way the rest of bin/ does.
#
# --emit prints ONLY a JSON array on stdout, shaped as the todo tool's `init`
# `list` argument: [{"phase":"<name>","items":["<id> - <title>", ...]}]. Two
# phases are projected - "Active" (every in-flight task) and "Ready" (every
# dispatchable queued task from `tasks-axi ready`). A phase with no tasks is
# omitted rather than emitted empty, because the tool requires at least one item
# per phase; an empty board therefore emits `[]`. Item text is one line and its
# title is capped so the complete durable ID and separator are always preserved,
# even when FM_TODO_ITEM_MAX (default 100) is smaller than that identity prefix.
# TOON string escapes are decoded strictly, with line-breaking whitespace
# collapsed before projection; malformed escapes make the listing incompatible.
#
# --check is REPORT-ONLY and never mutates the board. Reconciliation stays with
# firstmate's judgment: an in-flight row with no worker may need a relaunch, a
# teardown, or nothing at all, and a lapsed hold on a captain-gated item is the
# captain's to lift. It prints one finding per line and nothing when clean, so it
# composes into the session-start digest and a heartbeat sweep without noise, and
# it always exits 0 - it is a report, not a gate.
#
# Findings:
#   DRIFT inflight-no-worker: <id> - <reason>
#     The board says in-flight but bin/fm-crew-state.sh - the single owner of
#     current-state reconciliation - can find no worker at all (state `unknown`
#     from source `none`: no metadata, a torn-down worktree, or a recorded
#     endpoint that is gone). Liveness is never reimplemented here.
#   DRIFT hold-expired: <id> - hold_until <date> passed
#     A date-gated hold whose deadline has lapsed. tasks-axi's own gate is
#     inactive ON and after that date, so `--state held` no longer lists these
#     rows at all - they reappear as ordinary queued work while the board text
#     still reads as held. The lapsed rows are therefore found by asking for
#     hold_until across the in-flight and queued listings, not from `--state held`.
#
# When the board cannot be read machine-side at all - `config/backlog-backend`
# selects manual, or tasks-axi is missing or incompatible - --check prints one
# DRIFT-CHECK-SKIPPED line naming the reason (still exit 0) and --emit refuses on
# stderr with a non-zero exit rather than printing `[]`, which would wipe a live
# todo list on a tooling failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-todo-project: %s\n' "$*" >&2
  exit 1
}

MODE=check
case "${1:-}" in
  ''|--check) MODE=check ;;
  --emit) MODE=emit ;;
  -h|--help) usage; exit 0 ;;
  *) fail "unknown argument '$1' (see --help)" ;;
esac
[ "$#" -le 1 ] || fail "unexpected extra argument '$2' (see --help)"

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  fail "FM_HOME is not set; refusing to project or check a board without an explicit firstmate home"
fi
[ -d "$FM_HOME" ] || fail "FM_HOME '$FM_HOME' is not a directory"

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BOARD="$DATA/backlog.md"

ITEM_MAX=${FM_TODO_ITEM_MAX:-100}
case "$ITEM_MAX" in ''|*[!0-9]*|0) ITEM_MAX=100 ;; esac

# --- board access -----------------------------------------------------------

# Why the board might not be machine-readable, or empty for "it is".
board_unavailable_reason() {
  if [ ! -f "$BOARD" ]; then
    printf 'backlog %s is absent\n' "$BOARD"
    return 0
  fi
  if fm_backlog_backend_manual "$CONFIG"; then
    printf 'backlog backend is manual\n'
    return 0
  fi
  if ! fm_tasks_axi_compatible; then
    printf 'tasks-axi is unavailable or incompatible\n'
    return 0
  fi
  printf ''
}

# axi_rows <table> <listing> <rows|items> <field> [<field>...]: validated
# selected fields, as TAB-separated rows or JSON-escaped todo items. Item mode
# keeps decoded values inside its byte-oriented parser through normalization,
# codepoint-safe truncation, and JSON escaping, so NUL and UTF-8 never cross an
# unsafe shell-string boundary. A successful empty listing must carry the tool's
# explicit count-zero scalar; a non-empty listing must carry the expected table
# header with every requested field and the declared number of parseable rows.
# Anything else is incompatible rather than an empty board.
axi_rows() {
  local table=$1 listing=$2 output=$3
  shift 3
  LC_ALL=C awk -v table="$table" -v output="$output" -v item_max="$ITEM_MAX" -v want="$*" '
    function hex_value(hex,   i, digit, value) {
      if (length(hex) != 4) return -1
      value = 0
      for (i = 1; i <= 4; i++) {
        digit = index("0123456789abcdef", tolower(substr(hex, i, 1))) - 1
        if (digit < 0) return -1
        value = value * 16 + digit
      }
      return value
    }
    function utf8(code) {
      if (code <= 127) return sprintf("%c", code)
      if (code <= 2047) {
        return sprintf("%c%c", 192 + int(code / 64), 128 + code % 64)
      }
      return sprintf("%c%c%c", 224 + int(code / 4096), \
        128 + int(code / 64) % 64, 128 + code % 64)
    }
    function decode_token(token,   i, c, nxt, hex, code, value) {
      sub(/^[[:space:]]+/, "", token)
      sub(/[[:space:]]+$/, "", token)
      if (substr(token, 1, 1) != "\"") {
        if (index(token, "\"") != 0) { token_bad = 1; return "" }
        return token
      }
      if (length(token) < 2 || substr(token, length(token), 1) != "\"") {
        token_bad = 1
        return ""
      }
      token = substr(token, 2, length(token) - 2)
      value = ""; i = 1
      while (i <= length(token)) {
        c = substr(token, i, 1)
        if (c != "\\") { value = value c; i++; continue }
        nxt = substr(token, i + 1, 1)
        if (nxt == "\"" || nxt == "\\" || nxt == "/") {
          value = value nxt; i += 2; continue
        }
        if (nxt == "b") { value = value sprintf("%c", 8); i += 2; continue }
        if (nxt == "f") { value = value sprintf("%c", 12); i += 2; continue }
        if (nxt == "n" || nxt == "r" || nxt == "t") {
          value = value " "; i += 2; continue
        }
        if (nxt == "u") {
          hex = substr(token, i + 2, 4)
          code = hex_value(hex)
          if (code < 0 || (code >= 55296 && code <= 57343)) {
            token_bad = 1
            return ""
          }
          if (code == 9 || code == 10 || code == 13) value = value " "
          else value = value utf8(code)
          i += 6
          continue
        }
        token_bad = 1
        return ""
      }
      return value
    }
    function split_row(line, out,   n, i, c, token, inq, nxt) {
      n = 0; token = ""; inq = 0; i = 1
      while (i <= length(line)) {
        c = substr(line, i, 1)
        if (inq && c == "\\") {
          nxt = substr(line, i + 1, 1)
          if (nxt == "") return -1
          token = token c nxt; i += 2; continue
        }
        if (c == "\"") { inq = !inq; token = token c; i++; continue }
        if (c == "," && !inq) {
          token_bad = 0
          out[++n] = decode_token(token)
          if (token_bad) return -1
          token = ""; i++; continue
        }
        token = token c; i++
      }
      if (inq) return -1
      token_bad = 0
      out[++n] = decode_token(token)
      if (token_bad) return -1
      return n
    }
    function byte_value(c) {
      if (c == nul) return 0
      return byte_of[c]
    }
    function utf8_step(s, pos,   b, b2, b3, b4) {
      b = byte_value(substr(s, pos, 1))
      if (b <= 127) return 1
      b2 = byte_value(substr(s, pos + 1, 1))
      if (b >= 194 && b <= 223 && b2 >= 128 && b2 <= 191) return 2
      b3 = byte_value(substr(s, pos + 2, 1))
      if (b == 224 && b2 >= 160 && b2 <= 191 && b3 >= 128 && b3 <= 191) return 3
      if (b >= 225 && b <= 236 && b2 >= 128 && b2 <= 191 && b3 >= 128 && b3 <= 191) return 3
      if (b == 237 && b2 >= 128 && b2 <= 159 && b3 >= 128 && b3 <= 191) return 3
      if (b >= 238 && b <= 239 && b2 >= 128 && b2 <= 191 && b3 >= 128 && b3 <= 191) return 3
      b4 = byte_value(substr(s, pos + 3, 1))
      if (b == 240 && b2 >= 144 && b2 <= 191 && b3 >= 128 && b3 <= 191 && b4 >= 128 && b4 <= 191) return 4
      if (b >= 241 && b <= 243 && b2 >= 128 && b2 <= 191 && b3 >= 128 && b3 <= 191 && b4 >= 128 && b4 <= 191) return 4
      if (b == 244 && b2 >= 128 && b2 <= 143 && b3 >= 128 && b3 <= 191 && b4 >= 128 && b4 <= 191) return 4
      return 0
    }
    function text_length(s,   pos, count, step) {
      pos = 1; count = 0
      while (pos <= length(s)) {
        step = utf8_step(s, pos)
        if (step == 0) { utf8_bad = 1; return 0 }
        pos += step; count++
      }
      return count
    }
    function text_prefix(s, limit,   pos, count, step) {
      pos = 1; count = 0
      while (pos <= length(s) && count < limit) {
        step = utf8_step(s, pos)
        if (step == 0) { utf8_bad = 1; return "" }
        pos += step; count++
      }
      return substr(s, 1, pos - 1)
    }
    function json_string(s,   i, c, b, result) {
      result = "\""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1); b = byte_value(c)
        if (b == 34) result = result "\\\""
        else if (b == 92) result = result "\\\\"
        else if (b <= 31) result = result sprintf("\\u%04x", b)
        else result = result c
      }
      return result "\""
    }
    function todo_json(id, title,   prefix, effective_max, title_max, title_len) {
      gsub(/[\t\r\n]/, " ", title)
      gsub(/ +/, " ", title)
      sub(/^ /, "", title); sub(/ $/, "", title)
      if (title == "") title = "-"
      prefix = id " - "
      utf8_bad = 0
      effective_max = item_max
      if (effective_max < text_length(prefix) + 1) effective_max = text_length(prefix) + 1
      title_max = effective_max - text_length(prefix)
      title_len = text_length(title)
      if (utf8_bad) return ""
      if (title_len > title_max) {
        if (title_max == 1) title = "…"
        else title = text_prefix(title, title_max - 1) "…"
      }
      if (utf8_bad) return ""
      return json_string(prefix title)
    }
    BEGIN {
      nul = sprintf("%c", 0)
      for (i = 0; i <= 255; i++) byte_of[sprintf("%c", i)] = i
      nwant = split(want, wanted, " ")
    }
    $0 == "count: 0" { zero_count = 1; next }
    table == "tasks" && /^tasks: 0 .*tasks in this backlog$/ { zero_scalar = 1; next }
    table == "ready" && $0 == "ready: 0 unblocked queued tasks" { zero_scalar = 1; next }
    /^help\[/ { exit }
    /^(tasks|ready)\[[0-9]+\]\{.*\}:$/ {
      name = $0
      sub(/\[.*/, "", name)
      if (name != table) { rows = 0; next }
      spec = $0
      sub(/^[a-z]+\[[0-9]+\]\{/, "", spec)
      sub(/\}:$/, "", spec)
      declared = $0
      sub(/^[a-z]+\[/, "", declared)
      sub(/\].*$/, "", declared)
      for (key in index_of) delete index_of[key]
      ncol = split(spec, cols, ",")
      for (i = 1; i <= ncol; i++) index_of[cols[i]] = i
      for (i = 1; i <= nwant; i++) if (!index_of[wanted[i]]) bad = 1
      header = 1
      rows = 1
      next
    }
    rows && /^[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      for (key in cells) delete cells[key]
      ncells = split_row(line, cells)
      if (ncells != ncol) { bad = 1; next }
      out = ""
      for (i = 1; i <= nwant; i++) {
        col = index_of[wanted[i]]
        out = out (i > 1 ? "\t" : "") (col ? cells[col] : "")
      }
      if (output == "items") {
        out = todo_json(cells[index_of["id"]], cells[index_of["title"]])
        if (utf8_bad) { bad = 1; next }
      }
      print out
      seen++
      next
    }
    { rows = 0 }
    END {
      if (header) {
        if (bad || seen != declared) exit 3
        exit 0
      }
      if (zero_count && zero_scalar) exit 0
      exit 3
    }
  ' <<< "$listing"
}

axi_list() {  # <state> [<extra-fields>]
  local state=$1 fields=${2:-}
  if [ -n "$fields" ]; then
    tasks-axi list --file "$BOARD" --state "$state" --fields "$fields" 2>&1
  else
    tasks-axi list --file "$BOARD" --state "$state" 2>&1
  fi
}

# --- emit -------------------------------------------------------------------

# Collect "<id>\t<title>" rows for one phase into a JSON phase object, or
# nothing when the phase has no tasks (the todo tool requires >= 1 item).
phase_json() {  # <phase-name> <rows>
  local name=$1 rows=$2 item first=1 items=
  [ -n "$rows" ] || return 1
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    [ "$first" -eq 1 ] || items="$items,"$'\n'
    first=0
    items="$items      $item"
  done <<< "$rows"
  [ "$first" -eq 0 ] || return 1
  printf '  {\n    "phase": "%s",\n    "items": [\n%s\n    ]\n  }' \
    "$name" "$items"
}

run_emit() {
  local reason in_flight ready in_flight_rows ready_rows phases=() rendered
  reason=$(board_unavailable_reason)
  [ -z "$reason" ] || fail "cannot project the todo: $reason"

  in_flight=$(axi_list in_flight) || fail "tasks-axi list --state in_flight failed: $in_flight"
  ready=$(tasks-axi ready --file "$BOARD" 2>&1) || fail "tasks-axi ready failed: $ready"
  in_flight_rows=$(axi_rows tasks "$in_flight" items id title) \
    || fail "tasks-axi list --state in_flight returned an unrecognized listing"
  ready_rows=$(axi_rows ready "$ready" items id title) \
    || fail "tasks-axi ready returned an unrecognized listing"

  if rendered=$(phase_json Active "$in_flight_rows"); then
    phases+=("$rendered")
  fi
  if rendered=$(phase_json Ready "$ready_rows"); then
    phases+=("$rendered")
  fi

  if [ "${#phases[@]}" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi
  printf '[\n'
  local i
  for i in "${!phases[@]}"; do
    printf '%s' "${phases[$i]}"
    [ "$i" -eq $((${#phases[@]} - 1)) ] || printf ','
    printf '\n'
  done
  printf ']\n'
}

# --- check ------------------------------------------------------------------

# An in-flight row whose worker cannot be found at all. bin/fm-crew-state.sh is
# the owner of that verdict: `state: unknown · source: none · <reason>` is its
# one canonical way of saying no current-state source exists for this task.
check_inflight() {  # <in_flight-listing>
  local listing=$1 id verdict reason
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    verdict=$("$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null) || continue
    case "$verdict" in
      'state: unknown'*'source: none'*) ;;
      *) continue ;;
    esac
    reason=${verdict##*source: none}
    reason=${reason# · }
    [ -n "$reason" ] || reason="no current-state source available"
    printf 'DRIFT inflight-no-worker: %s - %s\n' "$id" "$reason"
  done <<< "$(axi_rows tasks "$listing" rows id)"
}

# A date-gated hold whose deadline has lapsed.
check_holds() {  # <listing>...
  local listing id hold_until today
  today=$(date +%F)
  for listing in "$@"; do
    while IFS=$'\t' read -r id hold_until; do
      [ -n "$id" ] || continue
      case "$hold_until" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) continue ;;
      esac
      # Lexical compare is exact for YYYY-MM-DD. tasks-axi's own gate is
      # inactive ON and after the date, so a same-day deadline has lapsed too.
      if [[ $hold_until > $today ]]; then
        continue
      fi
      printf 'DRIFT hold-expired: %s - hold_until %s passed\n' "$id" "$hold_until"
    done <<< "$(axi_rows tasks "$listing" rows id hold_until)"
  done
}

run_check() {
  local reason in_flight queued
  reason=$(board_unavailable_reason)
  if [ -n "$reason" ]; then
    printf 'DRIFT-CHECK-SKIPPED: %s\n' "$reason"
    return 0
  fi

  # One failed listing never suppresses the other's findings: a partial report
  # plus a named skip is more useful than silence.
  local -a hold_listings=()
  if in_flight=$(axi_list in_flight hold_until); then
    if axi_rows tasks "$in_flight" rows id hold_until >/dev/null; then
      check_inflight "$in_flight"
      hold_listings+=("$in_flight")
    else
      printf 'DRIFT-CHECK-SKIPPED: tasks-axi list --state in_flight returned an unrecognized listing\n'
    fi
  else
    printf 'DRIFT-CHECK-SKIPPED: tasks-axi list --state in_flight failed\n'
  fi
  if queued=$(axi_list queued hold_until); then
    if axi_rows tasks "$queued" rows id hold_until >/dev/null; then
      hold_listings+=("$queued")
    else
      printf 'DRIFT-CHECK-SKIPPED: tasks-axi list --state queued returned an unrecognized listing\n'
    fi
  else
    printf 'DRIFT-CHECK-SKIPPED: tasks-axi list --state queued failed\n'
  fi
  [ "${#hold_listings[@]}" -eq 0 ] || check_holds "${hold_listings[@]}"
  return 0
}

case "$MODE" in
  emit) run_emit ;;
  check) run_check ;;
esac
