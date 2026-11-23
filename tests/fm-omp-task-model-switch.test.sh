#!/usr/bin/env bash
# The extension side of fm-control's switch-model verb: when a model-switch
# request is applied, what the acknowledgement records, how every refusal and
# partial result is typed, and how the admission gate keeps a switch out of a
# turn.
#
# This drives the REAL .omp/extensions/lib/fm-task-model-switch.ts, and for the
# gate cases the real fm-task-inbox-doorbell.ts beside it, through a fake OMP
# host (tests/fm-omp-model-switch-host.mjs); only OMP itself is faked. What OMP
# really does with these calls - turn_end handlers not being awaited, isIdle
# across a tool run, thinking-level clamping, resume - is proven against the
# installed OMP by tests/fm-omp-model-switch-live-e2e.test.sh and recorded in
# docs/verification/runtime-backends.md.
#
# Each case protects one consumer-visible bug: a switch applied inside a turn,
# a prompt that starts while the switch is half applied, a request delivered as
# chat, a refusal that changes the live model anyway, a partial result claimed
# as success, a race reported as clean, or a request that applies after it was
# withdrawn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found (required to run the TypeScript extension)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-omp-task-model-switch)
HOST="$ROOT/tests/fm-omp-model-switch-host.mjs"
DOORBELL="$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts"

OUT=$(HOST="$HOST" DOORBELL="$DOORBELL" TMP_ROOT="$TMP_ROOT" node --input-type=module <<'JS' 2>&1
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const host = await import(pathToFileURL(process.env.HOST).href);
const { LIB, createHost, model, waitFor, writeRequest, readAck, ackFile, requestFile, sleep } = host;
const { installTaskModelSwitch } = await import(LIB);
const { installTaskInboxDoorbell } = await import(pathToFileURL(process.env.DOORBELL).href);

const catalog = [
	model("p", "a", ["low", "high", "max"]),
	model("p", "b", ["low", "medium", "high"]),
	model("q", "c"),
	model("locked", "d", ["low"]),
];
let n = 0;
const live = [];
const fresh = (options = {}, spawnGen = "g1", dir = `${process.env.TMP_ROOT}/case-${++n}`) => {
	mkdirSync(dir, { recursive: true });
	const h = createHost({ catalog, available: ["p/a", "p/b", "q/c"], current: "p/a", thinking: "low", ...options });
	installTaskModelSwitch(h.pi, { requestDir: dir, spawnGen });
	const c = { ...h, dir, spawnGen };
	live.push(c);
	return c;
};
// Cases share one process, and so one process-global gate: retire every
// instance between cases so a stale watcher never answers a later case.
const finish = async () => {
	for (const c of live.splice(0)) await c.fire("session_shutdown");
};
const start = async (c) => c.fire("session_start");
const ask = (c, id, target, effort = null, extra = {}) =>
	writeRequest(c.dir, { id, spawnGen: c.spawnGen, model: target, effort, ...extra });
const acked = (c, id) => waitFor(() => existsSync(ackFile(c.dir, id)), `ack for ${id}`);
const ok = (name) => console.log(`ok - ${name}`);
const settled = (promise) => {
	const box = { done: false };
	promise.then(() => {
		box.done = true;
	});
	return box;
};

// 1. Idle: applied at once, credentials resolved first, through the session API only.
{
	const c = fresh();
	await start(c);
	assert.equal(existsSync(`${c.dir}/model-switch.ready`), true, "activation publishes its ready marker");
	ask(c, "r1", "p/b", "medium");
	await acked(c, "r1");
	const ack = readAck(c.dir, "r1");
	assert.equal(ack.outcome, "applied");
	assert.equal(ack.id, "r1");
	assert.equal(ack.boundary, "idle");
	assert.equal(ack.raced, false);
	assert.equal("ackedAtMs" in ack, false, "the sequence is the only order field");
	assert.deepEqual(ack.before, { model: "p/a", thinking: "low" });
	assert.deepEqual(ack.after, { model: "p/b", thinking: "medium" });
	assert.equal(ack.modelChanged, true);
	assert.deepEqual(c.keyCalls, ["p/b"], "the target credentials are prepared");
	assert.deepEqual(c.calls, [["setModel", "p/b"], ["setThinkingLevel", "medium"]]);
	assert.equal(existsSync(`${c.dir}/model-switch.r1.processing`), false, "the claim is retired once acknowledged");
	ok("idle: the request applies at once and the acknowledgement records id, before, after, thinking, and raced=false");
	await finish();
}

{
	const c = fresh({ idle: false });
	await start(c);
	let releaseFirst;
	let releaseSecond;
	const firstKey = new Promise((resolve) => { releaseFirst = resolve; });
	const secondKey = new Promise((resolve) => { releaseSecond = resolve; });
	c.state.keyHold = (target) => target === "p/b" ? firstKey : secondKey;
	ask(c, "prewarm-first", "p/b");
	c.state.idle = true;
	const terminal = settled(c.fire("agent_end", { willContinue: false }));
	await waitFor(() => c.keyCalls.includes("p/b"), "the first request to begin credential preparation");
	await waitFor(() => terminal.done, "terminal lifecycle delivery while credentials are outstanding");
	renameSync(requestFile(c.dir, "prewarm-first"), `${c.dir}/model-switch.prewarm-first.cancelled`);
	ask(c, "prewarm-second", "q/c");
	releaseFirst();
	await waitFor(() => c.keyCalls.includes("q/c"), "credential preparation for the replacement request");
	const prompt = settled(c.fire("before_agent_start", { prompt: "go" }));
	await waitFor(() => prompt.done, "the prompt to pass before the replacement enters the gate");
	assert.equal(existsSync(requestFile(c.dir, "prewarm-second")), true, "preparation does not claim the request");
	assert.deepEqual(c.calls, [], "neither the withdrawn request nor the unprepared replacement may reach setModel");
	releaseSecond();
	await acked(c, "prewarm-second");
	assert.deepEqual(c.calls, [["setModel", "q/c"]]);
	assert.equal(existsSync(ackFile(c.dir, "prewarm-first")), false);
	ok("credentials: a replacement gets its own preparation before the claim and the gate");
	await finish();
}

// 2. Busy: never inside a run. turn_end is not a boundary; only settled idle is.
{
	const c = fresh({ idle: false });
	await start(c);
	ask(c, "r2", "p/b", "high");
	await sleep(300);
	assert.deepEqual(c.calls, [], "a busy session must not be touched");
	assert.equal(existsSync(requestFile(c.dir, "r2")), true, "the request stays queued, unclaimed, while the run is open");
	await c.fire("turn_end", { turnIndex: 0 });
	await c.fire("turn_end", { turnIndex: 1 });
	await c.fire("agent_end", { willContinue: false });
	assert.deepEqual(c.calls, [], "a terminal agent_end that still reads busy applies nothing");
	assert.equal(existsSync(requestFile(c.dir, "r2")), true, "and the request is not silently dropped");

	await c.fire("agent_start");
	c.state.idle = true;
	ask(c, "paused", "p/b", "high", { requestedAtMs: Date.now() + 100 });
	await sleep(150);
	assert.deepEqual(c.calls, [], "an open run blocks the watcher even when the context looks idle");
	await c.fire("agent_end", { willContinue: true });
	writeFileSync(`${c.dir}/paused-watcher-trigger`, "");
	await sleep(150);
	assert.deepEqual(c.calls, [], "a continuing agent_end blocks the watcher while the run is paused");
	assert.equal(existsSync(requestFile(c.dir, "paused")), true);
	await c.fire("agent_end", { willContinue: false });
	await acked(c, "paused");
	assert.equal(readAck(c.dir, "r2").outcome, "superseded");
	const ack = readAck(c.dir, "paused");
	assert.equal(ack.outcome, "applied");
	assert.equal(ack.boundary, "agent_end");
	assert.deepEqual(ack.after, { model: "p/b", thinking: "high" });
	ok("busy: the run finishes on the old model; the request applies only at settled idle");
	await finish();
}

// 3. Queued messages mean a run is about to start: the apply waits for them.
{
	const c = fresh({ pending: true });
	await start(c);
	ask(c, "r3", "p/b");
	await sleep(250);
	assert.deepEqual(c.calls, [], "a session with queued messages must not be switched");
	assert.equal(existsSync(requestFile(c.dir, "r3")), true);
	c.state.pending = false;
	await c.fire("agent_end", { willContinue: false });
	await acked(c, "r3");
	assert.equal(readAck(c.dir, "r3").outcome, "applied");
	ok("pending messages: an idle session with queued steers or follow-ups is not switched until they are gone");
	await finish();
}

// 4. The gate: a prompt that starts mid-switch is held until the switch is done.
{
	const c = fresh();
	await start(c);
	let release;
	c.state.hold = new Promise((resolve) => {
		release = resolve;
	});
	ask(c, "r4", "p/b", "high");
	await waitFor(() => c.calls.some(([name]) => name === "setModel"), "the switch to reach setModel");
	const prompt = settled(c.fire("before_agent_start", { prompt: "go" }));
	await sleep(250);
	assert.equal(prompt.done, false, "a prompt's first provider request must wait while the model is half switched");
	assert.equal(c.state.current, "p/a", "the model has not changed yet");
	release();
	await acked(c, "r4");
	await waitFor(() => prompt.done, "the held prompt to proceed");
	assert.equal(c.state.current, "p/b", "the held prompt proceeds only on the new model");
	assert.equal(c.state.thinking, "high");
	assert.equal(readAck(c.dir, "r4").raced, false, "a held prompt is not a race");
	const free = settled(c.fire("before_agent_start", { prompt: "again" }));
	await sleep(30);
	assert.equal(free.done, true, "with no switch applying, a prompt is never held");
	ok("gate: before_agent_start holds a prompt's first request across both writes and releases it on the new model");
	await finish();
}

// 5. The witness: a provider request prepared mid-switch is reported, never claimed clean.
{
	const c = fresh();
	await start(c);
	let release;
	c.state.hold = new Promise((resolve) => {
		release = resolve;
	});
	ask(c, "r5", "p/b");
	await waitFor(() => c.calls.some(([name]) => name === "setModel"), "the switch to reach setModel");
	await c.fire("context", { messages: [] });
	release();
	await acked(c, "r5");
	const ack = readAck(c.dir, "r5");
	assert.equal(ack.outcome, "applied");
	assert.equal(ack.raced, true, "a provider request prepared while the switch applied must be reported");
	assert.deepEqual(ack.after, { model: "p/b", thinking: "low" }, "the readback still reports the live state");
	const child = fresh();
	await start(child);
	let childRelease;
	child.state.hold = new Promise((resolve) => {
		childRelease = resolve;
	});
	ask(child, "r5b", "p/b");
	await waitFor(() => child.calls.some(([name]) => name === "setModel"), "the second switch to reach setModel");
	await child.fire("context", { messages: [] }, { ...child.ctx, agent: { kind: "sub" } });
	childRelease();
	await acked(child, "r5b");
	assert.equal(readAck(child.dir, "r5b").raced, false, "a subagent's provider request is not the main session's race");
	ok("witness: a main-session provider request during the apply sets raced=true; a subagent's does not");
	await finish();
}

// 6. The hold is capped: a setter that never returns cannot freeze every prompt, and still reports.
{
	const realSetTimeout = globalThis.setTimeout;
	globalThis.setTimeout = (callback, ms, ...rest) => realSetTimeout(callback, ms === 10000 ? 60 : ms, ...rest);
	try {
		const c = fresh();
		await start(c);
		let release;
		c.state.hold = new Promise((resolve) => {
			release = resolve;
		});
		ask(c, "r6", "p/b");
		await waitFor(() => c.calls.some(([name]) => name === "setModel"), "the switch to reach setModel");
		const prompt = settled(c.fire("before_agent_start", { prompt: "go" }));
		await waitFor(() => prompt.done, "the capped hold to release the prompt");
		assert.equal(existsSync(ackFile(c.dir, "r6")), false, "the setter is still running, so there is no result yet");
		await c.fire("agent_start");
		await c.fire("context", { messages: [] });
		ask(c, "r6-next", "q/c");
		const terminal = settled(c.fire("agent_end", { willContinue: false }));
		await waitFor(() => terminal.done, "the next run's terminal event to return while the setter is outstanding");
		assert.deepEqual(c.calls, [["setModel", "p/b"]], "the next apply stays serialized after the gate cap");
		release();
		await acked(c, "r6");
		await acked(c, "r6-next");
		assert.deepEqual(c.calls, [["setModel", "p/b"], ["setModel", "q/c"]]);
		const ack = readAck(c.dir, "r6");
		assert.equal(ack.outcome, "applied", "the late setter still publishes its own acknowledgement");
		assert.equal(ack.raced, true, "and raced covers the whole apply, not just the capped hold");
		ok("cap: a hung setter releases the gate at the cap, then reports its late result with raced=true");
		await finish();
	} finally {
		globalThis.setTimeout = realSetTimeout;
	}
}

// 7. The doorbell holds its dispatch while a switch applies, then delivers.
const doorbellFor = (dir) => {
	const base = dir.replace(/\.requests$/, "");
	const sent = [];
	const turnHandlers = new Map();
	const bell = installTaskInboxDoorbell(
		{
			sendMessage: (message) => {
				sent.push(message);
			},
			on: (event, handler) => turnHandlers.set(event, handler),
		},
		{ inboxDir: `${base}.inbox`, readyMarker: base, turnGraceMs: 100000 },
	);
	assert.equal(bell.activate(), true);
	return { bell, sent, turnHandlers, requests: `${base}.requests` };
};
{
	const dir = `${process.env.TMP_ROOT}/bell-hold.requests`;
	const c = fresh({}, "g1", dir);
	const door = doorbellFor(dir);
	await start(c);
	let release;
	c.state.hold = new Promise((resolve) => {
		release = resolve;
	});
	ask(c, "r7", "p/b");
	await waitFor(() => c.calls.some(([name]) => name === "setModel"), "the switch to reach setModel");
	writeFileSync(`${door.requests}/request.1.pending`, "wake the worker\n");
	await sleep(300);
	assert.equal(door.sent.length, 0, "a doorbell wake must not start a turn while the model is half switched");
	assert.equal(existsSync(`${door.requests}/request.1.pending`), true, "the wake stays pending, not lost");
	release();
	await acked(c, "r7");
	await waitFor(() => door.sent.length === 1, "the held wake to be delivered after the switch");
	assert.equal(readAck(c.dir, "r7").raced, false);
	door.bell.retire();
	ok("doorbell: a wake that arrives during the apply is held, not lost, and delivered after the gate releases");
	await finish();
}

// 8. A wake already sent but without a turn yet still reads idle: the switch waits for it.
{
	const dir = `${process.env.TMP_ROOT}/bell-busy.requests`;
	const c = fresh({}, "g1", dir);
	const door = doorbellFor(dir);
	await start(c);
	writeFileSync(`${door.requests}/request.1.pending`, "wake the worker\n");
	await waitFor(() => door.sent.length === 1, "the doorbell to send its wake");
	ask(c, "r8", "p/b");
	await sleep(300);
	assert.deepEqual(c.calls, [], "a switch must not apply between a doorbell wake and its turn");
	assert.equal(existsSync(requestFile(c.dir, "r8")), true);
	c.state.idle = false;
	await c.fire("agent_start");
	door.turnHandlers.get("turn_start")();
	await sleep(150);
	assert.equal(existsSync(requestFile(c.dir, "r8")), true, "opening the doorbell's turn must leave the switch queued");
	assert.deepEqual(c.calls, [], "the doorbell run keeps the old model");
	c.state.idle = true;
	await c.fire("agent_end", { willContinue: false });
	await acked(c, "r8");
	assert.equal(readAck(c.dir, "r8").outcome, "applied");
	door.bell.retire();
	ok("doorbell: a switch waits for a wake that has not opened its turn, and applies when the doorbell settles");
	await finish();
}

// 9. Refusals are typed, and none of them changes the live session.
const refusals = [
	["unknown-model", {}, "nowhere/nothing", null, "an unknown model"],
	["no-credentials", {}, "locked/d", null, "a known model this session has no credentials for"],
	["no-credentials", { setModelResult: false }, "p/b", null, "a model whose key does not resolve"],
	["no-credentials", { setModelThrows: "No API key for p/b" }, "p/b", null, "a setModel that throws a missing-key error"],
	["set-model-failed", { setModelThrows: "provider exploded" }, "p/b", null, "a setModel that throws something else"],
	["model-mismatch", { resolveOverride: { "p/b": "q/c" } }, "p/b", null, "a spec that resolves to a different model"],
	["effort-unsupported", {}, "p/b", "max", "an effort the target model does not support"],
];
for (const [reason, options, target, effort, what] of refusals) {
	const c = fresh(options);
	await start(c);
	ask(c, "rf", target, effort);
	await acked(c, "rf");
	const ack = readAck(c.dir, "rf");
	assert.equal(ack.outcome, "refused", what);
	assert.equal(ack.reason, reason, what);
	assert.equal(ack.modelChanged, false, what);
	assert.deepEqual(ack.after, ack.before, what);
	assert.equal(c.state.current, "p/a", what);
	assert.equal(c.state.thinking, "low", what);
	assert.equal(c.calls.some(([name]) => name === "setThinkingLevel"), false, `${what}: thinking untouched`);
	ok(`refused ${reason}: ${what}; the live model and thinking level are untouched`);
	await finish();
}

// 10. Partial: the model switched, the thinking level did not - reported, never rolled back.
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
	assert.equal(ack.modelChanged, true);
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

// 11. Superseded: only the newest request applies.
{
	const c = fresh({ idle: false });
	await start(c);
	ask(c, "old", "q/c", null, { requestedAtMs: 1000 });
	ask(c, "new", "p/b", null, { requestedAtMs: 2000 });
	c.state.idle = true;
	await c.fire("agent_end", { willContinue: false });
	await Promise.all([acked(c, "old"), acked(c, "new")]);
	assert.equal(readAck(c.dir, "old").outcome, "superseded");
	assert.equal(readAck(c.dir, "old").reason, "newer-request");
	assert.equal(readAck(c.dir, "new").outcome, "applied");
	assert.deepEqual(c.calls, [["setModel", "p/b"]], "the older request never touches the session");
	assert.equal(readAck(c.dir, "new").ackSequence > readAck(c.dir, "old").ackSequence, true, "receipts are ordered by sequence");
	ok("superseded: two queued requests apply only the newest");
	await finish();
}

// 12. A request for another incarnation, and a malformed one, are refused.
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

// 13. A request withdrawn before the boundary can never apply.
{
	const c = fresh({ idle: false });
	await start(c);
	ask(c, "wd", "p/b");
	renameSync(requestFile(c.dir, "wd"), `${c.dir}/model-switch.wd.cancelled`);
	c.state.idle = true;
	await c.fire("agent_end", { willContinue: false });
	await sleep(150);
	assert.deepEqual(c.calls, []);
	assert.equal(existsSync(ackFile(c.dir, "wd")), false);
	assert.equal(c.state.current, "p/a");
	ok("withdrawn: a request renamed away before the boundary is never applied");
	await finish();
}

// 14. Only the main session answers, and only one instance owns a directory.
{
	const c = fresh({ idle: false });
	await start(c);
	ask(c, "own", "p/b");
	c.state.idle = true;
	await c.fire("agent_end", { willContinue: false }, { ...c.ctx, agent: { kind: "sub" } });
	assert.deepEqual(c.calls, [], "a subagent's run end must not apply the parent's request");
	const child = createHost({ catalog, available: ["p/a", "p/b", "q/c"], current: "p/a", idle: true });
	installTaskModelSwitch(child.pi, { requestDir: c.dir, spawnGen: c.spawnGen });
	await child.fire("session_start");
	await child.fire("agent_end", { willContinue: false });
	assert.deepEqual(child.calls, [], "a duplicate instance in the same process stays inert");
	await c.fire("agent_end", { willContinue: false });
	await acked(c, "own");
	assert.deepEqual(c.calls, [["setModel", "p/b"]]);
	ok("ownership: a subagent context and a duplicate instance never answer the worker's request");
	await finish();
}

// 15. Already on the target: acknowledged without touching the session.
{
	const c = fresh();
	await start(c);
	ask(c, "np", "p/a");
	await acked(c, "np");
	assert.equal(readAck(c.dir, "np").outcome, "applied");
	assert.equal(readAck(c.dir, "np").modelChanged, false);
	assert.deepEqual(c.calls, []);
	ok("no-op: a request for the live model applies without a setModel call");
	await finish();
}

process.exit(0);
JS
)
RC=$?
printf '%s\n' "$OUT"
[ "$RC" -eq 0 ] || fail "model-switch extension cases failed (exit $RC)"
