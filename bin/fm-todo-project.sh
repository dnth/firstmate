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
#     The board says in-flight but its recorded metadata, worktree, window, or
#     backend endpoint is gone. This uses fm-backend.sh's shared cheap endpoint
#     existence primitive; bin/fm-crew-state.sh remains the owner of richer
#     run-step, busy-state, and current-state reconciliation.
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

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
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

# axi_rows <table> <listing> <field> [<field>...]: validated TAB-separated
# selected fields, one row per task. A successful empty listing must carry the
# tool's explicit count-zero scalar; a non-empty listing must carry the expected
# table header with every requested field and the declared number of parseable
# rows. Anything else is incompatible rather than an empty board.
axi_rows() {
  local table=$1 listing=$2
  shift 2
  awk -v table="$table" -v want="$*" '
    function split_row(line, out,   n, i, c, field, inq, nxt) {
      n = 0; field = ""; inq = 0; i = 1
      while (i <= length(line)) {
        c = substr(line, i, 1)
        if (inq) {
          if (c == "\\") {
            nxt = substr(line, i + 1, 1)
            # Only \" and \\ are escapes; every other backslash is literal text.
            if (nxt == "\"" || nxt == "\\") { field = field nxt; i += 2; continue }
            field = field c; i += 1; continue
          }
          if (c == "\"") { inq = 0; i += 1; continue }
          field = field c; i += 1; continue
        }
        if (c == "\"") { inq = 1; i += 1; continue }
        if (c == ",") { out[++n] = field; field = ""; i += 1; continue }
        field = field c; i += 1
      }
      if (inq) return -1
      out[++n] = field
      return n
    }
    BEGIN { nwant = split(want, wanted, " ") }
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

json_escape() {  # <text>
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# One todo item line: "<id> - <title>", whitespace-collapsed with only the
# title length-capped. A too-small configured cap is raised per item just enough
# to preserve the ID, separator, and an ellipsis.
todo_item() {  # <id> <title>
  local id=$1 title=$2 prefix item_max title_max
  title=$(printf '%s' "$title" | tr '\t\n' '  ' | tr -s ' ' | sed 's/^ //; s/ $//')
  [ -n "$title" ] || title=-
  prefix="$id - "
  item_max=$ITEM_MAX
  if [ "$item_max" -lt $((${#prefix} + 1)) ]; then
    item_max=$((${#prefix} + 1))
  fi
  title_max=$((item_max - ${#prefix}))
  if [ "${#title}" -gt "$title_max" ]; then
    if [ "$title_max" -eq 1 ]; then
      title=…
    else
      title="${title:0:$((title_max - 1))}…"
    fi
  fi
  printf '%s%s' "$prefix" "$title"
}

# Collect "<id>\t<title>" rows for one phase into a JSON phase object, or
# nothing when the phase has no tasks (the todo tool requires >= 1 item).
phase_json() {  # <phase-name> <rows>
  local name=$1 rows=$2 id title first=1 items=
  [ -n "$rows" ] || return 1
  while IFS=$'\t' read -r id title; do
    [ -n "$id" ] || continue
    [ "$first" -eq 1 ] || items="$items,"$'\n'
    first=0
    items="$items$(printf '      "%s"' "$(json_escape "$(todo_item "$id" "$title")")")"
  done <<< "$rows"
  [ "$first" -eq 0 ] || return 1
  printf '  {\n    "phase": "%s",\n    "items": [\n%s\n    ]\n  }' \
    "$(json_escape "$name")" "$items"
}

run_emit() {
  local reason in_flight ready in_flight_rows ready_rows phases=() rendered
  reason=$(board_unavailable_reason)
  [ -z "$reason" ] || fail "cannot project the todo: $reason"

  in_flight=$(axi_list in_flight) || fail "tasks-axi list --state in_flight failed: $in_flight"
  ready=$(tasks-axi ready --file "$BOARD" 2>&1) || fail "tasks-axi ready failed: $ready"
  in_flight_rows=$(axi_rows tasks "$in_flight" id title) \
    || fail "tasks-axi list --state in_flight returned an unrecognized listing"
  ready_rows=$(axi_rows ready "$ready" id title) \
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

# An in-flight row whose recorded worker resources no longer exist. This is the
# same cheap metadata and endpoint-liveness boundary used by session start.
check_inflight() {  # <in_flight-listing>
  local listing=$1 id meta worktree window backend target
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    meta="$STATE/$id.meta"
    if [ ! -f "$meta" ]; then
      printf 'DRIFT inflight-no-worker: %s - no metadata\n' "$id"
      continue
    fi
    worktree=$(fm_meta_get "$meta" worktree)
    if [ -z "$worktree" ]; then
      printf 'DRIFT inflight-no-worker: %s - no worktree recorded\n' "$id"
      continue
    fi
    if [ ! -d "$worktree" ]; then
      printf 'DRIFT inflight-no-worker: %s - worktree is gone\n' "$id"
      continue
    fi
    window=$(fm_meta_get "$meta" window)
    if [ -z "$window" ]; then
      printf 'DRIFT inflight-no-worker: %s - no window recorded\n' "$id"
      continue
    fi
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if ! fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
      printf 'DRIFT inflight-no-worker: %s - recorded endpoint is dead\n' "$id"
    fi
  done <<< "$(axi_rows tasks "$listing" id)"
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
    done <<< "$(axi_rows tasks "$listing" id hold_until)"
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
    if axi_rows tasks "$in_flight" id hold_until >/dev/null; then
      check_inflight "$in_flight"
      hold_listings+=("$in_flight")
    else
      printf 'DRIFT-CHECK-SKIPPED: tasks-axi list --state in_flight returned an unrecognized listing\n'
    fi
  else
    printf 'DRIFT-CHECK-SKIPPED: tasks-axi list --state in_flight failed\n'
  fi
  if queued=$(axi_list queued hold_until); then
    if axi_rows tasks "$queued" id hold_until >/dev/null; then
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
