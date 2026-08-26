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
needs-decision: [key=review] confirm rollout
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
FM_HOOKS="$FM_HOOKS" FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" \
FM_DATA_OVERRIDE="$HOME_FIXTURE/data" node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
const { buildFleetSnapshot, parseTodoCheckDrift, redactSecretText, redactToolResultContent } =
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

const snapshot = buildFleetSnapshot({
  metas: [{ id: "ship-1", kind: "ship", window: "crew:ship-1", project: "alpha", pr: "https://github.com/example/alpha/pull/7" }],
  openDecisions: ["ship-1: needs-decision [key=review] confirm rollout"],
  backlog: "## In flight\n- [ ] ship-1 - Ship Alpha\n## Queued\n- [ ] queued-1 - Queue Beta\n## Done\n- [x] done-1 - Done Gamma",
});
assert.match(snapshot, /ship-1\(ship,crew:ship-1,alpha\)/);
assert.match(snapshot, /OPEN DECISIONS/);
assert.match(snapshot, /pull\/7/);
assert.match(snapshot, /Ready=1 In-flight=1/);
assert.ok(snapshot.length <= 1200);

console.log("ok - OMP fleet pure helpers redact secrets, parse drift, and build bounded snapshots");
JS

FM_HOOKS="$FM_HOOKS" FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" \
FM_DATA_OVERRIDE="$HOME_FIXTURE/data" node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
const { default: extension } = await import(process.env.FM_HOOKS);

const handlers = new Map();
extension({ on(name, handler) { handlers.set(name, handler); } });
assert.deepEqual([...handlers.keys()], ["tool_result", "todo_reminder", "session.compacting"]);
assert.equal(await handlers.get("tool_result")({ content: null }), undefined);
assert.equal(await handlers.get("todo_reminder")({}, {}), undefined);
const compacted = await handlers.get("session.compacting")({}, {});
assert.match(compacted?.context?.[0] ?? "", /Firstmate fleet snapshot/);
assert.match(compacted?.context?.[0] ?? "", /ship-1/);
console.log("ok - OMP fleet handlers register independently and fail open");
JS
