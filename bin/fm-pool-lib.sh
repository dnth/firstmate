#!/usr/bin/env bash
# shellcheck shell=bash
# Shared predicates for treehouse-backed firstmate pool worktrees.
#
# A pool backing clone may legitimately carry an untracked root-level
# treehouse.toml, because that file is the pool's local treehouse config.
# Treat only that lone porcelain entry as clean.
# Every other porcelain entry is real uncommitted work.
#
# Every slot lifecycle path that judges a pool worktree must agree on this, or a
# slot that spawn accepted becomes a slot teardown/rehome refuses - which strands
# its treehouse lease until someone forces it. Callers that carry their own
# harness-noise allowlist filter through fm_pool_ignorable_porcelain_filter on
# top of it rather than restating the exemption.

fm_pool_ignorable_porcelain_filter() {  # porcelain lines on stdin
  grep -vFx '?? treehouse.toml' || true
}

fm_pool_real_porcelain() {  # <repo>
  local repo=$1 out
  out=$(git -C "$repo" status --porcelain --untracked-files=all 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | fm_pool_ignorable_porcelain_filter
}

fm_pool_worktree_clean() {  # <repo>
  local repo=$1 real
  real=$(fm_pool_real_porcelain "$repo") || return 1
  [ -z "$real" ]
}

fm_pool_first_real_porcelain_line() {  # <repo>
  local repo=$1 real
  real=$(fm_pool_real_porcelain "$repo") || return 1
  [ -n "$real" ] || return 1
  printf '%s\n' "${real%%$'\n'*}"
}

fm_pool_worktree_idle() {  # <repo>
  local repo=$1 root out pid path line
  root=$(cd "$repo" 2>/dev/null && pwd -P) || return 2
  if [ -n "${FM_POOL_LSOF_CWD_FILE:-}" ]; then
    out=$(cat "$FM_POOL_LSOF_CWD_FILE" 2>/dev/null) || return 2
  else
    command -v lsof >/dev/null 2>&1 || return 2
    out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 2
  fi
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p} ;;
      fcwd) ;;
      n*)
        path=${line#n}
        case "$path" in
          "$root"|"$root"/*) [ "$pid" = "${BASHPID:-$$}" ] || return 1 ;;
        esac
        ;;
    esac
  done <<EOF
$out
EOF
  return 0
}

fm_pool_real_directory() {  # <absolute normalized directory>
  local path=$1 physical
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path/" in *'/../'*|*'/./'*|*'//'*) return 1 ;; esac
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  physical=$(cd "$path" 2>/dev/null && pwd -P) || return 1
  [ "$physical" = "$path" ]
}

fm_treehouse_local_pool_validate() {  # <pool-root>
  local root=$1 child
  fm_pool_real_directory "$root" || return 1
  for child in .treehouse .firstmate-config; do
    fm_pool_real_directory "$root/$child" || return 1
  done
}

fm_treehouse_local_pool_prepare() {  # <pool-root>
  local root=$1 child
  fm_pool_real_directory "$root" || return 1
  for child in .treehouse .firstmate-config; do
    if [ ! -e "$root/$child" ] && [ ! -L "$root/$child" ]; then
      mkdir -- "$root/$child" || return 1
    fi
  done
  fm_treehouse_local_pool_validate "$root"
}

fm_treehouse_local_pool_prepare_directory() {  # <safe-parent> <child-name>
  local parent=$1 name=$2 path
  fm_pool_real_directory "$parent" || return 1
  case "$name" in ''|.|..|*/*) return 1 ;; esac
  path="$parent/$name"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    mkdir -- "$path" || return 1
  fi
  fm_pool_real_directory "$path"
}
