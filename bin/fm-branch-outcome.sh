#!/usr/bin/env bash
# fm-branch-outcome.sh - the durable outcome store for the OMP supervision
# branch (docs/omp-supervision-branch.md).
#
# CONTRACT (this header is the one owner of the store's format).
#   - Store: $STATE/branch-outcomes.jsonl, strictly APPEND-ONLY. One JSON
#     object per line: {"seq":N,"epoch":N,"task":"...","wake":"...",
#     "verdict":"routine"|"captain","summary":"...","silent":true|false,
#     "statusEndpoint":N,"statusIdent":"dev:inode"}.
#     statusEndpoint/statusIdent record the exact status-file event span the
#     outcome answers: the granting snapshot's captured endpoint when the task
#     was granted to the branch, else the live file's stable EOF at append
#     time. An outcome never claims events appended after its handling began.
#     Legacy rows without `silent` remain valid and are treated as visible.
#     Existing lines are never rewritten, reordered, or deleted by any
#     subcommand; the read state lives
#     entirely in the cursor sidecar so marking outcomes read cannot disturb
#     the log. Retention: the log is small (one line per handled fleet event)
#     and truncation, if ever needed, is a captain-approved manual act.
#   - Completion delivery ledger: $STATE/completion-deliveries.jsonl, strictly
#     APPEND-ONLY, one {"task":"...","statusIdent":"dev:inode","endpoint":N,
#     "epoch":N} receipt per discharged notification. The completion-delivery
#     contract (docs/omp-supervision-branch.md): every captain-facing status
#     event - a completion, failure, or unkeyed decision - carries one durable
#     notification obligation, identified by task + status-file identity +
#     event byte endpoint, that is discharged ONLY by a receipt here. An
#     outcome covering the event records it (state "recorded"), an uncovered
#     one is "pending"; neither presentation nor a routine verdict retires it.
#     Keyed needs-decision/blocked events are not obligations: the OPEN
#     DECISIONS fold owns them and they close by resolution, not delivery.
#   - Cursor: $STATE/.branch-outcomes-cursor holds the highest seq handed to
#     OMP as an append-only merge note, emitted by the locked session-start
#     replay, or silently consumed there because `silent` is true. Records
#     above the cursor are "unread": the branch stored them but
#     did not reach either handoff. A crash inside OMP's delivery window after
#     cursor advancement does not auto-replay the row; it remains durable and
#     available through the main session's fm_branch_outcomes tool.
#   - Every mutation runs under $STATE/.branch-outcomes.lock so the branch
#     extension and a concurrent session-start replay cannot interleave.
#   - The store is written BEFORE the merge note is appended to main
#     (store-first durability): nothing about a handled event depends on
#     conversation memory.
#
# Usage:
#   fm-branch-outcome.sh append --task <id> --verdict routine|captain \
#       --summary <text> [--wake <text>] [--silent true|false]
#     Append one outcome record; prints the assigned seq.
#   fm-branch-outcome.sh unread
#     Print every unread record (raw JSONL). Exit 0 with no output when none.
#   fm-branch-outcome.sh handoff-next --seq <seq>
#     Advance the cursor for exactly the next unread live-delivery record.
#     Refuse when an earlier unread record exists so live delivery cannot skip
#     a durable outcome that must remain available to startup replay.
#   fm-branch-outcome.sh list [--recent <n>]
#     Print the last n records (default 20), read or not.
#   fm-branch-outcome.sh startup-replay
#     Session-start recovery: print visible unread records under a labeled
#     header into the locked startup digest, skip rows whose `silent` field is
#     true, and mark the valid unread prefix read. A torn record stops replay at
#     its expected sequence with one bounded diagnostic, while earlier valid
#     outcomes are still emitted. Prints nothing when nothing visible is unread,
#     so a home that never ran the branch stays silent. Run it only when the
#     session holds the lock (fm-session-start.sh owns the call site).
#   fm-branch-outcome.sh completions --task <id> --status-ident <dev:inode>
#       [--through <endpoint>] [--from <offset>]
#     Print one "<endpoint><TAB>recorded|pending<TAB><line>" row per
#     undelivered captain-facing event in the span, then a final
#     "bound<TAB>N" row: the delivered frontier, the greatest endpoint such
#     that every obligation event at or before it is delivered. Fails when
#     the status file cannot be read or no longer has the named identity.
#   fm-branch-outcome.sh undelivered
#     Fleet-wide pending scan: print "<task><TAB><ident><TAB><endpoint><TAB>
#     <line>" for every undelivered captain-facing event in every status file.
#   fm-branch-outcome.sh deliver --task <id> --status-ident <dev:inode>
#       --endpoint <endpoint> | --through <endpoint>
#     Record the captain-facing delivery receipt that discharges an
#     obligation. --endpoint marks exactly that event; --through marks every
#     undelivered obligation event at or before it. Idempotent: an already
#     delivered endpoint is reported, never duplicated.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
DELIVERIES="$STATE/completion-deliveries.jsonl"
CURSOR="$STATE/.branch-outcomes-cursor"
LOCK="$STATE/.branch-outcomes.lock"

usage() {
  echo "usage: fm-branch-outcome.sh append --task <id> --verdict routine|captain --summary <text> [--wake <text>] [--silent true|false] | unread | handoff-next --seq <seq> | list [--recent <n>] | startup-replay | completions --task <id> --status-ident <dev:inode> [--through <endpoint>] [--from <offset>] | undelivered | deliver --task <id> --status-ident <dev:inode> --endpoint <endpoint> | deliver --task <id> --status-ident <dev:inode> --through <endpoint>" >&2
  exit 2
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

read_cursor() {
  local value
  value=$(head -n 1 "$CURSOR" 2>/dev/null | tr -cd '0-9' || true)
  printf '%s\n' "${value:-0}"
}

normalize_record() { # <jsonl-line>
  printf '%s\n' "$1" | jq -ec '
    select(type == "object")
    | select(
        keys == ["epoch", "seq", "summary", "task", "verdict", "wake"]
        or (keys == ["epoch", "seq", "silent", "summary", "task", "verdict", "wake"] and (.silent | type) == "boolean")
        or (keys == ["epoch", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "verdict", "wake"]
          and (.silent | type) == "boolean"
          and (.statusEndpoint | type) == "number" and .statusEndpoint >= 0 and .statusEndpoint == (.statusEndpoint | floor)
          and (.statusIdent | type) == "string")
      )
    | select((.seq | type) == "number" and .seq >= 1 and .seq == (.seq | floor))
    | select((.epoch | type) == "number" and .epoch >= 0 and .epoch == (.epoch | floor))
    | select((.task | type) == "string" and (.wake | type) == "string")
    | select((.summary | type) == "string" and (.verdict == "routine" or .verdict == "captain"))
    | if has("statusEndpoint")
      then {seq, epoch, task, wake, verdict, summary, silent, statusEndpoint, statusIdent}
      elif has("silent")
      then {seq, epoch, task, wake, verdict, summary, silent}
      else {seq, epoch, task, wake, verdict, summary}
      end
  '
}

last_seq() {
  local normalized
  [ -s "$STORE" ] || { printf '0\n'; return 0; }
  normalized=$(normalize_record "$(tail -n 1 "$STORE" 2>/dev/null)") || return 1
  printf '%s\n' "$normalized" | jq -r '.seq'
}

record_seq() { # <jsonl-line>
  printf '%s\n' "$1" | sed -n 's/^{"seq":\([0-9]*\),.*/\1/p'
}

print_unread() {
  local cursor seq line
  cursor=$(read_cursor)
  [ -s "$STORE" ] || return 0
  while IFS= read -r line; do
    seq=$(record_seq "$line")
    [ -n "$seq" ] || continue
    [ "$seq" -gt "$cursor" ] || continue
    printf '%s\n' "$line"
  done < "$STORE"
}

advance_cursor() { # <seq>
  local through=$1 cursor tmp
  cursor=$(read_cursor)
  [ "$through" -gt "$cursor" ] || return 0
  tmp=$(mktemp "$STATE/.branch-outcomes-cursor.XXXXXX")
  printf '%s\n' "$through" > "$tmp"
  mv -f -- "$tmp" "$CURSOR"
}

capture_status_position() { # <task>
  local f="$STATE/$1.status" size ident size_after ident_after
  local grant_status="$STATE/.branch-eligible-status" gtask gendpoint gident
  CAPTURED_STATUS_ENDPOINT=0
  CAPTURED_STATUS_IDENT=-
  # A task granted to the branch records the granting snapshot's endpoint, so
  # the outcome claims exactly the event span the branch owned. A live EOF
  # read here would let the outcome cover events appended after the grant that
  # the branch never saw.
  if [ -f "$grant_status" ] && [ ! -L "$grant_status" ]; then
    while IFS=$(printf '\t') read -r gtask gendpoint gident; do
      [ "$gtask" = "$1" ] || continue
      case "$gendpoint" in ''|*[!0-9]*) return 0 ;; esac
      case "$gident" in ''|*:*[!0-9]*|*[!0-9]:*) return 0 ;; esac
      CAPTURED_STATUS_ENDPOINT=$gendpoint
      CAPTURED_STATUS_IDENT=$gident
      return 0
    done < "$grant_status"
  fi
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  size=$(_fm_status_file_size "$f") || return 0; size=${size//[[:space:]]/}
  ident=$(_fm_open_decisions_file_ident "$f") || return 0
  size_after=$(_fm_status_file_size "$f") || return 0; size_after=${size_after//[[:space:]]/}
  ident_after=$(_fm_open_decisions_file_ident "$f") || return 0
  case "$size:$size_after" in *[!0-9:]*) return 0 ;; esac
  [ "$size" = "$size_after" ] && [ "$ident" = "$ident_after" ] || return 0
  CAPTURED_STATUS_ENDPOINT=$size
  CAPTURED_STATUS_IDENT=$ident
}

# Print "<endpoint><TAB><line>" for every captain-facing obligation event in
# the status file's byte span [from, through]. Obligation events are
# captain-relevant lines minus keyed needs-decision/blocked events, which the
# OPEN DECISIONS fold owns and which close by resolution rather than delivery.
# Fails when the file cannot be read as a regular file.
_fm_outcome_events() { # <status-file> <from> <through>
  local f=$1 from=$2 through=$3 span line key pos
  local LC_ALL=C
  case "$from" in ''|*[!0-9]*) from=0 ;; esac
  [ "$through" -gt "$from" ] || return 0
  span=$(_fm_status_read_span "$f" "$from" "$((through - from))") || return 1
  pos=$from
  while :; do
    if IFS= read -r line; then
      pos=$((pos + ${#line} + 1))
    elif [ -n "$line" ]; then
      # An unterminated final line ends at the byte the file ends at; adding a
      # phantom newline would invent an endpoint past EOF that --through then
      # refuses.
      pos=$((pos + ${#line}))
    else
      break
    fi
    case "$line" in *[[:space:]]*[[:alnum:]]*) ;; *) continue ;; esac
    status_is_captain_relevant "$line" || continue
    case "$(status_line_verb "$line")" in
      needs-decision|blocked)
        key=$(_fm_decision_key "$line") || continue
        [ "$key" = default ] || continue
        ;;
    esac
    line=$(printf '%s' "$line" | tr '\t\r' '  ')
    printf '%s\t%s\n' "$pos" "$line"
  done <<EOF
$span
EOF
}

# Print "<task><TAB><ident><TAB><endpoint>" for every delivered obligation
# event. A torn ledger line fails the whole read so callers fail safe.
_fm_outcome_delivered_rows() {
  [ -s "$DELIVERIES" ] || return 0
  jq -r '
    if (type == "object")
       and (.task | type) == "string"
       and (.statusIdent | type) == "string"
       and (.endpoint | type) == "number" and .endpoint >= 0 and .endpoint == (.endpoint | floor)
    then [.task, .statusIdent, (.endpoint | tostring)] | @tsv
    else error("malformed completion delivery record") end
  ' "$DELIVERIES"
}

# Print "<task><TAB><ident><TAB><endpoint>" for the greatest statusEndpoint
# each recorded outcome claims. A torn store line fails the whole read.
_fm_outcome_covered_rows() {
  [ -s "$STORE" ] || return 0
  jq -r '
    if (type == "object")
       and (.task | type) == "string"
       and (.statusIdent | type) == "string"
       and (.statusEndpoint | type) == "number" and .statusEndpoint >= 0 and .statusEndpoint == (.statusEndpoint | floor)
    then [.task, .statusIdent, (.statusEndpoint | tostring)] | @tsv
    else error("malformed branch outcome record") end
  ' "$STORE" | awk -F '\t' '
    { key = $1 "\t" $2
      if (!(key in max) || $3 + 0 > max[key]) max[key] = $3 + 0 }
    END { for (key in max) print key "\t" max[key] }
  '
}

# Print "bound<TAB>N" then one "<endpoint><TAB>recorded|pending<TAB><line>" row
# per undelivered obligation event in [from, through]. bound is the delivered
# frontier: the greatest endpoint such that every obligation event at or
# before it is delivered. Fails when the status file cannot be read or its
# identity no longer matches <ident>.
_fm_outcome_completions() { # <task> <ident> <from> <through>
  local task=$1 ident=$2 from=$3 through=$4
  local f="$STATE/$task.status" live_ident live_size
  local delivered covered events ev_endpoint ev_state ev_line bound gap
  local delivered_keys covered_max dtask dident dendpoint ctask cident cendpoint
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  live_ident=$(_fm_open_decisions_file_ident "$f") || return 1
  [ "$live_ident" = "$ident" ] || return 1
  live_size=$(_fm_status_file_size "$f") || return 1
  live_size=${live_size//[[:space:]]/}
  case "$live_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$live_size" -ge "$through" ] || return 1
  delivered=$(_fm_outcome_delivered_rows) || return 1
  covered=$(_fm_outcome_covered_rows) || return 1
  # Membership is a newline-anchored case lookup (bash 3.2 has no associative
  # arrays); filtered to this task+ident the key is the bare endpoint.
  delivered_keys=
  while IFS=$(printf '\t') read -r dtask dident dendpoint; do
    [ -n "$dtask" ] || continue
    [ "$dtask" = "$task" ] && [ "$dident" = "$ident" ] || continue
    delivered_keys="${delivered_keys}${dendpoint}"$'\n'
  done <<EOF
$delivered
EOF
  covered_max=0
  while IFS=$(printf '\t') read -r ctask cident cendpoint; do
    [ -n "$ctask" ] || continue
    [ "$ctask" = "$task" ] && [ "$cident" = "$ident" ] || continue
    case "$cendpoint" in ''|*[!0-9]*) continue ;; esac
    [ "$cendpoint" -gt "$covered_max" ] && covered_max=$cendpoint
  done <<EOF
$covered
EOF
  events=$(_fm_outcome_events "$f" "$from" "$through") || return 1
  bound=$from
  gap=0
  while IFS=$(printf '\t') read -r ev_endpoint ev_line; do
    [ -n "$ev_endpoint" ] || continue
    case "
$delivered_keys" in
      *$'\n'"$ev_endpoint"$'\n'*)
        # The delivered frontier advances only across a contiguous delivered
        # prefix: a later receipt must never pull bound past an undelivered
        # event, or the next --from scan would skip it.
        [ "$gap" -eq 0 ] && bound=$ev_endpoint
        continue
        ;;
    esac
    gap=1
    ev_state=pending
    [ "$ev_endpoint" -le "$covered_max" ] && ev_state=recorded
    printf '%s\t%s\t%s\n' "$ev_endpoint" "$ev_state" "$ev_line"
  done <<EOF
$events
EOF
  printf 'bound\t%s\n' "$bound"
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    TASK=''
    VERDICT=''
    SUMMARY=''
    WAKE=''
    SILENT=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --verdict) VERDICT=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --silent) SILENT=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    [ -n "$SUMMARY" ] || usage
    case "$VERDICT" in routine|captain) ;; *) usage ;; esac
    case "$SILENT" in true|false) ;; *) usage ;; esac
    fm_lock_acquire_wait "$LOCK"
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome store has a malformed final record" >&2
      exit 1
    fi
    SEQ=$(( LAST_SEQ + 1 ))
    capture_status_position "$TASK"
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s,"statusEndpoint":%s,"statusIdent":"%s"}\n' \
      "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
      "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" "$CAPTURED_STATUS_ENDPOINT" \
      "$(json_escape "$CAPTURED_STATUS_IDENT")" >> "$STORE"
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    print_unread
    fm_lock_release "$LOCK"
    ;;
  handoff-next)
    [ "${1:-}" = --seq ] || usage
    SEQ=${2:-}
    case "$SEQ" in ''|0|0*|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    CURSOR_VALUE=$(read_cursor)
    EXPECTED=$(( CURSOR_VALUE + 1 ))
    NEXT=$(print_unread | sed -n '1p')
    NEXT_NORMALIZED=$(normalize_record "$NEXT" 2>/dev/null || true)
    NEXT_SEQ=$(record_seq "$NEXT_NORMALIZED")
    if [ "$SEQ" != "$EXPECTED" ] || [ "$NEXT_SEQ" != "$SEQ" ]; then
      fm_lock_release "$LOCK"
      echo "error: live outcome handoff refused - seq $SEQ is not the next unread record after cursor $CURSOR_VALUE" >&2
      exit 1
    fi
    advance_cursor "$SEQ"
    fm_lock_release "$LOCK"
    ;;
  list)
    RECENT=20
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    [ -s "$STORE" ] || exit 0
    tail -n "$RECENT" "$STORE"
    ;;
  startup-replay)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    CURSOR_VALUE=$(read_cursor)
    EXPECTED=1
    VALID_UNREAD=
    TORN_SEQUENCE=
    if [ -s "$STORE" ]; then
      while IFS= read -r LINE || [ -n "$LINE" ]; do
        if ! NORMALIZED=$(normalize_record "$LINE" 2>/dev/null); then
          TORN_SEQUENCE=$EXPECTED
          break
        fi
        RECORD_SEQUENCE=$(record_seq "$NORMALIZED")
        if [ "$RECORD_SEQUENCE" != "$EXPECTED" ]; then
          TORN_SEQUENCE=$EXPECTED
          break
        fi
        if [ "$RECORD_SEQUENCE" -gt "$CURSOR_VALUE" ]; then
          if [ -n "$VALID_UNREAD" ]; then
            VALID_UNREAD="$VALID_UNREAD
$NORMALIZED"
          else
            VALID_UNREAD=$NORMALIZED
          fi
        fi
        EXPECTED=$(( EXPECTED + 1 ))
      done < "$STORE"
    fi
    if [ -n "$VALID_UNREAD" ]; then
      VISIBLE=$(printf '%s\n' "$VALID_UNREAD" | jq -c 'select(.silent != true)')
      if [ -n "$VISIBLE" ]; then
        printf 'BRANCH OUTCOMES (handled by the supervision branch, not yet seen by this session):\n'
        printf '%s\n' "$VISIBLE"
      fi
      LAST=$(record_seq "$(printf '%s\n' "$VALID_UNREAD" | tail -n 1)")
      [ -z "$LAST" ] || advance_cursor "$LAST"
    fi
    fm_lock_release "$LOCK"
    if [ -n "$TORN_SEQUENCE" ]; then
      printf 'error: branch outcome startup replay stopped at torn sequence %s; valid earlier outcomes were replayed and later outcomes remain unread\n' "$TORN_SEQUENCE" >&2
      exit 1
    fi
    ;;
  completions)
    TASK=''
    IDENT=''
    THROUGH=''
    FROM=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --status-ident) IDENT=${2:-}; shift 2 || usage ;;
        --through) THROUGH=${2:-}; shift 2 || usage ;;
        --from) FROM=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] && [ -n "$IDENT" ] || usage
    case "$FROM" in ''|*[!0-9]*) usage ;; esac
    F="$STATE/$TASK.status"
    if [ -z "$THROUGH" ]; then
      THROUGH=$(_fm_status_file_size "$F" 2>/dev/null) || usage
      THROUGH=${THROUGH//[[:space:]]/}
    fi
    case "$THROUGH" in ''|*[!0-9]*) usage ;; esac
    _fm_outcome_completions "$TASK" "$IDENT" "$FROM" "$THROUGH"
    ;;
  undelivered)
    [ "$#" -eq 0 ] || usage
    DELIVERED=$(_fm_outcome_delivered_rows) || {
      echo "error: completion delivery ledger is malformed; refusing to classify" >&2
      exit 1
    }
    for F in "$STATE"/*.status; do
      [ -e "$F" ] || continue
      [ -f "$F" ] && [ -r "$F" ] && [ ! -L "$F" ] || continue
      TASK=$(basename "$F" .status)
      IDENT=$(_fm_open_decisions_file_ident "$F") || continue
      SIZE=$(_fm_status_file_size "$F") || continue
      SIZE=${SIZE//[[:space:]]/}
      case "$SIZE" in ''|*[!0-9]*) continue ;; esac
      # Newline-anchored case membership (bash 3.2): the delivered key is
      # task|ident|endpoint.
      DELIVERED_KEYS=
      while IFS=$(printf '\t') read -r DTASK DIDENT DENDPOINT; do
        [ -n "$DTASK" ] || continue
        [ "$DTASK" = "$TASK" ] && [ "$DIDENT" = "$IDENT" ] || continue
        DELIVERED_KEYS="${DELIVERED_KEYS}${DENDPOINT}"$'\n'
      done <<EOF
$DELIVERED
EOF
      EVENTS=$(_fm_outcome_events "$F" 0 "$SIZE") || continue
      while IFS=$(printf '\t') read -r EV_ENDPOINT EV_LINE; do
        [ -n "$EV_ENDPOINT" ] || continue
        case "
$DELIVERED_KEYS" in
          *$'\n'"$EV_ENDPOINT"$'\n'*) continue ;;
        esac
        printf '%s\t%s\t%s\t%s\n' "$TASK" "$IDENT" "$EV_ENDPOINT" "$EV_LINE"
      done <<EOF
$EVENTS
EOF
    done
    ;;
  deliver)
    TASK=''
    IDENT=''
    ENDPOINT=''
    THROUGH=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --status-ident) IDENT=${2:-}; shift 2 || usage ;;
        --endpoint) ENDPOINT=${2:-}; shift 2 || usage ;;
        --through) THROUGH=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] && [ -n "$IDENT" ] || usage
    case "$IDENT" in ''|*[!0-9:]*|*:*:*) usage ;; esac
    case "${IDENT%%:*}" in ''|*[!0-9]*) usage ;; esac
    case "${IDENT##*:}" in ''|*[!0-9]*) usage ;; esac
    if [ -n "$ENDPOINT" ] && [ -n "$THROUGH" ]; then usage; fi
    [ -n "$ENDPOINT$THROUGH" ] || usage
    if [ -n "$ENDPOINT" ]; then case "$ENDPOINT" in *[!0-9]*) usage ;; esac; fi
    if [ -n "$THROUGH" ]; then case "$THROUGH" in *[!0-9]*) usage ;; esac; fi
    fm_lock_acquire_wait "$LOCK"
    # A torn ledger must refuse new receipts: appending a valid line after a
    # malformed one would leave every later read failing, so the receipt would
    # never discharge the obligation it records.
    if ! DELIVERED=$(_fm_outcome_delivered_rows); then
      fm_lock_release "$LOCK"
      echo "error: completion delivery ledger is malformed; refusing to record a receipt" >&2
      exit 1
    fi
    DELIVERED_KEYS=
    while IFS=$(printf '\t') read -r DTASK DIDENT DENDPOINT; do
      [ -n "$DTASK" ] || continue
      [ "$DTASK" = "$TASK" ] && [ "$DIDENT" = "$IDENT" ] || continue
      DELIVERED_KEYS="${DELIVERED_KEYS}${DENDPOINT}"$'\n'
    done <<EOF
$DELIVERED
EOF
    MARKED=0
    if [ -n "$THROUGH" ]; then
      # --through marks every undelivered obligation event at or before it, so
      # the status file must still be the named identity and readable.
      F="$STATE/$TASK.status"
      if [ ! -f "$F" ] || [ -L "$F" ] || [ ! -r "$F" ]; then
        fm_lock_release "$LOCK"
        echo "error: cannot mark $TASK through $THROUGH: status file is missing or unreadable" >&2
        exit 1
      fi
      LIVE_IDENT=$(_fm_open_decisions_file_ident "$F") || LIVE_IDENT=
      if [ "$LIVE_IDENT" != "$IDENT" ]; then
        fm_lock_release "$LOCK"
        echo "error: cannot mark $TASK through $THROUGH: status file identity changed; re-drain for the current receipt identity" >&2
        exit 1
      fi
      LIVE_SIZE=$(_fm_status_file_size "$F") || LIVE_SIZE=
      LIVE_SIZE=${LIVE_SIZE//[[:space:]]/}
      case "$LIVE_SIZE" in ''|*[!0-9]*) LIVE_SIZE=0 ;; esac
      if [ "$LIVE_SIZE" -lt "$THROUGH" ]; then
        fm_lock_release "$LOCK"
        echo "error: cannot mark $TASK through $THROUGH: status file is shorter than the receipt endpoint" >&2
        exit 1
      fi
      EVENTS=$(_fm_outcome_events "$F" 0 "$THROUGH") || {
        fm_lock_release "$LOCK"
        echo "error: cannot mark $TASK through $THROUGH: status file could not be read" >&2
        exit 1
      }
      while IFS=$(printf '\t') read -r EV_ENDPOINT EV_LINE; do
        [ -n "$EV_ENDPOINT" ] || continue
        case "
$DELIVERED_KEYS" in
          *$'\n'"$EV_ENDPOINT"$'\n'*) continue ;;
        esac
        printf '{"task":"%s","statusIdent":"%s","endpoint":%s,"epoch":%s}\n' \
          "$(json_escape "$TASK")" "$(json_escape "$IDENT")" "$EV_ENDPOINT" "$(date +%s)" >> "$DELIVERIES"
        MARKED=$((MARKED + 1))
      done <<EOF
$EVENTS
EOF
    else
      # --endpoint records the receipt unconditionally: the obligation is
      # keyed by identity, so a rotated or replaced status file leaves the
      # marker inert rather than wrong. When the file is still the named
      # identity, a non-event endpoint is a caller error worth refusing.
      F="$STATE/$TASK.status"
      if [ -f "$F" ] && [ ! -L "$F" ] && [ -r "$F" ]; then
        LIVE_IDENT=$(_fm_open_decisions_file_ident "$F" 2>/dev/null) || LIVE_IDENT=
        if [ "$LIVE_IDENT" = "$IDENT" ]; then
          LIVE_SIZE=$(_fm_status_file_size "$F" 2>/dev/null) || LIVE_SIZE=0
          LIVE_SIZE=${LIVE_SIZE//[[:space:]]/}
          case "$LIVE_SIZE" in ''|*[!0-9]*) LIVE_SIZE=0 ;; esac
          EVENTS=$(_fm_outcome_events "$F" 0 "$LIVE_SIZE" 2>/dev/null) || EVENTS=
          EVENT_MATCH=0
          while IFS=$(printf '\t') read -r EV_ENDPOINT EV_LINE; do
            [ "$EV_ENDPOINT" = "$ENDPOINT" ] && EVENT_MATCH=1
          done <<EOF
$EVENTS
EOF
          if [ "$EVENT_MATCH" -eq 0 ]; then
            fm_lock_release "$LOCK"
            echo "error: $ENDPOINT is not a captain-facing event endpoint in $TASK.status" >&2
            exit 1
          fi
        fi
      fi
      case "
$DELIVERED_KEYS" in
        *$'\n'"$ENDPOINT"$'\n'*) ;;
        *)
          printf '{"task":"%s","statusIdent":"%s","endpoint":%s,"epoch":%s}\n' \
            "$(json_escape "$TASK")" "$(json_escape "$IDENT")" "$ENDPOINT" "$(date +%s)" >> "$DELIVERIES"
          MARKED=1
          ;;
      esac
    fi
    fm_lock_release "$LOCK"
    printf 'delivered: %s receipt(s) recorded for %s\n' "$MARKED" "$TASK"
    ;;
  *) usage ;;
esac
