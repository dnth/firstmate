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

export const FM_TASK_INBOX_DOORBELL_SIGNAL = "SIGUSR2";

type OmpDoorbellApi = {
	sendMessage?: (
		message: {
			customType: string;
			content: string;
			display: boolean;
			attribution: "agent";
			details: { kind: "task-inbox"; runtime: "omp" };
		},
		options: { deliverAs: "steer"; triggerTurn: true },
	) => void;
	// The downgrade recovery channel: a user prompt starts a turn on an idle
	// session, where the agent-initiated sendMessage path can be deferred into
	// append-only delivery by the runtime's turn policy.
	sendUserMessage?: (
		content: string,
		options?: { deliverAs?: "steer" | "followUp" },
	) => void | Promise<void>;
	// Optional turn observation enables downgrade recovery. Runtimes without an
	// event surface keep the prior accept-only semantics.
	// Method syntax keeps the parameter bivariant: the real extension API types
	// `on` as per-event-name overloads, which a property signature could not
	// accept.
	on?(event: string, handler: () => void): void;
};

const DEFAULT_TURN_GRACE_MS = 8000;
const MIN_TURN_GRACE_MS = 100;
const MAX_TURN_GRACE_MS = 120000;

export type TaskInboxDoorbellOptions = {
	inboxDir?: string;
	readyMarker?: string;
	// How long a delivered doorbell may go without a turn_start before the
	// triggerTurn call is treated as downgraded to append-only and the
	// instruction is re-driven through the user-prompt channel.
	turnGraceMs?: number;
};

export type TaskInboxDoorbell = {
	activate: () => void;
	retire: () => void;
};

function configuredOptions(options: TaskInboxDoorbellOptions): Required<TaskInboxDoorbellOptions> | undefined {
	const inboxDir = options.inboxDir ?? process.env.FM_OMP_TASK_INBOX_DIR ?? "";
	const readyMarker = options.readyMarker ?? process.env.FM_OMP_TASK_DOORBELL_READY ?? "";
	if (!inboxDir.startsWith("/") || !readyMarker.startsWith("/")) return undefined;
	const configuredGrace = options.turnGraceMs
		?? Number(process.env.FM_OMP_DOORBELL_TURN_GRACE_MS ?? DEFAULT_TURN_GRACE_MS);
	const turnGraceMs = Number.isFinite(configuredGrace)
		? Math.min(Math.max(Math.trunc(configuredGrace), MIN_TURN_GRACE_MS), MAX_TURN_GRACE_MS)
		: DEFAULT_TURN_GRACE_MS;
	return { inboxDir, readyMarker, turnGraceMs };
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

// A turn proof left unsettled by a dead generation re-queues for delivery: the
// message may or may not still sit in the runtime's deferred queue, and the
// doorbell is idempotent, so a rare duplicate steer is harmless next to a lost
// doorbell.
function reconcileAwaitingTurns(requestDir: string): void {
	for (const name of readdirSync(requestDir).sort()) {
		const match = name.match(/^(.*\.pending)\.awaiting-turn$/);
		if (!match) continue;
		bestEffortRename(join(requestDir, name), join(requestDir, match[1]));
	}
}

export function installTaskInboxDoorbell(
	omp: OmpDoorbellApi,
	options: TaskInboxDoorbellOptions = {},
): TaskInboxDoorbell {
	const configured = configuredOptions(options);
	if (!configured || typeof omp.sendMessage !== "function") {
		return { activate: () => {}, retire: () => {} };
	}

	const requestDir = `${configured.readyMarker}.requests`;
	const turnGraceMs = configured.turnGraceMs;
	const canObserveTurns = typeof omp.on === "function";
	const canReDrive = typeof omp.sendUserMessage === "function";
	let active = false;
	let draining = false;
	let signalHandlerInstalled = false;
	let turnListenersInstalled = false;
	let turnOpen = false;
	const awaitingTurns = new Map<string, ReturnType<typeof setTimeout>>();
	let watcher: FSWatcher | undefined;
	const settleAwaiting = (awaitingPath: string, outcome: "delivered" | "failed"): void => {
		const timer = awaitingTurns.get(awaitingPath);
		if (timer !== undefined) {
			clearTimeout(timer);
			awaitingTurns.delete(awaitingPath);
		}
		bestEffortRename(awaitingPath, awaitingPath.replace(/\.awaiting-turn$/, `.${outcome}`));
	};
	// A delivered doorbell that produced no turn within the grace bound was
	// downgraded by the runtime to append-only delivery. Re-drive the same
	// instruction through the user-prompt channel, which an idle session cannot
	// defer; while streaming it queues as a steer into the open turn. Without a
	// recovery channel the prior accept-only semantics stand.
	const recoverUnprovenTurn = (awaitingPath: string): void => {
		awaitingTurns.delete(awaitingPath);
		if (turnOpen || !canReDrive) {
			settleAwaiting(awaitingPath, "delivered");
			return;
		}
		let content = "";
		try {
			content = readFileSync(awaitingPath, "utf8");
		} catch {
			return;
		}
		let result: void | Promise<void>;
		try {
			result = omp.sendUserMessage!(content);
		} catch {
			settleAwaiting(awaitingPath, "failed");
			return;
		}
		void Promise.resolve(result).then(
			() => settleAwaiting(awaitingPath, "delivered"),
			() => settleAwaiting(awaitingPath, "failed"),
		);
	};
	const onTurnOpen = (): void => {
		turnOpen = true;
		const awaitingPath = awaitingTurns.keys().next().value;
		if (awaitingPath) settleAwaiting(awaitingPath, "delivered");
	};
	const onTurnClose = (): void => {
		turnOpen = false;
	};
	const installTurnListeners = (): void => {
		if (turnListenersInstalled || !canObserveTurns) return;
		turnListenersInstalled = true;
		omp.on!("turn_start", onTurnOpen);
		omp.on!("agent_start", onTurnOpen);
		omp.on!("turn_end", onTurnClose);
		omp.on!("agent_end", onTurnClose);
	};
	const retire = (): void => {
		if (!active) return;
		retireOwnedReadyMarker(configured.readyMarker);
		active = false;
		for (const timer of awaitingTurns.values()) clearTimeout(timer);
		awaitingTurns.clear();
		watcher?.close();
		watcher = undefined;
	};
	const drain = (): void => {
		if (!active || draining) return;
		draining = true;
		try {
			for (const name of readdirSync(requestDir).filter((entry) => entry.endsWith(".pending")).sort()) {
				const pending = join(requestDir, name);
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
					// A steer into an open turn is delivered by that turn. On an idle
					// session, triggerTurn must start one; claiming delivered without
					// that proof is the downgrade that strands an idle worker.
					if (!canObserveTurns) {
						renameSync(ambiguous, `${pending}.delivered`);
						continue;
					}
					const awaitingPath = `${pending}.awaiting-turn`;
					renameSync(ambiguous, awaitingPath);
					if (turnOpen) {
						settleAwaiting(awaitingPath, "delivered");
						continue;
					}
					awaitingTurns.set(
						awaitingPath,
						setTimeout(() => recoverUnprovenTurn(awaitingPath), turnGraceMs),
					);
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
			reconcileAwaitingTurns(requestDir);
			installTurnListeners();
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

	return { activate, retire };
}
