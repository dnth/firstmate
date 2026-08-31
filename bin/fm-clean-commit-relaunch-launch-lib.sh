#!/usr/bin/env bash
# Private post-allocation launch implementation for fm-clean-commit-relaunch.
#
# This file is source-only implementation code, not an operator command.
# Its interface accepts only a destination identity and an already allocated
# worktree. It never receives, reads, or validates source relaunch authority,
# an exact commit, a handoff path, or relaunch environment state.

_FM_CLEAN_RELAUNCH_LAUNCH_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$_FM_CLEAN_RELAUNCH_LAUNCH_LIB_DIR/fm-task-inbox-lib.sh"

FM_CLEAN_RELAUNCH_LAUNCH_TARGET=
FM_CLEAN_RELAUNCH_LAUNCH_STATE=
FM_CLEAN_RELAUNCH_LAUNCH_WINDOW_ID=
FM_CLEAN_RELAUNCH_LAUNCH_CREATE_INTERRUPTED=0

fm_clean_relaunch_defer_window_creation_signal() {
  FM_CLEAN_RELAUNCH_LAUNCH_CREATE_INTERRUPTED=1
}

fm_clean_relaunch_shell_quote() {  # <value>
  local value=$1
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

fm_clean_relaunch_destination_meta_absent() {  # <state> <id>
  local state=$1 id=$2 artifact
  for artifact in "$state/$id.meta" "$state/$id.inbox" "$state/$id.status" "${TMPDIR:-/tmp}/fm-$id"; do
    [ ! -e "$artifact" ] && [ ! -L "$artifact" ] || return 1
  done
}

fm_clean_relaunch_launch_cleanup() {  # <destination-id>
  local id=$1 state=${FM_CLEAN_RELAUNCH_LAUNCH_STATE:-} window_id=${FM_CLEAN_RELAUNCH_LAUNCH_WINDOW_ID:-}
  [ -n "$window_id" ] && fm_backend_kill tmux "$window_id" >/dev/null 2>&1 || true
  [ -n "$state" ] || return 0
  rm -rf -- "${TMPDIR:-/tmp}/fm-$id"
  rm -rf -- "$state/$id.inbox"
  rm -f -- "$state/$id.meta" "$state/$id.status" "$state/$id.turn-ended" \
    "$state/$id.pi-ext.ts" "$state/$id.omp-ext.ts" "$state/$id.omp-ready" \
    "$state/$id.omp-started" "$state/$id.omp-doorbell-ready" "$state/$id.busy-state" \
    "$state/$id.omp-doorbell-ready.requests" "$state/$id.busy-gen" \
    "$state/$id.grok-turnend-token" "$state/$id.kimi-turnend-token" \
    "$state/$id.hermes-turnend-token" "$state/$id.hermes-session" "$state/$id.hermes-started"
}

fm_clean_relaunch_wait_for_ack() {  # <state> <id> <record>
  local state=$1 id=$2 record=$3 polls=${FM_CLEAN_COMMIT_RELAUNCH_ACK_POLLS:-120}
  local interval=${FM_CLEAN_COMMIT_RELAUNCH_ACK_INTERVAL:-0.5} handled
  case "$polls" in ''|*[!0-9]*|0) polls=120 ;; esac
  handled="$state/$id.inbox/handled/${record##*/}"
  while [ "$polls" -gt 0 ]; do
    [ -f "$handled" ] && return 0
    sleep "$interval"
    polls=$((polls - 1))
  done
  return 1
}

# fm_clean_relaunch_launch_allocated starts one fresh endpoint in an already
# validated clean worktree. The relaunch owner alone decides whether that
# worktree was allocated or which commit it contains.
#
# Interface:
#   <destination-id> <project-root> <allocated-worktree> <brief>
#   <harness> <backend> <mode> <yolo> <model> <effort>
#
# The first supported profile is codex on the reference tmux backend. Refusing
# every other tuple before endpoint creation is deliberate. Their lifecycle
# setup and acknowledgement semantics stay owned by generic fm-spawn until a
# profile can share this helper without relaunch-specific input.
fm_clean_relaunch_launch_allocated() {
  local id=$1 project=$2 worktree=$3 brief=$4 harness=$5 backend=$6 mode=$7 yolo=$8 model=$9 effort=${10}
  local state=${STATE:?STATE must be set by the relaunch owner}
  local session window target window_id task_tmp meta_tmp launch record handoff

  [ "$harness:$backend" = codex:tmux ] || {
    echo "error: allocated relaunch launch supports only codex/tmux" >&2
    return 1
  }
  [ -f "$brief" ] && [ ! -L "$brief" ] && [ -r "$brief" ] || {
    echo "error: destination brief is unreadable" >&2
    return 1
  }
  [ -d "$project" ] && [ -d "$worktree" ] && [ ! -L "$worktree" ] || {
    echo "error: destination worktree is unreadable" >&2
    return 1
  }
  [ "$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null || true)" = "$worktree" ] || {
    echo "error: allocated destination is not a worktree root" >&2
    return 1
  }
  fm_clean_relaunch_destination_meta_absent "$state" "$id" || {
    echo "error: destination state is already occupied" >&2
    return 1
  }
  fm_backend_source tmux || return 1
  session=$(fm_backend_tmux_container_ensure) || return 1
  window="fm-$id"
  target="$session:$window"
  FM_CLEAN_RELAUNCH_LAUNCH_STATE=$state
  trap fm_clean_relaunch_defer_window_creation_signal HUP INT TERM
  if window_id=$(fm_backend_tmux_create_task "$session" "$window" "$worktree"); then
    FM_CLEAN_RELAUNCH_LAUNCH_WINDOW_ID="$session:$window_id"
  else
    trap interrupted HUP INT TERM
    return 1
  fi
  trap interrupted HUP INT TERM
  [ "$FM_CLEAN_RELAUNCH_LAUNCH_CREATE_INTERRUPTED" -eq 0 ] || return 1

  task_tmp="${TMPDIR:-/tmp}/fm-$id"
  if [ -L "$task_tmp" ]; then
    echo "error: destination task temp root must not be a symlink" >&2
    return 1
  fi
  mkdir -p "$task_tmp/gotmp" || return 1

  meta_tmp=$(mktemp "$state/.${id}.meta.XXXXXX") || return 1
  if ! {
    printf 'window=%s\n' "$target"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$worktree"
    printf 'project=%s\n' "$project"
    printf 'harness=%s\n' "$harness"
    printf 'kind=ship\n'
    printf 'mode=%s\n' "$mode"
    printf 'yolo=%s\n' "$yolo"
    printf 'tasktmp=%s\n' "$task_tmp"
    printf 'model=%s\n' "$model"
    printf 'effort=%s\n' "$effort"
  } > "$meta_tmp"; then
    rm -f -- "$meta_tmp"
    return 1
  fi
  if ! mv -f -- "$meta_tmp" "$state/$id.meta"; then
    rm -f -- "$meta_tmp"
    return 1
  fi

  fm_backend_tmux_send_text_line "$target" "export GOTMPDIR=$(fm_clean_relaunch_shell_quote "$task_tmp/gotmp")" || return 1
  launch="codex"
  [ "$model" = default ] || launch="$launch --model $(fm_clean_relaunch_shell_quote "$model")"
  case "$effort" in
    low|medium|high|xhigh) launch="$launch -c $(fm_clean_relaunch_shell_quote "model_reasoning_effort=\"$effort\"")" ;;
  esac
  launch="$launch --dangerously-bypass-approvals-and-sandbox \$( $(fm_clean_relaunch_shell_quote "$FM_ROOT/bin/fm-operational-input.sh") encode launch-brief < $(fm_clean_relaunch_shell_quote "$brief") )"
  fm_backend_tmux_send_literal "$target" "$launch" || return 1
  fm_backend_tmux_send_key "$target" Enter || return 1
  handoff="${DATA:?DATA must be set by the relaunch owner}/$id/relaunch-handoff.json"

  record=$(fm_task_inbox_write "$state" "$id" "Read the durable preserved-work handoff at $handoff before continuing the task.") || return 1
  fm_task_inbox_ring tmux "$target" "$record" "$window" codex || return 1
  fm_clean_relaunch_wait_for_ack "$state" "$id" "$record" || {
    echo "error: destination worker did not acknowledge the preserved-work handoff" >&2
    return 1
  }
}
