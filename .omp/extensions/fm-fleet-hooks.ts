// Read-only, fail-open fleet context hooks for OMP sessions.
// This adapter is intentionally separate from fm-primary-omp.ts, which owns
// native lifecycle and watcher integration.
import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

export type ToolContent = { type: string; text?: string; [key: string]: unknown };

const SECRET_PATTERNS: Array<{ pattern: RegExp; label: string }> = [
	{ pattern: /\$ANSIBLE_VAULT;[^\r\n]+(?:\r?\n[0-9a-fA-F]{16,})+/g, label: "ANSIBLE_VAULT" },
	{ pattern: /\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{12,}|gloas-[A-Za-z0-9_-]{12,}|sk-(?:proj-)?[A-Za-z0-9_-]{16,})\b/g, label: "TOKEN" },
	{ pattern: /\bAKIA[0-9A-Z]{16}\b/g, label: "AWS_ACCESS_KEY" },
	{ pattern: /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/g, label: "BEARER" },
];

const NAMED_SECRET_PATTERN = /\b([A-Za-z_][A-Za-z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASS|CREDENTIAL)[A-Za-z0-9_]*)\s*=\s*([^\s"'`]{8,})/g;

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
	const findings = output
		.split(/\r?\n/)
		.map((line) => line.trim())
		.filter((line) => line.startsWith("DRIFT "));
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
	backlog?: string;
	maxChars?: number;
};

function parseBacklogCounts(backlog: string | undefined): { ready: number; inFlight: number } {
	let section = "";
	let ready = 0;
	let inFlight = 0;
	for (const line of (backlog ?? "").split(/\r?\n/)) {
		const heading = line.match(/^##\s+(.+?)\s*$/);
		if (heading) {
			section = heading[1].toLowerCase();
			continue;
		}
		if (!/^\s*-\s+/.test(line)) continue;
		if (section === "queued") ready += 1;
		if (section === "in flight" || section === "in-flight") inFlight += 1;
	}
	return { ready, inFlight };
}

function compact(value: string | undefined, fallback = "-"): string {
	const normalized = value?.trim();
	return normalized ? normalized.replace(/\s+/g, " ") : fallback;
}

/** Build a bounded, deterministic fleet context line from read-only fixtures. */
export function buildFleetSnapshot(input: FleetSnapshotInput): string {
	const maxChars = Math.max(1, input.maxChars ?? 1200);
	const metas = [...(input.metas ?? [])].sort((a, b) => a.id.localeCompare(b.id));
	const roster = metas.length === 0
		? "none"
		: metas.map((meta) => `${compact(meta.id)}(${compact(meta.kind, "crew")},${compact(meta.window)},${compact(meta.project)})`).join(" ");
	const prs = metas.filter((meta) => meta.pr).map((meta) => `${compact(meta.id)}=${compact(meta.pr)}`).join(" ") || "none";
	const decisions = (input.openDecisions ?? []).map((decision) => compact(decision)).filter(Boolean);
	const decisionText = decisions.length > 0 ? decisions.join(" | ") : "none";
	const counts = parseBacklogCounts(input.backlog);
	const full = `Firstmate fleet snapshot: roster ${roster}; OPEN DECISIONS ${decisionText}; in-flight PRs ${prs}; backlog Ready=${counts.ready} In-flight=${counts.inFlight}`;
	return full.length <= maxChars ? full : `${full.slice(0, Math.max(0, maxChars - 1)).trimEnd()}…`;
}

function parseMeta(id: string, source: string): FleetMeta {
	const values: Record<string, string> = {};
	for (const line of source.split(/\r?\n/)) {
		const separator = line.indexOf("=");
		if (separator <= 0) continue;
		values[line.slice(0, separator)] = line.slice(separator + 1);
	}
	return { id, kind: values.kind, window: values.window, project: values.project, pr: values.pr };
}

function parseOpenDecisions(id: string, source: string): string[] {
	const open = new Map<string, { verb: string; note: string }>();
	for (const line of source.split(/\r?\n/)) {
		const match = line.match(/^\s*(needs-decision|blocked|resolved|captain-held)(?:\s+\[key=([A-Za-z0-9._-]+)\])?\s*:\s*(.*)$/);
		if (!match) continue;
		const key = match[2] || "default";
		if (match[1] === "needs-decision" || match[1] === "blocked") open.set(key, { verb: match[1], note: match[3] });
		else open.delete(key);
	}
	return [...open.values()].map((decision) => `${id}: ${decision.verb}: ${decision.note}`);
}

function readFleetSnapshot(state: string, data: string): string {
	const metas: FleetMeta[] = [];
	for (const entry of readdirSync(state)) {
		if (!entry.endsWith(".meta")) continue;
		const id = entry.slice(0, -5);
		metas.push(parseMeta(id, readFileSync(resolve(state, entry), "utf8")));
	}
	const openDecisions: string[] = [];
	for (const meta of metas) {
		const statusPath = resolve(state, `${meta.id}.status`);
		try {
			openDecisions.push(...parseOpenDecisions(meta.id, readFileSync(statusPath, "utf8")));
		} catch {
			// Missing status logs are normal for a newly launched task.
		}
	}
	let backlog: string | undefined;
	try {
		backlog = readFileSync(resolve(data, "backlog.md"), "utf8");
	} catch {
		backlog = undefined;
	}
	return buildFleetSnapshot({ metas, openDecisions, backlog });
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
			const result = spawnSync(resolve(extensionRoot, "bin/fm-todo-project.sh"), ["--check"], {
				cwd: extensionRoot,
				encoding: "utf8",
				env: { ...process.env, FM_HOME: fmHome },
				maxBuffer: 256 * 1024,
			});
			const output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
			const note = parseTodoCheckDrift(output);
			if (!note) return undefined;
			const sendMessage = (pi as unknown as { sendMessage?: (message: string, options?: { deliverAs?: string }) => void }).sendMessage;
			if (typeof sendMessage === "function") sendMessage.call(pi, note, { deliverAs: "nextTurn" });
			return { context: [note] };
		} catch {
			return undefined;
		}
	});

	register(pi, "session.compacting", () => {
		try {
			const extensionRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
			const fmHome = process.env.FM_HOME || extensionRoot;
			const state = process.env.FM_STATE_OVERRIDE || resolve(fmHome, "state");
			const data = process.env.FM_DATA_OVERRIDE || resolve(fmHome, "data");
			const context = readFleetSnapshot(state, data);
			return { context: [context] };
		} catch {
			return undefined;
		}
	});
}
