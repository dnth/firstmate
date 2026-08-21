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
#   fm-todo-project.sh --check --reconcile
#                                reconcile lifecycle drift with verified authority
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
# --check is strictly report-only unless its caller also supplies --reconcile
# after verifying fleet-mutation authority. Reconciliation auto-fixes exactly
# one unambiguous board state: an open task whose recorded PR is exactly merged.
# It first persists a private identity-bound merged receipt, runs ordinary
# guarded teardown, and closes the board item only after teardown succeeds, so
# dirty or unlanded work retains every existing refusal and a transient board
# close failure remains retryable after task metadata is removed. Each receipt
# binds its task ID and canonical PR to the board row's exact created generation,
# which is re-read before every close; an unbound or mismatched open receipt is
# retired without touching the row. Receipts move from pending to closed only
# after tasks-axi confirms closure; closed receipts carry cleanup authority but
# never board-close authority, and the receipt sweep retires them independently
# of open rows. Every other finding stays report-only and requires firstmate
# judgment. Reconciliation recovers only the PR-ready status contracts owned by
# bin/fm-brief.sh through bin/fm-pr-check.sh, so discovered PR-bearing tasks
# converge on the ordinary merge watch without treating unrelated status URLs as
# task identity. The command prints one finding per line and nothing when clean,
# and after invocation validation it always exits 0 - it is a reconciler, not a
# gate.
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
#   DRIFT secondmate-scope-on-main: <id> - <reason>
#     A main-board row names a project registered to a secondmate but has the
#     same canonical unknown/source-none verdict as an item with no local worker.
#     This is report-only so firstmate can migrate it through the handoff owner.
#   DRIFT merged-pr-open: <id> - <reason>
#     A task's canonical recorded PR is exactly merged while its board row is
#     still open. This is the sole auto-fix: guarded teardown runs without force,
#     then tasks-axi closes the item with its recorded PR URL.
#   DRIFT queued-has-worker: <id> - <reason>
#     A queued board row has a current-state source, so a local worker already
#     exists even though the board still presents the work as dispatchable.
#
# The caller re-projects the session todo after every board mutation, including
# this script's merged-PR close. Deferred work is put on hold at deferral time,
# because --emit projects every dispatchable queued row into Ready by design.
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
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

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
RECONCILE=0
case "$#:$*" in
  0:|1:--check) ;;
  '2:--check --reconcile') RECONCILE=1 ;;
  1:--emit) MODE=emit ;;
  1:-h|1:--help) usage; exit 0 ;;
  *) fail "invalid arguments '$*' (see --help)" ;;
esac

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  fail "FM_HOME is not set; refusing to project or check a board without an explicit firstmate home"
fi
[ -d "$FM_HOME" ] || fail "FM_HOME '$FM_HOME' is not a directory"

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
BOARD="$DATA/backlog.md"
SECONDMATES="$DATA/secondmates.md"

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

AUTO_CLOSED_IDS=$'\n'
PR_CHECKED_IDS=$'\n'
SECONDMATE_PROJECT_ROWS=
CREW_PROBED_IDS=$'\n'
CREW_VERDICT_ROWS=
OPEN_IDS=$'\n'
OPEN_GENERATION_ROWS=
MERGED_RECEIPT_SUFFIX=.todo-merged-reconciliation

id_in_set() {  # <newline-delimited-set> <id>
  case "$1" in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

mark_auto_closed() { AUTO_CLOSED_IDS="${AUTO_CLOSED_IDS}$1"$'\n'; }

# Read the registry through its one parser and retain only exact project names.
# The projects field is comma-separated provisioning data; matching it is a
# deterministic integrity hint, while the report deliberately leaves routing
# judgment and handoff to firstmate.
load_secondmate_projects() {
  local line project
  local -a projects
  [ -e "$SECONDMATES" ] || return 0
  if [ ! -f "$SECONDMATES" ] || [ -L "$SECONDMATES" ]; then
    printf 'DRIFT-CHECK-SKIPPED: secondmate registry is unavailable or unsafe\n'
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '- '*) ;;
      *) continue ;;
    esac
    if ! secondmate_registry_parse_line "$line"; then
      printf 'DRIFT-CHECK-SKIPPED: secondmate registry contains a malformed entry\n'
      return 1
    fi
    IFS=, read -ra projects <<< "$SECONDMATE_REGISTRY_PROJECTS"
    for project in "${projects[@]}"; do
      project=${project#"${project%%[![:space:]]*}"}
      project=${project%"${project##*[![:space:]]}"}
      [ -n "$project" ] && [ "$project" != '-' ] || continue
      SECONDMATE_PROJECT_ROWS="${SECONDMATE_PROJECT_ROWS}${project}"$'\t'"${SECONDMATE_REGISTRY_ID}"$'\n'
    done
  done < "$SECONDMATES"
}

secondmate_for_repo() {  # <repo>
  local want=$1 project secondmate
  while IFS=$'\t' read -r project secondmate; do
    [ -n "$project" ] || continue
    if [ "$project" = "$want" ]; then
      printf '%s\n' "$secondmate"
      return 0
    fi
  done <<< "$SECONDMATE_PROJECT_ROWS"
  return 1
}

crew_verdict() {  # <id>
  "$SCRIPT_DIR/fm-crew-state.sh" "$1" 2>/dev/null
}

capture_crew_verdicts() {  # <listing>...
  local listing id generation verdict
  for listing in "$@"; do
    while IFS=$'\t' read -r id generation; do
      [ -n "$id" ] || continue
      fm_pr_task_id_valid "$id" || continue
      if ! id_in_set "$OPEN_IDS" "$id"; then
        OPEN_IDS="${OPEN_IDS}${id}"$'\n'
        OPEN_GENERATION_ROWS="${OPEN_GENERATION_ROWS}${id}"$'\t'"${generation}"$'\n'
      fi
      id_in_set "$CREW_PROBED_IDS" "$id" && continue
      CREW_PROBED_IDS="${CREW_PROBED_IDS}${id}"$'\n'
      verdict=$(crew_verdict "$id") || continue
      case "$verdict" in *$'\n'*|*$'\t'*) continue ;; esac
      CREW_VERDICT_ROWS="${CREW_VERDICT_ROWS}${id}"$'\t'"${verdict}"$'\n'
    done <<< "$(axi_rows tasks "$listing" rows id created)"
  done
}

board_generation_valid() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

board_generation_for() {  # <id>
  local want=$1 id generation
  while IFS=$'\t' read -r id generation; do
    [ "$id" = "$want" ] || continue
    board_generation_valid "$generation" || return 1
    printf '%s\n' "$generation"
    return 0
  done <<< "$OPEN_GENERATION_ROWS"
  return 1
}

current_board_generation() {  # <id>
  local want=$1 state listing id generation found=
  for state in in_flight queued; do
    listing=$(axi_list "$state" created) || return 1
    axi_rows tasks "$listing" rows id created >/dev/null || return 1
    while IFS=$'\t' read -r id generation; do
      [ "$id" = "$want" ] || continue
      board_generation_valid "$generation" || return 1
      [ -z "$found" ] || [ "$found" = "$generation" ] || return 1
      found=$generation
    done <<< "$(axi_rows tasks "$listing" rows id created)"
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

crew_verdict_for() {  # <id>
  local want=$1 id verdict
  while IFS=$'\t' read -r id verdict; do
    [ "$id" = "$want" ] || continue
    printf '%s\n' "$verdict"
    return 0
  done <<< "$CREW_VERDICT_ROWS"
  return 1
}

verdict_has_no_source() {  # <fm-crew-state verdict>
  case "$1" in
    'state: unknown'*'source: none'*) return 0 ;;
    *) return 1 ;;
  esac
}

status_pr_url() {  # <id>
  local log="$STATE/$1.status" line candidate found=
  [ -f "$log" ] && [ ! -L "$log" ] || return 1
  [ "$(fm_pr_file_link_count "$log")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    candidate=
    case "$line" in
      'done: PR '*' checks green')
        candidate=${line#done: PR }
        candidate=${candidate% checks green}
        ;;
      'done: PR '*) candidate=${line#done: PR } ;;
      *) continue ;;
    esac
    if fm_pr_url_parse "$candidate"; then
      found=$FM_PR_URL
    fi
  done < "$log"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

set_task_pr_identity() {
  TASK_PR_PROVIDER=$FM_PR_PROVIDER
  TASK_PR_URL=$FM_PR_URL
  TASK_PR_HOST=$FM_PR_HOST
  TASK_PR_PATH=$FM_PR_PATH
  TASK_PR_NUMBER=$FM_PR_NUMBER
}

merged_receipt_path() { printf '%s/%s%s\n' "$STATE" "$1" "$MERGED_RECEIPT_SUFFIX"; }

merged_receipt_parse() {  # <id>; sets TASK_PR_* globals
  local id=$1 receipt state_device version receipt_id provider url host path number result stage generation= extra
  TASK_RECEIPT_STAGE=
  TASK_RECEIPT_GENERATION=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  receipt=$(merged_receipt_path "$id")
  fm_pr_private_file_valid "$receipt" 600 "$state_device" || return 1
  exec 9< "$receipt" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r receipt_id <&9 || { exec 9<&-; return 1; }
  IFS= read -r provider <&9 || { exec 9<&-; return 1; }
  IFS= read -r url <&9 || { exec 9<&-; return 1; }
  IFS= read -r host <&9 || { exec 9<&-; return 1; }
  IFS= read -r path <&9 || { exec 9<&-; return 1; }
  IFS= read -r number <&9 || { exec 9<&-; return 1; }
  IFS= read -r result <&9 || { exec 9<&-; return 1; }
  case "$version" in
    fm-todo-merged-reconciliation-v1) stage=pending ;;
    fm-todo-merged-reconciliation-v2)
      IFS= read -r stage <&9 || { exec 9<&-; return 1; }
      ;;
    fm-todo-merged-reconciliation-v3)
      IFS= read -r stage <&9 || { exec 9<&-; return 1; }
      IFS= read -r generation <&9 || { exec 9<&-; return 1; }
      ;;
    *) exec 9<&-; return 1 ;;
  esac
  if IFS= read -r extra <&9; then exec 9<&-; return 1; fi
  exec 9<&-
  [ "$receipt_id" = "$id" ] || return 1
  fm_pr_url_parse "$url" || return 1
  [ "$provider" = "$FM_PR_PROVIDER" ] || return 1
  [ "$host" = "$FM_PR_HOST" ] || return 1
  [ "$path" = "$FM_PR_PATH" ] || return 1
  [ "$number" = "$FM_PR_NUMBER" ] || return 1
  [ "$result" = merged ] || return 1
  case "$stage" in pending|closed) ;; *) return 1 ;; esac
  [ -z "$generation" ] || board_generation_valid "$generation" || return 1
  TASK_RECEIPT_STAGE=$stage
  TASK_RECEIPT_GENERATION=$generation
  set_task_pr_identity
}

merged_receipt_matches_task() {  # <id>
  local meta="$STATE/$1.meta"
  fm_pr_metadata_identity_parse "$meta" || return 1
  [ "$FM_PR_META_PROVIDER" = "$TASK_PR_PROVIDER" ] || return 1
  [ "$FM_PR_META_URL" = "$TASK_PR_URL" ] || return 1
  [ "$FM_PR_META_HOST" = "$TASK_PR_HOST" ] || return 1
  [ "$FM_PR_META_PATH" = "$TASK_PR_PATH" ] || return 1
  [ "$FM_PR_META_NUMBER" = "$TASK_PR_NUMBER" ]
}

merged_receipt_publish() {  # <id>
  local id=$1 receipt tmp existing_url=$TASK_PR_URL existing_generation=$TASK_BOARD_GENERATION
  board_generation_valid "$existing_generation" || return 1
  receipt=$(merged_receipt_path "$id")
  if [ -e "$receipt" ] || [ -L "$receipt" ]; then
    merged_receipt_parse "$id" || return 1
    [ "$TASK_PR_URL" = "$existing_url" ] \
      && [ "$TASK_RECEIPT_STAGE" = pending ] \
      && [ "$TASK_RECEIPT_GENERATION" = "$existing_generation" ]
    return
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(mktemp "$STATE/.todo-merged-reconciliation.${id}.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! printf '%s\n' fm-todo-merged-reconciliation-v3 "$id" \
      "$TASK_PR_PROVIDER" "$TASK_PR_URL" "$TASK_PR_HOST" "$TASK_PR_PATH" \
      "$TASK_PR_NUMBER" merged pending "$existing_generation" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_pr_regular_destination_or_absent "$receipt" || ! mv -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
  merged_receipt_parse "$id" \
    && [ "$TASK_PR_URL" = "$existing_url" ] \
    && [ "$TASK_RECEIPT_STAGE" = pending ] \
    && [ "$TASK_RECEIPT_GENERATION" = "$existing_generation" ]
}

merged_receipt_mark_closed() {  # <id> [<completed-generation>]
  local id=$1 completed_generation=${2:-} receipt tmp before_hash before_identity expected_url expected_generation
  receipt=$(merged_receipt_path "$id")
  merged_receipt_parse "$id" || return 1
  case "$TASK_RECEIPT_STAGE" in pending) ;; closed) return 0 ;; esac
  expected_url=$TASK_PR_URL
  expected_generation=$TASK_RECEIPT_GENERATION
  if [ -z "$expected_generation" ]; then expected_generation=$completed_generation; fi
  board_generation_valid "$expected_generation" || return 1
  before_hash=$(fm_pr_sha256 "$receipt") || return 1
  before_identity=$(fm_pr_file_identity "$receipt") || return 1
  tmp=$(mktemp "$STATE/.todo-merged-reconciliation.${id}.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! printf '%s\n' fm-todo-merged-reconciliation-v3 "$id" \
      "$TASK_PR_PROVIDER" "$TASK_PR_URL" "$TASK_PR_HOST" "$TASK_PR_PATH" \
      "$TASK_PR_NUMBER" merged closed "$expected_generation" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! merged_receipt_parse "$id" \
      || [ "$TASK_RECEIPT_STAGE" != pending ] \
      || [ "$(fm_pr_sha256 "$receipt")" != "$before_hash" ] \
      || [ "$(fm_pr_file_identity "$receipt")" != "$before_identity" ] \
      || ! mv -- "$tmp" "$receipt"; then
    rm -f -- "$tmp"
    return 1
  fi
  merged_receipt_parse "$id" \
    && [ "$TASK_PR_URL" = "$expected_url" ] \
    && [ "$TASK_RECEIPT_STAGE" = closed ] \
    && [ "$TASK_RECEIPT_GENERATION" = "$expected_generation" ]
}

merged_receipt_retire_stale() {  # <id> <current-generation>
  local id=$1 current_generation=$2 receipt before_hash before_identity
  receipt=$(merged_receipt_path "$id")
  board_generation_valid "$current_generation" || return 1
  merged_receipt_parse "$id" || return 1
  [ "$TASK_RECEIPT_STAGE" = pending ] || return 1
  [ -z "$TASK_RECEIPT_GENERATION" ] \
    || [ "$TASK_RECEIPT_GENERATION" != "$current_generation" ] \
    || return 1
  before_hash=$(fm_pr_sha256 "$receipt") || return 1
  before_identity=$(fm_pr_file_identity "$receipt") || return 1
  merged_receipt_parse "$id" \
    && [ "$TASK_RECEIPT_STAGE" = pending ] \
    && { [ -z "$TASK_RECEIPT_GENERATION" ] \
      || [ "$TASK_RECEIPT_GENERATION" != "$current_generation" ]; } \
    && [ "$(fm_pr_sha256 "$receipt")" = "$before_hash" ] \
    && [ "$(fm_pr_file_identity "$receipt")" = "$before_identity" ] \
    && rm -f -- "$receipt"
}

merged_receipt_remove_closed() {  # <id>
  local id=$1 receipt before_hash before_identity
  receipt=$(merged_receipt_path "$id")
  merged_receipt_parse "$id" || return 1
  [ "$TASK_RECEIPT_STAGE" = closed ] || return 1
  before_hash=$(fm_pr_sha256 "$receipt") || return 1
  before_identity=$(fm_pr_file_identity "$receipt") || return 1
  merged_receipt_parse "$id" \
    && [ "$TASK_RECEIPT_STAGE" = closed ] \
    && [ "$(fm_pr_sha256 "$receipt")" = "$before_hash" ] \
    && [ "$(fm_pr_file_identity "$receipt")" = "$before_identity" ] \
    && rm -f -- "$receipt"
}

recorded_pr_identity() {  # <id>; sets TASK_PR_* globals
  local id=$1 meta="$STATE/$1.meta" url
  TASK_PR_PROVIDER=
  TASK_PR_URL=
  TASK_PR_HOST=
  TASK_PR_PATH=
  TASK_PR_NUMBER=
  TASK_PR_ARMED_NOW=0
  if fm_pr_metadata_identity_parse "$meta"; then
    TASK_PR_PROVIDER=$FM_PR_META_PROVIDER
    TASK_PR_URL=$FM_PR_META_URL
    TASK_PR_HOST=$FM_PR_META_HOST
    TASK_PR_PATH=$FM_PR_META_PATH
    TASK_PR_NUMBER=$FM_PR_META_NUMBER
    return 0
  fi
  url=$(status_pr_url "$id") || return 1
  if [ "$RECONCILE" -eq 0 ]; then
    fm_pr_url_parse "$url" || return 1
    set_task_pr_identity
    TASK_PR_ARMED_NOW=0
    return 0
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-pr-check.sh" "$id" "$url" >/dev/null 2>&1; then
    printf 'DRIFT-CHECK-SKIPPED: could not arm merge watch for %s\n' "$id"
    return 1
  fi
  TASK_PR_ARMED_NOW=1
  fm_pr_metadata_identity_parse "$meta" || {
    printf 'DRIFT-CHECK-SKIPPED: merge watch for %s did not record canonical PR metadata\n' "$id"
    return 1
  }
  TASK_PR_PROVIDER=$FM_PR_META_PROVIDER
  TASK_PR_URL=$FM_PR_META_URL
  TASK_PR_HOST=$FM_PR_META_HOST
  TASK_PR_PATH=$FM_PR_META_PATH
  TASK_PR_NUMBER=$FM_PR_META_NUMBER
}

pr_is_exactly_merged() {
  local result
  result=$("$SCRIPT_DIR/fm-pr-poll.sh" --validated \
    "$TASK_PR_PROVIDER" "$TASK_PR_URL" "$TASK_PR_HOST" "$TASK_PR_PATH" "$TASK_PR_NUMBER" 2>/dev/null) || result=
  [ "$result" = merged ]
}

ensure_pr_watch() {  # <id>
  local id=$1
  [ "$TASK_PR_ARMED_NOW" -eq 0 ] || return 0
  if fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
    return 0
  fi
  if [ "$RECONCILE" -eq 0 ]; then
    printf 'DRIFT-CHECK-SKIPPED: merge watch for %s requires verified mutation authority\n' "$id"
    return 0
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-pr-check.sh" "$id" "$TASK_PR_URL" >/dev/null 2>&1; then
    printf 'DRIFT-CHECK-SKIPPED: could not arm merge watch for %s\n' "$id"
  fi
}

close_merged_board_item() {  # <id>
  local id=$1 current_generation
  if ! merged_receipt_parse "$id" \
      || [ "$TASK_RECEIPT_STAGE" != pending ] \
      || ! board_generation_valid "$TASK_RECEIPT_GENERATION"; then
    printf 'DRIFT-CHECK-SKIPPED: merged reconciliation receipt for %s failed validation before board closure\n' "$id"
    return 1
  fi
  current_generation=$(current_board_generation "$id") || {
    printf 'DRIFT-CHECK-SKIPPED: board generation for %s could not be verified before closure\n' "$id"
    return 1
  }
  if [ "$current_generation" != "$TASK_RECEIPT_GENERATION" ]; then
    printf 'DRIFT merged-pr-open: %s - stale reconciliation receipt does not match the current board generation\n' "$id"
    return 1
  fi
  if ! tasks-axi "done" "$id" --file "$BOARD" --pr "$TASK_PR_URL" >/dev/null 2>&1; then
    printf 'DRIFT merged-pr-open: %s - teardown completed but the merged board item could not be closed\n' "$id"
    return 1
  fi
  if ! merged_receipt_mark_closed "$id"; then
    printf 'DRIFT merged-pr-open: %s - merged board item closed but reconciliation completion could not be recorded\n' "$id"
    mark_auto_closed "$id"
    return 1
  fi
  if ! merged_receipt_remove_closed "$id"; then
    printf 'DRIFT merged-pr-open: %s - merged board item closed but reconciliation receipt cleanup failed\n' "$id"
    mark_auto_closed "$id"
    return 1
  fi
  mark_auto_closed "$id"
  printf 'DRIFT merged-pr-open: %s - merged PR closed and task torn down\n' "$id"
}

done_listing_has_receipt() {  # <done-listing> <id> <url> <generation>
  local listing=$1 want_id=$2 want_url=$3 want_generation=$4 id links generation link
  local -a receipt_links
  DONE_RECEIPT_GENERATION=
  while IFS=$'\t' read -r id links generation; do
    [ "$id" = "$want_id" ] || continue
    board_generation_valid "$generation" || continue
    if [ -n "$want_generation" ]; then
      [ "$generation" = "$want_generation" ] || continue
    fi
    IFS=, read -ra receipt_links <<< "$links"
    for link in "${receipt_links[@]}"; do
      if [ "$link" = "pr:$want_url" ]; then
        DONE_RECEIPT_GENERATION=$generation
        return 0
      fi
    done
  done <<< "$(axi_rows tasks "$listing" rows id links created)"
  return 1
}

sweep_merged_receipts() {  # <done-listing-or-empty>
  local done_listing=$1 receipt id completed_generation=
  for receipt in "$STATE"/*"$MERGED_RECEIPT_SUFFIX"; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    id=${receipt##*/}
    id=${id%"$MERGED_RECEIPT_SUFFIX"}
    if ! fm_pr_task_id_valid "$id"; then
      printf 'DRIFT-CHECK-SKIPPED: merged reconciliation receipt has an invalid task identity\n'
      continue
    fi
    if ! merged_receipt_parse "$id"; then
      printf 'DRIFT-CHECK-SKIPPED: merged reconciliation receipt for %s is invalid\n' "$id"
      PR_CHECKED_IDS="${PR_CHECKED_IDS}${id}"$'\n'
      continue
    fi
    if [ "$TASK_RECEIPT_STAGE" = pending ] \
        && id_in_set "$OPEN_IDS" "$id"; then
      continue
    fi
    if [ "$TASK_RECEIPT_STAGE" = pending ]; then
      [ -n "$done_listing" ] || continue
      done_listing_has_receipt "$done_listing" "$id" "$TASK_PR_URL" "$TASK_RECEIPT_GENERATION" || continue
      completed_generation=$DONE_RECEIPT_GENERATION
    fi
    PR_CHECKED_IDS="${PR_CHECKED_IDS}${id}"$'\n'
    if [ "$RECONCILE" -eq 0 ]; then
      printf 'DRIFT merged-pr-open: %s - completed reconciliation receipt cleanup requires verified mutation authority\n' "$id"
      continue
    fi
    if [ "$TASK_RECEIPT_STAGE" = pending ] \
        && ! merged_receipt_mark_closed "$id" "$completed_generation"; then
      printf 'DRIFT-CHECK-SKIPPED: completed reconciliation receipt for %s could not record closure\n' "$id"
      continue
    fi
    if merged_receipt_remove_closed "$id"; then
      printf 'DRIFT merged-pr-open: %s - completed reconciliation receipt retired\n' "$id"
    else
      printf 'DRIFT-CHECK-SKIPPED: completed reconciliation receipt for %s could not be retired\n' "$id"
    fi
  done
}

auto_close_merged_pr() {  # <id>
  local id=$1
  if [ "$RECONCILE" -eq 0 ]; then
    printf 'DRIFT merged-pr-open: %s - recorded PR is merged; reconciliation requires verified mutation authority\n' "$id"
    return 1
  fi
  if ! merged_receipt_publish "$id"; then
    printf 'DRIFT merged-pr-open: %s - merged reconciliation receipt could not be persisted; task and board item preserved\n' "$id"
    return 1
  fi
  if [ -e "$STATE/$id.meta" ] || [ -L "$STATE/$id.meta" ]; then
    if ! merged_receipt_matches_task "$id"; then
      printf 'DRIFT-CHECK-SKIPPED: merged reconciliation receipt for %s does not match canonical task metadata\n' "$id"
      return 1
    fi
    if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
        FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-teardown.sh" "$id" >/dev/null 2>&1; then
      printf 'DRIFT merged-pr-open: %s - merged PR teardown refused; task and board item preserved\n' "$id"
      return 1
    fi
  fi
  close_merged_board_item "$id"
}

# Discover PR-ready status that missed its lifecycle arming, keep unmerged PRs
# watched, and reconcile the sole auto-fix when the forge returns exact merged.
check_pr_lifecycle() {  # <listing>...
  local listing id current_generation
  for listing in "$@"; do
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      fm_pr_task_id_valid "$id" || continue
      id_in_set "$PR_CHECKED_IDS" "$id" && continue
      PR_CHECKED_IDS="${PR_CHECKED_IDS}${id}"$'\n'
      if [ -e "$(merged_receipt_path "$id")" ] || [ -L "$(merged_receipt_path "$id")" ]; then
        if ! merged_receipt_parse "$id"; then
          printf 'DRIFT-CHECK-SKIPPED: merged reconciliation receipt for %s is invalid\n' "$id"
          continue
        fi
        current_generation=$(board_generation_for "$id") || {
          printf 'DRIFT-CHECK-SKIPPED: board generation for %s is unavailable; reconciliation receipt preserved\n' "$id"
          continue
        }
        if [ -z "$TASK_RECEIPT_GENERATION" ] \
            || [ "$TASK_RECEIPT_GENERATION" != "$current_generation" ]; then
          if [ "$RECONCILE" -eq 1 ] \
              && merged_receipt_retire_stale "$id" "$current_generation"; then
            printf 'DRIFT merged-pr-open: %s - stale reconciliation receipt retired without closing the current board generation\n' "$id"
          else
            printf 'DRIFT merged-pr-open: %s - stale reconciliation receipt does not authorize the current board generation\n' "$id"
          fi
          continue
        fi
        TASK_BOARD_GENERATION=$current_generation
        auto_close_merged_pr "$id" || true
        continue
      fi
      recorded_pr_identity "$id" || continue
      if pr_is_exactly_merged; then
        TASK_BOARD_GENERATION=$(board_generation_for "$id") || {
          printf 'DRIFT-CHECK-SKIPPED: board generation for %s is unavailable; merged reconciliation preserved\n' "$id"
          continue
        }
        auto_close_merged_pr "$id" || true
      else
        ensure_pr_watch "$id"
      fi
    done <<< "$(axi_rows tasks "$listing" rows id)"
  done
}

# An in-flight row whose worker cannot be found at all. bin/fm-crew-state.sh is
# the owner of that verdict: `state: unknown · source: none · <reason>` is its
# one canonical way of saying no current-state source exists for this task.
check_inflight() {  # <in_flight-listing>
  local listing=$1 id verdict reason
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    id_in_set "$AUTO_CLOSED_IDS" "$id" && continue
    verdict=$(crew_verdict_for "$id") || continue
    verdict_has_no_source "$verdict" || continue
    reason=${verdict##*source: none}
    reason=${reason# · }
    [ -n "$reason" ] || reason="no current-state source available"
    printf 'DRIFT inflight-no-worker: %s - %s\n' "$id" "$reason"
  done <<< "$(axi_rows tasks "$listing" rows id)"
}

# Main-board items inside a registered secondmate project need an explicit
# handoff when no local worker owns them. A live local worker makes the row
# clean for this finding even though other board-state checks may still apply.
check_secondmate_scopes() {  # <listing>...
  local listing id repo secondmate verdict
  [ -n "$SECONDMATE_PROJECT_ROWS" ] || return 0
  for listing in "$@"; do
    while IFS=$'\t' read -r id repo; do
      [ -n "$id" ] || continue
      id_in_set "$AUTO_CLOSED_IDS" "$id" && continue
      secondmate=$(secondmate_for_repo "$repo") || continue
      verdict=$(crew_verdict_for "$id") || continue
      verdict_has_no_source "$verdict" || continue
      printf 'DRIFT secondmate-scope-on-main: %s - repo %s is registered to secondmate %s and has no local worker\n' \
        "$id" "$repo" "$secondmate"
    done <<< "$(axi_rows tasks "$listing" rows id repo)"
  done
}

# A current-state source proves the queued item already has a local worker.
check_queued_workers() {  # <queued-listing>
  local listing=$1 id verdict
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    id_in_set "$AUTO_CLOSED_IDS" "$id" && continue
    verdict=$(crew_verdict_for "$id") || continue
    verdict_has_no_source "$verdict" && continue
    printf 'DRIFT queued-has-worker: %s - board says queued but a local worker has a current-state source\n' "$id"
  done <<< "$(axi_rows tasks "$listing" rows id)"
}

# A date-gated hold whose deadline has lapsed.
check_holds() {  # <listing>...
  local listing id hold_until today
  today=$(date +%F)
  for listing in "$@"; do
    while IFS=$'\t' read -r id hold_until; do
      [ -n "$id" ] || continue
      id_in_set "$AUTO_CLOSED_IDS" "$id" && continue
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
  local reason in_flight queued done_receipts= receipt receipt_id receipts_present=0 receipts_need_done=0
  local in_flight_valid=0 queued_valid=0 secondmate_projects_valid=0
  reason=$(board_unavailable_reason)
  if [ -n "$reason" ]; then
    printf 'DRIFT-CHECK-SKIPPED: %s\n' "$reason"
    return 0
  fi

  # One failed listing never suppresses the other's findings: a partial report
  # plus a named skip is more useful than silence.
  local -a hold_listings=() open_listings=()
  if in_flight=$(axi_list in_flight hold_until,created); then
    if axi_rows tasks "$in_flight" rows id hold_until repo created >/dev/null; then
      in_flight_valid=1
      open_listings+=("$in_flight")
      hold_listings+=("$in_flight")
    else
      printf 'DRIFT-CHECK-SKIPPED: tasks-axi list --state in_flight returned an unrecognized listing\n'
    fi
  else
    printf 'DRIFT-CHECK-SKIPPED: tasks-axi list --state in_flight failed\n'
  fi
  if queued=$(axi_list queued hold_until,created); then
    if axi_rows tasks "$queued" rows id hold_until repo created >/dev/null; then
      queued_valid=1
      open_listings+=("$queued")
      hold_listings+=("$queued")
    else
      printf 'DRIFT-CHECK-SKIPPED: tasks-axi list --state queued returned an unrecognized listing\n'
    fi
  else
    printf 'DRIFT-CHECK-SKIPPED: tasks-axi list --state queued failed\n'
  fi
  [ "${#open_listings[@]}" -eq 0 ] || capture_crew_verdicts "${open_listings[@]}"
  for receipt in "$STATE"/*"$MERGED_RECEIPT_SUFFIX"; do
    [ -e "$receipt" ] || [ -L "$receipt" ] || continue
    receipts_present=1
    receipt_id=${receipt##*/}
    receipt_id=${receipt_id%"$MERGED_RECEIPT_SUFFIX"}
    if fm_pr_task_id_valid "$receipt_id" \
        && merged_receipt_parse "$receipt_id" \
        && [ "$TASK_RECEIPT_STAGE" = pending ] \
        && ! id_in_set "$OPEN_IDS" "$receipt_id"; then
      receipts_need_done=1
    fi
  done
  if [ "$receipts_need_done" -eq 1 ]; then
    if done_receipts=$(axi_list done links,created); then
      if ! axi_rows tasks "$done_receipts" rows id links created >/dev/null; then
        printf 'DRIFT-CHECK-SKIPPED: tasks-axi list --state done returned an unrecognized receipt listing\n'
        done_receipts=
      fi
    else
      printf 'DRIFT-CHECK-SKIPPED: tasks-axi list --state done failed during receipt cleanup\n'
      done_receipts=
    fi
  fi
  if [ "$receipts_present" -eq 1 ]; then
    sweep_merged_receipts "$done_receipts"
  fi
  [ "${#open_listings[@]}" -eq 0 ] || check_pr_lifecycle "${open_listings[@]}"
  load_secondmate_projects && secondmate_projects_valid=1
  [ "$in_flight_valid" -eq 0 ] || check_inflight "$in_flight"
  if [ "$secondmate_projects_valid" -eq 1 ] && [ "${#open_listings[@]}" -gt 0 ]; then
    check_secondmate_scopes "${open_listings[@]}"
  fi
  [ "$queued_valid" -eq 0 ] || check_queued_workers "$queued"
  [ "${#hold_listings[@]}" -eq 0 ] || check_holds "${hold_listings[@]}"
  return 0
}

case "$MODE" in
  emit) run_emit ;;
  check) run_check ;;
esac
