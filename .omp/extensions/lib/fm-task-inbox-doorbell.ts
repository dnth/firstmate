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
	) => void | Promise<void>;
	// The downgrade recovery channel: a user prompt starts a turn on an idle
	// session, where the agent-initiated sendMessage path can be deferred into
	// append-only delivery by the runtime's turn policy.
	sendUserMessage?: (
		content: string,
		options?: { deliverAs?: "steer" | "followUp" },
	) => void | Promise<void>;
	// A turn-event surface enables downgrade recovery, whether the doorbell
	// subscribes itself or the embedding extension forwards its own correlated
	// turn_start/turn_end through notifyTurnStart/notifyTurnEnd. Runtimes
	// without an event surface keep the prior accept-only semantics.
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
	// Durable diagnosis for a refused handshake: a failure that retires the
	// ready marker (activation, or a drain that takes the doorbell down) writes
	// its reason here, so a missing marker is never ambiguous. Deliberately
	// independent of the doorbell's own configuration - an unconfigured
	// doorbell is itself an activation failure only this file can report.
	failureJournal?: string;
	// How long a delivered doorbell may go without a turn_start before the
	// triggerTurn call is treated as downgraded to append-only and the
	// instruction is re-driven through the user-prompt channel.
	turnGraceMs?: number;
	// false keeps the doorbell off the event surface: the embedding extension
	// forwards its own correlated turn_start/turn_end through notifyTurnStart
	// and notifyTurnEnd instead. Turn proof and downgrade re-drive apply
	// either way whenever the runtime exposes an event surface.
	observeTurns?: boolean;
};

export type TaskInboxDoorbell = {
	// activate reports whether the doorbell is live after the call. A caller
	// that publishes its own readiness marker (fm-spawn's generated extension
	// touching .omp-ready) must gate that marker on this result, or readiness
	// silently outlives a failed handshake.
	activate: () => boolean | Promise<boolean>;
	retire: () => void;
	notifyTurnStart: () => void;
	notifyTurnEnd: () => void;
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
	return { inboxDir, readyMarker, turnGraceMs, observeTurns: options.observeTurns !== false };
}

function publishReadyMarker(marker: string): void {
	mkdirSync(dirname(marker), { recursive: true });
	const staged = `${marker}.staging.${process.pid}`;
	writeFileSync(staged, `${process.pid}\n`, { mode: 0o600 });
	renameSync(staged, marker);
}

// Best-effort durable diagnosis for a lost handshake: "<iso> <phase>: <error>".
// The write is staged and renamed like the ready marker so a concurrent reader
// never sees a partial reason. A failed journal write is swallowed - the
// journal explains failures, it must never become one.
function journalDoorbellFailure(journal: string, phase: string, error: unknown): void {
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

function defaultFailureJournal(options: TaskInboxDoorbellOptions): string {
	const explicit = options.failureJournal || process.env.FM_OMP_TASK_DOORBELL_FAILED || "";
	if (explicit) return explicit;
	const readyMarker = options.readyMarker || process.env.FM_OMP_TASK_DOORBELL_READY || "";
	if (readyMarker.startsWith("/")) {
		const suffix = ".omp-doorbell-ready";
		const stem = readyMarker.endsWith(suffix)
			? readyMarker.slice(0, -suffix.length)
			: readyMarker;
		return `${stem}.omp-doorbell-failed`;
	}
	const inboxDir = options.inboxDir || process.env.FM_OMP_TASK_INBOX_DIR || "";
	const stateDir = inboxDir.startsWith("/")
		? dirname(inboxDir)
		: (process.env.FM_STATE_OVERRIDE?.startsWith("/")
			? process.env.FM_STATE_OVERRIDE
			: join(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || process.cwd(), "state"));
	return stateDir ? join(stateDir, `.omp-doorbell-failed.${process.pid}`) : "";
}

export function installTaskInboxDoorbell(
	omp: OmpDoorbellApi,
	options: TaskInboxDoorbellOptions = {},
): TaskInboxDoorbell {
	const failureJournal = defaultFailureJournal(options);
	const configured = configuredOptions(options);
	if (!configured || typeof omp.sendMessage !== "function") {
		const unconfiguredWhy = !configured
			? "task inbox doorbell is unconfigured (inboxDir/readyMarker unresolved)"
			: "OMP sendMessage is unavailable";
		return {
			activate: () => {
				journalDoorbellFailure(failureJournal, "activate", new Error(unconfiguredWhy));
				return false;
			},
			retire: () => {},
			notifyTurnStart: () => {},
			notifyTurnEnd: () => {},
		};
	}

	const requestDir = `${configured.readyMarker}.requests`;
	const turnGraceMs = configured.turnGraceMs;
	const turnEventsReachable = typeof omp.on === "function";
	const canObserveTurns = options.observeTurns !== false && turnEventsReachable;
	const canReDrive = typeof omp.sendUserMessage === "function";
	let active = false;
	let draining = false;
	let signalHandlerInstalled = false;
	let turnListenersInstalled = false;
	let turnOpen = false;
	let turnEpoch = 0;
	let dispatchingTurn = false;
	let dispatchingTurnObserved = false;
	const awaitingTurns = new Map<string, ReturnType<typeof setTimeout>>();
	const activationSends = new Set<Promise<void>>();
	let watcher: FSWatcher | undefined;
	const settleAwaiting = (awaitingPath: string, outcome: "delivered" | "failed" | "unproven"): void => {
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
	// defer; while streaming it queues as a steer into the open turn. The
	// re-drive is itself only a request: a nonthrowing return or resolved
	// promise is never a receipt, so the entry re-parks for one more bounded
	// proof window. A turn opening inside that window settles it delivered;
	// expiry settles it unproven - a durable marker that is not a tombstone,
	// so the next ring is a real delivery attempt rather than a suppressed
	// false success. Without a recovery channel the request settles unproven
	// at once - still unconfirmed, never delivered.
	const recoverUnprovenTurn = (awaitingPath: string): void => {
		awaitingTurns.delete(awaitingPath);
		const settleUnproven = (): void => {
			settleAwaiting(awaitingPath, "unproven");
		};
		if (!canReDrive) {
			settleUnproven();
			return;
		}
		let content = "";
		try {
			content = readFileSync(awaitingPath, "utf8");
		} catch {
			settleUnproven();
			return;
		}
		let result: void | Promise<void>;
		const epochAtRedrive = turnEpoch;
		try {
			result = omp.sendUserMessage!(content);
		} catch {
			settleAwaiting(awaitingPath, "failed");
			return;
		}
		void Promise.resolve(result).then(
			() => {
				if (!existsSync(awaitingPath)) return;
				if (turnEpoch !== epochAtRedrive) {
					settleAwaiting(awaitingPath, "delivered");
					return;
				}
				awaitingTurns.set(awaitingPath, setTimeout(settleUnproven, turnGraceMs));
			},
			() => settleAwaiting(awaitingPath, "failed"),
		);
	};
	const onTurnOpen = (): void => {
		turnOpen = true;
		turnEpoch += 1;
		if (dispatchingTurn) dispatchingTurnObserved = true;
		// A turn opening while a steer sits parked is proof the session took
		// the work: the steer caused the turn or was absorbed into it, so
		// settle every awaiting entry delivered and cancel its grace timer
		// instead of re-driving the same instruction as a user prompt.
		for (const awaitingPath of [...awaitingTurns.keys()]) {
			settleAwaiting(awaitingPath, "delivered");
		}
	};
	const notifyTurnStart = (): void => onTurnOpen();
	const onTurnClose = (): void => {
		turnOpen = false;
	};
	const notifyTurnEnd = (): void => onTurnClose();
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
					dispatchingTurn = true;
					dispatchingTurnObserved = false;
					const sendResult = omp.sendMessage(
						{
							customType: "firstmate-task-inbox-doorbell",
							content,
							display: false,
							attribution: "agent",
							details: { kind: "task-inbox", runtime: "omp" },
						},
						{ deliverAs: "steer", triggerTurn: true },
					);
					if (sendResult && typeof sendResult.then === "function") {
						const delivery = Promise.resolve(sendResult);
						activationSends.add(delivery);
						void delivery.catch((error: unknown) => {
							if (!active && existsSync(configured.readyMarker)) return;
							bestEffortRename(`${pending}.delivered`, pending);
							bestEffortRename(`${pending}.awaiting-turn`, pending);
							bestEffortRename(ambiguous, pending);
							journalDoorbellFailure(failureJournal, "drain", error);
							retire();
						}).finally(() => activationSends.delete(delivery));
					}
					const turnStartedDuringSend = dispatchingTurnObserved;
					dispatchingTurn = false;
					dispatchingTurnObserved = false;
					// A steer into an open turn is delivered by that turn. On an idle
					// session, triggerTurn must start one; claiming delivered without
					// that proof is the downgrade that strands an idle worker.
					if (!turnEventsReachable) {
						renameSync(ambiguous, `${pending}.delivered`);
						continue;
					}
					const awaitingPath = `${pending}.awaiting-turn`;
					renameSync(ambiguous, awaitingPath);
					if (turnStartedDuringSend || turnOpen) {
						settleAwaiting(awaitingPath, "delivered");
						continue;
					}
					awaitingTurns.set(
						awaitingPath,
						setTimeout(() => recoverUnprovenTurn(awaitingPath), turnGraceMs),
					);
				} catch (error) {
					dispatchingTurn = false;
					if (invoked) bestEffortRename(ambiguous, pending);
					else bestEffortRename(ambiguous, `${pending}.failed`);
					journalDoorbellFailure(failureJournal, "drain", error);
					retire();
					break;
				}
			}
		} finally {
			draining = false;
		}
	};
	const activate = (): boolean | Promise<boolean> => {
		if (active) return true;
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
		} catch (error) {
			journalDoorbellFailure(failureJournal, "activate", error);
			retire();
			return false;
		}
		// A drain failure retires the doorbell without throwing; it already
		// journaled its reason, so the activation reports the failure it caused.
		if (!active) return false;
		if (activationSends.size > 0) {
			return (async (): Promise<boolean> => {
				while (activationSends.size > 0) {
					await Promise.allSettled([...activationSends]);
				}
				if (!active) return false;
				bestEffortUnlink(failureJournal);
				return true;
			})();
		}
		bestEffortUnlink(failureJournal);
		return true;
	};

	return { activate, retire, notifyTurnStart, notifyTurnEnd };
}
