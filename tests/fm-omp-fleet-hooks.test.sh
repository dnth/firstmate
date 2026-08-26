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
].join("\n");
const redacted = redactSecretText(secretFixture);
assert.match(redacted, /ordinary prose stays visible/);
assert.match(redacted, /\[REDACTED:ANSIBLE_VAULT\]/);
assert.match(redacted, /\[REDACTED:API_KEY\]/);
assert.ok(!redacted.includes("0123456789abcdef0123456789abcdef"));
assert.equal(redactToolResultContent([{ type: "text", text: "ordinary prose" }]), undefined);
const chunks = redactToolResultContent([
  { type: "text", text: "API_KEY=abcdefghijk123456" },
  { type: "image", data: "unchanged" },
]);
assert.equal(chunks?.[1].type, "image");
assert.match(chunks?.[0].text ?? "", /REDACTED:API_KEY/);

assert.equal(parseTodoCheckDrift(""), undefined);
assert.match(parseTodoCheckDrift("DRIFT queued-has-worker: queued-1 - worker exists") ?? "", /queued-1/);

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
case "${1:-}" in
  --check) printf '%s\n' 'DRIFT queued-has-worker: queued-1 - worker exists' ;;
  --emit) printf '%s\n' '[{"phase":"Active","items":["ship-1 - Ship Alpha"]},{"phase":"Ready","items":["queued-1 - Queue Beta"]}]' ;;
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
extension({ on(name, handler) { handlers.set(name, handler); }, sendMessage(message) { sent.push(message); } });
assert.deepEqual([...handlers.keys()], ["tool_result", "todo_reminder", "session.compacting"]);
assert.equal(await handlers.get("tool_result")({ content: null }), undefined);
const reminder = await handlers.get("todo_reminder")({}, {});
assert.match(reminder?.context?.[0] ?? "", /Firstmate board drift/);
assert.equal(sent.length, 1);
const compacted = await handlers.get("session.compacting")({}, {});
assert.match(compacted?.context?.[0] ?? "", /Firstmate fleet snapshot/);
assert.match(compacted?.context?.[0] ?? "", /ship-1/);
console.log("ok - OMP fleet handlers register independently and fail open");
JS
handler_status=$?
expect_code 0 "$handler_status" "OMP fleet handler assertions should pass"
after_handler=$(fixture_digest)
[ "$before_handler" = "$after_handler" ] \
  || fail "OMP fleet handlers mutated the observable board or state bytes"
pass "OMP fleet drift and compaction handlers leave board and state bytes unchanged"
