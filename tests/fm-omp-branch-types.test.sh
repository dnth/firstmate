#!/usr/bin/env bash
# Strict no-emit contract check for the tracked Firstmate OMP extensions.
#
# This is the mechanical guard for the supervision-branch port: it typechecks
# .omp/extensions/fm-branch-supervision-omp.ts (and the sibling OMP extensions
# and the shared watcher core it wires into) against the INSTALLED
# @oh-my-pi/pi-coding-agent SDK, so a renamed or removed named export, an option
# the SDK no longer accepts, or an effort level added to or removed from OMP's
# Effort union fails the build here rather than at load time. The extension's
# BRANCH_EFFORT_LEVELS assertion in particular is a compile-time pin against
# OMP's own Effort catalog.
set -u

command -v tsc >/dev/null 2>&1 || { echo "skip: tsc not found for OMP extension typecheck"; exit 0; }

OMP_PACKAGE_DIR=${FM_OMP_PACKAGE_DIR:-"${BUN_INSTALL:-$HOME/.bun}/install/global/node_modules/@oh-my-pi/pi-coding-agent"}
if [ ! -f "$OMP_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @oh-my-pi/pi-coding-agent package not found (set FM_OMP_PACKAGE_DIR to override)"
  exit 0
fi
# The package lives inside the global node_modules that also holds its
# @oh-my-pi/* peers, @types/node, and every other dependency the extensions
# resolve. Symlinking that one directory as the temp project's node_modules is
# what lets NodeNext resolution find the whole graph.
OMP_NODE_MODULES=$(cd "$OMP_PACKAGE_DIR/.." && cd .. && pwd)
if [ ! -d "$OMP_NODE_MODULES/@types/node" ]; then
  echo "not ok - installed OMP package is missing Node declarations (@types/node)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-branch-types.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/.omp/extensions/lib" "$TMP_ROOT/bin"
cp "$ROOT/.omp/extensions/fm-branch-supervision-omp.ts" "$TMP_ROOT/.omp/extensions/fm-branch-supervision-omp.ts"
cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$TMP_ROOT/.omp/extensions/fm-primary-omp.ts"
cp "$ROOT/.omp/extensions/fm-fleet-hooks.ts" "$TMP_ROOT/.omp/extensions/fm-fleet-hooks.ts"
cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$TMP_ROOT/.omp/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.omp/extensions/lib/fm-async-exec.ts" "$TMP_ROOT/.omp/extensions/lib/fm-async-exec.ts"
cp "$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$TMP_ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
cp "$ROOT/.omp/extensions/lib/fm-branch-model-picker.ts" "$TMP_ROOT/.omp/extensions/lib/fm-branch-model-picker.ts"
cp "$ROOT/bin/fm-primary-watch-core.ts" "$TMP_ROOT/bin/fm-primary-watch-core.ts"
ln -s "$OMP_NODE_MODULES" "$TMP_ROOT/node_modules"

cat > "$TMP_ROOT/package.json" <<'JSON'
{"type":"module"}
JSON
cat > "$TMP_ROOT/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2022",
    "types": ["node"]
  },
  "include": [".omp/extensions/*.ts", ".omp/extensions/lib/*.ts", "bin/*.ts"]
}
JSON

tsc -p "$TMP_ROOT/tsconfig.json" || exit 1
version=$(jq -r '.version' "$OMP_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
printf 'ok - tracked OMP extensions pass strict no-emit typecheck against @oh-my-pi/pi-coding-agent %s\n' "$version"
