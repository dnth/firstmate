#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables
# and nothing else. It has no side effects, runs no backend command, and reads
# no state, so it can be sourced by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb. It is not deterministic across the
# verified adapters: codex and grok resume only from a session id printed at
# exit, opencode resumes the most recent session for the cwd with --continue,
# and claude, pi, pi-signed, and kimi have no verified pane-resume contract at
# all. `relaunch` covers the same need deterministically for every adapter,
# because the brief on disk - not a harness-private session - is the durable
# instruction.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

# The harnesses whose control mechanics are verified. Mirrors AGENTS.md
# section 4's verified-adapter list; an unverified adapter is refused rather
# than guessed at, exactly as a spawn on it would be.
fm_control_harness_supported() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse) return 0 ;;
  esac
  return 1
}

# The verified adapter a RECORDED harness value belongs to. Every table below
# is keyed by the exact verified adapter name, but a task launched from a raw
# command records the command's basename instead (bin/fm-spawn.sh derives
# harness= that way), which is why the spawn adapters match `claude*`, `muse*`,
# and friends. This is the one place that prefix rule is stated. `pi` and
# `pi-signed` are exact because a `pi*` prefix would swallow the signed adapter,
# and an unrecognized value returns nonzero rather than being guessed into a
# family.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    omp) printf 'omp' ;;
    claude*) printf 'claude' ;;
    codex*) printf 'codex' ;;
    opencode*) printf 'opencode' ;;
    grok*) printf 'grok' ;;
    kimi*) printf 'kimi' ;;
    cursor*) printf 'cursor' ;;
    gemini*) printf 'gemini' ;;
    muse*) printf 'muse' ;;
    *) return 1 ;;
  esac
}

# Which task kinds an adapter is verified to run. muse and gemini are
# crewmate/scout adapters only: neither has a primary supervision protocol,
# and bin/fm-spawn.sh refuses a --secondmate launch on either. The control plane
# asks this BEFORE it stops anything, so an incompatible relaunch target is
# refused while the current agent is still running rather than after it has
# been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-} kind=${2-}
  fm_control_harness_supported "$harness" || return 1
  case "$harness" in
    muse|gemini) [ "$kind" != secondmate ] || return 1 ;;
  esac
  return 0
}

# The key that cancels a running turn. Escape for every adapter except grok,
# whose Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
# gemini names its own key in the running turn's status row
# (`(esc to cancel, <n>s)`), and a single Escape was verified to cancel it.
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|kimi|cursor|gemini|muse) printf 'Escape' ;;
    grok) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode needs a double
# Escape; every other verified adapter interrupts on a single press.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode) printf '2' ;;
    claude|codex|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse) printf '1' ;;
    *) return 1 ;;
  esac
}

# The key that must follow the interrupt key to leave the composer empty, or
# nothing when the adapter needs none. muse is the one verified adapter that
# RESTORES the cancelled prompt into its composer as real bright text, so an
# interrupt is not complete until Ctrl+U has cleared it; leaving it there would
# make the next submitted line - a steer, or this plane's own exit command -
# concatenate onto it. cursor was checked for exactly that behaviour and does
# NOT repollute: after a single Escape its composer shows only the `Add a
# follow-up` placeholder, so it needs no clear key. gemini was checked the
# same way and also does not repollute: after a single Escape it prints
# `Request cancelled.` and its composer shows only the `Type your message
# or @path/to/file` placeholder. Prints the key or nothing;
# a harness with no verified mechanics returns nonzero, matching the tables
# above.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    muse) printf 'C-u' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini) ;;
    *) return 1 ;;
  esac
}

fm_control_interrupt_ack_source() {  # <harness>
  case "${1-}" in
    muse) printf 'muse-session-terminal' ;;
    # cursor's transcript DOES type an aborted close, but its write latency
    # after an interrupt was measured as variable - sometimes seconds, sometimes
    # not within 20 - so a cancellation claim built on it would be unreliable.
    # Normal turn completion is prompt, which is what the busy fold depends on.
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini) printf 'none' ;;
    *) return 1 ;;
  esac
}

# The command that exits the agent from its own composer.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    claude|opencode|grok|kimi|cursor|muse|omp) printf '/exit' ;;
    codex|pi|pi-signed|gemini) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# The pid recorded as the owner of an OMP second mate's home session, or
# nothing when the home names none. bin/fm-spawn.sh refuses a second mate launch
# while that pid is still alive, so it is also the process whose absence has to
# be proven before this function may retire anything.
fm_control_omp_home_owner_pid() {  # <home-state>
  local home_state=$1 pid=""
  if [ -f "$home_state/.lock" ] && [ ! -L "$home_state/.lock" ]; then
    IFS= read -r pid < "$home_state/.lock" || pid=""
  fi
  case "$pid" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  printf '%s' "$pid"
}

# Retire the session artifacts an OMP second mate leaves behind, so its
# replacement launch is not refused by its own predecessor's leftovers.
#
# The order is the contract. Both owners have to be proven gone FIRST - the
# recorded endpoint, and the process holding the home session - because an
# artifact removed under a live agent is indistinguishable from a fresh one, and
# the launch owner would then accept a duplicate against a still-running mate.
#
# FM_RESTART_STOP_CMD replaces the signal and the liveness probe for the home
# session owner (default: kill; invoked as "<cmd> <pid>" to stop it and
# "<cmd> -0 <pid>" to probe it, so one override covers both halves). It exists so
# tests/fm-secondmate-restart.test.sh can drive this sequence deterministically;
# unset, this is an ordinary kill and the behavior is unchanged.
#   FM_RESTART_STOP_WAIT  seconds to wait for the owner to go (default 30)
#   FM_RESTART_STOP_POLL  seconds between absence probes (default 1)
fm_control_omp_secondmate_prepare_relaunch() {  # <state> <id> <worktree> <backend> <target> <meta>
  local state=$1 id=$2 worktree=$3 backend=$4 target=$5 meta=$6 omp_state
  local stop_cmd stop_wait stop_poll owner_pid elapsed proven
  omp_state=$(fm_backend_agent_state "$backend" "$target" "$meta" 2>/dev/null || printf 'unreadable')
  case "$omp_state" in
    missing) ;;
    dead)
      fm_backend_kill "$backend" "$target" || return 1
      omp_state=$(fm_backend_agent_state "$backend" "$target" "$meta" 2>/dev/null || printf 'unreadable')
      [ "$omp_state" = missing ] || return 1
      ;;
    *) return 1 ;;
  esac
  stop_cmd=${FM_RESTART_STOP_CMD:-kill}
  stop_wait=${FM_RESTART_STOP_WAIT:-30}
  stop_poll=${FM_RESTART_STOP_POLL:-1}
  case "$stop_wait" in ''|*[!0-9]*) return 1 ;; esac
  case "$stop_poll" in ''|*[!0-9]*|0) return 1 ;; esac
  if owner_pid=$(fm_control_omp_home_owner_pid "$worktree/state"); then
    "$stop_cmd" "$owner_pid" >/dev/null 2>&1 || true
    proven=0
    elapsed=0
    while :; do
      if ! "$stop_cmd" -0 "$owner_pid" >/dev/null 2>&1; then
        proven=1
        break
      fi
      [ "$elapsed" -lt "$stop_wait" ] || break
      sleep "$stop_poll"
      elapsed=$((elapsed + stop_poll))
    done
    [ "$proven" -eq 1 ] || return 1
  fi
  rm -f -- "$state/$id.omp-ext.ts" "$state/$id.omp-ready" \
    "$state/$id.omp-started" "$worktree/state/.omp-primary-extension-loaded"
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear; Orca's terminal API
# exposes only an interrupt and an Enter, so it can deliver neither Escape nor
# Ctrl+U (bin/backends/orca.sh's fm_backend_orca_send_key).
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
    orca)
      case "$key" in Enter|C-c) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. Only tmux and
# herdr implement fm_backend_agent_state; zellij, orca, and cmux report
# `unverified`, so no reading of theirs can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr) return 0 ;;
  esac
  return 1
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Prints zero or more absolute paths, one per
# line: worktree-resident hook files and firstmate-owned state tokens only,
# never a harness's own managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    claude) printf '%s\n' "$wt/.claude/settings.local.json" ;;
    opencode) printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js" ;;
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
    grok)
      printf '%s\n' "$wt/.fm-grok-turnend"
      printf '%s\n' "$state/$id.grok-turnend-token"
      ;;
    kimi)
      printf '%s\n' "$wt/.fm-kimi-turnend"
      printf '%s\n' "$state/$id.kimi-turnend-token"
      ;;
    muse)
      # muse installs no hook: its busy source is its own session event log,
      # bound to the pane by these two firstmate-owned sidecars. A relaunch
      # ONTO muse rewrites them, but a relaunch AWAY from muse must retire them
      # so no retired incarnation's session binding outlives the agent.
      printf '%s\n' "$state/$id.muse-session"
      printf '%s\n' "$state/$id.muse-session-current"
      ;;
    cursor) printf '%s\n' "$state/$id.cursor-session" ;;
    # gemini's busy-state and turn-end hooks live in a firstmate-owned
    # settings file the launch reaches through GEMINI_CLI_SYSTEM_SETTINGS_PATH,
    # so retiring that one file retires the whole incarnation's wiring. Nothing
    # is written into the worktree, whose own .gemini/settings.json belongs to
    # the project, and nothing global is installed.
    gemini) printf '%s\n' "$state/$id.gemini-settings.json" ;;
  esac
}

# The firstmate-owned global turn-end registry entry a harness mints per task.
# grok and kimi are the two adapters whose turn-end hook is global and gated by
# a private token file; every other adapter's wiring is fully covered by
# fm_control_harness_wiring_paths. Prints the registry path or nothing.
fm_control_harness_turnend_token_path() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    grok) printf '%s\n' "$state/$id.grok-turnend-token" ;;
    kimi) printf '%s\n' "$state/$id.kimi-turnend-token" ;;
  esac
}

fm_control_harness_turnend_auth_path() {  # <harness> <token>
  local harness=${1-} token=${2-}
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$harness" in
    grok) printf '%s\n' "${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d/$token" ;;
    kimi) printf '%s\n' "$HOME/.kimi-code/fm-turn-end.d/$token" ;;
    *) return 0 ;;
  esac
}
