#!/usr/bin/env bash
# Per-working-copy pre-push guard for spawned firstmate workers.
#
# bin/fm-spawn.sh runs `install <worktree> <dir>` for every ship and scout
# working copy, placing <dir> under the task's temp root (/tmp/fm-<id>/) and
# pointing the worker's git at it through command-scope GIT_CONFIG_*
# environment on the launch command (GIT_CONFIG_KEY_0=core.hooksPath). The
# guard therefore binds the worker's process tree only: nothing is written to
# the repository's shared config or common hooks dir, sibling worktrees are
# byte-identical before and after install, and fm-teardown's tasktmp removal
# retires the hooks dir with the task.
#
# install <worktree> <dir>
#   Records the worktree's canonical git common dir in <dir>/common-dir, then
#   emits one wrapper for every known git hook name, each execing
#   `dispatch <dir> <name>`. A full wrapper set is required because an
#   effective core.hooksPath replaces the repository's whole hooks directory:
#   without pass-through wrappers, project hooks (pre-commit, commit-msg, ...)
#   would silently stop running inside the worker.
#
# dispatch <dir> <name> [git's hook args]
#   Runs as the hook itself. Two duties:
#   1. For pre-push, when the pushed repository's canonical git common dir
#      matches the recorded one, inspect every destination ref on stdin and
#      refuse main, master, and the pushed remote's resolved default branch
#      (refs/remotes/<remote>/HEAD, falling back to origin/HEAD and
#      init.defaultBranch). A refusal prints the rule and the deliberate
#      bypass. The common-dir match means the guard also holds for sibling
#      worktrees and the primary checkout of that same repository when a push
#      runs under the worker's environment, while unrelated repositories -
#      scratch repos, test fixtures, other clones - are never guarded.
#   2. Chain to the repository's OWN hook for <name>: the repo's configured
#      core.hooksPath (--local, which ignores this command-scope injection) or
#      the default <common-dir>/hooks location. Chaining preserves whatever
#      hooks the project already had instead of shadowing them.
#
# This is an accident guard, not a security boundary: `git push --no-verify`
# or an explicit hooksPath/env override bypasses it by design. That bypass is
# the sanctioned escape for a deliberately captain-approved default-branch
# push; server-side rulesets remain the authoritative protection.
set -u

SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SELF="$SELF_DIR/$(basename -- "${BASH_SOURCE[0]}")"

usage() {
  printf '%s\n' \
    'usage: fm-prepush-guard.sh install <worktree> <dir>' \
    '       fm-prepush-guard.sh dispatch <dir> <hook-name> [args]' >&2
  exit 2
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

resolve_push_defaults() {  # <remote>
  local remote=$1 urls url default_ref default_branch resolved=''
  urls=$(git remote get-url --push --all "$remote" 2>/dev/null) || return 1
  [ -n "$urls" ] || return 1
  while IFS= read -r url; do
    [ -n "$url" ] || return 1
    default_ref=$(git ls-remote --symref "$url" HEAD 2>/dev/null) || return 1
    default_ref=$(printf '%s\n' "$default_ref" |
      awk '$1 == "ref:" && $3 == "HEAD" { print $2; exit }')
    case "$default_ref" in
      refs/heads/*) default_branch=${default_ref#refs/heads/} ;;
      *) return 1 ;;
    esac
    case " $resolved " in
      *" $default_branch "*) ;;
      *) resolved="$resolved $default_branch" ;;
    esac
  done <<EOF
$urls
EOF
  PUSH_DEFAULT_BRANCHES=$resolved
}

# Every hook name git may look up in hooksPath (githooks(5)), so the private
# dir can stand in for the repository's hooks dir without dropping any hook.
HOOK_NAMES=(
  applypatch-msg pre-applypatch post-applypatch
  pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit
  pre-rebase post-checkout post-merge pre-push
  pre-receive update proc-receive post-receive post-update
  reference-transaction push-to-checkout pre-auto-gc post-rewrite
  sendemail-validate fsmonitor-watchman
  p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit
  post-index-change
)

cmd_install() {  # <worktree> <dir>
  local wt=$1 dir=$2 common name self_q dir_q
  [ -d "$wt" ] || {
    echo "error: pre-push guard install worktree does not exist: $wt" >&2
    return 1
  }
  common=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || {
    echo "error: pre-push guard install target is not a git worktree: $wt" >&2
    return 1
  }
  case "$common" in
    /*) ;;
    *) common="$wt/$common" ;;
  esac
  common=$(cd "$common" 2>/dev/null && pwd -P) || {
    echo "error: pre-push guard could not canonicalize the git common dir for $wt" >&2
    return 1
  }
  if [ -L "$dir" ]; then
    echo "error: pre-push guard dir must not be a symlink: $dir" >&2
    return 1
  fi
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    echo "error: pre-push guard dir exists and is not a directory: $dir" >&2
    return 1
  fi
  mkdir -p "$dir" || {
    echo "error: pre-push guard could not create dir: $dir" >&2
    return 1
  }
  if [ -L "$dir/common-dir" ] || { [ -e "$dir/common-dir" ] && [ ! -f "$dir/common-dir" ]; }; then
    echo "error: pre-push guard common-dir entry must be a regular file: $dir/common-dir" >&2
    return 1
  fi
  if [ -e "$dir/common-dir" ] && ! rm -f "$dir/common-dir"; then
    echo "error: pre-push guard could not replace $dir/common-dir" >&2
    return 1
  fi
  printf '%s\n' "$common" > "$dir/common-dir" || {
    echo "error: pre-push guard could not record the common dir in $dir" >&2
    return 1
  }
  self_q=$(shell_quote "$SELF")
  dir_q=$(shell_quote "$dir")
  for name in "${HOOK_NAMES[@]}"; do
    if [ -L "$dir/$name" ] || { [ -e "$dir/$name" ] && [ ! -f "$dir/$name" ]; }; then
      echo "error: pre-push guard wrapper entry must be a regular file: $dir/$name" >&2
      return 1
    fi
    if [ -e "$dir/$name" ] && ! rm -f "$dir/$name"; then
      echo "error: pre-push guard could not replace wrapper $dir/$name" >&2
      return 1
    fi
    printf '#!/bin/sh\nexec %s dispatch %s %s "$@"\n' "$self_q" "$dir_q" "$name" > "$dir/$name" || {
      echo "error: pre-push guard could not write wrapper $dir/$name" >&2
      return 1
    }
    chmod +x "$dir/$name" || {
      echo "error: pre-push guard could not mark wrapper executable: $dir/$name" >&2
      return 1
    }
  done
}

# Canonicalize <path> (may be relative to $2, the dir the path was reported
# from). Prints the physical path, or nothing when it cannot be resolved.
canon_dir() {  # <path> <base>
  local p=$1 base=$2
  case "$p" in
    /*) ;;
    *) p="$base/$p" ;;
  esac
  cd "$p" 2>/dev/null && pwd -P
}

cmd_dispatch() {  # <dir> <hook-name> [git's hook args]
  local dir=$1 name=$2 common='' hooks_dir cand cand_dir
  shift 2
  local hook_args=("$@")
  dir=$(canon_dir "$dir" "$PWD") || exit 0

  # Resolve the pushed repository's canonical common dir (the scope key) once;
  # it also supplies the default hooks location below.
  common=$(git rev-parse --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    common=$(canon_dir "$common" "$PWD" || true)
  fi

  # The repository's own hook for <name>: its repo-configured core.hooksPath
  # (--local reads the repo config file only, never this command-scope
  # injection), else the default common-dir hooks location.
  hooks_dir=$(git config --local --get core.hooksPath 2>/dev/null || true)
  if [ -n "$hooks_dir" ]; then
    hooks_dir=$(canon_dir "$hooks_dir" "$PWD" || true)
  elif [ -n "$common" ]; then
    hooks_dir="$common/hooks"
  fi
  cand=
  if [ -n "$hooks_dir" ] && [ -d "$hooks_dir" ]; then
    cand="$hooks_dir/$name"
    # A candidate inside this guard's own dir, or resolving back to this
    # script, is not a repository hook: chaining it would recurse.
    case "$cand" in
      "$dir"/*) cand= ;;
    esac
    if [ -n "$cand" ] && [ -e "$cand" ]; then
      cand_dir=$(canon_dir "$(dirname -- "$cand")" "$PWD" || true)
      [ "$cand_dir" = "$dir" ] && cand=
      [ -n "$cand" ] && [ "$cand" -ef "$SELF" ] && cand=
    fi
  fi

  if [ "$name" = pre-push ]; then
    local remote_name=${1:-} recorded default_branch input line
    local blocked='' remote_ref ref_name
    recorded=$(cat "$dir/common-dir" 2>/dev/null || true)
    if [ -n "$common" ] && [ -n "$recorded" ] && [ "$common" = "$recorded" ]; then
      # Resolve the pushed remote's current default branch. main/master are
      # always protected regardless.
      PUSH_DEFAULT_BRANCHES=
      if [ -n "$remote_name" ]; then
        resolve_push_defaults "$remote_name" || true
      fi
      default_branch=$PUSH_DEFAULT_BRANCHES
      input=$(cat)
      if [ -z "$default_branch" ]; then
        printf '%s\n' \
          "fm-prepush-guard: refused push on remote '$remote_name' because its default branch could not be resolved." \
          "Rule: a spawned working copy may not push when the repository's default branch is unknown - push a task branch (fm/<task>) only after the remote is available." \
          "Deliberate bypass for a captain-authorized push: git push --no-verify <remote> <refspec>" >&2
        exit 1
      fi
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        # stdin records: <local ref> <local sha> <remote ref> <remote sha>.
        # Ref names cannot contain spaces or glob characters, so word
        # splitting is the intended parse here.
        # shellcheck disable=SC2086
        set -- $line
        remote_ref=${3:-}
        ref_name=${remote_ref#refs/heads/}
        [ -n "$ref_name" ] || continue
        case " main master $default_branch " in
          *" $ref_name "*) blocked=$remote_ref; break ;;
        esac
      done <<EOF
$input
EOF
      if [ -n "$blocked" ]; then
        printf '%s\n' \
          "fm-prepush-guard: refused push to '$blocked' on remote '$remote_name'." \
          "Rule: a spawned working copy may not push to main, master, or the repository's default branch - push a task branch (fm/<task>) and open a PR instead." \
          "Deliberate bypass for a captain-authorized push: git push --no-verify <remote> <refspec>" >&2
        exit 1
      fi
      # Allowed push: replay the captured records into the repo's own hook.
      if [ -n "$cand" ] && [ -x "$cand" ]; then
        if [ -n "$input" ]; then
          printf '%s\n' "$input" | "$cand" ${hook_args[@]+"${hook_args[@]}"}
        else
          "$cand" ${hook_args[@]+"${hook_args[@]}"} </dev/null
        fi
        exit $?
      fi
      exit 0
    fi
  fi
  # Out of scope, or a non-push hook: chain through with inherited stdin.
  if [ -n "$cand" ] && [ -x "$cand" ]; then
    exec "$cand" ${hook_args[@]+"${hook_args[@]}"}
  fi
  exit 0
}

case "${1:-}" in
  install)
    [ "$#" -eq 3 ] || usage
    cmd_install "$2" "$3"
    ;;
  dispatch)
    [ "$#" -ge 3 ] || usage
    cmd_dispatch "$2" "$3" "${@:4}"
    ;;
  *) usage ;;
esac
