// Firstmate supervision branch for OMP (docs/omp-supervision-branch.md).
//
// A persistent second AgentSession - the supervision BRANCH - inside the same
// OMP process as the captain's MAIN session. The watcher adapter offers each
// actionable wake here (lib/fm-branch-dispatch.ts); the branch handles it with
// real tools and reports through the fm_branch_report custom tool, which
// writes the durable outcome store FIRST (bin/fm-branch-outcome.sh) and then
// merges an append-only note to main's tail. Main's captain/assistant dialog
// is mirrored into the branch as read-only fm-main-mirror context at main's
// turn_end. OMP-only by construction: this file lives in .omp/extensions, so no
// other harness ever loads it. Supervision is default-on for every task once
// this OMP session owns the fleet lock: no captain grant file is required.
// Away mode (or a broken branch) keeps today's wake-to-main behavior
// untouched regardless.
//
// This is a focused fork of the Pi supervision-branch extension. The bash
// layer (fm-lease*.sh, fm-branch-outcome.sh, fm-branch-prompt.sh,
// fm-wake-grant.sh, the fm-wake-drain.sh per-actor additions) and
// lib/fm-branch-dispatch.ts are harness-agnostic and shared verbatim; only the
// coding-agent SDK surface differs. The localized deltas from the Pi original:
//   - Model resolution uses OMP's ModelRegistry (find/hasConfiguredAuth) taken
//     from the live extension context, not Pi's ModelRuntime.
//   - Reasoning-effort vocabulary comes from OMP's Effort catalog + the shim's
//     clampThinkingLevel, not Pi's getSupportedThinkingLevels.
//   - The branch session is built with OMP-native createAgentSession options
//     (systemPrompt, disableExtensionDiscovery, restricted tool set, native
//     providerPromptCacheKey) rather than Pi's DefaultResourceLoader form.
//   - The /supervision-model picker uses the portable ctx.ui.select dialog, so
//     the port needs no pi-tui component surface (and no DynamicBorder).
//
// Prefix stability (the cache contract, owner: bin/fm-branch-prompt.sh
// header): the branch's system prompt is the generator's byte-stable output,
// the tool set is BRANCH_TOOL_NAMES in that fixed order on every spawn, and
// one shared per-home providerPromptCacheKey is set for the branch session -
// main keeps OMP's default per-session key. Wakes, mirrored dialog, and merge
// notes are all appends at a tail.
//
// Session-lock ownership: every branch side-effect boundary re-evaluates the
// current extension generation and lock ownership LAZILY, the same way the
// watcher adapter evaluates ownership at arm time. A cold OMP start acquires
// the lock only when the session runs fm-session-start.sh, so latching
// ownership once at session_start would leave the branch inert for the whole
// process; and a secondary read-only OMP session that never owns the lock must
// never write markers, clean leases, or accept wakes.
//
// Failure direction: every path that cannot reach a working branch falls back
// to delivering the wake to MAIN exactly as before the branch existed - a
// broken branch degrades to today's behavior, never to a lost wake. The wake
// queue itself stays durable until the handler runs the drain's
// acknowledgement, so a branch that dies mid-handling re-presents its rows at
// the next drain exactly as a mid-handling main crash always has.
//
// OMP-context marker: fm-lease-lib.sh gates lease liveness on the ambient
// coding-agent marker PI_CODING_AGENT. The Pi runtime sets it natively; OMP
// does not, so this extension sets it at load. That is the single OMP-side
// adaptation that lets the byte-identical bash lease layer recognize both the
// main and branch actors under OMP.
//
// Threat model (captain-decided): the branch's actor identity is
// CONFUSED-AGENT-GRADE - deterministic spawnHook env injection plus a
// readonly-variable shell prelude so an accidental override fails loudly
// inside the branch's own shell. bin/fm-lease-lib.sh documents the grade and
// its deliberate limits.
import { spawnSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createAgentSession,
  type ExtensionFactory,
  SessionManager,
  type AgentSession,
  type ExtensionAPI,
  type ExtensionCommandContext,
  type ExtensionContext,
  type ModelRegistry,
  type ToolDefinition,
} from "@oh-my-pi/pi-coding-agent";
import { createBashToolDefinition, Type } from "@oh-my-pi/pi-coding-agent/extensibility/legacy-pi-coding-agent-shim";
import { clampThinkingLevel } from "@oh-my-pi/pi-coding-agent/extensibility/legacy-pi-ai-shim";
import type { Model } from "@oh-my-pi/pi-ai";
import type { Effort } from "@oh-my-pi/pi-catalog/effort";
import {
  activateEligibleRowsOwner,
  deactivateEligibleRowsOwner,
  FM_BRANCH_DISPATCH_EVENT,
  releaseEligibleRowsSnapshot,
  scopeForUnreadWake,
  writeEligibleRowsSnapshot,
  type BranchDispatchOffer,
} from "./lib/fm-branch-dispatch.ts";
import { buildBranchModelItems, FOLLOW_MAIN_VALUE } from "./lib/fm-branch-model-picker.ts";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const afkFlag = join(state, ".afk");
const sessionsDir = join(state, "branch-session");
const sessionPointer = join(state, ".branch-session");
const mirrorCursorFile = join(state, ".branch-mirror-cursor");
const promptScript = join(fmRoot, "bin", "fm-branch-prompt.sh");
const outcomeScript = join(fmRoot, "bin", "fm-branch-outcome.sh");
const operationalInputScript = join(fmRoot, "bin", "fm-operational-input.sh");
const leaseScript = join(fmRoot, "bin", "fm-lease.sh");
const wakeGrantScript = join(fmRoot, "bin", "fm-wake-grant.sh");
const loadedMarker = join(state, ".omp-branch-extension-loaded");
const modelPinFile = join(config, "supervision-branch-model");
const effortPinFile = join(config, "supervision-branch-effort");

// The ambient coding-agent-context marker fm-lease-lib.sh reads. The Pi runtime
// sets it natively; OMP does not, so establish it here. It is set
// UNCONDITIONALLY to "true": an inherited empty or "false" value would make the
// lease-liveness gate treat a live branch lease as stale, letting a main-side
// fm-send delete it and mutate the same task concurrently. The marker's whole
// purpose is to prove the coding-agent context, so it must always be present.
process.env.PI_CODING_AGENT = "true";

// Same tool set in the same order on every request (part of the cached
// prefix). "bash" resolves to the customTools override below, which injects
// the branch actor identity deterministically into every shell command.
const BRANCH_TOOL_NAMES = ["read", "bash", "fm_branch_report"] as const;

// One shared prompt_cache_key per home for ALL branch sessions, derived only
// from the home path so it survives restarts; main keeps its own session key.
const branchCacheKey = `fm-branch-${createHash("sha256").update(fmHome).digest("hex").slice(0, 24)}`;

const MIRROR_MESSAGE_CAP = 4000;
const MERGE_NOTE_BOAT = "⛵";
type MirrorItem = { tag: "captain" | "main"; text: string };
type MirrorCursor = { file: string; index: number };
type Verdict = "routine" | "captain";
type LockOwnership = "owned" | "other" | "missing";

const scriptEnv = {
  ...process.env,
  FM_HOME: fmHome,
  FM_ROOT_OVERRIDE: fmRoot,
  FM_STATE_OVERRIDE: state,
  FM_CONFIG_OVERRIDE: config,
};

// One model the registry can hand back, and OMP's own reasoning-effort
// vocabulary. clampThinkingLevel (the shim) accepts and returns exactly
// Effort | "off", which is the branch's own effort domain.
type BranchModel = Model;
type BranchEffort = Effort | "off";
type PinnedBranchModel = { model: BranchModel };
type BranchModelResolution = { ok: true; selection: PinnedBranchModel } | { ok: false; reason: string };

// OMP owns the effort vocabulary. clampThinkingLevel takes and returns exactly
// Effort | "off", so this array exists for one job the type system cannot do
// at runtime: rejecting a hand-edited pin token OMP would not recognize. The
// bidirectional assertion below fails the tracked strict typecheck against the
// INSTALLED @oh-my-pi packages (tests/fm-omp-branch-types.test.sh) the moment
// OMP adds or removes an Effort level in either direction, so the list cannot
// drift into a stale Firstmate catalog.
const BRANCH_EFFORT_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
type DeclaredBranchEffort = (typeof BRANCH_EFFORT_LEVELS)[number];
// OMP's Effort is a string enum; its members are nominal, so coerce the branch
// effort domain to its underlying string values before the pin. The check then
// fails the strict typecheck the moment OMP's Effort union gains or loses a
// member in either direction.
type BranchEffortString = `${BranchEffort}`;
const ompOwnsTheEffortVocabulary: [DeclaredBranchEffort] extends [BranchEffortString]
  ? [BranchEffortString] extends [DeclaredBranchEffort]
    ? true
    : never
  : never = true;
void ompOwnsTheEffortVocabulary;

function isBranchEffort(level: unknown): level is BranchEffort {
  return typeof level === "string" && (BRANCH_EFFORT_LEVELS as readonly string[]).includes(level);
}

// The supervision-branch model pin, owned operator-side by
// docs/configuration.md: one "<provider>/<model-id>" line under this home's
// config/. An absent, unreadable, or unparseable file means no pin, and the
// branch then follows main's own model. Only the FIRST "/" separates the two
// halves, so a provider-qualified model id such as
// openrouter/anthropic/claude survives.
function readModelPin(): { provider: string; modelId: string } | null {
  let stored: string;
  try {
    stored = readFileSync(modelPinFile, "utf8");
  } catch {
    return null;
  }
  const line = (stored.split("\n")[0] ?? "").trim();
  const separator = line.indexOf("/");
  if (separator <= 0 || separator >= line.length - 1) return null;
  return { provider: line.slice(0, separator), modelId: line.slice(separator + 1) };
}

// The supervision-branch effort pin, owned operator-side by the same
// docs/configuration.md section: one OMP thinking-level line under this home's
// config/, independent of the model pin. An absent, unreadable, or
// unrecognized file means no pin, and the branch then follows main's own
// effort.
function readEffortPin(): BranchEffort | null {
  let stored: string;
  try {
    stored = readFileSync(effortPinFile, "utf8");
  } catch {
    return null;
  }
  const line = (stored.split("\n")[0] ?? "").trim();
  return isBranchEffort(line) ? line : null;
}

// Replaces a pin atomically so a failed write leaves the current choice
// intact rather than claiming persistence (the config/calm precedent).
function writePinFile(pinFile: string, selection: string): void {
  mkdirSync(dirname(pinFile), { recursive: true });
  const temporaryPath = `${pinFile}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporaryPath, `${selection}\n`, { encoding: "utf8", flag: "wx", mode: 0o600 });
    renameSync(temporaryPath, pinFile);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

function clearPinFile(pinFile: string): void {
  rmSync(pinFile, { force: true });
}

function modelLabel(model: { provider: string; id: string }): string {
  return `${model.provider}/${model.id}`;
}

function afkActive(): boolean {
  return existsSync(afkFlag);
}

function offerEligible(offer: BranchDispatchOffer): boolean {
  return offer.eligible === true;
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

let ownedLockPid = "";

// Same ownership read as the watcher adapter's lockOwnership(): the lock names
// the harness pid, and this process owns it when that pid appears in its own
// ancestry.
function lockOwnership(): LockOwnership {
  ownedLockPid = "";
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) {
      ownedLockPid = lockPid;
      return "owned";
    }
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

// Encode a watcher wake as a marked operational injection through the bash
// owner, matching the primary OMP adapter's own fallback delivery. An encoding
// failure must never lose a wake, so the raw body is returned unmarked.
function encodeOperationalInput(content: string): string {
  try {
    const result = spawnSync(operationalInputScript, ["encode", "watcher"], {
      encoding: "utf8",
      input: content,
      maxBuffer: 1024 * 1024,
    });
    if (result.status === 0 && result.stdout) return result.stdout;
  } catch {
    // fall through to the unmarked body
  }
  return content;
}

function textOfContent(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        const p = part as { type?: string; text?: string };
        return p && p.type === "text" && typeof p.text === "string" ? p.text : "";
      })
      .filter((piece) => piece.length > 0)
      .join("\n");
  }
  return "";
}

// Operational injections (watcher wakes, away-supervisor escalations, launch
// briefs) are fleet machinery, not captain dialog; mirroring them would feed
// the branch its own supervision traffic back. Current injections start with
// the U+2063 operational prefix; the plain legacy form starts with FIRSTMATE.
function isOperationalUserText(text: string): boolean {
  return text.startsWith("⁣") || /^FIRSTMATE[ _]/.test(text);
}

function capMirrorText(text: string): string {
  if (text.length <= MIRROR_MESSAGE_CAP) return text;
  return `${text.slice(0, MIRROR_MESSAGE_CAP)}\n[mirror truncated at ${MIRROR_MESSAGE_CAP} characters]`;
}

function readMirrorCursor(): MirrorCursor {
  try {
    const parsed = JSON.parse(readFileSync(mirrorCursorFile, "utf8")) as Partial<MirrorCursor>;
    if (typeof parsed.file === "string" && typeof parsed.index === "number" && parsed.index >= 0) {
      return { file: parsed.file, index: Math.floor(parsed.index) };
    }
  } catch {
    // Absent or torn cursor: re-mirror the current main session from its
    // start. Idempotent context, so over-mirroring is safe; dropping is not.
  }
  return { file: "", index: 0 };
}

function writeMirrorCursor(cursor: MirrorCursor): void {
  mkdirSync(state, { recursive: true });
  writeFileSync(mirrorCursorFile, `${JSON.stringify(cursor)}\n`);
}

type ReadonlyEntries = {
  getSessionFile(): string | undefined;
  getEntries(): Array<{ type: string }>;
};

// Volatile mirror-collection state. Instance-scoped and cleared at the
// session replacement boundary, so a replacement extension instance
// reconstructs EXCLUSIVELY from the durable cursor: dialog collected but not
// yet delivered re-mirrors rather than dropping (the durable cursor advances
// only in flushMirror after delivery).
type MirrorCollectionState = {
  collectAnchor: MirrorCursor | null;
  pendingCursor: MirrorCursor | null;
};

function collectMainDialog(sessionManager: ReadonlyEntries, collection: MirrorCollectionState): MirrorItem[] {
  const file = sessionManager.getSessionFile() ?? "";
  const entries = sessionManager.getEntries();
  const anchor = collection.collectAnchor ?? readMirrorCursor();
  const start = anchor.file === file ? Math.min(anchor.index, entries.length) : 0;
  const items: MirrorItem[] = [];
  for (const entry of entries.slice(start)) {
    if (entry.type !== "message") continue;
    const message = (entry as { message?: { role?: string; content?: unknown } }).message;
    if (!message) continue;
    if (message.role !== "user" && message.role !== "assistant") continue;
    const text = textOfContent(message.content).trim();
    if (!text) continue;
    if (message.role === "user" && isOperationalUserText(text)) continue;
    items.push({ tag: message.role === "user" ? "captain" : "main", text: capMirrorText(text) });
  }
  collection.collectAnchor = { file, index: entries.length };
  collection.pendingCursor = collection.collectAnchor;
  return items;
}

export default function (pi: ExtensionAPI) {
  let branch: AgentSession | null = null;
  let branchBroken = "";
  let mainStreaming = false;
  let shuttingDown = false;
  // Advanced once per cold-start arm (session_start). There is no live-handoff
  // replacement, so within a process the branch is persistent and the generation
  // stays fixed; the guards below then reduce to the shutdown and lock-ownership
  // checks. A fresh process re-arms from zero with fresh in-memory state.
  let generation = 0;
  // One-time per-generation activation work (marker write + stray branch
  // lease cleanup); ownership itself is re-read lazily at every boundary.
  let activatedGeneration = -1;
  // Serializes branch work: mirror appends and wake turns run strictly in
  // dispatch order, one at a time (the branch runs drain -> handle -> ack
  // serially by design).
  let branchChain: Promise<void> = Promise.resolve();
  const pendingMirror: MirrorItem[] = [];
  const mirrorCollection: MirrorCollectionState = { collectAnchor: null, pendingCursor: null };
  // Main's own current model and its live registry, tracked from the contexts
  // OMP already hands this extension, because createBranch runs at wake time
  // with no context of its own. mainModel is what "follow main" applies;
  // mainModelRegistry resolves both a pin and the followed model against the
  // credentials this home already holds - reads only, so main never moves.
  let mainModel: { provider: string; id: string } | null = null;
  let mainModelRegistry: ModelRegistry | null = null;

  // Main's own current effort needs no such tracking: OMP answers it directly
  // on demand, including at wake time. A value that is not one of the branch's
  // pinnable levels ("inherit", the auto sentinel, or undefined) means "follow
  // main's default" - no explicit override - never a refused wake.
  function mainEffort(): BranchEffort | undefined {
    try {
      const level = pi.getThinkingLevel?.();
      return isBranchEffort(level) ? level : undefined;
    } catch {
      return undefined;
    }
  }

  function rememberMainContext(ctx?: ExtensionContext): void {
    if (!ctx) return;
    if (ctx.modelRegistry) mainModelRegistry = ctx.modelRegistry;
    if (ctx.model) mainModel = { provider: ctx.model.provider, id: ctx.model.id };
  }

  // Resolves one model against main's live model registry using only the
  // credentials that registry already holds - the branch runs in the same home
  // and same user as main, so stored credentials keep their own semantics
  // (OAuth stays OAuth, an API key stays an API key) and nothing is ever
  // installed, converted, derived, or overwritten here. The lookups are pure
  // reads, so resolving the branch's model never perturbs main's own model.
  function resolveBranchModel(provider: string, modelId: string): BranchModelResolution {
    const label = `${provider}/${modelId}`;
    const registry = mainModelRegistry;
    if (!registry) return { ok: false, reason: `${label} cannot be resolved yet: the model registry is not known` };
    const model = registry.find(provider, modelId) as BranchModel | undefined;
    if (!model) return { ok: false, reason: `${label} is unavailable to the branch model registry` };
    if (!registry.hasConfiguredAuth(model)) {
      return { ok: false, reason: `${label} has no configured credentials in the branch model registry` };
    }
    return { ok: true, selection: { model } };
  }

  function preparePinnedBranchModel(pin: { provider: string; modelId: string }): PinnedBranchModel {
    const resolved = resolveBranchModel(pin.provider, pin.modelId);
    if (!resolved.ok) {
      throw new Error(`supervision model pin ${resolved.reason} (config/supervision-branch-model)`);
    }
    return resolved.selection;
  }

  // The pin file's CURRENT state decides the model on every branch build,
  // create and reopen alike, and it overrides any model a reopened branch
  // session recorded. With a pin, that model. With no pin, main's own model is
  // applied EXPLICITLY - otherwise clearing the pin would report that the
  // branch follows main while the reopened session quietly restored the model
  // an earlier pin left behind. Only when main's model is genuinely unknown,
  // or the registry cannot run it, does the build fall back to passing no
  // override at all, which is the pre-feature behavior; an unpinned branch is
  // never refused over model choice alone.
  function branchModelSelection(): PinnedBranchModel | undefined {
    const pin = readModelPin();
    if (pin) return preparePinnedBranchModel(pin);
    if (!mainModel) return undefined;
    const resolved = resolveBranchModel(mainModel.provider, mainModel.id);
    return resolved.ok ? resolved.selection : undefined;
  }

  // The effort pin file's CURRENT state decides the branch's reasoning effort
  // on every branch build, create and reopen alike, on exactly the model-pin
  // contract above and for exactly the same reason: a reopened branch session
  // records the effort it last ran under, so an unpinned branch must apply
  // main's own effort EXPLICITLY or clearing a pin would silently restore the
  // level that pin left behind. OMP owns the clamp, so a level the branch's
  // model does not support becomes that model's nearest supported level rather
  // than a refusal - the branch is never refused over effort. Only when main's
  // own effort is unknowable too does the build fall back to passing no effort
  // override at all, which is the behavior from before this file existed.
  function branchEffortSelection(model: BranchModel | undefined): BranchEffort | undefined {
    const chosen = readEffortPin() ?? mainEffort();
    if (chosen === undefined) return undefined;
    return model ? clampThinkingLevel(model, chosen) : chosen;
  }

  function generationOwnsLock(expectedGeneration: number): boolean {
    return !shuttingDown && expectedGeneration === generation && lockOwnership() === "owned";
  }

  function markLoaded(): void {
    try {
      mkdirSync(state, { recursive: true });
      writeFileSync(loadedMarker, `${process.pid}\n`);
    } catch {
      // Diagnostic marker only; never block activation on it.
    }
  }

  // A replaced branch conversation must not leave its per-task leases behind
  // (the session-lock holder pid is still alive, so the sweep alone would
  // keep them). One bulk release per generation, at activation.
  function releaseBranchLeases(expectedGeneration: number): boolean {
    if (!generationOwnsLock(expectedGeneration)) return false;
    try {
      const result = spawnSync("bash", [leaseScript, "release-actor", "--actor", "branch"], {
        cwd: fmRoot,
        encoding: "utf8",
        env: { ...scriptEnv, FM_SUPERVISION_ACTOR: "branch" },
      });
      return result.status === 0;
    } catch {
      return false;
    }
  }

  // Lazy, per-action ownership evaluation (see the header). Returns true only
  // when this session owns the fleet lock right now; the first true evaluation
  // of a generation also writes the diagnostic marker and clears stray branch
  // leases from a prior generation.
  function actingAsOwner(expectedGeneration = generation): boolean {
    if (!generationOwnsLock(expectedGeneration)) return false;
    if (activatedGeneration !== expectedGeneration) {
      if (!releaseBranchLeases(expectedGeneration)) return false;
      if (!generationOwnsLock(expectedGeneration)) return false;
      if (!activateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(expectedGeneration))) return false;
      if (!generationOwnsLock(expectedGeneration)) {
        deactivateEligibleRowsOwner(state, wakeGrantScript, process.pid, String(expectedGeneration));
        return false;
      }
      markLoaded();
      activatedGeneration = expectedGeneration;
    }
    return generationOwnsLock(expectedGeneration);
  }

  function runOutcomeScript(args: string[]): { ok: boolean; stdout: string; detail: string } {
    try {
      const result = spawnSync("bash", [outcomeScript, ...args], {
        cwd: fmRoot,
        encoding: "utf8",
        env: scriptEnv,
      });
      if (result.status === 0) return { ok: true, stdout: (result.stdout || "").trim(), detail: "" };
      return {
        ok: false,
        stdout: "",
        detail: `fm-branch-outcome.sh exited ${result.status ?? "none"}: ${(result.stderr || "").trim()}`,
      };
    } catch (error) {
      return { ok: false, stdout: "", detail: error instanceof Error ? error.message : String(error) };
    }
  }

  // Append-only merge into main. The store row is already durable when this
  // runs; the note is a cache of it at main's tail. Delivery modes per the
  // design: routine+idle appends now with no turn, routine+busy appends after
  // the captain's next prompt, captain-relevant triggers exactly one turn
  // (queued as a follow-up while main is busy) - that follow-up turn is itself
  // the captain-visible outcome, so the captain-facing note is delivered
  // silently (display: false) rather than rendered a second time; routine
  // notes stay rendered except an explicitly silent no-change heartbeat.
  //
  // Delivery idempotency: the durable handoff cursor advances BEFORE the visible
  // delivery, not after. A captain follow-up that is accepted but whose cursor
  // advance then fails must never be re-delivered on a report retry or
  // re-surfaced by session-start replay - both would double-open a captain turn.
  // The opposite risk, a cursor that advanced but a delivery that failed, leaves
  // the outcome durable in the store and recoverable through main's
  // fm_branch_outcomes tool, which is the strictly safer failure. The store row
  // is already durable when this runs (the report tool appends store-first).
  function mergeIntoMain(
    expectedGeneration: number,
    seq: string,
    task: string,
    verdict: Verdict,
    summary: string,
    silent: boolean,
  ): boolean {
    if (!actingAsOwner(expectedGeneration)) return false;
    // Advance the cursor first so the outcome can never be delivered twice.
    if (/^[0-9]+$/.test(seq) && !runOutcomeScript(["mark-read", "--through", seq]).ok) {
      return false;
    }
    if (verdict === "captain") {
      const message = { customType: "fm-branch-merge", content: `${task}: ${summary}`, display: false };
      pi.sendMessage(message, { triggerTurn: true, deliverAs: "followUp" });
    } else {
      const message = {
        customType: "fm-branch-merge",
        content: `${MERGE_NOTE_BOAT} ${task}: ${summary}`,
        display: !(task === "fleet" && silent),
      };
      if (mainStreaming) {
        pi.sendMessage(message, { deliverAs: "nextTurn" });
      } else {
        pi.sendMessage(message, {});
      }
    }
    return true;
  }

  function createReportTool(toolGeneration: number): ToolDefinition {
    return {
      name: "fm_branch_report",
      label: "Report supervision outcome",
      description:
        "Record the outcome of one handled fleet event: write it durably to the outcome store, then merge an append-only note into the captain-facing main conversation. verdict captain surfaces it to the captain in one turn; routine notes render unless silent marks a no-change heartbeat.",
      parameters: Type.Object({
        task: Type.String({ description: "The task id the event belongs to (or 'fleet' for fleet-wide events)" }),
        verdict: Type.Union([Type.Literal("routine"), Type.Literal("captain")], {
          description: "captain only for what a human must see; routine otherwise",
        }),
        summary: Type.String({
          description:
            "One or two sentences in captain outcome language; include the full https:// PR URL when a PR is involved",
        }),
        wake: Type.Optional(Type.String({ description: "The wake reason line this outcome answers" })),
        silent: Type.Optional(
          Type.Boolean({
            description:
              "True only when a fleet-wide heartbeat review found literally nothing worth reporting; omit or use false whenever any action was taken or any routine result is worth a note",
          }),
        ),
      }),
      execute: async (_toolCallId, params) => {
        const task = String((params as { task: unknown }).task || "").trim();
        const verdictRaw = String((params as { verdict: unknown }).verdict || "");
        const summary = String((params as { summary: unknown }).summary || "").trim();
        const wake = String((params as { wake?: unknown }).wake ?? "").trim();
        const silent = (params as { silent?: unknown }).silent === true;
        if (
          !task ||
          !summary ||
          (verdictRaw !== "routine" && verdictRaw !== "captain") ||
          (silent && (task !== "fleet" || verdictRaw !== "routine"))
        ) {
          return {
            content: [{ type: "text", text: "invalid report: task, verdict (routine|captain), and summary are required" }],
            details: undefined,
            isError: true,
          };
        }
        const verdict = verdictRaw as Verdict;
        const appendArgs = ["append", "--task", task, "--verdict", verdict, "--summary", summary, "--silent", String(silent)];
        if (wake) appendArgs.push("--wake", wake);
        if (!actingAsOwner(toolGeneration)) {
          return {
            content: [{ type: "text", text: "report refused: supervision session was replaced or lost lock ownership" }],
            details: undefined,
            isError: true,
          };
        }
        const appended = runOutcomeScript(appendArgs);
        if (!appended.ok) {
          return {
            content: [{ type: "text", text: `outcome store append failed (nothing merged): ${appended.detail}` }],
            details: undefined,
            isError: true,
          };
        }
        if (!mergeIntoMain(toolGeneration, appended.stdout, task, verdict, summary, silent)) {
          return {
            content: [{ type: "text", text: `recorded seq ${appended.stdout}, but merge refused after supervision replacement or lock loss` }],
            details: undefined,
            isError: true,
          };
        }
        return {
          content: [{ type: "text", text: `recorded seq ${appended.stdout} and merged [${verdict}] into main` }],
          details: undefined,
        };
      },
    };
  }

  // The belt-and-suspenders cache-key hook. OMP's native providerPromptCacheKey
  // option (set on createAgentSession) is the primary mechanism; this inline
  // extension additionally rewrites the provider payload's own prompt_cache_key
  // when it carries one, so the shared per-home key survives regardless of
  // which layer the provider client honors. Any payload without that field
  // passes through untouched.
  const cacheKeyExtension: ExtensionFactory = (branchPi: ExtensionAPI) => {
    branchPi.on("before_provider_request", (event) => {
      const payload = event.payload;
      if (payload && typeof payload === "object" && "prompt_cache_key" in payload) {
        return { ...(payload as Record<string, unknown>), prompt_cache_key: branchCacheKey };
      }
    });
  };

  async function createBranch(branchGeneration: number): Promise<AgentSession> {
    // Resolved first, before any session file or prompt work: a model pin OMP
    // cannot honor must fail before this build leaves anything behind. Every
    // branch build goes through here - first wake of a cold start, and the
    // reopen after /new, /resume, /fork, or reload - so resolving the model
    // and the effort here is what makes the captain's current choices
    // authoritative on all of them.
    const pinned = branchModelSelection();
    const effort = branchEffortSelection(pinned?.model);
    const prompt = spawnSync("bash", [promptScript], {
      cwd: fmRoot,
      encoding: "utf8",
      env: scriptEnv,
      maxBuffer: 4 * 1024 * 1024,
    });
    if (prompt.status !== 0 || !prompt.stdout || prompt.stdout.length < 1024) {
      throw new Error(
        `fm-branch-prompt.sh did not produce a usable branch prompt (status=${prompt.status ?? "none"}): ${(prompt.stderr || "").trim()}`,
      );
    }
    if (!actingAsOwner(branchGeneration)) throw new Error("supervision session was replaced or lost lock ownership");
    mkdirSync(sessionsDir, { recursive: true });
    let sessionManager: SessionManager | null = null;
    try {
      const recorded = readFileSync(sessionPointer, "utf8").trim();
      if (recorded && existsSync(recorded)) {
        sessionManager = await SessionManager.open(recorded, sessionsDir);
      }
    } catch {
      sessionManager = null;
    }
    if (!sessionManager) {
      sessionManager = SessionManager.create(fmRoot, sessionsDir);
    }
    if (!actingAsOwner(branchGeneration)) throw new Error("supervision session was replaced or lost lock ownership");
    const leaseHolderPid = ownedLockPid;
    const bashTool = createBashToolDefinition(fmRoot, {
      spawnHook: (context) => {
        if (!actingAsOwner(branchGeneration)) {
          throw new Error("bash refused: supervision session was replaced or lost lock ownership");
        }
        return {
          ...context,
          // Loud accidental-override guard (captain-decided): the actor
          // variables are readonly inside the branch's own shell, so an
          // accidental in-shell reassignment fails loudly instead of silently
          // impersonating main. Confused-agent-grade by design; the threat
          // model lives in bin/fm-lease-lib.sh.
          command: `readonly FM_SUPERVISION_ACTOR FM_LEASE_HOLDER_PID
(
${context.command}
)`,
          env: {
            ...context.env,
            ...scriptEnv,
            FM_SUPERVISION_ACTOR: "branch",
            FM_LEASE_HOLDER_PID: leaseHolderPid,
          },
        };
      },
    });
    // Native OMP session build: the branch loads no project resources at all
    // (extensions off so it can never spawn its own branch; skills, context
    // files, and prompt templates off because they vary per home and would
    // destabilize the byte-stable prefix; MCP and LSP off). Its whole standing
    // context is the generator's prompt. Only the caller-supplied tools load,
    // and one belt-and-suspenders cache-key extension. The per-home
    // providerPromptCacheKey pins the shared cache key natively.
    const created = await createAgentSession({
      cwd: fmRoot,
      sessionManager,
      systemPrompt: prompt.stdout,
      disableExtensionDiscovery: true,
      extensions: [cacheKeyExtension],
      skills: [],
      contextFiles: [],
      promptTemplates: [],
      enableMCP: false,
      enableLsp: false,
      toolNames: [...BRANCH_TOOL_NAMES],
      restrictToolNames: true,
      allowRestrictedCustomTools: true,
      customTools: [bashTool as unknown as ToolDefinition, createReportTool(branchGeneration)],
      providerPromptCacheKey: branchCacheKey,
      providerPromptCacheKeySource: "explicit",
      ...(pinned ? { model: pinned.model } : {}),
      ...(effort === undefined ? {} : { thinkingLevel: effort }),
    });
    if (!actingAsOwner(branchGeneration)) {
      try {
        await created.session.dispose();
      } catch {}
      throw new Error("supervision session was replaced or lost lock ownership");
    }
    try {
      writeFileSync(sessionPointer, `${sessionManager.getSessionFile()}\n`);
    } catch {
      // Pointer write failure only costs cross-restart session reuse.
    }
    return created.session;
  }

  async function ensureBranch(expectedGeneration: number): Promise<AgentSession> {
    if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session was replaced or lost lock ownership");
    if (branch) return branch;
    if (branchBroken) throw new Error(branchBroken);
    try {
      const created = await createBranch(expectedGeneration);
      if (!actingAsOwner(expectedGeneration)) {
        try {
          await created.dispose();
        } catch {}
        throw new Error("supervision session was replaced or lost lock ownership");
      }
      branch = created;
      return created;
    } catch (error) {
      if (expectedGeneration === generation && !shuttingDown) {
        branchBroken = error instanceof Error ? error.message : String(error);
      }
      throw error;
    }
  }

  async function flushMirror(session: AgentSession, expectedGeneration: number): Promise<void> {
    if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
    while (pendingMirror.length > 0) {
      const item = pendingMirror[0];
      if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
      await session.sendCustomMessage(
        { customType: "fm-main-mirror", content: `[${item.tag}] ${item.text}`, display: false },
        {},
      );
      if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session was replaced during mirror delivery");
      pendingMirror.shift();
    }
    if (mirrorCollection.pendingCursor) {
      if (!actingAsOwner(expectedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
      writeMirrorCursor(mirrorCollection.pendingCursor);
      mirrorCollection.pendingCursor = null;
    }
  }

  function fallbackToMain(message: string, detail: string): void {
    const body = `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. (Supervision branch unavailable, falling back to main: ${detail})`;
    // Marked operational like every watcher injection, so the wake is never
    // mistaken for captain input (away-mode return semantics, mirror filter).
    const content = encodeOperationalInput(body);
    // Deliver through the exact main-wake mechanism the primary OMP adapter uses
    // (fm-primary-omp.ts sendFollowUp): a custom watcher-wake message delivered
    // as a steer with triggerTurn. Unlike sendUserMessage/followUp, this
    // reliably wakes an idle or interrupted main under OMP steer/continuation
    // semantics, so a broken branch never strands the wake.
    pi.sendMessage(
      {
        customType: "firstmate-watcher-wake",
        content,
        display: false,
        attribution: "agent",
        details: { kind: "watcher", runtime: "omp" },
      },
      { deliverAs: "steer", triggerTurn: true },
    );
  }

  function enqueueWake(message: string, acceptedGeneration: number): void {
    branchChain = branchChain
      .then(async () => {
        if (shuttingDown || acceptedGeneration !== generation) {
          throw new Error("supervision session was replaced before handling the accepted wake");
        }
        if (!actingAsOwner(acceptedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
        const session = await ensureBranch(acceptedGeneration);
        await flushMirror(session, acceptedGeneration);
        if (!actingAsOwner(acceptedGeneration)) throw new Error("supervision session no longer owns the fleet lock");
        const heartbeat = /^heartbeat($|:)/.test(message);
        const scope = scopeForUnreadWake(state, heartbeat);
        // A newly-arrived main-owned (check-kind) row never bounces this whole
        // recheck back to main - scopeForUnreadWake excludes it from
        // eligibleSeqs rather than vetoing the scan. A genuinely empty queue,
        // or one that simply has nothing (or nothing further) eligible for the
        // branch right now, is an ordinary quiet no-op - not a fault, so it is
        // never reported back to main. Only a scan scopeForUnreadWake itself
        // marks corrupted still falls back to main.
        if (scope.status === "empty" || (!scope.corrupted && scope.eligibleSeqs.length === 0)) return;
        if (scope.corrupted) {
          throw new Error("the unread wake queue could not be read safely");
        }
        const grant = writeEligibleRowsSnapshot(state, scope.eligibleSeqs, wakeGrantScript, String(acceptedGeneration));
        if (grant === "main-owned") throw new Error("the wake rows are already claimed by main");
        if (grant !== "published") throw new Error("could not record the branch's eligible row snapshot");
        // A row can still arrive between this re-check and the model starting
        // the drain; that residual is accepted by the confused-agent-grade boundary.
        await session.prompt(
          `FIRSTMATE SUPERVISION WAKE: ${message}\n\nHandle this per your operating procedure and finish with fm_branch_report.`,
        );
        if (!releaseEligibleRowsSnapshot(state, wakeGrantScript, String(acceptedGeneration))) {
          throw new Error("could not release the branch's settled wake-row grant");
        }
      })
      .catch(async (error: unknown) => {
        releaseEligibleRowsSnapshot(state, wakeGrantScript, String(acceptedGeneration));
        // Only fall the wake back to main when this generation still owns the
        // fleet lock and is not shutting down. If the session lost ownership or a
        // cold-start re-arm advanced the generation, the durable row stays queued
        // for the owning session to reclaim - the row is never lost - and falling
        // back here would risk a stale extra main turn for a row a fresh arm may
        // already handle.
        if (shuttingDown || acceptedGeneration !== generation) return;
        if (!actingAsOwner(acceptedGeneration)) return;
        try {
          fallbackToMain(message, error instanceof Error ? error.message : String(error));
        } catch {}
      });
  }

  function enqueueMirrorFlush(): void {
    if (!branch || pendingMirror.length === 0) return;
    const flushGeneration = generation;
    const flushSession = branch;
    branchChain = branchChain
      .then(async () => {
        if (!actingAsOwner(flushGeneration)) return;
        await flushMirror(flushSession, flushGeneration);
      })
      .catch(() => {
        // Mirror items stay queued in pendingMirror on failure; the next wake
        // or flush retries them in order.
      });
  }

  pi.events?.on?.(FM_BRANCH_DISPATCH_EVENT, (data) => {
    const offer = data as BranchDispatchOffer;
    if (!offer || typeof offer.accept !== "function") return;
    // Check eligibility before ownership activation so an out-of-scope wake
    // gets neither branch routing nor branch-owned state/lease cleanup side
    // effects.
    if (!offerEligible(offer)) return;
    if (!actingAsOwner()) return; // cold start pre-lock, secondary session, or shutdown
    if (afkActive()) return; // the away daemon owns supervision while afk
    if (branchBroken) return; // fail back to today's wake-to-main path
    offer.accept();
    enqueueWake(offer.message, generation);
  });

  pi.on?.("agent_start", () => {
    mainStreaming = true;
  });
  pi.on?.("agent_end", () => {
    mainStreaming = false;
  });

  // Mirror at main's turn_end: collect the new captain/assistant dialog into
  // the volatile queue, then deliver it through the serialized chain so it
  // lands before any later wake. The durable cursor advances only in
  // flushMirror after the complete pending batch reaches the branch.
  pi.on?.("turn_end", (_event, ctx) => {
    rememberMainContext(ctx);
    if (!actingAsOwner()) return;
    try {
      pendingMirror.push(...collectMainDialog(ctx.sessionManager, mirrorCollection));
    } catch {
      return;
    }
    enqueueMirrorFlush();
  });

  // session_start arms this generation at a cold start (a fresh process). It is
  // the sole clean-boundary transition: the branch is persistent across main's
  // own /new, /resume, and /fork navigation and is never displaced by a
  // synchronous live handoff (that path, and hung-branch takeover, are out of
  // scope - see docs/omp-supervision-branch.md). The mirror re-anchors on its
  // own when the session file changes (collectMainDialog compares the file), and
  // mainModel/mainModelRegistry refresh at every turn_end, so no session_switch
  // handling is needed. Terminal quit fires session_shutdown and never a start.
  pi.on?.("session_start", (_event, ctx) => {
    rememberMainContext(ctx);
    shuttingDown = false;
    branchBroken = "";
    generation += 1;
    actingAsOwner(generation);
  });

  // Terminal quit: latch shutdown so no further wake or mirror turn starts. No
  // synchronous lock-based settlement runs here. Mid-flight ownership handoff
  // from a live or hung branch is deliberately out of scope: it would have to
  // acquire the shared wake-queue and lease-command locks the branch's own
  // in-flight work may hold, which can block the whole single-threaded process
  // (docs/omp-supervision-branch.md). On terminal quit the process is ending
  // anyway - its branch leases and wake-grant rows go stale on death and are
  // swept - and a hung branch is recovered by killing the process and letting a
  // fresh one re-arm, never by a live takeover.
  pi.on?.("session_shutdown", () => {
    shuttingDown = true;
  });

  // OMP keeps /model and its own thinking selector for the captain's own
  // conversation and exposes no hook an extension can open, so this is the
  // smallest supported equivalent: main's own registry (available models with
  // configured credentials) for the model step, then the branch model's
  // supported levels for the effort step, with no parallel Firstmate catalog.
  // Both steps use OMP's portable ctx.ui.select dialog. Pinning the branch only
  // writes the pin file: it never calls setModel (so it never moves main's own
  // conversation) and never swaps the live branch. A saved pin takes effect when
  // the branch is next built - the next firstmate start, or after the branch is
  // torn down - because mid-flight model/effort change is out of scope
  // (docs/omp-supervision-branch.md).
  pi.registerCommand?.("supervision-model", {
    description: "Pick the model and reasoning effort Firstmate's OMP supervision branch uses, or follow main's.",
    handler: async (_args, ctx) => {
      rememberMainContext(ctx);
      const pin = readModelPin();
      const current = pin ? `${pin.provider}/${pin.modelId}` : "follows main";
      const followMain = `Follow main${ctx.model ? ` (${modelLabel(ctx.model)})` : ""}`;
      let available: string[];
      try {
        available = ctx.modelRegistry
          .getAvailable()
          .filter((model) => ctx.modelRegistry.hasConfiguredAuth(model))
          .map(modelLabel);
      } catch (error) {
        ctx.ui.notify(
          `Could not read the supervision branch models: ${error instanceof Error ? error.message : String(error)}`,
          "error",
        );
        return;
      }
      const items = buildBranchModelItems(followMain, available, pin ? `${pin.provider}/${pin.modelId}` : null);
      const picked = await pickFromItems(ctx, `Supervision branch model (now: ${current})`, items);
      if (picked === undefined) return; // cancelled: the current choice stands
      let branchModel: BranchModel | undefined;
      try {
        if (picked === FOLLOW_MAIN_VALUE) {
          clearPinFile(modelPinFile);
        } else {
          const separator = picked.indexOf("/");
          if (separator <= 0 || separator >= picked.length - 1) throw new Error(`invalid model selection: ${picked}`);
          branchModel = preparePinnedBranchModel({ provider: picked.slice(0, separator), modelId: picked.slice(separator + 1) }).model;
          writePinFile(modelPinFile, picked);
        }
      } catch (error) {
        ctx.ui.notify(
          `Could not apply or save the supervision branch model: ${error instanceof Error ? error.message : String(error)}`,
          "error",
        );
        return;
      }
      let modelReport: { message: string; warning: boolean };
      if (picked !== FOLLOW_MAIN_VALUE) {
        modelReport = { message: `Supervision branch model pinned to ${picked}; it takes effect when the branch is next started.`, warning: false };
      } else {
        // Clearing the pin only follows main if main's model can actually be
        // applied to the branch; say what will really happen at the next build.
        const following = mainModel ? resolveBranchModel(mainModel.provider, mainModel.id) : null;
        if (following?.ok) branchModel = following.selection.model;
        modelReport = following?.ok
          ? { message: `Supervision branch will follow main's model (${modelLabel(following.selection.model)}) when it is next started.`, warning: false }
          : {
              message: `Supervision branch pin cleared, but main's model could not be applied (${following ? following.reason : "main's model is not known yet"}); the next branch will retry when it is started.`,
              warning: true,
            };
      }

      // The model choice is already persisted, so a failing effort step must
      // never swallow it: the pin still stands and the captain still hears what
      // was saved and what was not. Neither choice touches the branch already
      // running for this session - both apply at the next branch build.
      let effortReport: { message: string; warning: boolean };
      try {
        effortReport = await pickBranchEffort(ctx, branchModel);
      } catch (error) {
        effortReport = {
          message: `The effort step failed (${error instanceof Error ? error.message : String(error)}); the branch keeps its current effort pin.`,
          warning: true,
        };
      }
      ctx.ui.notify(
        `${modelReport.message} ${effortReport.message}`,
        modelReport.warning || effortReport.warning ? "warning" : "info",
      );
    },
  });

  // Step one of /supervision-model, over OMP's portable select dialog. The rows
  // and their order (follow-main first, current marked) come from
  // lib/fm-branch-model-picker.ts; the dialog itself is OMP's own. Returns the
  // chosen item's value, or undefined when the captain cancels.
  async function pickFromItems(
    ctx: ExtensionCommandContext,
    title: string,
    items: ReturnType<typeof buildBranchModelItems>,
  ): Promise<string | undefined> {
    const labels = items.map((item) => (item.description ? `${item.label} (${item.description})` : item.label));
    const picked = await ctx.ui.select(title, labels);
    if (picked === undefined) return undefined;
    const index = labels.indexOf(picked);
    return index >= 0 ? items[index]?.value : undefined;
  }

  // Step two of /supervision-model, shown after the model pick and driven by
  // OMP's effort catalog for the model the branch will now use, so the menu is
  // the branch's own pinnable levels and keeps no parallel Firstmate catalog.
  // Cancelling leaves the current effort choice standing; the model pick
  // already made is still applied.
  async function pickBranchEffort(
    ctx: ExtensionCommandContext,
    selectedModel: BranchModel | undefined,
  ): Promise<{ message: string; warning: boolean }> {
    const branchModel = selectedModel;
    const currentPin = readEffortPin();
    const current = currentPin ?? "follows main";
    const main = mainEffort();
    const followMainEffort = `Follow main${main ? ` (${main})` : ""}`;
    const picked = await ctx.ui.select(`Supervision branch effort (now: ${current})`, [followMainEffort, ...BRANCH_EFFORT_LEVELS]);
    if (picked === undefined) {
      return { message: describeBranchEffort(currentPin, branchModel), warning: branchModel === undefined };
    }
    try {
      if (picked === followMainEffort) {
        clearPinFile(effortPinFile);
      } else if (isBranchEffort(picked)) {
        writePinFile(effortPinFile, picked);
      } else {
        throw new Error(`invalid effort selection: ${picked}`);
      }
    } catch (error) {
      return {
        message: `The effort choice could not be saved (${error instanceof Error ? error.message : String(error)}). ${describeBranchEffort(currentPin, branchModel)}`,
        warning: true,
      };
    }
    return { message: describeBranchEffort(readEffortPin(), branchModel), warning: branchModel === undefined };
  }

  // Reports the effort the branch will actually run at, never the raw choice:
  // OMP clamps a level the branch's model does not support, and an unpinned
  // branch follows main's own effort only when it can be determined.
  function describeBranchEffort(pin: BranchEffort | null, branchModel: BranchModel | undefined): string {
    if (!branchModel) {
      return "The effort level the branch will run at cannot be determined because its effective model could not be resolved.";
    }
    const chosen = pin ?? mainEffort();
    if (chosen === undefined) {
      return "Effort follows main, whose own effort is not known yet, so the branch keeps the effort its own session recorded until it is next started.";
    }
    const applied = clampThinkingLevel(branchModel, chosen);
    if (pin === null) return `Effort follows main (${applied}).`;
    return applied === pin ? `Effort: ${pin}.` : `Effort: ${pin}, which this model runs at ${applied}.`;
  }

  pi.registerTool?.({
    name: "fm_branch_outcomes",
    label: "Read supervision branch outcomes",
    description:
      "Read the durable outcome store of the supervision branch: what fleet events it handled, each verdict, and each summary. Use when the captain asks what happened in the fleet.",
    parameters: Type.Object({
      recent: Type.Optional(Type.Number({ description: "How many most-recent outcomes to read (default 20)" })),
    }),
    execute: async (_toolCallId, params) => {
      const recentRaw = (params as { recent?: unknown }).recent;
      const recent = typeof recentRaw === "number" && recentRaw >= 1 ? String(Math.floor(recentRaw)) : "20";
      const listed = runOutcomeScript(["list", "--recent", recent]);
      if (!listed.ok) {
        return {
          content: [{ type: "text", text: `could not read the outcome store: ${listed.detail}` }],
          details: undefined,
          isError: true,
        };
      }
      return {
        content: [{ type: "text", text: listed.stdout || "(no branch outcomes recorded)" }],
        details: undefined,
      };
    },
  });
}
