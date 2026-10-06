#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# Every ship PR-ready requires complete acceptance evidence
# (bin/fm-receipt-check.sh <task-id> exits 0); missing or invalid receipts
# refuse registration naming the criteria.
# A no-mistakes task additionally proves its run from No-Mistakes' own status:
# `axi status` in the task worktree must report a run whose branch is the task
# branch, whose pr is this URL, and whose full head_sha equals the forge's PR
# head, and the run must be passed or CI-green (fm_nm_run_is_pr_ready). That
# run id is recorded as nm_run_id=<id>; the decision-evidence audit owned by
# bin/fm-nm-run-lib.sh then runs against it as that guarantee's single
# PR-ready owner, and unreadable run data or insufficient decision records
# refuse registration. Nothing here reconstructs what the pipeline validated
# from the worker's object store.
# Publication is serialized per task through state/.<task-id>.pr-publication.lock
# (a mkdir lock) so a concurrent registration cannot interleave its metadata
# replacement with this one; bin/fm-watch.sh defers a pre-metadata poll while
# that lock is fresh.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

NM_TIMEOUT=${FM_PR_CHECK_NM_TIMEOUT:-${FM_RECEIPT_NM_TIMEOUT:-10}}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

pr_check_lease_cleanup() {
  fm_lease_guard_release || true
}
trap pr_check_lease_cleanup EXIT
fm_lease_guard "$ID" "PR check registration"

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

META_SNAPSHOT=$(mktemp "$STATE/.fm-pr-meta-snapshot.XXXXXX") || exit 1
META_RECORDS=$(mktemp "$STATE/.fm-pr-meta-records.XXXXXX") || { rm -f -- "$META_SNAPSHOT"; exit 1; }
META_UPDATED=$(mktemp "$STATE/.fm-pr-meta-updated.XXXXXX") \
  || { rm -f -- "$META_SNAPSHOT" "$META_RECORDS"; exit 1; }
PUBLICATION_LOCK=
pr_check_cleanup() {
  fm_lease_guard_release || true
  fm_pr_poll_cleanup
  rm -f -- "$META_SNAPSHOT" "$META_RECORDS" "$META_UPDATED"
  [ -z "$PUBLICATION_LOCK" ] || rmdir "$PUBLICATION_LOCK" 2>/dev/null || true
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-receipt-store.sh" "$ID" meta-read "$META_SNAPSHOT" \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META="$META_SNAPSHOT"

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only from a forge-observed value.
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

# Every ship PR-ready requires complete acceptance evidence.
KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "$KIND" = ship ]; then
  EVIDENCE_RC=0
  EVIDENCE_OUT=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-receipt-check.sh" "$ID" 2>&1) || EVIDENCE_RC=$?
  if [ "$EVIDENCE_RC" -ne 0 ]; then
    EVIDENCE_DETAIL=$(printf '%s' "$EVIDENCE_OUT" | jq -r '
      if .status == "invalid" then "invalid evidence: " + (.invalid | join("; "))
      elif .status == "missing" then "missing evidence: " + (.missing | join(", "))
      else "evidence check failed" end' 2>/dev/null || printf 'evidence check failed')
    echo "error: PR-ready refused for $ID: $EVIDENCE_DETAIL" >&2
    exit 1
  fi
fi

# A no-mistakes task proves its run from No-Mistakes' own status, then passes
# the decision-evidence audit owned by bin/fm-nm-run-lib.sh (process-evidence
# limitation owned by bin/fm-classify-lib.sh).
NM_RUN_ID=
if [ "$KIND" = ship ] && [ "$MODE" = no-mistakes ]; then
  [ -n "$WT" ] && [ -d "$WT" ] || { echo "error: no-mistakes PR-ready requires the task worktree" >&2; exit 1; }
  NM_OUT=$(fm_nm_run_checked "$WT" "$NM_TIMEOUT" axi status) \
    || { echo "error: No-Mistakes status could not be observed for $ID" >&2; exit 1; }
  NM_RUN_ID=$(fm_nm_field "$NM_OUT" id)
  NM_BRANCH=$(fm_nm_field "$NM_OUT" branch)
  NM_PR=$(fm_nm_field "$NM_OUT" pr)
  NM_HEAD=$(fm_nm_field "$NM_OUT" head_sha)
  case "$NM_RUN_ID" in ''|*[!A-Za-z0-9._-]*) echo "error: No-Mistakes status reports no run for $ID" >&2; exit 1 ;; esac
  fm_nm_branch_matches_worktree "$WT" "$NM_BRANCH" \
    || { echo "error: No-Mistakes run $NM_RUN_ID is on branch '$NM_BRANCH', not the task branch" >&2; exit 1; }
  [ "$NM_PR" = "$URL" ] \
    || { echo "error: No-Mistakes run $NM_RUN_ID opened '$NM_PR', not $URL" >&2; exit 1; }
  [ -n "$PR_HEAD" ] \
    || { echo "error: the forge's PR head could not be observed, so run $NM_RUN_ID cannot be matched to $URL" >&2; exit 1; }
  [ "$NM_HEAD" = "$PR_HEAD" ] \
    || { echo "error: No-Mistakes run $NM_RUN_ID validated head ${NM_HEAD:-<none>} but the PR head is $PR_HEAD; let the pipeline reconcile the branch and re-report" >&2; exit 1; }
  fm_nm_run_is_pr_ready "$WT" "$NM_TIMEOUT" "$NM_OUT" "$NM_RUN_ID" \
    || { echo "error: No-Mistakes run $NM_RUN_ID is neither passed nor CI-green" >&2; exit 1; }
  ASK_USER_RC=0
  ASK_USER_REPORT=$(fm_nm_ask_user_decisions "$WT" "$NM_TIMEOUT" "$NM_RUN_ID" "$STATE/$ID.status") \
    || ASK_USER_RC=$?
  if [ "$ASK_USER_RC" -ne 0 ]; then
    if [ "$ASK_USER_RC" -eq 1 ]; then
      echo "error: No-Mistakes run $NM_RUN_ID resolved ask-user findings without matching firstmate decisions" >&2
      printf '%s\n' "$ASK_USER_REPORT" >&2
      echo "error: firstmate must record one resolved [key=nm-$NM_RUN_ID-<step>] line per decision event in state/$ID.status" >&2
    else
      echo "error: No-Mistakes run $NM_RUN_ID ask-user decision evidence could not be read" >&2
    fi
    exit 1
  fi
fi

fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

PUBLICATION_LOCK="$STATE/.$ID.pr-publication.lock"
mkdir "$PUBLICATION_LOCK" 2>/dev/null \
  || { PUBLICATION_LOCK=; echo "error: PR publication is locked by another registration" >&2; exit 1; }
printf 'pr=%s\n' "$URL" > "$META_RECORDS" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_RECORDS" || exit 1
META_REPLACE_KEYS=pr,pr_head
if [ -n "$NM_RUN_ID" ]; then
  printf 'nm_run_id=%s\n' "$NM_RUN_ID" >> "$META_RECORDS" || exit 1
  META_REPLACE_KEYS="$META_REPLACE_KEYS,nm_run_id"
fi
fm_pr_poll_publish_prepared defer-metadata || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
if ! FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" FM_RECEIPT_META_REPLACE_KEYS="$META_REPLACE_KEYS" \
  "$SCRIPT_DIR/fm-receipt-store.sh" "$ID" meta-replace "$META" "$META_RECORDS" "$META_UPDATED"; then
  fm_pr_poll_revoke_final || true
  echo "error: PR metadata publication could not be recorded" >&2
  exit 1
fi
mv -f -- "$META_UPDATED" "$META"
fm_pr_metadata_identity_parse "$META" || { fm_pr_poll_revoke_final || true; exit 1; }
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] \
  || { fm_pr_poll_revoke_final || true; exit 1; }
fm_pr_poll_artifacts_valid "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { fm_pr_poll_revoke_final || true; echo "error: published PR poll is invalid" >&2; exit 1; }
printf 'armed: state/%s.check.sh\n' "$ID"
