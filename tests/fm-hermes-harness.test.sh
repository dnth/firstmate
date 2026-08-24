#!/usr/bin/env bash
# Behavior tests for the verified crewmate-only Hermes Agent CLI adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
STATE_READ="$ROOT/bin/fm-crew-state.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HOOK_INSTALLER="$ROOT/bin/fm-hermes-turnend-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  ln -s "$PYTHON_BIN" "$fakebin/python3"
  ln -s "$JQ_BIN" "$fakebin/jq"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  cat > "$fakebin/hermes" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  'config path') printf '%s/config.yaml\n' "$HERMES_HOME" ;;
  '--version') printf 'Hermes Agent v0.20.0 (test)\n' ;;
  *) printf 'fake Hermes should be launched through the pane fixture\n' >&2; exit 1 ;;
esac
SH
  chmod +x "$fakebin/hermes"
  cat > "$fakebin/pane-ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  '-o tpgid= -p 4100') printf '4200\n' ;;
  '-p 4200 -o comm=') printf '%s\n' "${FM_FAKE_PS_COMMAND:-hermes}" ;;
  '-p 4200 -o args=') printf 'python3 %s chat --tui\n' "$FM_FAKE_HERMES_BIN" ;;
  '-axo pid=,pgid=,ppid=') printf '%s\n' '4100 4100 1' '4200 4200 4100' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/pane-ps"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
fire_hook() {
  local event=$1 session_id=${2:-} hook="$HERMES_HOME/fm-turn-end.sh"
  if [ -z "$session_id" ]; then
    session_id=$(cat "$FM_FAKE_HERMES_SESSION_FILE" 2>/dev/null || printf 'hermes-session-test')
  fi
  printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s","task_id":"","turn_id":"turn-test"}\n' \
    "$event" "$session_id" "$FM_FAKE_PANE_PATH" \
    | HERMES_HOME="$HERMES_HOME" bash "$hook"
}
submit_command() {
  local command=$1
  printf '%s\n' "$command" >> "$FM_FAKE_COMMAND_LOG"
  case "$command" in
    *hermes*chat*--tui*) printf 'idle\n' > "$FM_FAKE_HERMES_TUI_STATE" ;;
    '/reasoning '*) printf '%s\n' "${command#/reasoning }" > "$FM_FAKE_HERMES_REASONING" ;;
    /exit) printf 'shell\n' > "$FM_FAKE_HERMES_TUI_STATE" ;;
    *)
      if [ -n "${FM_FAKE_HERMES_BLOCK_DIR:-}" ]; then
        if mkdir "$FM_FAKE_HERMES_BLOCK_DIR/first.claim" 2>/dev/null; then
          touch "$FM_FAKE_HERMES_BLOCK_DIR/first-entered"
          while [ ! -f "$FM_FAKE_HERMES_BLOCK_DIR/release-first" ]; do sleep 0.01; done
        else
          touch "$FM_FAKE_HERMES_BLOCK_DIR/second-entered"
        fi
      fi
      if [ ! -s "$FM_FAKE_HERMES_SESSION_FILE" ]; then
        fire_hook on_session_start
      fi
      [ "${FM_FAKE_HERMES_START_ONLY:-0}" != 1 ] || return 0
      [ "${FM_FAKE_HERMES_NO_PRE_LLM:-0}" != 1 ] || return 0
      fire_hook pre_llm_call
      fire_hook on_session_end
      ;;
  esac
}
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *'#{pane_current_command}'*)
    if [ "$(cat "$FM_FAKE_HERMES_TUI_STATE" 2>/dev/null)" = shell ]; then
      printf 'zsh\n'
    else
      printf '%s\n' "${FM_FAKE_TMUX_COMMAND:-python3}"
    fi
    exit 0
    ;;
  *'#{pane_pid}'*) printf '4100\n'; exit 0 ;;
  *'#{pane_id}'*) printf '%%1\n'; exit 0 ;;
  *'#{cursor_y}'*) printf '2\n'; exit 0 ;;
  *'#{pane_height}'*) printf '3\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ ! -f "$FM_FAKE_WINDOW_STATE" ] || printf '%s\n' "$FM_FAKE_WINDOW"; exit 0 ;;
  new-window) touch "$FM_FAKE_WINDOW_STATE"; printf '@1\n'; exit 0 ;;
  kill-window) rm -f "$FM_FAKE_WINDOW_STATE"; exit 0 ;;
  has-session|new-session|set-window-option) exit 0 ;;
  send-keys)
    case " $* " in
      *' C-c '*) : > "$FM_FAKE_PENDING_COMMAND"; printf 'idle\n' > "$FM_FAKE_HERMES_TUI_STATE"; exit 0 ;;
    esac
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      printf '%s\n' "$literal" > "$FM_FAKE_PENDING_COMMAND"
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        if [ -s "$FM_FAKE_PENDING_COMMAND" ]; then
          command=$(cat "$FM_FAKE_PENDING_COMMAND")
          : > "$FM_FAKE_PENDING_COMMAND"
          submit_command "$command"
        else
          command=${4:-}
          [ "$command" = Enter ] || submit_command "$command"
        fi
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    state=$(cat "$FM_FAKE_HERMES_TUI_STATE" 2>/dev/null || printf 'shell')
    if [ "$state" = shell ]; then
      printf '$ \n'
      exit 0
    fi
    reasoning=$(cat "$FM_FAKE_HERMES_REASONING" 2>/dev/null || printf 'high')
    if [ "$state" = busy ]; then
      printf ' ─ (busy) thinking… · 0s │ gpt 5.6 sol %s │\n ❯ Ctrl+C to interrupt…\n' "$reasoning"
      exit 0
    fi
    if [ -s "$FM_FAKE_PENDING_COMMAND" ]; then
      composer="❯ $(cat "$FM_FAKE_PENDING_COMMAND")"
    else
      composer='❯ Ask me anything…'
    fi
    case " $* " in
      *' -E 2 '*) printf '%s\n' "$composer" ;;
      *) printf ' reasoning: %s\n ─ ready │ gpt 5.6 sol %s │\n%s\n' "$reasoning" "$reasoning" "$composer" ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home hermes_home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  hermes_home="$home/.hermes"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$hermes_home/skills/native-check" "$home/.agents/skills/no-mistakes"
  printf 'Follow the launch brief.\n' > "$home/data/$id/brief.md"
  printf 'model:\n  default: gpt-5.6-sol\n  provider: openai-codex\n' > "$hermes_home/config.yaml"
  printf '%s\n' '---' 'name: native-check' '---' '# Native check' > "$hermes_home/skills/native-check/SKILL.md"
  printf '%s\n' '---' 'name: no-mistakes' '---' '# No mistakes' > "$home/.agents/skills/no-mistakes/SKILL.md"
  printf 'hermes\n' > "$home/config/crew-harness"
  fm_git_worktree "$project" "$worktree" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/tmux.log"
  : > "$case_dir/commands.log"
  : > "$case_dir/pending"
  printf 'shell\n' > "$case_dir/hermes-tui-state"
  printf 'high\n' > "$case_dir/hermes-reasoning"
  printf '%s\n' "$case_dir|$home|$hermes_home|$project|$worktree|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR HERMES_HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

fixture_env() {
  env HOME="$HOME_DIR" HERMES_HOME="$HERMES_HOME_DIR" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WORKTREE_DIR" \
    FM_FAKE_WINDOW="fm-$TEST_ID" FM_FAKE_TMUX_CALL_LOG="$CASE_DIR/tmux.log" \
    FM_FAKE_COMMAND_LOG="$CASE_DIR/commands.log" \
    FM_FAKE_PENDING_COMMAND="$CASE_DIR/pending" \
    FM_FAKE_HERMES_TUI_STATE="$CASE_DIR/hermes-tui-state" \
    FM_FAKE_HERMES_REASONING="$CASE_DIR/hermes-reasoning" \
    FM_FAKE_HERMES_SESSION_FILE="$HOME_DIR/state/$TEST_ID.hermes-session" \
    FM_FAKE_HERMES_BIN="$FAKEBIN_DIR/hermes" \
    FM_FAKE_WINDOW_STATE="$CASE_DIR/window.state" \
    FM_TMUX_PS_BIN="$FAKEBIN_DIR/pane-ps" \
    FM_HERMES_PYTHON="$PYTHON_BIN" FM_HERMES_LAUNCH_ACK_POLLS=2 \
    FM_HERMES_LAUNCH_ACK_INTERVAL=0 FM_HERMES_READY_POLLS=4 \
    FM_HERMES_READY_INTERVAL=0 FM_HERMES_SETTING_POLLS=4 \
    FM_HERMES_SETTING_INTERVAL=0 FM_SEND_HERMES_START_POLLS=4 \
    FM_SEND_HERMES_START_INTERVAL=0.01 FM_SEND_SETTLE=0 TMUX='fake,1,0' \
    PATH="$FAKEBIN_DIR:$BASE_PATH" "$@"
}

fixture_hook() {
  local event=$1 session_id=$2
  printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s","task_id":"","turn_id":"turn-test"}\n' \
    "$event" "$session_id" "$WORKTREE_DIR" \
    | env HOME="$HOME_DIR" HERMES_HOME="$HERMES_HOME_DIR" PATH="$FAKEBIN_DIR:$BASE_PATH" \
      bash "$HERMES_HOME_DIR/fm-turn-end.sh"
}

config_hook_timeouts() {
  "$PYTHON_BIN" - "$1" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    config = yaml.safe_load(stream)
for event in ("on_session_start", "pre_llm_call", "on_session_end"):
    entries = config["hooks"][event]
    owned = [entry for entry in entries if entry.get("command", "").endswith("/fm-turn-end.sh")]
    if len(owned) != 1:
        raise SystemExit(1)
    print(owned[0]["timeout"])
PY
}

test_hermes_hook_install_is_surgical_idempotent_and_removable() {
  local home config original once no_newline timeouts
  home="$TMP_ROOT/config-surgery"
  config="$home/config.yaml"
  original="$home/original.yaml"
  once="$home/once.yaml"
  mkdir -p "$home"
  printf '# Captain comment\nmodel:\n  default: gpt-5.6-sol\nhooks:\n  pre_tool_call:\n    - command: /foreign/hook.sh\n      matcher: terminal\n' > "$config"
  cp "$config" "$original"

  HERMES_HOME="$home" HERMES_BIN="$TMP_ROOT/config-hermes" \
    FM_HERMES_PYTHON="$PYTHON_BIN" PATH="$(dirname "$JQ_BIN"):$BASE_PATH" \
    "$HOOK_INSTALLER" install 2>/dev/null && fail "nonexistent Hermes binary was accepted"
  cat > "$TMP_ROOT/config-hermes" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'config path' ] && printf '%s/config.yaml\n' "$HERMES_HOME"
SH
  chmod +x "$TMP_ROOT/config-hermes"
  HERMES_HOME="$home" HERMES_BIN="$TMP_ROOT/config-hermes" FM_HERMES_PYTHON="$PYTHON_BIN" \
    "$HOOK_INSTALLER" install || fail "Hermes hook install refused a foreign hooks mapping"
  assert_present "$home/plugins/firstmate-lifecycle/plugin.yaml" "Hermes lifecycle plugin manifest was not installed"
  assert_present "$home/plugins/firstmate-lifecycle/__init__.py" "Hermes lifecycle plugin bridge was not installed"
  assert_grep 'firstmate-lifecycle' "$config" "Hermes lifecycle plugin was not enabled"
  mkdir -m 700 "$home/plugins/firstmate-lifecycle/__pycache__"
  printf 'test bytecode cache\n' > "$home/plugins/firstmate-lifecycle/__pycache__/__init__.cpython-311.pyc"
  chmod 600 "$home/plugins/firstmate-lifecycle/__pycache__/__init__.cpython-311.pyc"
  timeouts=$(config_hook_timeouts "$config") || fail "Hermes hook timeouts were not readable"
  [ "$timeouts" = $'10\n10\n10' ] || fail "Hermes hook timeout did not exceed the busy-lock budget"
  cp "$config" "$once"
  HERMES_HOME="$home" HERMES_BIN="$TMP_ROOT/config-hermes" FM_HERMES_PYTHON="$PYTHON_BIN" \
    "$HOOK_INSTALLER" install || fail "second Hermes hook install failed"
  cmp -s "$once" "$config" || fail "second Hermes hook install changed config bytes"
  assert_absent "$home/plugins/firstmate-lifecycle/__pycache__" "Hermes hook install retained stale plugin bytecode"
  "$PYTHON_BIN" - "$config" <<'PY'
import sys

path = sys.argv[1]
with open(path, "rb") as stream:
    data = stream.read()
if data.count(b"timeout: 10") != 3:
    raise SystemExit(1)
with open(path, "wb") as stream:
    stream.write(data.replace(b"timeout: 10", b"timeout: 2"))
PY
  HERMES_HOME="$home" HERMES_BIN="$TMP_ROOT/config-hermes" FM_HERMES_PYTHON="$PYTHON_BIN" \
    "$HOOK_INSTALLER" install || fail "Hermes hook installer did not upgrade legacy timeout entries"
  cmp -s "$once" "$config" || fail "Hermes hook timeout upgrade changed unrelated config bytes"
  assert_grep '/foreign/hook.sh' "$config" "Hermes hook install removed a foreign hook"
  HERMES_HOME="$home" HERMES_BIN="$TMP_ROOT/config-hermes" FM_HERMES_PYTHON="$PYTHON_BIN" \
    "$HOOK_INSTALLER" remove || fail "Hermes hook removal failed"
  cmp -s "$original" "$config" || fail "Hermes hook removal did not restore foreign config bytes"
  assert_absent "$home/fm-turn-end.sh" "Hermes hook removal left its script"
  assert_absent "$home/fm-turn-end.d" "Hermes hook removal left its registry"
  assert_absent "$home/plugins/firstmate-lifecycle" "Hermes hook removal left its lifecycle plugin"

  no_newline="$TMP_ROOT/config-no-newline"
  mkdir -p "$no_newline"
  printf 'model: {default: gpt-5.6-sol}' > "$no_newline/config.yaml"
  cp "$no_newline/config.yaml" "$no_newline/original.yaml"
  HERMES_HOME="$no_newline" HERMES_BIN="$TMP_ROOT/config-hermes" FM_HERMES_PYTHON="$PYTHON_BIN" \
    "$HOOK_INSTALLER" install || fail "Hermes hook install refused YAML without a final newline"
  HERMES_HOME="$no_newline" HERMES_BIN="$TMP_ROOT/config-hermes" FM_HERMES_PYTHON="$PYTHON_BIN" \
    "$HOOK_INSTALLER" remove || fail "Hermes hook removal failed without a final newline"
  cmp -s "$no_newline/original.yaml" "$no_newline/config.yaml" \
    || fail "Hermes hook removal did not restore the absent final newline"
  pass "Hermes hook install preserves foreign YAML and is idempotent and removable"
}

test_hermes_spawn_tui_skill_state_and_teardown() {
  local rec out rc launch meta state_line token registry commands interrupt_state
  TEST_ID=hermes-lifecycle-x1
  rec=$(make_case lifecycle "$TEST_ID")
  read_case "$rec"
  out=$(fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" --harness hermes \
    --model gpt-5.6-sol --effort xhigh --mode no-mistakes --yolo off 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\nstate=%s\ncommands:\n%s\ntmux:\n%s\n' "$out" \
      "$(cat "$CASE_DIR/hermes-tui-state")" "$(cat "$CASE_DIR/commands.log")" \
      "$(cat "$CASE_DIR/tmux.log")" >&2
  fi
  expect_code 0 "$rc" "Hermes spawn should succeed"
  assert_contains "$out" "spawned $TEST_ID harness=hermes" "Hermes spawn did not report success"
  launch=$(grep 'hermes.*chat --tui' "$CASE_DIR/commands.log" | head -1)
  assert_contains "$launch" "chat --tui" "Hermes launch did not use the persistent TUI"
  assert_contains "$launch" "--in '$WORKTREE_DIR' --no-restore-cwd" "Hermes launch did not pin the task worktree"
  assert_contains "$launch" "--provider openai-codex" "Hermes launch lost its provider"
  assert_contains "$launch" "--model 'gpt-5.6-sol'" "Hermes launch lost its model"
  assert_contains "$launch" "--reasoning 'xhigh'" "Hermes launch lost its reasoning effort"
  assert_contains "$launch" "--accept-hooks --yolo --pass-session-id" "Hermes launch lost autonomy/session flags"
  assert_not_contains "$launch" "--safe-mode" "Hermes launch disabled its hooks and rules"
  assert_not_contains "$launch" " -Q " "Hermes launch retained the headless quiet path"

  meta="$HOME_DIR/state/$TEST_ID.meta"
  assert_grep 'harness=hermes' "$meta" "Hermes metadata lost its harness identity"
  assert_grep 'model=gpt-5.6-sol' "$meta" "Hermes metadata lost its model"
  assert_grep 'effort=xhigh' "$meta" "Hermes metadata lost its effort"
  assert_present "$HOME_DIR/state/$TEST_ID.hermes-session" "Hermes start hook did not record a session"
  assert_present "$HOME_DIR/state/$TEST_ID.turn-ended" "Hermes end hook did not touch the turn marker"
  assert_present "$HOME_DIR/state/$TEST_ID.hermes-started" "Hermes start hook did not acknowledge launch"
  [ "$(cat "$HOME_DIR/state/$TEST_ID.hermes-session")" = hermes-session-test ] \
    || fail "Hermes hook recorded the wrong session id"
  token=$(sed -n 's/^token=//p' "$WORKTREE_DIR/.fm-hermes-turnend")
  registry="$HERMES_HOME_DIR/fm-turn-end.d/$token"
  assert_present "$registry" "Hermes spawn did not create a private registry token"
  assert_not_contains "$(cat "$WORKTREE_DIR/.fm-hermes-turnend")" "$HOME_DIR/state" \
    "Hermes pointer exposed task state paths"

  printf 'working: implementing Hermes adapter\n' >> "$HOME_DIR/state/$TEST_ID.status"
  state_line=$(fixture_env "$STATE_READ" "$TEST_ID")
  assert_contains "$state_line" "state: working" "Hermes crew-state did not use the status fallback"
  assert_contains "$state_line" "source: status-log" "Hermes crew-state did not pass through semantic idle"
  # shellcheck disable=SC2016 # Positional parameters expand inside the fixture shell.
  [ "$(fixture_env bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2" "$3"' _ "$ROOT" "firstmate:fm-$TEST_ID" "$meta")" = alive ] \
    || fail "Hermes resumable idle endpoint did not classify alive"

  fixture_env "$SEND" "$TEST_ID" 'Continue with the adapter.' || fail "Hermes TUI steer failed"
  fixture_env "$SEND" "$TEST_ID" /no-mistakes || fail "Hermes skill steer failed"
  fixture_env "$SEND" "$TEST_ID" /native-check || fail "Hermes native skill steer failed"
  commands=$(cat "$CASE_DIR/commands.log")
  [ "$(grep -c 'hermes.*chat --tui' "$CASE_DIR/commands.log")" = 1 ] \
    || fail "Hermes steer launched another process instead of using the persistent composer"
  assert_contains "$commands" "Continue with the adapter." "Hermes TUI steer lost its message"
  assert_contains "$commands" "Read the skill at $HOME_DIR/.agents/skills/no-mistakes/SKILL.md completely and follow it now." \
    "Hermes skill invocation did not use the validated Firstmate skill pointer"
  assert_contains "$commands" "/native-check" "Hermes native skill invocation did not stay a TUI slash command"
  printf 'busy\n' > "$CASE_DIR/hermes-tui-state"
  fixture_env "$SEND" "$TEST_ID" --key C-c || fail "Hermes interrupt key was not mapped"
  assert_contains "$(cat "$CASE_DIR/tmux.log")" " C-c" "Hermes interrupt did not send Ctrl+C"
  # shellcheck disable=SC2016 # Positional parameters expand inside the fixture shell.
  interrupt_state=$(fixture_env bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux unused hermes "$2" "$3"' _ "$ROOT" "$TEST_ID" "$HOME_DIR/state")
  [ "$interrupt_state" = 'idle fm-interrupt' ] || fail "Hermes Ctrl+C did not record the interrupt edge: $interrupt_state"
  fixture_env "$SEND" "$TEST_ID" /exit || fail "Hermes /exit did not stop the persistent TUI"

  fixture_env "$TEARDOWN" "$TEST_ID" --force >/dev/null 2>&1 || fail "Hermes teardown failed"
  assert_absent "$WORKTREE_DIR/.fm-hermes-turnend" "Hermes pointer survived teardown"
  assert_absent "$registry" "Hermes registry token survived teardown"
  assert_absent "$HOME_DIR/state/$TEST_ID.hermes-turnend-token" "Hermes state token survived teardown"
  assert_absent "$HOME_DIR/state/$TEST_ID.hermes-session" "Hermes session sidecar survived teardown"
  assert_absent "$HOME_DIR/state/$TEST_ID.hermes-started" "Hermes start marker survived teardown"
  pass "Hermes crew lifecycle covers persistent TUI launch, steering, skill, interrupt, exit, state read, and teardown"
}

test_hermes_secondmate_is_refused() {
  local rec out rc
  TEST_ID=hermes-secondmate-x2
  rec=$(make_case secondmate "$TEST_ID")
  read_case "$rec"
  rc=0
  out=$(fixture_env "$SPAWN" "$TEST_ID" "$HOME_DIR/not-a-secondmate" --secondmate --harness hermes 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Hermes was accepted as a secondmate harness"
  assert_contains "$out" "harness=hermes is verified for crewmates and scouts only" \
    "an explicit Hermes secondmate did not report the crew/scout-only reason"
  assert_not_contains "$out" "unknown secondmate harness" \
    "a verified crew-only harness was reported as unknown"
  assert_not_contains "$(cat "$CASE_DIR/tmux.log")" "new-window" "Hermes secondmate refusal created an endpoint"

  printf 'hermes\n' > "$HOME_DIR/config/secondmate-harness"
  rc=0
  out=$(fixture_env "$SPAWN" "$TEST_ID" "$HOME_DIR/not-a-secondmate" --secondmate 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "config/secondmate-harness: hermes was accepted"
  assert_contains "$out" "harness=hermes is verified for crewmates and scouts only" \
    "a configured Hermes secondmate did not report the crew/scout-only reason"
  assert_not_contains "$out" "no verified secondmate launch template" \
    "a configured crew-only harness fell through to the generic template diagnostic"
  rm -f "$HOME_DIR/config/secondmate-harness"
  pass "Hermes remains crewmate/scout-only with an accurate diagnostic"
}

test_secondmates_refuse_every_raw_launch_command() {
  local raw rec out rc index=0
  for raw in \
    'hermes --yolo' \
    'env HERMES_HOME=/tmp/profile hermes --yolo' \
    "bash -lc 'hermes --yolo'" \
    'omp --resume /notes/hermes-port.md'; do
    index=$((index + 1))
    TEST_ID="raw-secondmate-refusal-x$index"
    rec=$(make_case "raw-secondmate-$index" "$TEST_ID")
    read_case "$rec"
    rc=0
    out=$(fixture_env "$SPAWN" "$TEST_ID" "$HOME_DIR/not-a-secondmate" "$raw" --secondmate 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "secondmate accepted raw launch command: $raw"
    assert_contains "$out" "raw launch commands are unavailable for secondmates" \
      "secondmate raw-command refusal omitted its kind boundary"
    assert_not_contains "$(cat "$CASE_DIR/tmux.log")" "new-window" \
      "secondmate raw-command refusal created an endpoint"
  done
  pass "secondmates refuse every raw launch command"
}

test_workers_and_scouts_preserve_raw_launch_commands() {
  local kind rec out
  for kind in ship scout; do
    TEST_ID="raw-$kind-preserved-x14"
    rec=$(make_case "raw-$kind-preserved" "$TEST_ID")
    read_case "$rec"
    if [ "$kind" = scout ]; then
      out=$(fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" 'custom-agent --flag' --scout 2>&1) \
        || fail "raw scout launch was refused"
    else
      out=$(fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" 'custom-agent --flag' \
        --mode no-mistakes --yolo off 2>&1) || fail "raw worker launch was refused"
    fi
    assert_contains "$out" "spawned $TEST_ID harness=custom-agent" "raw $kind launch lost its executable identity"
    assert_contains "$(cat "$CASE_DIR/commands.log")" "custom-agent --flag" "raw $kind command was not submitted"
    fixture_env "$TEARDOWN" "$TEST_ID" --force >/dev/null 2>&1 || fail "raw $kind fixture teardown failed"
  done
  pass "workers and scouts preserve raw launch commands"
}

test_hermes_tui_busy_state_and_composer() {
  local state out idle busy
  state="$TMP_ROOT/tui-classifier-state"
  mkdir -p "$state"
  idle=$' ─ ready │ gpt 5.6 sol low │\n ❯ Ask me anything…'
  busy=$' ─ (◔_◔) computing… · 2s │ gpt 5.6 sol low │\n ❯ Ctrl+C to interrupt…'
  out=$(bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux unused hermes tui "$2" "$3"' _ "$ROOT" "$state" "$idle")
  [ "$out" = 'idle hermes-tui' ] || fail "Hermes ready footer classified '$out'"
  out=$(bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux unused hermes tui "$2" "$3"' _ "$ROOT" "$state" "$busy")
  [ "$out" = 'busy hermes-tui' ] || fail "Hermes busy footer classified '$out'"
  out=$(bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_classify_content 0 "$2" "$FM_COMPOSER_IDLE_RE"' _ "$ROOT" '❯ Ask me anything…')
  [ "$out" = empty ] || fail "Hermes plain placeholder composer classified '$out'"
  out=$(bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_classify_content 0 "$2" "$FM_COMPOSER_IDLE_RE"' _ "$ROOT" '❯ Ctrl+C to interrupt…')
  [ "$out" = empty ] || fail "Hermes busy placeholder composer classified '$out'"
  out=$(bash -c '. "$1/bin/fm-composer-lib.sh"; fm_composer_classify_content 0 "$2" "$FM_COMPOSER_IDLE_RE"' _ "$ROOT" '❯ real pending text')
  [ "$out" = pending ] || fail "Hermes real composer text classified '$out'"
  pass "Hermes TUI busy and composer classifiers distinguish ready, working, placeholder, and pending text"
}

test_hermes_spawn_resumes_existing_tui_session() {
  local rec launch
  TEST_ID=hermes-resume-tui-x22
  rec=$(make_case resume-tui "$TEST_ID")
  read_case "$rec"
  printf 'hermes-session-existing\n' > "$HOME_DIR/state/$TEST_ID.hermes-session"
  fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" --harness hermes \
    --model gpt-5.6-sol --effort medium --mode no-mistakes --yolo off >/dev/null \
    || fail "Hermes persistent TUI resume spawn failed"
  launch=$(grep 'hermes.*chat --tui' "$CASE_DIR/commands.log" | head -1)
  assert_contains "$launch" "--resume 'hermes-session-existing'" "Hermes TUI launch did not resume the exact bound session"
  assert_contains "$(cat "$CASE_DIR/commands.log")" "Resume the task from the brief at" \
    "Hermes resumed TUI did not receive the recovery-specific brief pointer"
  fixture_env "$SEND" "$TEST_ID" /exit >/dev/null || fail "Hermes resumed TUI did not exit cleanly"
  fixture_env "$TEARDOWN" "$TEST_ID" --force >/dev/null 2>&1 || fail "Hermes resumed fixture teardown failed"
  pass "Hermes persistent TUI resumes the exact task-bound session"
}

test_hermes_session_binding_and_busy_ack_order() {
  local rec stable gen busy
  TEST_ID=hermes-session-binding-x9
  rec=$(make_case session-binding "$TEST_ID")
  read_case "$rec"
  fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" --harness hermes \
    --model gpt-5.6-sol --effort high --mode no-mistakes --yolo off >/dev/null \
    || fail "Hermes session-binding fixture spawn failed"
  stable=$(cat "$HOME_DIR/state/$TEST_ID.hermes-session")
  rm -f "$HOME_DIR/state/$TEST_ID.hermes-started" "$HOME_DIR/state/$TEST_ID.turn-ended"
  fixture_hook on_session_start nested-session
  fixture_hook pre_llm_call nested-session
  fixture_hook on_session_end nested-session
  [ "$(cat "$HOME_DIR/state/$TEST_ID.hermes-session")" = "$stable" ] \
    || fail "nested Hermes session replaced the task-bound session"
  assert_absent "$HOME_DIR/state/$TEST_ID.hermes-started" "nested Hermes session acknowledged a task turn"
  assert_absent "$HOME_DIR/state/$TEST_ID.turn-ended" "nested Hermes session ended the task turn"

  gen=$(jq -r '.gen' "$HERMES_HOME_DIR/fm-turn-end.d/$(cat "$HOME_DIR/state/$TEST_ID.hermes-turnend-token")")
  printf '%s\n' foreign-generation > "$HOME_DIR/state/$TEST_ID.busy-gen"
  fixture_hook pre_llm_call "$stable"
  assert_absent "$HOME_DIR/state/$TEST_ID.hermes-started" "Hermes acknowledged before busy state succeeded"
  printf '%s\n' "$gen" > "$HOME_DIR/state/$TEST_ID.busy-gen"
  fixture_hook pre_llm_call "$stable"
  assert_present "$HOME_DIR/state/$TEST_ID.hermes-started" "matching Hermes session did not acknowledge after busy state"
  # shellcheck disable=SC2016 # Positional parameters expand inside the fixture shell.
  busy=$(fixture_env bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux unused hermes "$2" "$3"' _ "$ROOT" "$TEST_ID" "$HOME_DIR/state")
  [ "${busy%% *}" = busy ] || fail "Hermes start acknowledgement did not imply semantic busy state"
  fixture_hook on_session_end "$stable"
  pass "Hermes binds one session and acknowledges only after busy state"
}

# fm-send decides a resumed turn actually started by content-comparing
# state/<id>.hermes-started against a snapshot taken before the resume, and a
# false "equal" becomes a non-retryable delivered-no-turn verdict. Session id
# and event are stable by construction for a resumed task and a pid is
# reusable, so this pins that consecutive acknowledgements differ on something
# other than the pid.
# A rendered Hermes ready footer is a screen state, not a lifecycle fact: a
# redraw, scroll, or tool render can show it while a turn is running. A trusted
# pre_llm_call busy record must therefore outrank it, or fm-send would admit a
# steer into a live turn (Hermes treats that as an interrupt, not a queue).
test_hermes_busy_record_outranks_rendered_ready_footer() {
  local rec stable ready busy
  TEST_ID=hermes-record-precedence-x11
  rec=$(make_case record-precedence "$TEST_ID")
  read_case "$rec"
  fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" --harness hermes \
    --model gpt-5.6-sol --effort high --mode no-mistakes --yolo off >/dev/null \
    || fail "Hermes record-precedence fixture spawn failed"
  stable=$(cat "$HOME_DIR/state/$TEST_ID.hermes-session")
  fixture_hook pre_llm_call "$stable"
  ready=$' \xe2\x94\x80 ready \xe2\x94\x82 gpt 5.6 sol low \xe2\x94\x82\n \xe2\x9d\xaf Ask me anything\xe2\x80\xa6'
  # shellcheck disable=SC2016 # Positional parameters expand inside the fixture shell.
  busy=$(fixture_env bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux unused hermes "$2" "$3" "$4"' \
    _ "$ROOT" "$TEST_ID" "$HOME_DIR/state" "$ready")
  [ "${busy%% *}" = busy ] \
    || fail "a rendered ready footer demoted a trusted busy lifecycle record: $busy"
  fixture_hook on_session_end "$stable"
  # shellcheck disable=SC2016 # Positional parameters expand inside the fixture shell.
  busy=$(fixture_env bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux unused hermes "$2" "$3" "$4"' \
    _ "$ROOT" "$TEST_ID" "$HOME_DIR/state" "$ready")
  [ "${busy%% *}" = idle ] \
    || fail "Hermes turn end did not settle idle with the same ready footer: $busy"
  fixture_env "$TEARDOWN" "$TEST_ID" --force >/dev/null 2>&1 \
    || fail "Hermes record-precedence fixture teardown failed"
  pass "a trusted Hermes busy record outranks a rendered ready footer"
}

test_hermes_start_ack_is_unique_per_turn() {
  local rec stable started first second first_nopid second_nopid
  TEST_ID=hermes-start-ack-x16
  rec=$(make_case start-ack "$TEST_ID")
  read_case "$rec"
  fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" --harness hermes \
    --model gpt-5.6-sol --effort high --mode no-mistakes --yolo off >/dev/null \
    || fail "Hermes start-acknowledgement fixture spawn failed"
  stable=$(cat "$HOME_DIR/state/$TEST_ID.hermes-session")
  started="$HOME_DIR/state/$TEST_ID.hermes-started"

  fixture_hook pre_llm_call "$stable"
  first=$(cat "$started")
  fixture_hook pre_llm_call "$stable"
  second=$(cat "$started")

  [ "${first%%:*}" = "$stable" ] && [ "${second%%:*}" = "$stable" ] \
    || fail "a start acknowledgement lost its task-bound session id"
  [ "$first" != "$second" ] \
    || fail "two consecutive start acknowledgements were byte-identical: $first"

  first_nopid=$(printf '%s\n' "$first" | cut -d: -f1,2,4-)
  second_nopid=$(printf '%s\n' "$second" | cut -d: -f1,2,4-)
  [ "$first_nopid" != "$second_nopid" ] \
    || fail "start acknowledgements differ only by pid, so pid reuse would look like no new turn: $first_nopid"

  # Every acknowledgement in a burst must be distinct, not merely adjacent ones.
  : > "$CASE_DIR/acks.log"
  for _ in 1 2 3 4 5 6 7 8; do
    fixture_hook pre_llm_call "$stable"
    cut -d: -f1,2,4- < "$started" >> "$CASE_DIR/acks.log"
  done
  [ "$(sort -u "$CASE_DIR/acks.log" | wc -l | tr -d '[:space:]')" = 8 ] \
    || fail "a burst of start acknowledgements repeated a pid-independent value"
  pass "each Hermes start acknowledgement is unique independently of the hook pid"
}

test_hermes_hook_waits_through_busy_lock_contention() {
  local rec stable hook_pid busy
  TEST_ID=hermes-hook-contention-x13
  rec=$(make_case hook-contention "$TEST_ID")
  read_case "$rec"
  fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" --harness hermes \
    --model gpt-5.6-sol --effort high --mode no-mistakes --yolo off >/dev/null \
    || fail "Hermes hook-contention fixture spawn failed"
  stable=$(cat "$HOME_DIR/state/$TEST_ID.hermes-session")
  rm -f "$HOME_DIR/state/$TEST_ID.hermes-started"
  mkdir "$HOME_DIR/state/$TEST_ID.busy-state.lock"
  fixture_hook pre_llm_call "$stable" > "$CASE_DIR/contention.out" 2>&1 &
  hook_pid=$!
  sleep 1
  rmdir "$HOME_DIR/state/$TEST_ID.busy-state.lock"
  wait "$hook_pid" || fail "Hermes pre-LLM hook failed after bounded busy-lock contention"
  assert_present "$HOME_DIR/state/$TEST_ID.hermes-started" "Hermes hook contention lost start acknowledgement"
  # shellcheck disable=SC2016 # Positional parameters expand inside the fixture shell.
  busy=$(fixture_env bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux unused hermes "$2" "$3"' _ "$ROOT" "$TEST_ID" "$HOME_DIR/state")
  [ "${busy%% *}" = busy ] || fail "Hermes hook contention did not finish the busy transition"
  fixture_hook on_session_end "$stable"
  pass "Hermes hook survives bounded busy-lock contention"
}

test_hermes_delivered_no_turn_persistence_failure_is_distinct() {
  local rec out rc wake
  TEST_ID=hermes-persistence-x10
  rec=$(make_case persistence "$TEST_ID")
  read_case "$rec"
  fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" --harness hermes \
    --model gpt-5.6-sol --effort high --mode no-mistakes --yolo off >/dev/null \
    || fail "Hermes persistence fixture spawn failed"
  rm -f "$HOME_DIR/state/$TEST_ID.status"
  : > "$CASE_DIR/status-target"
  ln -s "$CASE_DIR/status-target" "$HOME_DIR/state/$TEST_ID.status"
  rc=0
  out=$(fixture_env env FM_FAKE_HERMES_NO_PRE_LLM=1 "$SEND" "$TEST_ID" \
    'Acknowledge failure probe.' 2>&1) || rc=$?
  expect_code 5 "$rc" "Hermes recovery persistence failure should be distinct"
  assert_contains "$out" "delivered-no-turn-persistence-failed" "Hermes persistence failure lost its verdict"
  assert_contains "$out" "do not resend" "Hermes persistence failure did not forbid redelivery"
  wake=$(cat "$HOME_DIR/state/.wake-queue")
  assert_contains "$wake" $'\tsignal\t'"$TEST_ID.status"$'\tdelivered-no-turn: '"$TEST_ID" \
    "Hermes marker failure prevented the independent recovery wake"
  pass "Hermes persistence failure is distinct after delivery"
}

test_hermes_resume_inherits_launch_ack_budget() {
  local rec out rc elapsed
  TEST_ID=hermes-resume-budget-x15
  rec=$(make_case resume-budget "$TEST_ID")
  read_case "$rec"
  fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" --harness hermes \
    --model gpt-5.6-sol --effort high --mode no-mistakes --yolo off >/dev/null \
    || fail "Hermes resume-budget fixture spawn failed"
  SECONDS=0
  rc=0
  out=$(fixture_env env -u FM_SEND_HERMES_START_POLLS -u FM_SEND_HERMES_START_INTERVAL \
    FM_HERMES_LAUNCH_ACK_POLLS=2 FM_HERMES_LAUNCH_ACK_INTERVAL=0.01 \
    FM_FAKE_HERMES_NO_PRE_LLM=1 "$SEND" "$TEST_ID" 'Budget inheritance probe.' 2>&1) || rc=$?
  elapsed=$SECONDS
  expect_code 4 "$rc" "Hermes resume without acknowledgement should keep delivered-no-turn semantics"
  [ "$elapsed" -lt 10 ] || fail "Hermes resume did not inherit the bounded launch acknowledgement budget"
  assert_contains "$out" "delivered-no-turn" "Hermes inherited-budget failure lost its verdict"
  pass "Hermes resume inherits launch acknowledgement timing"
}

test_hermes_refuses_nonresumable_backends() {
  local backend rec out rc
  for backend in zellij orca cmux; do
    TEST_ID="hermes-backend-$backend-x11"
    rec=$(make_case "backend-$backend" "$TEST_ID")
    read_case "$rec"
    rc=0
    out=$(fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" --harness hermes --backend "$backend" \
      --model gpt-5.6-sol --effort high --mode no-mistakes --yolo off 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "Hermes spawn accepted nonresumable backend=$backend"
    assert_contains "$out" "supports persistent TUI spawns only on tmux and herdr" \
      "Hermes backend=$backend refusal omitted its persistent-TUI boundary"
    assert_not_contains "$(cat "$CASE_DIR/tmux.log")" "new-window" \
      "Hermes backend=$backend refusal created an endpoint"
  done
  pass "Hermes refuses backends without resumable idle-shell proof"
}

test_hermes_help_states_kind_scope() {
  local out
  out=$($SPAWN --help)
  assert_contains "$out" "Hermes overrides only a crewmate or scout spawn" \
    "fm-spawn help did not state Hermes kind scope"
  assert_contains "$out" "refused for secondmates" "fm-spawn help did not state the secondmate refusal"
  assert_contains "$out" "Secondmates refuse every raw launch command" \
    "fm-spawn help did not state the raw-command kind boundary"
  pass "fm-spawn help states Hermes kind scope"
}

test_hermes_spawn_requires_pre_llm_acknowledgement() {
  local rec out rc
  TEST_ID=hermes-start-only-x3
  rec=$(make_case start-only "$TEST_ID")
  read_case "$rec"
  rc=0
  out=$(fixture_env env FM_FAKE_HERMES_START_ONLY=1 "$SPAWN" "$TEST_ID" "$PROJECT_DIR" \
    --harness hermes --model gpt-5.6-sol --effort high --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Hermes spawn accepted on_session_start without pre_llm_call"
  assert_contains "$out" "initial instruction did not publish a resumable session" \
    "Hermes spawn did not refuse a missing pre_llm_call acknowledgement"
  assert_not_contains "$out" "spawned $TEST_ID" "Hermes spawn reported success without pre_llm_call"
  pass "Hermes spawn requires pre_llm_call acknowledgement"
}

test_hermes_concurrent_sends_serialize_through_acknowledgement() {
  local rec block first_pid second_pid first_rc second_rc commands status
  TEST_ID=hermes-concurrent-x4
  rec=$(make_case concurrent "$TEST_ID")
  read_case "$rec"
  fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" --harness hermes \
    --model gpt-5.6-sol --effort high --mode no-mistakes --yolo off >/dev/null \
    || fail "Hermes concurrency fixture spawn failed"
  block="$CASE_DIR/block"
  mkdir -p "$block"
  printf '%s\n' 'needs-decision [key=first-send]: first answer' \
    'needs-decision [key=second-send]: second answer' >> "$HOME_DIR/state/$TEST_ID.status"

  fixture_env env FM_FAKE_HERMES_BLOCK_DIR="$block" "$SEND" "$TEST_ID" \
    --resolve-key first-send 'First concurrent answer.' > "$CASE_DIR/first.out" 2>&1 &
  first_pid=$!
  for _ in $(seq 1 500); do
    [ -f "$block/first-entered" ] && break
    sleep 0.01
  done
  [ -f "$block/first-entered" ] || fail "first concurrent Hermes send did not reach the backend"

  fixture_env env FM_FAKE_HERMES_BLOCK_DIR="$block" "$SEND" "$TEST_ID" \
    --resolve-key second-send 'Second concurrent answer.' > "$CASE_DIR/second.out" 2>&1 &
  second_pid=$!
  for _ in $(seq 1 200); do
    kill -0 "$second_pid" 2>/dev/null || break
    sleep 0.01
  done
  assert_absent "$block/second-entered" "second concurrent Hermes send crossed the first acknowledgement boundary"
  status=$(cat "$HOME_DIR/state/$TEST_ID.status")
  assert_not_contains "$status" 'resolved [key=first-send]' "first decision closed before start acknowledgement"
  assert_not_contains "$status" 'resolved [key=second-send]' "second decision closed before delivery"

  touch "$block/release-first"
  first_rc=0
  wait "$first_pid" || first_rc=$?
  second_rc=0
  wait "$second_pid" || second_rc=$?
  expect_code 0 "$first_rc" "first concurrent Hermes send should succeed"
  expect_code 0 "$second_rc" "second concurrent Hermes send should succeed"
  commands=$(cat "$CASE_DIR/commands.log")
  assert_contains "$commands" "First concurrent answer." "first concurrent Hermes send was not delivered"
  assert_contains "$commands" "Second concurrent answer." "second concurrent Hermes send was not delivered"
  status=$(cat "$HOME_DIR/state/$TEST_ID.status")
  assert_contains "$status" 'resolved [key=first-send]' "first decision did not close after acknowledgement"
  assert_contains "$status" 'resolved [key=second-send]' "second decision did not close after acknowledgement"
  pass "Hermes concurrent sends serialize through start acknowledgement"
}

test_hermes_static_crew_resolution() {
  local config out
  config="$TMP_ROOT/static-config"
  mkdir -p "$config"
  printf 'hermes\n' > "$config/crew-harness"
  out=$(FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-harness.sh" crew)
  [ "$out" = hermes ] || fail "configured Hermes crew harness resolved '$out'"
  pass "fm-harness resolves configured Hermes crewmates"
}

# A crew-only Hermes fleet must still be able to launch secondmates: the
# documented secondmate fallback chain skips the ineligible crew value and
# continues to primary harness auto-detection instead of resolving to a harness
# with no verified secondmate launch template.
test_hermes_crew_only_is_filtered_from_secondmate_fallback() {
  local config out
  config="$TMP_ROOT/crew-only-secondmate/config"
  mkdir -p "$config"
  printf 'hermes\n' > "$config/crew-harness"
  out=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-harness.sh" secondmate)
  [ "$out" = claude ] \
    || fail "crew-only hermes leaked into implicit secondmate resolution: '$out'"
  out=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-harness.sh" crew)
  [ "$out" = hermes ] || fail "crew resolution changed while filtering the secondmate: '$out'"

  printf 'hermes\n' > "$config/secondmate-harness"
  out=$(CLAUDECODE=1 FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-harness.sh" secondmate)
  [ "$out" = hermes ] \
    || fail "an explicit secondmate-harness must stay authoritative: '$out'"
  pass "crew-only Hermes is ineligible for the implicit secondmate fallback"
}

# A persistent Hermes Herdr pane is alive only while Herdr reports a registered
# agent; the resumable session sidecar no longer upgrades an idle shell husk.
test_hermes_herdr_persistent_process_classifies_alive() {
  local case_dir state fakebin meta out
  case_dir="$TMP_ROOT/herdr-state"
  state="$case_dir/state"
  fakebin="$case_dir/bin"
  mkdir -p "$state" "$fakebin"
  ln -s "$JQ_BIN" "$fakebin/jq"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "$1 $2" in
  'pane get') printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3" ;;
  'agent get')
    if [ "$(cat "$FM_FAKE_HERDR_MODE")" = live ]; then
      printf '{"result":{"agent":{"agent":"hermes","agent_status":"idle"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    ;;
  *) printf '{"error":{"code":"unsupported"}}\n' ;;
esac
SH
  chmod +x "$fakebin/herdr"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/hermes"
  chmod +x "$fakebin/hermes"
  printf 'live\n' > "$case_dir/herdr-mode"
  meta="$state/herdr-hermes.meta"
  {
    printf 'window=fmlab:pane-1\n'
    printf 'endpoint_task_id=herdr-hermes\n'
    printf 'worktree=/tmp/herdr-hermes-worktree\n'
    printf 'project=/tmp/herdr-hermes-project\n'
    printf 'harness=hermes\n'
    printf 'backend=herdr\n'
    printf 'herdr_session=fmlab\n'
    printf 'herdr_workspace_id=ws-1\n'
    printf 'herdr_tab_id=tab-1\n'
    printf 'herdr_pane_id=pane-1\n'
    printf 'hermes_bin=%s\n' "$fakebin/hermes"
    printf 'hermes_session_file=%s\n' "$state/herdr-hermes.hermes-session"
  } > "$meta"
  printf 'hermes-session-herdr\n' > "$state/herdr-hermes.hermes-session"

  # shellcheck disable=SC2016 # Positional parameters expand inside the probe shell.
  out=$(FM_FAKE_HERDR_MODE="$case_dir/herdr-mode" PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_agent_state herdr "$2" "$3"' _ "$ROOT" fmlab:pane-1 "$meta")
  [ "$out" = alive ] || fail "persistent Hermes herdr pane classified '$out'"
  # shellcheck disable=SC2016 # Positional parameters expand inside the probe shell.
  out=$(FM_FAKE_HERDR_MODE="$case_dir/herdr-mode" PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_agent_alive herdr "$2" "$3"' _ "$ROOT" fmlab:pane-1 "$meta")
  [ "$out" = alive ] || fail "the three-state herdr view lost the live Hermes TUI: '$out'"

  printf 'husk\n' > "$case_dir/herdr-mode"
  # shellcheck disable=SC2016 # Positional parameters expand inside the probe shell.
  out=$(FM_FAKE_HERDR_MODE="$case_dir/herdr-mode" PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_agent_state herdr "$2" "$3"' _ "$ROOT" fmlab:pane-1 "$meta")
  [ "$out" = dead ] || fail "a Hermes shell husk with a session sidecar classified '$out'"
  pass "Hermes Herdr liveness requires the persistent registered TUI process"
}

# The Herdr presentation-journal reclaim guard itself, driven directly through
# bin/fm-spawn-herdr-reclaim-lib.sh. This is the code that decides whether a
# relaunch under an existing task id may reclaim the recorded pane. Before the
# routing fix it read the pane classifier without the task metadata, so an idle
# Hermes crewmate looked agent-free and the guard allowed the reclaim that
# deletes the session sidecar; with the metadata routed through
# fm_backend_agent_state it refuses instead. The unreadable-metadata case pins
# the fail-closed direction the same routing introduced.
test_herdr_reclaim_guard_preserves_hermes_session() {
  local case_dir state fakebin meta out rc
  case_dir="$TMP_ROOT/herdr-reclaim-guard"
  state="$case_dir/state"
  fakebin="$case_dir/bin"
  mkdir -p "$state" "$fakebin"
  ln -s "$JQ_BIN" "$fakebin/jq"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "$1 ${2:-}" in
  'status --json') printf '{"server":{"running":true},"client":{"protocol":14}}\n' ;;
  'pane get') printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$3" ;;
  'agent get')
    if [ "$(cat "$FM_FAKE_HERDR_MODE")" = live ]; then
      printf '{"result":{"agent":{"agent":"hermes","agent_status":"idle"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    ;;
  *) printf '{"error":{"code":"unsupported"}}\n' ;;
esac
SH
  chmod +x "$fakebin/herdr"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/hermes"
  chmod +x "$fakebin/hermes"
  printf 'live\n' > "$case_dir/herdr-mode"

  meta="$state/reclaim-hermes.meta"
  {
    printf 'harness=hermes\n'
    printf 'endpoint_task_id=reclaim-hermes\n'
    printf 'worktree=/tmp/reclaim-hermes-worktree\n'
    printf 'project=/tmp/reclaim-hermes-project\n'
    printf 'backend=herdr\n'
    printf 'window=fmlab:pane-1\n'
    printf 'herdr_session=fmlab\n'
    printf 'herdr_workspace_id=ws-1\n'
    printf 'herdr_tab_id=tab-1\n'
    printf 'herdr_pane_id=pane-1\n'
    printf 'hermes_bin=%s\n' "$fakebin/hermes"
    printf 'hermes_session_file=%s\n' "$state/reclaim-hermes.hermes-session"
  } > "$meta"
  printf 'hermes-session-reclaim\n' > "$state/reclaim-hermes.hermes-session"

  # shellcheck disable=SC2016 # Positional parameters expand inside the guard shell.
  rc=0
  out=$(FM_FAKE_HERDR_MODE="$case_dir/herdr-mode" PATH="$fakebin:$BASE_PATH" bash -c '
    set -u
    ID=reclaim-hermes
    . "$1/bin/fm-backend.sh"
    . "$1/bin/fm-spawn-herdr-reclaim-lib.sh"
    herdr_projection_existing_meta_allows_flat "$2"
  ' _ "$ROOT" "$meta" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "the reclaim guard allowed a relaunch over an idle Hermes session: $out"
  assert_contains "$out" "existing herdr endpoint for reclaim-hermes is live" \
    "the reclaim guard did not classify the bound Hermes session as live"
  assert_present "$state/reclaim-hermes.hermes-session" \
    "the refused reclaim discarded the resumable session"

  printf 'husk\n' > "$case_dir/herdr-mode"
  rc=0
  out=$(FM_FAKE_HERDR_MODE="$case_dir/herdr-mode" PATH="$fakebin:$BASE_PATH" bash -c '
    set -u
    ID=reclaim-hermes
    . "$1/bin/fm-backend.sh"
    . "$1/bin/fm-spawn-herdr-reclaim-lib.sh"
    herdr_projection_existing_meta_allows_flat "$2"
  ' _ "$ROOT" "$meta" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a Hermes pane without its persistent TUI must be reclaimable even with resume state: $out"

  printf 'harness=hermes\n' >> "$meta"
  rc=0
  out=$(FM_FAKE_HERDR_MODE="$case_dir/herdr-mode" PATH="$fakebin:$BASE_PATH" bash -c '
    set -u
    ID=reclaim-hermes
    . "$1/bin/fm-backend.sh"
    . "$1/bin/fm-spawn-herdr-reclaim-lib.sh"
    herdr_projection_existing_meta_allows_flat "$2"
  ' _ "$ROOT" "$meta" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an ambiguous harness record must refuse the reclaim: $out"
  assert_contains "$out" "existing herdr endpoint for reclaim-hermes is unknown" \
    "an unreadable task record did not fail closed"
  pass "the herdr reclaim guard preserves a live Hermes TUI and reclaims only a proven husk"
}

test_hermes_scout_defaults_model_and_preserves_every_effort() {
  local rec effort launch
  for effort in low medium high xhigh max; do
    TEST_ID="hermes-scout-default-$effort-x21"
    rec=$(make_case "scout-default-$effort" "$TEST_ID")
    read_case "$rec"
    fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" --harness hermes --scout \
      --effort "$effort" >/dev/null 2>&1 || fail "Hermes scout spawn was refused for effort=$effort"
    launch=$(grep 'hermes.*chat --tui' "$CASE_DIR/commands.log" | head -1)
    assert_contains "$launch" "--provider openai-codex" "Hermes scout launch lost its provider"
    assert_contains "$launch" "--model 'gpt-5.6-sol'" "Hermes scout launch did not default to gpt-5.6-sol"
    assert_contains "$launch" "--reasoning '$effort'" "Hermes scout launch dropped reasoning effort $effort"
    assert_grep "model=gpt-5.6-sol" "$HOME_DIR/state/$TEST_ID.meta" "Hermes scout metadata lost the default model"
    assert_grep "effort=$effort" "$HOME_DIR/state/$TEST_ID.meta" "Hermes scout metadata lost effort $effort"
    fixture_env "$TEARDOWN" "$TEST_ID" --force >/dev/null 2>&1 || fail "Hermes scout fixture teardown failed"
  done
  pass "Hermes scouts default to gpt-5.6-sol on openai-codex and preserve low/medium/high/xhigh/max reasoning"
}

test_hermes_hook_install_is_surgical_idempotent_and_removable
test_hermes_spawn_tui_skill_state_and_teardown
test_hermes_secondmate_is_refused
test_secondmates_refuse_every_raw_launch_command
test_workers_and_scouts_preserve_raw_launch_commands
test_hermes_tui_busy_state_and_composer
test_hermes_spawn_resumes_existing_tui_session
test_hermes_session_binding_and_busy_ack_order
test_hermes_busy_record_outranks_rendered_ready_footer
test_hermes_start_ack_is_unique_per_turn
test_hermes_hook_waits_through_busy_lock_contention
test_hermes_delivered_no_turn_persistence_failure_is_distinct
test_hermes_resume_inherits_launch_ack_budget
test_hermes_refuses_nonresumable_backends
test_hermes_help_states_kind_scope
test_hermes_spawn_requires_pre_llm_acknowledgement
test_hermes_concurrent_sends_serialize_through_acknowledgement
test_hermes_static_crew_resolution
test_hermes_crew_only_is_filtered_from_secondmate_fallback
test_hermes_herdr_persistent_process_classifies_alive
test_herdr_reclaim_guard_preserves_hermes_session
test_hermes_scout_defaults_model_and_preserves_every_effort
