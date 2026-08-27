#!/usr/bin/env bash
# fm-primary-watch-version-lib.sh - the one definition of OMP and Pi loaded
# extension marker versions.
#
# A primary watcher is its runtime adapter (.pi/extensions/fm-primary-pi-watch.ts
# or .omp/extensions/fm-primary-omp.ts) plus the shared lifecycle core it binds
# (bin/fm-primary-watch-core.ts).
# OMP additionally routes through .omp/extensions/lib/fm-branch-dispatch.ts.
# The version hashes those files in runtime order, exactly as the core does when
# it publishes the marker, so no live session keeps stale loaded behavior behind
# a still-matching marker.
#
# The adapter resolves its core through <adapter-dir>/../../bin, so the core is
# always <fm-root>/bin/fm-primary-watch-core.ts for the same root that owns the
# adapter. Missing files or a missing SHA-256 utility return nonzero, which every
# caller already treats as "not loaded" rather than as a match.
#
# The OMP supervision branch marker hashes its extension followed by the branch
# dispatch and model-picker helpers, matching its in-process producer.
# Missing files or a missing SHA-256 utility return nonzero, which callers treat
# as "not loaded" rather than as a match.
#
# No side effects on source. set -u / set -e safe.

fm_extension_version_hash() {
  if command -v shasum >/dev/null 2>&1; then
    cat "$@" | shasum -a 256 | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    cat "$@" | sha256sum | awk '{print "sha256:" $1}'
  else
    return 1
  fi
}

fm_primary_watch_version() {  # <extension-file> <fm-root> -> sha256:<hex>
  local extension=${1:-} root=${2:-} core dispatch
  [ -n "$extension" ] && [ -f "$extension" ] || return 1
  [ -n "$root" ] || return 1
  core="$root/bin/fm-primary-watch-core.ts"
  [ -f "$core" ] || return 1
  dispatch=
  if [ "$extension" = "$root/.omp/extensions/fm-primary-omp.ts" ]; then
    dispatch="$root/.omp/extensions/lib/fm-branch-dispatch.ts"
    [ -f "$dispatch" ] || return 1
  fi
  set -- "$extension" "$core"
  [ -z "$dispatch" ] || set -- "$@" "$dispatch"
  fm_extension_version_hash "$@"
}

fm_omp_branch_extension_version() {  # <extension-file> <fm-root> -> sha256:<hex>
  local extension=${1:-} root=${2:-} dispatch picker
  [ -n "$extension" ] && [ -f "$extension" ] || return 1
  [ -n "$root" ] || return 1
  dispatch="$root/.omp/extensions/lib/fm-branch-dispatch.ts"
  picker="$root/.omp/extensions/lib/fm-branch-model-picker.ts"
  [ -f "$dispatch" ] && [ -f "$picker" ] || return 1
  fm_extension_version_hash "$extension" "$dispatch" "$picker"
}
