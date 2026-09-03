// Firstmate primary watcher bridge for Pi.
//
// Pi-specific extension discovery, session events, follow-up delivery, tool UI,
// and imports stay in this adapter. The watcher lifecycle is shared only through
// the exact-runtime core in bin/fm-primary-watch-core.ts.
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, Theme } from "@earendil-works/pi-coding-agent";
import { Box, Container, Text, type Component } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { createPrimaryWatchCore } from "../../bin/fm-primary-watch-core.ts";
import {
  type CalmPresentationState,
  calmTranscriptClassIsVisible,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
} from "./lib/fm-calm-visibility.ts";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.ts";

type WatchToolShellState = {
  shell?: Box;
  call?: Component;
  result?: Component;
};

type WatchToolRenderContext = {
  isError: boolean;
  isPartial: boolean;
};

function refreshWatchToolShell(
  state: WatchToolShellState,
  theme: Theme,
  context: WatchToolRenderContext,
): Box {
  const background = context.isPartial
    ? (text: string) => theme.bg("toolPendingBg", text)
    : context.isError
      ? (text: string) => theme.bg("toolErrorBg", text)
      : (text: string) => theme.bg("toolSuccessBg", text);
  const shell = state.shell ?? new Box(1, 1, background);
  state.shell = shell;
  shell.setBgFn(background);
  shell.clear();
  if (state.call) shell.addChild(state.call);
  if (state.result) shell.addChild(state.result);
  return shell;
}

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const marker = `${state}/.pi-watch-extension-loaded`;

export default function (pi: ExtensionAPI) {
  let calmPresentation: CalmPresentationState = {
    active: false,
    stockExportRendering: false,
  };
  pi.events?.on?.(FIRSTMATE_CALM_PRESENTATION_EVENT, (data) => {
    const next = data as Partial<CalmPresentationState>;
    calmPresentation = {
      active: next.active === true,
      stockExportRendering: next.stockExportRendering === true,
    };
  });
  const calmHides = (itemClass: Parameters<typeof calmTranscriptClassIsVisible>[0]): boolean =>
    calmPresentation.active &&
    !calmPresentation.stockExportRendering &&
    !calmTranscriptClassIsVisible(itemClass);

  const watch = createPrimaryWatchCore({
    runtime: "pi",
    runtimeLabel: "Pi",
    extensionFile,
    marker,
    fmHome,
    fmRoot,
    state,
    config,
    armReadyTimeoutEnv: "FM_PI_ARM_READY_TIMEOUT_MS",
    repairToolName: "fm_watch_arm_pi",
    encodeOperationalInput: encodeFirstmateOperationalInput,
    sendFollowUp: async (content) => {
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    },
  });

  pi.on?.("before_agent_start", (event) => {
    watch.acknowledgeWake(event.prompt);
  });

  pi.on?.("session_start", () => {
    watch.sessionStart();
  });
  pi.on?.("session_shutdown", async (event) => {
    const replacement = ["reload", "new", "resume", "fork"].includes(String(event.reason ?? ""));
    await watch.sessionShutdown(replacement);
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = watch.arm();
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: "fm_watch_arm_pi",
    label: "Arm firstmate watcher",
    description: "Start the first required Pi watcher cycle, or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the Pi extension re-arms automatically. Never run bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Start the first required Pi watcher cycle or repair a cycle reported missing, failed, or unhealthy; ordinary re-arming is automatic.",
    promptGuidelines: [
      "Call fm_watch_arm_pi only for the first required cycle or after a notification says the cycle is missing, failed, or unhealthy. Do not call it after ordinary work, turn completion, or ordinary signal, stale, check, or heartbeat handling because the Pi extension owns re-arming. Never run bin/fm-watch-arm.sh through bash.",
    ],
    parameters: Type.Object({}),
    renderShell: "self",
    renderCall: (_args, theme, context) => {
      if (calmHides("assistant-tool-call")) return new Container();
      if (calmPresentation.stockExportRendering) {
        return new Text(theme.fg("toolTitle", theme.bold("fm_watch_arm_pi")), 0, 0);
      }
      const shellState = context.state as WatchToolShellState;
      shellState.call = new Text(theme.fg("toolTitle", theme.bold("fm_watch_arm_pi")), 0, 0);
      return refreshWatchToolShell(shellState, theme, context);
    },
    renderResult: (result, _options, theme, context) => {
      if (calmHides("tool-result")) return new Container();
      const output = result.content
        .filter((item) => item.type === "text")
        .map((item) => item.text)
        .join("\n");
      if (calmPresentation.stockExportRendering) {
        return new Text(theme.fg("toolOutput", output), 0, 0);
      }
      const shellState = context.state as WatchToolShellState;
      shellState.result = output
        ? new Text(theme.fg("toolOutput", output), 0, 0)
        : new Container();
      refreshWatchToolShell(shellState, theme, context);
      return new Container();
    },
    execute: async () => {
      const result = watch.arm();
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  watch.markLoaded();
}
