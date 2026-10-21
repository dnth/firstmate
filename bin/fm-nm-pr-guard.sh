#!/usr/bin/env bash
# Per-worker No-Mistakes PR guard for spawned ship workers.
#
# A ship task in no-mistakes mode must let the No-Mistakes pipeline create its
# pull request: a worker-created PR exists before any run on its branch, so
# every downstream gate (fm-pr-check.sh, fm-pr-merge.sh) has no run to prove.
# bin/fm-spawn.sh installs this guard for that mode only, into a task-private
# directory (<tasktmp>/nm-pr-guard), and puts that directory first on the
# worker's PATH together with FM_NM_PR_GUARD=1 on the launch command. The guard
# therefore binds the worker's process tree only: nothing is written to the
# repository, sibling worktrees stay byte-identical, and fm-teardown's tasktmp
# removal retires it with the task.
#
# install <dir>
#   Writes `gh` and `gh-axi` wrappers, each execing `run <dir> <tool> "$@"`.
#
# run <dir> <tool> [args...]
#   With FM_NM_PR_GUARD=1, refuses a PR creation initiated by the worker:
#     - `<tool> pr create ...`
#     - `<tool> api` posting to a repository's pulls endpoint
#   The refusal is one line on stderr naming the No-Mistakes pipeline, exit 2.
#   Every other invocation, and every invocation without the marker, execs the
#   real tool resolved from PATH with <dir> skipped.
#   No-Mistakes itself runs `gh pr create` from its own daemon process tree,
#   which never carries the marker and never has <dir> on PATH (fm-spawn sets
#   both on the worker launch only), so pipeline PR creation is unaffected.
#
# This is an accident guard, not a security boundary: an absolute path
# (`/usr/bin/gh`), another API client (including a GitLab `glab mr create`),
# a login shell that rewrites PATH ahead of the wrapper directory, or clearing
# FM_NM_PR_GUARD bypasses it by design. bin/fm-watch.sh's nm_pr_unguarded_tick
# is the detection backstop for exactly that bypass.
# tests/fm-nm-pr-guard.test.sh owns portable coverage.
set -u

SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SELF="$SELF_DIR/$(basename -- "${BASH_SOURCE[0]}")"

usage() {
  printf '%s\n' \
    'usage: fm-nm-pr-guard.sh install <dir>' \
    '       fm-nm-pr-guard.sh run <dir> <tool> [args...]' >&2
  exit 2
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# Print 0 when the arguments name a PR creation.
is_pr_create() {  # <args...>
  local arg sub='' i=0
  local -a args=("$@")
  # Only a global option and its value can precede the subcommand.
  while [ "$i" -lt "${#args[@]}" ]; do
    arg=${args[$i]}
    case "$arg" in
      -R|--repo|--hostname) i=$((i + 2)) ;;
      --repo=*|--hostname=*) i=$((i + 1)) ;;
      -*) i=$((i + 1)) ;;
      *) sub=$arg; break ;;
    esac
  done
  case "$sub" in
    pr)
      i=$((i + 1))
      while [ "$i" -lt "${#args[@]}" ]; do
        arg=${args[$i]}
        case "$arg" in
          -R|--repo) i=$((i + 2)); continue ;;
          -*) i=$((i + 1)); continue ;;
          create) return 0 ;;
          *) return 1 ;;
        esac
      done
      return 1
      ;;
    api)
      local -a rest=("${args[@]:$((i + 1))}")
      api_posts_to_pulls "${rest[@]}"
      ;;
    *) return 1 ;;
  esac
}

# Print 0 when `gh api` arguments POST to a repository's pulls endpoint.
api_posts_to_pulls() {  # <api args...>
  local arg method='' path='' fields=0 i=0
  local -a args=("$@")
  while [ "$i" -lt "${#args[@]}" ]; do
    arg=${args[$i]}
    case "$arg" in
      -X|--method) i=$((i + 1)); method=${args[$i]:-} ;;
      --method=*) method=${arg#--method=} ;;
      -X?*) method=${arg#-X}; method=${method#=} ;;
      -f|--raw-field|-F|--field) fields=1; i=$((i + 1)) ;;
      -f?*|-F?*|--field=*|--raw-field=*|--input=*) fields=1 ;;
      --input) fields=1; i=$((i + 1)) ;;
      -H|--header|--hostname|--cache|-p|--preview|-q|--jq|-t|--template) i=$((i + 1)) ;;
      -*) ;;
      *) [ -n "$path" ] || path=$arg ;;
    esac
    i=$((i + 1))
  done
  [ -n "$path" ] || return 1
  path=${path%%\?*}
  path=${path#https://api.github.com}
  path=${path#/}
  case "$path" in
    *repos/*/pulls) ;;
    *) return 1 ;;
  esac
  method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
  if [ -z "$method" ]; then
    # `gh api` reads with GET unless fields or an input body are supplied.
    [ "$fields" -eq 1 ] || return 1
    return 0
  fi
  [ "$method" = POST ]
}

# Print the real <tool> resolved from PATH, skipping the guard's own directory.
real_tool() {  # <dir> <tool>
  local dir=$1 tool=$2 dir_real entry candidate entry_real
  dir_real=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    candidate="$entry/$tool"
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    entry_real=$(CDPATH='' cd -- "$entry" 2>/dev/null && pwd -P) || continue
    [ "$entry_real" = "$dir_real" ] && continue
    printf '%s\n' "$candidate"
    return 0
  done <<EOF
$(printf '%s' "${PATH:-}" | tr ':' '\n')
EOF
  return 1
}

cmd_install() {  # <dir>
  local dir=${1:-} tool self_q dir_q
  [ -n "$dir" ] || usage
  if [ -L "$dir" ]; then
    echo "error: no-mistakes PR guard dir must not be a symlink: $dir" >&2
    return 1
  fi
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    echo "error: no-mistakes PR guard dir exists and is not a directory: $dir" >&2
    return 1
  fi
  mkdir -p "$dir" || {
    echo "error: no-mistakes PR guard could not create dir: $dir" >&2
    return 1
  }
  chmod 700 "$dir" || {
    echo "error: no-mistakes PR guard could not secure dir: $dir" >&2
    return 1
  }
  self_q=$(shell_quote "$SELF")
  dir_q=$(shell_quote "$dir")
  for tool in gh gh-axi; do
    if [ -L "$dir/$tool" ] || { [ -e "$dir/$tool" ] && [ ! -f "$dir/$tool" ]; }; then
      echo "error: no-mistakes PR guard wrapper must be a regular file: $dir/$tool" >&2
      return 1
    fi
    if [ -e "$dir/$tool" ] && ! rm -f "$dir/$tool"; then
      echo "error: no-mistakes PR guard could not replace wrapper $dir/$tool" >&2
      return 1
    fi
    printf '#!/bin/sh\nexec %s run %s %s "$@"\n' "$self_q" "$dir_q" "$tool" > "$dir/$tool" || {
      echo "error: no-mistakes PR guard could not write wrapper $dir/$tool" >&2
      return 1
    }
    chmod 700 "$dir/$tool" || {
      echo "error: no-mistakes PR guard could not mark wrapper executable: $dir/$tool" >&2
      return 1
    }
  done
}

cmd_run() {  # <dir> <tool> [args...]
  local dir=${1:-} tool=${2:-} real
  [ -n "$dir" ] && [ -n "$tool" ] || usage
  shift 2
  case "$tool" in
    gh|gh-axi) ;;
    *) echo "error: no-mistakes PR guard does not wrap '$tool'" >&2; return 2 ;;
  esac
  if [ "${FM_NM_PR_GUARD:-}" = 1 ] && is_pr_create "$@"; then
    printf '%s\n' \
      "blocked: this no-mistakes task must let the No-Mistakes pipeline create its PR - run /no-mistakes (no-mistakes axi run) and let it raise the PR instead of creating it yourself with $tool." >&2
    return 2
  fi
  real=$(real_tool "$dir" "$tool") || {
    echo "error: no-mistakes PR guard could not resolve the real $tool on PATH" >&2
    return 127
  }
  exec "$real" "$@"
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  run) shift; cmd_run "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
