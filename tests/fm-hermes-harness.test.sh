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
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
fire_hook() {
  local event=$1 hook="$HERMES_HOME/fm-turn-end.sh"
  printf '{"hook_event_name":"%s","session_id":"hermes-session-test","cwd":"%s","task_id":"","turn_id":"turn-test"}\n' \
    "$event" "$FM_FAKE_PANE_PATH" \
    | HERMES_HOME="$HERMES_HOME" bash "$hook"
}
submit_command() {
  local command=$1
  printf '%s\n' "$command" >> "$FM_FAKE_COMMAND_LOG"
  case "$command" in
    *hermes*chat*-Q*--query*)
      case "$command" in *--resume*) ;; *) fire_hook on_session_start ;; esac
      fire_hook pre_llm_call
      fire_hook on_session_end
      ;;
  esac
}
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *'#{pane_current_command}'*) printf 'zsh\n'; exit 0 ;;
  *'#{pane_id}'*) printf '%%1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ ! -f "$FM_FAKE_WINDOW_STATE" ] || printf '%s\n' "$FM_FAKE_WINDOW"; exit 0 ;;
  new-window) touch "$FM_FAKE_WINDOW_STATE"; printf '@1\n'; exit 0 ;;
  kill-window) rm -f "$FM_FAKE_WINDOW_STATE"; exit 0 ;;
  has-session|new-session|set-window-option) exit 0 ;;
  send-keys)
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
  capture-pane) printf '$ \n'; exit 0 ;;
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
    FM_FAKE_WINDOW_STATE="$CASE_DIR/window.state" \
    FM_HERMES_PYTHON="$PYTHON_BIN" FM_HERMES_LAUNCH_ACK_POLLS=2 \
    FM_HERMES_LAUNCH_ACK_INTERVAL=0 FM_SEND_HERMES_START_POLLS=4 \
    FM_SEND_HERMES_START_INTERVAL=0.01 FM_SEND_SETTLE=0 TMUX='fake,1,0' \
    PATH="$FAKEBIN_DIR:$BASE_PATH" "$@"
}

test_hermes_hook_install_is_surgical_idempotent_and_removable() {
  local home config original once no_newline
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
  cp "$config" "$once"
  HERMES_HOME="$home" HERMES_BIN="$TMP_ROOT/config-hermes" FM_HERMES_PYTHON="$PYTHON_BIN" \
    "$HOOK_INSTALLER" install || fail "second Hermes hook install failed"
  cmp -s "$once" "$config" || fail "second Hermes hook install changed config bytes"
  assert_grep '/foreign/hook.sh' "$config" "Hermes hook install removed a foreign hook"
  HERMES_HOME="$home" HERMES_BIN="$TMP_ROOT/config-hermes" FM_HERMES_PYTHON="$PYTHON_BIN" \
    "$HOOK_INSTALLER" remove || fail "Hermes hook removal failed"
  cmp -s "$original" "$config" || fail "Hermes hook removal did not restore foreign config bytes"
  assert_absent "$home/fm-turn-end.sh" "Hermes hook removal left its script"
  assert_absent "$home/fm-turn-end.d" "Hermes hook removal left its registry"

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

test_hermes_spawn_resume_skill_state_and_teardown() {
  local rec out rc launch meta state_line token registry commands
  TEST_ID=hermes-lifecycle-x1
  rec=$(make_case lifecycle "$TEST_ID")
  read_case "$rec"
  out=$(fixture_env "$SPAWN" "$TEST_ID" "$PROJECT_DIR" --harness hermes \
    --model gpt-5.6-sol --effort xhigh --mode no-mistakes --yolo off 2>&1)
  rc=$?
  expect_code 0 "$rc" "Hermes spawn should succeed"
  assert_contains "$out" "spawned $TEST_ID harness=hermes" "Hermes spawn did not report success"
  launch=$(grep 'hermes.*chat -Q' "$CASE_DIR/commands.log" | head -1)
  assert_contains "$launch" "chat -Q --query" "Hermes launch did not use quiet headless chat"
  assert_contains "$launch" "--provider openai-codex" "Hermes launch lost its provider"
  assert_contains "$launch" "--model 'gpt-5.6-sol'" "Hermes launch lost its model"
  assert_contains "$launch" "--reasoning 'xhigh'" "Hermes launch lost its reasoning effort"
  assert_contains "$launch" "--accept-hooks --yolo --pass-session-id" "Hermes launch lost autonomy/session flags"
  assert_not_contains "$launch" "--safe-mode" "Hermes launch disabled its hooks and rules"
  assert_not_contains "$launch" " -z " "Hermes launch used the non-resumable v0.20.0 one-shot path"

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

  fixture_env "$SEND" "$TEST_ID" 'Continue with the adapter.' || fail "Hermes follow-up resume failed"
  fixture_env "$SEND" "$TEST_ID" /no-mistakes || fail "Hermes skill resume failed"
  fixture_env "$SEND" "$TEST_ID" /native-check || fail "Hermes native skill resume failed"
  commands=$(cat "$CASE_DIR/commands.log")
  assert_contains "$commands" "--resume 'hermes-session-test'" "Hermes steer did not resume the stable session"
  assert_contains "$commands" "--no-restore-cwd" "Hermes steer did not retain the task worktree"
  assert_contains "$commands" "Read the skill at $HOME_DIR/.agents/skills/no-mistakes/SKILL.md completely and follow it now." \
    "Hermes skill invocation did not use the validated Firstmate skill pointer"
  assert_contains "$commands" "--skills 'native-check'" "Hermes native skill invocation did not preload the skill"
  assert_contains "$commands" "Apply the preloaded native-check skill now." "Hermes native skill invocation lost its action prompt"
  fixture_env "$SEND" "$TEST_ID" --key C-c || fail "Hermes interrupt key was not mapped"
  assert_contains "$(cat "$CASE_DIR/tmux.log")" " C-c" "Hermes interrupt did not send Ctrl+C"
  fixture_env "$SEND" "$TEST_ID" /exit || fail "idle Hermes exit should be an idempotent no-op"

  fixture_env "$TEARDOWN" "$TEST_ID" --force >/dev/null 2>&1 || fail "Hermes teardown failed"
  assert_absent "$WORKTREE_DIR/.fm-hermes-turnend" "Hermes pointer survived teardown"
  assert_absent "$registry" "Hermes registry token survived teardown"
  assert_absent "$HOME_DIR/state/$TEST_ID.hermes-turnend-token" "Hermes state token survived teardown"
  assert_absent "$HOME_DIR/state/$TEST_ID.hermes-session" "Hermes session sidecar survived teardown"
  assert_absent "$HOME_DIR/state/$TEST_ID.hermes-started" "Hermes start marker survived teardown"
  pass "Hermes crew lifecycle covers launch, hook state, resume, skill, interrupt, exit, state read, and teardown"
}

test_hermes_secondmate_is_refused() {
  local rec out rc
  TEST_ID=hermes-secondmate-x2
  rec=$(make_case secondmate "$TEST_ID")
  read_case "$rec"
  rc=0
  out=$(fixture_env "$SPAWN" "$TEST_ID" "$HOME_DIR/not-a-secondmate" --secondmate --harness hermes 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Hermes was accepted as a secondmate harness"
  assert_contains "$out" "hermes" "Hermes secondmate refusal omitted the harness identity"
  assert_not_contains "$(cat "$CASE_DIR/tmux.log")" "new-window" "Hermes secondmate refusal created an endpoint"
  pass "Hermes remains crewmate/scout-only"
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

test_hermes_hook_install_is_surgical_idempotent_and_removable
test_hermes_spawn_resume_skill_state_and_teardown
test_hermes_secondmate_is_refused
test_hermes_static_crew_resolution
