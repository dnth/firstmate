import {
	type FSWatcher,
	existsSync,
	linkSync,
	mkdirSync,
	readFileSync,
	readdirSync,
	renameSync,
	unlinkSync,
	watch,
	writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

export const FM_TASK_INBOX_DOORBELL_SIGNAL = "SIGUSR2";

export type OmpDoorbellApi = {
	sendMessage?: ExtensionAPI["sendMessage"];
	sendUserMessage?: ExtensionAPI["sendUserMessage"];
};

export type TaskInboxDoorbellOptions = {
	inboxDir?: string;
	readyMarker?: string;
};

export type TaskInboxDoorbell = {
	activate: () => void;
	retire: () => void;
	turnStarted: () => void;
	turnEnded: () => void;
};

function configuredOptions(options: TaskInboxDoorbellOptions): Required<TaskInboxDoorbellOptions> | undefined {
	const inboxDir = options.inboxDir ?? process.env.FM_OMP_TASK_INBOX_DIR ?? "";
	const readyMarker = options.readyMarker ?? process.env.FM_OMP_TASK_DOORBELL_READY ?? "";
	if (!inboxDir.startsWith("/") || !readyMarker.startsWith("/")) return undefined;
	return { inboxDir, readyMarker };
}

function publishReadyMarker(marker: string): void {
	mkdirSync(dirname(marker), { recursive: true });
	const staged = `${marker}.staging.${process.pid}`;
	writeFileSync(staged, `${process.pid}\n`, { mode: 0o600 });
	renameSync(staged, marker);
}

function retireOwnedReadyMarker(marker: string): void {
	try {
		if (readFileSync(marker, "utf8") === `${process.pid}\n`) unlinkSync(marker);
	} catch {
		// Marker cleanup is best-effort; a stale marker cannot pass backend PID ownership checks.
	}
}

function bestEffortRename(from: string, to: string): void {
	try {
		renameSync(from, to);
	} catch {
		return;
	}
}

function bestEffortUnlink(path: string): void {
	try {
		unlinkSync(path);
	} catch {
		return;
	}
}

function requeueAmbiguousClaim(ack: PendingAck): void {
	let target = ack.pending;
	let suffix = 0;
	while (existsSync(target)) {
		suffix += 1;
		target = `${ack.pending}.recovered.${suffix}.pending`;
	}
	try {
		linkSync(ack.ambiguous, target);
		bestEffortUnlink(ack.ambiguous);
	} catch {
		return;
	}
}

function reconcileAmbiguousClaims(requestDir: string): void {
	for (const name of readdirSync(requestDir).sort()) {
		const match = name.match(/^(.*\.pending)\.processing\.([0-9]+)$/);
		if (!match) continue;
		const processing = join(requestDir, name);
		const pending = join(requestDir, match[1]);
		const ambiguous = `${pending}.ambiguous`;
		try {
			linkSync(processing, ambiguous);
		} catch {
			if (!existsSync(ambiguous)) continue;
		}
		bestEffortUnlink(processing);
		bestEffortUnlink(pending);
	}
}

type PendingAck = {
	pending: string;
	ambiguous: string;
	content: string;
};

export function installTaskInboxDoorbell(
	omp: OmpDoorbellApi,
	options: TaskInboxDoorbellOptions = {},
): TaskInboxDoorbell {
	const configured = configuredOptions(options);
	if (!configured || typeof omp.sendMessage !== "function") {
		return { activate: () => {}, retire: () => {}, turnStarted: () => {}, turnEnded: () => {} };
	}

	const requestDir = `${configured.readyMarker}.requests`;
	let active = false;
	let draining = false;
	let signalHandlerInstalled = false;
	let watcher: FSWatcher | undefined;
	const pendingAcks: PendingAck[] = [];
	let sessionIdle = true;
	let fallbackTimer: ReturnType<typeof setTimeout> | undefined;
	let forceTurnAttempted = false;

	const turnAckMs = Math.max(10, Math.min(3000, Number(process.env.FM_OMP_DOORBELL_TURN_ACK_MS ?? 500)));

	const clearFallbackTimer = (): void => {
		if (fallbackTimer) {
			clearTimeout(fallbackTimer);
			fallbackTimer = undefined;
		}
	};

	const acknowledgeAll = (): void => {
		while (pendingAcks.length > 0) {
			const ack = pendingAcks.shift();
			if (!ack) continue;
			bestEffortRename(ack.ambiguous, `${ack.pending}.delivered`);
		}
		clearFallbackTimer();
		forceTurnAttempted = false;
	};

	const failAll = (reason: string): void => {
		while (pendingAcks.length > 0) {
			const ack = pendingAcks.shift();
			if (!ack) continue;
			bestEffortRename(ack.ambiguous, `${ack.pending}.failed`);
		}
		clearFallbackTimer();
		forceTurnAttempted = false;
		// Loud escalation: the ready marker is still owned by this process, so the
		// mismatch will be noticed, but also drop a durable status note when state
		// is addressable from the marker path.
		if (configured) {
			try {
				const stateDir = dirname(configured.readyMarker);
				const taskId = basenameWithoutSuffix(configured.readyMarker, ".omp-doorbell-ready");
				if (taskId && stateDir.startsWith("/")) {
					const statusFile = join(stateDir, `${taskId}.status`);
					const note = `failed: ${reason}: ${new Date().toISOString()}; the doorbell could not start a bound turn; supervised recovery must relaunch or inspect the session`;
					writeFileSync(statusFile, `${note}\n`, { flag: "a", mode: 0o600 });
				}
			} catch {
				// Status escalation is best-effort; the failed marker is the primary signal.
			}
		}
	};

	const tryForceTurn = (): void => {
		if (forceTurnAttempted) return;
		forceTurnAttempted = true;
		if (pendingAcks.length === 0) return;
		if (typeof omp.sendUserMessage === "function") {
			const content = pendingAcks[0].content;
			try {
				omp.sendUserMessage(content);
				// Wait one more bounded beat for the forced user turn to emit turn_start.
				fallbackTimer = setTimeout(() => {
					fallbackTimer = undefined;
					if (pendingAcks.length > 0) failAll("forced-turn-failed");
				}, turnAckMs);
				return;
			} catch {
				// Fall through to failAll.
			}
		}
		failAll("no-turn");
	};

	const scheduleFallback = (): void => {
		if (fallbackTimer || forceTurnAttempted) return;
		fallbackTimer = setTimeout(() => {
			fallbackTimer = undefined;
			if (pendingAcks.length === 0) return;
			tryForceTurn();
		}, turnAckMs);
	};

	const turnStarted = (): void => {
		sessionIdle = false;
		if (pendingAcks.length > 0) acknowledgeAll();
	};

	const turnEnded = (): void => {
		sessionIdle = true;
	};

	const handledReceiptExists = (requestId: string): boolean => {
		const record = requestId.startsWith("request.") ? requestId.slice("request.".length) : requestId;
		const recordName = record.endsWith(".msg") ? record : `${record}.msg`;
		return existsSync(join(configured.inboxDir, "handled", recordName));
	};

	const retire = (): void => {
		if (!active) return;
		retireOwnedReadyMarker(configured.readyMarker);
		active = false;
		watcher?.close();
		watcher = undefined;
		clearFallbackTimer();
		for (const ack of pendingAcks) requeueAmbiguousClaim(ack);
		pendingAcks.length = 0;
		forceTurnAttempted = false;
	};

	const drain = (): void => {
		if (!active || draining) return;
		draining = true;
		try {
			for (const name of readdirSync(requestDir).filter((entry) => entry.endsWith(".pending")).sort()) {
				const pending = join(requestDir, name);
				const requestId = name.slice(0, -".pending".length);
				const ambiguous = `${pending}.ambiguous`;
				let invoked = false;
				try {
					renameSync(pending, ambiguous);
				} catch {
					continue;
				}
				try {
					if (typeof omp.sendMessage !== "function") throw new Error("OMP sendMessage unavailable");
					const content = readFileSync(ambiguous, "utf8");
					invoked = true;
					omp.sendMessage(
						{
							customType: "firstmate-task-inbox-doorbell",
							content,
							display: false,
							attribution: "agent",
							details: { kind: "task-inbox", runtime: "omp" },
						},
						{ deliverAs: "steer", triggerTurn: true },
					);
					if (handledReceiptExists(requestId)) {
						// A worker may consume the durable inbox record synchronously
						// while handling sendMessage. That handled/ move is the
						// strongest receipt and does not require a separate turn_start
						// event from the host client.
						bestEffortRename(ambiguous, `${pending}.delivered`);
					} else if (sessionIdle) {
						// The session was idle when we called sendMessage. If the
						// turn starts, turnStarted acknowledges; if the client
						// defers agent-initiated turns, the fallback path will
						// force a user turn or escalate instead of pretending.
						pendingAcks.push({ pending, ambiguous, content });
						scheduleFallback();
					} else {
						// A turn is already in progress, so the steer is queued for
						// the running turn. Confirm delivery immediately.
						bestEffortRename(ambiguous, `${pending}.delivered`);
					}
				} catch {
					if (!invoked) bestEffortRename(ambiguous, `${pending}.failed`);
					retire();
					break;
				}
			}
		} finally {
			draining = false;
		}
	};

	const activate = (): void => {
		if (active) return;
		try {
			mkdirSync(requestDir, { recursive: true, mode: 0o700 });
			reconcileAmbiguousClaims(requestDir);
			watcher = watch(requestDir, drain);
			active = true;
			if (!signalHandlerInstalled) {
				process.on(FM_TASK_INBOX_DOORBELL_SIGNAL, drain);
				signalHandlerInstalled = true;
			}
			publishReadyMarker(configured.readyMarker);
			drain();
		} catch {
			retire();
		}
	};

	return { activate, retire, turnStarted, turnEnded };
}

function basenameWithoutSuffix(path: string, suffix: string): string {
	const base = path.slice(path.lastIndexOf("/") + 1);
	return base.endsWith(suffix) ? base.slice(0, -suffix.length) : base;
}
