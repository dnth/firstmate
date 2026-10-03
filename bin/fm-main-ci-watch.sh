#!/usr/bin/env bash
# Arm a one-shot base-branch CI watch for a verified merge.
# bin/fm-pr-merge.sh calls this after the forge confirms a merge landed; it may
# also be invoked directly to arm the same watch by hand.
# The check is state/<task-id>-main-ci-<pr-number>.check.sh, a thin shim that
# execs bin/fm-main-ci-poll.sh with the armed identity, bound to its bytes by
# bin/fm-check-register.sh so the watcher's custom-check path executes it.
# That poll retires itself through bin/fm-check-unregister.sh at its terminal
# verdict: one failure wake, one timeout wake, or silence on green.
# The watch is bounded by FM_MAIN_CI_WATCH_SECS (default 14400 seconds) counted
# from arming time; the deadline is baked into the armed check, so later
# environment changes do not move it. A non-numeric value refuses the arm
# rather than arming an unbounded or mis-bounded watch.
# Works for any GitHub pull request the URL names; the repository comes only
# from the canonical URL, so no registered-project lookup is needed.
# Usage: fm-main-ci-watch.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid base-branch CI watch request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid base-branch CI watch request" >&2
  exit 2
fi
URL=$FM_PR_URL
REPO="$FM_PR_OWNER/$FM_PR_REPO"
CHECK_ID="$ID-main-ci-$FM_PR_NUMBER"

WATCH_SECS=${FM_MAIN_CI_WATCH_SECS:-14400}
case "$WATCH_SECS" in
  ''|*[!0-9]*)
    echo "error: FM_MAIN_CI_WATCH_SECS must be a number of seconds" >&2
    exit 2
    ;;
esac
DEADLINE=$(( $(date +%s) + WATCH_SECS ))

[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  echo "error: state directory is unavailable" >&2
  exit 1
}

# The shim carries the armed identity as literals; every value is either a
# validated charset above or a path %q-quoted so it survives exactly as given.
umask 077
TMP=$(mktemp "$STATE/.fm-main-ci-check.XXXXXX") || exit 1
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT
trap 'exit 1' HUP INT TERM
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# Armed by bin/fm-main-ci-watch.sh after a verified merge and bound by'
  printf '%s\n' '# bin/fm-check-register.sh; bin/fm-main-ci-poll.sh owns the verdict and'
  printf '%s\n' '# self-retirement through bin/fm-check-unregister.sh.'
  printf 'exec %q %q %q %q %q %q\n' \
    "$FM_ROOT/bin/fm-main-ci-poll.sh" \
    "$STATE" "$CHECK_ID" "$REPO" "$URL" "$DEADLINE"
} > "$TMP" || exit 1
chmod 0700 "$TMP" || exit 1
mv -f -- "$TMP" "$STATE/$CHECK_ID.check.sh" || exit 1
TMP=

FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null || {
  echo "error: could not register the base-branch CI watch" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
