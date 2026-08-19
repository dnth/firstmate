#!/usr/bin/env bash
# tests/fm-omp-secondmate.test.sh - persistent OMP secondmate launch, exact
# durable-session selection, duplicate-safe recovery, and abort preservation.
# shellcheck disable=SC2119,SC2120  # optional env arguments are fixture controls
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-primary-watch-version-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-primary-watch-version-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-$PATH}
TMP_ROOT=$(fm_test_tmproot fm-omp-secondmate)
TASK_ID="omp-sm-$$"
WINDOW_NAME="fm-$TASK_ID"
PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$TMP_ROOT" "/tmp/fm-$TASK_ID"
}
trap cleanup EXIT

setup_case() { # <name>
  rm -rf "/tmp/fm-$TASK_ID"
  CASE="$TMP_ROOT/$1"
  MAIN_STATE="$CASE/main-state"
  MAIN_DATA="$CASE/main-data"
  MAIN_CONFIG="$CASE/main-config"
  MAIN_PROJECTS="$CASE/main-projects"
  HOME_DIR="$CASE/secondmate-home"
  FAKEBIN="$CASE/fakebin"
  TMUX_LOG="$CASE/tmux.log"
  HERDR_LOG="$CASE/herdr.log"
  LAUNCH_LOG="$CASE/launch"
  WINDOW_FLAG="$CASE/window"
  RETIRED_FLAG="$CASE/retired"
  mkdir -p "$MAIN_STATE" "$MAIN_DATA/$TASK_ID" "$MAIN_CONFIG" "$MAIN_PROJECTS" \
    "$HOME_DIR/.omp/extensions" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/projects" "$FAKEBIN" "$CASE/tmp"
  : > "$HERDR_LOG"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$HOME_DIR/.omp/extensions/fm-primary-omp.ts"
  cp "$ROOT/AGENTS.md" "$HOME_DIR/AGENTS.md"
  ln -s "$ROOT/bin" "$HOME_DIR/bin"
  printf '%s\n' "$TASK_ID" > "$HOME_DIR/.fm-secondmate-home"
  printf 'OMP secondmate test charter.\n' > "$MAIN_DATA/$TASK_ID/brief.md"
  printf 'omp test/model low\n' > "$MAIN_CONFIG/secondmate-harness"
  printf 'pi\n' > "$MAIN_CONFIG/crew-harness"
  git -C "$HOME_DIR" init -q
  git -C "$HOME_DIR" config user.name fmtest
  git -C "$HOME_DIR" config user.email fmtest@example.com
  printf 'home\n' > "$HOME_DIR/README.md"
  git -C "$HOME_DIR" add README.md .omp/extensions/fm-primary-omp.ts
  git -C "$HOME_DIR" commit -qm init

  cat > "$FAKEBIN/omp" <<'JS'
#!/usr/bin/env bun
if (process.argv.includes("--hold")) {
  setInterval(() => {}, 60_000);
} else if (process.argv[2] === "models" && process.argv.includes("--json")) {
  console.log(JSON.stringify({models: [
    {selector: "test/model", thinking: ["low", "medium", "high", "xhigh"]},
    {selector: "test/finish", thinking: ["low", "medium", "high", "xhigh"]}
  ]}));
} else console.log(`OMP 17.2.11
--model=provider/id
--thinking=level
--auto-approve
--max-time=value
--approval-mode=mode
--extension=path
--session-dir=path
--resume=path
--prewalk native switch
--prewalk-into=<value>
--no-prewalk`);
JS
  chmod +x "$FAKEBIN/omp"
  TEST_OMP_BIN=$(fm_test_realpath "$FAKEBIN/omp")
  # A Node symlink supplies the fixture's Bun launch boundary without making
  # the portable deterministic lane depend on a host OMP/Bun installation.
  TEST_OMP_BUN=$(fm_test_realpath "$(command -v node)")
  ln -sf "$TEST_OMP_BUN" "$FAKEBIN/bun"
  "$TEST_OMP_BUN" "$TEST_OMP_BIN" --hold &
  AGENT_PID=$!
  PIDS+=("$AGENT_PID")

  cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"tpgid="*"$FM_TEST_AGENT_PID"*) printf '%s\n' "$FM_TEST_AGENT_PID" ;;
  *"args="*"$FM_TEST_AGENT_PID"*) printf '%s %s --auto-approve\n' "$FM_TEST_OMP_BUN" "$FM_TEST_OMP_BIN" ;;
  *) exec /usr/bin/ps "$@" ;;
esac
SH
  chmod +x "$FAKEBIN/ps"

  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%q ' "$@" >> "$FM_TEST_TMUX_LOG"
printf '\n' >> "$FM_TEST_TMUX_LOG"
cmd=${1:-}
shift || true
case "$cmd" in
  has-session|new-session|set-window-option|select-window) exit 0 ;;
  list-windows)
    if [ "${FM_TEST_STATE_MODE:-}" = unreadable ]; then
      printf 'permission denied\n' >&2
      exit 1
    fi
    [ -f "$FM_TEST_WINDOW_FLAG" ] && printf '%s\n' "$FM_TEST_WINDOW_NAME"
    ;;
  new-window)
    : > "$FM_TEST_WINDOW_FLAG"
    printf '@1\n'
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "${FM_TEST_STATE_MODE:-live}" in
          ambiguous) printf 'node\n' ;;
          dead) [ -f "$FM_TEST_RETIRED_FLAG" ] && printf 'omp\n' || printf 'bash\n' ;;
          *) printf 'omp\n' ;;
        esac
        ;;
      *pane_pid*) printf '%s\n' "$FM_TEST_AGENT_PID" ;;
      *pane_current_path*) printf '%s\n' "$FM_TEST_HOME" ;;
      *'#S'*) printf 'firstmate\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  send-keys)
    args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
      if [ "${args[$i]}" = -l ] && [ $((i + 1)) -lt ${#args[@]} ]; then
        printf '%s\n' "${args[$((i + 1))]}" > "$FM_TEST_LAUNCH_LOG"
      fi
    done
    if [ "${args[${#args[@]}-1]:-}" = Enter ] && [ -s "$FM_TEST_LAUNCH_LOG" ] && [ "${FM_TEST_SKIP_ACK:-0}" != 1 ]; then
      mkdir -p "$FM_TEST_HOME/state/omp-sessions"
      session="$FM_TEST_HOME/state/omp-sessions/${FM_TEST_ACK_SESSION:-selected.jsonl}"
      printf '{"type":"session"}\n' > "$session"
      printf '%s\n' "$session" > "$FM_TEST_HOME/state/.omp-session"
      version=$(bash -c '. "$1/bin/fm-primary-watch-version-lib.sh"; fm_primary_watch_version "$1/.omp/extensions/fm-primary-omp.ts" "$1"' _ "$FM_TEST_HOME")
      printf '%s\n%s\n%s\n%s\n' "$version" "$FM_TEST_AGENT_PID" "$FM_TEST_OMP_BUN" "$FM_TEST_OMP_BIN" > "$FM_TEST_HOME/state/.omp-primary-extension-loaded"
      printf '%s\n' "$FM_TEST_AGENT_PID" > "$FM_TEST_HOME/state/.lock"
    fi
    ;;
  kill-window)
    rm -f "$FM_TEST_WINDOW_FLAG"
    : > "$FM_TEST_RETIRED_FLAG"
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/tmux"

  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%q ' "$@" >> "$FM_TEST_HERDR_LOG"
printf '\n' >> "$FM_TEST_HERDR_LOG"
cmd=${1:-}
sub=${2:-}
case "$cmd $sub" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.7.5","protocol":17},"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"2ndmate-%s"}]}}\n' "$FM_TEST_TASK_ID"
    ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[]}}'
    ;;
  "tab create")
    : > "$FM_TEST_WINDOW_FLAG"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
    ;;
  "pane get")
    if [ ! -f "$FM_TEST_WINDOW_FLAG" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    if [ "${FM_TEST_STATE_MODE:-}" = unreadable ] && [ ! -f "$FM_TEST_RETIRED_FLAG" ]; then
      printf '%s\n' '{"error":{"code":"internal_error"}}' >&2
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"w1:p2","foreground_cwd":"%s"}}}\n' "$FM_TEST_HOME"
    ;;
  "agent get")
    if [ ! -f "$FM_TEST_WINDOW_FLAG" ]; then
      printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
      exit 1
    fi
    if [ "${FM_TEST_STATE_MODE:-}" = dead ] && [ ! -f "$FM_TEST_RETIRED_FLAG" ]; then
      printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
      exit 1
    fi
    if [ "${FM_TEST_STATE_MODE:-}" = unreadable ] && [ ! -f "$FM_TEST_RETIRED_FLAG" ]; then
      printf '%s\n' '{"error":{"code":"internal_error"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"agent":{"agent":"omp","agent_status":"idle"}}}'
    ;;
  "pane run")
    ;;
  "pane send-text")
    printf '%s\n' "${4:-}" > "$FM_TEST_LAUNCH_LOG"
    ;;
  "pane send-keys")
    if [ "${4:-}" = enter ] && [ -s "$FM_TEST_LAUNCH_LOG" ] && [ "${FM_TEST_SKIP_ACK:-0}" != 1 ]; then
      mkdir -p "$FM_TEST_HOME/state/omp-sessions"
      session="$FM_TEST_HOME/state/omp-sessions/${FM_TEST_ACK_SESSION:-selected.jsonl}"
      printf '{"type":"session"}\n' > "$session"
      printf '%s\n' "$session" > "$FM_TEST_HOME/state/.omp-session"
      version=$(bash -c '. "$1/bin/fm-primary-watch-version-lib.sh"; fm_primary_watch_version "$1/.omp/extensions/fm-primary-omp.ts" "$1"' _ "$FM_TEST_HOME")
      printf '%s\n%s\n%s\n%s\n' "$version" "$FM_TEST_AGENT_PID" "$FM_TEST_OMP_BUN" "$FM_TEST_OMP_BIN" > "$FM_TEST_HOME/state/.omp-primary-extension-loaded"
      printf '%s\n' "$FM_TEST_AGENT_PID" > "$FM_TEST_HOME/state/.lock"
    fi
    ;;
  "pane close")
    # FM_TEST_REFUSE_CLOSE reproduces herdr's real refusal shape: the close is
    # declined (the pane stays) while the CLI still exits 0.
    if [ "${FM_TEST_REFUSE_CLOSE:-0}" = 1 ]; then
      exit 0
    fi
    rm -f "$FM_TEST_WINDOW_FLAG"
    : > "$FM_TEST_RETIRED_FLAG"
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/herdr"

  cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TREEHOUSE_LOG"
exit 1
SH
  chmod +x "$FAKEBIN/treehouse"
  : > "$CASE/treehouse.log"
}

run_spawn() { # [extra env NAME=VALUE ...] [-- <extra spawn args>]
  local -a env_args=() spawn_args=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    env_args+=("$1")
    shift
  done
  if [ "${1:-}" = -- ]; then
    shift
    spawn_args=("$@")
  fi
  env \
    PATH="$FAKEBIN:$BASE_PATH" \
    TMPDIR="$CASE/tmp" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$MAIN_STATE" \
    FM_DATA_OVERRIDE="$MAIN_DATA" \
    FM_CONFIG_OVERRIDE="$MAIN_CONFIG" \
    FM_PROJECTS_OVERRIDE="$MAIN_PROJECTS" \
    FM_BACKEND=tmux \
    FM_TEST_TMUX_LOG="$TMUX_LOG" \
    FM_TEST_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_TEST_WINDOW_FLAG="$WINDOW_FLAG" \
    FM_TEST_RETIRED_FLAG="$RETIRED_FLAG" \
    FM_TEST_WINDOW_NAME="$WINDOW_NAME" \
    FM_TEST_AGENT_PID="$AGENT_PID" \
    FM_TEST_OMP_BIN="$TEST_OMP_BIN" \
    FM_TEST_OMP_BUN="$TEST_OMP_BUN" \
    FM_TEST_HOME="$HOME_DIR" \
    FM_TEST_TREEHOUSE_LOG="$CASE/treehouse.log" \
    FM_TEST_STATE_MODE="${FM_TEST_STATE_MODE:-}" \
    FM_TEST_SKIP_ACK="${FM_TEST_SKIP_ACK:-0}" \
    FM_OMP_SECONDMATE_ACK_POLLS=3 \
    FM_OMP_LAUNCH_ACK_INTERVAL=0.01 \
    "${env_args[@]}" \
    "$ROOT/bin/fm-spawn.sh" "$TASK_ID" "$HOME_DIR" --secondmate "${spawn_args[@]}"
}

run_spawn_herdr() { # [extra env NAME=VALUE ...]
  env \
    PATH="$FAKEBIN:$BASE_PATH" \
    TMPDIR="$CASE/tmp" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$MAIN_STATE" \
    FM_DATA_OVERRIDE="$MAIN_DATA" \
    FM_CONFIG_OVERRIDE="$MAIN_CONFIG" \
    FM_PROJECTS_OVERRIDE="$MAIN_PROJECTS" \
    FM_BACKEND=herdr \
    HERDR_SESSION=fmtest \
    FM_TEST_HERDR_LOG="$HERDR_LOG" \
    FM_TEST_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_TEST_WINDOW_FLAG="$WINDOW_FLAG" \
    FM_TEST_RETIRED_FLAG="$RETIRED_FLAG" \
    FM_TEST_AGENT_PID="$AGENT_PID" \
    FM_TEST_OMP_BIN="$TEST_OMP_BIN" \
    FM_TEST_OMP_BUN="$TEST_OMP_BUN" \
    FM_TEST_HOME="$HOME_DIR" \
    FM_TEST_TASK_ID="$TASK_ID" \
    FM_TEST_TREEHOUSE_LOG="$CASE/treehouse.log" \
    FM_TEST_STATE_MODE="${FM_TEST_STATE_MODE:-}" \
    FM_TEST_SKIP_ACK="${FM_TEST_SKIP_ACK:-0}" \
    FM_OMP_SECONDMATE_ACK_POLLS=3 \
    FM_OMP_LAUNCH_ACK_INTERVAL=0.01 \
    "$@" \
    "$ROOT/bin/fm-spawn.sh" "$TASK_ID" "$HOME_DIR" --secondmate
}

count_new_windows() {
  # shellcheck disable=SC2126  # wc keeps a zero count readable when grep finds none
  grep '^new-window ' "$TMUX_LOG" 2>/dev/null | wc -l | tr -d '[:space:]'
}

write_meta() {
  cat > "$MAIN_STATE/$TASK_ID.meta" <<EOF_META
window=firstmate:$WINDOW_NAME
endpoint_task_id=$TASK_ID
worktree=$HOME_DIR
project=$HOME_DIR
harness=omp
model=test/model
effort=low
kind=secondmate
home=$HOME_DIR
omp_bin=$TEST_OMP_BIN
omp_bun=$TEST_OMP_BUN
backend=tmux
EOF_META
}

write_herdr_meta() {
  cat > "$MAIN_STATE/$TASK_ID.meta" <<EOF_META
window=fmtest:w1:p2
endpoint_task_id=$TASK_ID
worktree=$HOME_DIR
project=$HOME_DIR
harness=omp
model=test/model
effort=low
kind=secondmate
home=$HOME_DIR
omp_bin=$TEST_OMP_BIN
omp_bun=$TEST_OMP_BUN
backend=herdr
herdr_session=fmtest
herdr_workspace_id=w1
herdr_tab_id=w1:t2
herdr_pane_id=w1:p2
EOF_META
}

test_herdr_launch_exact_resume_recovery_and_abort() {
  local out selected before token_file launch
  setup_case herdr-launch

  out=$(run_spawn_herdr 2>&1) || fail "fresh OMP Herdr secondmate spawn failed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "PATH='$FAKEBIN':\${PATH:-} '$TEST_OMP_BIN' --session-dir '$HOME_DIR/state/omp-sessions'" \
    "OMP Herdr secondmate launch did not invoke its canonical executable with the isolated session directory"
  assert_not_contains "$launch" "'$TEST_OMP_BUN' '$TEST_OMP_BIN'" \
    "OMP Herdr secondmate launch routed the selected executable through Bun"
  assert_contains "$(cat "$MAIN_STATE/$TASK_ID.meta")" 'harness=omp' "OMP Herdr secondmate identity was not exact"
  assert_contains "$(cat "$MAIN_STATE/$TASK_ID.meta")" 'backend=herdr' "OMP Herdr secondmate backend was not recorded"
  assert_contains "$(cat "$MAIN_STATE/$TASK_ID.meta")" 'herdr_pane_id=w1:p2' "OMP Herdr secondmate exact pane was not recorded"
  selected="$HOME_DIR/state/omp-sessions/selected.jsonl"
  [ -f "$selected" ] || fail "OMP Herdr secondmate acknowledgement did not create its selected durable session"

  rm -f "$WINDOW_FLAG" "$HOME_DIR/state/.omp-primary-extension-loaded" "$HOME_DIR/state/.lock"
  : > "$LAUNCH_LOG"
  out=$(FM_TEST_STATE_MODE=missing run_spawn_herdr 2>&1) || fail "OMP Herdr secondmate exact resume failed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "--resume '$selected'" \
    "OMP Herdr secondmate recovery did not resume the pointer-bound exact session"

  setup_case herdr-broker-launch
  token_file="$CASE/omp-auth-broker.token"
  printf '%s' 'dummy_remote_agent_broker_token_789' > "$token_file"
  chmod 600 "$token_file"
  out=$(run_spawn_herdr \
    FM_OMP_AUTH_BROKER_URL=http://127.0.0.1:8765 \
    FM_OMP_AUTH_BROKER_TOKEN_FILE="$token_file" 2>&1) \
    || fail "OMP Herdr secondmate broker launch failed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "OMP_AUTH_BROKER_URL='http://127.0.0.1:8765'" \
    "OMP secondmate agent launch did not receive the pod-loopback broker URL"
  assert_contains "$launch" "OMP_AUTH_BROKER_TOKEN=\"\$(cat '$token_file')\"" \
    "OMP secondmate agent launch did not defer bearer expansion to the pane shell"
  assert_contains "$launch" "FM_OMP_AUTH_BROKER_TOKEN_FILE='$token_file'" \
    "OMP secondmate agent launch did not retain the safe token-file path for descendants"
  assert_not_contains "$launch" 'dummy_remote_agent_broker_token_789' \
    "OMP secondmate agent launch exposed broker bearer bytes in backend transport"

  setup_case herdr-live-refusal
  write_herdr_meta
  : > "$WINDOW_FLAG"
  before=$(grep -c '^tab create ' "$HERDR_LOG" 2>/dev/null || true)
  out=$(FM_TEST_STATE_MODE=alive run_spawn_herdr 2>&1) && fail "OMP Herdr secondmate accepted a live duplicate"
  assert_contains "$out" 'already has a live agent' "OMP Herdr live duplicate refusal was not actionable"
  [ "$(grep -c '^tab create ' "$HERDR_LOG" 2>/dev/null || true)" = "$before" ] \
    || fail "OMP Herdr live duplicate refusal created another endpoint: $(cat "$HERDR_LOG")"

  setup_case herdr-unreadable-refusal
  write_herdr_meta
  : > "$WINDOW_FLAG"
  out=$(FM_TEST_STATE_MODE=unreadable run_spawn_herdr 2>&1) && fail "OMP Herdr secondmate accepted an unreadable duplicate"
  assert_contains "$out" 'endpoint state is unreadable' "OMP Herdr unreadable duplicate refusal was not actionable"

  setup_case herdr-dead-recovery
  write_herdr_meta
  : > "$WINDOW_FLAG"
  out=$(FM_TEST_STATE_MODE=dead run_spawn_herdr 2>&1) || fail "dead OMP Herdr secondmate did not recover: $out"
  assert_contains "$(cat "$HERDR_LOG")" 'pane close w1:p2' "dead OMP Herdr endpoint was not retired"
  assert_contains "$(cat "$HERDR_LOG")" 'tab create' "dead OMP Herdr secondmate was not relaunched"

  setup_case herdr-abort
  printf 'preserve me\n' > "$HOME_DIR/state/sentinel"
  out=$(FM_TEST_SKIP_ACK=1 run_spawn_herdr 2>&1) && fail "OMP Herdr secondmate launch unexpectedly succeeded without acknowledgement"
  assert_contains "$out" 'preserving the persistent home' "OMP Herdr acknowledgement failure did not preserve its home contract"
  [ -f "$HOME_DIR/state/sentinel" ] || fail "OMP Herdr secondmate abort removed persistent home state"
  [ -f "$MAIN_STATE/$TASK_ID.meta" ] || fail "OMP Herdr secondmate abort removed recovery metadata"
  [ ! -f "$WINDOW_FLAG" ] || fail "OMP Herdr secondmate abort left its owned endpoint running"
  [ ! -s "$CASE/treehouse.log" ] || fail "OMP Herdr secondmate abort invoked treehouse against a persistent home"

  setup_case herdr-abort-refused-close
  printf 'preserve me\n' > "$HOME_DIR/state/sentinel"
  out=$(FM_TEST_SKIP_ACK=1 FM_TEST_REFUSE_CLOSE=1 run_spawn_herdr 2>&1) \
    && fail "OMP Herdr secondmate launch unexpectedly succeeded without acknowledgement"
  assert_contains "$out" 'could not confirm its owned endpoint stopped' \
    "OMP Herdr abort trusted a refused pane close as a stopped endpoint"
  [ -f "$WINDOW_FLAG" ] || fail "refused herdr close should have left the endpoint present"
  [ -f "$HOME_DIR/state/sentinel" ] || fail "OMP Herdr abort removed home state after an unconfirmed close"
  [ -f "$MAIN_STATE/$TASK_ID.meta" ] || fail "OMP Herdr abort removed recovery metadata after an unconfirmed close"
  [ ! -s "$CASE/treehouse.log" ] || fail "OMP Herdr abort invoked treehouse after an unconfirmed close"

  pass "OMP Herdr secondmate launch, exact resume, conservative recovery, and post-ack abort preserve the durable contract"
}

test_launch_and_exact_resume() {
  local out selected nested before after launch
  setup_case launch

  out=$(run_spawn -- --prewalk-into 'test/finish:xhigh' 2>&1) || fail "fresh OMP secondmate spawn failed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_OMP_SESSION_POINTER='$HOME_DIR/state/.omp-session'" "OMP launch did not bind the home-owned session pointer"
  assert_contains "$launch" "PATH='$FAKEBIN':\${PATH:-} '$TEST_OMP_BIN'" \
    "OMP launch did not invoke the capability-checked canonical executable"
  assert_not_contains "$launch" "'$TEST_OMP_BUN' '$TEST_OMP_BIN'" \
    "OMP launch routed the selected executable through Bun"
  assert_contains "$(cat "$LAUNCH_LOG")" "--session-dir '$HOME_DIR/state/omp-sessions' --auto-approve --max-time=3h --model 'test/model' --thinking 'low'" "OMP launch did not preserve exact pins and durable session directory"
  assert_contains "$(cat "$LAUNCH_LOG")" "-e '$HOME_DIR/.omp/extensions/fm-primary-omp.ts'" "OMP launch did not preserve its exact adapter"
  assert_not_contains "$(cat "$LAUNCH_LOG")" '__OMP' "OMP launch retained an unsubstituted template placeholder"
  assert_contains "$(cat "$MAIN_STATE/$TASK_ID.meta")" 'harness=omp' "OMP identity was not recorded exactly"
  assert_contains "$(cat "$MAIN_STATE/$TASK_ID.meta")" 'model=test/model' "OMP model pin was not recorded"
  assert_contains "$(cat "$MAIN_STATE/$TASK_ID.meta")" 'effort=low' "OMP thinking pin was not recorded"
  assert_contains "$(cat "$MAIN_STATE/$TASK_ID.meta")" 'prewalk_into=test/finish:xhigh' "OMP Prewalk target was not recorded"
  assert_contains "$(cat "$LAUNCH_LOG")" "--prewalk --prewalk-into='test/finish:xhigh'" \
    "OMP secondmate launch did not enable its exact native Prewalk target"
  [ -d "$HOME_DIR/state/omp-sessions" ] || fail "durable OMP session directory was not created in the secondmate home"

  selected="$HOME_DIR/state/omp-sessions/selected.jsonl"
  printf '{"other":1}\n' > "$HOME_DIR/state/omp-sessions/000-earlier.jsonl"
  printf '{"other":2}\n' > "$HOME_DIR/state/omp-sessions/zzz-later.jsonl"
  printf '%s\n' "$selected" > "$HOME_DIR/state/.omp-session"
  rm -f "$WINDOW_FLAG" "$HOME_DIR/state/.omp-primary-extension-loaded" "$HOME_DIR/state/.lock"
  : > "$LAUNCH_LOG"
  out=$(run_spawn 2>&1) || fail "OMP secondmate exact resume failed: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "--resume '$selected'" "OMP recovery did not resume the manifest-bound exact session"
  assert_contains "$(cat "$LAUNCH_LOG")" "--prewalk --prewalk-into='test/finish:xhigh'" \
    "OMP secondmate recovery did not restore its recorded native Prewalk target"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'zzz-later.jsonl' "OMP recovery selected a lexically last session instead of the exact pointer"

  rm -f "$WINDOW_FLAG" "$HOME_DIR/state/.omp-primary-extension-loaded" "$HOME_DIR/state/.lock"
  mkdir -p "$HOME_DIR/state/omp-sessions/nested"
  nested="$HOME_DIR/state/omp-sessions/nested/not-a-direct-session.jsonl"
  printf '{}\n' > "$nested"
  printf '%s\n' "$nested" > "$HOME_DIR/state/.omp-session"
  before=$(count_new_windows)
  out=$(run_spawn 2>&1) && fail "OMP secondmate accepted a nested session pointer"
  assert_contains "$out" 'must name a direct child' "nested OMP session refusal was not actionable"
  after=$(count_new_windows)
  [ "$before" = "$after" ] || fail "nested session refusal created another endpoint"

  rm -f "$HOME_DIR/state/.omp-session"
  out=$(run_spawn 2>&1) && fail "OMP secondmate accepted retained sessions without an exact pointer"
  assert_contains "$out" 'retained sessions but no exact session pointer' "unbound retained-session refusal was not actionable"

  pass "OMP secondmate launch and recovery use the isolated adapter and an exact home-owned session pointer"
}

test_duplicate_recovery_states() {
  local out before after mode expected version invalid_lock

  for row in 'live already has a live agent' 'ambiguous has an ambiguous agent process' 'unreadable endpoint state is unreadable'; do
    mode=${row%% *}
    expected=${row#* }
    setup_case "duplicate-$mode"
    write_meta
    : > "$WINDOW_FLAG"
    before=$(count_new_windows)
    out=$(FM_TEST_STATE_MODE="$mode" run_spawn 2>&1) && fail "OMP secondmate duplicate probe accepted $mode state"
    assert_contains "$out" "$expected" "OMP $mode duplicate refusal was not actionable"
    after=$(count_new_windows)
    [ "$before" = "$after" ] || fail "OMP $mode duplicate refusal created another endpoint"
  done

  setup_case duplicate-home-owner
  write_meta
  printf 'sha256:test\n%s\n' "$AGENT_PID" > "$HOME_DIR/state/.omp-primary-extension-loaded"
  printf '%s\n' "$AGENT_PID" > "$HOME_DIR/state/.lock"
  out=$(FM_TEST_STATE_MODE=missing run_spawn 2>&1) && fail "OMP secondmate ignored a live isolated-home session owner"
  assert_contains "$out" 'already has a live session-lock owner' "live isolated-home owner refusal was not actionable"
  [ "$(count_new_windows)" = 0 ] || fail "live isolated-home owner refusal created another endpoint"

  for invalid_lock in 0 00 01 1; do
    setup_case "duplicate-malformed-lock-$invalid_lock"
    write_meta
    printf '%s\n' "$invalid_lock" > "$HOME_DIR/state/.lock"
    out=$(FM_TEST_STATE_MODE=missing run_spawn 2>&1) && fail "OMP secondmate accepted reserved session-lock PID $invalid_lock"
    assert_contains "$out" 'malformed session-lock PID' "reserved session-lock PID $invalid_lock refusal was not actionable"
    [ "$(count_new_windows)" = 0 ] || fail "reserved session-lock PID $invalid_lock refusal created another endpoint"
  done

  setup_case duplicate-malformed-marker
  write_meta
  version=$(fm_primary_watch_version "$HOME_DIR/.omp/extensions/fm-primary-omp.ts" "$HOME_DIR")
  printf '%s\n99999999\nunterminated-third-line' "$version" > "$HOME_DIR/state/.omp-primary-extension-loaded"
  printf '99999999\n' > "$HOME_DIR/state/.lock"
  out=$(FM_TEST_STATE_MODE=missing run_spawn 2>&1) && fail "OMP secondmate retired an integration marker with trailing unterminated data"
  assert_contains "$out" 'unowned or malformed primary-integration marker' "trailing integration marker refusal was not actionable"
  [ "$(count_new_windows)" = 0 ] || fail "trailing integration marker refusal created another endpoint"

  setup_case duplicate-owned-stale-marker
  write_meta
  version=$(fm_primary_watch_version "$HOME_DIR/.omp/extensions/fm-primary-omp.ts" "$HOME_DIR")
  printf '%s\n99999999\n%s\n%s\n' "$version" "$TEST_OMP_BUN" "$TEST_OMP_BIN" > "$HOME_DIR/state/.omp-primary-extension-loaded"
  printf '99999999\n' > "$HOME_DIR/state/.lock"
  out=$(FM_TEST_STATE_MODE=missing run_spawn 2>&1) || fail "OMP secondmate did not recover from its proven stale integration marker: $out"
  assert_contains "$(cat "$TMUX_LOG")" 'new-window' "proven stale integration marker did not permit recovery"

  setup_case duplicate-dead
  write_meta
  : > "$WINDOW_FLAG"
  out=$(FM_TEST_STATE_MODE=dead run_spawn 2>&1) || fail "proven-dead OMP secondmate did not recover: $out"
  assert_contains "$(cat "$TMUX_LOG")" 'kill-window' "dead OMP secondmate endpoint was not retired"
  assert_contains "$(cat "$TMUX_LOG")" 'new-window' "dead OMP secondmate was not relaunched"

  pass "OMP secondmate recovery refuses live, ambiguous, and unreadable duplicates and relaunches only proven dead endpoints"
}

test_post_meta_abort_preserves_home() {
  local out
  setup_case abort
  printf 'preserve me\n' > "$HOME_DIR/state/sentinel"
  out=$(FM_TEST_SKIP_ACK=1 run_spawn 2>&1) && fail "OMP secondmate launch unexpectedly succeeded without integration acknowledgement"
  assert_contains "$out" 'preserving the persistent home' "OMP secondmate acknowledgement failure did not name its preservation contract"
  [ -f "$HOME_DIR/state/sentinel" ] || fail "OMP secondmate abort removed persistent home state"
  [ -d "$HOME_DIR/.git" ] || fail "OMP secondmate abort removed the persistent home"
  [ -f "$MAIN_STATE/$TASK_ID.meta" ] || fail "OMP secondmate abort removed recovery metadata"
  [ ! -f "$WINDOW_FLAG" ] || fail "OMP secondmate abort left its proven-owned endpoint running"
  [ ! -s "$CASE/treehouse.log" ] || fail "OMP secondmate abort invoked treehouse against a persistent home"

  pass "post-metadata OMP acknowledgement failure stops only the owned endpoint and preserves home, metadata, and sessions"
}

test_stale_omp_runtime_cleanup() {
  local version out stale_session
  setup_case stale-runtime-cleanup
  version=$(fm_primary_watch_version "$HOME_DIR/.omp/extensions/fm-primary-omp.ts" "$HOME_DIR")
  stale_session="$HOME_DIR/state/omp-sessions/old.jsonl"
  mkdir -p "$HOME_DIR/state/omp-sessions"
  printf '{"stale":true}\n' > "$stale_session"
  printf '%s\n' "$stale_session" > "$HOME_DIR/state/.omp-session"
  printf '%s\n%s\n%s\n%s\n' "$version" 99999999 "$TEST_OMP_BUN" "$TEST_OMP_BIN" \
    > "$HOME_DIR/state/.omp-primary-extension-loaded"
  printf '99999999\n' > "$HOME_DIR/state/.lock"
  out=$(bash -c '. "$1/bin/fm-omp-process-lib.sh"; fm_omp_clear_stale_runtime_markers "$2"' _ "$ROOT" "$HOME_DIR" 2>&1) \
    || fail "stale OMP runtime cleanup refused a dead prior occupant: $out"
  assert_absent "$HOME_DIR/state/.omp-session" "stale OMP session pointer was not cleared"
  assert_absent "$HOME_DIR/state/.omp-primary-extension-loaded" "stale OMP primary marker was not cleared"
  assert_absent "$stale_session" "stale OMP session file was not cleared"

  setup_case live-runtime-preserve
  version=$(fm_primary_watch_version "$HOME_DIR/.omp/extensions/fm-primary-omp.ts" "$HOME_DIR")
  printf '%s\n%s\n%s\n%s\n' "$version" "$AGENT_PID" "$TEST_OMP_BUN" "$TEST_OMP_BIN" \
    > "$HOME_DIR/state/.omp-primary-extension-loaded"
  printf '%s\n' "$AGENT_PID" > "$HOME_DIR/state/.lock"
  out=$(bash -c '. "$1/bin/fm-omp-process-lib.sh"; fm_omp_clear_stale_runtime_markers "$2"' _ "$ROOT" "$HOME_DIR" 2>&1) \
    && fail "OMP runtime cleanup removed markers owned by a live prior occupant"
  assert_contains "$out" 'still live' "live OMP runtime cleanup refusal was not actionable"
  assert_present "$HOME_DIR/state/.omp-primary-extension-loaded" "live OMP primary marker was removed"
  assert_present "$HOME_DIR/state/.lock" "live OMP session lock was removed"
  pass "OMP runtime cleanup clears dead occupants and preserves live occupants"
}

test_stale_omp_runtime_cleanup
test_herdr_launch_exact_resume_recovery_and_abort
test_launch_and_exact_resume
test_duplicate_recovery_states
test_post_meta_abort_preserves_home
