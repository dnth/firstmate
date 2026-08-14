#!/usr/bin/env bash
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
overlay_repo="$pool_root/.firstmate-config/$overlay_key/${repo_root##*/}"
mkdir -p "$overlay_repo" || exit 1
overlay_config=$(mktemp "$overlay_repo/.treehouse.toml.XXXXXX") || exit 1
trap 'rm -f -- "$overlay_config"' EXIT
if ! node - "$repo_config" "$overlay_config" "$pool_root" <<'NODE'
const fs = require("fs");
const [source, destination, root] = process.argv.slice(2);
const lines = fs.readFileSync(source, "utf8").replace(/^\uFEFF/, "").split(/\r?\n/);
const replacement = `root = ${JSON.stringify(root)}`;
let section = lines.findIndex((line) => /^\s*\[/.test(line));
if (section < 0) section = lines.length;
let rootIndex = -1;
for (let index = 0; index < section; index += 1) {
  if (!/^\s*root\s*=/.test(lines[index])) continue;
  if (rootIndex !== -1) process.exit(2);
  rootIndex = index;
}
if (rootIndex === -1) {
  lines.splice(section, 0, replacement);
} else {
  const value = lines[rootIndex].replace(/^\s*root\s*=\s*/, "");
  if (value.startsWith("'''")) {
    let end = value.includes("'''", 3) ? rootIndex : rootIndex + 1;
    while (end < lines.length && !lines[end].includes("'''")) end += 1;
    if (end >= lines.length) process.exit(2);
    lines.splice(rootIndex, end - rootIndex + 1, replacement);
  } else if (value.startsWith('"""')) {
    let end = value.includes('"""', 3) ? rootIndex : rootIndex + 1;
    while (end < lines.length && !lines[end].includes('"""')) end += 1;
    if (end >= lines.length) process.exit(2);
    lines.splice(rootIndex, end - rootIndex + 1, replacement);
  } else {
    lines[rootIndex] = replacement;
  }
}
fs.writeFileSync(destination, lines.join("\n"));
NODE
then
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
