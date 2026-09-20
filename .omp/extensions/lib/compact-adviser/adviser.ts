// Hint-only compact adviser lifecycle for the Firstmate OMP primary session.
// Ported from upstream compact-adviser packages/pi-extension/src/adviser.ts
// at pinned commit b2a27b59ce86af4dc8fb5141e169bfbed1e68cee, adapted to the
// OMP 18.2.6 extension surface:
//   - Pi's `agent_settled` maps to OMP `agent_end` gated on `willContinue !== true`
//     so an auto-retry continuation is never treated as a settled checkpoint.
//   - Pi's `session_before_fork` is covered by OMP `session_before_switch`
//     (reason "fork"); OMP has no `model_select` event - an in-flight judgment
//     is still invalidated by the sessionIdentity comparison, and a stale
//     post-compaction baseline only delays hints conservatively.
//   - The hint surface is person-only: ctx.ui.setWidget/setStatus. sendMessage
//     and before_agent_start injection are forbidden for hints because every
//     deliverAs variant enters model context (captain-resolved contract).
//   - Automatic compaction is not ported: mode "auto" is rejected by config
//     validation and no code path calls ctx.compact().
//   - The Pi >=0.82 version gate is dropped; the adapter targets the verified
//     OMP 18.2.6 extension API.
import type {
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionContext,
} from "@oh-my-pi/pi-coding-agent";
import {
  type Config,
  ConfigStore,
  DEFAULT_CONFIG,
  type Mode,
  parseMinimum,
} from "./config.ts";
import { snapshot } from "./context.ts";
import { DISABLE_ENV, disabledByEnv } from "./disable.ts";
import { formatKeyStatus, type ResolvedTypesafeApiKey, resolveTypesafeApiKey } from "./env.ts";
import {
  floorFor,
  JUDGE_UNAVAILABLE_MESSAGE,
  type Judgment,
  judge,
  qualifies,
  requestBody,
} from "./judge.ts";
import { appendErrorLog, appendRequestLog, appendResponseLog, requestLogPath } from "./log.ts";
import {
  cooldownReason,
  initialState,
  lastResponse,
  restoreState,
  type SessionState,
  STATE_TYPE,
} from "./state.ts";

const LABEL = "compact-adviser";
const HINT = "Compact adviser: work appears completed or recorded. Run /compact to save tokens.";
const USAGE =
  "Use /compact-adviser hint, off, status, threshold <tokens|default>, snooze or dismiss.";
interface Options {
  /** Directory holding compact-adviser.json (the explicit opt-in record). */
  configDir: string;
  /** Directory for the sanitized request log when logRequests is on. */
  logDir: string;
  key?: () => string | undefined;
  now?: () => number;
  evaluate?: (
    state: unknown,
    key: string,
    signal: AbortSignal,
  ) => Promise<Judgment>;
}
function savedApiKey(store: ConfigStore): string | undefined {
  try {
    return store.read().typesafeApiKey;
  } catch {
    return undefined;
  }
}
export function installAdviser(pi: ExtensionAPI, options: Options): void {
  // `COMPACT_ADVISER_DISABLE` is read once per install: a session's environment is fixed,
  // and re-reading it per event would only invite a mid-session half-disabled state.
  if (disabledByEnv(process.env[DISABLE_ENV])) return;
  const store = new ConfigStore(options.configDir);
  const resolvedKey = (): ResolvedTypesafeApiKey => {
    if (options.key) {
      const value = options.key();
      return value !== undefined && value.trim() !== ""
        ? { value, source: "env" }
        : { value: undefined, source: "missing" };
    }
    return resolveTypesafeApiKey(process.env, process.cwd(), savedApiKey(store));
  };
  const key = () => resolvedKey().value;
  const now = options.now ?? Date.now;
  const evaluate =
    options.evaluate ??
    ((state, key, signal) => judge(state, key, signal));
  let generation = 0;
  let lifetime = 0;
  let request: AbortController | undefined;
  let compacting = false;
  let hintVisible = false;
  let diagnostic = "";
  const active = (ctx: ExtensionContext) => ctx.mode === "tui" && ctx.hasUI;
  function persist(state: SessionState) {
    pi.appendEntry(STATE_TYPE, state);
  }
  function clearStatus(ctx: ExtensionContext) {
    if (active(ctx)) ctx.ui.setStatus(LABEL, undefined);
  }
  function notice(ctx: ExtensionContext, message: string) {
    if (!active(ctx) || diagnostic === message) return;
    diagnostic = message;
    ctx.ui.notify(message, "warning");
  }
  function refresh(ctx: ExtensionContext) {
    try {
      store.read();
    } catch {
      notice(ctx, "Cannot read compact-adviser settings; automatic action is disabled.");
    }
  }
  function invalidate(ctx: ExtensionContext) {
    generation++;
    request?.abort();
    request = undefined;
    if (hintVisible && active(ctx)) ctx.ui.setWidget(LABEL, undefined);
    hintVisible = false;
  }
  function eligible(ctx: ExtensionContext, c: Config, s: SessionState): number | undefined {
    const usage = ctx.getContextUsage();
    if (
      !ctx.model ||
      !active(ctx) ||
      compacting ||
      !ctx.isIdle() ||
      ctx.hasPendingMessages() ||
      ctx.ui.getEditorText?.().trim() ||
      c.mode === "off" ||
      !key()?.trim() ||
      !usage ||
      usage.tokens === null ||
      !Number.isFinite(usage.tokens) ||
      !Number.isFinite(usage.contextWindow) ||
      usage.contextWindow <= 0 ||
      usage.tokens < c.minContextTokens ||
      cooldownReason(s, usage.tokens, now())
    )
      return undefined;
    return usage.tokens;
  }
  /** Context tokens over the model's window, or NaN when OMP does not know it (strictest floor). */
  function usageFraction(ctx: ExtensionContext): number {
    const usage = ctx.getContextUsage();
    if (
      !usage ||
      usage.tokens === null ||
      !Number.isFinite(usage.tokens) ||
      !Number.isFinite(usage.contextWindow) ||
      usage.contextWindow <= 0
    )
      return Number.NaN;
    return usage.tokens / usage.contextWindow;
  }
  function sessionIdentity(ctx: ExtensionContext) {
    return JSON.stringify([
      ctx.sessionManager.getSessionId(),
      ctx.sessionManager.getLeafId(),
      ctx.model?.provider,
      ctx.model?.id,
    ]);
  }
  async function settled(ctx: ExtensionContext) {
    if (!active(ctx)) return;
    let state = restoreState(ctx.sessionManager.getBranch());
    const last = lastResponse(ctx.sessionManager.getBranch());
    if (last?.message.stopReason !== "stop" || state.lastSettled === last.id) return;
    state = { ...state, lastSettled: last.id, completed: state.completed + 1 };
    const tokens = ctx.getContextUsage()?.tokens;
    if (
      state.compactionId &&
      state.baseline === null &&
      typeof tokens === "number" &&
      Number.isFinite(tokens)
    )
      state.baseline = tokens;
    persist(state);
    let config: Config;
    try {
      config = store.read();
    } catch {
      refresh(ctx);
      return;
    }
    if (request || eligible(ctx, config, state) === undefined) return;
    const view = snapshot(ctx, [key(), savedApiKey(store)]);
    if (view.conversationTokens <= 20000 || view.checkpointKey === state.lastHintKey) return;
    let loggedBody: string | undefined;
    if (config.logRequests) {
      try {
        loggedBody = requestBody(view.state);
        appendRequestLog(options.logDir, loggedBody);
      } catch {
        // Request logging must not replace or delay the judgment.
      }
    }
    const controller = new AbortController();
    request = controller;
    const epoch = generation,
      identity = sessionIdentity(ctx),
      configIdentity = JSON.stringify(config);
    const current = () =>
      !controller.signal.aborted && generation === epoch && sessionIdentity(ctx) === identity;
    try {
      const result = await evaluate(view.state, key()?.trim() ?? "", controller.signal);
      if (!current()) return;
      if (config.logRequests) {
        try {
          appendResponseLog(
            options.logDir,
            loggedBody ?? requestBody(view.state),
            result,
            usageFraction(ctx),
          );
        } catch {
          // Response logging must not replace the gate decision.
        }
      }
      // No await between this final cross-session configuration/state check and the hint.
      const latest = store.read();
      if (JSON.stringify(latest) !== configIdentity || eligible(ctx, latest, state) === undefined)
        return;
      state = { ...state, failures: 0, retryAfter: 0 };
      if (!qualifies(result, usageFraction(ctx))) {
        persist(state);
        return;
      }
      diagnostic = "";
      state = { ...state, lastHintAt: state.completed, lastHintKey: view.checkpointKey };
      persist(state);
      ctx.ui.setWidget(LABEL, [HINT]);
      hintVisible = true;
    } catch (error) {
      if (!current()) return;
      if (config.logRequests) {
        try {
          appendErrorLog(options.logDir, error, loggedBody);
        } catch {
          // Error logging must not replace backoff.
        }
      }
      const failures = Math.min(state.failures + 1, 6);
      persist({ ...state, failures, retryAfter: now() + Math.min(300000, 5000 * 2 ** failures) });
      notice(
        ctx,
        error instanceof Error && error.name === "JudgeError"
          ? error.message
          : JUDGE_UNAVAILABLE_MESSAGE,
      );
    } finally {
      if (request === controller) request = undefined;
    }
  }
  pi.on("turn_end", (_event, ctx) => {
    if (!ctx.isIdle() && hintVisible) invalidate(ctx);
  });
  pi.on("agent_end", (event, ctx) => {
    // willContinue marks an auto-retry continuation, not a settled checkpoint.
    if (event.willContinue === true) return;
    void settled(ctx).catch(() =>
      notice(ctx, "Compact adviser could not inspect this checkpoint; context left unchanged."),
    );
  });
  pi.on("session_start", (_event, ctx) => {
    lifetime++;
    invalidate(ctx);
    compacting = false;
    clearStatus(ctx);
    refresh(ctx);
  });
  pi.on("before_agent_start", (_event, ctx) => {
    invalidate(ctx);
    compacting = false;
  });
  pi.on("input", (_event, ctx) => {
    invalidate(ctx);
  });
  pi.on("session_before_compact", (_event, ctx) => {
    invalidate(ctx);
    compacting = true;
  });
  pi.on("session_compact", (event, ctx) => {
    if (!active(ctx)) return;
    invalidate(ctx);
    compacting = false;
    persist(initialState(event.compactionEntry.id));
    refresh(ctx);
  });
  pi.on("session_before_switch", (_event, ctx) => {
    lifetime++;
    invalidate(ctx);
  });
  pi.on("session_switch", (_event, ctx) => {
    invalidate(ctx);
    compacting = false;
    refresh(ctx);
  });
  pi.on("session_before_branch", (_event, ctx) => {
    lifetime++;
    invalidate(ctx);
  });
  pi.on("session_branch", (_event, ctx) => {
    invalidate(ctx);
    compacting = false;
    refresh(ctx);
  });
  pi.on("session_before_tree", (_event, ctx) => {
    lifetime++;
    invalidate(ctx);
  });
  pi.on("session_tree", (_event, ctx) => {
    invalidate(ctx);
    compacting = false;
    refresh(ctx);
  });
  pi.on("session_shutdown", (_event, ctx) => {
    lifetime++;
    invalidate(ctx);
    compacting = false;
    clearStatus(ctx);
  });

  function save(ctx: ExtensionContext, patch: Partial<Config>, message: string) {
    invalidate(ctx);
    store.update(patch);
    diagnostic = "";
    ctx.ui.notify(message, "info");
  }
  function changeMode(ctx: ExtensionCommandContext, mode: Mode) {
    save(
      ctx,
      { mode },
      `${mode === "hint" ? "Hints only" : "Off"} saved (all sessions). Compaction stays manual.`,
    );
  }
  function minimum(ctx: ExtensionCommandContext, text: string) {
    const count = text === "default" ? DEFAULT_CONFIG.minContextTokens : parseMinimum(text);
    save(
      ctx,
      { minContextTokens: count },
      `Minimum context saved: ${count.toLocaleString("en-US")} tokens (all sessions).`,
    );
    if (ctx.model && count >= ctx.model.contextWindow)
      ctx.ui.notify(
        "This minimum is at or above the active model's context window. Opportunistic advice will not trigger before native compaction.",
        "warning",
      );
  }
  function status(ctx: ExtensionCommandContext) {
    const c = store.read(),
      s = restoreState(ctx.sessionManager.getBranch()),
      t = ctx.getContextUsage()?.tokens,
      u = usageFraction(ctx);
    ctx.ui.notify(
      `Mode: ${c.mode}. Minimum: ${c.minContextTokens.toLocaleString("en-US")} tokens. Context: ${t ?? "unknown"}${Number.isFinite(u) ? ` (${Math.round(u * 100)}% of the window; hint floor ${floorFor(u).toFixed(2)})` : ""}. ${formatKeyStatus(resolvedKey().source)}. ${typeof t === "number" ? (cooldownReason(s, t, now()) ?? "No cooldown; semantic checks still apply.") : "Waiting for fresh model usage."} Request log: ${c.logRequests ? requestLogPath(options.logDir) : "off"}. Settings: ${store.path}`,
      "info",
    );
  }
  pi.registerCommand("compact-adviser", {
    description: "Configure persistent compaction advice and token minimum",
    getArgumentCompletions: (prefix) =>
      ["hint", "off", "status", "threshold ", "threshold default", "snooze", "dismiss"]
        .filter((v) => v.startsWith(prefix))
        .map((value) => ({ value, label: value })),
    handler: async (args, ctx) => {
      if (!active(ctx)) return;
      try {
        const [command, ...rest] = args.trim().split(/\s+/);
        const value = rest.join(" ");
        if (!command) throw new Error(USAGE);
        else if (["hint", "off"].includes(command) && !value) changeMode(ctx, command as Mode);
        else if (command === "threshold" && value) minimum(ctx, value);
        else if (command === "status" && !value) status(ctx);
        else if (["snooze", "dismiss"].includes(command) && !value) {
          const s = restoreState(ctx.sessionManager.getBranch());
          invalidate(ctx);
          persist({ ...s, snoozeUntil: command === "snooze" ? s.completed + 4 : s.snoozeUntil });
          ctx.ui.notify(
            command === "snooze"
              ? "Advice snoozed for three completed exchanges."
              : "Hint dismissed.",
            "info",
          );
        } else throw new Error(USAGE);
      } catch (error) {
        ctx.ui.notify(error instanceof Error ? error.message : "Could not save settings.", "error");
      }
    },
  });
}
