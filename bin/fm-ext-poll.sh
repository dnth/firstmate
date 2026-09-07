#!/usr/bin/env bash
# One slow-check of the local Communication Officer inbox.
#
# Inert by default: a HARD no-op (exit 0, no output) unless the local
# ext-bridge is active (config/ext-bridge plus a valid secret file; no
# environment value can activate a home that never opted in). The watcher invokes this trusted repository script only after
# state/ext-watch.check.sh matches the expected byte-static identity shim.
#
# Appends one durable `ext-request <slug>` wake record for each newly claimed
# offer that still has an inbox file, and releases the claim again if that
# append fails, so a request is never claimed without a wake that survives the
# watcher dying. This mirrors fm-ext-intake.sh, which owns the same pattern.
# The matching line is also printed so the watcher nudges Firstmate; the
# watcher does not append a second record for this check.
# An already claimed offer stays silent, including after Firstmate restart, so
# each offer wakes once.
# Each poll also expires local bridge records past the retention window, the
# same way fm-x-poll.sh expires X-mode context.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-ext-lib.sh
. "$SCRIPT_DIR/fm-ext-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_ext_active "$FM_HOME" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

fm_ext_context_prune "$STATE"
fm_ext_outbox_prune "$STATE"

INBOX=$(fm_ext_inbox_dir)
CONTEXT=$(fm_ext_context_dir)
[ -d "$INBOX" ] && [ ! -L "$INBOX" ] || exit 0

for file in "$INBOX"/*.json; do
  [ -e "$file" ] || continue
  base=$(basename "$file")
  slug=${base%.json}
  fm_ext_slug_valid "$slug" || continue
  fm_ext_private_artifact_file_valid "$INBOX" "$base" 600 || continue
  rid=$(jq -r '.request_id // empty' "$file" 2>/dev/null) || continue
  fm_ext_request_id_valid "$rid" || continue
  expected=$(fm_ext_request_slug "$rid") || continue
  [ "$expected" = "$slug" ] || continue
  if fm_ext_private_artifact_file_valid "$CONTEXT" "$slug.offered.json" 600; then
    continue
  fi
  fm_ext_offer_registry_claim "$STATE" "$slug" "$rid"
  case $? in
    0) ;;
    *) continue ;;
  esac
  # Make the wake durable here rather than leaving it to the watcher: the
  # watcher can exit between this claim and its own append, and a claimed
  # offer never surfaces again, so that window silently dropped the request.
  if ! fm_wake_append check "$FM_EXT_WATCH_SHIM" "ext-request $slug"; then
    fm_ext_offer_registry_unclaim "$STATE" "$slug" || true
    continue
  fi
  printf 'ext-request %s\n' "$slug"
done

exit 0
