// Firstmate primary integration for OMP.
// OMP-native session, stop, tool-call, and shutdown events stay in this adapter.
import { spawn, spawnSync } from "node:child_process";
import { renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  BeforeAgentStartEventResult,
  ExtensionAPI,
  ExtensionContext,
  SessionStopEvent,
  SessionStopEventResult,
} from "@oh-my-pi/pi-coding-agent";
import { createPrimaryWatchCore, ompNativeProcessIdentity } from "../../bin/fm-primary-watch-core.ts";
import {
  createBranchDispatchOffer,
  FM_BRANCH_DISPATCH_EVENT,
  scopeForUnreadWake,
} from "./lib/fm-branch-dispatch.ts";
import { installTaskInboxDoorbell } from "./lib/fm-task-inbox-doorbell.ts";

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const marker = `${state}/.omp-primary-extension-loaded`;
const operationalInputScript = `${fmRoot}/bin/fm-operational-input.sh`;

type ProcessResult = {
  code: number;
  stderr: string;
};

function encodeOperationalInput(kind: "session-start" | "watcher" | "turn-end-guard", content: string): string {
  const result = spawnSync(operationalInputScript, ["encode", kind], {
    encoding: "utf8",
    input: content,
    maxBuffer: 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`could not encode Firstmate operational input kind ${kind}`);
  return result.stdout;
}

function primaryIntegrationApplies(): boolean {
  const result = spawnSync(
    "bash",
    [
      "-c",
      `
        . "$1/bin/fm-gate-refuse-lib.sh"
        . "$1/bin/fm-primary-scope-lib.sh"
        ! fm_is_gate_agent "$1" || exit 1
        fm_primary_scope_matches "$1" "$2" && exit 0
        # Only the native OMP owner admits a first plain launch before its
        # canonical state directory exists. Generic hooks remain silent.
        [ "$2" = "$1/state" ] && [ ! -e "$2" ] && [ ! -L "$2" ] || exit 1
        [ -f "$1/AGENTS.md" ] && [ -d "$1/bin" ] || exit 1
        git_dir=$(git -C "$1" rev-parse --git-dir 2>/dev/null) || exit 1
        git_common_dir=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || exit 1
        [ "$git_dir" = "$git_common_dir" ]
      `,
      "fm-omp-primary-scope",
      fmRoot,
      state,
    ],
    { stdio: "ignore" },
  );
  return result.status === 0;
}

function publishNativeProcessIdentity(): void {
  const { bunPath, ompPath } = ompNativeProcessIdentity();
  process.env.FM_OMP_PROCESS_EXPECTED_BUN = bunPath;
  process.env.FM_OMP_PROCESS_EXPECTED_BIN = ompPath;
}

function publishSecondmateSession(ctx: ExtensionContext): void {
  const pointer = process.env.FM_OMP_SESSION_POINTER;
  if (!pointer || !isAbsolute(pointer)) return;
  const sessionFile = ctx.sessionManager.getSessionFile();
  if (!sessionFile || !isAbsolute(sessionFile)) return;
  const temp = `${pointer}.tmp.${process.pid}`;
  try {
    writeFileSync(temp, `${sessionFile}\n`, { mode: 0o600 });
    renameSync(temp, pointer);
  } catch {
    try {
      unlinkSync(temp);
    } catch {
      // The temporary file may not have been created.
    }
    // Session persistence must never break the live OMP conversation.
  }
}

function runSessionstartNudge(forceForNativeSwitch = false): string {
  if (forceForNativeSwitch) {
    if (!primaryIntegrationApplies()) return "";
    return encodeOperationalInput(
      "session-start",
      "Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.",
    );
  }
  const result = spawnSync(`${fmRoot}/bin/fm-sessionstart-nudge.sh`, [], {
    encoding: "utf8",
    env: {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_STATE_OVERRIDE: state,
      FM_CONFIG_OVERRIDE: config,
    },
  });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function runChecker(script: string, flag: "--command" | "--tool", value: string): Promise<ProcessResult> {
  return new Promise((resolveResult) => {
    const child = spawn(`${fmRoot}/bin/${script}`, [flag, value], {
      env: {
        ...process.env,
        FM_HOME: fmHome,
        FM_ROOT_OVERRIDE: fmRoot,
        FM_STATE_OVERRIDE: state,
        FM_CONFIG_OVERRIDE: config,
      },
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}

function runGuard(event: SessionStopEvent): Promise<ProcessResult> {
  return new Promise((resolveResult) => {
    const child = spawn(`${fmRoot}/bin/fm-turnend-guard.sh`, {
      env: {
        ...process.env,
        FM_HOME: fmHome,
        FM_ROOT_OVERRIDE: fmRoot,
        FM_STATE_OVERRIDE: state,
        FM_CONFIG_OVERRIDE: config,
      },
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    let settled = false;
    const settle = (result: ProcessResult): void => {
      if (settled) return;
      settled = true;
      event.signal.removeEventListener("abort", abort);
      resolveResult(result);
    };
    const abort = (): void => {
      child.kill("SIGTERM");
      settle({ code: 0, stderr: "" });
    };
    if (event.signal.aborted) {
      abort();
      return;
    }
    event.signal.addEventListener("abort", abort, { once: true });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => settle({ code: 0, stderr: "" }));
    child.on("close", (code) => settle({ code: code ?? 0, stderr }));
    child.stdin.end(JSON.stringify({
      session_id: event.session_id,
      stop_hook_active: event.stop_hook_active,
    }));
  });
}

export default function (omp: ExtensionAPI) {
  if (!primaryIntegrationApplies()) return;
  publishNativeProcessIdentity();
  const retireTaskInboxDoorbell = installTaskInboxDoorbell(omp);
  let pendingStartupNudge = "";

  // Supervision-branch dispatch handshake (docs/omp-supervision-branch.md).
  // Build one offer per ordinary actionable wake and emit it on the shared
  // event bus; a live, enabled branch extension calls accept() synchronously
  // inside its handler (EventBus.emit runs a synchronous handler to completion
  // before returning), so reading offer.accepted right after emit routes
  // branch-vs-main. A check-kind trigger (merge polls, relay mentions,
  // credential/auth failures) is never offered - it stays main-owned - and with
  // no branch extension loaded no one accepts, so every wake falls through to
  // main exactly as before.
  const offerWakeToBranch = (message: string): boolean => {
    const heartbeat = /^heartbeat($|:)/.test(message);
    const isCheckTrigger = /^check:/.test(message);
    const scope = scopeForUnreadWake(state, heartbeat);
    const eligible = !isCheckTrigger && scope.eligible;
    const offer = createBranchDispatchOffer(message, scope.projects, heartbeat, eligible);
    omp.events?.emit?.(FM_BRANCH_DISPATCH_EVENT, offer);
    return offer.accepted;
  };

  const watch = createPrimaryWatchCore({
    runtime: "omp",
    runtimeLabel: "OMP",
    extensionFile,
    marker,
    fmHome,
    fmRoot,
    state,
    config,
    armReadyTimeoutEnv: "FM_OMP_ARM_READY_TIMEOUT_MS",
    repairToolName: "fm_watch_arm_omp",
    encodeOperationalInput,
    sendFollowUp: async (content) => {
      // Deliver a custom steer so OMP wakes idle sessions without touching the editable draft.
      omp.sendMessage(
        {
          customType: "firstmate-watcher-wake",
          content,
          display: false,
          attribution: "agent",
          details: { kind: "watcher", runtime: "omp" },
        },
        { deliverAs: "steer", triggerTurn: true },
      );
    },
    offerWakeToBranch,
  });

  const deliverSessionstartNudge = (forceForNativeSwitch = false): void => {
    watch.markLoaded();
    pendingStartupNudge = runSessionstartNudge(forceForNativeSwitch);
  };

  omp.on("session_start", (_event, ctx) => {
    watch.sessionStart();
    publishSecondmateSession(ctx);
    deliverSessionstartNudge();
  });

  omp.on("session_switch", (event, ctx) => {
    watch.sessionShutdown();
    watch.sessionStart();
    publishSecondmateSession(ctx);
    deliverSessionstartNudge(event.reason === "new" || event.reason === "resume");
    watch.arm();
  });

  omp.on("before_agent_start", (): BeforeAgentStartEventResult | undefined => {
    if (!pendingStartupNudge) return undefined;
    const content = pendingStartupNudge;
    pendingStartupNudge = "";
    return {
      message: {
        customType: "firstmate-sessionstart-nudge",
        content,
        display: false,
        attribution: "agent",
        details: { kind: "session-start", runtime: "omp" },
      },
    };
  });

  omp.on("session_stop", async (event): Promise<SessionStopEventResult | undefined> => {
    if (event.stop_hook_active) return undefined;
    const result = await runGuard(event);
    if (result.code !== 2) return undefined;
    const additionalContext = encodeOperationalInput(
      "turn-end-guard",
      "TURN WOULD END BLIND - supervision is off. " +
        "The watcher cycle is missing, failed, or unhealthy. " +
        "Follow the OMP supervision recovery instruction below before ending the turn.\n\n" +
        result.stderr,
    );
    return { continue: true, additionalContext };
  });

  omp.on("tool_call", async (event) => {
    const delegation = await runChecker("fm-subagent-pretool-check.sh", "--tool", event.toolName);
    if (delegation.code === 2) {
      return { block: true, reason: delegation.stderr.trim() || "denied by the delegation-shape seatbelt" };
    }
    if (event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const directory = await runChecker("fm-cd-pretool-check.sh", "--command", command);
    if (directory.code === 2) {
      return { block: true, reason: directory.stderr.trim() || "denied by the directory-change seatbelt" };
    }
    const watcher = await runChecker("fm-arm-pretool-check.sh", "--command", command);
    if (watcher.code === 2) {
      return { block: true, reason: watcher.stderr.trim() || "denied by the watcher-arm seatbelt" };
    }
    return {};
  });

  omp.on("session_shutdown", () => {
    retireTaskInboxDoorbell();
    watch.sessionShutdown();
  });

  omp.registerCommand("fm-watch-arm-omp", {
    description: "Arm Firstmate watcher supervision through the OMP primary integration.",
    handler: async (_args, ctx) => {
      const result = await watch.armAndWait();
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  omp.registerTool({
    name: "fm_watch_arm_omp",
    label: "Firstmate Watch Arm",
    description: "Start or repair the extension-owned Firstmate watcher cycle only when required.",
    parameters: omp.zod.object({}),
    approval: "exec",
    async execute() {
      const result = await watch.armAndWait();
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  watch.markLoaded();
}
