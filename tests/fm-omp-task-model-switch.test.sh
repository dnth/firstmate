#!/usr/bin/env bash
# The extension side of fm-control's switch-model verb: when a model-switch
# request is applied, what the acknowledgement records, and how every refusal
# and partial result is typed.
#
# This drives the REAL .omp/extensions/lib/fm-task-model-switch.ts through a
# fake OMP host (tests/fm-omp-model-switch-host.mjs); only OMP itself is faked.
# What OMP really does with these calls - the request in flight finishing on the
# old model while the next one uses the new model, thinking-level clamping,
# resume - is proven against the installed OMP by
# tests/fm-omp-model-switch-live-e2e.test.sh.
#
# Each case protects one consumer-visible bug: a switch that waits for the
# worker to go idle, a request delivered as chat, a refusal that changes the
# live model anyway, a partial result claimed as success, or a request that
# applies after it was withdrawn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found (required to run the TypeScript extension)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-omp-task-model-switch)
HOST="$ROOT/tests/fm-omp-model-switch-host.mjs"

HOST="$HOST" TMP_ROOT="$TMP_ROOT" node --input-type=module <<'JS' 2>&1
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const host = await import(pathToFileURL(process.env.HOST).href);
const { LIB, createHost, model, waitFor, writeRequest, readAck, ackFile, requestFile, sleep } = host;
const { installTaskModelSwitch } = await import(LIB);

const catalog = [
	model("p", "a", ["low", "high", "max"]),
	model("p", "b", ["low", "medium", "high"]),
	model("q", "c"),
	model("locked", "d", ["low"]),
];
let n = 0;
const live = [];
const fresh = (options = {}, spawnGen = "g1") => {
	const dir = `${process.env.TMP_ROOT}/case-${++n}`;
	mkdirSync(dir, { recursive: true });
	const h = createHost({ catalog, available: ["p/a", "p/b", "q/c"], current: "p/a", thinking: "low", ...options });
	installTaskModelSwitch(h.pi, { requestDir: dir, spawnGen });
	const c = { ...h, dir, spawnGen };
	live.push(c);
	return c;
};
// Retire every instance between cases so a stale watcher never answers a later one.
const finish = async () => {
	for (const c of live.splice(0)) await c.fire("session_shutdown");
};
const start = async (c) => c.fire("session_start");
const ask = (c, id, target, effort = null, extra = {}) =>
	writeRequest(c.dir, { id, spawnGen: c.spawnGen, model: target, effort, ...extra });
const acked = (c, id) => waitFor(() => existsSync(ackFile(c.dir, id)), `ack for ${id}`);
const ok = (name) => console.log(`ok - ${name}`);

// 1. Applied at once, through the session API only.
{
	const c = fresh();
	await start(c);
	assert.equal(existsSync(`${c.dir}/model-switch.ready`), true, "activation publishes its ready marker");
	ask(c, "r1", "p/b", "medium");
	await acked(c, "r1");
	const ack = readAck(c.dir, "r1");
	assert.equal(ack.outcome, "applied");
	assert.equal(ack.id, "r1");
	assert.equal("boundary" in ack || "raced" in ack || "ackedAtMs" in ack || "pid" in ack, false, "the acknowledgement carries only the sequence as order and no publisher pid");
	const ready = JSON.parse(readFileSync(`${c.dir}/model-switch.ready`, "utf8"));
	assert.equal(ready.pid, process.pid, "the ready marker names its publisher");
	assert.equal("at" in ready, false, "the ready marker carries no wall-clock timestamp");
	assert.deepEqual(ack.before, { model: "p/a", thinking: "low" });
	assert.deepEqual(ack.after, { model: "p/b", thinking: "medium" });
	assert.deepEqual(c.calls, [["setModel", "p/b"], ["setThinkingLevel", "medium"]]);
	assert.equal(existsSync(`${c.dir}/model-switch.r1.processing`), false, "the claim is retired once acknowledged");
	ok("applied: the acknowledgement records id, before, after, and the thinking level");
	await finish();
}

// 2. Mid-task: a busy worker with queued messages is switched at once, not at idle.
{
	const c = fresh({ idle: false, pending: true });
	await start(c);
	ask(c, "r2", "p/b", "high");
	await acked(c, "r2");
	const ack = readAck(c.dir, "r2");
	assert.equal(ack.outcome, "applied");
	assert.deepEqual(ack.after, { model: "p/b", thinking: "high" });
	assert.deepEqual(c.calls, [["setModel", "p/b"], ["setThinkingLevel", "high"]]);
	ok("mid-task: a request applies at once while the session reads busy with messages queued");
	await finish();
}

// 3. Refusals are typed, and none of them changes the live session.
const refusals = [
	["unknown-model", {}, "nowhere/nothing", null, "an unknown model"],
	["no-credentials", {}, "locked/d", null, "a known model this session has no credentials for"],
	["no-credentials", { setModelResult: false }, "p/b", null, "a model whose key does not resolve"],
	["no-credentials", { setModelThrows: "No API key for p/b" }, "p/b", null, "a setModel that throws a missing-key error"],
	["set-model-failed", { setModelThrows: "provider exploded" }, "p/b", null, "a setModel that throws something else"],
	["model-mismatch", { resolveOverride: { "p/b": "q/c" } }, "p/b", null, "a spec that resolves to a different model"],
	["effort-unsupported", {}, "p/b", "max", "an effort the target model does not support"],
	["effort-unsupported", {}, "q/c", "low", "a target model with no thinking levels"],
];
for (const [reason, options, target, effort, what] of refusals) {
	const c = fresh(options);
	await start(c);
	ask(c, "rf", target, effort);
	await acked(c, "rf");
	const ack = readAck(c.dir, "rf");
	assert.equal(ack.outcome, "refused", what);
	assert.equal(ack.reason, reason, what);
	assert.deepEqual(ack.after, ack.before, what);
	assert.equal(c.state.current, "p/a", what);
	assert.equal(c.state.thinking, "low", what);
	assert.equal(c.calls.some(([name]) => name === "setThinkingLevel"), false, `${what}: thinking untouched`);
	ok(`refused ${reason}: ${what}; the live model and thinking level are untouched`);
	await finish();
}

// 4. Partial: the model switched, the thinking level did not - reported, never rolled back.
{
	const clamped = fresh({ clamp: { medium: "low" } });
	await start(clamped);
	ask(clamped, "pm", "p/b", "medium");
	await acked(clamped, "pm");
	const ack = readAck(clamped.dir, "pm");
	assert.equal(ack.outcome, "partial");
	assert.equal(ack.reason, "thinking-mismatch");
	assert.deepEqual(ack.before, { model: "p/a", thinking: "low" });
	assert.deepEqual(ack.after, { model: "p/b", thinking: "low" });
	assert.equal(clamped.state.current, "p/b", "no rollback is performed or claimed");
	assert.equal(clamped.calls.filter(([name]) => name === "setModel").length, 1);
	const thrown = fresh({ setThinkingThrows: "thinking refused" });
	await start(thrown);
	ask(thrown, "pt", "p/b", "high");
	await acked(thrown, "pt");
	assert.equal(readAck(thrown.dir, "pt").outcome, "partial");
	assert.equal(readAck(thrown.dir, "pt").reason, "thinking-error");
	assert.equal(readAck(thrown.dir, "pt").detail, "thinking refused");
	assert.equal(thrown.state.current, "p/b");
	ok("partial: a clamped or failing thinking step reports both live values and rolls nothing back");
	await finish();
}

// 5. Superseded: only the newest request applies.
{
	const c = fresh();
	ask(c, "ms-2000-first", "q/c", null, { requestedAtMonotonicUs: 1000 });
	ask(c, "ms-1000-retry", "p/b", null, { requestedAtMonotonicUs: 2000 });
	await start(c);
	await Promise.all([acked(c, "ms-2000-first"), acked(c, "ms-1000-retry")]);
	const first = readAck(c.dir, "ms-2000-first");
	const retry = readAck(c.dir, "ms-1000-retry");
	assert.equal(first.outcome, "superseded");
	assert.equal(first.reason, "newer-request");
	assert.equal(retry.outcome, "applied");
	assert.deepEqual(c.calls, [["setModel", "p/b"]], "the older request never touches the session");
	assert.equal(retry.ackSequence > first.ackSequence, true, "receipts are ordered by sequence");
	ok("superseded: publication order wins even when the newer request id sorts first");
	await finish();
}

// 6. A request for another incarnation, and a malformed one, are refused.
{
	const c = fresh();
	await start(c);
	writeRequest(c.dir, { id: "sg", spawnGen: "other-gen", model: "p/b" });
	await acked(c, "sg");
	assert.equal(readAck(c.dir, "sg").reason, "stale-incarnation");
	writeFileSync(requestFile(c.dir, "bad"), "{not json");
	await acked(c, "bad");
	assert.equal(readAck(c.dir, "bad").reason, "invalid-request");
	assert.equal(c.state.current, "p/a");
	assert.deepEqual(c.calls, []);
	ok("refused: another worker generation's request and a malformed request never touch the session");
	await finish();
}

// 7. A request withdrawn before it is claimed can never apply.
{
	const c = fresh();
	await start(c);
	ask(c, "wd", "p/b");
	renameSync(requestFile(c.dir, "wd"), `${c.dir}/model-switch.wd.cancelled`);
	await sleep(250);
	assert.deepEqual(c.calls, []);
	assert.equal(existsSync(ackFile(c.dir, "wd")), false);
	assert.equal(c.state.current, "p/a");
	ok("withdrawn: a request renamed away before the claim is never applied");
	await finish();
}

// 8. Only one instance owns a directory, and a subagent context never activates it.
{
	const c = fresh();
	const child = createHost({ catalog, available: ["p/a", "p/b", "q/c"], current: "p/a" });
	await c.fire("session_start", {}, { ...c.ctx, agent: { kind: "sub" } });
	assert.equal(existsSync(`${c.dir}/model-switch.ready`), false, "a subagent context must not activate the channel");
	await start(c);
	installTaskModelSwitch(child.pi, { requestDir: c.dir, spawnGen: c.spawnGen });
	await child.fire("session_start");
	ask(c, "own", "p/b");
	await acked(c, "own");
	assert.deepEqual(child.calls, [], "a duplicate instance in the same process stays inert");
	assert.deepEqual(c.calls, [["setModel", "p/b"]]);
	ok("ownership: a subagent context and a duplicate instance never answer the worker's request");
	await finish();
}

// 9. Explicitly reselecting the live model goes through OMP's setter.
{
	const c = fresh();
	await start(c);
	ask(c, "np", "p/a");
	await acked(c, "np");
	const ack = readAck(c.dir, "np");
	assert.equal(ack.outcome, "applied");
	assert.deepEqual(ack.before, { model: "p/a", thinking: "low" });
	assert.deepEqual(ack.after, ack.before);
	assert.deepEqual(c.calls, [["setModel", "p/a"]]);
	ok("explicit selection: a request for the live model still invokes OMP's model setter");
	await finish();
}

process.exit(0);
JS
RC=$?
[ "$RC" -eq 0 ] || fail "model-switch extension cases failed (exit $RC)"
