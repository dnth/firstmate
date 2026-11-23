import {
	type FSWatcher,
	existsSync,
	mkdirSync,
	readFileSync,
	readdirSync,
	renameSync,
	unlinkSync,
	watch,
	writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { turnAdmissionGate } from "./fm-task-inbox-doorbell.ts";

// Firstmate's in-session model switch for a live OMP worker.
//
// bin/fm-control.sh `switch-model` owns the verb; this file owns the wire
// contract and the extension side of it. Nothing is typed into the TUI: the
// request travels as files beside the inbox doorbell's request directory and
// is applied through OMP's documented extension API (ctx.models.resolve,
// pi.setModel, pi.setThinkingLevel), which is session-only - it does not
// rewrite global modelRoles and it appends a model-change entry to the session
// so a resume keeps the model.
//
// Files in <requestDir> (the doorbell's `<task>.omp-doorbell-ready.requests`;
// every name carries the model-switch. prefix, so the doorbell never sees them):
//   model-switch.ready              this extension's activation: pid, spawnGen
//   model-switch.<id>.request.json  a pending request, published atomically
//   model-switch.<id>.processing    the request, claimed by this extension
//   model-switch.<id>.cancelled     the request, cancelled by fm-control
//   model-switch.<id>.ack.json      the result, published atomically
//   model-switch.failed             why activation failed, when it did
//
// A request is in exactly one state. The claim and the cancel are both an
// atomic rename away from the pending name, so exactly one of them wins: a
// request that fm-control renamed to .cancelled can never be applied, and a
// request that was claimed can no longer be cancelled - its only remaining
// outcome is its acknowledgement, which a waiter that timed out reads later.
//
// Boundary. A request applies only at settled idle: from the watcher while
// ctx.isIdle() reads true, or from the terminal agent_end, which OMP emits
// once the session is quiet. A busy worker finishes its whole run on the old
// model and the request applies afterwards. turn_end is not a boundary: OMP
// does not await extension turn_end handlers, so the loop issues the next
// provider request while a switch is still running. A request that arrives
// mid-run waits for settled idle and is never delivered as a message.
//
// Admission gate. OMP gives an extension no lock against a turn starting while
// setModel awaits credentials and model metadata, so the apply is one critical
// section holding a process-global gate (Symbol.for("firstmate.turn-admission")).
// The gate holds every turn start the extension API can reach: this module's
// before_agent_start handler waits on it, and fm-task-inbox-doorbell.ts defers
// its dispatch while it is held and reports through gate.busy a wake it sent
// that has not opened a turn yet. Entry also needs an empty message queue.
// Credentials are resolved before entering, and the hold is capped well inside
// OMP's 30 s handler limit. A turn OMP starts on its own (a job result, a
// retry, an IRC wake) bypasses both holds, so the context handler counts every
// provider request prepared by the main session and the acknowledgement
// carries raced=true when one was prepared while the switch applied.
//
// Acknowledgement. outcome is applied, partial (the model switched but the
// thinking level did not land as requested), refused (typed reason), or
// superseded (a newer request replaced it before it ran). It records the
// request id, the model and thinking level before and after (read back from the
// live session), whether the model changed, and raced. Nothing is rolled back,
// so a partial or post-apply refusal reports the live state rather than
// claiming the prior one.

export const FM_MODEL_SWITCH_ACK_SCHEMA = "fm-model-switch.ack.v1";
export const FM_MODEL_SWITCH_READY_SCHEMA = "fm-model-switch.ready.v1";
export const FM_MODEL_SWITCH_REQUEST_SCHEMA = "fm-model-switch.request.v1";
export const FM_MODEL_SWITCH_EFFORTS: readonly string[] = ["low", "medium", "high", "xhigh", "max"];

type SwitchModel = {
	provider: string;
	id: string;
	thinking?: { efforts?: readonly string[] };
};

// The slice of the extension context this module reads. ctx.models is the
// documented read-only facade; ctx.modelRegistry tells an unknown model apart
// from one that exists but has no credentials, because resolve only searches
// the authenticated set.
type SwitchContext = {
	agent?: { kind?: string };
	isIdle: () => boolean;
	hasPendingMessages?: () => boolean;
	models: {
		current: () => SwitchModel | undefined;
		resolve: (spec: string) => SwitchModel | undefined;
	};
	modelRegistry: {
		find: (provider: string, id: string) => SwitchModel | undefined;
		getApiKey?: (model: SwitchModel) => Promise<unknown>;
	};
};

// Method syntax keeps setModel and setThinkingLevel bivariant, so the real
// ExtensionAPI - whose setModel takes OMP's full Model - is assignable. `on` is
// typed loosely because OMP declares one overload per event name, which no
// single signature can express; install narrows it where it is used.
type ModelSwitchApi = {
	setModel(model: SwitchModel): Promise<boolean>;
	getThinkingLevel(): string | undefined;
	setThinkingLevel(level: string): void;
	on?: unknown;
};

export type TaskModelSwitchOptions = {
	requestDir: string;
	// The generation fm-spawn minted for this incarnation. A request carrying
	// another one was written for a different worker and is refused.
	spawnGen: string;
};

export type TaskModelSwitchContext = SwitchContext;

type Boundary = "idle" | "agent_end";
type Outcome = "applied" | "partial" | "refused" | "superseded";
type Snapshot = { model: string | null; thinking: string | null };
type Request = {
	id: string;
	spawnGen: string;
	model: string;
	effort: string | null;
	requestedAtMs: number;
};
type Pending = { id: string; parsed: Request | string };
type AckTarget = Pick<Request, "id" | "model" | "effort">;

const ACK_NAME = /^model-switch\.[A-Za-z0-9._-]+\.ack\.json(?:\.folded)?$/;
const REQUEST_NAME = /^model-switch\.([A-Za-z0-9][A-Za-z0-9._-]{0,63})\.request\.json$/;
const OWNERS_KEY = Symbol.for("firstmate.task-model-switch.owners");
// OMP binds this extension again inside a native subagent's child session in
// the same process, and a runtime may re-evaluate this module per session, so
// the owner registry rides the shared symbol registry rather than module scope.
const registryHost = globalThis as unknown as Record<symbol, Map<string, object> | undefined>;
const owners: Map<string, object> = (registryHost[OWNERS_KEY] ??= new Map<string, object>());

const GATE_CAP_MS = 10_000;

function labelOf(model: SwitchModel | undefined | null): string | null {
	return model ? `${model.provider}/${model.id}` : null;
}

function jsonField(value: object, key: string): unknown {
	return Reflect.get(value, key);
}

function bestEffortUnlink(path: string): void {
	try {
		unlinkSync(path);
	} catch {
		return;
	}
}

function publishJson(path: string, value: unknown): void {
	const staged = join(dirname(path), `.${path.slice(dirname(path).length + 1)}.staging.${process.pid}`);
	writeFileSync(staged, `${JSON.stringify(value)}\n`, { mode: 0o600 });
	renameSync(staged, path);
}

// Best-effort durable diagnosis: "<iso> <phase>: <error>". A failed journal
// write is swallowed - the journal explains failures, it must never become one.
function journalFailure(journal: string, phase: string, error: unknown): void {
	if (!journal.startsWith("/")) return;
	try {
		const reason = error instanceof Error ? (error.stack ?? error.message) : String(error);
		mkdirSync(dirname(journal), { recursive: true });
		const staged = `${journal}.staging.${process.pid}`;
		writeFileSync(staged, `${new Date().toISOString()} ${phase}: ${reason}\n`, { mode: 0o600 });
		renameSync(staged, journal);
	} catch {
		return;
	}
}

function parseRequest(id: string, text: string): Request | string {
	let raw: unknown;
	try {
		raw = JSON.parse(text);
	} catch {
		return "the request is not valid JSON";
	}
	if (raw === null || typeof raw !== "object" || jsonField(raw, "schema") !== FM_MODEL_SWITCH_REQUEST_SCHEMA) {
		return "the request does not carry the model-switch request schema";
	}
	const spawnGen = jsonField(raw, "spawnGen");
	const model = jsonField(raw, "model");
	const rawEffort = jsonField(raw, "effort");
	const requestedAtMs = Number(jsonField(raw, "requestedAtMs"));
	if (jsonField(raw, "id") !== id) return "the request id does not match its file name";
	if (typeof spawnGen !== "string" || spawnGen === "") return "the request names no worker generation";
	if (typeof model !== "string") return "the request names no model";
	const slash = model.indexOf("/");
	if (slash < 1 || slash === model.length - 1 || /\s/.test(model)) return "the model must be written provider/id";
	const effort = rawEffort === null || rawEffort === undefined ? null : rawEffort;
	if (effort !== null && (typeof effort !== "string" || !FM_MODEL_SWITCH_EFFORTS.includes(effort))) {
		return `the effort must be one of ${FM_MODEL_SWITCH_EFFORTS.join(", ")}`;
	}
	return { id, spawnGen, model, effort, requestedAtMs: Number.isFinite(requestedAtMs) ? requestedAtMs : 0 };
}

export function installTaskModelSwitch(
	omp: ModelSwitchApi,
	{ requestDir, spawnGen }: TaskModelSwitchOptions,
): void {
	const journal = join(requestDir, "model-switch.failed");
	if (!requestDir.startsWith("/") || spawnGen === "" || typeof omp.on !== "function") {
		journalFailure(journal, "install", new Error("model switch is unconfigured (requestDir/spawnGen unresolved or no event surface)"));
		return;
	}
	const subscribe: (event: string, handler: (event: never, ctx: never) => unknown) => void = omp.on.bind(omp);

	const readyFile = join(requestDir, "model-switch.ready");
	const ownerKey = resolve(readyFile);
	const ownerToken = {};
	const gate = turnAdmissionGate();
	let active = false;
	let runOpen = false;
	let ackSequence = Date.now() * 1000;
	let mainCtx: SwitchContext | undefined;
	let watcher: FSWatcher | undefined;
	let chain: Promise<void> = Promise.resolve();
	let sectionActivity: number | undefined;

	const isMain = (ctx: SwitchContext | undefined): ctx is SwitchContext =>
		ctx !== undefined && ctx !== null && (ctx.agent?.kind === undefined || ctx.agent.kind === "main");
	const idleNow = (ctx: SwitchContext): boolean => {
		try {
			return ctx.isIdle();
		} catch {
			return false;
		}
	};
	const snapshot = (ctx: SwitchContext): Snapshot => {
		let thinking: string | undefined;
		try {
			thinking = omp.getThinkingLevel();
		} catch {
			thinking = undefined;
		}
		return { model: labelOf(ctx.models.current()), thinking: thinking ? thinking : null };
	};

	// Publishes the acknowledgement and reports whether it landed. Without one
	// the claimed request stays claimed, which a waiter reports as
	// pending-unknown rather than as a result.
	const writeAck = (
		request: AckTarget,
		outcome: Outcome,
		boundary: Boundary,
		before: Snapshot,
		after: Snapshot,
		reason: string | null = null,
		detail: string | null = null,
	): boolean => {
		try {
			publishJson(join(requestDir, `model-switch.${request.id}.ack.json`), {
				schema: FM_MODEL_SWITCH_ACK_SCHEMA,
				id: request.id,
				spawnGen,
				pid: process.pid,
				outcome,
				reason,
				detail,
				boundary,
				target: { model: request.model, effort: request.effort },
				before,
				after,
				modelChanged: before.model !== after.model,
				raced: sectionActivity !== undefined && gate.activity !== sectionActivity,
				ackSequence: ++ackSequence,
			});
			return true;
		} catch (error) {
			journalFailure(journal, "ack", error);
			return false;
		}
	};

	// Resolve, switch the model, then the thinking level, reading everything back
	// from the live session. Every refusal that can be known before a change is
	// raised before the change.
	const apply = async (
		request: Request, resolved: SwitchModel | undefined, boundary: Boundary, ctx: SwitchContext,
	): Promise<boolean> => {
		const before = snapshot(ctx);
		const refuse = (reason: string, detail: string | null): boolean =>
			writeAck(request, "refused", boundary, before, snapshot(ctx), reason, detail);
		if (request.spawnGen !== spawnGen) {
			return refuse("stale-incarnation", `the request was written for worker generation ${request.spawnGen}, not ${spawnGen}`);
		}
		const slash = request.model.indexOf("/");
		if (!resolved) {
			const known = ctx.modelRegistry.find(request.model.slice(0, slash), request.model.slice(slash + 1));
			return labelOf(known) === request.model
				? refuse("no-credentials", `${request.model} exists but this session has no credentials for it`)
				: refuse("unknown-model", `${request.model} is not a model this OMP knows`);
		}
		if (labelOf(resolved) !== request.model) {
			return refuse("model-mismatch", `${request.model} resolves to ${labelOf(resolved)}; name the exact provider/id`);
		}
		const efforts = resolved.thinking?.efforts;
		if (request.effort !== null && Array.isArray(efforts) && efforts.length > 0 && !efforts.includes(request.effort)) {
			return refuse("effort-unsupported", `${request.model} supports ${efforts.join(", ")}, not ${request.effort}`);
		}
		if (before.model !== request.model) {
			let switched: boolean;
			try {
				switched = await omp.setModel(resolved);
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				return refuse(/api key|credential/i.test(message) ? "no-credentials" : "set-model-failed", message);
			}
			if (!switched) return refuse("no-credentials", `OMP has no usable credentials for ${request.model}`);
		}
		const afterModel = snapshot(ctx);
		if (afterModel.model !== request.model) {
			return writeAck(
				request, "refused", boundary, before, afterModel, "model-mismatch",
				`the live model reads ${afterModel.model ?? "nothing"} after the switch, not ${request.model}`,
			);
		}
		if (request.effort !== null) {
			let failure: string | null = null;
			try {
				omp.setThinkingLevel(request.effort);
			} catch (error) {
				failure = error instanceof Error ? error.message : String(error);
			}
			const afterThinking = snapshot(ctx);
			if (afterThinking.model !== request.model) {
				return writeAck(request, "refused", boundary, before, afterThinking, "model-mismatch",
					`the live model reads ${afterThinking.model ?? "nothing"} after the thinking change`);
			}
			if (failure !== null) {
				return writeAck(request, "partial", boundary, before, afterThinking, "thinking-error", failure);
			}
			if (afterThinking.thinking !== request.effort) {
				return writeAck(
					request, "partial", boundary, before, afterThinking, "thinking-mismatch",
					`the live thinking level reads ${afterThinking.thinking ?? "nothing"}, not ${request.effort}`,
				);
			}
			return writeAck(request, "applied", boundary, before, afterThinking);
		}
		return writeAck(request, "applied", boundary, before, afterModel);
	};

	const claim = (id: string): string | undefined => {
		const processing = join(requestDir, `model-switch.${id}.processing`);
		try {
			renameSync(join(requestDir, `model-switch.${id}.request.json`), processing);
			return processing;
		} catch {
			return undefined;
		}
	};

	// Settled idle: nothing running, nothing queued, no doorbell wake in flight,
	// and no switch already holding the gate.
	const quiet = (ctx: SwitchContext): boolean => {
		if (runOpen || gate.held || !idleNow(ctx)) return false;
		try {
			if (typeof ctx.hasPendingMessages === "function" && ctx.hasPendingMessages()) return false;
			for (const probe of gate.busy) if (probe()) return false;
		} catch {
			return false;
		}
		return true;
	};

	const readPending = (): { newest: Request | undefined; pending: Pending[] } => {
		let newest: Request | undefined;
		const pending: Pending[] = [];
		for (const name of readdirSync(requestDir).sort()) {
			const match = REQUEST_NAME.exec(name);
			if (!match) continue;
			let parsed: Request | string;
			try {
				parsed = parseRequest(match[1], readFileSync(join(requestDir, name), "utf8"));
			} catch {
				continue;
			}
			pending.push({ id: match[1], parsed });
			if (typeof parsed === "string") continue;
			if (
				!newest ||
				parsed.requestedAtMs > newest.requestedAtMs ||
				(parsed.requestedAtMs === newest.requestedAtMs && parsed.id > newest.id)
			) {
				newest = parsed;
			}
		}
		return { newest, pending };
	};

	const applyClaimed = async (
		{ newest, pending }: ReturnType<typeof readPending>, resolved: SwitchModel | undefined,
		boundary: Boundary, ctx: SwitchContext,
	): Promise<void> => {
		const selected = newest && claim(newest.id);
		if (newest && !selected) return;
		for (const { id, parsed } of pending) {
			if (id === newest?.id) continue;
			const processing = claim(id);
			if (!processing) continue;
			const now = snapshot(ctx);
			const landed = typeof parsed === "string"
				? writeAck({ id, model: "", effort: null }, "refused", boundary, now, now, "invalid-request", parsed)
				: writeAck(parsed, "superseded", boundary, now, now, "newer-request", `request ${newest?.id} replaced it`);
			if (landed) bestEffortUnlink(processing);
		}
		if (!newest || !selected) return;
		let landed: boolean;
		try {
			landed = await apply(newest, resolved, boundary, ctx);
		} catch (error) {
			const now = snapshot(ctx);
			landed = writeAck(newest, "refused", boundary, now, now, "internal-error", String(error));
			journalFailure(journal, "apply", error);
		}
		if (landed) bestEffortUnlink(selected);
	};

	// The critical section. The gate is taken before the first await, so no
	// turn start the extension API reaches can slip in between the quiet check
	// that admitted the caller and the first write. The hold is capped; a setter
	// that outlives the cap keeps running and still publishes its own
	// acknowledgement, with raced reflecting the whole apply.
	const runSection = async (work: () => Promise<void>): Promise<void> => {
		let release: () => void = () => {};
		gate.pending = new Promise<void>((settle) => {
			release = settle;
		});
		gate.held = true;
		sectionActivity = gate.activity;
		const done = work().finally(() => {
			sectionActivity = undefined;
		});
		let timer: ReturnType<typeof setTimeout> | undefined;
		const cap = new Promise<void>((settle) => {
			timer = setTimeout(settle, GATE_CAP_MS);
		});
		try {
			await Promise.race([done, cap]);
		} finally {
			clearTimeout(timer);
			gate.held = false;
			gate.pending = undefined;
			release();
			for (const wakeDoorbell of [...gate.onRelease]) {
				try {
					wakeDoorbell();
				} catch {
					continue;
				}
			}
		}
		await done;
	};

	const drainOnce = async (boundary: Boundary, ctx: SwitchContext): Promise<void> => {
		if (!active || !quiet(ctx)) return;
		const initial = readPending();
		if (initial.pending.length === 0) return;
		const target = initial.newest;
		const resolved = target?.spawnGen === spawnGen ? ctx.models.resolve(target.model) : undefined;
		if (target && resolved && labelOf(resolved) === target.model) {
			try {
				await ctx.modelRegistry.getApiKey?.(resolved);
			} catch {
				// setModel reports a credential failure as its typed refusal.
			}
		}
		if (!active || !quiet(ctx)) return;
		const batch = readPending();
		if (batch.pending.length === 0 || JSON.stringify(batch.newest) !== JSON.stringify(target)) return;
		await runSection(() => applyClaimed(batch, resolved, boundary, ctx));
	};

	// Drains run one at a time, in arrival order.
	const drain = (boundary: Boundary, ctx: SwitchContext): void => {
		chain = chain.then(() => drainOnce(boundary, ctx))
			.catch((error: unknown) => journalFailure(journal, "drain", error));
	};

	const wake = (): void => {
		if (mainCtx) drain("idle", mainCtx);
	};

	const retire = (): void => {
		if (!active) return;
		active = false;
		runOpen = false;
		watcher?.close();
		watcher = undefined;
		gate.onQuiet.delete(wake);
		try {
			const recorded: unknown = JSON.parse(readFileSync(readyFile, "utf8"));
			if (recorded !== null && typeof recorded === "object" && jsonField(recorded, "pid") === process.pid) {
				bestEffortUnlink(readyFile);
			}
		} catch {
			// A missing or foreign marker is not this instance's to retire.
		}
		if (owners.get(ownerKey) === ownerToken) owners.delete(ownerKey);
	};

	const activate = (ctx: SwitchContext): boolean => {
		if (active) return true;
		if (owners.has(ownerKey)) return false;
		try {
			mkdirSync(requestDir, { recursive: true, mode: 0o700 });
			for (const name of readdirSync(requestDir)) {
				if (!ACK_NAME.test(name)) continue;
				try {
					const receipt: unknown = JSON.parse(readFileSync(join(requestDir, name), "utf8"));
					if (receipt === null || typeof receipt !== "object") continue;
					const sequence = jsonField(receipt, "ackSequence");
					if (jsonField(receipt, "spawnGen") === spawnGen && typeof sequence === "number" && Number.isSafeInteger(sequence)) {
						ackSequence = Math.max(ackSequence, sequence);
					}
				} catch {
					continue;
				}
			}
			mainCtx = ctx;
			watcher = watch(requestDir, wake);
			active = true;
			gate.onQuiet.add(wake);
			owners.set(ownerKey, ownerToken);
			publishJson(readyFile, {
				schema: FM_MODEL_SWITCH_READY_SCHEMA,
				pid: process.pid,
				spawnGen,
				at: new Date().toISOString(),
			});
			if (existsSync(journal)) bestEffortUnlink(journal);
			return true;
		} catch (error) {
			journalFailure(journal, "activate", error);
			retire();
			return false;
		}
	};

	// Activation publishes the ready marker; requests are only written after it,
	// so nothing needs draining here.
	subscribe("session_start", (_event: unknown, ctx: SwitchContext) => {
		if (isMain(ctx)) activate(ctx);
	});
	subscribe("agent_start", (_event: unknown, ctx: SwitchContext) => {
		if (isMain(ctx) && active) runOpen = true;
	});
	subscribe("agent_end", (event: { willContinue?: boolean }, ctx: SwitchContext) => {
		if (!isMain(ctx) || !active) return;
		mainCtx = ctx;
		runOpen = event?.willContinue === true;
		if (!runOpen) drain("agent_end", ctx);
	});
	// Holds a prompt's first provider request while a switch is applying.
	subscribe("before_agent_start", async () => {
		while (gate.pending) await gate.pending;
	});
	// The witness: one count per provider request the main session prepares.
	subscribe("context", (_event: unknown, ctx: SwitchContext) => {
		if (isMain(ctx)) gate.activity += 1;
	});
	subscribe("session_shutdown", () => retire());
}
