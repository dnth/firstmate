#!/usr/bin/env bash
# Unit tests for the pure OMP fleet-hook helpers and their fail-open wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-fleet-hooks)
HOME_FIXTURE="$TMP_ROOT/home"
mkdir -p "$HOME_FIXTURE/state" "$HOME_FIXTURE/data"
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
assert.deepEqual([...handlers.keys()], ["tool_result", "todo_reminder", "session.compacting"]);
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
