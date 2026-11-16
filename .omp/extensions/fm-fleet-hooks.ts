// Fail-open fleet context hooks for OMP sessions.
// This adapter is intentionally separate from fm-primary-omp.ts, which owns
// native lifecycle and watcher integration.
//
// The turn-end handler keeps the primary's session todo in step with the board.
// OMP v18 exposes no extension API that sets the session todo list live: the
// only todo surfaces are the `todo_reminder` event (gated by `todo.reminders`,
// which Firstmate disables), `ExtensionAPI.appendEntry`, which writes a
// transcript entry that rehydrates only on branch/session transition, and the
// `/todo` command controller. The handler therefore works through the seam the
// brief allows instead: it compares the board's `fm-todo-project.sh --emit`
// projection with the last one offered to this session and injects exactly one
// bounded instruction carrying the projection. An unchanged board, an unusable
// projection, or an unreadable record injects nothing and never blocks a turn.
//
// Cost and identity: `--emit` drives tasks-axi and takes tens of seconds in a
// real home, so a turn first compares the board file's version (mtime, size) and
// the UTC date with the record, and only a changed board version pays for the
// projection. The pass runs unawaited because the injected instruction starts
// its own turn. The record lives in this home's private
// `state/omp-todo-autosync/<session-key>.json`, keyed by an opaque hash of the
// OMP session id, so sibling homes and sibling sessions never share it, and a
// worker whose todo belongs to its own task never touches it.
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { closeSync, constants, fstatSync, mkdirSync, openSync, readdirSync, readSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

export type ToolContent = { type: string; text?: string; [key: string]: unknown };

const SECRET_PATTERNS: Array<{ pattern: RegExp; label: string }> = [
	{ pattern: /\$ANSIBLE_VAULT;[^\r\n]+(?:\r?\n[0-9a-fA-F]{16,})+/g, label: "ANSIBLE_VAULT" },
	{ pattern: /\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|gl(?:pat|oas|rt|dt|cbt)-[A-Za-z0-9_-]{12,}|sk-(?:proj-)?[A-Za-z0-9_-]{16,})\b/g, label: "TOKEN" },
	{ pattern: /\bAKIA[0-9A-Z]{16}\b/g, label: "AWS_ACCESS_KEY" },
	{ pattern: /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/g, label: "BEARER" },
];

const NAMED_SECRET_PATTERN = /\b((?:[A-Za-z_][A-Za-z0-9_]*)?(?:KEY|SECRET|TOKEN|PASSWORD|PASS|CREDENTIAL)[A-Za-z0-9_]*)\s*=\s*(?:"((?:\\.|[^"\\\r\n]){8,})"|'((?:\\.|[^'\\\r\n]){8,})'|([^\s"'`]{8,}))/g;
const READ_ONLY_TIMEOUT_MS = 2000;
const SNAPSHOT_SCAN_TIMEOUT_MS = 5000;
const MAX_META_BYTES = 64 * 1024;
const MAX_COMMAND_OUTPUT_BYTES = 256 * 1024;

/** Redact only credential-shaped substrings, preserving ordinary prose. */
export function redactSecretText(text: string): string {
	let redacted = text;
	for (const { pattern, label } of SECRET_PATTERNS) {
		redacted = redacted.replace(pattern, `[REDACTED:${label}]`);
	}
	return redacted.replace(NAMED_SECRET_PATTERN, (_match, name: string) => `[REDACTED:${name}]`);
}

/** Return a rewritten content array, or undefined when no text changed. */
export function redactToolResultContent(content: readonly ToolContent[]): ToolContent[] | undefined {
	let changed = false;
	const rewritten = content.map((chunk) => {
		if (chunk.type !== "text" || typeof chunk.text !== "string") return chunk;
		const text = redactSecretText(chunk.text);
		if (text === chunk.text) return chunk;
		changed = true;
		return { ...chunk, text };
	});
	return changed ? rewritten : undefined;
}

/** Parse report-only fm-todo-project --check output into a bounded note. */
export function parseTodoCheckDrift(output: string): string | undefined {
	const findings: string[] = [];
	for (const rawLine of output.split(/\r?\n/)) {
		const line = rawLine.trim();
		if (!line) continue;
		if (line.startsWith("DRIFT ")) {
			findings.push(line);
			continue;
		}
		if (line.startsWith("DRIFT-CHECK-SKIPPED: ")) continue;
		throw new TypeError("drift output is malformed");
	}
	if (findings.length === 0) return undefined;
	const suffix = findings.length > 1 ? ` (+${findings.length - 1} more)` : "";
	const first = findings[0].slice(0, 220);
	return `Firstmate board drift: ${first}${suffix}`;
}

export type FleetMeta = {
	id: string;
	kind?: string;
	window?: string;
	project?: string;
	pr?: string;
};

export type FleetSnapshotInput = {
	metas?: readonly FleetMeta[];
	openDecisions?: readonly string[];
	todoProjection?: string;
	maxChars?: number;
};

export function parseTodoProjectionCounts(source: string): { ready: number; inFlight: number } {
	const projection = JSON.parse(source) as unknown;
	if (!Array.isArray(projection)) throw new TypeError("todo projection must be an array");
	let ready = 0;
	let inFlight = 0;
	for (const phase of projection) {
		if (!phase || typeof phase !== "object") throw new TypeError("todo phase must be an object");
		const record = phase as { phase?: unknown; items?: unknown };
		if (typeof record.phase !== "string" || !Array.isArray(record.items)) throw new TypeError("todo phase is malformed");
		if (!record.items.every((item) => typeof item === "string")) throw new TypeError("todo items must be strings");
		if (record.phase === "Ready") ready += record.items.length;
		if (record.phase === "Active") inFlight += record.items.length;
	}
	return { ready, inFlight };
}

function compact(value: string | undefined, fallback = "-"): string {
	const normalized = value?.trim();
	return normalized ? normalized.replace(/\s+/g, " ") : fallback;
}

export function boundSnapshotItems(items: readonly string[], maxChars: number): string {
	if (items.length === 0) return "none";
	const shown: string[] = [];
	for (let index = 0; index < items.length; index += 1) {
		const candidate = [...shown, items[index]].join(" ");
		const omitted = items.length - index - 1;
		const suffix = omitted > 0 ? ` …(+${omitted} omitted)` : "";
		if (`${candidate}${suffix}`.length > maxChars) break;
		shown.push(items[index]);
	}
	const omitted = items.length - shown.length;
	if (omitted === 0) return shown.join(" ");
	return `${shown.join(" ")}${shown.length > 0 ? " " : ""}…(+${omitted} omitted)`;
}

/** Build a bounded, deterministic fleet context line from read-only fixtures. */
export function buildFleetSnapshot(input: FleetSnapshotInput): string {
	const maxChars = Math.max(240, input.maxChars ?? 1200);
	const metas = [...(input.metas ?? [])].sort((a, b) => a.id.localeCompare(b.id));
	const rosterItems = metas.map((meta) => `${compact(meta.id)}(${compact(meta.kind, "crew")},${compact(meta.window)},${compact(meta.project)})`);
	const prItems = metas.filter((meta) => meta.pr).map((meta) => `${compact(meta.id)}=${compact(meta.pr)}`);
	const decisionItems = (input.openDecisions ?? []).map((decision) => compact(decision)).filter((decision) => decision !== "-");
	const counts = parseTodoProjectionCounts(input.todoProjection ?? "[]");
	const fixed = `Firstmate fleet snapshot: roster ; OPEN DECISIONS ; in-flight PRs ; backlog Ready=${counts.ready} In-flight=${counts.inFlight}`;
	const available = Math.max(0, maxChars - fixed.length);
	const rosterBudget = Math.floor(available * 0.4);
	const decisionBudget = Math.floor(available * 0.35);
	const prBudget = available - rosterBudget - decisionBudget;
	return `Firstmate fleet snapshot: roster ${boundSnapshotItems(rosterItems, rosterBudget)}; OPEN DECISIONS ${boundSnapshotItems(decisionItems, decisionBudget)}; in-flight PRs ${boundSnapshotItems(prItems, prBudget)}; backlog Ready=${counts.ready} In-flight=${counts.inFlight}`;
}

export function parseFleetMeta(id: string, source: string): FleetMeta {
	const values: Record<string, string> = {};
	for (const line of source.split(/\r?\n/)) {
		const separator = line.indexOf("=");
		if (separator <= 0) continue;
		values[line.slice(0, separator)] = line.slice(separator + 1);
	}
	return { id, kind: values.kind, window: values.window, project: values.project, pr: values.pr };
}

export function parseOpenDecisionRows(source: string): string[] {
	const decisions: string[] = [];
	for (const line of source.split(/\r?\n/)) {
		if (!line) continue;
		const fields = line.split("\t");
		if (fields.length < 4) throw new TypeError("open-decision row is malformed");
		const [id, key, verb, ...note] = fields;
		decisions.push(`${compact(id)}: ${compact(verb)} [key=${compact(key, "default")}]: ${compact(note.join("\t"))}`);
	}
	return decisions;
}

function runReadOnly(command: string, args: string[], extensionRoot: string, fmHome: string, timeoutMs = READ_ONLY_TIMEOUT_MS): Promise<string> {
	return new Promise((resolveOutput, rejectOutput) => {
		const child = spawn(command, args, {
			cwd: extensionRoot,
			detached: true,
			env: { ...process.env, FM_HOME: fmHome },
			stdio: ["ignore", "pipe", "pipe"],
		});
		const stdout: Buffer[] = [];
		const stderr: Buffer[] = [];
		let outputBytes = 0;
		let settled = false;
		const finish = (error?: Error, output?: string): void => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			if (error) rejectOutput(error);
			else resolveOutput(output ?? "");
		};
		const killGroup = (): void => {
			if (child.pid === undefined) throw new Error(`${command} did not start`);
			process.kill(-child.pid, "SIGKILL");
		};
		const capture = (target: Buffer[]) => (chunk: Buffer): void => {
			if (settled) return;
			outputBytes += chunk.length;
			if (outputBytes > MAX_COMMAND_OUTPUT_BYTES) {
				try {
					killGroup();
				} catch {
				}
				finish(new Error(`${command} output exceeded the limit`));
				return;
			}
			target.push(chunk);
		};
		child.stdout.on("data", capture(stdout));
		child.stderr.on("data", capture(stderr));
		child.once("error", (error) => finish(error));
		child.once("close", (status, signal) => {
			const stderrText = Buffer.concat(stderr).toString("utf8");
			if (status !== 0 || signal !== null || stderrText) {
				finish(new Error(`${command} failed`));
				return;
			}
			finish(undefined, Buffer.concat(stdout).toString("utf8"));
		});
		const timer = setTimeout(() => {
			try {
				killGroup();
				finish(new Error(`${command} timed out`));
			} catch (error) {
				finish(error instanceof Error ? error : new Error(`${command} timed out`));
			}
		}, timeoutMs);
	});
}

function readFleetMetaFile(path: string): string {
	const fd = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK | constants.O_NOFOLLOW);
	try {
		const stat = fstatSync(fd);
		if (!stat.isFile() || stat.size > MAX_META_BYTES) throw new TypeError("fleet metadata is not a bounded regular file");
		const buffer = Buffer.alloc(MAX_META_BYTES + 1);
		let length = 0;
		while (length < buffer.length) {
			const bytesRead = readSync(fd, buffer, length, buffer.length - length, null);
			if (bytesRead === 0) break;
			length += bytesRead;
		}
		if (length > MAX_META_BYTES) throw new TypeError("fleet metadata exceeds the size bound");
		return buffer.subarray(0, length).toString("utf8");
	} finally {
		closeSync(fd);
	}
}

async function readFleetSnapshot(extensionRoot: string, fmHome: string, state: string): Promise<string> {
	const metas: FleetMeta[] = [];
	for (const entry of readdirSync(state)) {
		if (!entry.endsWith(".meta")) continue;
		const id = entry.slice(0, -5);
		metas.push(parseFleetMeta(id, readFleetMetaFile(resolve(state, entry))));
	}
	const openDecisionRows = await runReadOnly("bash", ["-c", '. "$1/bin/fm-classify-lib.sh"; scan_open_decisions "$2"', "_", extensionRoot, state], extensionRoot, fmHome, SNAPSHOT_SCAN_TIMEOUT_MS);
	const todoProjection = await runReadOnly(resolve(extensionRoot, "bin/fm-todo-project.sh"), ["--emit"], extensionRoot, fmHome);
	return buildFleetSnapshot({ metas, openDecisions: parseOpenDecisionRows(openDecisionRows), todoProjection });
}

// =============================================================================
// Session-todo autosync
// =============================================================================

type TodoProjectionPhase = { phase: string; items: string[] };

// The projection is already bounded by fm-todo-project.sh (Active is complete,
// Ready is capped by FM_TODO_READY_MAX), so this only refuses a pathological
// board instead of truncating JSON the todo tool would then reject.
const TODO_AUTOSYNC_MAX_INSTRUCTION_CHARS = 8000;
const TODO_AUTOSYNC_STATE_DIR = "omp-todo-autosync";
// `--emit` drives tasks-axi and costs tens of seconds in a real home, so it is
// bounded generously and only a changed board pays it.
const TODO_AUTOSYNC_EMIT_TIMEOUT_MS = 30000;

/**
 * Parse `fm-todo-project.sh --emit` output.
 * Any shape other than a complete phased list is unusable, so the caller stays
 * silent rather than re-initializing the todo from a partial read.
 */
function parseTodoProjection(output: string): TodoProjectionPhase[] | undefined {
	let parsed: unknown;
	try {
		parsed = JSON.parse(output.trim());
	} catch {
		return undefined;
	}
	if (!Array.isArray(parsed)) return undefined;
	const phases: TodoProjectionPhase[] = [];
	for (const entry of parsed) {
		if (typeof entry !== "object" || entry === null || !("phase" in entry) || !("items" in entry)) return undefined;
		const { phase, items } = entry;
		if (typeof phase !== "string" || phase.length === 0) return undefined;
		if (!Array.isArray(items) || items.length === 0) return undefined;
		const phaseItems: string[] = [];
		for (const item of items) {
			if (typeof item !== "string" || item.length === 0) return undefined;
			phaseItems.push(item);
		}
		phases.push({ phase, items: phaseItems });
	}
	return phases;
}

/** Stable identity of a projection: the exact JSON the todo tool would receive. */
function todoProjectionHash(phases: readonly TodoProjectionPhase[]): string {
	return createHash("sha256").update(JSON.stringify(phases)).digest("hex");
}

/** One bounded instruction that re-initializes the todo from the projection. */
function buildTodoAutosyncInstruction(phases: readonly TodoProjectionPhase[]): string | undefined {
	const list = JSON.stringify(phases);
	const instruction = [
		"Firstmate board projection changed. Re-initialize the session todo list now with the todo tool, then continue:",
		`{"op":"init","list":${list}}`,
		"This is the board projection, not a new request; the board stays the source of truth.",
	].join("\n");
	return instruction.length <= TODO_AUTOSYNC_MAX_INSTRUCTION_CHARS ? instruction : undefined;
}

// One private record per session: the projection hash last observed or offered
// plus the board version that produced it. The version lets an unchanged board
// skip the projection subprocess entirely, because `--emit` costs seconds in a
// real home and a turn-end hook must not pay that on every turn.
type TodoAutosyncRecord = {
	hash?: string;
	liveTodoHash: string;
	boardMtimeMs: number;
	boardSize: number;
	dateKey: string;
};

function readTodoAutosyncRecord(path: string): TodoAutosyncRecord | undefined {
	let parsed: unknown;
	try {
		parsed = JSON.parse(readFleetMetaFile(path));
	} catch {
		return undefined;
	}
	if (typeof parsed !== "object" || parsed === null) return undefined;
	if (!("boardMtimeMs" in parsed) || !("boardSize" in parsed) || !("dateKey" in parsed)) return undefined;
	const { boardMtimeMs, boardSize, dateKey } = parsed;
	if (typeof boardMtimeMs !== "number" || !Number.isFinite(boardMtimeMs)) return undefined;
	if (typeof boardSize !== "number" || !Number.isFinite(boardSize)) return undefined;
	if (typeof dateKey !== "string") return undefined;
	const hash = "hash" in parsed ? parsed.hash : undefined;
	if (hash !== undefined && typeof hash !== "string") return undefined;
	const liveTodoHash = "liveTodoHash" in parsed ? parsed.liveTodoHash : "";
	if (typeof liveTodoHash !== "string") return undefined;
	return { hash: hash === "" ? undefined : hash, liveTodoHash, boardMtimeMs, boardSize, dateKey };
}

function writeTodoAutosyncRecord(path: string, record: TodoAutosyncRecord): boolean {
	const temporary = `${path}.tmp.${process.pid}.${randomUUID()}`;
	try {
		mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
		writeFileSync(temporary, `${JSON.stringify(record)}\n`, { mode: 0o600, flag: "wx" });
		renameSync(temporary, path);
		return true;
	} catch {
		try {
			unlinkSync(temporary);
		} catch {
		}
		return false;
	}
}

/** Session identity when the OMP context exposes one, without trusting its shape. */
function todoAutosyncSessionId(ctx: unknown): string {
	if (typeof ctx !== "object" || ctx === null || !("sessionManager" in ctx)) return "";
	const manager = ctx.sessionManager;
	if (typeof manager !== "object" || manager === null || !("getSessionId" in manager)) return "";
	const getSessionId = manager.getSessionId;
	if (typeof getSessionId !== "function") return "";
	const sessionId: unknown = getSessionId.call(manager);
	return typeof sessionId === "string" ? sessionId : "";
}

function liveTodoProjection(ctx: any): TodoProjectionPhase[] | undefined {
	try {
		const branch: unknown = ctx?.sessionManager?.getBranch?.();
		if (!Array.isArray(branch)) return undefined;
		for (let index = branch.length - 1; index >= 0; index--) {
			const entry = branch[index];
			let phases: unknown;
			try {
				if (entry?.type === "custom" && entry.customType === "user_todo_edit") {
					phases = entry.data?.phases;
				} else if (entry?.type === "message" && entry.message?.role === "toolResult"
					&& entry.message.toolName === "todo" && entry.message.isError !== true) {
					phases = entry.message.details?.phases;
				} else {
					continue;
				}
				if (!Array.isArray(phases)) continue;
				const projection: TodoProjectionPhase[] = [];
				for (const phase of phases) {
					if (typeof phase?.name !== "string" || !Array.isArray(phase.tasks)) throw new Error();
					const items: string[] = [];
					for (const task of phase.tasks) {
						if (typeof task?.content !== "string" || typeof task.status !== "string") throw new Error();
						items.push(task.content);
					}
					projection.push({ phase: phase.name, items });
				}
				return projection;
			} catch {
				continue;
			}
		}
	} catch {
	}
	return undefined;
}

/** Board version a projection was computed from; `undefined` when it is unusable. */
function boardVersion(boardPath: string): { boardMtimeMs: number; boardSize: number } | undefined {
	try {
		const stats = statSync(boardPath);
		return stats.isFile() ? { boardMtimeMs: stats.mtimeMs, boardSize: stats.size } : undefined;
	} catch {
		return undefined;
	}
}

// Only a genuine home owner re-initializes the fleet todo. An fm-spawn'd
// worker's OMP session runs from a disposable worktree of this repo, carries
// its own task todo list, and must never have it replaced by the board.
// Only a positive verdict is cached: a plain launch can begin before this home
// has a state directory, and that first-turn refusal must not stick.
let todoAutosyncScope = false;
function todoAutosyncScopeApplies(extensionRoot: string, state: string): boolean {
	if (todoAutosyncScope) return true;
	if (process.env.FM_TASK_ID) return false;
	const result = spawnSync(
		"bash",
		["-c", '. "$1/bin/fm-primary-scope-lib.sh"; fm_primary_scope_matches "$1" "$2"', "fm-omp-todo-autosync-scope", extensionRoot, state],
		{ stdio: "ignore" },
	);
	todoAutosyncScope = result.status === 0;
	return todoAutosyncScope;
}

function todoAutosyncOwnsLock(state: string): boolean {
	try {
		const lockPid = readFleetMetaFile(resolve(state, ".lock")).trim();
		if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return false;
		let pid = String(process.pid);
		for (let depth = 0; depth < 8; depth++) {
			if (pid === lockPid) return true;
			const parent = spawnSync("ps", ["-o", "ppid=", "-p", pid], {
				encoding: "utf8", timeout: READ_ONLY_TIMEOUT_MS,
			});
			if (parent.status !== 0) return false;
			pid = parent.stdout.trim();
			if (!/^[0-9]+$/.test(pid) || pid === "1") break;
		}
	} catch {
	}
	return false;
}

let todoAutosyncGeneration = 0;

// Sessions whose projection pass is still running, and the projection each
// session was already offered. The first prevents a slow projection from
// overlapping itself when turns arrive faster than `--emit` returns; the second
// bounds repeats even when the record cannot be written.
const autosyncInFlight = new Set<string>();
const offeredProjections = new Map<string, string>();

async function syncSessionTodo(pi: ExtensionAPI, ctx: unknown): Promise<void> {
	try {
		const extensionRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
		const fmHome = process.env.FM_HOME || extensionRoot;
		const state = process.env.FM_STATE_OVERRIDE || resolve(fmHome, "state");
		if (!todoAutosyncScopeApplies(extensionRoot, state) || !todoAutosyncOwnsLock(state)) return;
		const data = process.env.FM_DATA_OVERRIDE || resolve(fmHome, "data");
		const boardPath = resolve(data, "backlog.md");
		let version = boardVersion(boardPath);
		if (!version) return;
		const sessionId = todoAutosyncSessionId(ctx);
		const generation = todoAutosyncGeneration;
		const passIsCurrent = () => generation === todoAutosyncGeneration
			&& todoAutosyncSessionId(ctx) === sessionId && todoAutosyncOwnsLock(state);
		const recordPath = resolve(state, TODO_AUTOSYNC_STATE_DIR, `${createHash("sha256").update(sessionId || "session").digest("hex").slice(0, 16)}.json`);
		const memoryKey = `${recordPath}\u0000${sessionId}`;
		if (autosyncInFlight.has(memoryKey)) return;
		// A date-gated hold can change the Ready phase with no board write, so a
		// new UTC day also earns one recomputation.
		let dateKey = new Date().toISOString().slice(0, 10);
		let previous = readTodoAutosyncRecord(recordPath);
		const initialLive = liveTodoProjection(ctx);
		const initialLiveHash = initialLive ? todoProjectionHash(initialLive) : "unreadable";
		if (previous && previous.boardMtimeMs === version.boardMtimeMs && previous.boardSize === version.boardSize && previous.dateKey === dateKey && previous.liveTodoHash === initialLiveHash) return;
		autosyncInFlight.add(memoryKey);
		try {
			for (let round = 0; round < 3; round++) {
				let phases: TodoProjectionPhase[] | undefined;
				try {
					const output = await runReadOnly(resolve(extensionRoot, "bin/fm-todo-project.sh"), ["--emit"], extensionRoot, fmHome, TODO_AUTOSYNC_EMIT_TIMEOUT_MS);
					phases = parseTodoProjection(output);
				} catch {
				}
				if (!passIsCurrent()) return;
				const currentVersion = boardVersion(boardPath);
				const currentDate = new Date().toISOString().slice(0, 10);
				if (!currentVersion) return;
				if (currentVersion.boardMtimeMs !== version.boardMtimeMs
					|| currentVersion.boardSize !== version.boardSize || currentDate !== dateKey) {
					version = currentVersion;
					dateKey = currentDate;
					continue;
				}
				const live = liveTodoProjection(ctx);
				const liveTodoHash = live ? todoProjectionHash(live) : "unreadable";
				const record: TodoAutosyncRecord = { ...previous, ...version, dateKey, liveTodoHash };
				if (phases) {
					const hash = todoProjectionHash(phases);
					const offeredIdentity = `${hash}:${liveTodoHash}`;
					if (liveTodoHash === hash
						|| (previous?.hash === hash && previous.liveTodoHash === liveTodoHash)
						|| offeredProjections.get(memoryKey) === offeredIdentity) {
						record.hash = hash;
						offeredProjections.set(memoryKey, offeredIdentity);
					} else {
						const content = buildTodoAutosyncInstruction(phases);
						if (content) {
							if (!passIsCurrent()) return;
							pi.sendMessage(
								{
									customType: "firstmate-todo-projection",
									content,
									display: false,
									attribution: "agent",
									details: { kind: "todo-projection", runtime: "omp" },
								},
								{ deliverAs: "nextTurn", triggerTurn: true },
							);
							offeredProjections.set(memoryKey, offeredIdentity);
							record.hash = hash;
						}
					}
				}
				if (!passIsCurrent()) return;
				writeTodoAutosyncRecord(recordPath, record);
				const nextVersion = boardVersion(boardPath);
				const nextDate = new Date().toISOString().slice(0, 10);
				if (!nextVersion || (nextVersion.boardMtimeMs === version.boardMtimeMs
					&& nextVersion.boardSize === version.boardSize && nextDate === dateKey)) break;
				previous = record;
				version = nextVersion;
				dateKey = nextDate;
			}
		} finally {
			autosyncInFlight.delete(memoryKey);
		}
	} catch {
		return;
	}
}

function register(pi: ExtensionAPI, event: string, handler: (event: any, ctx: any) => unknown): void {
	(pi.on as unknown as (name: string, callback: (event: any, ctx: any) => unknown) => void)(event, handler);
}

export default function fmFleetHooks(pi: ExtensionAPI): void {
	register(pi, "session_switch", () => {
		todoAutosyncGeneration++;
	});

	register(pi, "tool_result", (event) => {
		try {
			const content = redactToolResultContent(event?.content);
			return content ? { content } : undefined;
		} catch {
			return undefined;
		}
	});

	register(pi, "todo_reminder", async () => {
		try {
			const extensionRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
			const fmHome = process.env.FM_HOME || extensionRoot;
			const output = await runReadOnly(resolve(extensionRoot, "bin/fm-todo-project.sh"), ["--check"], extensionRoot, fmHome);
			const note = parseTodoCheckDrift(output);
			if (!note) return undefined;
			pi.sendMessage(
				{
					customType: "firstmate-todo-drift",
					content: note,
					display: false,
					attribution: "agent",
					details: { kind: "todo-drift", runtime: "omp" },
				},
				{ deliverAs: "nextTurn" },
			);
			return undefined;
		} catch {
			return undefined;
		}
	});

	// Not awaited: a projection pass can take tens of seconds, and the injected
	// instruction starts its own turn, so turn end never waits on it.
	register(pi, "turn_end", (_event, ctx) => {
		void syncSessionTodo(pi, ctx);
		return undefined;
	});

	register(pi, "session.compacting", async () => {
		try {
			const extensionRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
			const fmHome = process.env.FM_HOME || extensionRoot;
			const state = process.env.FM_STATE_OVERRIDE || resolve(fmHome, "state");
			const context = await readFleetSnapshot(extensionRoot, fmHome, state);
			return { context: [context] };
		} catch {
			return undefined;
		}
	});
}
