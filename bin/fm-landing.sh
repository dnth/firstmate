#!/usr/bin/env bash
# fm-landing.sh - main-owned landing records for a remote second mate's PRs.
#
# docs/remote-secondmates.md#landing-owner owns the remote PR landing lifecycle.
# Merge authority is unchanged and lives in .agents/skills/ship-landing/SKILL.md.
#
# Usage:
#   fm-landing.sh register <secondmate-id> <pr-url>
#       File (or find) the landing record for the PR and arm its merge poll.
#       Idempotent. Prints `landing: <landing-id>`. Refuses an id that is not a
#       registered remote second mate and any URL that is not a canonical PR.
#       A first report of a merged or closed PR settles immediately.
#       A durable per-URL settled marker makes subsequent reports no-ops.
#   fm-landing.sh ingest <secondmate-id> <status-line>
#       What the reply relay calls for every accepted line from a remote mate: a
#       `done` line reporting `PR <url>` files the landing (register), and the
#       custody line below also records custody on it. Other lines do nothing.
#   fm-landing.sh report <task-id>
#       Mate side. bin/fm-pr-check.sh calls it after its PR-ready gates pass; in a
#       remote second mate's home it appends one custody line to
#       state/parent-replies.status naming the validated PR head, No-Mistakes run,
#       mode, whether the acceptance evidence was complete, and any
#       accepted-blocked criterion ids; elsewhere it does nothing.
#   fm-landing.sh rearm <landing-id> <pr-url>
#       Re-arm the poll of an existing record (what bin/fm-pr-check.sh does for
#       a landing id, so bin/fm-pr-merge.sh works on one unchanged).
#   fm-landing.sh sweep [--report]
#       Ask the forge about every landing record. A merged PR, or a PR closed
#       without merging (GitHub), is settled; with --report each such record is
#       only printed as `DRIFT landing-<merged|closed>: <id> - <reason>`.
#       bin/fm-todo-project.sh runs this under --check --reconcile, which the
#       merged-PR check wake already triggers.
#   fm-landing.sh settle <landing-id> <merged|closed>
#       Finish a landed or closed PR: on merge refresh the project's clone through bin/fm-fleet-sync.sh (best effort), tell the second mate through bin/fm-send.sh so it can close its own row, then retire the poll and the record.
#       A mate that cannot be told keeps the record for identity-bound delivery retry.
#       Delivered notices, durable requests, and unknown completion after delivery are never resent; pre-delivery refusals keep the record without writing a settled marker.
#       Diagnostics remain visible.
#       Failed or skipped clone refreshes are reported in the settlement output.
#
# Record: state/land-<secondmate-id>-<number>-<digest>.meta holding kind=landing, secondmate=<id>, the canonical pr=<url>, and the custody the mate reported (pr_head=, nm_run_id=, custody_task=, custody_mode=, custody_evidence=, custody_blocked=), plus the standard PR-poll sidecars.
# bin/fm-merge-guard-lib.sh owns custody merge guards.
# The record is a state record, not a board item and not a worker: the poll, merge outcome, and cleanup reuse bin/fm-pr-lib.sh and bin/fm-merge-outcome-lib.sh unchanged.
# Its presence also keeps supervision armed, which the merge poll needs.
# state/landing-settled-<digest> records the canonical PR URL after notification.
# FM_LANDING_SEND_BIN and FM_LANDING_FLEET_SYNC_BIN replace the notifier and the
# clone refresh; FM_LANDING_FORGE_TIMEOUT (default 20) bounds each forge read.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
SEND_BIN="${FM_LANDING_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"
FLEET_SYNC_BIN="${FM_LANDING_FLEET_SYNC_BIN:-$SCRIPT_DIR/fm-fleet-sync.sh}"
FORGE_TIMEOUT="${FM_LANDING_FORGE_TIMEOUT:-20}"
case "$FORGE_TIMEOUT" in ''|0|*[!0-9]*) FORGE_TIMEOUT=20 ;; esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-merge-outcome-lib.sh
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

bounded() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$secs" "$@"
  else
    return 124
  fi
}

url_digest() {  # <url> -> first 8 hex chars of its SHA-256
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-8
  else
    printf '%s' "$1" | sha256sum | cut -c1-8
  fi
}

landing_id_for() {  # <secondmate-id> <canonical-url>
  printf 'land-%s-%s-%s\n' "$1" "$FM_PR_NUMBER" "$(url_digest "$2")"
}

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

lock_path() { printf '%s/.landing-%s.lock\n' "$STATE" "$(url_digest "$1")"; }
settled_path() { printf '%s/landing-settled-%s\n' "$STATE" "$(url_digest "$1")"; }

arm_poll() {  # <landing-id> <canonical-url>; FM_PR_* already parsed from it
  local id=$1 url=$2
  fm_pr_poll_prepare "$STATE" "$id" "$FM_PR_PROVIDER" "$url" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" \
    "$SCRIPT_DIR/fm-pr-poll.sh" || { echo "error: could not prepare the landing merge poll for $id" >&2; return 1; }
  fm_pr_poll_publish_prepared \
    || { fm_pr_poll_cleanup; echo "error: could not publish the landing merge poll for $id" >&2; return 1; }
}

# File (or find) the landing record for <url> and arm its poll; with
# LANDING_CUSTODY set (name=value lines) the record's custody keys are replaced
# by it. Prints the landing id, or `skipped` for a previously settled URL.
register_core() {  # <secondmate-id> <url>
  local sm=$1 raw=$2 id meta tmp lock remote outcome marker
  fm_pr_task_id_valid "$sm" || die "invalid second mate id"
  fm_pr_url_parse "$raw" || die "not a canonical PR URL: $raw"
  remote=$(secondmate_registry_field "$DATA/secondmates.md" "$sm" remote 2>/dev/null || true)
  [ "$remote" = 1 ] || die "$sm is not a registered remote second mate"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  raw=$FM_PR_URL
  id=$(landing_id_for "$sm" "$raw")
  meta="$STATE/$id.meta"
  marker=$(settled_path "$raw")
  lock=$(lock_path "$raw")
  fm_lock_acquire_wait "$lock" || die "cannot lock landing record $id"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    if [ -L "$marker" ] || ! grep -qxF "$raw" "$marker"; then
      fm_lock_release "$lock"
      die "invalid settled marker for $raw"
    fi
    fm_lock_release "$lock"
    echo skipped
    return 0
  fi
  outcome=$(forge_outcome "$FM_PR_PROVIDER" "$raw" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER")
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    if ! { fm_pr_meta_kind_is "$meta" landing && grep -qxF "pr=$raw" "$meta"; }; then
      fm_lock_release "$lock"
      die "$meta exists and is not the landing record for $raw"
    fi
  else
    umask 077
    tmp=$(mktemp "$STATE/.fm-landing-meta.XXXXXX") || { fm_lock_release "$lock"; die "cannot stage the landing record"; }
    if ! { printf 'kind=landing\nsecondmate=%s\npr=%s\nregistered=%s\n' "$sm" "$raw" "$(date +%s)" > "$tmp" \
      && mv -f -- "$tmp" "$meta"; }; then
      rm -f -- "$tmp"
      fm_lock_release "$lock"
      die "cannot write the landing record"
    fi
  fi
  if [ -n "${LANDING_CUSTODY:-}" ]; then
    tmp=$(mktemp "$STATE/.fm-landing-meta.XXXXXX") || { fm_lock_release "$lock"; die "cannot stage the landing record"; }
    if ! { { grep -Ev '^(pr_head|nm_run_id|custody_[a-z]+)=' "$meta"; printf '%s\n' "$LANDING_CUSTODY"; } > "$tmp" \
      && mv -f -- "$tmp" "$meta"; }; then
      rm -f -- "$tmp"
      fm_lock_release "$lock"
      die "cannot record custody on $id"
    fi
  fi
  # The record outlives a skipped arm (state without a poll is re-armed by the
  # next register or by a landing id's fm-pr-check), so arm even when it exists.
  if [ "$outcome" = open ] && ! fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
    arm_poll "$id" "$raw" || { fm_lock_release "$lock"; exit 1; }
  fi
  fm_lock_release "$lock"
  if [ "$outcome" != open ]; then
    "$SCRIPT_DIR/fm-landing.sh" settle "$id" "$outcome" >&2 || return 1
  fi
  echo "$id"
}

cmd_register() {
  local id
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  LANDING_CUSTODY=
  id=$(register_core "$1" "$2") || exit 1
  if [ "$id" = skipped ]; then
    printf 'landing: skipped %s - previously settled\n' "$2"
  else
    printf 'landing: %s\n' "$id"
  fi
}

# Canonical PR URLs a second mate's `done` line reports as `PR <url>`, one per
# line, so a PR-ready report is recognised and a merged or other outcome line
# that merely carries a URL is not.
done_line_pr_urls() {  # <status line>
  local line=$1 rest url
  [[ "$line" =~ ^done(\ \[[^]]*\])*:\ (.*)$ ]] || return 0
  rest=${BASH_REMATCH[2]}
  while [[ "$rest" =~ (^|[[:space:]])PR[[:space:]]+(https://[^[:space:]]+) ]]; do
    url=${BASH_REMATCH[2]}
    rest=${rest#*"${BASH_REMATCH[0]}"}
    url=${url%[.,;:\)]}
    printf '%s\n' "$url"
  done
}

# Custody line the second mate's own PR-ready gate emits (cmd_report): the
# validated PR's head, No-Mistakes run, mode, evidence status, and accepted-blocked
# ids. Sets CUSTODY_URL and LANDING_CUSTODY on a well-formed line.
parse_custody_line() {  # <status line>
  local line=$1 task head run mode evidence blocked
  local re='^working \[key=pr-custody-[0-9a-f]{8}\]: PR (https://[^[:space:]]+) custody task=([A-Za-z0-9._-]+) head=([0-9a-f]{40}|[0-9a-f]{64}|none) run=([A-Za-z0-9._-]+|none) mode=(no-mistakes|direct-PR|local-only) evidence=(complete|incomplete) blocked=(none|[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*)$'
  [[ "$line" =~ $re ]] || return 1
  CUSTODY_URL=${BASH_REMATCH[1]}
  task=${BASH_REMATCH[2]} head=${BASH_REMATCH[3]} run=${BASH_REMATCH[4]}
  mode=${BASH_REMATCH[5]} evidence=${BASH_REMATCH[6]} blocked=${BASH_REMATCH[7]}
  LANDING_CUSTODY="custody_task=$task"
  [ "$head" = none ] || LANDING_CUSTODY="$LANDING_CUSTODY"$'\n'"pr_head=$head"
  [ "$run" = none ] || LANDING_CUSTODY="$LANDING_CUSTODY"$'\n'"nm_run_id=$run"
  LANDING_CUSTODY="$LANDING_CUSTODY"$'\n'"custody_mode=$mode"$'\n'"custody_evidence=$evidence"$'\n'"custody_blocked=$blocked"
}

# One accepted status line from a remote second mate (what the reply relay
# hands over): a PR-ready `done` report files the landing, and a custody line
# also records the validated custody the merge guards need.
cmd_ingest() {
  local sm=${1:-} line=${2:-} url
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  CUSTODY_URL=
  LANDING_CUSTODY=
  if parse_custody_line "$line"; then
    register_core "$sm" "$CUSTODY_URL" >/dev/null
    return 0
  fi
  LANDING_CUSTODY=
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    register_core "$sm" "$url" >/dev/null
  done < <(done_line_pr_urls "$line")
}

# Mate side: after the PR-ready gates passed in a remote second mate's home,
# report the validated PR's custody upward once, so the main home keeps it after
# the worker is released. A home that is not a remote second mate reports nothing.
cmd_report() {
  local id=${1:-} meta kind url head run mode out evidence blocked line latest lock
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  fm_pr_task_id_valid "$id" || die "invalid task id"
  fm_merge_outcome_home_id "$FM_HOME" >/dev/null 2>&1 || return 0
  fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || return 0
  [ "$FM_SECONDMATE_PARENT_ROUTE" = remote ] || return 0
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(meta_value "$meta" kind)
  [ "${kind:-ship}" = ship ] || return 0
  url=$(meta_value "$meta" pr)
  fm_pr_url_parse "$url" || return 0
  head=$(meta_value "$meta" pr_head)
  run=$(meta_value "$meta" nm_run_id)
  mode=$(meta_value "$meta" mode)
  out=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-receipt-check.sh" "$id" 2>/dev/null) || out=
  evidence=incomplete
  blocked=none
  if [ -n "$out" ] && [ "$(printf '%s' "$out" | jq -r '.status // ""' 2>/dev/null)" = complete ]; then
    evidence=complete
    blocked=$(printf '%s' "$out" | jq -r '[.accepted_blocked[].criterion] | if length == 0 then "none" else join(",") end' 2>/dev/null) || blocked=
    [ -n "$blocked" ] || { evidence=incomplete; blocked=none; }
  fi
  line="working [key=pr-custody-$(url_digest "$FM_PR_URL")]: PR $FM_PR_URL custody task=$id head=${head:-none} run=${run:-none} mode=${mode:-unknown} evidence=$evidence blocked=$blocked"
  parse_custody_line "$line" || die "refusing to report custody for $id: the record is not well formed"
  lock="$STATE/.landing-custody.lock"
  fm_lock_acquire_wait "$lock" || die "cannot lock the custody report"
  trap 'fm_lock_release "$lock"' EXIT
  [ ! -L "$STATE/parent-replies.status" ] || die "invalid custody report ledger"
  latest=$(grep -F "PR $FM_PR_URL custody task=$id " "$STATE/parent-replies.status" 2>/dev/null | tail -1) || latest=
  if [ "$latest" != "$line" ]; then
    printf '%s\n' "$line" >> "$STATE/parent-replies.status" || die "could not append the custody report"
  fi
  fm_lock_release "$lock"
  trap - EXIT
  printf 'custody: %s\n' "$id"
}

cmd_rearm() {
  local id=${1:-} raw=${2:-} meta
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  fm_pr_task_id_valid "$id" || die "invalid landing id"
  fm_pr_url_parse "$raw" || die "not a canonical PR URL: $raw"
  meta="$STATE/$id.meta"
  fm_pr_meta_kind_is "$meta" landing || die "$id is not a landing record"
  grep -qxF "pr=$FM_PR_URL" "$meta" || die "$id tracks a different PR"
  arm_poll "$id" "$FM_PR_URL" || exit 1
  printf 'armed: state/%s.check.sh\n' "$id"
}

# merged | closed | open for a landing record's canonical PR; unreadable or
# unsupported reads are "open", the same non-settling answer the poll gives.
forge_outcome() {  # <provider> <url> <host> <path> <number>
  local provider=$1 url=$2 host=$3 path=$4 number=$5 out state
  out=$(bounded "$FORGE_TIMEOUT" "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
    "$provider" "$url" "$host" "$path" "$number" 2>/dev/null) || out=
  if [ "$out" = merged ]; then
    echo merged
    return 0
  fi
  if [ "$provider" = github ] && command -v gh >/dev/null 2>&1; then
    state=$(bounded "$FORGE_TIMEOUT" gh pr view "$url" --json state -q .state 2>/dev/null) || state=
    if [ "$state" = CLOSED ]; then
      echo closed
      return 0
    fi
  fi
  echo open
}

# The project clone whose origin is the PR's repository, by name; empty if none.
clone_for_pr() {  # <host> <path>
  local host=$1 path=$2 dir origin norm want
  want=$(printf '%s/%s' "$host" "$path" | tr '[:upper:]' '[:lower:]')
  for dir in "$PROJECTS"/*/; do
    [ -d "$dir" ] || continue
    origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
    norm=$(printf '%s' "$origin" | tr '[:upper:]' '[:lower:]' | sed -e 's#^[a-z+]*://\([^@/]*@\)\{0,1\}##' -e 's#^[^@/]*@##' -e 's#:#/#' -e 's#\.git$##' -e 's#/$##')
    if [ "$norm" = "$want" ]; then
      basename "$dir"
      return 0
    fi
  done
  return 1
}

cmd_settle() {
  local id=${1:-} outcome=${2:-} meta url sm lock clone text marker tmp result send_rc sync_rc note=
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  case "$outcome" in merged|closed) ;; *) die "outcome must be merged or closed" ;; esac
  fm_pr_task_id_valid "$id" || die "invalid landing id"
  meta="$STATE/$id.meta"
  fm_pr_meta_kind_is "$meta" landing || die "$id is not a landing record"
  url=$(meta_value "$meta" pr)
  sm=$(meta_value "$meta" secondmate)
  fm_pr_url_parse "$url" || die "$id records no canonical PR"
  fm_pr_task_id_valid "$sm" || die "$id records no second mate"
  marker=$(settled_path "$url")
  lock=$(lock_path "$url")
  fm_lock_acquire_wait "$lock" || die "cannot lock landing record $id"
  trap 'fm_lock_release "$lock"' EXIT
  if [ ! -e "$marker" ] && [ ! -L "$marker" ] && [ "$outcome" = merged ]; then
    if clone=$(clone_for_pr "$FM_PR_HOST" "$FM_PR_PATH"); then
      sync_rc=0
      result=$("$FLEET_SYNC_BIN" "$clone" 2>&1) || sync_rc=$?
      if [ "$sync_rc" -eq 0 ]; then
        note="clone $clone sync: ${result:-completed}, "
      else
        note="clone $clone sync failed (exit $sync_rc): ${result:-no diagnostic}, "
      fi
    else
      note="no project clone matches, "
    fi
  fi
  if [ "$outcome" = merged ]; then
    text="Landing notice: $url was merged. Close any row you kept open for it and retire any worker still tied to it; the main home owns the merge record and needs no reply beyond your usual status line."
  else
    text="Landing notice: $url was closed without merging. Close or re-plan any row you kept open for it; the main home no longer tracks it."
  fi
  # The reconcile plane carries only from-firstmate payloads, like every other
  # reconcile delivery; the delivery id stays URL-bound so a retry is identical.
  fm_message_mark_from_firstmate "$text" text
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    if [ -L "$marker" ] || ! grep -qxF "$url" "$marker"; then
      die "invalid settled marker for $url"
    fi
  else
    send_rc=0
    result=$(FM_HOME="$FM_HOME" FM_SEND_RECONCILE_AUTH=1 "$SEND_BIN" "$sm" \
      --reconcile-delivery "landing-$(url_digest "$url")" "$text" 2>&1) || send_rc=$?
    [ -z "$result" ] || printf '%s\n' "$result" >&2
    case "$send_rc" in
      0|4|5|6|7|8|255) ;;
      *)
        if [ "$send_rc" -ne 1 ] || ! printf '%s\n' "$result" | grep -qE '^error: text was delivered to .+, but its pending-reply delivery commit|^error: text delivery to remote secondmate [A-Za-z0-9._-]+ is unknown;'; then
          printf 'DRIFT landing-notify-failed: %s - second mate %s delivery unresolved (exit %s); record kept for identity-bound retry\n' "$id" "$sm" "$send_rc"
          exit 1
        fi
        ;;
    esac
    tmp=$(umask 077; mktemp "$STATE/.fm-landing-settled.XXXXXX") || die "cannot stage settled marker"
    if ! { printf '%s\n' "$url" > "$tmp" && mv -f -- "$tmp" "$marker"; }; then
      rm -f -- "$tmp"
      die "cannot record settled URL"
    fi
  fi
  fm_pr_poll_cleanup_remove "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
    || { printf 'DRIFT landing-cleanup-refused: %s - PR poll artifacts could not be retired; record kept\n' "$id"; exit 1; }
  rm -f -- "$meta"
  fm_lock_release "$lock"
  trap - EXIT
  printf 'DRIFT landing-%s: %s - %s %s; %ssecond mate %s notified or delivery retained; record retired\n' "$outcome" "$id" "$url" "$outcome" "$note" "$sm"
}

cmd_sweep() {
  local report=0 meta id url outcome rc=0
  case "${1:-}" in
    '') ;;
    --report) report=1 ;;
    *) usage >&2; exit 2 ;;
  esac
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    fm_pr_meta_kind_is "$meta" landing || continue
    id=$(basename "$meta" .meta)
    fm_pr_task_id_valid "$id" || continue
    url=$(meta_value "$meta" pr)
    fm_pr_url_parse "$url" || continue
    outcome=$(forge_outcome "$FM_PR_PROVIDER" "$FM_PR_URL" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER")
    [ "$outcome" != open ] || continue
    if [ "$report" -eq 1 ]; then
      printf 'DRIFT landing-%s: %s - %s is %s; settling requires verified mutation authority\n' "$outcome" "$id" "$url" "$outcome"
      continue
    fi
    "$SCRIPT_DIR/fm-landing.sh" settle "$id" "$outcome" || rc=1
  done
  return "$rc"
}

case "${1:-}" in
  register) shift; cmd_register "$@" ;;
  ingest) shift; cmd_ingest "$@" ;;
  report) shift; cmd_report "$@" ;;
  rearm) shift; cmd_rearm "$@" ;;
  settle) shift; cmd_settle "$@" ;;
  sweep) shift; cmd_sweep "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
