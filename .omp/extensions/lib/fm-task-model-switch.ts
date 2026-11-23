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

// Firstmate's in-session model switch for a live OMP worker.
//
// bin/fm-control.sh `switch-model` owns the verb; this file owns the wire
// contract and the extension side of it. Nothing is typed into the TUI: the
// request travels as files beside the inbox doorbell's request directory and
// is applied through OMP's documented extension API (ctx.models.resolve,
// pi.setModel, pi.setThinkingLevel), which is session-only - it does not
// rewrite global modelRoles and it appends a model-change entry to the session
// so a resume keeps the model. OMP's own /switch picker uses the same
// session-only path through AgentSession#setModelTemporary, which the
// extension API does not expose; pi.setModel is the equivalent it does.
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
// Timing. A request applies as soon as it is seen, whatever the worker is
// doing, exactly like the picker: the model request already in flight
// finishes on the old model and the next one uses the new model, even
// mid-task. Nothing waits for idle and nothing holds a turn off; a request is
// never delivered as a message.
//
// Acknowledgement. outcome is applied, partial (the model switched but the
// thinking level did not land as requested), refused (typed reason), or
// superseded (a newer request replaced it before it ran). It records the
// request id, the model and thinking level before and after (read back from the
// live session), and whether the model changed. Nothing is rolled back, so a
// partial or post-apply refusal reports the live state rather than claiming
// the prior one.

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
	models: {
		current: () => SwitchModel | undefined;
		resolve: (spec: string) => SwitchModel | undefined;
	};
	modelRegistry: { find: (provider: string, id: string) => SwitchModel | undefined };
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

type Outcome = "applied" | "partial" | "refused" | "superseded";
type Snapshot = { model: string | null; thinking: string | null };
type Request = {
	id: string;
	spawnGen: string;
	model: string;
	effort: string | null;
	requestedAtMs: number;
};
type Claim = { id: string; processing: string };
type AckTarget = Pick<Request, "id" | "model" | "effort">;

const ACK_NAME = /^model-switch\.[A-Za-z0-9._-]+\.ack\.json(?:\.folded)?$/;
const REQUEST_NAME = /^model-switch\.([A-Za-z0-9][A-Za-z0-9._-]{0,63})\.request\.json$/;
const OWNERS_KEY = Symbol.for("firstmate.task-model-switch.owners");
// OMP binds this extension again inside a native subagent's child session in
// the same process, and a runtime may re-evaluate this module per session, so
// the owner registry rides the shared symbol registry rather than module scope.
const registryHost = globalThis as unknown as Record<symbol, Map<string, object> | undefined>;
const owners: Map<string, object> = (registryHost[OWNERS_KEY] ??= new Map<string, object>());

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
	let active = false;
	let ackSequence = Date.now() * 1000;
	let mainCtx: SwitchContext | undefined;
	let watcher: FSWatcher | undefined;
	let chain: Promise<void> = Promise.resolve();

	const isMain = (ctx: SwitchContext | undefined): ctx is SwitchContext =>
		ctx !== undefined && ctx !== null && (ctx.agent?.kind === undefined || ctx.agent.kind === "main");
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
				target: { model: request.model, effort: request.effort },
				before,
				after,
				modelChanged: before.model !== after.model,
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
	// raised before the change: ctx.models.resolve searches only the models this
	// session has credentials for, and setModel checks the key again.
	const apply = async (request: Request, ctx: SwitchContext): Promise<boolean> => {
		const before = snapshot(ctx);
		const refuse = (reason: string, detail: string | null): boolean =>
			writeAck(request, "refused", before, snapshot(ctx), reason, detail);
		if (request.spawnGen !== spawnGen) {
			return refuse("stale-incarnation", `the request was written for worker generation ${request.spawnGen}, not ${spawnGen}`);
		}
		const slash = request.model.indexOf("/");
		const resolved = ctx.models.resolve(request.model);
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
				request, "refused", before, afterModel, "model-mismatch",
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
				return writeAck(request, "refused", before, afterThinking, "model-mismatch",
					`the live model reads ${afterThinking.model ?? "nothing"} after the thinking change`);
			}
			if (failure !== null) {
				return writeAck(request, "partial", before, afterThinking, "thinking-error", failure);
			}
			if (afterThinking.thinking !== request.effort) {
				return writeAck(
					request, "partial", before, afterThinking, "thinking-mismatch",
					`the live thinking level reads ${afterThinking.thinking ?? "nothing"}, not ${request.effort}`,
				);
			}
			return writeAck(request, "applied", before, afterThinking);
		}
		return writeAck(request, "applied", before, afterModel);
	};

	const claimPending = (): Claim[] => {
		const claims: Claim[] = [];
		for (const name of readdirSync(requestDir).sort()) {
			const match = REQUEST_NAME.exec(name);
			if (!match) continue;
			const processing = join(requestDir, `model-switch.${match[1]}.processing`);
			try {
				renameSync(join(requestDir, name), processing);
			} catch {
				// fm-control cancelled it first: it is never applied.
				continue;
			}
			claims.push({ id: match[1], processing });
		}
		return claims;
	};

	const drainOnce = async (ctx: SwitchContext): Promise<void> => {
		if (!active) return;
		const claims = claimPending();
		if (claims.length === 0) return;
		const valid: Array<{ request: Request; claim: Claim }> = [];
		for (const claim of claims) {
			const parsed = parseRequest(claim.id, readFileSync(claim.processing, "utf8"));
			if (typeof parsed === "string") {
				const now = snapshot(ctx);
				if (writeAck({ id: claim.id, model: "", effort: null }, "refused", now, now, "invalid-request", parsed)) {
					bestEffortUnlink(claim.processing);
				}
			} else {
				valid.push({ request: parsed, claim });
			}
		}
		valid.sort((a, b) => a.request.requestedAtMs - b.request.requestedAtMs || (a.request.id < b.request.id ? -1 : 1));
		const newest = valid.pop();
		for (const older of valid) {
			const now = snapshot(ctx);
			const detail = `request ${newest?.request.id} replaced it`;
			if (writeAck(older.request, "superseded", now, now, "newer-request", detail)) {
				bestEffortUnlink(older.claim.processing);
			}
		}
		if (!newest) return;
		let landed: boolean;
		try {
			landed = await apply(newest.request, ctx);
		} catch (error) {
			const now = snapshot(ctx);
			landed = writeAck(newest.request, "refused", now, now, "internal-error", String(error));
			journalFailure(journal, "apply", error);
		}
		if (landed) bestEffortUnlink(newest.claim.processing);
	};

	// Drains run one at a time, in arrival order.
	const drain = (ctx: SwitchContext): Promise<void> => {
		const run = chain.then(() => drainOnce(ctx));
		chain = run.catch(() => {});
		return run.catch((error: unknown) => journalFailure(journal, "drain", error));
	};

	const retire = (): void => {
		if (!active) return;
		active = false;
		watcher?.close();
		watcher = undefined;
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
			watcher = watch(requestDir, () => {
				if (mainCtx) void drain(mainCtx);
			});
			active = true;
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

	subscribe("session_start", async (_event: unknown, ctx: SwitchContext) => {
		if (!isMain(ctx)) return;
		if (activate(ctx)) await drain(ctx);
	});
	subscribe("session_shutdown", () => retire());
}
