#!/usr/bin/env bash
# Bind a spawned task to a local Communication Officer request_id.
#
# Usage: fm-ext-link.sh <task-id> <request_id>
#
# Records link lines in state/<task-id>.meta (replacing any prior ext link,
# preserving every other meta line):
#   ext_request=<canonical request_id>
#   ext_request_slug=<sha256 of that id>
#   ext_request_ts=<epoch>
#   ext_followups=<n>
#
# This is deliberately not x_request=. The hosted X-mode relay is a separate
# seam. Fresh links start ext_followups at 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-ext-lib.sh
. "$SCRIPT_DIR/fm-ext-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  echo "usage: fm-ext-link.sh <task-id> <request_id>" >&2
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

case "${1:-}" in
  --help|-h) help; exit 0 ;;
esac

ID=${1:-}
RID=${2:-}
if [ -z "$ID" ] || [ -z "$RID" ]; then
  usage
  exit 2
fi

fm_pr_task_id_valid "$ID" || { echo "fm-ext-link: unsafe task id: $ID" >&2; exit 2; }
fm_ext_request_id_valid "$RID" || { echo "fm-ext-link: unsafe request_id: $RID" >&2; exit 2; }

META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  echo "fm-ext-link: no such task: state/$ID.meta" >&2
  exit 1
fi

SLUG=$(fm_ext_request_slug "$RID") || {
  echo "fm-ext-link: could not derive request slug" >&2
  exit 1
}

LINK_TS=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
case "$LINK_TS" in
  ''|*[!0-9]*) echo "fm-ext-link: could not read the current time" >&2; exit 1 ;;
esac

if ! fm_ext_meta_link_set "$META" "$RID" "$SLUG" "$LINK_TS" 0; then
  echo "fm-ext-link: failed to record the link in state/$ID.meta" >&2
  exit 1
fi

printf 'linked %s to ext request %s\n' "$ID" "$RID"
