#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, atomically arm a static merge poll, then
# record PR-path validation completion only after publication succeeds.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
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
VALIDATION_LOCK=
pr_check_cleanup() {
  fm_lease_guard_release || true
  fm_pr_poll_cleanup
  rm -f -- "$META_SNAPSHOT" "$META_RECORDS" "$META_UPDATED"
  [ -z "$VALIDATION_LOCK" ] || rmdir "$VALIDATION_LOCK" 2>/dev/null || true
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

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
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

fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

VALIDATION_LOCK="$STATE/.$ID.validation-plan.lock"
mkdir "$VALIDATION_LOCK" 2>/dev/null \
  || { VALIDATION_LOCK=; echo "error: validation metadata is locked" >&2; exit 1; }
EXPECTED_GENERATION=$(grep '^validation_generation=' "$META" | tail -1 | cut -d= -f2- || true)
VALIDATION_PATH=$(grep '^validation_path=' "$META" | tail -1 | cut -d= -f2- || true)
VALIDATION_GENERATION=$(grep '^validation_generation=' "$META" | tail -1 | cut -d= -f2- || true)
[ "$VALIDATION_GENERATION" = "$EXPECTED_GENERATION" ] \
  || { echo "error: validation generation changed during PR registration" >&2; exit 1; }
printf 'pr=%s\n' "$URL" > "$META_RECORDS" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_RECORDS" || exit 1
META_REPLACE_KEYS=pr,pr_head
if [ "$VALIDATION_PATH" = direct-PR ] || [ "$VALIDATION_PATH" = receipts-mechanical ]; then
  [ -n "$VALIDATION_GENERATION" ] \
    || { echo "error: PR validation generation is missing" >&2; exit 1; }
  printf 'validation_pr_published_generation=%s\n' "$VALIDATION_GENERATION" >> "$META_RECORDS" || exit 1
  META_REPLACE_KEYS="$META_REPLACE_KEYS,validation_pr_published_generation"
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
if [ "$VALIDATION_PATH" = direct-PR ] || [ "$VALIDATION_PATH" = receipts-mechanical ]; then
  rmdir "$VALIDATION_LOCK" || { echo "error: validation metadata lock could not be released" >&2; exit 1; }
  VALIDATION_LOCK=
  "$SCRIPT_DIR/fm-receipt-check.sh" "$ID" --complete --terminal-evidence pr-opened >/dev/null \
    || { echo "error: PR validation completion could not be observed" >&2; exit 1; }
fi
printf 'armed: state/%s.check.sh\n' "$ID"
