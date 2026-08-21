// Harness-neutral watcher lifecycle core for explicitly verified Pi-compatible runtimes.
// Runtime adapters retain their exact identity, event bindings, extension entry points,
// UI integration, operational-input encoding, and follow-up delivery mechanics.
//
// Session-generation ownership (stated once here): one generation is bound per
// runtime session activation. Only the active live generation may start, stop,
// rearm, or clear the arm child. A runtime-specific replacement event or a
// fresh factory bind activates a new live generation so monitoring can arm
// without restarting the process. Terminal shutdown leaves the final generation
// stopped so late callbacks cannot rearm. Stale callbacks from an earlier
// generation, including callbacks retained by a superseded core instance, are
// no-ops against the active replacement. The active generation and the
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
// the runtime adapter AND this shared core. Verifiers recompute it from the same
// two files (bin/fm-primary-watch-version-lib.sh).
const coreFile = fileURLToPath(import.meta.url);

type LockOwnership = "owned" | "missing" | "other";

type CloseClassification = {
  kind: "actionable" | "failure";
  message: string;
};

type SessionGeneration = {
  id: number;
  stopping: boolean;
  child: ChildProcess | null;
  retryTimer: ReturnType<typeof setTimeout> | null;
  retryFailures: number;
  restoring: boolean;
  seq: number;
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
};

export type PrimaryWatchCore = {
  readonly runtime: "pi" | "omp";
  arm: () => ArmResult;
  armAndWait: () => Promise<ArmResult>;
  markLoaded: () => void;
  sessionShutdown: () => void;
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
let nextGenerationId = 0;
let activeGeneration: SessionGeneration | null = null;
let activeBinding: symbol | null = null;
let exitFallbackInstalled = false;

function createGeneration(): SessionGeneration {
  return {
    id: ++nextGenerationId,
    stopping: false,
    child: null,
    retryTimer: null,
    retryFailures: 0,
    restoring: false,
    seq: 0,
  };
}

function activateGeneration(owner: SessionGeneration): void {
  if (activeGeneration && activeGeneration !== owner) stopGeneration(activeGeneration);
  activeGeneration = owner;
}

function generationIsLive(owner: SessionGeneration): boolean {
  return activeGeneration === owner && !owner.stopping;
}

function stopGeneration(owner: SessionGeneration): void {
  owner.stopping = true;
  clearTimeout(owner.retryTimer ?? undefined);
  owner.retryTimer = null;
  if (owner.child) owner.child.kill("SIGTERM");
  owner.child = null;
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
  } = options;
  const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
  const extensionVersion = `sha256:${createHash("sha256")
    .update(readFileSync(extensionFile))
    .update(readFileSync(coreFile))
    .digest("hex")}`;
  const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
  const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
  const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
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

  async function sendWake(owner: SessionGeneration, message: string): Promise<void> {
    if (!generationIsLive(owner)) return;
    const content = encodeOperationalInput(
      "watcher",
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`,
    );
    await sendFollowUp(content);
  }

  function surfaceFailure(owner: SessionGeneration, message: string): void {
    void sendWake(owner, message).catch(() => {
      // The runtime adapter owns delivery errors; continuity restoration never waits on prompting.
    });
  }

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

  async function restoreAfterActionableClose(owner: SessionGeneration, predecessorArmPid: string): Promise<string> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (!generationIsLive(owner)) return "";
      const replacement = startArm(owner, predecessorArmPid);
      const successorChild = owner.child;
      if (replacement.ok && successorChild && await waitForReadiness(successorChild)) return "";
      if (replacement.ok) {
        failure = `watcher: FAILED - ${runtimeLabel} extension could not verify a ready successor watcher`;
        if (!(await retireArm(successorChild))) {
          return (
            `${failure}\nwatcher: FAILED - ${runtimeLabel} extension could not restore watcher continuity ` +
            `because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`
          );
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
    return `${failure}\nwatcher: FAILED - ${runtimeLabel} extension could not restore watcher continuity after ${retryLimit} retries`;
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
      if (/^watcher: (?:started|attached)\b/m.test(`${stdout}\n${stderr}`)) {
        settleReadiness(true);
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
      if (!generationIsLive(owner)) return;
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        owner.retryFailures = 0;
        owner.restoring = true;
        void (async () => {
          const failure = await restoreAfterActionableClose(owner, predecessor);
          if (generationIsLive(owner)) owner.restoring = false;
          if (!generationIsLive(owner)) return;
          const message = failure ? `${classification.message}\n\n${failure}` : classification.message;
          await sendWake(owner, message);
        })().catch(() => {
        });
        return;
      }
      if (owner.restoring) return;
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
    const result = startArm(owner);
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

  function sessionStart(): void {
    if (activeBinding !== binding) return;
    if (generation.stopping) generation = createGeneration();
    activateGeneration(generation);
    markLoaded();
  }

  function sessionShutdown(): void {
    if (activeBinding !== binding) return;
    stopGeneration(generation);
  }

  activeBinding = binding;
  activateGeneration(generation);
  installExitFallback();

  return {
    runtime,
    arm: () => startArm(generation),
    armAndWait,
    markLoaded,
    sessionShutdown,
    sessionStart,
  };
}
