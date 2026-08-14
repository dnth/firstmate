#!/usr/bin/env bash
# Treehouse command boundary for RunPod-local pools.
# Outside the RunPod sandbox it is a transparent exec wrapper.
# Inside the sandbox it preserves each repository's Treehouse settings while
# replacing only its pool root in an isolated overlay under the validated local
# container-storage root; it never edits the repository configuration.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TREEHOUSE_BIN=$(command -v treehouse 2>/dev/null) || {
  echo "error: treehouse is required" >&2
  exit 1
}
DOWNSTREAM_GIT=$(command -v git 2>/dev/null) || {
  echo "error: git is required for Treehouse configuration" >&2
  exit 1
}
# shellcheck source=bin/fm-pool-lib.sh
. "$SCRIPT_DIR/fm-pool-lib.sh"

if [ "${IS_SANDBOX:-0}" != 1 ]; then
  exec "$TREEHOUSE_BIN" "$@"
fi

pool_root=${FM_TREEHOUSE_LOCAL_ROOT:-}
case "$pool_root" in
  /*) ;;
  *) echo "error: RunPod Treehouse requires an absolute local pool root" >&2; exit 1 ;;
esac
case "$pool_root/" in
  *'/../'*|*'/./'*|*'//'* )
    echo "error: RunPod Treehouse requires a normalized local pool root" >&2
    exit 1
    ;;
esac
[ -d "$pool_root" ] && [ ! -L "$pool_root" ] || {
  echo "error: RunPod Treehouse requires a real local pool directory" >&2
  exit 1
}
fm_treehouse_root_prepare_existing "$pool_root" || {
  echo "error: RunPod Treehouse requires physically contained pool directories" >&2
  exit 1
}

repo_root=$("$DOWNSTREAM_GIT" -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || {
  echo "error: RunPod Treehouse could not read the repository root" >&2
  exit 1
}
repo_config="$repo_root/treehouse.toml"
if [ ! -e "$repo_config" ] && [ ! -L "$repo_config" ]; then
  exec "$TREEHOUSE_BIN" "$@"
fi
[ -f "$repo_config" ] && [ ! -L "$repo_config" ] || {
  echo "error: refusing unsafe repository Treehouse config" >&2
  exit 1
}

overlay_key=$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update(process.argv[1]).digest("hex"))' \
  "$repo_root") || exit 1
overlay_repo=$(fm_treehouse_root_prepare_overlay "$pool_root" "$overlay_key" "${repo_root##*/}") || exit 1
overlay_config=$(mktemp "$overlay_repo/.treehouse.toml.XXXXXX") || exit 1
trap 'rm -f -- "$overlay_config"' EXIT
if ! fm_treehouse_root_config_rewrite_overlay "$repo_config" "$overlay_config" "$pool_root"; then
  echo "error: repository Treehouse config could not be routed to the RunPod-local pool" >&2
  exit 1
fi
mv -f -- "$overlay_config" "$overlay_repo/treehouse.toml" || exit 1
trap - EXIT

(
  cd "$overlay_repo" || exit 1
  FM_TREEHOUSE_CONFIG_OVERLAY_REPO="$overlay_repo" \
  FM_TREEHOUSE_CONFIG_SOURCE_REPO="$repo_root" \
  FM_TREEHOUSE_CONFIG_DOWNSTREAM_GIT="$DOWNSTREAM_GIT" \
  PATH="$SCRIPT_DIR/treehouse-config-git:$PATH" \
    "$TREEHOUSE_BIN" "$@"
)
status=$?
exit "$status"
