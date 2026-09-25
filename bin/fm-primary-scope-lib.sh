#!/usr/bin/env bash
# Usage: source bin/fm-primary-scope-lib.sh; fm_primary_scope_matches <root> <state>
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when this process runs inside an fm-spawn'd ordinary task worker's
# launch environment. bin/fm-spawn.sh exports FM_TASK_ID=<id> on every
# non-secondmate launch (ship, scout, prewalk, relaunch); a secondmate launch
# never carries it. The variable is set on the launch command itself, so the
# worker's harness and every tool it spawns inherit it. Whatever shape the
# worktree happens to have - including a reused Treehouse pool slot still
# carrying a retired secondmate's .fm-secondmate-home marker - a task worker is
# never a firstmate home owner.
fm_env_is_task_worker() {
  [ -n "${FM_TASK_ID:-}" ]
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
# A task-worker launch environment (FM_TASK_ID) is never in scope.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  # Launch-env identity wins over whatever markers the worktree carries.
  fm_env_is_task_worker && return 1
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] && [ ! -L "$state" ]
}
