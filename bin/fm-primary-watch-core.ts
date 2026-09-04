// Harness-neutral watcher lifecycle core for explicitly verified Pi-compatible runtimes.
// Runtime adapters retain their exact identity, event bindings, extension entry points,
// UI integration, operational-input encoding, and follow-up delivery mechanics.
//
// Session-generation ownership (stated once here): one generation is bound per
// runtime session activation. Only the active live generation may start, stop,
// rearm, or clear the arm child. An owning replacement activation arms its new
// generation without a model turn. A replacement handoff carries actionable
// closes that were still pending delivery; its durable state lives below
// state/extensions/<runtime>-primary-watch/. Terminal shutdown leaves the final
// generation stopped so late callbacks cannot rearm. Stale callbacks from an
// earlier generation, including callbacks retained by a superseded core instance,
// are no-ops against the active replacement. Compaction is not a session
// replacement and never enters this lifecycle. The active generation and the
// process-exit fallback are process-wide, not per-core-instance.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { fileURLToPath } from "node:url";

// The marker version must cover every file the watcher lifecycle is built from:
// the runtime adapter, this shared core, and OMP's dispatch helper when present.
// Verifiers recompute it from the same files (bin/fm-primary-watch-version-lib.sh).
const coreFile = fileURLToPath(import.meta.url);

type LockOwnership = "owned" | "missing" | "other";

type CloseClassification = {
  kind: "actionable" | "failure";
  message: string;
};

type PendingActionableClose = {
  version: 1;
  token: string;
  message: string;
  predecessorArmPid: string;
  delivered?: true;
};

type ReplacementActionableHandoff = {
  version: 2;
  pending: PendingActionableClose[];
};

// One outstanding watcher recovery episode, as reported by an established
// successor arm. bin/fm-wake-lib.sh owns the marker grammar; this adapter only
// carries the generation back so the handling handshake can name it.
type RecoveryHandoff = {
  generation: string;
  watcherPid: string;
};

type RestorationResult = {
  failure: string;
  recovery?: RecoveryHandoff;
};

type SessionGeneration = {
  id: number;
  stopping: boolean;
  replacement: boolean;
  child: ChildProcess | null;
  retryTimer: ReturnType<typeof setTimeout> | null;
  cleanupTimer: ReturnType<typeof setTimeout> | null;
  retryFailures: number;
  restoring: boolean;
  seq: number;
  pendingActionables: PendingActionableClose[];
  cleanupFailure: string;
  wakeAcknowledgements: Map<string, { content: string; settle: (consumed: boolean) => void }>;
};

export type ArmResult = {
  ok: boolean;
  message: string;
};

export type PrimaryWatchCoreOptions = {
  runtime: string;
  runtimeLabel: string;
  extensionFile: string;
  marker: string;
  fmHome: string;
  fmRoot: string;
  state: string;
  config: string;
  armReadyTimeoutEnv: string;
  repairToolName: string;
  encodeOperationalInput: (kind: "watcher", content: string) => string;
  sendFollowUp: (content: string) => Promise<void>;
  // Optional supervision-branch dispatch handshake. A synchronous non-null
  // settlement means the branch accepted handling, while rejection returns
  // delivery ownership to the core's consumption-acknowledged main path.
  // Never offered for repair-failed delivery: only main can repair the cycle.
  offerWakeToBranch?: (message: string) => Promise<void> | null;
};

export type PrimaryWatchCore = {
  readonly runtime: "pi" | "omp";
  arm: () => ArmResult;
  armAndWait: () => Promise<ArmResult>;
  acknowledgeWake: (content: string) => void;
  markLoaded: () => void;
  sessionShutdown: (replacement?: boolean) => Promise<void>;
  sessionStart: () => void;
};

// Single producer of the OMP native process identity pair. Both the loaded
// marker and FM_OMP_PROCESS_EXPECTED_{BUN,BIN} come from here so the two can
// never drift apart. Bun-script OMP exposes a physical entrypoint through
// argv[1]. A standalone Bun-compiled OMP instead exposes a virtual source path,
// so process.execPath is both its runtime and OMP executable identity.
export function ompNativeProcessIdentity(): { bunPath: string; ompPath: string } {
  const bunPath = realpathSync(process.execPath);
  const argvEntrypoint = process.argv[1];
  if (!argvEntrypoint) {
    throw new Error("OMP primary has no runtime entrypoint identity");
  }
  const ompPath = argvEntrypoint.startsWith("/$bunfs/")
    ? bunPath
    : realpathSync(argvEntrypoint);
  if (/\s/u.test(bunPath) || /\s/u.test(ompPath)) {
    throw new Error("OMP primary identity paths containing whitespace are unsupported");
  }
  return { bunPath, ompPath };
}

function verifiedRuntime(runtime: string, fmRoot: string): runtime is "pi" | "omp" {
  let allowlist = "";
  try {
    allowlist = readFileSync(`${fmRoot}/bin/fm-pi-compatible-runtimes`, "utf8");
  } catch {
    return false;
  }
  return allowlist.split(/\r?\n/).some((entry) => entry === runtime);
}

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function completedActionableLine(output: string): string {
  const newline = output.lastIndexOf("\n");
  return newline < 0 ? "" : actionableLine(output.slice(0, newline + 1));
}

function nodeErrorCode(error: unknown): string {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code ?? "")
    : "";
}

type ReplacementActionableReceiver = (pending: PendingActionableClose) => void;
type ActionableDeliveryClaim = {
  owner: SessionGeneration;
  settlement: Promise<"delivered" | "failed">;
};
type ReplacementCoordinator = {
  receiver: ReplacementActionableReceiver | null;
  pending: PendingActionableClose[];
  nextTokenId: number;
  deliveries: Map<string, ActionableDeliveryClaim>;
};
type ReplacementCoordinatorGlobal = typeof globalThis & {
  __firstmatePrimaryWatchReplacements?: Map<string, ReplacementCoordinator>;
};
const replacementCoordinatorGlobal = globalThis as ReplacementCoordinatorGlobal;
const replacementCoordinators = replacementCoordinatorGlobal.__firstmatePrimaryWatchReplacements ??= new Map();

let nextGenerationId = 0;
let activeGeneration: SessionGeneration | null = null;
let activeBinding: symbol | null = null;
let exitFallbackInstalled = false;

function createGeneration(): SessionGeneration {
  return {
    id: ++nextGenerationId,
    stopping: false,
    replacement: false,
    child: null,
    retryTimer: null,
    cleanupTimer: null,
    retryFailures: 0,
    restoring: false,
    seq: 0,
    pendingActionables: [],
    cleanupFailure: "",
    wakeAcknowledgements: new Map(),
  };
}

function activateGeneration(owner: SessionGeneration): void {
  if (activeGeneration && activeGeneration !== owner) stopGeneration(activeGeneration);
  activeGeneration = owner;
}

function generationIsLive(owner: SessionGeneration): boolean {
  return activeGeneration === owner && !owner.stopping;
}

function stopGeneration(owner: SessionGeneration): ChildProcess | null {
  owner.stopping = true;
  clearTimeout(owner.retryTimer ?? undefined);
  clearTimeout(owner.cleanupTimer ?? undefined);
  owner.retryTimer = null;
  owner.cleanupTimer = null;
  const child = owner.child;
  if (child) child.kill("SIGTERM");
  owner.child = null;
  return child;
}

function cleanupOnProcessExit(): void {
  if (activeGeneration) stopGeneration(activeGeneration);
}

function installExitFallback(): void {
  if (exitFallbackInstalled) return;
  exitFallbackInstalled = true;
  process.once("exit", cleanupOnProcessExit);
}

export function createPrimaryWatchCore(options: PrimaryWatchCoreOptions): PrimaryWatchCore {
  if (!verifiedRuntime(options.runtime, options.fmRoot)) {
    throw new Error(`${options.runtime} is not an explicitly verified Pi-compatible runtime`);
  }
  const runtime = options.runtime;
  const {
    runtimeLabel,
    extensionFile,
    marker,
    fmHome,
    fmRoot,
    state,
    config,
    armReadyTimeoutEnv,
    repairToolName,
    encodeOperationalInput,
    sendFollowUp,
    offerWakeToBranch,
  } = options;
  const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
  const handoffDir = `${state}/extensions/${runtime}-primary-watch`;
  const actionableHandoff = `${handoffDir}/session-replacement-actionable.json`;
  let nextHandoffId = 0;
  let replacementHandoff: PendingActionableClose[] | null = null;
  let replacementCoordinator = replacementCoordinators.get(actionableHandoff);
  if (!replacementCoordinator) {
    replacementCoordinator = {
      receiver: null,
      pending: [],
      nextTokenId: 0,
      deliveries: new Map(),
    };
    replacementCoordinators.set(actionableHandoff, replacementCoordinator);
  }
  const extensionVersionHash = createHash("sha256")
    .update(readFileSync(extensionFile))
    .update(readFileSync(coreFile));
  if (runtime === "omp") {
    extensionVersionHash.update(readFileSync(`${fmRoot}/.omp/extensions/lib/fm-branch-dispatch.ts`));
    extensionVersionHash.update(readFileSync(`${fmRoot}/.omp/extensions/lib/fm-task-inbox-doorbell.ts`));
  }
  const extensionVersion = `sha256:${extensionVersionHash.digest("hex")}`;
  const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
  const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
  const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
  // A delivered wake is acknowledged when the runtime starts a turn whose prompt
  // is that wake. A wake the runtime queues into an already-running turn never
  // starts one, so that acknowledgement can never arrive; bound the wait so one
  // unacknowledged delivery cannot hold the successor chain forever.
  const wakeConsumeTimeoutMs = positiveInteger("FM_WATCH_WAKE_CONSUME_TIMEOUT_MS", 15000);
  const armReadyTimeoutMs = positiveInteger(
    armReadyTimeoutEnv,
    process.platform === "win32" ? 35000 : 12000,
  );
  const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
  const repairOnlyHint =
    `call ${repairToolName} again only after a later notification says the cycle is missing, failed, or unhealthy`;
  const shuttingDownMessage = `watcher: not armed - ${runtimeLabel} session is shutting down`;

  const binding = Symbol(`${runtime}-primary-watch-binding`);
  let generation = createGeneration();
  const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
  const armClose = new WeakMap<ChildProcess, Promise<void>>();
  const armPendingActionable = new WeakMap<ChildProcess, PendingActionableClose>();
  // The recovery generation an established successor arm reported, keyed by the
  // arm child that reported it. bin/fm-watch-arm.sh only prints it while a
  // recovery episode is outstanding, so its absence means there is nothing to
  // hand off and the ordinary wake path applies unchanged.
  const armRecovery = new WeakMap<ChildProcess, RecoveryHandoff>();

  function createPendingActionable(message: string, predecessorArmPid: string): PendingActionableClose {
    return {
      version: 1,
      token: `${process.pid}-${Date.now()}-${++replacementCoordinator.nextTokenId}`,
      message,
      predecessorArmPid,
    };
  }

  function validatePendingActionable(value: unknown): PendingActionableClose {
    if (
      typeof value !== "object" || value === null ||
      (value as { version?: unknown }).version !== 1 ||
      typeof (value as { token?: unknown }).token !== "string" ||
      !/^[0-9]+-[0-9]+-[0-9]+$/.test((value as { token: string }).token) ||
      typeof (value as { message?: unknown }).message !== "string" ||
      !actionableLine((value as { message: string }).message) ||
      typeof (value as { predecessorArmPid?: unknown }).predecessorArmPid !== "string" ||
      !/^[0-9]*$/.test((value as { predecessorArmPid: string }).predecessorArmPid) ||
      ((value as { delivered?: unknown }).delivered !== undefined &&
        (value as { delivered?: unknown }).delivered !== true)
    ) {
      throw new Error(`invalid ${runtimeLabel} replacement actionable handoff at ${actionableHandoff}`);
    }
    return value as PendingActionableClose;
  }

  function validateReplacementHandoff(value: unknown): PendingActionableClose[] {
    if (
      typeof value !== "object" || value === null ||
      (value as { version?: unknown }).version !== 2 ||
      !Array.isArray((value as { pending?: unknown }).pending) ||
      (value as { pending: unknown[] }).pending.length === 0
    ) {
      throw new Error(`invalid ${runtimeLabel} replacement actionable handoff at ${actionableHandoff}`);
    }
    const pending = (value as { pending: unknown[] }).pending.map(validatePendingActionable);
    if (new Set(pending.map((item) => item.token)).size !== pending.length) {
      throw new Error(`invalid ${runtimeLabel} replacement actionable handoff at ${actionableHandoff}`);
    }
    return pending;
  }

  function writeReplacementHandoff(pending: PendingActionableClose[]): void {
    replacementHandoff = [...pending];
    mkdirSync(handoffDir, { recursive: true });
    const temporary = `${actionableHandoff}.tmp-${process.pid}-${++nextHandoffId}`;
    const handoff: ReplacementActionableHandoff = { version: 2, pending };
    try {
      writeFileSync(temporary, `${JSON.stringify(handoff)}\n`, { mode: 0o600 });
      renameSync(temporary, actionableHandoff);
    } catch (error) {
      try {
        unlinkSync(temporary);
      } catch {
        // Preserve the original handoff publication error.
      }
      throw error;
    }
  }

  function persistReplacementHandoff(pending: PendingActionableClose[]): void {
    if (pending.length === 0) return;
    writeReplacementHandoff(pending);
  }

  function loadReplacementHandoff(): PendingActionableClose[] {
    try {
      const pending = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8")));
      replacementHandoff = pending;
      return [...pending];
    } catch (error) {
      if (nodeErrorCode(error) === "ENOENT") {
        replacementHandoff = null;
        return [];
      }
      throw error;
    }
  }

  function mergeReplacementHandoff(pending: PendingActionableClose): void {
    let stored: PendingActionableClose[] = [];
    try {
      stored = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8")));
    } catch (error) {
      if (nodeErrorCode(error) !== "ENOENT") throw error;
    }
    if (!stored.some((item) => item.token === pending.token)) stored.push(pending);
    writeReplacementHandoff(stored);
  }

  function clearReplacementHandoff(pending: PendingActionableClose): void {
    try {
      const stored = validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8")));
      const remaining = stored.filter((item) => item.token !== pending.token);
      if (remaining.length === stored.length) return;
      if (remaining.length > 0) {
        writeReplacementHandoff(remaining);
      } else {
        replacementHandoff = null;
        unlinkSync(actionableHandoff);
      }
    } catch (error) {
      if (nodeErrorCode(error) !== "ENOENT") throw error;
    }
  }

  function lockOwnership(): LockOwnership {
    let lockPid = "";
    try {
      lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
    } catch {
      return "missing";
    }
    if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
    let pid = String(process.pid);
    for (let i = 0; i < 8; i += 1) {
      if (pid === lockPid) return "owned";
      pid = parentPid(pid);
      if (!pid || pid === "1") break;
    }
    return pidAlive(lockPid) ? "other" : "missing";
  }

  async function waitForGenerationChildClose(armChild: ChildProcess | null): Promise<void> {
    if (!armChild) return;
    const closed = armClose.get(armChild);
    if (!closed) return;
    await new Promise<void>((resolveWait) => {
      const timer = setTimeout(resolveWait, armRetireTimeoutMs);
      void closed.then(() => {
        clearTimeout(timer);
        resolveWait();
      });
    });
  }

  async function stopSessionGeneration(owner: SessionGeneration, replacement: boolean): Promise<void> {
    owner.replacement = replacement;
    let persistedTokens = "";
    let persistenceFailed = false;
    try {
      if (replacement && owner.pendingActionables.length > 0) {
        persistReplacementHandoff(owner.pendingActionables);
        persistedTokens = owner.pendingActionables.map((pending) => pending.token).join("\n");
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      for (const pending of owner.pendingActionables) {
        if (replacementCoordinator.pending.some((item: PendingActionableClose) => item.token === pending.token)) continue;
        replacementCoordinator.pending.push({
          ...pending,
          message:
            `${pending.message}\n\nwatcher: FAILED - ${runtimeLabel} extension could not persist ` +
            `a replacement-session actionable wake\n${detail}`,
        });
      }
      persistenceFailed = true;
    } finally {
      const child = stopGeneration(owner);
      await waitForGenerationChildClose(child);
    }
    const currentTokens = owner.pendingActionables.map((pending) => pending.token).join("\n");
    if (replacement && !persistenceFailed && currentTokens && currentTokens !== persistedTokens) {
      persistReplacementHandoff(owner.pendingActionables);
    }
  }

  function markLoaded(): void {
    if (lockOwnership() === "other") return;
    mkdirSync(state, { recursive: true });
    let runtimeIdentity = "";
    if (runtime === "omp") {
      const { bunPath, ompPath } = ompNativeProcessIdentity();
      runtimeIdentity = `${bunPath}\n${ompPath}\n`;
    }
    const contents = `${extensionVersion}\n${process.pid}\n${runtimeIdentity}`;
    const temporary = `${marker}.tmp.${process.pid}.${randomUUID()}`;
    let descriptor = -1;
    try {
      descriptor = openSync(temporary, "wx", 0o600);
      writeFileSync(descriptor, contents, "utf8");
      closeSync(descriptor);
      descriptor = -1;
      // Same-directory rename replaces the marker pathname itself, so a
      // pre-existing symlink is never followed to its target.
      renameSync(temporary, marker);
    } catch (error) {
      if (descriptor >= 0) {
        try {
          closeSync(descriptor);
        } catch {
          // Preserve the publication error; the descriptor may already be closed.
        }
      }
      try {
        unlinkSync(temporary);
      } catch {
        // The temp path may not exist yet or may already have been renamed.
      }
      throw error;
    }
  }

  function classifyClose(
    stdout: string,
    stderr: string,
    code: number | null,
    signal: NodeJS.Signals | null,
  ): CloseClassification {
    const combined = `${stdout}\n${stderr}`.trim();
    const reason = actionableLine(combined);
    if (reason) return { kind: "actionable", message: reason };
    const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
    if (healthy) {
      return {
        kind: "failure",
        message:
          `watcher: FAILED - ${runtimeLabel} extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
      };
    }
    const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
    if (failed) return { kind: "failure", message: failed };
    if (signal) {
      return {
        kind: "failure",
        message:
          `watcher: FAILED - ${runtimeLabel} extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}`,
      };
    }
    if (code && code !== 0) {
      return {
        kind: "failure",
        message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`,
      };
    }
    return {
      kind: "failure",
      message: `watcher: FAILED - ${runtimeLabel} extension arm cycle ended without an actionable reason`,
    };
  }

  async function sendWake(owner: SessionGeneration, message: string, token?: string): Promise<boolean> {
    if (!generationIsLive(owner)) return false;
    const content = encodeOperationalInput(
      "watcher",
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`,
    );
    if (!token) {
      await sendFollowUp(content);
      return generationIsLive(owner);
    }
    let settleConsumption: (consumed: boolean) => void = () => {};
    const consumption = new Promise<boolean>((resolveConsumption) => {
      settleConsumption = resolveConsumption;
    });
    owner.wakeAcknowledgements.set(token, { content, settle: settleConsumption });
    try {
      await sendFollowUp(content);
      let consumeTimer: ReturnType<typeof setTimeout> | undefined;
      const consumeTimeout = new Promise<"timeout">((resolveTimeout) => {
        consumeTimer = setTimeout(() => resolveTimeout("timeout"), wakeConsumeTimeoutMs);
        consumeTimer.unref();
      });
      try {
        const consumed = await Promise.race([consumption, consumeTimeout]);
        if (consumed !== "timeout") return consumed;
      } finally {
        clearTimeout(consumeTimer);
      }
      // The runtime accepted the wake without starting a turn for it: the message
      // is already queued into the running conversation, so it counts as
      // delivered. Returning true here (never false) keeps the pending loop from
      // re-sending the same wake.
      owner.wakeAcknowledgements.delete(token);
      settleConsumption(true);
      return generationIsLive(owner);
    } catch (error) {
      owner.wakeAcknowledgements.delete(token);
      settleConsumption(false);
      throw error;
    }
  }

  function confirmHandlingDelivery(recovery: RecoveryHandoff): { ok: boolean; detail: string } {
    try {
      const result = spawnSync(
        "bash",
        [armScript, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
        {
          cwd: fmRoot,
          encoding: "utf8",
          env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot },
        },
      );
      if (result.status === 0) return { ok: true, detail: "" };
      const stderr = (result.stderr || "").trim();
      return {
        ok: false,
        detail:
          `watcher: FAILED - handling delivery confirmation was rejected ` +
          `(status=${result.status ?? "none"} generation=${recovery.generation} watcherPid=${recovery.watcherPid})` +
          `${stderr ? `\n${stderr}` : ""}`,
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return {
        ok: false,
        detail:
          `watcher: FAILED - handling delivery confirmation could not be executed ` +
          `(generation=${recovery.generation} watcherPid=${recovery.watcherPid})\n${message}`,
      };
    }
  }

  // Retry once against whatever the live successor now reports: the first
  // attempt can lose a race with a generation that moved on between readiness
  // and delivery, and a second attempt costs one bounded call.
  function confirmHandlingDeliveryWithRetry(
    owner: SessionGeneration,
    recovery: RecoveryHandoff,
  ): { ok: boolean; detail: string } {
    const snapshot = (): RecoveryHandoff => {
      const current = owner.child ? armRecovery.get(owner.child) : undefined;
      return current ?? recovery;
    };
    const first = confirmHandlingDelivery(snapshot());
    if (first.ok) return first;
    return confirmHandlingDelivery(snapshot());
  }

  async function deliverActionableWake(
    owner: SessionGeneration,
    message: string,
    repairFailed: boolean,
    token: string,
    recovery?: RecoveryHandoff,
  ): Promise<boolean> {
    if (!generationIsLive(owner)) return false;
    if (recovery) {
      const confirmed = confirmHandlingDeliveryWithRetry(owner, recovery);
      if (!confirmed.ok) {
        if (!pidAlive(recovery.watcherPid)) await retireArm(owner.child);
        return await sendWake(owner, `${message}\n\n${confirmed.detail}`, token);
      }
    }
    if (!repairFailed && offerWakeToBranch) {
      const branchDelivery = offerWakeToBranch(message);
      if (branchDelivery) {
        try {
          await branchDelivery;
          return true;
        } catch {
          // The core retains delivery ownership when branch settlement rejects.
        }
      }
    }
    return await sendWake(owner, message, token);
  }

  function surfaceFailure(owner: SessionGeneration, message: string): void {
    void sendWake(owner, message).catch(() => {
      // The runtime adapter owns delivery errors; continuity restoration never waits on prompting.
    });
  }

  function enqueuePendingActionable(owner: SessionGeneration, pending: PendingActionableClose): void {
    if (owner.pendingActionables.some((item) => item.token === pending.token)) return;
    owner.pendingActionables.push(pending);
    if (owner.stopping && owner.replacement) {
      let replacementPending = pending;
      try {
        mergeReplacementHandoff(pending);
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        replacementPending = {
          ...pending,
          message:
            `${pending.message}\n\nwatcher: FAILED - ${runtimeLabel} extension could not persist ` +
            `a late replacement-session actionable wake\n${detail}`,
        };
      }
      if (replacementCoordinator.receiver) {
        replacementCoordinator.receiver(replacementPending);
      } else if (replacementPending !== pending) {
        replacementCoordinator.pending.push(replacementPending);
      }
    }
  }

  function finishPendingActionable(owner: SessionGeneration, pending: PendingActionableClose): void {
    clearReplacementHandoff(pending);
    const index = owner.pendingActionables.findIndex((item) => item.token === pending.token);
    if (index >= 0) owner.pendingActionables.splice(index, 1);
    owner.cleanupFailure = "";
  }

  function surfaceCleanupFailure(owner: SessionGeneration, error: unknown): void {
    const detail = error instanceof Error ? error.message : String(error);
    if (owner.cleanupFailure === detail) return;
    owner.cleanupFailure = detail;
    surfaceFailure(
      owner,
      `watcher: FAILED - ${runtimeLabel} extension could not clear a delivered replacement-session actionable wake\n${detail}`,
    );
  }

  function schedulePendingCleanup(owner: SessionGeneration): void {
    if (!generationIsLive(owner) || owner.cleanupTimer) return;
    const timer = setTimeout(() => {
      if (owner.cleanupTimer === timer) owner.cleanupTimer = null;
      void processPendingActionables(owner);
    }, retryDelay(1));
    timer.unref();
    owner.cleanupTimer = timer;
  }

  async function processPendingActionables(owner: SessionGeneration): Promise<void> {
    if (!generationIsLive(owner) || owner.restoring || owner.pendingActionables.length === 0) return;
    owner.restoring = true;
    const attemptedCleanup = new Set<string>();
    try {
      while (generationIsLive(owner) && owner.pendingActionables.length > 0) {
        for (const delivered of owner.pendingActionables.filter(
          (item) => item.delivered && !attemptedCleanup.has(item.token),
        )) {
          attemptedCleanup.add(delivered.token);
          try {
            finishPendingActionable(owner, delivered);
          } catch (error) {
            surfaceCleanupFailure(owner, error);
          }
        }
        const pending = owner.pendingActionables.find((item) => !item.delivered);
        if (!pending) break;
        const existingClaim = replacementCoordinator.deliveries.get(pending.token);
        if (existingClaim && existingClaim.owner !== owner) {
          const settlement = await existingClaim.settlement;
          if (!generationIsLive(owner)) return;
          if (settlement === "delivered") {
            pending.delivered = true;
            continue;
          }
          if (replacementCoordinator.deliveries.get(pending.token) === existingClaim) {
            replacementCoordinator.deliveries.delete(pending.token);
          }
        }
        let settleClaim: (settlement: "delivered" | "failed") => void = () => {};
        const settlement = new Promise<"delivered" | "failed">((resolveSettlement) => {
          settleClaim = resolveSettlement;
        });
        const deliveryClaim = { owner, settlement };
        replacementCoordinator.deliveries.set(pending.token, deliveryClaim);
        const releaseClaim = (): void => {
          if (replacementCoordinator.deliveries.get(pending.token) === deliveryClaim) {
            replacementCoordinator.deliveries.delete(pending.token);
          }
        };
        try {
          const restoration = await restoreAfterActionableClose(owner, pending.predecessorArmPid);
          if (!generationIsLive(owner)) {
            settleClaim("failed");
            releaseClaim();
            return;
          }
          const message = restoration.failure
            ? `${pending.message}\n\n${restoration.failure}`
            : pending.message;
          const delivered = await deliverActionableWake(
            owner,
            message,
            Boolean(restoration.failure),
            pending.token,
            restoration.recovery,
          );
          if (!delivered) {
            settleClaim("failed");
            releaseClaim();
            return;
          }
          pending.delivered = true;
          settleClaim("delivered");
          try {
            finishPendingActionable(owner, pending);
          } catch (error) {
            surfaceCleanupFailure(owner, error);
          }
          releaseClaim();
        } catch (error) {
          settleClaim("failed");
          releaseClaim();
          throw error;
        }
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      surfaceFailure(owner, `watcher: FAILED - ${runtimeLabel} extension could not deliver an actionable wake\n${detail}`);
    } finally {
      if (generationIsLive(owner)) {
        owner.restoring = false;
        if (owner.pendingActionables.length > 0) schedulePendingCleanup(owner);
        if (!owner.child && !owner.retryTimer) startArm(owner);
      }
    }
  }

  const receiveReplacementActionable: ReplacementActionableReceiver = (pending) => {
    if (!generationIsLive(generation)) return;
    enqueuePendingActionable(generation, pending);
    void processPendingActionables(generation);
  };

  function retryDelay(attempt: number): number {
    return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
  }

  function waitForRetry(attempt: number): Promise<void> {
    return new Promise((resolveRetry) => {
      const timer = setTimeout(resolveRetry, retryDelay(attempt));
      timer.unref();
    });
  }

  function waitForReadiness(armChild: ChildProcess): Promise<boolean> {
    const readiness = armReadiness.get(armChild);
    if (!readiness) return Promise.resolve(false);
    return new Promise((resolveReady) => {
      const timer = setTimeout(() => resolveReady(false), armReadyTimeoutMs);
      timer.unref();
      void readiness.then((ready) => {
        clearTimeout(timer);
        resolveReady(ready);
      });
    });
  }

  async function retireArm(armChild: ChildProcess | null): Promise<boolean> {
    if (!armChild) return true;
    armChild.kill("SIGTERM");
    const closed = armClose.get(armChild);
    if (!closed) return false;
    return new Promise((resolveRetired) => {
      const timer = setTimeout(() => resolveRetired(false), armRetireTimeoutMs);
      timer.unref();
      void closed.then(() => {
        clearTimeout(timer);
        resolveRetired(true);
      });
    });
  }

  async function restoreAfterActionableClose(
    owner: SessionGeneration,
    predecessorArmPid: string,
  ): Promise<RestorationResult> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (!generationIsLive(owner)) return { failure: "" };
      const replacement = startArm(owner, predecessorArmPid);
      const successorChild = owner.child;
      if (replacement.ok && successorChild && await waitForReadiness(successorChild)) {
        return { failure: "", recovery: armRecovery.get(successorChild) };
      }
      if (replacement.ok) {
        failure = `watcher: FAILED - ${runtimeLabel} extension could not verify a ready successor watcher`;
        if (!(await retireArm(successorChild))) {
          return {
            failure:
              `${failure}\nwatcher: FAILED - ${runtimeLabel} extension could not restore watcher continuity ` +
              `because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`,
          };
        }
      } else {
        failure = /(?:read-only|no live session)/.test(replacement.message)
          ? `watcher: FAILED - ${runtimeLabel} extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}`
          : `watcher: FAILED - ${runtimeLabel} extension could not start the successor watcher cycle\n${replacement.message}`;
        if (/(?:read-only|no live session)/.test(replacement.message)) break;
      }
      if (attempt === retryLimit) break;
      await waitForRetry(attempt + 1);
    }
    return {
      failure: `${failure}\nwatcher: FAILED - ${runtimeLabel} extension could not restore watcher continuity after ${retryLimit} retries`,
    };
  }

  function scheduleRetry(owner: SessionGeneration, message: string, predecessorArmPid: string): void {
    if (!generationIsLive(owner) || owner.child || owner.retryTimer) return;
    const ownership = lockOwnership();
    if (ownership !== "owned") {
      surfaceFailure(
        owner,
        `watcher: FAILED - ${runtimeLabel} extension cannot restore continuity because this session no longer owns the lock\n${message}`,
      );
      return;
    }
    owner.retryFailures += 1;
    if (owner.retryFailures > retryLimit) {
      surfaceFailure(
        owner,
        `watcher: FAILED - ${runtimeLabel} extension could not restore watcher continuity after ${retryLimit} retries\n${message}`,
      );
      return;
    }
    const timer = setTimeout(() => {
      if (owner.retryTimer === timer) owner.retryTimer = null;
      if (!generationIsLive(owner)) return;
      const result = startArm(owner, predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(
          owner,
          `watcher: FAILED - ${runtimeLabel} extension could not launch a continuity retry\n${result.message}`,
        );
      }
    }, retryDelay(owner.retryFailures));
    timer.unref();
    owner.retryTimer = timer;
  }

  function startArm(owner: SessionGeneration, predecessorArmPid = ""): ArmResult {
    if (!generationIsLive(owner)) return { ok: false, message: shuttingDownMessage };
    const ownership = lockOwnership();
    if (ownership === "other") {
      return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    }
    if (ownership === "missing") {
      return {
        ok: false,
        message:
          `watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, ` +
          `then call ${repairToolName} to re-arm`,
      };
    }
    markLoaded();
    if (owner.child) {
      return {
        ok: true,
        message:
          `watcher: unchanged - ${runtimeLabel} extension already owns an arm child; ` +
          `no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    if (owner.retryTimer) {
      return {
        ok: true,
        message:
          `watcher: unchanged - ${runtimeLabel} extension already owns a scheduled continuity retry; ` +
          `no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    const id = ++owner.seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
      FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
    };
    const armChild = spawn(
      "bash",
      [
        "-lc",
        "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; " +
          "[ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; " +
          'exec "$FM_WATCH_ARM_SCRIPT" --restart',
      ],
      {
        cwd: fmRoot,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    owner.child = armChild;
    let stdout = "";
    let stderr = "";
    let settled = false;
    let readinessSettled = false;
    let resolveReadiness: (ready: boolean) => void = () => {};
    let resolveClosed: () => void = () => {};
    const readiness = new Promise<boolean>((resolveReady) => {
      resolveReadiness = resolveReady;
    });
    armReadiness.set(armChild, readiness);
    const closed = new Promise<void>((resolveClosedChild) => {
      resolveClosed = resolveClosedChild;
    });
    armClose.set(armChild, closed);
    const settleReadiness = (ready: boolean): void => {
      if (readinessSettled) return;
      readinessSettled = true;
      resolveReadiness(ready);
    };
    const observeEstablishedArm = (): void => {
      const combined = `${stdout}\n${stderr}`;
      const recovery = combined.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
      if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
      if (/^watcher: (?:started|attached)\b/m.test(combined)) {
        settleReadiness(true);
      }
      const reason = completedActionableLine(stdout) || completedActionableLine(stderr);
      if (reason && !armPendingActionable.has(armChild)) {
        const pending = createPendingActionable(reason, String(armChild.pid ?? ""));
        armPendingActionable.set(armChild, pending);
        enqueuePendingActionable(owner, pending);
      }
    };
    const releaseChild = (): void => {
      if (owner.child === armChild) owner.child = null;
    };
    armChild.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      observeEstablishedArm();
    });
    armChild.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      observeEstablishedArm();
    });
    armChild.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        const pending = armPendingActionable.get(armChild) ??
          createPendingActionable(classification.message, predecessor);
        enqueuePendingActionable(owner, pending);
        if (!generationIsLive(owner)) return;
        owner.retryFailures = 0;
        void processPendingActionables(owner);
        return;
      }
      if (!generationIsLive(owner) || owner.restoring) return;
      scheduleRetry(owner, classification.message, predecessor);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive(owner)) return;
      if (owner.restoring) return;
      scheduleRetry(
        owner,
        `watcher: FAILED - ${runtimeLabel} extension arm child ${id} failed: ${error.message}`,
        String(armChild.pid ?? ""),
      );
    });
    return {
      ok: true,
      message:
        `watcher: started ${runtimeLabel} extension arm child ${id}; future ordinary re-arms are automatic; ` +
        repairOnlyHint,
    };
  }

  async function armAndWait(): Promise<ArmResult> {
    const owner = generation;
    const result = activateOwnedWatch(owner);
    if (!result.ok) return result;
    const armChild = owner.child;
    if (!armChild || await waitForReadiness(armChild)) return result;
    return {
      ok: false,
      message:
        `watcher: FAILED - ${runtimeLabel} extension could not verify a ready watcher within ${armReadyTimeoutMs}ms; ` +
        repairOnlyHint,
    };
  }

  function activateOwnedWatch(owner: SessionGeneration): ArmResult {
    if (!generationIsLive(owner)) return { ok: false, message: shuttingDownMessage };
    if (lockOwnership() !== "owned") return startArm(owner);
    replacementCoordinator.receiver = receiveReplacementActionable;
    let pending: PendingActionableClose[] = [];
    let loadFailure = "";
    try {
      pending = loadReplacementHandoff();
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      loadFailure =
        `watcher: FAILED - ${runtimeLabel} extension could not load a replacement-session actionable wake\n${detail}`;
    }
    const inProcessPending = replacementCoordinator.pending.splice(0);
    for (const actionable of [...pending, ...inProcessPending]) {
      enqueuePendingActionable(owner, actionable);
    }
    if (owner.pendingActionables.length > 0) {
      if (loadFailure) surfaceFailure(owner, loadFailure);
      const armResult = startArm(owner, owner.pendingActionables[0].predecessorArmPid);
      if (!armResult.ok) {
        surfaceFailure(
          owner,
          `watcher: FAILED - ${runtimeLabel} extension could not arm before replacement wake delivery\n${armResult.message}`,
        );
      }
      void processPendingActionables(owner);
      return armResult;
    }
    const result = startArm(owner);
    if (loadFailure) surfaceFailure(owner, `${loadFailure}\n${result.message}`);
    return result;
  }

  function acknowledgeWake(content: string): void {
    for (const [token, acknowledgement] of generation.wakeAcknowledgements) {
      if (acknowledgement.content !== content) continue;
      generation.wakeAcknowledgements.delete(token);
      acknowledgement.settle(true);
      break;
    }
  }

  function sessionStart(): void {
    if (activeBinding !== binding) return;
    if (generation.stopping) generation = createGeneration();
    activateGeneration(generation);
    markLoaded();
    if (lockOwnership() === "owned") activateOwnedWatch(generation);
  }

  async function sessionShutdown(replacement = false): Promise<void> {
    if (activeBinding !== binding) return;
    for (const acknowledgement of generation.wakeAcknowledgements.values()) acknowledgement.settle(false);
    generation.wakeAcknowledgements.clear();
    if (replacementCoordinator.receiver === receiveReplacementActionable) replacementCoordinator.receiver = null;
    await stopSessionGeneration(generation, replacement);
  }

  activeBinding = binding;
  activateGeneration(generation);
  installExitFallback();

  return {
    runtime,
    arm: () => activateOwnedWatch(generation),
    armAndWait,
    acknowledgeWake,
    markLoaded,
    sessionShutdown,
    sessionStart,
  };
}
