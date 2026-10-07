#!/usr/bin/env bash
# fm-landing.sh - main-owned landing records for a remote second mate's PRs.
#
# A remote second mate sleeps between turns, and its merge poll runs only while
# it is awake, so the home that must notice a merge cannot be the mate's. When
# the remote reply relay (bin/fm-procevent-remote-reply.sh) ingests a mate's
# `done` line naming `PR <url>`, this home records one landing record for that
# PR under a main-owned id and arms the ordinary merge poll on it. The mate may
# then release its finished worker at PR-ready: main keeps the PR tracked.
# Merge authority is unchanged and lives in .agents/skills/ship-landing/SKILL.md.
#
# Usage:
#   fm-landing.sh register <secondmate-id> <pr-url>
#       File (or find) the landing record for the PR and arm its merge poll.
#       Idempotent. Prints `landing: <landing-id>`. Refuses an id that is not a
#       registered remote second mate and any URL that is not a canonical PR.
#       A PR the forge already shows merged or closed gets no record (prints
#       `landing: skipped ...`), so a mate's reply to a settle notice cannot
#       register it again.
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
#       Finish a landed or closed PR: on merge refresh the project's clone
#       through bin/fm-fleet-sync.sh (best effort), tell the second mate through bin/fm-send.sh
#       so it can close its own row, then retire the poll and the record. A mate
#       that cannot be told keeps the record, so the next sweep retries.
#
# Record: state/<landing-id>.meta holding kind=landing, secondmate=<id>, and the
# canonical pr=<url>, plus the standard PR-poll sidecars. The record is a state
# record, not a board item and not a worker: the poll, merge outcome, and
# cleanup reuse bin/fm-pr-lib.sh and bin/fm-merge-outcome-lib.sh unchanged. Its
# presence also keeps supervision armed, which the merge poll needs.
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
case "$FORGE_TIMEOUT" in ''|*[!0-9]*) FORGE_TIMEOUT=20 ;; esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# <seconds> <command...>: bounded forge read; an unavailable timeout runs the
# command as is, because every caller treats a failed read as "not settled".
bounded() {
  local secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    "$@"
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

lock_path() { printf '%s/.landing-%s.lock\n' "$STATE" "$1"; }

arm_poll() {  # <landing-id> <canonical-url>; FM_PR_* already parsed from it
  local id=$1 url=$2
  fm_pr_poll_prepare "$STATE" "$id" "$FM_PR_PROVIDER" "$url" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" \
    "$SCRIPT_DIR/fm-pr-poll.sh" || die "could not prepare the landing merge poll for $id"
  fm_pr_poll_publish_prepared \
    || { fm_pr_poll_cleanup; die "could not publish the landing merge poll for $id"; }
}

cmd_register() {
  local sm=${1:-} raw=${2:-} id meta tmp lock remote outcome
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  fm_pr_task_id_valid "$sm" || die "invalid second mate id"
  fm_pr_url_parse "$raw" || die "not a canonical PR URL: $raw"
  remote=$(secondmate_registry_field "$DATA/secondmates.md" "$sm" remote 2>/dev/null || true)
  [ "$remote" = 1 ] || die "$sm is not a registered remote second mate"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  raw=$FM_PR_URL
  # A PR the forge already shows merged or closed needs no record, and filing
  # one would let a mate's reply to the settle notice register it again.
  outcome=$(forge_outcome "$FM_PR_PROVIDER" "$raw" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER")
  if [ "$outcome" != open ]; then
    printf 'landing: skipped %s - already %s\n' "$raw" "$outcome"
    return 0
  fi
  id=$(landing_id_for "$sm" "$raw")
  meta="$STATE/$id.meta"
  lock=$(lock_path "$id")
  fm_lock_acquire_wait "$lock" || die "cannot lock landing record $id"
  trap 'fm_lock_release "$lock"' EXIT
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    fm_pr_meta_kind_is "$meta" landing && grep -qxF "pr=$raw" "$meta" \
      || die "$meta exists and is not the landing record for $raw"
  else
    umask 077
    tmp=$(mktemp "$STATE/.fm-landing-meta.XXXXXX") || die "cannot stage the landing record"
    printf 'kind=landing\nsecondmate=%s\npr=%s\nregistered=%s\n' "$sm" "$raw" "$(date +%s)" > "$tmp" \
      && mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; die "cannot write the landing record"; }
  fi
  # The record outlives a skipped arm (state without a poll is re-armed by the
  # next register or by a landing id's fm-pr-check), so arm even when it exists.
  if ! fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
    arm_poll "$id" "$raw"
  fi
  fm_lock_release "$lock"
  trap - EXIT
  printf 'landing: %s\n' "$id"
}

cmd_rearm() {
  local id=${1:-} raw=${2:-} meta
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  fm_pr_task_id_valid "$id" || die "invalid landing id"
  fm_pr_url_parse "$raw" || die "not a canonical PR URL: $raw"
  meta="$STATE/$id.meta"
  fm_pr_meta_kind_is "$meta" landing || die "$id is not a landing record"
  grep -qxF "pr=$FM_PR_URL" "$meta" || die "$id tracks a different PR"
  arm_poll "$id" "$FM_PR_URL"
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
  want=$(printf '%s/%s' "$host" "$path" | tr 'A-Z' 'a-z')
  for dir in "$PROJECTS"/*/; do
    [ -d "$dir" ] || continue
    origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
    norm=$(printf '%s' "$origin" | tr 'A-Z' 'a-z' | sed -e 's#^[a-z+]*://\([^@/]*@\)\{0,1\}##' -e 's#^[^@/]*@##' -e 's#:#/#' -e 's#\.git$##' -e 's#/$##')
    if [ "$norm" = "$want" ]; then
      basename "$dir"
      return 0
    fi
  done
  return 1
}

cmd_settle() {
  local id=${1:-} outcome=${2:-} meta url sm lock clone text note=
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  case "$outcome" in merged|closed) ;; *) die "outcome must be merged or closed" ;; esac
  fm_pr_task_id_valid "$id" || die "invalid landing id"
  meta="$STATE/$id.meta"
  fm_pr_meta_kind_is "$meta" landing || die "$id is not a landing record"
  url=$(meta_value "$meta" pr)
  sm=$(meta_value "$meta" secondmate)
  fm_pr_url_parse "$url" || die "$id records no canonical PR"
  fm_pr_task_id_valid "$sm" || die "$id records no second mate"
  lock=$(lock_path "$id")
  fm_lock_acquire_wait "$lock" || die "cannot lock landing record $id"
  trap 'fm_lock_release "$lock"' EXIT
  if [ "$outcome" = merged ]; then
    if clone=$(clone_for_pr "$FM_PR_HOST" "$FM_PR_PATH"); then
      "$FLEET_SYNC_BIN" "$clone" >/dev/null 2>&1 || true
      note="clone $clone refreshed, "
    else
      note="no project clone matches, "
    fi
    text="Landing notice: $url was merged. Close any row you kept open for it and retire any worker still tied to it; the main home owns the merge record and needs no reply beyond your usual status line."
  else
    text="Landing notice: $url was closed without merging. Close or re-plan any row you kept open for it; the main home no longer tracks it."
  fi
  FM_HOME="$FM_HOME" "$SEND_BIN" "$sm" "$text" >/dev/null 2>&1 \
    || { printf 'DRIFT landing-notify-failed: %s - second mate %s could not be told; record kept for retry\n' "$id" "$sm"; exit 1; }
  fm_pr_poll_cleanup_remove "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
    || { printf 'DRIFT landing-cleanup-refused: %s - PR poll artifacts could not be retired; record kept\n' "$id"; exit 1; }
  rm -f -- "$meta"
  fm_lock_release "$lock"
  trap - EXIT
  printf 'DRIFT landing-%s: %s - %s %s; %ssecond mate %s told, record retired\n' "$outcome" "$id" "$url" "$outcome" "$note" "$sm"
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
  rearm) shift; cmd_rearm "$@" ;;
  settle) shift; cmd_settle "$@" ;;
  sweep) shift; cmd_sweep "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
