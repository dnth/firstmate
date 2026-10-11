#!/usr/bin/env bash
# Prove-execution pane-launch guard (spawn-time only).
#
# A shell-startup prompt (an oh-my-zsh update check, a theme wizard, a read in
# .zshrc) can swallow the first bytes of a typed launch line while the pane's
# process shape still reads as one idle shell: a zsh blocked in read -k 1 is
# that shell's lone childless foreground process in a sleeping state. Typing
# the agent launch into such a pane eats its leading character (and, past the
# macOS 1024-byte canonical-mode line limit, the rest of a long line), so the
# agent never starts and the failure misreports as a harness setup problem.
#
# This library submits one short probe command through the same send path as
# the real launch and requires its marker file before the launch may be typed.
# A prompt that swallows the probe leaves no marker, and the caller refuses
# with the pane's visible tail instead of typing into an unknown prompt.
#
# The probe is deliberately a bare touch with NO leading space. A leading
# space looks like history suppression but is load-bearing input here: a
# single-key prompt consumes exactly the first byte, so a leading space would
# be eaten as the sacrifice, the prompt would dismiss, and the remainder
# would execute - a false pass. The bare command fails safe instead: losing
# its first byte yields ouch, which is not a command, so no marker appears.
#
# Sourced through bin/fm-backend.sh's lib dir like the other shared libs, so
# every backend adapter and fm-spawn.sh share one implementation. Uses only
# fm_backend_capture for reads (bounded, backend-agnostic) and the caller's
# established submit primitive for the single probe line.
#
# Contract (single owner here; callers cross-reference, never restate):
#   fm_pane_launch_prove_execution <backend> <target> <task-tmp> [label]
# prints the typed probe line length on stdout and returns 0 once the marker
# exists, else returns 1 after FM_PANE_LAUNCH_PROBE_POLLS (default 20) polls
# of FM_PANE_LAUNCH_PROBE_INTERVAL (default 0.5) seconds. Never types more
# than the one probe line. The marker dir must already exist; the probe
# creates only the marker file inside it.

# fm_pane_launch_probe_nonce: one unpredictable marker stem per launch, so a
# stale marker from an earlier incarnation can never satisfy this proof.
fm_pane_launch_probe_nonce() {
  local nonce=
  if command -v od >/dev/null 2>&1; then
    nonce=$(od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n') || nonce=
  fi
  [ -n "$nonce" ] || nonce="$$-$RANDOM-$RANDOM"
  printf '%s' "$nonce"
}

# fm_pane_launch_write_script: write <command> to a private 0700 script under
# <dir> and print its path. The typed launch then stays a short Bash
# invocation (well under the 1024-byte macOS canonical-mode limit) no matter
# how long the full command grows. The pane shell is never asked to parse the
# command itself, so a fish pane (or any non-POSIX shell) cannot misread the
# POSIX assignments and command substitutions every launch carries. The final
# agent command inside the script must use exec, so no extra bash parent
# survives: the pane's foreground process shape stays identical to a directly
# typed launch, which the agent-liveness classifiers depend on (an extra bash
# -c parent reads as no agent running). Verified live on tmux: /bin/bash
# <script> ending in VAR=val exec <agent> leaves the agent as the lone
# childless foreground process, exactly as a typed launch does.
fm_pane_launch_write_script() {  # <dir> <command> -> prints script path
  local dir=$1 command=$2 script old_umask
  [ -n "$dir" ] && [ -n "$command" ] || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  script="$dir/.fm-launch-$(fm_pane_launch_probe_nonce).sh"
  [ ! -e "$script" ] && [ ! -L "$script" ] || return 1
  # Restrictive-first: the script carries bearer-adjacent launch secrets, so
  # it must never exist world-readable, even briefly under a permissive
  # umask. Create with umask 077 (0600), write, then chmod to 0700.
  old_umask=$(umask)
  umask 077
  {
    printf '#!/bin/bash\n'
    printf '%s\n' "$command"
  } > "$script"
  umask "$old_umask"
  [ -f "$script" ] && [ ! -L "$script" ] || return 1
  chmod 700 "$script" || return 1
  printf '%s\n' "$script"
}

# fm_pane_launch_typed_line: the short Bash invocation for a written script.
# Single-quoted (never %q double-quoted): the script path is task-tmp under
# /tmp with no spaces in practice, and single quotes keep the typed line byte
# stable; the writer refuses paths containing a single quote outright.
fm_pane_launch_typed_line() {  # <script-path> -> prints typed line
  case "${1:-}" in
    ''|*"'"*) return 1 ;;
  esac
  printf "/bin/bash '%s'" "$1"
}

# fm_pane_launch Prove execution in the exact pane before the caller types its
# launch there. <submit-fn> names the caller's own one-line submit primitive
# (spawn_send_text_line semantics: line + Enter through the pane's path).
fm_pane_launch_prove_execution() {  # <backend> <target> <task-tmp> <submit-fn> [label]
  local backend=$1 target=$2 task_tmp=$3 submit_fn=$4 label=${5:-pane}
  local polls=${FM_PANE_LAUNCH_PROBE_POLLS:-20} interval=${FM_PANE_LAUNCH_PROBE_INTERVAL:-0.5}
  local nonce marker probe i
  [ -n "$backend" ] && [ -n "$target" ] && [ -n "$task_tmp" ] && [ -n "$submit_fn" ] || return 1
  [ -d "$task_tmp" ] && [ ! -L "$task_tmp" ] || return 1
  case "$polls" in ''|*[!0-9]*|0) polls=20 ;; esac
  case "$interval" in ''|*[!0-9.]*) interval=0.5 ;; esac
  nonce=$(fm_pane_launch_probe_nonce) || return 1
  case "$nonce" in ''|*/*|*' '*) return 1 ;; esac
  marker="$task_tmp/.fm-launch-probe.$nonce"
  [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
  probe="touch '$marker'"
  "$submit_fn" "$target" "$probe" || return 1
  i=0
  while [ "$i" -lt "$polls" ]; do
    [ ! -f "$marker" ] || [ -L "$marker" ] || return 0
    sleep "$interval"
    i=$((i + 1))
  done
  [ -f "$marker" ] && [ ! -L "$marker" ]
}

# fm_pane_launch_tail: bounded visible pane tail for refusal diagnostics, so a
# probe or doorbell timeout names what the pane actually shows (e.g. an
# oh-my-zsh update prompt) instead of blaming harness setup. Never fails: an
# unreadable pane yields the fallback line, which still refuses honestly.
fm_pane_launch_tail() {  # <backend> <target> <lines> [label]
  local backend=$1 target=$2 lines=${3:-15} label=${4:-pane} tail
  case "$lines" in ''|*[!0-9]*|0) lines=15 ;; esac
  tail=$(fm_backend_capture "$backend" "$target" "$lines" 2>/dev/null || true)
  if [ -z "$tail" ]; then
    printf 'pane %s of %s is unreadable; cannot show its visible state' "$label" "$target"
    return 0
  fi
  printf '%s' "$tail" | tail -n "$lines"
}

# fm_pane_launch_omp_observed: true (0) only when the pane holds an
# OMP-specific observed identity - Herder native agent identity plus live
# status, or the tmux foreground process matching the recorded canonical OMP
# runtime and entrypoint. A live non-OMP agent (or any unreadable state) is
# false, so callers name the OMP setup bypass only when OMP was actually
# observed. <meta> is the spawned task record (harness/omp_bin/omp_bun and
# backend ids); every read failure is false, never an error.
fm_pane_launch_omp_observed() {  # <backend> <target> <meta>
  local backend=$1 target=$2 meta=$3 session pane comm bun bin verdict
  # Sourced through bin/fm-backend.sh alongside fm-omp-process-lib.sh, which
  # provides fm_meta_get and (via the backend adapters) the per-backend
  # readers below. Fail closed when not loaded rather than misreading.
  command -v fm_meta_get >/dev/null 2>&1 || return 1
  command -v fm_backend_capture >/dev/null 2>&1 || return 1
  [ -n "$backend" ] && [ -n "$target" ] && [ -n "$meta" ] || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_meta_get "$meta" harness 2>/dev/null)" = omp ] || return 1
  case "$backend" in
    herdr)
      session=$(fm_meta_get "$meta" herdr_session 2>/dev/null) || return 1
      pane=$(fm_meta_get "$meta" herdr_pane_id 2>/dev/null) || return 1
      [ -n "$session" ] && [ -n "$pane" ] || return 1
      fm_backend_herdr_omp_observed "$session" "$pane" 2>/dev/null
      ;;
    tmux)
      bun=$(fm_meta_get "$meta" omp_bun 2>/dev/null) || return 1
      bin=$(fm_meta_get "$meta" omp_bin 2>/dev/null) || return 1
      [ -n "$bun" ] && [ -n "$bin" ] || return 1
      comm=$(fm_backend_tmux_current_command "$target" 2>/dev/null) || return 1
      verdict=$(fm_backend_tmux_bun_agent_state "$target" "$comm" "$bun" "$bin" 2>/dev/null) || return 1
      [ "$verdict" = alive ]
      ;;
    *) return 1 ;;
  esac
}
