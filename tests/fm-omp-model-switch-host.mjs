// A fake OMP extension host for the model-switch tests.
//
// It does not stub the code under test: it drives the REAL
// .omp/extensions/lib/fm-task-model-switch.ts through the event surface OMP
// gives an extension (pi.on, ctx.models, ctx.modelRegistry, pi.setModel,
// pi.setThinkingLevel), so the wire protocol and the boundary rule run for
// real and only OMP itself is faked. As in OMP, nothing here waits for an
// extension's turn_end handler: the extension can only act when the session is
// settled idle (state.idle, with state.pending false), never at a turn boundary. As a script it is the long-lived
// responder a worker's extension would be: tests/fm-control-switch-model.test.sh
// starts it against a task's request directory and steers it through files.
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const LIB = pathToFileURL(fileURLToPath(new URL("../.omp/extensions/lib/fm-task-model-switch.ts", import.meta.url))).href;

export const label = (model) => (model ? `${model.provider}/${model.id}` : null);
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function model(provider, id, efforts) {
	return efforts ? { provider, id, thinking: { efforts } } : { provider, id };
}

// catalog: every model the registry knows. available: the labels this session
// has credentials for (default: all). current/thinking: the starting live state.
export function createHost(options = {}) {
	const catalog = options.catalog ?? [];
	const available = new Set(options.available ?? catalog.map(label));
	// state.hold, when set to a promise, parks setModel until it settles - the
	// credential or metadata await a real setModel makes. state.pending stands
	// for OMP's queued steers and follow-ups (ctx.hasPendingMessages()).
	const state = {
		current: options.current ?? null,
		thinking: options.thinking ?? "low",
		idle: options.idle ?? true,
		pending: options.pending ?? false,
		hold: undefined,
	};
	const calls = [];
	const keyCalls = [];
	const handlers = new Map();
	const find = (provider, id) => catalog.find((m) => m.provider === provider && m.id === id);
	const ctx = {
		agent: { kind: options.kind ?? "main" },
		isIdle: () => state.idle,
		hasPendingMessages: () => state.pending,
		models: {
			current: () => catalog.find((m) => label(m) === state.current),
			// OMP's resolve is fuzzy and searches only authenticated models. A test
			// that needs a fuzzy answer passes resolveOverride: { spec: label|null }.
			resolve: (spec) => {
				if (options.resolveOverride && spec in options.resolveOverride) {
					const overridden = options.resolveOverride[spec];
					return overridden === null ? undefined : catalog.find((m) => label(m) === overridden);
				}
				return catalog.find((m) => label(m) === spec && available.has(label(m)));
			},
		},
		modelRegistry: {
			find,
			getApiKey: async (target) => {
				keyCalls.push(label(target));
				return options.apiKey === false ? undefined : "key";
			},
		},
	};
	const pi = {
		on(event, handler) {
			handlers.set(event, [...(handlers.get(event) ?? []), handler]);
		},
		async setModel(target) {
			calls.push(["setModel", label(target)]);
			if (state.hold) await state.hold;
			if (options.setModelDelayMs) await sleep(options.setModelDelayMs);
			if (options.setModelThrows) throw new Error(options.setModelThrows);
			if (options.setModelResult === false) return false;
			state.current = label(target);
			return true;
		},
		getThinkingLevel: () => state.thinking,
		setThinkingLevel(level) {
			calls.push(["setThinkingLevel", level]);
			if (options.setThinkingThrows) throw new Error(options.setThinkingThrows);
			state.thinking = options.clamp?.[level] ?? level;
		},
	};
	const fire = async (event, payload = {}, withCtx = ctx) => {
		for (const handler of handlers.get(event) ?? []) await handler(payload, withCtx);
	};
	return { pi, ctx, state, calls, keyCalls, fire };
}

export async function waitFor(predicate, what, timeoutMs = 4000) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (predicate()) return;
		await sleep(15);
	}
	throw new Error(`timed out waiting for ${what}`);
}

export const requestFile = (dir, id) => join(dir, `model-switch.${id}.request.json`);
export const ackFile = (dir, id) => join(dir, `model-switch.${id}.ack.json`);
export const readAck = (dir, id) => JSON.parse(readFileSync(ackFile(dir, id), "utf8"));

export function writeRequest(dir, { id, spawnGen, model: target, effort = null, requestedAtMs = Date.now() }) {
	mkdirSync(dir, { recursive: true });
	writeFileSync(requestFile(dir, id), `${JSON.stringify({
		schema: "fm-model-switch.request.v1", id, spawnGen, model: target, effort, requestedAtMs,
	})}\n`);
}

// Responder mode. Environment:
//   FM_HOST_REQUEST_DIR  the request directory (required)
//   FM_HOST_SPAWN_GEN    the generation this "incarnation" answers for
//   FM_HOST_CATALOG      JSON [{provider,id,efforts?}] - every known model
//   FM_HOST_AVAILABLE    JSON ["provider/id",...] - models with credentials
//   FM_HOST_CURRENT, FM_HOST_THINKING, FM_HOST_CLAMP (JSON), FM_HOST_SET_DELAY_MS
//   FM_HOST_BUSY=1       start mid-turn
//   FM_HOST_CONTROL_DIR  command files: busy, idle, pending, unpending, context
//                        (a provider request is prepared), before_agent_start,
//                        agent_end (settles idle, then the terminal event), quit
//   FM_HOST_LOG          one JSON line per host call
if (process.argv[2] === "responder") {
	const env = process.env;
	const requestDir = env.FM_HOST_REQUEST_DIR;
	const controlDir = env.FM_HOST_CONTROL_DIR;
	const catalog = JSON.parse(env.FM_HOST_CATALOG ?? "[]").map((m) => model(m.provider, m.id, m.efforts));
	const host = createHost({
		catalog,
		available: env.FM_HOST_AVAILABLE ? JSON.parse(env.FM_HOST_AVAILABLE) : undefined,
		current: env.FM_HOST_CURRENT,
		thinking: env.FM_HOST_THINKING,
		clamp: env.FM_HOST_CLAMP ? JSON.parse(env.FM_HOST_CLAMP) : undefined,
		idle: env.FM_HOST_BUSY !== "1",
		setModelDelayMs: Number(env.FM_HOST_SET_DELAY_MS ?? 0),
	});
	const log = (entry) => env.FM_HOST_LOG && appendFileSync(env.FM_HOST_LOG, `${JSON.stringify(entry)}\n`);
	for (const name of ["setModel", "setThinkingLevel"]) {
		const real = host.pi[name].bind(host.pi);
		host.pi[name] = async (...args) => {
			log({ call: name, args: args.map((a) => (typeof a === "object" ? label(a) : a)), idle: host.state.idle });
			return real(...args);
		};
	}
	const { installTaskModelSwitch } = await import(LIB);
	installTaskModelSwitch(host.pi, { requestDir, spawnGen: env.FM_HOST_SPAWN_GEN });
	mkdirSync(controlDir, { recursive: true });
	await host.fire("session_start");
	log({ event: "ready", pid: process.pid });
	for (;;) {
		for (const name of readdirSync(controlDir).sort()) {
			const path = join(controlDir, name);
			rmSync(path, { force: true });
			log({ event: "command", name });
			if (name === "busy") host.state.idle = false;
			else if (name === "idle") host.state.idle = true;
			else if (name === "pending") host.state.pending = true;
			else if (name === "unpending") host.state.pending = false;
			else if (name === "context") await host.fire("context", { messages: [] });
			else if (name === "before_agent_start") await host.fire("before_agent_start", { prompt: "" });
			else if (name === "agent_end") {
				host.state.idle = true;
				await host.fire("agent_end", { willContinue: false });
			} else if (name === "quit") {
				await host.fire("session_shutdown");
				process.exit(0);
			}
		}
		if (!existsSync(controlDir)) process.exit(0);
		await sleep(20);
	}
}
