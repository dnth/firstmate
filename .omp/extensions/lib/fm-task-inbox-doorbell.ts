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
};

export type TaskInboxDoorbellOptions = {
	inboxDir?: string;
	readyMarker?: string;
};

export type TaskInboxDoorbell = {
	activate: () => void;
	retire: () => void;
};

function configuredOptions(options: TaskInboxDoorbellOptions): Required<TaskInboxDoorbellOptions> | undefined {
	const inboxDir = options.inboxDir ?? process.env.FM_OMP_TASK_INBOX_DIR ?? "";
	const readyMarker = options.readyMarker ?? process.env.FM_OMP_TASK_DOORBELL_READY ?? "";
	if (!inboxDir.startsWith("/") || !readyMarker.startsWith("/")) return undefined;
	return { inboxDir, readyMarker };
}

function doorbellLine(inboxDir: string): string {
	return `Firstmate instruction waiting: list ${inboxDir}/*.msg and, in numeric order, read and act on each, then mv each handled file to ${inboxDir}/handled/.`;
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

function processIsAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

function reconcileStaleClaims(requestDir: string): void {
	for (const name of readdirSync(requestDir).sort()) {
		const match = name.match(/^(.*\.pending)\.processing\.([0-9]+)$/);
		if (!match) continue;
		const owner = Number(match[2]);
		if (!Number.isSafeInteger(owner) || owner <= 1 || processIsAlive(owner)) continue;
		const processing = join(requestDir, name);
		const pending = join(requestDir, match[1]);
		try {
			linkSync(processing, pending);
			unlinkSync(processing);
		} catch {
			if (existsSync(pending)) {
				try {
					unlinkSync(processing);
				} catch {
					continue;
				}
			}
		}
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
	let active = false;
	let draining = false;
	let watcher: FSWatcher | undefined;
	const retire = (): void => {
		if (!active) return;
		active = false;
		process.off(FM_TASK_INBOX_DOORBELL_SIGNAL, drain);
		watcher?.close();
		watcher = undefined;
		retireOwnedReadyMarker(configured.readyMarker);
	};
	const drain = (): void => {
		if (!active || draining) return;
		draining = true;
		try {
			for (const name of readdirSync(requestDir).filter((entry) => entry.endsWith(".pending")).sort()) {
				const pending = join(requestDir, name);
				const processing = `${pending}.processing.${process.pid}`;
				try {
					renameSync(pending, processing);
				} catch {
					continue;
				}
				try {
					if (typeof omp.sendMessage !== "function") throw new Error("OMP sendMessage unavailable");
					omp.sendMessage(
						{
							customType: "firstmate-task-inbox-doorbell",
							content: doorbellLine(configured.inboxDir),
							display: false,
							attribution: "agent",
							details: { kind: "task-inbox", runtime: "omp" },
						},
						{ deliverAs: "steer", triggerTurn: true },
					);
					renameSync(processing, `${pending}.delivered`);
				} catch {
					bestEffortRename(processing, `${pending}.failed`);
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
			reconcileStaleClaims(requestDir);
			watcher = watch(requestDir, drain);
			active = true;
			process.on(FM_TASK_INBOX_DOORBELL_SIGNAL, drain);
			publishReadyMarker(configured.readyMarker);
			drain();
		} catch {
			retire();
		}
	};

	return { activate, retire };
}
