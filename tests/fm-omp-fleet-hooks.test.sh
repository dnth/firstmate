#!/usr/bin/env bash
# Unit tests for the pure OMP fleet-hook helpers and their fail-open wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-fleet-hooks)
HOME_FIXTURE="$TMP_ROOT/home"
mkdir -p "$HOME_FIXTURE/state" "$HOME_FIXTURE/data"

test_project_todo_policy() {
  local reminders enabled
  if ! command -v omp >/dev/null 2>&1; then
    echo "skip: OMP not found for project todo-policy check"
    return
  fi
  reminders=$(cd "$ROOT" && omp config get todo.reminders --json | jq -r '.value') \
    || fail "OMP could not resolve the Firstmate project reminder policy"
  enabled=$(cd "$ROOT" && omp config get todo.enabled --json | jq -r '.value') \
    || fail "OMP could not resolve the Firstmate project todo-tool policy"
  [ "$reminders" = false ] \
    || fail "OMP end-of-turn todo reminders remain enabled for Firstmate's long-lived fleet projection"
  [ "$enabled" = true ] \
    || fail "the duplicate-response fix disabled OMP's todo tool"
  pass "OMP keeps normal todo operation while suppressing reminder-initiated turns"
}

test_project_todo_policy
cat > "$HOME_FIXTURE/state/ship-1.meta" <<'EOF'
kind=ship
window=crew:ship-1
project=alpha
pr=https://github.com/example/alpha/pull/7
EOF
cat > "$HOME_FIXTURE/state/ship-1.status" <<'EOF'
needs-decision [key=review]: confirm rollout
resolved [corr=answer-1] [key=review]: rollout confirmed
needs-decision [key=route]: choose deployment route
EOF
cat > "$HOME_FIXTURE/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-1 - Ship Alpha

## Queued
- [ ] queued-1 - Queue Beta

## Done
- [x] done-1 - Done Gamma
EOF

FM_HOOKS="$ROOT/.omp/extensions/fm-fleet-hooks.ts"
FM_HOOKS="$FM_HOOKS" FM_ROOT="$ROOT" FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" \
FM_DATA_OVERRIDE="$HOME_FIXTURE/data" node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
const { buildFleetSnapshot, parseFleetMeta, parseOpenDecisionRows, parseTodoCheckDrift,
  parseTodoProjectionCounts, redactSecretText, redactToolResultContent } =
  await import(process.env.FM_HOOKS);

const secretFixture = [
  "ordinary prose stays visible.",
  "$ANSIBLE_VAULT;1.1;AES256",
  "0123456789abcdef0123456789abcdef",
  "API_KEY=abcdefghijk123456",
  'QUOTED_API_KEY="abcdefgh"',
  'ESCAPED_API_KEY="abcd\\"efgh"',
  "PASSWORD='hunter2!'",
  "glrt-abcdefghijklmnop",
  "gldt-abcdefghijklmnop",
  "glcbt-abcdefghijklmnop",
].join("\n");
const redacted = redactSecretText(secretFixture);
assert.match(redacted, /ordinary prose stays visible/);
assert.match(redacted, /\[REDACTED:ANSIBLE_VAULT\]/);
assert.match(redacted, /\[REDACTED:API_KEY\]/);
assert.match(redacted, /\[REDACTED:QUOTED_API_KEY\]/);
assert.match(redacted, /\[REDACTED:ESCAPED_API_KEY\]/);
assert.match(redacted, /\[REDACTED:PASSWORD\]/);
assert.ok(!redacted.includes("0123456789abcdef0123456789abcdef"));
assert.ok(!redacted.includes("glrt-abcdefghijklmnop"));
assert.ok(!redacted.includes("gldt-abcdefghijklmnop"));
assert.ok(!redacted.includes("glcbt-abcdefghijklmnop"));
assert.equal(redactSecretText('API_KEY="1234567"'), 'API_KEY="1234567"');
assert.equal(redactSecretText('API_KEY="abc\\"def"'), 'API_KEY="abc\\"def"');
assert.equal(redactToolResultContent([{ type: "text", text: "ordinary prose" }]), undefined);
const chunks = redactToolResultContent([
  { type: "text", text: "API_KEY=abcdefghijk123456" },
  { type: "image", data: "unchanged" },
]);
assert.equal(chunks?.[1].type, "image");
assert.match(chunks?.[0].text ?? "", /REDACTED:API_KEY/);

assert.equal(parseTodoCheckDrift(""), undefined);
assert.match(parseTodoCheckDrift("DRIFT queued-has-worker: queued-1 - worker exists") ?? "", /queued-1/);
assert.equal(parseTodoCheckDrift("DRIFT-CHECK-SKIPPED: tasks-axi unavailable"), undefined);
assert.throws(() => parseTodoCheckDrift("unexpected output"), /malformed/);

assert.deepEqual(parseFleetMeta("ship-1", "kind=ship\nwindow=crew:ship-1\nproject=alpha\npr=https://github.com/example/alpha/pull/7\n"), {
  id: "ship-1", kind: "ship", window: "crew:ship-1", project: "alpha", pr: "https://github.com/example/alpha/pull/7",
});
const folded = execFileSync("bash", ["-c", '. "$1/bin/fm-classify-lib.sh"; scan_open_decisions "$2"', "_", process.env.FM_ROOT, `${process.env.FM_HOME}/state`], { encoding: "utf8" });
const openDecisions = parseOpenDecisionRows(folded);
assert.deepEqual(openDecisions, ["ship-1: needs-decision [key=route]: choose deployment route"]);
const todoProjection = JSON.stringify([
  { phase: "Active", items: ["ship-1 - Ship Alpha"] },
  { phase: "Ready", items: ["queued-1 - Queue Beta"] },
]);
assert.deepEqual(parseTodoProjectionCounts(todoProjection), { ready: 1, inFlight: 1 });

const snapshot = buildFleetSnapshot({
  metas: [{ id: "ship-1", kind: "ship", window: "crew:ship-1", project: "alpha", pr: "https://github.com/example/alpha/pull/7" }],
  openDecisions,
  todoProjection,
});
assert.match(snapshot, /ship-1\(ship,crew:ship-1,alpha\)/);
assert.match(snapshot, /OPEN DECISIONS/);
assert.match(snapshot, /pull\/7/);
assert.match(snapshot, /Ready=1 In-flight=1/);
assert.ok(snapshot.length <= 1200);

const largeSnapshot = buildFleetSnapshot({
  metas: Array.from({ length: 80 }, (_, index) => ({
    id: `ship-${String(index).padStart(2, "0")}`,
    kind: "ship",
    window: `crew:ship-${index}`,
    project: `long-project-${index}`,
    pr: `https://github.com/example/project/pull/${index}`,
  })),
  openDecisions: Array.from({ length: 30 }, (_, index) => `ship-${index}: needs-decision [key=route-${index}]: choose route ${index}`),
  todoProjection,
  maxChars: 600,
});
assert.ok(largeSnapshot.length <= 600);
assert.match(largeSnapshot, /roster .*omitted/);
assert.match(largeSnapshot, /OPEN DECISIONS .*omitted/);
assert.match(largeSnapshot, /in-flight PRs .*omitted/);
assert.match(largeSnapshot, /backlog Ready=1 In-flight=1/);

console.log("ok - OMP fleet pure helpers use authoritative rows and preserve bounded sections");
JS
pure_status=$?
expect_code 0 "$pure_status" "OMP fleet pure helper assertions should pass"

fixture_digest() {
  find "$HOME_FIXTURE/data" "$HOME_FIXTURE/state" -type f -exec cksum {} \; | LC_ALL=C sort
}
HANDLER_ROOT="$TMP_ROOT/handler-root"
mkdir -p "$HANDLER_ROOT/.omp/extensions" "$HANDLER_ROOT/bin"
cp "$FM_HOOKS" "$HANDLER_ROOT/.omp/extensions/fm-fleet-hooks.ts"
cp "$ROOT/bin/fm-classify-lib.sh" "$HANDLER_ROOT/bin/fm-classify-lib.sh"
cp "$ROOT/bin/fm-timeout-lib.sh" "$HANDLER_ROOT/bin/fm-timeout-lib.sh"
cat > "$HANDLER_ROOT/bin/fm-todo-project.sh" <<'SH'
#!/usr/bin/env bash
[ "$#" -eq 1 ] || exit 2
case "${FM_FAKE_TODO_MODE:-ok}:${1:-}" in
  partial-failure:--check)
    printf '%s\n' 'DRIFT queued-has-worker: partial output must be ignored'
    exit 7
    ;;
  invalid:--check) printf '%s\n' 'not a drift protocol line' ;;
  hang:--check)
    sleep 10 &
    wait
    ;;
  ok:--check) printf '%s\n' 'DRIFT queued-has-worker: queued-1 - worker exists' ;;
  *:--emit) printf '%s\n' '[{"phase":"Active","items":["ship-1 - Ship Alpha"]},{"phase":"Ready","items":["queued-1 - Queue Beta"]}]' ;;
  *) exit 2 ;;
esac
SH
chmod +x "$HANDLER_ROOT/bin/fm-todo-project.sh"
HANDLER_HOOKS="$HANDLER_ROOT/.omp/extensions/fm-fleet-hooks.ts"
before_handler=$(fixture_digest)
FM_HOOKS="$HANDLER_HOOKS" FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" \
FM_DATA_OVERRIDE="$HOME_FIXTURE/data" node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
const { default: extension } = await import(process.env.FM_HOOKS);

const handlers = new Map();
const sent = [];
extension({ on(name, handler) { handlers.set(name, handler); }, sendMessage(message, options) { sent.push({ message, options }); } });
assert.deepEqual([...handlers.keys()], ["tool_result", "todo_reminder", "turn_end", "session.compacting"]);
assert.equal(await handlers.get("tool_result")({ content: null }), undefined);
const reminder = await handlers.get("todo_reminder")({}, {});
assert.equal(reminder, undefined);
assert.equal(sent.length, 1);
assert.deepEqual(sent[0], {
  message: {
    customType: "firstmate-todo-drift",
    content: "Firstmate board drift: DRIFT queued-has-worker: queued-1 - worker exists",
    display: false,
    attribution: "agent",
    details: { kind: "todo-drift", runtime: "omp" },
  },
  options: { deliverAs: "nextTurn" },
});
process.env.FM_FAKE_TODO_MODE = "partial-failure";
assert.equal(await handlers.get("todo_reminder")({}, {}), undefined);
assert.equal(sent.length, 1);
process.env.FM_FAKE_TODO_MODE = "invalid";
assert.equal(await handlers.get("todo_reminder")({}, {}), undefined);
assert.equal(sent.length, 1);
process.env.FM_FAKE_TODO_MODE = "hang";
const timeoutStarted = Date.now();
assert.equal(await handlers.get("todo_reminder")({}, {}), undefined);
assert.ok(Date.now() - timeoutStarted < 5000);
assert.equal(sent.length, 1);
process.env.FM_FAKE_TODO_MODE = "ok";
const compacted = await handlers.get("session.compacting")({}, {});
assert.match(compacted?.context?.[0] ?? "", /Firstmate fleet snapshot/);
assert.match(compacted?.context?.[0] ?? "", /ship-1\(ship,crew:ship-1,alpha\)/);
assert.match(compacted?.context?.[0] ?? "", /choose deployment route/);
assert.match(compacted?.context?.[0] ?? "", /Ready=1 In-flight=1/);
console.log("ok - OMP fleet handlers register independently and fail open");
JS
handler_status=$?
expect_code 0 "$handler_status" "OMP fleet handler assertions should pass"
after_handler=$(fixture_digest)
[ "$before_handler" = "$after_handler" ] \
  || fail "OMP fleet handlers mutated the observable board or state bytes"
pass "OMP fleet drift and compaction handlers leave board and state bytes unchanged"

AUTOSYNC_ROOT="$TMP_ROOT/autosync-home"
mkdir -p "$AUTOSYNC_ROOT/.omp/extensions" "$AUTOSYNC_ROOT/bin" "$AUTOSYNC_ROOT/state" "$AUTOSYNC_ROOT/data"
cp "$FM_HOOKS" "$AUTOSYNC_ROOT/.omp/extensions/fm-fleet-hooks.ts"
cp "$ROOT/bin/fm-primary-scope-lib.sh" "$AUTOSYNC_ROOT/bin/fm-primary-scope-lib.sh"
printf 'fixture home\n' > "$AUTOSYNC_ROOT/AGENTS.md"
printf '## In flight\n- [ ] ship-1 - Ship Alpha\n' > "$AUTOSYNC_ROOT/data/backlog.md"
git -C "$AUTOSYNC_ROOT" init -q
cat > "$AUTOSYNC_ROOT/bin/fm-todo-project.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--emit" ] || exit 2
[ -z "${FM_FAKE_EMIT_LOG:-}" ] || printf 'emit\n' >> "$FM_FAKE_EMIT_LOG"
projection='[{"phase":"Active","items":["ship-1 - Ship Alpha"]}]'
[ -z "${FM_FAKE_PROJECTION:-}" ] || projection=$FM_FAKE_PROJECTION
case "${FM_FAKE_EMIT_MODE:-ok}" in
  catchup|catchup-fail|catchup-bad)
    if [ ! -f "$FM_FAKE_EMIT_LOG.rewrite" ]; then
      printf 'changed during emit\n' >> "$FM_FIXTURE_BOARD"
      printf 'done\n' > "$FM_FAKE_EMIT_LOG.rewrite"
      sleep 0.2
      case "$FM_FAKE_EMIT_MODE" in
        catchup-fail) exit 3 ;;
        catchup-bad) printf '{broken\n'; exit 0 ;;
      esac
      printf '%s\n' '[{"phase":"Active","items":["ship-1 - Ship Alpha"]}]'
    else
      printf '%s\n' "$FM_CHANGED_PROJECTION"
    fi
    ;;
  churn)
    printf 'changed during every emit\n' >> "$FM_FIXTURE_BOARD"
    printf '%s\n' "$FM_CHANGED_PROJECTION"
    ;;
  ok) printf '%s\n' "$projection" ;;
  fail) printf '%s\n' 'projection backend unavailable' >&2 ; exit 3 ;;
  badjson) printf '%s\n' '{"phase":"Active"' ;;
  shape) printf '%s\n' '[{"phase":"Active","items":[7]}]' ;;
  empty) printf '%s\n' '[]' ;;
  hang)
    [ -z "${FM_FAKE_EMIT_PID:-}" ] || printf '%s\n' "$$" > "$FM_FAKE_EMIT_PID"
    exec sleep 60
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$AUTOSYNC_ROOT/bin/fm-todo-project.sh"
AUTOSYNC_HOOKS="$AUTOSYNC_ROOT/.omp/extensions/fm-fleet-hooks.ts"
CHANGED_PROJECTION='[{"phase":"Active","items":["ship-1 - Ship Alpha"]},{"phase":"Ready","items":["queued-1 - Queue Beta"]}]'
BOARD="$AUTOSYNC_ROOT/data/backlog.md"
EMIT_LOG="$TMP_ROOT/autosync-emit.log"
EMIT_PID="$TMP_ROOT/autosync-emit.pid"

env -u FM_TASK_ID FM_HOOKS="$AUTOSYNC_HOOKS" FM_HOME="$AUTOSYNC_ROOT" FM_STATE_OVERRIDE="$AUTOSYNC_ROOT/state" \
FM_CHANGED_PROJECTION="$CHANGED_PROJECTION" FM_FAKE_EMIT_LOG="$EMIT_LOG" FM_FAKE_EMIT_PID="$EMIT_PID" \
FM_FIXTURE_BOARD="$BOARD" node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
import { appendFileSync, existsSync, readdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
const { default: extension } = await import(process.env.FM_HOOKS);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

const handlers = new Map();
const sent = [];
extension({ on(name, handler) { handlers.set(name, handler); }, sendMessage(message, options) { sent.push({ message, options }); } });
const turnEnd = handlers.get("turn_end");
const initialTodo = [{ name: "Active", tasks: [{ content: "ship-1 - Ship Alpha", status: "pending" }] }];
const todoResult = phases => ({ type: "message", message: { role: "toolResult", toolName: "todo", details: { phases } } });
const ctx = { sessionManager: { getSessionId: () => "primary-session-a", getBranch: () => [todoResult(initialTodo)] } };
const stateDir = join(process.env.FM_STATE_OVERRIDE, "omp-todo-autosync");
const board = process.env.FM_FIXTURE_BOARD;
const emitLog = process.env.FM_FAKE_EMIT_LOG;
const emitCount = () => {
  try { return readFileSync(emitLog, "utf8").split("\n").filter(Boolean).length; } catch { return 0; }
};
const waitForEmits = async count => {
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    if (emitCount() >= count) { await sleep(200); return; }
    await sleep(20);
  }
  throw new Error(`projection subprocess stayed at ${emitCount()}, waiting for ${count}`);
};
const settle = async () => { await sleep(300); };

// The live transcript confirms the initial todo matches the board.
await turnEnd({}, ctx);
await waitForEmits(1);
assert.equal(sent.length, 0);
const baselineFiles = readdirSync(stateDir);
assert.equal(baselineFiles.length, 1);
const baseline = JSON.parse(readFileSync(join(stateDir, baselineFiles[0]), "utf8"));
assert.match(baseline.hash, /^[0-9a-f]{64}$/);

// AC2: repeated turns on an unchanged board inject nothing and cost no
// projection subprocess at all.
await turnEnd({}, ctx);
await turnEnd({}, ctx);
await settle();
assert.equal(emitCount(), 1);
assert.equal(sent.length, 0);

// AC1: the turn that observes a board write offers one bounded instruction
// carrying the projection the todo tool must re-initialize from.
appendFileSync(board, "- [ ] queued-1 - Queue Beta\n");
process.env.FM_FAKE_PROJECTION = process.env.FM_CHANGED_PROJECTION;
await turnEnd({}, ctx);
await waitForEmits(2);
assert.equal(sent.length, 1);
assert.equal(sent[0].message.customType, "firstmate-todo-projection");
assert.equal(sent[0].message.display, false);
assert.match(sent[0].message.content, /\{"op":"init","list":\[/);
assert.match(sent[0].message.content, /queued-1 - Queue Beta/);
assert.match(sent[0].message.content, /board projection, not a new request/);
assert.ok(sent[0].message.content.length <= 8000);
assert.deepEqual(sent[0].options, { deliverAs: "nextTurn", triggerTurn: true });

// AC2: the same changed projection never repeats, however many turns follow.
await turnEnd({}, ctx);
await turnEnd({}, ctx);
await turnEnd({}, ctx);
await settle();
assert.equal(emitCount(), 2);
assert.equal(sent.length, 1);

// A board write that leaves the projection identical re-runs the projection
// once and still offers nothing.
appendFileSync(board, "\n");
await turnEnd({}, ctx);
await waitForEmits(3);
assert.equal(sent.length, 1);

// AC3: a failing, malformed, or wrongly shaped projection injects nothing,
// never throws, and is not retried while the board version is unchanged.
for (const mode of ["fail", "badjson", "shape"]) {
  process.env.FM_FAKE_EMIT_MODE = mode;
  appendFileSync(board, `# ${mode}\n`);
  const before = emitCount();
  await turnEnd({}, ctx);
  await waitForEmits(before + 1);
  assert.equal(sent.length, 1);
  await turnEnd({}, ctx);
  await turnEnd({}, ctx);
  await settle();
  assert.equal(emitCount(), before + 1);
  assert.equal(sent.length, 1);
}

// AC3: a hung projection never blocks the turn that observes it.
process.env.FM_FAKE_EMIT_MODE = "hang";
appendFileSync(board, "# hang\n");
const started = Date.now();
await turnEnd({}, ctx);
assert.ok(Date.now() - started < 100, `turn end blocked for ${Date.now() - started}ms`);
const pidDeadline = Date.now() + 8000;
while (Date.now() < pidDeadline && !existsSync(process.env.FM_FAKE_EMIT_PID)) await sleep(20);
assert.ok(existsSync(process.env.FM_FAKE_EMIT_PID), "hung projection subprocess never started");
process.kill(-Number(readFileSync(process.env.FM_FAKE_EMIT_PID, "utf8").trim()), "SIGKILL");
await settle();
assert.equal(sent.length, 1);
process.env.FM_FAKE_EMIT_MODE = "ok";

// An empty board is a real projection: its rebuild instruction clears the todo.
appendFileSync(board, "# empty\n");
process.env.FM_FAKE_PROJECTION = "[]";
await turnEnd({}, ctx);
await waitForEmits(emitCount() + 1);
assert.equal(sent.length, 2);
assert.match(sent[1].message.content, /"list":\[\]/);

// A different session in the same home keeps its own record and starts from
// its own live todo, so sibling sessions never inherit this one's projection.
process.env.FM_FAKE_PROJECTION = process.env.FM_CHANGED_PROJECTION;
const changedTodo = [...initialTodo, { name: "Ready", tasks: [{ content: "queued-1 - Queue Beta", status: "completed" }] }];
const ctxB = { sessionManager: { getSessionId: () => "primary-session-b", getBranch: () => [todoResult(changedTodo)] } };
await turnEnd({}, ctxB);
await waitForEmits(emitCount() + 1);
assert.equal(sent.length, 2);
assert.equal(readdirSync(stateDir).length, 2);
const freshTurn = async (id, getBranch, expectedOffers) => {
  const beforeOffers = sent.length;
  const beforeEmits = emitCount();
  const freshCtx = { sessionManager: { getSessionId: () => id, getBranch } };
  await turnEnd({}, freshCtx);
  await waitForEmits(beforeEmits + 1);
  assert.equal(sent.length - beforeOffers, expectedOffers, id);
  await turnEnd({}, freshCtx);
  await settle();
  assert.equal(sent.length - beforeOffers, expectedOffers, `${id} repeated`);
};
await freshTurn("fresh-stale", () => [todoResult(initialTodo)], 1);
await freshTurn("fresh-unreadable", () => { throw new Error("unreadable"); }, 1);
await freshTurn("fresh-custom", () => [{ type: "custom", customType: "user_todo_edit", data: { phases: changedTodo } }], 0);
await freshTurn("fresh-newest-tool", () => [{ type: "custom", customType: "user_todo_edit", data: { phases: initialTodo } }, todoResult(changedTodo)], 0);
await freshTurn("fresh-error", () => [todoResult(initialTodo), { ...todoResult(changedTodo), message: { ...todoResult(changedTodo).message, isError: true } }], 1);
await freshTurn("fresh-malformed", () => [todoResult(initialTodo), todoResult([{ name: "Ready", tasks: [null] }])], 1);
process.env.FM_FAKE_PROJECTION = '[{"phase":"Active","items":["first","second"]}]';
await freshTurn("fresh-reordered", () => [todoResult([{ name: "Active", tasks: [{ content: "second", status: "pending" }, { content: "first", status: "pending" }] }])], 1);

for (const mode of ["catchup", "catchup-fail", "catchup-bad", "churn"]) {
  try { unlinkSync(`${emitLog}.rewrite`); } catch {}
  process.env.FM_FAKE_EMIT_MODE = mode;
  const beforeEmits = emitCount();
  const beforeOffers = sent.length;
  const catchupCtx = { sessionManager: { getSessionId: () => `session-${mode}`, getBranch: () => [todoResult(initialTodo)] } };
  await turnEnd({}, catchupCtx);
  if (mode !== "churn") {
    const deadline = Date.now() + 8000;
    while (!existsSync(`${emitLog}.rewrite`) && Date.now() < deadline) await sleep(10);
    assert.ok(existsSync(`${emitLog}.rewrite`));
  }
  await turnEnd({}, catchupCtx);
  const rounds = mode === "churn" ? 3 : 2;
  await waitForEmits(beforeEmits + rounds);
  await settle();
  assert.equal(emitCount() - beforeEmits, rounds, mode);
  assert.equal(sent.length - beforeOffers, 1, mode);
  assert.match(sent.at(-1).message.content, /queued-1 - Queue Beta/);
}
process.env.FM_FAKE_EMIT_MODE = "ok";
console.log("ok - OMP turn-end autosync offers one bounded projection per board change");
JS
autosync_status=$?
expect_code 0 "$autosync_status" "OMP turn-end todo autosync assertions should pass"

env -u FM_TASK_ID FM_HOOKS="$AUTOSYNC_HOOKS" FM_HOME="$AUTOSYNC_ROOT" FM_STATE_OVERRIDE="$AUTOSYNC_ROOT/state" \
FM_CHANGED_PROJECTION="$CHANGED_PROJECTION" FM_TASK_ID="ship-9" node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
const { default: extension } = await import(process.env.FM_HOOKS);
const handlers = new Map();
const sent = [];
extension({ on(name, handler) { handlers.set(name, handler); }, sendMessage(message, options) { sent.push({ message, options }); } });
process.env.FM_FAKE_PROJECTION = process.env.FM_CHANGED_PROJECTION;
await handlers.get("turn_end")({}, { sessionManager: { getSessionId: () => "primary-session-a" } });
await new Promise(resolve => setTimeout(resolve, 500));
assert.equal(sent.length, 0);
console.log("ok - an fm-spawn task worker never replaces its own todo with the board");
JS
scope_status=$?
expect_code 0 "$scope_status" "OMP todo autosync should stay silent inside a task worker"
pass "OMP turn-end todo autosync stays bounded, fail-open, and primary-only"


mkfifo "$HOME_FIXTURE/state/a-fifo.meta"
FM_HOOKS="$HANDLER_HOOKS" FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" \
FM_DATA_OVERRIDE="$HOME_FIXTURE/data" node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
const { default: extension } = await import(process.env.FM_HOOKS);
const handlers = new Map();
extension({ on(name, handler) { handlers.set(name, handler); } });
const started = Date.now();
assert.equal(await handlers.get("session.compacting")({}, {}), undefined);
assert.ok(Date.now() - started < 1000);
JS
fifo_status=$?
rm "$HOME_FIXTURE/state/a-fifo.meta"
expect_code 0 "$fifo_status" "OMP fleet compaction should reject FIFO metadata without blocking"

ln -s ship-1.meta "$HOME_FIXTURE/state/a-link.meta"
FM_HOOKS="$HANDLER_HOOKS" FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" \
FM_DATA_OVERRIDE="$HOME_FIXTURE/data" node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
const { default: extension } = await import(process.env.FM_HOOKS);
const handlers = new Map();
extension({ on(name, handler) { handlers.set(name, handler); } });
assert.equal(await handlers.get("session.compacting")({}, {}), undefined);
JS
link_status=$?
rm "$HOME_FIXTURE/state/a-link.meta"
expect_code 0 "$link_status" "OMP fleet compaction should reject symlink metadata"

dd if=/dev/zero of="$HOME_FIXTURE/state/z-large.meta" bs=65537 count=1 2>/dev/null
FM_HOOKS="$HANDLER_HOOKS" FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" \
FM_DATA_OVERRIDE="$HOME_FIXTURE/data" node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
const { default: extension } = await import(process.env.FM_HOOKS);
const handlers = new Map();
extension({ on(name, handler) { handlers.set(name, handler); } });
assert.equal(await handlers.get("session.compacting")({}, {}), undefined);
JS
large_status=$?
rm "$HOME_FIXTURE/state/z-large.meta"
expect_code 0 "$large_status" "OMP fleet compaction should reject oversized metadata"
pass "OMP fleet compaction rejects unsafe metadata entries without blocking"
