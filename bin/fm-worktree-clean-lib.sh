#!/usr/bin/env bash

fm_worktree_is_clean() {
  local worktree=$1 status_output
  status_output=$(git -C "$worktree" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null) || return 1
  [ -z "$status_output" ]
}
