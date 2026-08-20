#!/usr/bin/env bash
# Opt-in real OMP persistent-secondmate lifecycle on a private tmux socket.
set -u

if [ "${FM_OMP_SECONDMATE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_SECONDMATE_LIVE_E2E=1 to run the isolated OMP secondmate lifecycle"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-primary-watch-version-lib.sh
. "$ROOT/bin/fm-primary-watch-version-lib.sh"

command -v omp >/dev/null 2>&1 || fail "omp not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"
OMP_BIN=$("$ROOT/bin/fm-omp-capabilities.sh" --print-binary) || fail "OMP capability check failed"
OMP_BIN=$(fm_test_realpath "$OMP_BIN") || fail "OMP binary realpath could not be resolved"
REAL_TMUX=$(command -v tmux)
LAB=$(fm_test_tmproot fm-omp-secondmate-live)
SOCKET="fm-omp-secondmate-live-$$"
ID="omp-live-$$"
WINDOW="fm-$ID"
TARGET="firstmate:$WINDOW"
PRIMARY_HOME="$LAB/primary-home"
SECOND_HOME="$LAB/secondmate-home"
WRAPPER_BIN="$LAB/bin"
MAIN_STATE="$PRIMARY_HOME/state"
MAIN_DATA="$PRIMARY_HOME/data"
MAIN_CONFIG="$PRIMARY_HOME/config"
MAIN_PROJECTS="$PRIMARY_HOME/projects"
MODEL=${FM_OMP_SECONDMATE_LIVE_MODEL:-openai-codex/gpt-5.6-luna}
THINKING=${FM_OMP_SECONDMATE_LIVE_THINKING:-low}

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$LAB" "/tmp/fm-$ID"
}
trap cleanup EXIT

mkdir -p "$MAIN_STATE" "$MAIN_DATA" "$MAIN_CONFIG" "$MAIN_PROJECTS" "$WRAPPER_BIN" \
  "$SECOND_HOME/data" "$SECOND_HOME/state" "$SECOND_HOME/config" "$SECOND_HOME/projects"
cp "$ROOT/AGENTS.md" "$ROOT/.gitignore" "$ROOT/.tasks.toml" "$SECOND_HOME/"
cp -R "$ROOT/bin" "$ROOT/.agents" "$ROOT/.omp" "$ROOT/docs" "$SECOND_HOME/"
printf '%s\n' "$ID" > "$SECOND_HOME/.fm-secondmate-home"
git init -q -b main "$SECOND_HOME"
fm_git_identity fmtest fmtest@example.invalid
git -C "$SECOND_HOME" add AGENTS.md .gitignore .tasks.toml bin .agents .omp docs
printf 'seed\n' > "$SECOND_HOME/README.md"
git -C "$SECOND_HOME" add README.md
git -C "$SECOND_HOME" commit -qm init

printf 'omp %s %s\n' "$MODEL" "$THINKING" > "$MAIN_CONFIG/secondmate-harness"
printf 'codex\n' > "$MAIN_CONFIG/crew-harness"
FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$MAIN_STATE" \
  FM_DATA_OVERRIDE="$MAIN_DATA" FM_CONFIG_OVERRIDE="$MAIN_CONFIG" \
  FM_PROJECTS_OVERRIDE="$MAIN_PROJECTS" \
  FM_SECONDMATE_CHARTER='Wait for marked lifecycle-test requests and route every correlated answer to the parent status path.' \
  FM_SECONDMATE_SCOPE='OMP persistent-secondmate lifecycle verification only.' \
  "$ROOT/bin/fm-brief.sh" "$ID" --secondmate --no-projects >/dev/null

cat > "$WRAPPER_BIN/tmux" <<SH
#!/usr/bin/env bash
exec '$REAL_TMUX' -L '$SOCKET' "\$@"
SH
chmod +x "$WRAPPER_BIN/tmux"

fm_env() {
  env PATH="$WRAPPER_BIN:$PATH" TMUX='' OMP_SKIP_SETUP=1 FM_BACKEND=tmux \
    FM_HOME="$PRIMARY_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$MAIN_STATE" FM_DATA_OVERRIDE="$MAIN_DATA" \
    FM_CONFIG_OVERRIDE="$MAIN_CONFIG" FM_PROJECTS_OVERRIDE="$MAIN_PROJECTS" \
    "$@"
}

capture() {
  PATH="$WRAPPER_BIN:$PATH" tmux capture-pane -p -t "$TARGET" -S -300 2>/dev/null || true
}

wait_for() { # <description> <command...>
  local description=$1 i=0
  shift
  while [ "$i" -lt 600 ]; do
    "$@" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  fail "timed out waiting for $description"
}

marker_valid() {
  local marker="$SECOND_HOME/state/.omp-primary-extension-loaded" version pid lock bun bin
  [ -s "$marker" ] || return 1
  version=$(sed -n '1p' "$marker")
  pid=$(sed -n '2p' "$marker")
  lock=$(cat "$SECOND_HOME/state/.lock" 2>/dev/null || true)
  bun=$(sed -n '3p' "$marker")
  bin=$(sed -n '4p' "$marker")
  [ "$version" = "$(fm_primary_watch_version "$SECOND_HOME/.omp/extensions/fm-primary-omp.ts" "$SECOND_HOME")" ] || return 1
  [ "$(wc -l < "$marker" | tr -d '[:space:]')" = 4 ] \
    && [ "$bun" = "$(sed -n 's/^omp_bun=//p' "$MAIN_STATE/$ID.meta")" ] \
    && [ "$bin" = "$(sed -n 's/^omp_bin=//p' "$MAIN_STATE/$ID.meta")" ] \
    && [ "$pid" = "$lock" ] && kill -0 "$pid" 2>/dev/null
}

agent_state_is() {
  local expected=$1 got
  # shellcheck disable=SC2016  # expansion belongs to the inner bash
  got=$(fm_env bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2" "$3"' \
    _ "$ROOT" "$TARGET" "$MAIN_STATE/$ID.meta")
  [ "$got" = "$expected" ]
}

composer_empty() {
  local got
  # shellcheck disable=SC2016  # expansion belongs to the inner bash
  got=$(fm_env bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_agent_record_identity tmux "$2" "$3" || exit 1; fm_backend_composer_state tmux "$2" omp "$FM_BACKEND_AGENT_OMP_BUN" "$FM_BACKEND_AGENT_OMP_BIN"' \
      _ "$ROOT" "$TARGET" "$MAIN_STATE/$ID.meta")
  [ "$got" = empty ]
}

status_has() {
  grep -F -- "$1" "$MAIN_STATE/$ID.status" >/dev/null 2>&1
}

send_marked() {
  fm_env "$ROOT/bin/fm-send.sh" "$ID" "$1" >/dev/null
}

spawn_secondmate() {
  fm_env FM_OMP_SECONDMATE_ACK_POLLS=240 FM_OMP_LAUNCH_ACK_INTERVAL=0.5 \
    "$ROOT/bin/fm-spawn.sh" "$ID" "$SECOND_HOME" --secondmate
}

out=$(spawn_secondmate 2>&1) || fail "real OMP secondmate launch failed: $out"
wait_for "OMP primary integration marker and session lock" marker_valid
wait_for "idle OMP secondmate composer" composer_empty
agent_state_is alive || fail "idle OMP secondmate was not classified alive"

assert_contains "$(cat "$MAIN_STATE/$ID.meta")" 'harness=omp' "real launch did not record exact OMP identity"
assert_contains "$(cat "$MAIN_STATE/$ID.meta")" "model=$MODEL" "real launch did not record the configured model"
assert_contains "$(cat "$MAIN_STATE/$ID.meta")" "effort=$THINKING" "real launch did not record the configured thinking level"
[ "$(FM_HOME="$PRIMARY_HOME" FM_CONFIG_OVERRIDE="$MAIN_CONFIG" "$ROOT/bin/fm-harness.sh" crew)" = codex ] \
  || fail "OMP secondmate selection changed the primary crew runtime"
[ "$(cat "$SECOND_HOME/config/crew-harness")" = codex ] \
  || fail "OMP secondmate did not inherit the primary crew runtime for its own workers"

first_pid=$(sed -n '2p' "$SECOND_HOME/state/.omp-primary-extension-loaded")
first_args=$(ps -o args= -p "$first_pid" 2>/dev/null || true)
assert_contains "$first_args" "$OMP_BIN" "live OMP process did not retain the selected executable"
assert_contains "$first_args" "--model $MODEL" "live OMP process did not receive the selected model"
assert_contains "$first_args" "--thinking $THINKING" "live OMP process did not receive the selected thinking level"
assert_contains "$first_args" "-e $SECOND_HOME/.omp/extensions/fm-primary-omp.ts" "live OMP process did not explicitly load the isolated primary integration"
assert_contains "$first_args" "--session-dir $SECOND_HOME/state/omp-sessions" "live OMP process did not use durable home-owned sessions"

send_marked 'Persist the secret word ALBATROSS in data/omp-live-context.txt, then return exactly OMP_ROUTED_REPLY and that word through the correlated parent status path.'
wait_for "correlated marked-request reply" status_has OMP_ROUTED_REPLY
first_reply=$(grep -F 'OMP_ROUTED_REPLY' "$MAIN_STATE/$ID.status" | tail -1)
assert_contains "$first_reply" 'corr=' "marked OMP reply omitted its parent correlation token"
assert_contains "$first_reply" 'ALBATROSS' "marked OMP reply omitted the requested context"
wait_for "OMP secondmate to return idle" composer_empty
agent_state_is alive || fail "OMP secondmate was not healthy after a routed reply"

session_pointer="$SECOND_HOME/state/.omp-session"
[ -s "$session_pointer" ] || fail "OMP primary integration did not publish the exact durable session pointer"
session_file=$(cat "$session_pointer")
case "$session_file" in "$SECOND_HOME/state/omp-sessions/"*.jsonl) ;; *) fail "OMP session pointer escaped its durable session directory" ;; esac
[ -f "$session_file" ] || fail "OMP exact durable session file is missing"

fm_env "$ROOT/bin/fm-send.sh" "$TARGET" /exit >/dev/null
wait_for "clean OMP exit to a dead shell" agent_state_is dead
[ -f "$session_file" ] || fail "clean OMP exit removed durable context"

out=$(spawn_secondmate 2>&1) || fail "real OMP secondmate resume failed: $out"
wait_for "resumed OMP primary integration marker" marker_valid
wait_for "resumed OMP secondmate composer" composer_empty
resumed_session_file=$(cat "$session_pointer")
[ "$resumed_session_file" = "$session_file" ] \
  || fail "OMP recovery published a different session identity: $resumed_session_file"
second_pid=$(sed -n '2p' "$SECOND_HOME/state/.omp-primary-extension-loaded")
[ "$second_pid" != "$first_pid" ] || fail "OMP recovery reused the exited process identity"
second_args=$(ps -o args= -p "$second_pid" 2>/dev/null || true)
assert_contains "$second_args" "--resume $session_file" "OMP recovery did not resume the exact durable conversation"
assert_contains "$second_args" "-e $SECOND_HOME/.omp/extensions/fm-primary-omp.ts" "OMP recovery lost primary supervision integration"

send_marked 'Without reading any files, recall the secret word from our preceding conversation and return OMP_RESUME_CONTEXT plus that word through the correlated parent status path.'
wait_for "correlated resumed-context reply" status_has OMP_RESUME_CONTEXT
resume_reply=$(grep -F 'OMP_RESUME_CONTEXT' "$MAIN_STATE/$ID.status" | tail -1)
assert_contains "$resume_reply" 'corr=' "resumed OMP reply omitted its parent correlation token"
assert_contains "$resume_reply" 'ALBATROSS' "resumed OMP conversation lost its durable context"
wait_for "resumed OMP secondmate to return idle" composer_empty

set +e
duplicate=$(spawn_secondmate 2>&1)
duplicate_rc=$?
set -e
[ "$duplicate_rc" -ne 0 ] || fail "live OMP secondmate accepted a duplicate launch"
assert_contains "$duplicate" 'already has a live agent' "live OMP duplicate refusal was not authoritative"
agent_state_is alive || fail "duplicate refusal disturbed the live OMP secondmate"

fm_env "$ROOT/bin/fm-send.sh" "$TARGET" /exit >/dev/null || true
wait_for "final OMP exit" agent_state_is dead

pass "real isolated tmux OMP secondmate launch, idle health, marked replies, exit, same-session resume, context, and duplicate refusal"
