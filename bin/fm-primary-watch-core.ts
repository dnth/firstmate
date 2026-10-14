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
// replacement and never enters this lifecycle.
//
// Delivery versus consumption (stated once here):
// A main follow-up is delivered once the runtime accepts it (sendFollowUp
// resolves). Consumption is tracked so a replacement can replay a follow-up
// the runtime had not consumed and so a coalescing episode can be retired.
// Consumption evidence is whichever surface the runtime emits: a streaming
// main consumes at before_agent_start or the user message_start carrying the
// exact wake text, while an idle-main injection opens an agent-initiated turn
// that never emits before_agent_start - there the first turn_start after the
// accepted send, or the wake's own custom-role message_start, is the evidence.
// Any of these finishes the pending record. An accepted wake whose in-flight
// marker outlives a full turn boundary, or whose send-time queue rows were
// drained, is also cleared as consumed at turn_end, so a missed consumption
// signal can never suppress every later wake. A main-bound wake that arrives
// after the marker outlives FM_WATCH_MAIN_WAKE_INFLIGHT_BOUND_MS (default
// 120000 ms) likewise retires it and re-delivers through the runtime's
// turn-forcing send, bounded to one forced delivery per interval, so an idle
// or streaming main that never starts a turn for the hidden send is not deaf
// for the rest of the session. Decision-owned wakes bypass coalescing and the
// bound entirely. A still-unconsumed record rides the replacement handoff.
// Consuming a wake also releases the successor grant it spent, so a row that
// lands while that wake's own turn runs earns the next boundary's successor
// instead of waiting for a turn end that finds the queue empty. Every
// main-bound hand-off, suppression, grant, consumption, and the turn that
// finally carries the wake is appended to a bounded delivery ledger;
// docs/omp-supervision-branch.md owns how to read it.
//
// Branch settlement runs outside the serialized delivery loop; the handoff
// and rejection contract is owned by docs/omp-supervision-branch.md under
// "Components and their owners".
//
// The active generation and the process-exit fallback are process-wide, not
// per-core-instance.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  appendFileSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  statSync,
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
  fallbackOnly?: true;
  branchOffered?: true;
};

type UnconsumedWake = {
  content: string;
  pending: PendingActionableClose;
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
  // Main follow-ups the runtime has accepted but not yet consumed, by pending
  // token. Never cleared at shutdown: a delivery continuation that runs after
  // the replacement began reads it to tell a main-queued wake (replayed) from a
  // branch-handled one (finished).
  unconsumedWakes: Map<string, UnconsumedWake>;
  // A verified successor's failure close that arrived while the pipeline was
  // still delivering the wake it was started for; its bounded retry runs once
  // that delivery settles instead of being skipped by the single-flight guard.
  deferredClose: { message: string; predecessorArmPid: string } | null;
  // Closes the supervision branch accepted and has not settled yet, by pending
  // token. The delivery loop never waits on a branch: an accepted close stays
  // pending here until its settlement resolves (finished) or rejects (moved to
  // main-only delivery so the loop delivers it without a second offer).
  branchInFlight: Set<string>;
  // Main-fallback coalescing (docs/omp-supervision-branch.md "Main-fallback
  // re-entry coalescing"): while a main fallback notification's handling
  // episode is open, further main-bound injections are suppressed so a burst of
  // actionable closes cannot preempt the active handler. mainFallbackSuccessor
  // is a one-shot grant a turn boundary issues when unread main-owned rows
  // remain; episodeCoalesced names the closes whose notification the in-flight
  // episode covered, so an acknowledged boundary can finish them without a
  // second injection.
  mainFallbackEpisode: boolean;
  mainFallbackSuccessor: boolean;
  mainFallbackSuccessorGranted: boolean;
  episodeCoalesced: Set<string>;
  // A turn boundary that arrived while a delivery run was still in flight.
  // Evaluating then could retire the episode beneath a close that has not
  // reached its suppression point, so the boundary is replayed once the run
  // settles.
  pendingTurnEnd: boolean;
  mainFallbackWakeInFlight: string | null;
  mainFallbackBaselineRows: Set<string> | null;
  // Wedge evidence for an in-flight fallback wake whose consumption events the
  // runtime may never emit (the idle-main injection path raises neither
  // before_agent_start nor a user-role message_start): the queue rows pending
  // when it was sent, the count of turn boundaries it has outlived, and the
  // timestamps persisted for off-process diagnosis.
  mainFallbackInFlightRows: Set<string> | null;
  mainFallbackInFlightTurnEnds: number;
  mainFallbackWakeSentAtMs: number | null;
  mainFallbackWakeConsumedAtMs: number | null;
  lastTurnStartAtMs: number | null;
  lastTurnEndAtMs: number | null;
  // Recent main hand-offs by ledger wake id, so the turn that finally carries
  // a wake can be tied back to its close and hand-off time. Diagnostic only.
  sentWakes: Map<string, { content: string; close: string; sentAtMs: number; consumed: boolean }>;
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
  // A forceTurn option asks the runtime adapter to choose a transport that
  // starts an agent-initiated turn even while the session is streaming or
  // agent-initiated turns are deferred; the core requests it only for a stale
  // in-flight re-delivery or a decision-owned wake.
  sendFollowUp: (content: string, options?: { forceTurn?: boolean; wakeId?: string }) => Promise<void> | void;
  // Optional supervision-branch dispatch handshake. A synchronous non-null
  // settlement means the branch accepted handling. The core never waits on it
  // inside its delivery loop: later closes, their successor arms, and main-only
  // rows proceed while the branch works, the close finishes when the
  // settlement resolves, and a rejection returns delivery ownership to the
  // core's consumption-acknowledged main path exactly once.
  // Never offered for repair-failed delivery: only main can repair the cycle.
  offerWakeToBranch?: (message: string) => Promise<void> | null;
  // Coalesce main-fallback wake injections behind the active handling episode.
  // Only adapters that report main turn boundaries through turnEnd() may enable
  // it: without that callback an episode could never close and suppressed wakes
  // would starve.
  coalesceMainFallbackWakes?: boolean;
  // A decision-owned main wake is never coalesced behind an in-flight fallback
  // wake or an open episode; only meaningful with coalesceMainFallbackWakes.
  isDecisionOwnedWake?: (message: string) => boolean;
};

export type PrimaryWatchCore = {
  readonly runtime: "pi" | "omp";
  arm: () => ArmResult;
  armAndWait: () => Promise<ArmResult>;
  // evidence names the runtime surface that showed the wake being read; it is
  // recorded in the delivery ledger and never changes the consumption match.
  acknowledgeWake: (content: string, evidence?: string, deliveryId?: string) => void;
  // The runtime started a model turn whose input carries this wake message.
  // Recorded in the delivery ledger only; consumption is acknowledgeWake's.
  wakeEnteredTurn: (content: string, deliveryId?: string) => void;
  notifyWake: (content: string, forceTurn?: boolean) => Promise<void> | void;
  hasPendingActionableHandoff: () => boolean;
  ownsLock: () => boolean;
  markLoaded: () => void;
  sessionShutdown: (replacement?: boolean) => Promise<void>;
  sessionStart: () => void;
  // A main turn opened: positive consumption evidence for an accepted wake on
  // runtimes where the injection path emits no before_agent_start.
  turnStart: () => void;
  turnEnd: () => void;
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
    unconsumedWakes: new Map(),
    branchInFlight: new Set(),
    deferredClose: null,
    mainFallbackEpisode: false,
    mainFallbackSuccessor: false,
    mainFallbackSuccessorGranted: false,
    episodeCoalesced: new Set(),
    pendingTurnEnd: false,
    mainFallbackWakeInFlight: null,
    mainFallbackBaselineRows: null,
    mainFallbackInFlightRows: null,
    mainFallbackInFlightTurnEnds: 0,
    mainFallbackWakeSentAtMs: null,
    mainFallbackWakeConsumedAtMs: null,
    lastTurnStartAtMs: null,
    lastTurnEndAtMs: null,
    sentWakes: new Map(),
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
    coalesceMainFallbackWakes = false,
    isDecisionOwnedWake,
  } = options;
  const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
  const handoffDir = `${state}/extensions/${runtime}-primary-watch`;
  const actionableHandoff = `${handoffDir}/session-replacement-actionable.json`;
  // Durable, diagnostic-only mirror of the main-fallback episode so a wedge is
  // readable from disk (and fm-guard.sh can warn on an in-flight wake that has
  // outlived a full turn boundary) instead of living only in this process.
  const episodeStateFile = `${handoffDir}/main-fallback-episode.state`;
  // Append-only, bounded record of every main-bound wake hand-off and what
  // became of it, so a drop is distinguishable from a coalesce after the fact.
  const deliveryLedgerFile = `${handoffDir}/main-wake-deliveries.log`;
  const deliveryLedgerKeepLines = 2000;
  const deliveryLedgerTrimBytes = 512 * 1024;
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
  const armReadyTimeoutMs = positiveInteger(
    armReadyTimeoutEnv,
    process.platform === "win32" ? 35000 : 12000,
  );
  const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
  // Wall-clock bound on an accepted-but-unconsumed main fallback wake: once the
  // marker outlives this, the next main-bound wake may force one re-delivery
  // per bound interval instead of suppressing forever (docs/omp-supervision-branch.md).
  const mainFallbackWakeInFlightBoundMs = positiveInteger("FM_WATCH_MAIN_WAKE_INFLIGHT_BOUND_MS", 120000);
  const repairOnlyHint =
    `call ${repairToolName} again only after a later notification says the cycle is missing, failed, or unhealthy`;
  const shuttingDownMessage = `watcher: not armed - ${runtimeLabel} session is shutting down`;

  const binding = Symbol(`${runtime}-primary-watch-binding`);
  let generation = createGeneration();
  const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
  const armClose = new WeakMap<ChildProcess, Promise<void>>();
  // Children the core itself asked to exit; their close is not a failure of the
  // successor and never earns a deferred retry.
  const armRetired = new WeakSet<ChildProcess>();
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
        (value as { delivered?: unknown }).delivered !== true) ||
      ((value as { fallbackOnly?: unknown }).fallbackOnly !== undefined &&
        (value as { fallbackOnly?: unknown }).fallbackOnly !== true) ||
      ((value as { branchOffered?: unknown }).branchOffered !== undefined &&
        (value as { branchOffered?: unknown }).branchOffered !== true)
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

  // Best-effort atomic write of the episode mirror. Failures are swallowed:
  // this file is diagnosis, never delivery authority. Nothing is written until
  // an episode exists or a prior file needs its terminal state refreshed.
  let episodeStateWrites = 0;
  function persistEpisodeState(owner: SessionGeneration): void {
    if (!coalesceMainFallbackWakes) return;
    if (
      !owner.mainFallbackEpisode &&
      !owner.mainFallbackWakeInFlight &&
      !existsSync(episodeStateFile)
    ) {
      return;
    }
    const temporary = `${episodeStateFile}.tmp-${process.pid}-${++episodeStateWrites}`;
    try {
      mkdirSync(handoffDir, { recursive: true });
      const inFlightToken = owner.mainFallbackWakeInFlight
        ? createHash("sha256").update(owner.mainFallbackWakeInFlight).digest("hex").slice(0, 16)
        : "";
      writeFileSync(
        temporary,
        [
          "version=1",
          `generation=${owner.id}`,
          `episode=${owner.mainFallbackEpisode ? 1 : 0}`,
          `in_flight=${owner.mainFallbackWakeInFlight ? 1 : 0}`,
          `in_flight_token=${inFlightToken}`,
          `in_flight_sent_at_ms=${owner.mainFallbackWakeSentAtMs ?? 0}`,
          `in_flight_turn_ends=${owner.mainFallbackInFlightTurnEnds}`,
          `successor_granted=${owner.mainFallbackSuccessorGranted ? 1 : 0}`,
          `last_consume_at_ms=${owner.mainFallbackWakeConsumedAtMs ?? 0}`,
          `last_turn_start_at_ms=${owner.lastTurnStartAtMs ?? 0}`,
          `last_turn_end_at_ms=${owner.lastTurnEndAtMs ?? 0}`,
          `updated_at_ms=${Date.now()}`,
          "",
        ].join("\n"),
        { mode: 0o600 },
      );
      renameSync(temporary, episodeStateFile);
    } catch {
      try {
        unlinkSync(temporary);
      } catch {
        // The temp file may not have been created.
      }
    }
  }

  // Best-effort append to the delivery ledger, trimmed to its newest lines once
  // it outgrows its byte bound. Like the episode mirror it is diagnosis only:
  // a failed write never affects delivery.
  let deliveryLedgerWrites = 0;
  function recordWakeEvent(owner: SessionGeneration, event: string, fields: Array<[string, string | number]>): void {
    if (!coalesceMainFallbackWakes) return;
    const value = (raw: string | number): string => String(raw).replace(/[\t\r\n]+/g, " ").slice(0, 240);
    const line = [String(Date.now()), event, `gen=${owner.id}`, ...fields.map(([key, raw]) => `${key}=${value(raw)}`)]
      .join("\t");
    try {
      mkdirSync(handoffDir, { recursive: true });
      appendFileSync(deliveryLedgerFile, `${line}\n`, { mode: 0o600 });
      if (statSync(deliveryLedgerFile).size <= deliveryLedgerTrimBytes) return;
      const kept = readFileSync(deliveryLedgerFile, "utf8").split("\n").filter(Boolean).slice(-deliveryLedgerKeepLines);
      const temporary = `${deliveryLedgerFile}.tmp-${process.pid}-${++deliveryLedgerWrites}`;
      try {
        writeFileSync(temporary, kept.map((entry) => `${entry}\n`).join(""), { mode: 0o600 });
        renameSync(temporary, deliveryLedgerFile);
      } catch {
        try {
          unlinkSync(temporary);
        } catch {
          // The temp file may not have been created.
        }
      }
    } catch {
      // The ledger is diagnosis, never delivery authority.
    }
  }

  const closeReason = (message: string): string => message.split(/\r?\n/, 1)[0] ?? "";

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
      if (coalesceMainFallbackWakes) {
        owner.mainFallbackWakeInFlight = null;
        owner.mainFallbackInFlightRows = null;
        owner.mainFallbackInFlightTurnEnds = 0;
        owner.mainFallbackWakeSentAtMs = null;
        owner.mainFallbackEpisode = false;
        owner.mainFallbackSuccessor = false;
        owner.mainFallbackSuccessorGranted = false;
        owner.mainFallbackBaselineRows = null;
        persistEpisodeState(owner);
      }
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

  function notifyWake(
    content: string,
    forceTurn = false,
    owner = generation,
    close = "-",
    kind = "notice",
    reason = closeReason(content),
  ): Promise<void> | void {
    const id = randomUUID();
    owner.sentWakes.set(id, { content, close, sentAtMs: Date.now(), consumed: false });
    if (owner.sentWakes.size > 64) owner.sentWakes.delete(owner.sentWakes.keys().next().value as string);
    recordWakeEvent(owner, "sent", [
      ["wake", id], ["close", close], ["kind", kind], ["force", forceTurn ? 1 : 0], ["reason", reason],
    ]);
    const failed = (error: unknown): never => {
      owner.sentWakes.delete(id);
      recordWakeEvent(owner, "send-failed", [
        ["wake", id], ["close", close], ["error", error instanceof Error ? error.message : String(error)],
      ]);
      throw error;
    };
    try {
      const result = sendFollowUp(content, { forceTurn, wakeId: id });
      if (result) return result.catch(failed);
    } catch (error) {
      return failed(error);
    }
  }

  // Deliver a wake to main. The runtime accepting the follow-up is the
  // delivery; consumption is a separate event observed by the adapter (see the
  // delivery-versus-consumption contract at the top of this file). Until
  // consumption the pending record is kept in unconsumedWakes so a session
  // replacement can replay it.
  async function sendWake(
    owner: SessionGeneration,
    message: string,
    pending?: PendingActionableClose,
    trackMainFallback = false,
    forceTurn = false,
  ): Promise<boolean> {
    if (!generationIsLive(owner)) return false;
    const content = encodeOperationalInput(
      "watcher",
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`,
    );
    const sentAtMs = Date.now();
    if (pending) owner.unconsumedWakes.set(pending.token, { content, pending });
    if (trackMainFallback) {
      owner.mainFallbackWakeInFlight = content;
      owner.mainFallbackInFlightTurnEnds = 0;
      owner.mainFallbackWakeSentAtMs = sentAtMs;
      // Rows pending at send time are the drain-evidence baseline: if a later
      // boundary finds every one retired, the wake was handled even though no
      // consumption event ever surfaced.
      owner.mainFallbackInFlightRows = owner.mainFallbackBaselineRows ?? mainOwnedWakeSnapshot();
    }
    const kind = !pending ? "notice"
      : pending.fallbackOnly ? "synthetic"
        : owner.mainFallbackSuccessor ? "successor"
          : "close";
    try {
      await notifyWake(content, forceTurn, owner, pending?.token ?? "-", kind, closeReason(message));
    } catch (error) {
      if (pending) owner.unconsumedWakes.delete(pending.token);
      if (trackMainFallback && owner.mainFallbackWakeInFlight === content) {
        owner.mainFallbackWakeInFlight = null;
        owner.mainFallbackInFlightRows = null;
        owner.mainFallbackWakeSentAtMs = null;
        owner.mainFallbackInFlightTurnEnds = 0;
        if (generationIsLive(owner)) persistEpisodeState(owner);
      }
      throw error;
    }
    if (trackMainFallback && generationIsLive(owner)) persistEpisodeState(owner);
    // Accepted by the runtime. A generation replaced while the runtime was
    // accepting the follow-up may have lost the message with the old session,
    // so report it undelivered and let the replacement replay the still-pending
    // record.
    return generationIsLive(owner);
  }

  // The runtime consumed a main follow-up - or bookkeeping determined a
  // still-in-flight wake was handled/wedged past its bound (turnEnd). Either
  // way the pending record finishes and the in-flight marker clears. Clearing
  // the marker also releases the successor grant that wake spent: its rows
  // have now reached main, and the baseline check in turnEnd keeps a new grant
  // waiting until the drain that wake asked for has retired them.
  function consumeWake(owner: SessionGeneration, text: string, evidence: string, deliveryId?: string): void {
    for (const [token, wake] of owner.unconsumedWakes) {
      if (wake.content !== text) continue;
      owner.unconsumedWakes.delete(token);
      wake.pending.delivered = true;
      try {
        finishPendingActionable(owner, wake.pending);
      } catch (error) {
        surfaceCleanupFailure(owner, error);
        schedulePendingCleanup(owner);
      }
      break;
    }
    const inFlight = owner.mainFallbackWakeInFlight === text;
    if (inFlight) {
      owner.mainFallbackWakeInFlight = null;
      owner.mainFallbackInFlightRows = null;
      owner.mainFallbackInFlightTurnEnds = 0;
      owner.mainFallbackSuccessorGranted = false;
      owner.mainFallbackWakeConsumedAtMs = Date.now();
      persistEpisodeState(owner);
    }
    const delivery = [...owner.sentWakes].find(([id, sent]) =>
      sent.content === text && !sent.consumed && (!deliveryId || id === deliveryId));
    if (!delivery) return;
    const [id, sent] = delivery;
    sent.consumed = true;
    recordWakeEvent(owner, "consumed", [
      ["wake", id], ["close", sent.close], ["by", evidence], ["after_ms", Date.now() - sent.sentAtMs],
    ]);
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

  // A wake bound for MAIN while its fallback episode is still open is
  // suppressed instead of injected: the episode's drain already covers every
  // queued row, and a second operational notification can only preempt the
  // active handler. "delivered" is also the answer when the boundary pass has
  // mooted main delivery (queue already drained) while a branch offer is still
  // allowed to run.
  type MainWakeOutcome = "delivered" | "suppressed" | "failed";
  // Wall-clock stale check for an accepted-but-never-consumed in-flight wake:
  // the runtime queued the hidden send without ever starting or consuming a
  // turn for it. A turn that started after the send proves the runtime is
  // draining instead, so only an in-flight marker with no post-send turn
  // counts as stale. Retrying is bounded implicitly: one forced delivery per
  // bound interval, driven by the next main-bound wake - never a timer.
  function inFlightWakeUnconsumedPastBound(owner: SessionGeneration): boolean {
    if (!owner.mainFallbackWakeInFlight) return false;
    if (owner.mainFallbackWakeSentAtMs === null) return false;
    if (Date.now() - owner.mainFallbackWakeSentAtMs < mainFallbackWakeInFlightBoundMs) return false;
    return !(owner.lastTurnStartAtMs !== null && owner.lastTurnStartAtMs >= owner.mainFallbackWakeSentAtMs);
  }

  async function deliverMainWake(
    owner: SessionGeneration,
    message: string,
    pending: PendingActionableClose,
  ): Promise<MainWakeOutcome> {
    // Two bypasses ahead of ordinary episode coalescing. A stale in-flight
    // marker - accepted but unconsumed past
    // FM_WATCH_MAIN_WAKE_INFLIGHT_BOUND_MS - no longer earns suppression; the
    // wake re-delivers through the runtime's turn-forcing send so a main that
    // queued the hidden send without a turn hears the re-delivery out loud.
    // A decision-owned wake is never coalesced either: it bypasses suppression
    // behind an in-flight marker or an open episode and also forces the turn
    // (docs/omp-supervision-branch.md). In both cases the superseded marker is
    // retired exactly as the turnEnd stale bound does: its pending record
    // finishes, while the durable rows stay until a drain acknowledges them.
    const staleInFlight = coalesceMainFallbackWakes && inFlightWakeUnconsumedPastBound(owner);
    const decisionBypass = coalesceMainFallbackWakes && Boolean(isDecisionOwnedWake?.(message));
    const forceTurn = staleInFlight || decisionBypass;
    if (forceTurn && owner.mainFallbackWakeInFlight) {
      consumeWake(owner, owner.mainFallbackWakeInFlight, staleInFlight ? "inflight-bound" : "decision-bypass");
    }
    if (coalesceMainFallbackWakes && owner.mainFallbackWakeInFlight) {
      owner.mainFallbackEpisode = true;
      recordWakeEvent(owner, "suppressed", [
        ["close", pending.token],
        ["behind", "in-flight"],
        ["reason", closeReason(message)],
      ]);
      return "suppressed";
    }
    if (coalesceMainFallbackWakes && !forceTurn && owner.mainFallbackEpisode && !owner.mainFallbackSuccessor) {
      recordWakeEvent(owner, "suppressed", [
        ["close", pending.token],
        ["behind", "episode"],
        ["reason", closeReason(message)],
      ]);
      return "suppressed";
    }
    // Open the episode before the awaited send so a turn boundary landing while
    // the runtime accepts the follow-up still sees this notification in flight.
    if (coalesceMainFallbackWakes) {
      let baselineRows = owner.mainFallbackBaselineRows ?? mainOwnedWakeSnapshot();
      if (!baselineRows && mainOwnedWakeRows() === 0) baselineRows = new Set();
      if (!baselineRows) {
        schedulePendingCleanup(owner);
        return "failed";
      }
      owner.mainFallbackEpisode = true;
      if (!owner.mainFallbackSuccessor && !owner.mainFallbackWakeInFlight) {
        owner.mainFallbackSuccessorGranted = false;
      }
      owner.mainFallbackBaselineRows = baselineRows;
      // A record actually being sent is no longer coalesced, so a failed send
      // can be retried by a later boundary grant instead of staying invisible.
      owner.episodeCoalesced.delete(pending.token);
    }
    try {
      return (await sendWake(owner, message, pending, coalesceMainFallbackWakes, forceTurn)) ? "delivered" : "failed";
    } finally {
      // The grant pays for exactly one send attempt: a failure before confirmed
      // acceptance is replayed by a later boundary grant, never by letting a
      // mid-episode close inherit the unconsumed grant.
      if (coalesceMainFallbackWakes) owner.mainFallbackSuccessor = false;
      if (coalesceMainFallbackWakes && !owner.mainFallbackWakeInFlight) {
        owner.mainFallbackSuccessorGranted = false;
      }
    }
  }

  type ActionableWakeOutcome = MainWakeOutcome | { branch: Promise<void> };

  async function deliverActionableWake(
    owner: SessionGeneration,
    message: string,
    repairFailed: boolean,
    pending: PendingActionableClose,
    recovery?: RecoveryHandoff,
  ): Promise<ActionableWakeOutcome> {
    if (!generationIsLive(owner)) return "failed";
    if (recovery) {
      const confirmed = confirmHandlingDeliveryWithRetry(owner, recovery);
      if (!confirmed.ok) {
        if (!pidAlive(recovery.watcherPid)) await retireArm(owner.child);
        return await deliverMainWake(owner, `${message}\n\n${confirmed.detail}`, pending);
      }
    }
    if (!repairFailed && offerWakeToBranch) {
      const branchDelivery = offerWakeToBranch(message);
      // Accepted: the branch owns handling. The loop does not wait for it -
      // trackBranchSettlement reconciles the record when it settles.
      if (branchDelivery) return { branch: branchDelivery };
    }
    return await deliverMainWake(owner, message, pending);
  }

  // A branch-accepted close stays pending, but outside the delivery loop's
  // candidates, until the branch settles. Resolution finishes it exactly as a
  // synchronous branch delivery did; rejection hands it back so the loop
  // delivers it to main once, through the ordinary coalescing path, without a
  // second branch offer or a second successor restore. The replacement claim
  // stays open until then; replacement sessions also defer only this close
  // and replay it only if the branch rejected it.
  function trackBranchSettlement(
    owner: SessionGeneration,
    pending: PendingActionableClose,
    settlement: Promise<void>,
    settleClaim: (settlement: "delivered" | "failed") => void,
    releaseClaim: () => void,
  ): void {
    owner.branchInFlight.add(pending.token);
    settlement.then(
      () => {
        owner.branchInFlight.delete(pending.token);
        settleClaim("delivered");
        releaseClaim();
        pending.delivered = true;
        try {
          finishPendingActionable(owner, pending);
        } catch (error) {
          surfaceCleanupFailure(owner, error);
          schedulePendingCleanup(owner);
        }
      },
      () => {
        owner.branchInFlight.delete(pending.token);
        settleClaim("failed");
        releaseClaim();
        if (!generationIsLive(owner)) return;
        void processPendingActionables(owner);
      },
    );
  }

  function surfaceFailure(owner: SessionGeneration, message: string): void {
    if (coalesceMainFallbackWakes && (owner.mainFallbackWakeInFlight || owner.mainFallbackEpisode)) {
      if (owner.pendingActionables.some((pending) => !pending.delivered && !owner.unconsumedWakes.has(pending.token) && !owner.branchInFlight.has(pending.token))) {
        owner.mainFallbackSuccessor = true;
        schedulePendingCleanup(owner);
      }
      return;
    }
    if (coalesceMainFallbackWakes) {
      owner.mainFallbackEpisode = true;
      if (!owner.mainFallbackBaselineRows) owner.mainFallbackBaselineRows = mainOwnedWakeSnapshot();
    }
    void sendWake(owner, message, undefined, coalesceMainFallbackWakes).catch(() => {
      if (coalesceMainFallbackWakes && !owner.mainFallbackWakeInFlight) {
        owner.mainFallbackEpisode = false;
        owner.mainFallbackBaselineRows = null;
      }
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
        // A record the runtime has accepted but not consumed is neither
        // redelivered nor finished here: consumption finishes it; replacement
        // replays it. A record a branch is still handling is skipped the same
        // way: its settlement finishes it or hands it back.
        const pending = owner.pendingActionables.find(
          (item) =>
            !item.delivered &&
            !owner.unconsumedWakes.has(item.token) &&
            !owner.episodeCoalesced.has(item.token) &&
            !owner.branchInFlight.has(item.token),
        );
        if (!pending) break;
        const existingClaim = replacementCoordinator.deliveries.get(pending.token);
        if (existingClaim && existingClaim.owner !== owner) {
          owner.branchInFlight.add(pending.token);
          void existingClaim.settlement.then((result) => {
            owner.branchInFlight.delete(pending.token);
            if (!generationIsLive(owner)) return;
            if (result === "delivered") pending.delivered = true;
            if (replacementCoordinator.deliveries.get(pending.token) === existingClaim) {
              replacementCoordinator.deliveries.delete(pending.token);
            }
            void processPendingActionables(owner);
          });
          continue;
        }
        let settleClaim: (settlement: "delivered" | "failed") => void = () => {};
        const settlement = new Promise<"delivered" | "failed">((resolveSettlement) => {
          settleClaim = resolveSettlement;
        });
        const deliveryClaim: ActionableDeliveryClaim = { owner, settlement };
        replacementCoordinator.deliveries.set(pending.token, deliveryClaim);
        const releaseClaim = (): void => {
          if (replacementCoordinator.deliveries.get(pending.token) === deliveryClaim) {
            replacementCoordinator.deliveries.delete(pending.token);
          }
        };
        try {
          // A close the branch handed back already has its successor and its
          // handling-delivery handshake; it only still owes main a delivery.
          const alreadyOfferedToBranch = pending.branchOffered === true;
          // A new restoration supersedes whatever became of the previous
          // successor; only a failure during this delivery is retried after it.
          if (!alreadyOfferedToBranch) owner.deferredClose = null;
          const restoration = pending.fallbackOnly || alreadyOfferedToBranch
            ? { failure: "", recovery: undefined }
            : await restoreAfterActionableClose(owner, pending.predecessorArmPid);
          if (!generationIsLive(owner)) {
            settleClaim("failed");
            releaseClaim();
            return;
          }
          const message = restoration.failure
            ? `${pending.message}\n\n${restoration.failure}`
            : pending.message;
          let outcome: ActionableWakeOutcome;
          if (pending.fallbackOnly) {
            let baselineRows = owner.mainFallbackBaselineRows ?? mainOwnedWakeSnapshot();
            if (!baselineRows && mainOwnedWakeRows() === 0) baselineRows = new Set();
            if (!baselineRows) {
              schedulePendingCleanup(owner);
              outcome = "failed";
            } else {
              owner.mainFallbackEpisode = true;
              owner.mainFallbackBaselineRows = baselineRows;
              outcome = (await sendWake(owner, message, pending, coalesceMainFallbackWakes))
                ? "delivered"
                : "failed";
            }
          } else if (alreadyOfferedToBranch) {
            outcome = await deliverMainWake(owner, message, pending);
          } else {
            outcome = await deliverActionableWake(
              owner,
              message,
              Boolean(restoration.failure),
              pending,
              restoration.recovery,
            );
          }
          if (typeof outcome === "object") {
            // Handed to the branch. Its successor already runs, so the next
            // close - including a main-only row - proceeds now; the claim
            // stays open until the branch settles.
            pending.branchOffered = true;
            recordWakeEvent(owner, "branch-accepted", [["close", pending.token], ["reason", closeReason(message)]]);
            trackBranchSettlement(owner, pending, outcome.branch, settleClaim, releaseClaim);
            continue;
          }
          if (outcome === "suppressed") {
            if (restoration.failure) {
              scheduleRetry(owner, restoration.failure, pending.predecessorArmPid);
            }
            // The open main-fallback episode's drain covers this close's rows:
            // the record stays durable and undelivered until a turn boundary
            // either retires it (queue drained) or grants it the one successor
            // injection (rows remain). "failed" settles any cross-generation
            // waiter into the replay path, which re-evaluates the same guard.
            // Continue rather than break: the coalesced mark excludes this
            // record from the next find, while closes queued behind it still
            // earn their mark - and their successor arm - inside this run.
            owner.episodeCoalesced.add(pending.token);
            settleClaim("failed");
            releaseClaim();
            continue;
          }
          if (outcome !== "delivered") {
            if (pending.fallbackOnly && !owner.mainFallbackWakeInFlight) {
              owner.mainFallbackSuccessorGranted = false;
            }
            settleClaim("failed");
            releaseClaim();
            return;
          }
          const awaitingConsumption = owner.unconsumedWakes.has(pending.token);
          if (awaitingConsumption && !generationIsLive(owner)) {
            // The runtime accepted the follow-up, then the session was replaced
            // before this continuation ran: the shutdown persisted the still-
            // pending record, so a replacement waiting on this claim must
            // replay it.
            settleClaim("failed");
            releaseClaim();
            return;
          }
          settleClaim("delivered");
          if (!awaitingConsumption) {
            // The branch handled it, or the runtime consumed it before this ran.
            pending.delivered = true;
            try {
              finishPendingActionable(owner, pending);
            } catch (error) {
              surfaceCleanupFailure(owner, error);
            }
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
        if (owner.pendingTurnEnd) {
          owner.pendingTurnEnd = false;
          turnEnd();
        }
        if (owner.pendingActionables.some((pending) => pending.delivered)) schedulePendingCleanup(owner);
        // No bare arm is launched here. A generation without a child at this
        // point has either delivered a typed restoration failure after its
        // bounded retries, which hands repair to main through fm_watch_arm_pi
        // (one more silent launch past the bound could hold a hung child that
        // the repair call would then report as "unchanged"), or lost a verified
        // successor during the delivery, which takes the ordinary bounded,
        // lock-checked retry it would have taken had the pipeline been idle.
        const deferred = owner.deferredClose;
        owner.deferredClose = null;
        if (deferred && !owner.child && !owner.retryTimer) {
          scheduleRetry(owner, deferred.message, deferred.predecessorArmPid);
        }
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
    armRetired.add(armChild);
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
    let verified = false;
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
      verified = ready;
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
      if (!generationIsLive(owner)) return;
      if (owner.restoring) {
        // The pipeline is still delivering the wake this successor was started
        // for. A verified successor that failed on its own keeps its bounded
        // retry for the end of that delivery; an unready child closing here was
        // retired by the restoration itself.
        if (verified && !armRetired.has(armChild)) {
          owner.deferredClose = { message: classification.message, predecessorArmPid: predecessor };
        }
        return;
      }
      scheduleRetry(owner, classification.message, predecessor);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive(owner)) return;
      if (owner.restoring) {
        if (verified && !armRetired.has(armChild)) {
          owner.deferredClose = { message: `watcher: FAILED - ${runtimeLabel} extension arm child ${id} failed: ${error.message}`, predecessorArmPid: String(armChild.pid ?? "") };
        }
        return;
      }
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

  // True while the core still owns an actionable wake it has not delivered.
  function hasPendingActionableHandoff(): boolean {
    if (replacementCoordinator.pending.length > 0) return true;
    if (generation.pendingActionables.some((pending) => !pending.delivered)) return true;
    try {
      return validateReplacementHandoff(JSON.parse(readFileSync(actionableHandoff, "utf8")))
        .some((pending) => !pending.delivered);
    } catch {
      return false;
    }
  }

  function acknowledgeWake(content: string, evidence = "runtime", deliveryId?: string): void {
    consumeWake(generation, content, evidence, deliveryId);
  }

  // Consumption can be recorded before the wake's turn runs - OMP raises
  // before_agent_start when it stages a hidden next-turn prompt behind a
  // streaming run - so the ledger also records when the wake message itself
  // enters a model turn. A hand-off with no such line never reached the model.
  function wakeEnteredTurn(content: string, deliveryId?: string): void {
    const owner = generation;
    const delivery = [...owner.sentWakes].find(([id, sent]) =>
      sent.content === content && (!deliveryId || id === deliveryId));
    if (!delivery) return;
    const [id, sent] = delivery;
    owner.sentWakes.delete(id);
    recordWakeEvent(owner, "turn", [["wake", id], ["close", sent.close], ["after_ms", Date.now() - sent.sentAtMs]]);
  }

  // Unread rows main can still present or retire - exactly the set a main drain
  // would act on (bin/fm-wake-lib.sh's fm_wake_actor_pending_count owns the
  // per-actor count, including live branch-grant exclusion). An uncountable
  // queue is not evidence of an empty one: fail toward "rows remain" so an open
  // episode is never closed early and a successor is retried at the next
  // boundary.
  function mainOwnedWakeRows(): number {
    const result = spawnSync(
      "bash",
      ["-c", '. "$1/bin/fm-wake-lib.sh"; fm_wake_actor_pending_count main', "fm-main-wake-count", fmRoot],
      {
        encoding: "utf8",
        env: { ...process.env, FM_HOME: fmHome, FM_ROOT_OVERRIDE: fmRoot, FM_STATE_OVERRIDE: state },
      },
    );
    const count = Number((result.stdout || "").trim());
    return Number.isFinite(count) && count >= 0 ? count : 1;
  }

  function mainOwnedWakeSnapshot(): Set<string> | null {
    const result = spawnSync(
      "bash",
      ["-c", '. "$1/bin/fm-wake-lib.sh"; fm_wake_actor_pending_rows main', "fm-main-wake-rows", fmRoot],
      {
        encoding: "utf8",
        env: { ...process.env, FM_HOME: fmHome, FM_ROOT_OVERRIDE: fmRoot, FM_STATE_OVERRIDE: state },
      },
    );
    if (result.status !== 0) return null;
    return new Set((result.stdout || "").split(/\r?\n/).filter(Boolean));
  }

  // A main turn opened. An idle-main injection drives agent.prompt() directly,
  // which emits no before_agent_start and arrives as a custom-role message, so
  // the first turn boundary after an accepted send is itself the consumption
  // evidence: the runtime only starts a turn for a message it has accepted into
  // the prompt. A turn that was already streaming when its wake was queued
  // emitted its turn_start before the send, so this can only clear a marker
  // whose own turn (or a later one) has actually begun.
  function turnStart(): void {
    const owner = generation;
    owner.lastTurnStartAtMs = Date.now();
    if (!coalesceMainFallbackWakes || !generationIsLive(owner)) return;
    if (owner.mainFallbackWakeInFlight) consumeWake(owner, owner.mainFallbackWakeInFlight, "turn_start");
    persistEpisodeState(owner);
  }

  // Main turn boundary: the only safe point to evaluate a suppressed burst.
  // While an episode is open, unread main-owned rows mean the acknowledged
  // drain left work behind - grant exactly one successor injection. A fully
  // drained queue retires the episode and finishes every close it covered, so
  // no redundant notification follows an acknowledgement that consumed them.
  // The in-flight marker is bounded here too: if every row pending at send
  // time has been drained, or the marker has outlived a full turn boundary
  // (two consecutive turn ends without consumption), the wake is treated as
  // consumed instead of suppressing every later main-bound wake forever.
  // Turn boundaries alone cannot help an idle or streaming main that never
  // starts a turn, so deliverMainWake also enforces the wall-clock bound
  // FM_WATCH_MAIN_WAKE_INFLIGHT_BOUND_MS and the decision-owned bypass (see
  // the delivery-versus-consumption contract at the top of this file).
  function turnEnd(): void {
    const owner = generation;
    if (!coalesceMainFallbackWakes || !generationIsLive(owner)) return;
    owner.lastTurnEndAtMs = Date.now();
    try {
      if (!owner.mainFallbackEpisode) return;
      if (owner.restoring) {
        // A delivery run is mid-flight: a close in its restore phase has not
        // reached the suppression point yet, so an empty queue here could
        // retire the episode under it and let that close inject late.
        // Re-evaluate the boundary when the run settles.
        owner.pendingTurnEnd = true;
        return;
      }
      if (owner.mainFallbackWakeInFlight) {
        owner.mainFallbackInFlightTurnEnds += 1;
      } else {
        owner.mainFallbackInFlightTurnEnds = 0;
      }
      const rowCount = mainOwnedWakeRows();
      if (rowCount > 0) {
        let clearedStaleInFlight = false;
        if (owner.mainFallbackWakeInFlight) {
          const sendRows = owner.mainFallbackInFlightRows;
          const sendRowsDrained = sendRows !== null &&
            ((): boolean => {
              const currentRows = mainOwnedWakeSnapshot();
              return currentRows !== null &&
                ![...sendRows].some((row) => currentRows.has(row));
            })();
          // Two boundaries survived means the marker outlived one full turn
          // interval without the runtime surfacing any consumption event.
          if (sendRowsDrained || owner.mainFallbackInFlightTurnEnds >= 2) {
            consumeWake(
              owner,
              owner.mainFallbackWakeInFlight,
              sendRowsDrained ? "turn_end:rows-drained" : "turn_end:turn-bound",
            );
            clearedStaleInFlight = true;
          }
        }
        const retry = owner.pendingActionables.find(
          (pending) => !pending.delivered && !owner.unconsumedWakes.has(pending.token) &&
            !owner.episodeCoalesced.has(pending.token) && !owner.branchInFlight.has(pending.token),
        );
        if (retry && !owner.mainFallbackWakeInFlight) {
          owner.mainFallbackSuccessor = true;
          void processPendingActionables(owner);
          return;
        }
        if (!owner.mainFallbackBaselineRows) {
          const recoveredRows = mainOwnedWakeSnapshot();
          if (!recoveredRows) return;
          owner.mainFallbackBaselineRows = recoveredRows;
          return;
        }
        const currentRows = mainOwnedWakeSnapshot();
        if (!currentRows) return;
        if (
          !clearedStaleInFlight &&
          [...owner.mainFallbackBaselineRows].some((row) => currentRows.has(row))
        ) {
          return;
        }
        // The successor is the newest close whose notification was never
        // accepted: oldest-first would re-present rows the drain already
        // acknowledged. Coalesced marks are cleared only for that record so
        // the run loop delivers exactly it and re-suppresses the rest. A
        // just-cleared stale marker skips the baseline early return above:
        // its notification was never read, so the rows it covered still earn
        // one successor injection.
        const next = owner.pendingActionables
          .filter((pending) =>
            !pending.delivered && !owner.unconsumedWakes.has(pending.token) && !owner.branchInFlight.has(pending.token))
          .pop();
        if (next && !owner.mainFallbackWakeInFlight && !owner.mainFallbackSuccessorGranted) {
          owner.mainFallbackSuccessor = true;
          owner.mainFallbackSuccessorGranted = true;
          if (currentRows) owner.mainFallbackBaselineRows = currentRows;
          owner.episodeCoalesced.delete(next.token);
          recordWakeEvent(owner, "granted", [["close", next.token], ["kind", "successor"]]);
          void processPendingActionables(owner);
        } else if (
          owner.pendingActionables.every((pending) => pending.delivered || owner.branchInFlight.has(pending.token)) &&
          !owner.mainFallbackWakeInFlight &&
          !owner.mainFallbackSuccessorGranted
        ) {
        // Rows outlived every close record (e.g. appended after the last
        // actionable close): a synthetic wake re-presents them. The episode
        // stays open so the next boundary re-evaluates.
        const successor = createPendingActionable(
          "signal: watcher wakes remain queued after the acknowledged episode",
          "",
        );
        successor.fallbackOnly = true;
        owner.mainFallbackSuccessorGranted = true;
        // The rows this synthetic wake re-presents are its baseline, exactly as
        // for a close successor, so releasing the grant at its consumption
        // cannot re-grant before its drain has retired them.
        owner.mainFallbackBaselineRows = currentRows;
        enqueuePendingActionable(owner, successor);
        recordWakeEvent(owner, "granted", [["close", successor.token], ["kind", "synthetic"]]);
        void processPendingActionables(owner);
      }
      // Otherwise every undelivered record is an accepted-but-unconsumed wake:
      // that in-flight notification already covers the unread rows.
      return;
    }
      // An empty queue under a still-set in-flight marker means the wake's own
      // turn ran and drained everything while its consumption events never
      // surfaced; keeping the marker would wedge every later wake behind it.
      if (owner.mainFallbackWakeInFlight) consumeWake(owner, owner.mainFallbackWakeInFlight, "turn_end:queue-empty");
      owner.mainFallbackEpisode = false;
      owner.mainFallbackSuccessor = false;
      owner.mainFallbackSuccessorGranted = false;
      owner.mainFallbackBaselineRows = null;
      owner.mainFallbackInFlightRows = null;
      owner.mainFallbackInFlightTurnEnds = 0;
      for (const pending of owner.pendingActionables.filter(
        (item) => !item.delivered && owner.episodeCoalesced.has(item.token),
      )) {
        pending.delivered = true;
        owner.episodeCoalesced.delete(pending.token);
        recordWakeEvent(owner, "covered", [["close", pending.token], ["by", "queue-drained"]]);
        try {
          finishPendingActionable(owner, pending);
        } catch (error) {
          surfaceCleanupFailure(owner, error);
          schedulePendingCleanup(owner);
        }
      }
    } finally {
      persistEpisodeState(owner);
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
    // unconsumedWakes is intentionally not cleared here. A delivery continuation
    // that runs after the replacement began uses it to decide whether a pending
    // record still needs to be replayed.
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
    wakeEnteredTurn,
    notifyWake,
    hasPendingActionableHandoff,
    ownsLock: () => lockOwnership() === "owned",
    markLoaded,
    sessionShutdown,
    sessionStart,
    turnStart,
    turnEnd,
  };
}
