import { mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

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

export function installTaskInboxDoorbell(
	omp: OmpDoorbellApi,
	options: TaskInboxDoorbellOptions = {},
): () => void {
	const configured = configuredOptions(options);
	if (!configured || typeof omp.sendMessage !== "function") return () => {};

	let active = true;
	const retire = (): void => {
		if (!active) return;
		active = false;
		process.off(FM_TASK_INBOX_DOORBELL_SIGNAL, ring);
		retireOwnedReadyMarker(configured.readyMarker);
	};
	const ring = (): void => {
		try {
			omp.sendMessage?.(
				{
					customType: "firstmate-task-inbox-doorbell",
					content: doorbellLine(configured.inboxDir),
					display: false,
					attribution: "agent",
					details: { kind: "task-inbox", runtime: "omp" },
				},
				{ deliverAs: "steer", triggerTurn: true },
			);
		} catch {
			// Disable the programmatic surface so the next ring uses the composer fallback.
			retire();
		}
	};

	process.on(FM_TASK_INBOX_DOORBELL_SIGNAL, ring);
	try {
		publishReadyMarker(configured.readyMarker);
	} catch {
		process.off(FM_TASK_INBOX_DOORBELL_SIGNAL, ring);
		active = false;
	}
	return retire;
}
