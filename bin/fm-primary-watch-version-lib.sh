#!/usr/bin/env bash
# fm-primary-watch-version-lib.sh - the one definition of OMP and Pi loaded
# extension marker versions.
#
# A primary watcher is its runtime adapter (.pi/extensions/fm-primary-pi-watch.ts
# or .omp/extensions/fm-primary-omp.ts) plus the shared lifecycle core it binds
# (bin/fm-primary-watch-core.ts).
# OMP additionally routes through .omp/extensions/lib/fm-branch-dispatch.ts and
# .omp/extensions/lib/fm-task-inbox-doorbell.ts; fm_omp_primary_closure_paths is
# the one list of that closure.
# The version hashes those files in runtime order, exactly as the core does when
# it publishes the marker, so no live session keeps stale loaded behavior behind
# a still-matching marker.
# fm_omp_primary_version_at_commit computes the same version from one commit's
# objects, and fm_omp_primary_version_fast_forwarded_from uses it to explain a
# loaded version by the checkout's own recorded fast-forwards (its comment owns
# that rule).
#
# The adapter resolves its core through <adapter-dir>/../../bin, so the core is
# always <fm-root>/bin/fm-primary-watch-core.ts for the same root that owns the
# adapter. Missing files or a missing SHA-256 utility return nonzero, which every
# caller already treats as "not loaded" rather than as a match.
#
# The OMP supervision branch marker hashes its extension followed by the branch
# dispatch, async-exec, and model-picker helpers, matching its in-process producer.
# Missing files or a missing SHA-256 utility return nonzero, which callers treat
# as "not loaded" rather than as a match.
#
# No side effects on source. set -u / set -e safe.

fm_version_hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print "sha256:" $1}'
  else
    return 1
  fi
}

fm_extension_version_hash() {
  cat "$@" | fm_version_hash_stdin
}

# The OMP primary closure, relative to its Firstmate root, in the runtime order
# the core hashes it. Every OMP primary version below is computed over exactly
# these paths, whether they are read from a checkout's files or one commit's
# objects.
fm_omp_primary_closure_paths() {
  printf '%s\n' \
    .omp/extensions/fm-primary-omp.ts \
    bin/fm-primary-watch-core.ts \
    .omp/extensions/lib/fm-branch-dispatch.ts \
    .omp/extensions/lib/fm-task-inbox-doorbell.ts
}

fm_primary_watch_version() {  # <extension-file> <fm-root> -> sha256:<hex>
  local extension=${1:-} root=${2:-} core path
  [ -n "$extension" ] && [ -f "$extension" ] || return 1
  [ -n "$root" ] || return 1
  if [ "$extension" = "$root/.omp/extensions/fm-primary-omp.ts" ]; then
    set --
    while IFS= read -r path; do
      [ -f "$root/$path" ] || return 1
      set -- "$@" "$root/$path"
    done <<EOF
$(fm_omp_primary_closure_paths)
EOF
    fm_extension_version_hash "$@"
    return
  fi
  core="$root/bin/fm-primary-watch-core.ts"
  [ -f "$core" ] || return 1
  fm_extension_version_hash "$extension" "$core"
}

# The OMP primary version of one commit's committed closure, read from git
# objects rather than the working tree, so a loaded marker can be compared with
# a commit the checkout used to be at.
fm_omp_primary_version_at_commit() {  # <git-checkout> <commit> -> sha256:<hex>
  local checkout=${1:-} commit=${2:-} path
  [ -n "$checkout" ] || return 1
  case "$commit" in ''|*[!0-9a-f]*) return 1 ;; esac
  while IFS= read -r path; do
    [ "$(git -C "$checkout" cat-file -t "$commit:$path" 2>/dev/null)" = blob ] || return 1
  done <<EOF
$(fm_omp_primary_closure_paths)
EOF
  fm_omp_primary_closure_paths | while IFS= read -r path; do
    git -C "$checkout" cat-file blob "$commit:$path"
  done | fm_version_hash_stdin
}

# Explain a loaded OMP primary version that differs from the checkout's tracked
# closure by the checkout's own recorded fast-forwards. Git appends the HEAD
# reflog entry in the same operation that moves HEAD, so this record cannot
# lag or lead the update it describes. Walking back from HEAD, every earlier
# position must be an ancestor of the position after it; the first position
# whose committed closure has <version> is printed and explains it. A rewind,
# a non-fast-forward move, a missing or unreadable reflog, or a version that no
# recorded position committed explains nothing, so the caller keeps refusing.
# The walk is bounded by FM_OMP_PRIOR_CLOSURE_REFLOG_LIMIT distinct positions.
fm_omp_primary_version_fast_forwarded_from() {  # <git-checkout> <version> -> prints the prior commit
  local checkout=${1:-} version=${2:-} limit=${FM_OMP_PRIOR_CLOSURE_REFLOG_LIMIT:-64}
  local head positions prev commit seen=0
  [ -n "$checkout" ] && [ -n "$version" ] || return 1
  case "$limit" in ''|*[!0-9]*) return 1 ;; esac
  head=$(git -C "$checkout" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null) || return 1
  positions=$(git -C "$checkout" log -g --format=%H HEAD 2>/dev/null) || return 1
  prev=$head
  while IFS= read -r commit; do
    case "$commit" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "$commit" != "$prev" ] || continue
    seen=$((seen + 1))
    [ "$seen" -le "$limit" ] || return 1
    git -C "$checkout" merge-base --is-ancestor "$commit" "$prev" 2>/dev/null || return 1
    if [ "$(fm_omp_primary_version_at_commit "$checkout" "$commit" 2>/dev/null || true)" = "$version" ]; then
      printf '%s\n' "$commit"
      return 0
    fi
    prev=$commit
  done <<EOF
$positions
EOF
  return 1
}

fm_omp_branch_extension_version() {  # <extension-file> <fm-root> -> sha256:<hex>
  local extension=${1:-} root=${2:-} dispatch async_exec picker
  [ -n "$extension" ] && [ -f "$extension" ] || return 1
  [ -n "$root" ] || return 1
  dispatch="$root/.omp/extensions/lib/fm-branch-dispatch.ts"
  async_exec="$root/.omp/extensions/lib/fm-async-exec.ts"
  picker="$root/.omp/extensions/lib/fm-branch-model-picker.ts"
  [ -f "$dispatch" ] && [ -f "$async_exec" ] && [ -f "$picker" ] || return 1
  fm_extension_version_hash "$extension" "$dispatch" "$async_exec" "$picker"
}
