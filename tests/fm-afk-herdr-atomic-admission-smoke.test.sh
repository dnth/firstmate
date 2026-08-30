#!/usr/bin/env bash
# tests/fm-afk-herdr-atomic-admission-smoke.test.sh - opt-in real-Herdr smoke
# for the shipped away-supervisor admission path.  Every CLI operation routes
# through fm-herdr-lab.sh, so it can run only in a named non-default session.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-afk-atomic-admission)
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
export HERDR_SESSION="$HERDR_LAB_SESSION"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr

# Keep the production adapter and replace only its CLI process boundary with
# the mandatory lab helper.  The adapter still performs its own target parse,
# composer classification, and admission decision against a real Herdr pane.
fm_backend_herdr_cli() { # <session> <herdr args...>
  local session=$1
  shift
  [ "$session" = "$HERDR_LAB_SESSION" ] || {
    echo "not ok - production adapter attempted to escape the named Herdr lab: $session" >&2
    return 1
  }
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}
# This smoke provisions the real named server above, so avoid the adapter's
# session-independent version probe, which intentionally calls the raw client.
fm_backend_herdr_version_check() { return 0; }

container_raw=$(fm_backend_herdr_container_ensure /tmp)
container=${container_raw%%$'\t'*}
seeded_tab=${container_raw#*$'\t'}
task_ids=$(fm_backend_herdr_create_task "$container" "fm-afk-atomic-admission" /tmp "$seeded_tab")
read -r _tab pane <<EOF
$task_ids
EOF
[ -n "$pane" ] || { echo "not ok - could not create isolated smoke pane" >&2; exit 1; }
target="$HERDR_LAB_SESSION:$pane"

verdict=$(fm_backend_herdr_away_supervisor_admit "$target" "FIRSTMATE_ATOMIC_ADMISSION_SMOKE" claude)
case "$verdict" in
  deferred-pending|deferred-unknown|deferred-no-atomic-admission) ;;
  *) echo "not ok - unexpected Herdr atomic-admission verdict: $verdict" >&2; exit 1 ;;
esac

capture=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" --source recent)
case "$capture" in
  *FIRSTMATE_ATOMIC_ADMISSION_SMOKE*)
    echo "not ok - unavailable atomic admission typed into the real composer" >&2
    exit 1
    ;;
esac

echo "ok - named Herdr lab smoke: the shipped atomic-admission path deferred without typing into its isolated composer ($verdict)"
