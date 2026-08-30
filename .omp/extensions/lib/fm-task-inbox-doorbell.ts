import {
	type FSWatcher,
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
			watcher = watch(requestDir, drain);
			active = true;
			process.on(FM_TASK_INBOX_DOORBELL_SIGNAL, drain);
			publishReadyMarker(configured.readyMarker);
		} catch {
			retire();
		}
	};

	return { activate, retire };
}
