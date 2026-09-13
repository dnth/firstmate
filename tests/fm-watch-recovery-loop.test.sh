#!/usr/bin/env bash
# Pin the Pi/OpenCode recovery-loop fix: one announcement per generation, and a
# handling successor that keeps supervising instead of going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  # This fork's Pi adapter is a thin binding over the shared lifecycle core, and
  # the core admits only runtimes named in the tracked allowlist, so a fixture
  # repo needs both files to load the adapter at all.
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$repo/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$repo/bin/fm-pi-compatible-runtimes"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.
test_unacknowledged_recovery_is_announced_once_per_generation() {
  local repo home plugin fakebin out status lock_pid messages
  repo="$TMP_ROOT/t1-root"
  home="$TMP_ROOT/t1-home"
  fakebin="$TMP_ROOT/t1-fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  exit 1
fi
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$fakebin:\$PATH"
exec "$ROOT/bin/fm-watch-arm.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/seed.meta"
  printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: seed recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  out=$(
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(String(message));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
await tool.execute("tool-call-t1", {}, undefined, undefined, {});
const deadline = Date.now() + 75000;
let firstAt = 0;
while (Date.now() < deadline) {
  const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
  if (rearm.length > 1) {
    throw new Error(`unbounded recovery loop: ${rearm.length} rearm-resurface follow-ups`);
  }
  if (rearm.length === 1 && firstAt === 0) firstAt = Date.now();
  if (firstAt && Date.now() - firstAt >= 55000) break;
  await new Promise((resolve) => setTimeout(resolve, 200));
}
const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
if (rearm.length !== 1) {
  throw new Error(`expected exactly one recovery follow-up, got ${rearm.length}: ${prompts.join(" || ")}`);
}
const lockPid = existsSync(`${process.env.FM_HOME}/state/.watch.lock/pid`)
  ? readFileSync(`${process.env.FM_HOME}/state/.watch.lock/pid`, "utf8").trim()
  : "";
if (!/^[0-9]+$/.test(lockPid)) throw new Error("successor watcher lock pid missing");
try {
  process.kill(Number(lockPid), 0);
} catch {
  throw new Error(`successor watcher ${lockPid} is not alive`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "utf8").trim();
if (!marker.startsWith("announced:") && !marker.startsWith("pending:")) {
  throw new Error(`successor did not keep a live recovery episode: ${marker}`);
}
console.log(`T1_MESSAGES=${rearm.length}`);
console.log(`T1_LOCK_PID=${lockPid}`);
console.log(`T1_MARKER=${marker}`);
process.exit(0);
EOF
  )
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '%s\n' "$out"
  fi
  lock_pid=$(sed -n 's/^T1_LOCK_PID=//p' <<<"$out" | tail -1)
  messages=$(sed -n 's/^T1_MESSAGES=//p' <<<"$out" | tail -1)
  if [ -n "$lock_pid" ]; then
    kill -TERM "$lock_pid" 2>/dev/null || true
  fi
  expect_code 0 "$status" "an unacknowledged recovery must be announced at most once per generation: $out"
  [ "$messages" = 1 ] || fail "T1 did not report a single recovery follow-up: $out"
  pass "unacknowledged recovery is announced at most once per generation and the successor stays alive"
}

# T2: a handling successor must enter its poll loop immediately and surface a
# real crew event instead of sitting in a pre-loop wait that refreshes the
# liveness beacon and then exits with a synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 5 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within a poll interval or two (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

# --- bounded resurface ------------------------------------------------------
#
# Shared fixture for the bounded-resurface tests: one recorded window on an
# idle pane plus an unhandled steering-inbox record already at the re-ring
# bound, so the FIRST pane-loop pass escalates it through inbox_steer_check and
# exits on its stale wake. A generation that still exits on
# `wake "check: rearm-resurface"` never reaches that pass, which makes the
# .escalated marker an exact pane-loop-ran signal.
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%i:%z:%Fm' "$1" 2>/dev/null; else stat -c '%i:%s:%.9Y' "$1" 2>/dev/null; fi
}

make_resurface_case() {  # <name> -> dir with state/, fakebin/, home/, capture
  local name=$1 dir state key sig
  dir=$(make_case "$name")
  state="$dir/state"
  mkdir -p "$dir/home/data" "$state/resurface.inbox"
  printf 'idle crew pane\n' > "$dir/capture"
  printf 'window=test:fm-resurface\nkind=ship\n' > "$state/resurface.meta"
  printf 'working: mid-task\n' > "$state/resurface.status"
  sig=$(seen_sig "$state/resurface.status")
  printf '%s' "$sig" > "$state/.seen-resurface_status"
  key=$(printf '%s' 'test:fm-resurface' | tr ':/.' '___')
  printf '%s' "$(hash_text 'idle crew pane')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf 'steer: pick up the resurface fix\n' > "$state/resurface.inbox/001.msg"
  printf '001.msg\t3\t1\n' > "$state/resurface.inbox/.ring-state"
  printf 'announced:downtime:seed.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  printf '%s\n' "$dir"
}

run_resurface_watch() {  # <dir> <out> [env...] - run one watcher generation
  local dir=$1 out=$2
  shift 2
  env \
    PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_TMUX_WINDOW='test:fm-resurface' \
    FM_FAKE_TMUX_CAPTURE="$dir/capture" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' \
    FM_TASK_INBOX_GRACE_SECS=0 \
    "$@" \
    "$WATCH" > "$out" 2>&1
}

# T3: with .watcher-down=announced:* and no ack, the first
# FM_WATCH_RESURFACE_MAX_ANNOUNCEMENTS-1 generations still deliver
# `check: rearm-resurface` and exit before the pane loop; the bound generation
# surfaces the resurface once through the durable queue with the guard-level
# diagnostic and RESUMES supervision - proven by the seeded inbox record
# escalating through inbox_steer_check. The announcement stays ackable: a real
# drain + generation-bound ack retires the marker and the streak sidecar, and
# the next generation supervises normally.
test_resurface_bound_resumes_supervision() {
  local dir state key out1 out2 out3 out4 err pid i marker
  dir=$(make_resurface_case resurface-bound); state="$dir/state"
  key=$(printf '%s' 'test:fm-resurface' | tr ':/.' '___')
  out1="$dir/watch1.out"; out2="$dir/watch2.out"; out3="$dir/watch3.out"
  out4="$dir/watch4.out"; err="$dir/drain.err"

  run_resurface_watch "$dir" "$out1" FM_WATCH_RESURFACE_MAX_ANNOUNCEMENTS=3
  assert_grep 'check: rearm-resurface' "$out1" \
    "generation 1 did not deliver the resurface wake: $(cat "$out1")"
  assert_grep 'announced:downtime:' "$state/.watcher-down" \
    "generation 1 did not leave an announced marker"
  assert_grep "$(printf '1\t')" "$state/.watcher-down.resurface" \
    "generation 1 did not record its announcement in the streak sidecar"
  assert_absent "$state/resurface.inbox/.escalated" \
    "generation 1 reached the pane loop before the bound"

  run_resurface_watch "$dir" "$out2" FM_WATCH_RESURFACE_MAX_ANNOUNCEMENTS=3
  assert_grep 'check: rearm-resurface' "$out2" \
    "generation 2 did not deliver the resurface wake: $(cat "$out2")"
  assert_grep "$(printf '2\t')" "$state/.watcher-down.resurface" \
    "generation 2 did not extend the unacknowledged streak"
  assert_absent "$state/resurface.inbox/.escalated" \
    "generation 2 reached the pane loop before the bound"

  run_resurface_watch "$dir" "$out3" FM_WATCH_RESURFACE_MAX_ANNOUNCEMENTS=3
  assert_no_grep 'check: rearm-resurface' "$out3" \
    "bound generation still exited on the resurface wake: $(cat "$out3")"
  assert_grep 'unread firstmate instruction' "$out3" \
    "bound generation never ran inbox_steer_check: $(cat "$out3")"
  assert_grep '001.msg' "$state/resurface.inbox/.escalated" \
    "bound generation's pane loop did not escalate the unhandled inbox record"
  assert_grep 'daemon scan stale + watcher in resurface loop' "$state/.watch-triage.log" \
    "bound trip did not record the guard-level diagnostic"
  assert_grep 'daemon scan stale + watcher in resurface loop' "$state/.wake-queue" \
    "bound trip did not enqueue a durable resurface record"
  assert_grep 'announced:downtime:' "$state/.watcher-down" \
    "bound trip lost the announced marker"
  assert_grep "$(printf '3\t')" "$state/.watcher-down.resurface" \
    "bound generation did not extend the streak"

  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$err"
  ack_drain_err "$state" "$err" \
    || fail "wake drain did not acknowledge the announced downtime: $(cat "$err")"
  # The drain's begin-handling step turns the announced downtime generation into
  # a handling episode, so the generation-bound ack lands as acked:handling.
  assert_grep 'acked:handling:' "$state/.watcher-down" \
    "the generation-bound ack did not retire the downtime marker"
  assert_absent "$state/.watcher-down.resurface" \
    "the ack left the resurface streak sidecar behind"

  env \
    PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_TMUX_WINDOW='test:fm-resurface' \
    FM_FAKE_TMUX_CAPTURE="$dir/capture" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' \
    FM_TASK_INBOX_GRACE_SECS=0 \
    "$WATCH" > "$out4" 2>&1 &
  pid=$!
  i=0
  while [ ! -f "$state/.stale-$key" ] && [ "$i" -lt 40 ]; do
    sleep 0.25
    i=$((i + 1))
  done
  assert_present "$state/.stale-$key" \
    "post-ack generation never ran stale classification: $(cat "$out4")"
  is_live_non_zombie "$pid" \
    || fail "post-ack generation exited instead of supervising: $(cat "$out4")"
  assert_no_grep 'check: rearm-resurface' "$out4" \
    "post-ack generation replayed the resurface wake: $(cat "$out4")"
  stop_pid "$pid"
  pass "an unacknowledged downtime resurface is bounded: supervision resumes, the diagnostic is recorded, and the ack still clears the marker"
}

# T4: the elapsed-time bound trips even when the announcement count is below
# its configured maximum, by re-evaluating the persisted streak.
test_resurface_time_bound_resumes_supervision() {
  local dir state out
  dir=$(make_resurface_case resurface-time-bound); state="$dir/state"
  printf '2\t%s\n' "$(( $(date +%s) - 1000 ))" > "$state/.watcher-down.resurface"
  chmod 600 "$state/.watcher-down.resurface"
  out="$dir/watch.out"
  run_resurface_watch "$dir" "$out" \
    FM_WATCH_RESURFACE_MAX_ANNOUNCEMENTS=50 FM_WATCH_RESURFACE_MAX_SECS=60
  assert_no_grep 'check: rearm-resurface' "$out" \
    "time-bound generation still exited on the resurface wake: $(cat "$out")"
  assert_grep 'unread firstmate instruction' "$out" \
    "time-bound generation never ran inbox_steer_check: $(cat "$out")"
  assert_grep 'daemon scan stale + watcher in resurface loop' "$state/.watch-triage.log" \
    "time-bound trip did not record the guard-level diagnostic"
  assert_grep 'announced:downtime:' "$state/.watcher-down" \
    "time-bound trip lost the announced marker"
  pass "the elapsed-time resurface bound resumes supervision below the announcement bound"
}

# T5: the arm check counts one announcement per pending->announced transition,
# holds an already-announced marker at wait without double-counting, trips the
# count bound, keeps the bound visible on the wait path, and a generation-bound
# ack retires the streak so a fresh episode counts from zero.
resurface_arm_check() {  # <state> <max-announcements> <max-secs> -> "<action> <count> <bound>"
  local state=$1
  # shellcheck disable=SC2016 # The arm-check outputs expand inside the check shell.
  env \
    FM_STATE_OVERRIDE="$state" \
    FM_WATCH_RESURFACE_MAX_ANNOUNCEMENTS="$2" \
    FM_WATCH_RESURFACE_MAX_SECS="$3" \
    bash -c '
      # shellcheck disable=SC1090,SC1091
      . "$1"
      fm_recovery_marker_arm_check "$2" || exit 1
      printf "%s %s %s\n" "$FM_RECOVERY_MARKER_ACTION" \
        "$FM_RECOVERY_RESURFACE_COUNT" "$FM_RECOVERY_RESURFACE_BOUND"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down"
}

resurface_ack() {  # <state> <generation>
  local state=$1
  # shellcheck disable=SC2016 # The marker path and generation expand inside the ack shell.
  env FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_recovery_marker_ack "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state/.watcher-down" "$2"
}

test_recovery_arm_check_counts_resurface_streak() {
  local dir state out gen
  dir=$(make_case resurface-streak); state="$dir/state"

  printf 'pending:downtime:gen.a\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out=$(resurface_arm_check "$state" 3 900)
  [ "$out" = 'recover 1 0' ] || fail "first announcement: expected 'recover 1 0', got '$out'"
  out=$(resurface_arm_check "$state" 3 900)
  [ "$out" = 'wait 1 0' ] || fail "an already-announced marker must wait without double-counting, got '$out'"

  printf 'pending:downtime:gen.a\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out=$(resurface_arm_check "$state" 3 900)
  [ "$out" = 'recover 2 0' ] || fail "second announcement: expected 'recover 2 0', got '$out'"
  printf 'pending:downtime:gen.a\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out=$(resurface_arm_check "$state" 3 900)
  [ "$out" = 'recover 3 1' ] || fail "third unacknowledged announcement must trip the bound, got '$out'"
  out=$(resurface_arm_check "$state" 3 900)
  [ "$out" = 'wait 3 1' ] || fail "a tripped streak must keep the bound set on the wait path, got '$out'"

  gen=$(recovery_marker_generation "$state/.watcher-down")
  resurface_ack "$state" "$gen" || fail "generation-bound ack failed"
  assert_grep 'acked:downtime:' "$state/.watcher-down" "ack did not retire the marker"
  assert_absent "$state/.watcher-down.resurface" "ack left the streak sidecar behind"

  printf 'pending:downtime:gen.b\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out=$(resurface_arm_check "$state" 3 900)
  [ "$out" = 'recover 1 0' ] || fail "a fresh episode must restart the streak, got '$out'"
  pass "the arm check bounds the unacknowledged-announcement streak and the ack resets it"
}

test_handling_successor_does_not_go_blind
test_recovery_arm_check_counts_resurface_streak
test_resurface_time_bound_resumes_supervision
test_resurface_bound_resumes_supervision
test_unacknowledged_recovery_is_announced_once_per_generation
