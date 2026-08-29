#!/usr/bin/env bash
# tests/fm-send-inbox-doorbell-live-e2e.test.sh - live installed-harness proof
# that real workers follow the constant doorbell, act on the durable record,
# and acknowledge it by moving the record into handled/.
#
# Run with FM_SEND_INBOX_LIVE_E2E=1.
# This spends one small model turn per installed supported harness and uses a private tmux
# server only; it does not start, stop, or otherwise drive Herdr lifecycle.
# Codex and OMP are mandatory. All supported local harnesses are always
# discovered. Tune the per-harness wait with FM_SEND_INBOX_LIVE_TIMEOUT
# (default 240 seconds).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_SEND_INBOX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SEND_INBOX_LIVE_E2E=1 to run the live steering-inbox doorbell guard"
  exit 0
fi

command -v tmux >/dev/null 2>&1 \
  || { echo "not ok - live inbox guard requires tmux" >&2; exit 1; }
unset NO_MISTAKES_GATE

SOCKET="fm-inbox-live-$$"
SESSION=inboxlive
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-live.XXXXXX") || exit 1
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_SEND_INBOX_LIVE_TIMEOUT:-240}
CHECKED=0
FAILED=0

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  if [ "${FM_SEND_INBOX_LIVE_KEEP:-0}" = 1 ]; then
    printf '# preserved live inbox lab: %s socket=%s\n' "$LAB" "$SOCKET" >&2
    return
  fi
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
printf '%q ' "\$@" >> "$LAB/tmux.log"
printf '\n' >> "$LAB/tmux.log"
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$LAB"
tmux -L "$SOCKET" set-option -g remain-on-exit on

harness_binary() {
  local harness=$1 selected
  selected=$(command -v "$harness" 2>/dev/null) && {
    printf '%s' "$selected"
    return 0
  }
  case "$harness" in
    kimi)
      [ -x "$HOME/.kimi-code/bin/kimi" ] || return 1
      printf '%s' "$HOME/.kimi-code/bin/kimi"
      ;;
    hermes)
      [ -x "$HOME/.local/bin/hermes" ] || return 1
      printf '%s' "$HOME/.local/bin/hermes"
      ;;
    *) return 1 ;;
  esac
}

harness_version() {
  local version
  version=$("$1" --version 2>/dev/null | head -1) || true
  printf '%s' "${version:-version-unknown}"
}

launch_command() {  # <harness> <binary> <project>
  local harness=$1 binary=$2 project=$3 binary_q project_q
  printf -v binary_q '%q' "$binary"
  printf -v project_q '%q' "$project"
  case "$harness" in
    claude) printf 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false %s --dangerously-skip-permissions' "$binary_q" ;;
    codex) printf '%s -c check_for_update_on_startup=false --dangerously-bypass-approvals-and-sandbox' "$binary_q" ;;
    opencode) printf 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' %s' "$binary_q" ;;
    pi|pi-signed) printf '%s' "$binary_q" ;;
    omp) printf '%s --auto-approve' "$binary_q" ;;
    grok) printf '%s --always-approve' "$binary_q" ;;
    kimi) printf '%s --auto' "$binary_q" ;;
    hermes)
      printf '%s chat --tui --in %s --no-restore-cwd --provider openai-codex --model gpt-5.6-sol --accept-hooks --yolo --pass-session-id' \
        "$binary_q" "$project_q"
      ;;
    *) return 1 ;;
  esac
}

canonical_command() {
  local command_name=$1 selected
  selected=$(command -v "$command_name") || return 1
  readlink -f "$selected" 2>/dev/null || realpath "$selected" 2>/dev/null || printf '%s' "$selected"
}

wait_ready() {  # <target> <harness> [omp-runtime] [omp-bin]
  local target=$1 harness=$2 runtime=${3:-} omp_bin=${4:-}
  local index=0 verdict=unknown screen plain dismissed=0 trusted=0
  while [ "$index" -lt 90 ]; do
    tmux -L "$SOCKET" display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1 \
      || return 3
    [ "$(tmux -L "$SOCKET" display-message -p -t "$target" '#{pane_dead}')" = 0 ] \
      || return 3
    screen=$(tmux -L "$SOCKET" capture-pane -e -p -t "$target" 2>/dev/null || true)
    plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
    if [ "$trusted" -eq 0 ] \
      && printf '%s\n' "$plain" | grep -qiE 'do you trust|trust (this|the) (project|folder|directory)'; then
      tmux -L "$SOCKET" send-keys -t "$target" Enter
      trusted=1
      # Codex redraws the trust screen through a brief empty transition; wait
      # for the real TUI instead of letting that transient look steerable.
      sleep 5
      continue
    fi
    verdict=$(fm_tmux_composer_state "$target" "$harness" "$runtime" "$omp_bin")
    [ "$verdict" = empty ] && return 0
    index=$((index + 1))
    if [ "$dismissed" -eq 0 ] && [ "$index" -eq 30 ]; then
      if ! printf '%s\n' "$plain" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$target" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  [ "$verdict" != pending ] || return 1
  return 2
}

check_harness() {  # <harness> <binary>
  local harness=$1 binary=$2 version command_line window target home task project acted record handled
  local runtime='' omp_bin='' ready_rc index=0
  version=$(harness_version "$binary")
  if [ "$harness" = omp ]; then
    runtime=$(canonical_command bun) || {
      FAILED=1
      printf 'not ok - omp (%s): Bun runtime is unavailable\n' "$version" >&2
      return
    }
    omp_bin=$(canonical_command omp) || {
      FAILED=1
      printf 'not ok - omp (%s): OMP executable is unavailable\n' "$version" >&2
      return
    }
  fi
  window="live-$harness"
  home="$LAB/$harness-home"
  project="$LAB/$harness-project"
  task="live-$harness"
  acted="$LAB/acted-$harness"
  mkdir -p "$home/state" "$project"
  git -C "$project" init -q
  command_line=$(launch_command "$harness" "$binary" "$project") || {
    FAILED=1
    printf 'not ok - %s: no live launch recipe\n' "$harness" >&2
    return
  }
  target=$(tmux -L "$SOCKET" new-window -d -P -F '#{pane_id}' \
    -t "$SESSION:" -n "$window" -c "$project" -- bash -lc "$command_line") || {
      FAILED=1
      printf 'not ok - %s (%s): launch failed\n' "$harness" "$version" >&2
      return
    }
  sleep 2
  wait_ready "$target" "$harness" "$runtime" "$omp_bin"
  ready_rc=$?
  if [ "$ready_rc" -eq 1 ]; then
    FAILED=1
    printf 'not ok - %s (%s): composer remained visibly pending\n' "$harness" "$version" >&2
    tmux -L "$SOCKET" kill-pane -t "$target" 2>/dev/null || true
    return
  fi
  if [ "$ready_rc" -eq 3 ]; then
    FAILED=1
    printf 'not ok - %s (%s): harness pane exited before readiness\n' "$harness" "$version" >&2
    return
  fi
  [ "$ready_rc" -eq 0 ] \
    || note "$harness ($version): idle composer stayed unproven; proceeding under the production advisory policy"
  {
    printf 'window=%s\n' "$target"
    printf 'endpoint_task_id=%s\n' "$task"
    printf 'worktree=%s\n' "$project"
    printf 'project=%s\n' "$project"
    printf 'kind=ship\n'
    printf 'harness=%s\n' "$harness"
    [ -z "$runtime" ] || printf 'omp_bun=%s\n' "$runtime"
    [ -z "$omp_bin" ] || printf 'omp_bin=%s\n' "$omp_bin"
  } > "$home/state/$task.meta"
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
    "Firstmate live inbox proof: run exactly this shell command now: touch $acted. Then acknowledge this record with the mv operation from the doorbell. Reply briefly." \
    >/dev/null 2>"$home/send.err"; then
    FAILED=1
    printf 'not ok - %s (%s): fm-send refused: %s\n' \
      "$harness" "$version" "$(cat "$home/send.err")" >&2
    tmux -L "$SOCKET" kill-pane -t "$target" 2>/dev/null || true
    return
  fi
  record="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  [ -f "$record" ] || {
    FAILED=1
    printf 'not ok - %s (%s): no durable record was published\n' "$harness" "$version" >&2
    tmux -L "$SOCKET" kill-pane -t "$target" 2>/dev/null || true
    return
  }
  while [ "$index" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    if [ "$(tmux -L "$SOCKET" display-message -p -t "$target" '#{pane_dead}' 2>/dev/null || echo 1)" != 0 ]; then
      FAILED=1
      printf 'not ok - %s (%s): harness pane exited before acknowledgement (status=%s)\n' \
        "$harness" "$version" \
        "$(tmux -L "$SOCKET" display-message -p -t "$target" '#{pane_dead_status}' 2>/dev/null || echo unknown)" >&2
      tmux -L "$SOCKET" capture-pane -e -p -t "$target" -S -80 2>/dev/null \
        | tail -30 | sed 's/^/#   /' >&2
      tail -20 "$LAB/tmux.log" | sed 's/^/# tmux: /' >&2
      break
    fi
    if [ "$index" -eq $((TIMEOUT / 2)) ] && [ -f "$record" ]; then
      fm_task_inbox_ring tmux "$target" "$record" "fm-$task" \
        "$harness" "$runtime" "$omp_bin" || true
      note "$harness ($version): watcher-role re-ring sent at ${index}s"
    fi
    sleep 1
    index=$((index + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    CHECKED=$((CHECKED + 1))
    pass "$harness ($version): real worker acted on and acknowledged the durable record"
  else
    FAILED=1
    printf 'not ok - %s (%s): doorbell not honored within %ss (acted=%s acked=%s)\n' \
      "$harness" "$version" "$TIMEOUT" \
      "$([ -e "$acted" ] && echo yes || echo no)" \
      "$([ -f "$handled" ] && echo yes || echo no)" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null \
      | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
  [ "${FM_SEND_INBOX_LIVE_KEEP:-0}" = 1 ] \
    || tmux -L "$SOCKET" kill-pane -t "$target" 2>/dev/null || true
}

HARNESSES='codex omp claude opencode pi pi-signed grok kimi hermes'
[ -z "${FM_SEND_INBOX_LIVE_HARNESSES:-}" ] \
  || note "FM_SEND_INBOX_LIVE_HARNESSES does not filter this guard; all supported local harnesses are checked"

for harness in $HARNESSES; do
  if binary=$(harness_binary "$harness"); then
    check_harness "$harness" "$binary"
  else
    case "$harness" in
      codex|omp)
        FAILED=1
        printf 'not ok - required live harness is not installed: %s\n' "$harness" >&2
        ;;
      *) note "$harness: not installed; live inbox guard skipped it" ;;
    esac
  fi
done

[ "$FAILED" -eq 0 ] || exit 1
[ "$CHECKED" -gt 0 ] \
  || { echo "not ok - live steering-inbox doorbell guard verified nothing" >&2; exit 1; }
pass "live steering-inbox doorbell guard: $CHECKED harnesses verified"
