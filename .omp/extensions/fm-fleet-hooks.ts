// Read-only, fail-open fleet context hooks for OMP sessions.
// This adapter is intentionally separate from fm-primary-omp.ts, which owns
// native lifecycle and watcher integration.
import { spawnSync } from "node:child_process";
import { closeSync, constants, fstatSync, openSync, readdirSync, readSync } from "node:fs";
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
const PROCESS_GROUP_RUNNER = `
set -u
timeout_seconds=$1
shift
if command -v setsid >/dev/null 2>&1; then
	setsid --wait "$@" &
else
	"$@" &
fi
command_pid=$!
(
	sleep "$timeout_seconds"
	kill -KILL -- "-$command_pid" 2>/dev/null || true
	kill -KILL "$command_pid" 2>/dev/null || true
) </dev/null >/dev/null 2>&1 &
watchdog_pid=$!
set +e
wait "$command_pid"
status=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
exit "$status"
`;

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

function runReadOnly(command: string, args: string[], extensionRoot: string, fmHome: string, timeoutMs = READ_ONLY_TIMEOUT_MS): string {
	const result = spawnSync("bash", ["-c", PROCESS_GROUP_RUNNER, "_", (timeoutMs / 1000).toFixed(3), command, ...args], {
		cwd: extensionRoot,
		encoding: "utf8",
		env: { ...process.env, FM_HOME: fmHome },
		maxBuffer: 256 * 1024,
		timeout: timeoutMs + 1000,
		killSignal: "SIGKILL",
	});
	if (result.error || result.status !== 0 || result.signal || result.stderr) throw result.error ?? new Error(`${command} failed`);
	return result.stdout ?? "";
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

function readFleetSnapshot(extensionRoot: string, fmHome: string, state: string): string {
	const metas: FleetMeta[] = [];
	for (const entry of readdirSync(state)) {
		if (!entry.endsWith(".meta")) continue;
		const id = entry.slice(0, -5);
		metas.push(parseFleetMeta(id, readFleetMetaFile(resolve(state, entry))));
	}
	const openDecisionRows = runReadOnly("bash", ["-c", '. "$1/bin/fm-classify-lib.sh"; scan_open_decisions "$2"', "_", extensionRoot, state], extensionRoot, fmHome, SNAPSHOT_SCAN_TIMEOUT_MS);
	const todoProjection = runReadOnly(resolve(extensionRoot, "bin/fm-todo-project.sh"), ["--emit"], extensionRoot, fmHome);
	return buildFleetSnapshot({ metas, openDecisions: parseOpenDecisionRows(openDecisionRows), todoProjection });
}

function register(pi: ExtensionAPI, event: string, handler: (event: any, ctx: any) => unknown): void {
	(pi.on as unknown as (name: string, callback: (event: any, ctx: any) => unknown) => void)(event, handler);
}

export default function fmFleetHooks(pi: ExtensionAPI): void {
	register(pi, "tool_result", (event) => {
		try {
			const content = redactToolResultContent(event?.content);
			return content ? { content } : undefined;
		} catch {
			return undefined;
		}
	});

	register(pi, "todo_reminder", () => {
		try {
			const extensionRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
			const fmHome = process.env.FM_HOME || extensionRoot;
			const output = runReadOnly(resolve(extensionRoot, "bin/fm-todo-project.sh"), ["--check"], extensionRoot, fmHome);
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

	register(pi, "session.compacting", () => {
		try {
			const extensionRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
			const fmHome = process.env.FM_HOME || extensionRoot;
			const state = process.env.FM_STATE_OVERRIDE || resolve(fmHome, "state");
			const context = readFleetSnapshot(extensionRoot, fmHome, state);
			return { context: [context] };
		} catch {
			return undefined;
		}
	});
}
