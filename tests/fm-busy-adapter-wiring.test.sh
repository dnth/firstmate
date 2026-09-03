#!/usr/bin/env bash
# Behavior tests for the per-adapter semantic busy-state wiring that
# bin/fm-spawn.sh installs under the contract owned by bin/fm-busy-lib.sh.
#
# These tests run the REAL fm-spawn against a fake tmux pane and an isolated
# git worktree, then drive the generated adapter artifact (the Pi extension,
# the OpenCode plugin) in a plain Node host, so the artifact, the real
# bin/fm-busy-event.sh writer, and the real classifier are exercised together
# with no live harness session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-busy-adapter-wiring)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        [ -z "${FM_FAKE_LITERAL_LOG:-}" ] || printf '%s\n' "$arg" >> "$FM_FAKE_LITERAL_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi opencode claude codex
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  # Every case here is a ship spawn, which carries an explicit delivery contract
  # (AGENTS.md section 7); these tests are about busy-state wiring, so they pass a
  # fixed valid one.
  local home=$1 wt=$2 fakebin=$3
  shift 3
  set -- "$@" --mode no-mistakes --yolo off
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LITERAL_LOG="$home/tmux-literals.log" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

classify() {  # <harness> <id> <state-dir>
  fm_busy_classify tmux fake:w "$1" "$2" "$3"
}

# The publisher records which incarnation fired and makes NO live/stale decision -
# that gate moved to the consumer (fm-wake-lib.sh, exercised in fm-wake-queue.test.sh).
# It writes a PER-GENERATION marker state/<id>.turn-ended.<spawn_gen>, unconditionally
# and lock-free. Because each incarnation writes its OWN gen file, a delayed older
# incarnation can never clobber a newer one - the overwrite the single shared marker
# allowed. No meta is needed to publish.
test_turnend_signal_writes_per_generation_marker() {
  local state="$TMP_ROOT/turnend-signal" id=turnend-x1
  mkdir -p "$state"

  "$ROOT/bin/fm-turnend-signal.sh" "$state" "$id" spawn-one
  assert_present "$state/$id.turn-ended.spawn-one" "the publisher did not write the per-generation marker"

  # A newer incarnation, then a DELAYED older one: separate files, no clobber.
  "$ROOT/bin/fm-turnend-signal.sh" "$state" "$id" spawn-two
  "$ROOT/bin/fm-turnend-signal.sh" "$state" "$id" spawn-one
  assert_present "$state/$id.turn-ended.spawn-two" "the newer incarnation's marker was lost"
  assert_present "$state/$id.turn-ended.spawn-one" "an older incarnation clobbered a newer one - markers are not per-generation"

  # No shared single marker and no temp file is created.
  assert_absent "$state/$id.turn-ended" "the publisher wrote a shared single marker"
  pass "turn-end publisher writes a per-generation marker, so incarnations never clobber each other"
}

# Start a live process that holds the exact meta lock the signal must never take,
# so a test can prove the signal ignores it. Sets FM_TEST_LOCK_HOLDER (pid) and
# FM_TEST_LOCK_STATE. The holder self-releases after a bounded wait, so a failed
# assertion can never orphan it.
hold_meta_lock() {  # <state-dir> <meta-file>
  local state=$1 meta=$2 n=0
  rm -f "$state/.holder-ready" "$state/.holder-release"
  (
    FM_STATE_OVERRIDE="$state"
    export FM_STATE_OVERRIDE
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    lock=$(fm_meta_lock_path "$meta") || exit 1
    fm_lock_acquire_wait "$lock"
    : > "$state/.holder-ready"
    hn=0
    while [ ! -e "$state/.holder-release" ] && [ "$hn" -lt 200 ]; do sleep 0.05; hn=$((hn + 1)); done
    fm_lock_release "$lock"
  ) &
  FM_TEST_LOCK_HOLDER=$!
  FM_TEST_LOCK_STATE=$state
  while [ ! -e "$state/.holder-ready" ] && [ "$n" -lt 200 ]; do sleep 0.05; n=$((n + 1)); done
  [ -e "$state/.holder-ready" ] \
    || { kill "$FM_TEST_LOCK_HOLDER" 2>/dev/null; fail "the meta-lock holder never acquired the lock"; }
}

release_meta_lock() {
  : > "$FM_TEST_LOCK_STATE/.holder-release"
  wait "$FM_TEST_LOCK_HOLDER" 2>/dev/null
}

# A turn-end publish now creates a per-generation marker state/<id>.turn-ended.<gen>.
# The extension drivers do not know the spawn's gen, so these helpers match any gen.
turnend_published() {  # <state> <id>
  local g
  for g in "$1/$2".turn-ended.*; do
    [ -e "$g" ] && return 0
  done
  return 1
}
assert_turnend_published() {  # <state> <id> <msg>
  turnend_published "$1" "$2" || fail "$3"
}
clear_turnend() {  # <state> <id>  (guard-safe removal of every gen marker)
  local g
  for g in "$1/$2".turn-ended.*; do
    [ -e "$g" ] && rm -f -- "$g"
  done
}

# Regression: the publish is lock-free and never drops. fm-spawn holds the task
# metadata lock through launch, so a live worker's turn-end that fires while that
# lock is held must publish immediately - never blocking on the lock, never
# dropping the wake. `timeout` bounds the call so a regressed blocking path is
# caught as exit 124 rather than hanging the suite.
test_turnend_signal_is_lock_free_under_spawn_contention() {
  local state id marker meta rc
  state="$TMP_ROOT/turnend-signal-spawnrace" id=turnend-race1
  marker="$state/$id.turn-ended.race-gen" meta="$state/$id.meta"
  mkdir -p "$state"
  printf 'endpoint_task_id=%s\nspawn_gen=race-gen\n' "$id" > "$meta"

  hold_meta_lock "$state" "$meta"
  timeout 5 "$ROOT/bin/fm-turnend-signal.sh" "$state" "$id" race-gen
  rc=$?
  release_meta_lock

  [ "$rc" -ne 124 ] || fail "the signal blocked on the spawn-held meta lock (not lock-free)"
  assert_present "$marker" "a live completion was dropped while fm-spawn held the meta lock"
  pass "turn-end signal publishes lock-free under spawn-lock contention (never blocks, never drops)"
}

# Regression: turn-end must never deadlock teardown. fm-teardown holds the same
# metadata lock while it stops the harness, so a synchronous Stop/turn-end hook
# that blocked on that lock would wedge teardown waiting for harness shutdown.
# The lock-free signal returns promptly even while the lock is held.
test_turnend_signal_never_deadlocks_teardown() {
  local state id meta rc
  state="$TMP_ROOT/turnend-signal-teardown" id=turnend-td1
  meta="$state/$id.meta"
  mkdir -p "$state"
  printf 'endpoint_task_id=%s\nspawn_gen=td-gen\n' "$id" > "$meta"

  hold_meta_lock "$state" "$meta"
  timeout 5 "$ROOT/bin/fm-turnend-signal.sh" "$state" "$id" td-gen
  rc=$?
  release_meta_lock

  [ "$rc" -ne 124 ] || fail "the signal blocked on the teardown-held meta lock (deadlock)"
  pass "turn-end signal never blocks on the metadata lock, so it cannot deadlock teardown"
}

# drive_pi_ext <ext-path> <mode>: load the generated Pi extension in a plain
# Node host and fire one lifecycle handler. Modes: agent-start, settle-idle,
# settle-continuing, turn-end.
drive_pi_ext() {
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
const ctx = { isIdle: () => process.env.MODE !== "settle-continuing" };
switch (process.env.MODE) {
  case "agent-start": await handlers["agent_start"]({}, ctx); break;
  case "settle-idle": await handlers["agent_settled"]({}, ctx); break;
  case "settle-continuing": await handlers["agent_settled"]({}, ctx); break;
  case "settle-then-start":
    await handlers["agent_settled"]({}, ctx);
    await handlers["agent_start"]({}, ctx);
    break;
  case "turn-end": await handlers["turn_end"]({}, ctx); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (process.env.MODE === "turn-end") {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

test_pi_extension_semantic_lifecycle() {
  local rec id=busy-pi-1 out state ext
  rec=$(make_spawn_case pi-lifecycle pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"

  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  clear_turnend "$state" "$id"
  out=$(drive_pi_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  assert_turnend_published "$state" "$id" "turn_end no longer touches the notification marker"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "agent_settled drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "agent_settled with isIdle must classify 'idle pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "agent_start must classify 'busy pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" settle-continuing) || fail "continuing settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a settle while another run continues must stay busy, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "final settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "the final settle must classify idle, got '$out'"

  clear_turnend "$state" "$id"; rm -f -- "$state/$id.meta"
  out=$(drive_pi_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  assert_turnend_published "$state" "$id" "the Pi extension must publish a stamped marker unconditionally; incarnation gating is the consumer's job"
  pass "pi extension reports agent_start busy, settles idle only via ctx.isIdle(), and keeps turn_end a notification"
}

test_pi_extension_serializes_settle_before_next_start() {
  local rec id=busy-pi-order out state ext
  rec=$(make_spawn_case pi-order pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"

  out=$(drive_pi_ext "$ext" settle-then-start) || fail "settle/start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a fresh agent_start after agent_settled must win, got '$out'"
  pass "pi extension awaits agent_settled before the next agent_start without a test delay"
}

test_pi_extension_stale_incarnation_rejected() {
  local rec id=busy-pi-2 out state ext
  rec=$(make_spawn_case pi-stale pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  # A re-arm (a rewired incarnation) supersedes the gen embedded in the old
  # extension file: its late events must be rejected and never change state.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  out=$(drive_pi_ext "$ext" settle-idle) || fail "stale settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale extension event must not change state, got '$out'"
  pass "pi extension events from a superseded incarnation are rejected as stale"
}

# drive_oc_plugin <plugin-path> <events-json-lines...>: load the generated
# OpenCode plugin in a plain Node host and feed it one event per argument, in
# order, through the same hooks.event entry OpenCode calls.
drive_oc_plugin() {
  local plugin=$1
  shift
  PLUGIN_PATH="$plugin" node --input-type=module - "$@" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const hooks = await mod.FmBusyState({});
for (const arg of process.argv.slice(2)) {
  await hooks.event({ event: JSON.parse(arg) });
}
EOF
}

oc_status() {  # <sessionID> <type>
  printf '{"type":"session.status","properties":{"sessionID":"%s","status":{"type":"%s"}}}' "$1" "$2"
}

oc_idle() {  # <sessionID>
  printf '{"type":"session.idle","properties":{"sessionID":"%s"}}' "$1"
}

test_opencode_plugin_semantic_lifecycle() {
  local rec id=busy-oc-1 out state plugin
  rec=$(make_spawn_case oc-lifecycle opencode "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "opencode spawn should succeed: $out"
  state="$HOME_DIR/state"
  plugin="$WT_DIR/.opencode/plugins/fm-busy-state.js"
  assert_present "$plugin" "opencode spawn did not write the busy-state plugin"

  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  out=$(drive_oc_plugin "$plugin" "$(oc_status ses_main busy)") || fail "busy drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "session busy must classify 'busy opencode-plugin', got '$out'"

  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_status ses_child busy)" \
    "$(oc_status ses_child idle)") || fail "child-session drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "a child session's idle must not clear the worker, got '$out'"

  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main retry)" \
    "$(oc_status ses_main idle)") || fail "retry/idle drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "the latched session's idle must classify idle, got '$out'"

  clear_turnend "$state" "$id"
  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_idle ses_main)") || fail "session.idle drive failed: $out"
  assert_turnend_published "$state" "$id" "session.idle no longer touches the notification marker"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "session.idle for the latched session must classify idle, got '$out'"

  clear_turnend "$state" "$id"
  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses2 busy)" \
    "$(oc_idle ses_other)") || fail "other-session idle drive failed: $out"
  assert_turnend_published "$state" "$id" "the marker touch must stay a notification for every session.idle"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "another session's idle must not clear the latched busy, got '$out'"

  clear_turnend "$state" "$id"; rm -f -- "$state/$id.meta"
  out=$(drive_oc_plugin "$plugin" "$(oc_idle ses2)") || fail "session.idle drive failed: $out"
  assert_turnend_published "$state" "$id" "the OpenCode plugin must publish a stamped marker unconditionally; incarnation gating is the consumer's job"
  pass "opencode plugin classifies from session.status, scoped to the latched worker session"
}

run_claude_hook() {  # <settings.json> <hook-event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  sh -c "$cmd"
}

test_claude_hooks_semantic_lifecycle() {
  local rec id=busy-cl-1 out state settings
  rec=$(make_spawn_case claude-lifecycle claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "claude spawn did not write hook settings"
  jq -e . "$settings" >/dev/null || fail "claude hook settings are not valid JSON"
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "claude hook settings lack $ev"
  done

  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  clear_turnend "$state" "$id"
  run_claude_hook "$settings" Stop || fail "Stop hook command failed"
  assert_turnend_published "$state" "$id" "Stop no longer touches the notification marker"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "Stop must classify 'idle claude-hook', got '$out'"

  run_claude_hook "$settings" UserPromptSubmit || fail "UserPromptSubmit hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy claude-hook" ] || fail "UserPromptSubmit must classify 'busy claude-hook', got '$out'"

  run_claude_hook "$settings" StopFailure || fail "StopFailure hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "StopFailure must classify idle so an API error cannot strand busy, got '$out'"

  run_claude_hook "$settings" UserPromptSubmit
  run_claude_hook "$settings" SessionEnd || fail "SessionEnd hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "SessionEnd must classify idle, got '$out'"
  pass "claude hooks open on UserPromptSubmit and close on Stop, StopFailure, and SessionEnd"
}

test_claude_hooks_stale_incarnation_harmless() {
  local rec id=busy-cl-2 out state settings meta tmp
  rec=$(make_spawn_case claude-stale claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  meta="$state/$id.meta"
  tmp="$meta.tmp"
  awk '{ if ($0 ~ /^spawn_gen=/) print "spawn_gen=replacement"; else print }' "$meta" > "$tmp"
  mv -f "$tmp" "$meta"
  clear_turnend "$state" "$id"
  run_claude_hook "$settings" Stop \
    || fail "a stale-incarnation Stop hook must still exit 0 so Claude can stop"
  assert_turnend_published "$state" "$id" "the Stop hook must publish a stamped marker unconditionally; the superseded incarnation is discarded by the consumer, not the hook"
  run_claude_hook "$settings" UserPromptSubmit \
    || fail "a stale-gen hook must still exit 0 so Claude's lifecycle is never broken"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale-gen hook event must not change state, got '$out'"
  pass "claude hook events from a superseded incarnation are rejected without breaking the hook"
}

test_codex_unverified_until_a_semantic_source_exists() {
  local rec id=busy-cx-1 out state launch notify_cmd
  rec=$(make_spawn_case codex-unverified codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "codex spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_absent "$state/$id.busy-gen" "codex must not arm a busy contract with no verified semantic source"
  assert_absent "$WT_DIR/.codex/hooks.json" "codex must not install unverified busy hooks"
  assert_contains "$out" 'spawned '"$id"' harness=codex' "codex spawn did not complete normally"
  out=$(classify codex "$id" "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex must classify 'unknown codex-unverified', got '$out'"
  out=$(fm_busy_classify tmux fake:w codex "$id" "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "unknown codex-unverified" ] || fail "codex must not fall back to footer text, got '$out'"

  # Run the real turn-end notification the codex launch installs (the -c notify=[...]
  # command) and assert its observable effect: a published marker. Executing it - not
  # matching its text - is the behavioral check; an empty extraction publishes nothing
  # and fails the assertion below.
  launch=$(tail -1 "$HOME_DIR/tmux-literals.log")
  notify_cmd=$(printf '%s\n' "$launch" \
    | sed -n 's/.*notify=\[\\"bash\\",\\"-c\\",\\"\(.*\)\\"\].*/\1/p')
  clear_turnend "$state" "$id"
  sh -c "$notify_cmd"
  assert_turnend_published "$state" "$id" "the codex launch's turn-end notification did not publish for its live spawn"

  clear_turnend "$state" "$id"; rm -f -- "$state/$id.meta"
  sh -c "$notify_cmd"
  assert_turnend_published "$state" "$id" "the Codex notification must publish a stamped marker unconditionally; incarnation gating is the consumer's job"
  pass "codex classifies unknown until a semantic source is verified, never idle or footer-matched"
}

test_kimi_and_grok_install_no_unverified_wiring() {
  local state out
  state="$TMP_ROOT/gates/state"
  mkdir -p "$state"
  [ -z "$(fm_busy_sources_for_harness kimi)" ] \
    || fail "standalone kimi must trust no semantic source until it is verified"
  [ -z "$(fm_busy_sources_for_harness grok)" ] \
    || fail "grok must trust no semantic source while its structured path is unverified"
  out=$(fm_busy_classify tmux fake:w kimi gate-k "$state" '🌒 · thinking')
  [ "$out" = "unknown kimi-unverified" ] || fail "kimi must classify unknown, not from its spinner, got '$out'"
  out=$(fm_busy_classify tmux fake:w grok gate-g "$state" 'Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail "grok must classify through its isolated fallback, got '$out'"
  pass "kimi and grok install no unverified semantic wiring and classify through their own gates"
}

test_turnend_signal_writes_per_generation_marker
test_turnend_signal_is_lock_free_under_spawn_contention
test_turnend_signal_never_deadlocks_teardown
test_pi_extension_semantic_lifecycle
test_pi_extension_serializes_settle_before_next_start
test_pi_extension_stale_incarnation_rejected
test_kimi_and_grok_install_no_unverified_wiring
test_opencode_plugin_semantic_lifecycle
test_claude_hooks_semantic_lifecycle
test_claude_hooks_stale_incarnation_harmless
test_codex_unverified_until_a_semantic_source_exists

echo "all fm-busy-adapter-wiring tests passed"
