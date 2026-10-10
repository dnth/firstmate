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
#   - Typed advisory identity (issue #74): new records carry
#     "advisory":{"kind":"decision|worker|status|fleet|pause","key":"..." or
#     "-","gen":"<producer generation>","wakeSeqs":"<n,n,..>" or "-"}. kind is
#     supplied by the producer (a stale wake reports worker) or derived from
#     the covered span: the span's last structured event being a keyed
#     needs-decision/blocked yields decision + that key; fleet-scope yields
#     fleet; anything else status. key is meaningful only for decision. gen is
#     the branch producer's own generation token - deliberately a different
#     axis from the branch-process generation and the watcher-recovery
#     generation. statusEndpoint/statusIdent remain the source status-log
#     revision; wakeSeqs records the granted wake-row sequences. Legacy rows
#     without `advisory` remain valid and are treated as always-current.
#   - Merge delivery ledger: $STATE/branch-merge-deliveries.jsonl, strictly
#     APPEND-ONLY, one {"seq":N,"state":"accepted|failed|suppressed",
#     "epoch":N} receipt per merge-note delivery attempt, keyed by the durable
#     seq (the idempotent delivery token). `accepted` = sendMessage accepted
#     the note; `failed` = it provably threw before acceptance, so the row is
#     replayable WHILE ITS ADVISORY IS STILL CURRENT OR ITS COVERED SPAN STILL
#     OWES A COMPLETION; `suppressed` = the delivery boundary retired the row
#     after reconciliation. A cursor-
#     advanced row with no receipt is indeterminate - possibly delivered - and
#     is never replayed, matching the buffer's accepted-but-unconfirmed rule.
#   - Delivery-boundary reconcile (issue #74): `reconcile` answers whether the
#     advisory recorded on a seq is still current. The live merge runs the
#     cursor handoff FIRST, then reconciles, then sends with no further
#     awaited operation between them (issue #188), and replay applies the same
#     ordering; provably obsolete advisories are suppressed before the note
#     can enter main's queue: a pending-decision advisory whose key has closed
#     under the shared fold, a stopped-worker advisory whose status file has
#     moved past its captured revision, a pause advisory whose hold ended, or
#     one whose status file is gone. A replayed row first rebuilds its covered
#     span's undelivered completion obligations through `completions` on the
#     stored statusEndpoint/statusIdent pair, and a nonempty result bypasses
#     the reconcile entirely - the owed event is a fact, not advisory prose.
#     fm-classify-lib.sh's
#     fm_advisory_superseded is the single owner of the freshness rule, shared
#     with the away daemon's escalation-buffer reconcile.
#   - Cursor: $STATE/.branch-outcomes-cursor holds the highest seq handed to
#     OMP as an append-only merge note, retired by delivery-time suppression,
#     emitted by the locked session-start
#     replay, or silently consumed there because `silent` is true or the
#     replay's freshness gate found the row superseded. Records
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
#     obligation. --endpoint marks exactly that event and still records after
#     the status file is gone (teardown, merge reconciliation), so it is the
#     form the wake drain's backstop prints; --through marks every
#     undelivered obligation event at or before it and refuses unless the
#     live status file still has the named identity. Idempotent: an already
#     delivered endpoint is reported, never duplicated.
#   fm-branch-outcome.sh reconcile --seq <seq>
#     Print "current" when the seq's advisory is still deliverable, or
#     "suppressed" when current durable state provably supersedes it. Missing
#     seqs and rows without a typed advisory are "current" (fail-open).
#   fm-branch-outcome.sh repeat-prior --seq <seq>
#     Print "repeat" when seq N is a routine outcome whose (task, verdict,
#     statusIdent, statusEndpoint) matches the task's previously stored
#     outcome - the caller then merges it silently instead of re-rendering.
#     Anything else prints "current". Read-only under the store lock.
#   fm-branch-outcome.sh merge-receipt --seq <seq> --state accepted|failed|suppressed
#     Append one merge-delivery receipt to the merge ledger.
#   fm-branch-outcome.sh merge-replay
#     Print the normalized store rows whose newest merge receipt is "failed":
#     the replayable set. The caller re-reconciles each before resending.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

STORE="$STATE/branch-outcomes.jsonl"
DELIVERIES="$STATE/completion-deliveries.jsonl"
MERGE_DELIVERIES="$STATE/branch-merge-deliveries.jsonl"
CURSOR="$STATE/.branch-outcomes-cursor"
LOCK="$STATE/.branch-outcomes.lock"

usage() {
  echo "usage: fm-branch-outcome.sh append --task <id> --verdict routine|captain --summary <text> [--wake <text>] [--silent true|false] [--advisory-kind <kind>] [--advisory-key <key>] [--advisory-gen <gen>] [--advisory-wake-seqs <n,n,..>] | unread | handoff-next --seq <seq> | list [--recent <n>] | startup-replay | completions --task <id> --status-ident <dev:inode> [--through <endpoint>] [--from <offset>] | undelivered | deliver --task <id> --status-ident <dev:inode> --endpoint <endpoint> | deliver --task <id> --status-ident <dev:inode> --through <endpoint> | reconcile --seq <seq> | repeat-prior --seq <seq> | merge-receipt --seq <seq> --state accepted|failed|suppressed | merge-replay" >&2
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
        or (keys == ["advisory", "epoch", "seq", "silent", "statusEndpoint", "statusIdent", "summary", "task", "verdict", "wake"]
          and (.silent | type) == "boolean"
          and (.statusEndpoint | type) == "number" and .statusEndpoint >= 0 and .statusEndpoint == (.statusEndpoint | floor)
          and (.statusIdent | type) == "string"
          and (.advisory | type) == "object"
          and (.advisory.kind | type) == "string"
          and (.advisory.key | type) == "string"
          and (.advisory.gen | type) == "string"
          and (.advisory.wakeSeqs | type) == "string")
      )
    | select((.seq | type) == "number" and .seq >= 1 and .seq == (.seq | floor))
    | select((.epoch | type) == "number" and .epoch >= 0 and .epoch == (.epoch | floor))
    | select((.task | type) == "string" and (.wake | type) == "string")
    | select((.summary | type) == "string" and (.verdict == "routine" or .verdict == "captain"))
    | if has("advisory")
      then {seq, epoch, task, wake, verdict, summary, silent, statusEndpoint, statusIdent, advisory}
      elif has("statusEndpoint")
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

# Derive a task-scoped outcome's advisory kind from the status span it answers
# (issue #74). When the last structured event at-or-before <endpoint> is a
# keyed needs-decision/blocked, the outcome is a pending-decision advisory for
# that key - so a later resolution can retire it before delivery. Anything
# else stays a plain event advisory. Sets ADVISORY_KIND/ADVISORY_KEY on
# derivation; a missing, unreadable, or rotated file derives nothing.
_fm_outcome_derive_advisory() { # <task> <endpoint> <ident>
  local task=$1 endpoint=$2 ident=$3 f live_ident span_file line pos
  local LC_ALL=C
  local dec_pos=-1 dec_key=- last_pos=-1 verb k
  f="$STATE/$task.status"
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  live_ident=$(_fm_open_decisions_file_ident "$f") || return 0
  [ "$live_ident" = "$ident" ] || return 0
  case "$endpoint" in ''|*[!0-9]*|0) return 0 ;; esac
  span_file=$(mktemp "$STATE/.branch-outcome-span.XXXXXX") || return 0
  if ! _fm_status_read_span "$f" 0 "$endpoint" > "$span_file"; then
    rm -f -- "$span_file"
    return 0
  fi
  pos=0
  while IFS= read -r line; do
    pos=$((pos + ${#line} + 1))
    case "$line" in *[[:space:]]*[[:alnum:]]*) ;; *) continue ;; esac
    verb=$(status_line_verb "$line")
    case "$verb" in
      needs-decision|blocked)
        last_pos=$pos
        k=$(_fm_decision_key "$line") || k=
        case "$k" in ''|default) ;; *) dec_pos=$pos; dec_key=$k ;; esac
        ;;
      working|done|failed|paused|resolved|"${FM_CLASSIFY_CAPTAIN_HELD_VERB:-captain-held}")
        last_pos=$pos
        ;;
    esac
  done < "$span_file"
  rm -f -- "$span_file"
  if [ "$dec_pos" -ge 0 ] && [ "$dec_pos" -eq "$last_pos" ]; then
    ADVISORY_KIND=decision
    ADVISORY_KEY=$dec_key
  fi
  return 0
}

# Delivery-boundary freshness for one stored outcome row (issue #74): 0 when
# the row's typed advisory is provably superseded by current durable state.
# Rows without a typed advisory, and reconcile-time read failures, keep the
# historical always-deliver behavior (fail-open).
_fm_outcome_row_superseded() { # <normalized-json-row>
  local row=$1 task kind key endpoint ident
  kind=$(printf '%s' "$row" | jq -r '.advisory.kind // ""' 2>/dev/null) || return 1
  [ -n "$kind" ] || return 1
  task=$(printf '%s' "$row" | jq -r '.task // ""' 2>/dev/null) || return 1
  [ -n "$task" ] || return 1
  key=$(printf '%s' "$row" | jq -r '.advisory.key // "-"' 2>/dev/null) || key=-
  endpoint=$(printf '%s' "$row" | jq -r '.statusEndpoint // 0' 2>/dev/null) || endpoint=0
  ident=$(printf '%s' "$row" | jq -r '.statusIdent // "-"' 2>/dev/null) || ident=-
  fm_advisory_superseded "$STATE" "$task" "$kind" "$key" "$endpoint" "$ident"
}

# Identical-repeat check for one ordered pair of stored outcome rows (relay
# fix rank 2): 0 when the newer row is a routine, completion-free repeat of
# the older - same task, verdict, statusIdent, and statusEndpoint. Completion
# obligations are NOT compared here; the caller only consults this when its
# own completions scan is already empty, so an owed event always forces
# delivery regardless of this verdict. Fail-closed shape inverted on purpose:
# any unreadable field returns 1 (current, render), never silent.
_fm_outcome_is_identical_repeat() { # <prev-normalized-row> <row-normalized-row>
  local prev=$1 row=$2 ptask pverdict pident pendpoint rtask rverdict rident rendpoint
  ptask=$(printf '%s' "$prev" | jq -r '.task // ""' 2>/dev/null) || return 1
  rtask=$(printf '%s' "$row" | jq -r '.task // ""' 2>/dev/null) || return 1
  [ -n "$ptask" ] && [ "$ptask" = "$rtask" ] || return 1
  pverdict=$(printf '%s' "$prev" | jq -r '.verdict // ""' 2>/dev/null) || return 1
  rverdict=$(printf '%s' "$row" | jq -r '.verdict // ""' 2>/dev/null) || return 1
  [ "$rverdict" = routine ] && [ "$pverdict" = routine ] || return 1
  pident=$(printf '%s' "$prev" | jq -r '.statusIdent // "-"' 2>/dev/null) || return 1
  rident=$(printf '%s' "$row" | jq -r '.statusIdent // "-"' 2>/dev/null) || return 1
  [ "$pident" != "-" ] && [ "$pident" = "$rident" ] || return 1
  pendpoint=$(printf '%s' "$prev" | jq -r '.statusEndpoint // empty' 2>/dev/null) || return 1
  rendpoint=$(printf '%s' "$row" | jq -r '.statusEndpoint // empty' 2>/dev/null) || return 1
  case "$pendpoint" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pendpoint" = "$rendpoint" ] || return 1
  return 0
}

# Print "<endpoint><TAB><line>" for every captain-facing obligation event in
# the status file's byte span [from, through]. Obligation events are
# captain-relevant lines minus keyed needs-decision/blocked events, which the
# OPEN DECISIONS fold owns and which close by resolution rather than delivery.
# Fails when the file cannot be read as a regular file.
_fm_outcome_events() { # <status-file> <from> <through>
  local f=$1 from=$2 through=$3 span_file line key pos
  local LC_ALL=C
  case "$from" in ''|*[!0-9]*) from=0 ;; esac
  [ "$through" -gt "$from" ] || return 0
  span_file=$(mktemp "$STATE/.branch-outcome-span.XXXXXX") || return 1
  if ! _fm_status_read_span "$f" "$from" "$((through - from))" > "$span_file"; then
    rm -f -- "$span_file"
    return 1
  fi
  pos=$from
  while IFS= read -r line; do
    pos=$((pos + ${#line} + 1))
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
  done < "$span_file"
  if [ -n "$line" ] && [ "$(tail -c 1 "$span_file" | od -An -tx1 | tr -d '[:space:]')" != 0a ]; then
    pos=$((pos + ${#line}))
    case "$line" in *[[:space:]]*[[:alnum:]]*) ;; *) rm -f -- "$span_file"; return 0 ;; esac
    status_is_captain_relevant "$line" || { rm -f -- "$span_file"; return 0; }
    case "$(status_line_verb "$line")" in
      needs-decision|blocked)
        key=$(_fm_decision_key "$line") || { rm -f -- "$span_file"; return 0; }
        [ "$key" = default ] || { rm -f -- "$span_file"; return 0; }
        ;;
    esac
    line=$(printf '%s' "$line" | tr '\t\r' '  ')
    printf '%s\t%s\n' "$pos" "$line"
  fi
  rm -f -- "$span_file"
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
    ADVISORY_KIND=''
    ADVISORY_KEY='-'
    ADVISORY_ENDPOINT=''
    ADVISORY_IDENT=''
    ADVISORY_GEN='-'
    ADVISORY_WAKE_SEQS='-'
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --task) TASK=${2:-}; shift 2 || usage ;;
        --verdict) VERDICT=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --wake) WAKE=${2:-}; shift 2 || usage ;;
        --silent) SILENT=${2:-}; shift 2 || usage ;;
        --advisory-kind) ADVISORY_KIND=${2:-}; shift 2 || usage ;;
        --advisory-key) ADVISORY_KEY=${2:-}; shift 2 || usage ;;
        --advisory-endpoint) ADVISORY_ENDPOINT=${2:-}; shift 2 || usage ;;
        --advisory-ident) ADVISORY_IDENT=${2:-}; shift 2 || usage ;;
        --advisory-gen) ADVISORY_GEN=${2:-}; shift 2 || usage ;;
        --advisory-wake-seqs) ADVISORY_WAKE_SEQS=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$TASK" ] || usage
    [ -n "$SUMMARY" ] || usage
    case "$VERDICT" in routine|captain) ;; *) usage ;; esac
    case "$SILENT" in true|false) ;; *) usage ;; esac
    fm_lock_acquire_wait "$LOCK" || exit 1
    if ! LAST_SEQ=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the outcome store has a malformed final record" >&2
      exit 1
    fi
    SEQ=$(( LAST_SEQ + 1 ))
    if [ -n "${ADVISORY_ENDPOINT:-}" ] || [ -n "${ADVISORY_IDENT:-}" ]; then
      case "${ADVISORY_ENDPOINT:-}" in ''|*[!0-9]*) fm_lock_release "$LOCK"; usage ;; esac
      [[ "${ADVISORY_IDENT:-}" =~ ^[0-9]+:[0-9]+$ ]] || { fm_lock_release "$LOCK"; usage; }
      CAPTURED_STATUS_ENDPOINT=$ADVISORY_ENDPOINT
      CAPTURED_STATUS_IDENT=$ADVISORY_IDENT
    else
      capture_status_position "$TASK"
    fi
    # Typed advisory identity (issue #74): an explicit producer kind wins;
    # otherwise derive it from the covered span (a trailing keyed decision is a
    # pending-decision advisory, fleet-scope is fleet, the rest a plain event).
    # The advisory's source revision is the captured statusEndpoint/statusIdent.
    case "$ADVISORY_KIND" in
      decision|worker|status|fleet|pause) ;;
      ''|auto)
        if [ "$TASK" = fleet ]; then
          ADVISORY_KIND=fleet
        else
          ADVISORY_KIND=status
          ADVISORY_KEY=-
          _fm_outcome_derive_advisory "$TASK" "$CAPTURED_STATUS_ENDPOINT" "$CAPTURED_STATUS_IDENT"
        fi
        ;;
      *) echo "error: --advisory-kind must be decision, worker, status, fleet, pause, or auto" >&2
         fm_lock_release "$LOCK"; exit 2 ;;
    esac
    case "$ADVISORY_KIND" in decision) ;; *) ADVISORY_KEY=- ;; esac
    [ -n "$ADVISORY_KEY" ] || ADVISORY_KEY=-
    [ -n "$ADVISORY_GEN" ] || ADVISORY_GEN=-
    case "$ADVISORY_WAKE_SEQS" in ''|*[!0-9,]*) ADVISORY_WAKE_SEQS=- ;; esac
    printf '{"seq":%s,"epoch":%s,"task":"%s","wake":"%s","verdict":"%s","summary":"%s","silent":%s,"statusEndpoint":%s,"statusIdent":"%s","advisory":{"kind":"%s","key":"%s","gen":"%s","wakeSeqs":"%s"}}\n' \
      "$SEQ" "$(date +%s)" "$(json_escape "$TASK")" "$(json_escape "$WAKE")" \
      "$VERDICT" "$(json_escape "$SUMMARY")" "$SILENT" "$CAPTURED_STATUS_ENDPOINT" \
      "$(json_escape "$CAPTURED_STATUS_IDENT")" \
      "$(json_escape "$ADVISORY_KIND")" "$(json_escape "$ADVISORY_KEY")" \
      "$(json_escape "$ADVISORY_GEN")" "$(json_escape "$ADVISORY_WAKE_SEQS")" >> "$STORE"
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK" || exit 1
    print_unread
    fm_lock_release "$LOCK"
    ;;
  handoff-next)
    [ "${1:-}" = --seq ] || usage
    SEQ=${2:-}
    case "$SEQ" in ''|0|0*|*[!0-9]*) usage ;; esac
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK" || exit 1
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
    fm_lock_acquire_wait "$LOCK" || exit 1
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
      # Freshness gate (issue #74): an unread row whose typed advisory is
      # provably superseded by current durable state is consumed silently like
      # a `silent` row - replaying its prose would inject a stale advisory.
      CURRENT_UNREAD=
      while IFS= read -r UROW; do
        [ -n "$UROW" ] || continue
        if _fm_outcome_row_superseded "$UROW"; then
          continue
        fi
        if [ -n "$CURRENT_UNREAD" ]; then
          CURRENT_UNREAD="$CURRENT_UNREAD
$UROW"
        else
          CURRENT_UNREAD=$UROW
        fi
      done <<EOF
$VALID_UNREAD
EOF
      VISIBLE=$(printf '%s\n' "$CURRENT_UNREAD" | jq -c 'select(.silent != true)')
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
    fm_lock_acquire_wait "$LOCK" || exit 1
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
  reconcile)
    [ "${1:-}" = --seq ] && [ "$#" -eq 2 ] || usage
    SEQ=$2
    case "$SEQ" in ''|0|0*|*[!0-9]*) usage ;; esac
    fm_lock_acquire_wait "$LOCK" || exit 1
    RROW=
    if [ -s "$STORE" ]; then
      while IFS= read -r LINE || [ -n "$LINE" ]; do
        if [ "$(record_seq "$LINE")" = "$SEQ" ]; then
          RROW=$(normalize_record "$LINE" 2>/dev/null) || RROW=
          break
        fi
      done < "$STORE"
    fi
    fm_lock_release "$LOCK"
    if [ -n "$RROW" ] && _fm_outcome_row_superseded "$RROW"; then
      printf 'suppressed\n'
    else
      printf 'current\n'
    fi
    ;;
  repeat-prior)
    # Identical-repeat check (relay-noise fix): print "repeat" when seq N is a
    # routine outcome with no completion obligation whose (task, statusIdent,
    # statusEndpoint, verdict) matches the task's previously stored outcome -
    # the caller then merges it silently instead of re-rendering. Anything
    # else prints "current". Reads the append-only store under the same lock;
    # never writes.
    [ "${1:-}" = --seq ] && [ "$#" -eq 2 ] || usage
    SEQ=$2
    case "$SEQ" in ''|0|0*|*[!0-9]*) usage ;; esac
    fm_lock_acquire_wait "$LOCK" || exit 1
    RROW=
    RTASK=
    PROW=
    NORM=
    if [ -s "$STORE" ]; then
      while IFS= read -r LINE || [ -n "$LINE" ]; do
        NORM=$(normalize_record "$LINE" 2>/dev/null) || continue
        if [ "$(record_seq "$NORM")" = "$SEQ" ]; then
          RROW=$NORM
          RTASK=$(printf '%s' "$NORM" | jq -r '.task // ""' 2>/dev/null) || RTASK=
        elif [ -n "$RROW" ]; then
          break
        else
          NTASK=$(printf '%s' "$NORM" | jq -r '.task // ""' 2>/dev/null) || NTASK=
          # Track the latest row; the helper re-checks task equality, so a
          # neighbour task can never silence this row - it only decides which
          # candidate the helper compares.
          case "$NTASK" in '') ;; *) PROW=$NORM ;; esac
        fi
      done < "$STORE"
    fi
    [ -n "$RTASK" ] || PROW=
    fm_lock_release "$LOCK"
    if [ -z "$RROW" ] || [ -z "$PROW" ]; then
      printf 'current\n'
    elif _fm_outcome_is_identical_repeat "$PROW" "$RROW"; then
      printf 'repeat\n'
    else
      printf 'current\n'
    fi
    ;;
  merge-receipt)
    [ "${1:-}" = --seq ] && [ "${3:-}" = --state ] && [ "$#" -eq 4 ] || usage
    SEQ=$2
    RSTATE=$4
    case "$SEQ" in ''|0|0*|*[!0-9]*) usage ;; esac
    case "$RSTATE" in accepted|failed|suppressed) ;; *) usage ;; esac
    fm_lock_acquire_wait "$LOCK" || exit 1
    printf '{"seq":%s,"state":"%s","epoch":%s}\n' "$SEQ" "$RSTATE" "$(date +%s)" \
      >> "$MERGE_DELIVERIES" || {
      fm_lock_release "$LOCK"
      echo "error: merge delivery ledger append failed" >&2
      exit 1
    }
    fm_lock_release "$LOCK"
    ;;
  merge-replay)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK" || exit 1
    # The replayable set: seqs whose newest merge-delivery receipt is
    # "failed" - provably not accepted into main's queue. Rows with no receipt
    # at all are indeterminate (possibly delivered) and never replayed.
    FAILED_SEQS=
    if [ -s "$MERGE_DELIVERIES" ]; then
      FAILED_SEQS=$(awk '
        /^\{"seq":[0-9]+,"state":"(accepted|failed|suppressed)"/ {
          seq=$0; sub(/^\{"seq":/, "", seq); sub(/,.*/, "", seq)
          st=$0; sub(/^.*"state":"/, "", st); sub(/".*/, "", st)
          last[seq]=st
        }
        END { for (s in last) if (last[s] == "failed") print s }
      ' "$MERGE_DELIVERIES" 2>/dev/null | LC_ALL=C sort -n || true)
    fi
    if [ -n "$FAILED_SEQS" ] && [ -s "$STORE" ]; then
      while IFS= read -r RSEQ; do
        [ -n "$RSEQ" ] || continue
        while IFS= read -r LINE || [ -n "$LINE" ]; do
          if [ "$(record_seq "$LINE")" = "$RSEQ" ]; then
            normalize_record "$LINE" 2>/dev/null || true
            break
          fi
        done < "$STORE"
      done <<EOF
$FAILED_SEQS
EOF
    fi
    fm_lock_release "$LOCK"
    ;;
  *) usage ;;
esac
