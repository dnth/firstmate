#!/usr/bin/env bash
# Watcher program for one armed post-merge base-branch CI watch.
# bin/fm-main-ci-watch.sh writes it into state/<task>-main-ci-<pr>.check.sh as a
# thin shim that execs this file with the armed identity, and the watcher runs
# it once per check sweep through the custom-check path (bin/fm-check-register.sh
# trust), exactly like a hand-written check.
#
# One invocation reaches one verdict:
#   a completed base-branch run for the merge commit failed -> retire the check,
#       then print "<base> CI failed after <pr-url>: <workflow> / <job>".
#   every observed run is terminal and none failed -> retire the check silently.
#   runs are pending or none were created yet -> print nothing and stay armed.
#   the deadline passed without a terminal verdict -> retire the check, then
#       print "<base> CI not observed after <pr-url>" when no run was ever
#       listed, or "<base> CI still pending after <pr-url>: <workflows>" when
#       runs exist but none has finished.
# Every forge error is transient by construction and stays silent until the
# deadline, so a broken read never retires the watch and never reports a
# verdict it cannot prove.
#
# Retirement is self-service through bin/fm-check-unregister.sh and runs BEFORE
# a line prints: a wake is therefore emitted at most once, and a failed
# retirement leaves the check armed to retry next sweep rather than double
# waking. The merge commit is resolved live from the pull request each sweep,
# so a run armed while the forge was still creating the commit needs no
# re-arming to find its runs.
#
# Usage: fm-main-ci-poll.sh <state-dir> <check-id> <owner/repo> <pr-url> <deadline-epoch>
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
. "$SCRIPT_DIR/fm-timeout-lib.sh"

[ "$#" -eq 5 ] || exit 0
STATE=$1
CHECK_ID=$2
REPO=$3
URL=$4
DEADLINE=$5

[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
fm_pr_task_id_valid "$CHECK_ID" || exit 0
case "$DEADLINE" in
  ''|*[!0-9]*) exit 0 ;;
esac

# The armed identity is revalidated here rather than trusted from the shim: the
# URL must parse as a canonical GitHub pull request and the repository pair
# carried separately must be exactly the one the URL names, so a doctored
# check cannot redirect this watch at another project.
fm_pr_url_parse "$URL" || exit 0
[ "$FM_PR_PROVIDER" = github ] || exit 0
[ "$REPO" = "$FM_PR_OWNER/$FM_PR_REPO" ] || exit 0

check_budget=${FM_CHECK_TIMEOUT:-30}
case "$check_budget" in
  ''|*[!0-9]*) check_budget=30 ;;
esac
read_deadline=$((SECONDS + 10#$check_budget - 3))

forge_read() {
  local remaining=$((read_deadline - SECONDS))
  [ "$remaining" -gt 0 ] || return 124
  fm_run_timed "$remaining" gh "$@"
}

# Retire through the register's own unarm path; nothing else composes the
# removal. On success this invocation may print its verdict; on failure it
# stays silent so the check stays armed and retries next sweep.
retire() {
  FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null 2>&1
}

# Report the armed deadline verdict: the only line this check may print before
# it leaves, and the one that fires when the base-branch runs never produced a
# terminal answer inside the bound.
deadline_verdict() {
  local base=$1 pending_names=$2 now
  now=$(date +%s) || return 0
  [ "$now" -ge "$DEADLINE" ] || return 0
  retire || return 0
  if [ -n "$pending_names" ]; then
    printf '%s CI still pending after %s: %s\n' "$base" "$URL" "$pending_names"
  else
    printf '%s CI not observed after %s\n' "$base" "$URL"
  fi
}

# A missing reader can never observe a run; it still reaches the same bounded
# timeout verdict instead of staying armed forever.
if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  deadline_verdict base-branch ''
  exit 0
fi

view=$(forge_read pr view "$URL" --json baseRefName,mergeCommit 2>/dev/null) || view=
base=
sha=
if [ -n "$view" ]; then
  base=$(printf '%s' "$view" | jq -r '.baseRefName // ""' 2>/dev/null) || base=
  sha=$(printf '%s' "$view" | jq -r '.mergeCommit.oid // ""' 2>/dev/null) || sha=
fi
if [ -z "$base" ]; then
  base=base-branch
  sha=
fi
case "$sha" in
  ''|*[!0-9a-fA-F]*) sha= ;;
esac
if [ -z "$sha" ]; then
  # A merged pull request reports no merge commit only while the forge is still
  # creating it; keep waiting inside the same bound.
  deadline_verdict "$base" ''
  exit 0
fi

runs=$(forge_read run list --repo "$REPO" --commit "$sha" --branch "$base" --limit 100 \
  --json databaseId,workflowName,status,conclusion,headBranch 2>/dev/null) || runs=
if [ -z "$runs" ]; then
  deadline_verdict "$base" ''
  exit 0
fi
# One pre-classified verdict line, so empty JSON fields can never collapse
# into a shifted row: EMPTY when no run exists yet, DONE when every observed
# run is terminal with none failed, FAIL with the first failed run's id and
# workflow, PENDING with the still-open workflows joined.
verdict=$(printf '%s' "$runs" | jq -r --arg base "$base" '
  def isfail: .conclusion == "failure" or .conclusion == "timed_out"
    or .conclusion == "startup_failure" or .conclusion == "action_required";
  map(select(.headBranch == $base)) |
  if length == 0 then "EMPTY"
  elif ([.[] | select(.status == "completed" and isfail)] | length) > 0 then
    "FAIL\t" +
    ([.[] | select(.status == "completed" and isfail)][0].databaseId | tostring) +
    "\t" + ([.[] | select(.status == "completed" and isfail)][0].workflowName // "-")
  elif ([.[] | select(.status != "completed")] | length) > 0 then
    "PENDING\t" +
    ([.[] | select(.status != "completed") | .workflowName // "-"] | unique | join(", "))
  else "DONE" end' 2>/dev/null) || verdict=

case "$verdict" in
  FAIL*)
    rest=${verdict#*$'\t'}
    failed_id=${rest%%$'\t'*}
    failed_wf=${rest#*$'\t'}
    # Name the failing job when it can be read; the workflow alone is the
    # fallback line, never a reason to drop the verdict.
    jobs=$(forge_read run view "$failed_id" --repo "$REPO" --json jobs 2>/dev/null \
      | jq -r '[.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure" or .conclusion == "action_required") | .name] | join(", ")' \
      2>/dev/null) || jobs=
    retire || exit 0
    if [ -n "$jobs" ]; then
      printf '%s CI failed after %s: %s / %s\n' "$base" "$URL" "$failed_wf" "$jobs"
    else
      printf '%s CI failed after %s: %s\n' "$base" "$URL" "$failed_wf"
    fi
    ;;
  DONE)
    retire
    ;;
  PENDING*)
    deadline_verdict "$base" "${verdict#*$'\t'}"
    ;;
  *)
    # EMPTY or an unreadable answer: no base-branch run exists for the merge
    # commit yet - GitHub creates them after the push lands, so this stays a
    # waiting verdict inside the bound.
    deadline_verdict "$base" ''
    ;;
esac
exit 0
