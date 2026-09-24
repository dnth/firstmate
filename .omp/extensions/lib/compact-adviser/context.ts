// Bounded, redacted conversation snapshot for the TypeSafe judge.
// Ported from upstream compact-adviser packages/pi-extension/src/context.ts
// at pinned commit b2a27b59ce86af4dc8fb5141e169bfbed1e68cee.
//
// OMP adaptations (verified against @oh-my-pi/pi-coding-agent 18.2.6 source):
//   - Transcript source is `ctx.sessionManager.getBranch()` (active branch only,
//     so sibling branch content cannot leak) with explicit SessionEntry mapping,
//     per the port evaluation's adapter design. Upstream consumed Pi's
//     buildSessionContext() message list; the mapping below reproduces that
//     shape: message entries keep their AgentMessage, custom_message entries
//     (which participate in LLM context) map to user-role text, and
//     compaction/branch_summary entries feed previousSummary.
//   - `estimateTokens` is not exported from the OMP package barrel; the local
//     estimator below is byte-identical to pi-agent-core's non-accurate path
//     ((bytes + 3) >> 2) and only feeds the coarse <=20k conversation-size
//     skip gate - eligibility itself uses native ctx.getContextUsage().
import { createHash } from "node:crypto";
import { statSync } from "node:fs";
import { resolve } from "node:path";
import type { ExtensionContext, SessionEntry } from "@oh-my-pi/pi-coding-agent";

/** Recent assistant and toolResult messages considered for the TypeSafe/Jev snapshot. */
export const RECENT_TAIL_MESSAGES = 64;
export const SNAPSHOT_MESSAGE_CAP = 64;
/** Per-tool-result byte cap inside the recent tail; long results are middle-truncated. */
export const TOOL_RESULT_BUDGET = 512;

function clip(text: string, limit: number): { text: string; truncated: boolean } {
  if (Buffer.byteLength(text) <= limit) return { text, truncated: false };
  return {
    text: Buffer.from(text)
      .subarray(0, Math.max(0, limit - 3))
      .toString("utf8"),
    truncated: true,
  };
}

function truncatedMarker(omitted: number): string {
  return `...[truncated ${omitted} bytes]...`;
}

/** Keep a head and tail slice so one long tool dump cannot hide its start or end. */
export function clipMiddle(text: string, limit: number): { text: string; truncated: boolean } {
  const raw = Buffer.from(text);
  if (raw.byteLength <= limit) return { text, truncated: false };
  if (limit <= 0) return { text: "", truncated: true };
  let omitted = raw.byteLength;
  let head = 0;
  let tail = 0;
  for (let i = 0; i < 5; i++) {
    const markerBytes = Buffer.byteLength(truncatedMarker(omitted));
    if (markerBytes >= limit) return clip(text, limit);
    const keep = limit - markerBytes;
    head = Math.ceil(keep / 2);
    tail = Math.floor(keep / 2);
    omitted = Math.max(0, raw.byteLength - head - tail);
  }
  const marker = truncatedMarker(omitted);
  const candidate = Buffer.concat([
    raw.subarray(0, head),
    Buffer.from(marker),
    raw.subarray(raw.byteLength - tail),
  ]).toString("utf8");
  return {
    text: Buffer.byteLength(candidate) <= limit ? candidate : clip(candidate, limit).text,
    truncated: true,
  };
}
const sensitivePath =
  /(?:^|[\\/])(?:\.env(?:\.[^\\/]*)?|auth\.json|id_(?:rsa|ed25519)|[^\\/]*\.(?:pem|key))$/i;

function fileExists(path: string): boolean {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

function isOwnedSecretField(key: string): boolean {
  return key === "typesafeApiKey" || key.endsWith(".typesafeApiKey");
}

function redactOwnedSecretFields(value: unknown): { value: unknown; redacted: boolean } {
  let redacted = false;
  const walk = (node: unknown): unknown => {
    if (Array.isArray(node)) return node.map(walk);
    if (node && typeof node === "object") {
      const out: Record<string, unknown> = {};
      for (const [key, child] of Object.entries(node as Record<string, unknown>)) {
        if (isOwnedSecretField(key) && child !== "" && child != null) {
          out[key] = "[REDACTED]";
          redacted = true;
        } else out[key] = walk(child);
      }
      return out;
    }
    return node;
  };
  return { value: walk(value), redacted };
}

/** Strip the product's saved-key fields from JSON text; keep non-secret settings. */
export function redactOwnedSettings(text: string): { text: string; redacted: boolean } {
  if (!text.includes("typesafeApiKey")) return { text, redacted: false };
  try {
    const parsed = JSON.parse(text) as unknown;
    const walked = redactOwnedSecretFields(parsed);
    if (walked.redacted) return { text: JSON.stringify(walked.value), redacted: true };
  } catch {
    // Clipped or non-JSON tool output still goes through the field regex below.
  }
  const clean = text
    .replace(/("(?:[^"\\]*\.)?typesafeApiKey")\s*:\s*"(?:\\.|[^"\\])*"/g, '$1:"[REDACTED]"')
    .replace(/\b(typesafeApiKey)\s*[=:]\s*["']?[^\s"',}]+/g, "$1=[REDACTED]");
  return { text: clean, redacted: clean !== text };
}

export function scrubKnownSecrets(
  text: string,
  secrets: readonly (string | undefined)[],
): { text: string; redacted: boolean } {
  let clean = text;
  let redacted = false;
  for (const secret of secrets) {
    const value = secret?.trim();
    if (!value || !clean.includes(value)) continue;
    clean = clean.split(value).join("[REDACTED]");
    redacted = true;
  }
  return { text: clean, redacted };
}

export function redact(text: string): { text: string; redacted: boolean } {
  const fields = redactOwnedSettings(text);
  const clean = fields.text
    .replace(
      /-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)/g,
      "[REDACTED PRIVATE KEY]",
    )
    .replace(/\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{15,}|Bearer\s+\S+)/gi, "[REDACTED]")
    .replace(
      /\b([A-Z_]*(?:API_KEY|TOKEN|SECRET|PASSWORD))\s*[=:]\s*["']?[^\s"',}]+/g,
      "$1=[REDACTED]",
    );
  return { text: clean, redacted: fields.redacted || clean !== fields.text };
}

function sanitizeText(
  text: string,
  secrets: readonly (string | undefined)[],
): { text: string; redacted: boolean } {
  const cleaned = redact(text);
  const scrubbed = scrubKnownSecrets(cleaned.text, secrets);
  return { text: scrubbed.text, redacted: cleaned.redacted || scrubbed.redacted };
}

/** Byte-identical to pi-agent-core's non-accurate estimateTokens path. */
function estimateTextTokens(text: string): number {
  return (Buffer.byteLength(text, "utf-8") + 3) >> 2;
}

interface SnapshotMessage {
  role: string;
  /** Text content, or the summary for summary roles. */
  text?: string;
  summary?: string;
  toolCallId?: string;
  toolName?: string;
  isError?: boolean;
  hasImage?: boolean;
  /** Tool calls carried by an assistant message, for artifact tracking. */
  toolCalls?: { id: string; name: string; path?: string }[];
}

/**
 * Map one active-branch SessionEntry to the upstream message shape, or null
 * when the entry carries no conversational content (metadata entries such as
 * model_change, label, title_change, thinking_level_change, model_usage,
 * credential_pin, ttsr_injection, session_init, mode_change, reset_boundary,
 * and non-state custom entries are not conversation).
 */
function mapEntry(entry: SessionEntry): SnapshotMessage | null | "unknown" {
  if (entry.type === "message") {
    const m = entry.message;
    if (m.role === "developer") {
      // Developer messages are system-adjacent instructions, not user
      // constraints; the upstream contract excludes system prompts, so these
      // are omitted and flagged as uncovered context.
      return "unknown";
    }
    if (m.role === "user") {
      const content = m.content;
      if (typeof content === "string") return { role: "user", text: content };
      return {
        role: "user",
        text: content.filter((c) => c.type === "text").map((c) => c.text).join("\n"),
        hasImage: content.some((c) => c.type === "image"),
      };
    }
    if (m.role === "assistant") {
      const toolCalls = m.content
        .filter((c) => c.type === "toolCall")
        .map((c) => ({
          id: c.id,
          name: c.name,
          path: typeof c.arguments?.path === "string" ? c.arguments.path : undefined,
        }));
      return {
        role: "assistant",
        text: m.content
          .filter((c) => c.type === "text")
          .map((c) => c.text)
          .join("\n"),
        hasImage: m.content.some((c) => c.type === "image"),
        toolCalls,
      };
    }
    if (m.role === "toolResult") {
      return {
        role: "toolResult",
        text: m.content.filter((c) => c.type === "text").map((c) => c.text).join("\n"),
        hasImage: m.content.some((c) => c.type === "image"),
        toolCallId: m.toolCallId,
        toolName: m.toolName,
        isError: m.isError,
      };
    }
    return "unknown";
  }
  if (entry.type === "custom_message") {
    // Hidden operational messages (display: false) - Firstmate watcher wakes,
    // session-start nudges, inbox doorbells - are transport plumbing, not
    // conversation. They are omitted from the snapshot entirely and counted in
    // coverage so the omission is visible to the judge contract.
    if (entry.display === false) return { role: "hidden_operational" };
    // Visible custom messages participate in LLM context; map them to
    // user-role text so the judge sees the same conversation the model does.
    const content = entry.content;
    if (typeof content === "string") return { role: "user", text: content };
    return {
      role: "user",
      text: content.filter((c) => c.type === "text").map((c) => c.text).join("\n"),
      hasImage: content.some((c) => c.type === "image"),
    };
  }
  if (entry.type === "compaction" || entry.type === "branch_summary") {
    return { role: "summary", summary: entry.summary };
  }
  return null;
}

export function snapshot(ctx: ExtensionContext, secrets: readonly (string | undefined)[] = []) {
  const branch = ctx.sessionManager.getBranch();
  const messages: SnapshotMessage[] = [];
  let unknownContext = false;
  for (const entry of branch) {
    const mapped = mapEntry(entry);
    if (mapped === "unknown") {
      unknownContext = true;
    } else if (mapped !== null) {
      messages.push(mapped);
    }
  }
  const latestSummary = [...messages].reverse().find((m) => m.role === "summary");
  const roleBearingMessages = messages.filter((m) => m.role !== "summary");
  const selectedMessages = roleBearingMessages.slice(-SNAPSHOT_MESSAGE_CAP);
  const conversationTokens = messages.reduce(
    (sum, m) => sum + estimateTextTokens(m.text ?? m.summary ?? ""),
    0,
  );
  const paths = new Map<string, { path: string; name: string }>();
  const artifacts = new Set<string>();
  let hasImages = false,
    redacted = false,
    omittedUsers = 0,
    recentTruncated = false,
    hiddenOperational = 0;
  let userBudget = 8000,
    tailBudget = 14000;
  const users: { role: string; text: string }[] = [];
  const recent: { role: string; text: string; tool?: string; error?: boolean }[] = [];
  let summary = "";
  if (latestSummary) {
    const s = sanitizeText(latestSummary.summary ?? "", secrets);
    summary = clip(s.text, 1500).text;
    redacted ||= s.redacted;
  }
  // Tool-call provenance is derived from the WHOLE active branch, not just the
  // transmitted window: a tool result inside the 64-message cap whose
  // initiating call fell outside it must still resolve its path so the
  // sensitive-file exclusion below can fire. Only the conversation content
  // selected for transmission is capped; the id->path map is metadata.
  for (const m of messages) {
    if (m.role === "assistant" && m.toolCalls)
      for (const c of m.toolCalls)
        if (typeof c.path === "string") paths.set(c.id, { path: c.path, name: c.name });
  }
  for (const m of selectedMessages) {
    if (m.role === "toolResult" && m.toolCallId) {
      const p = paths.get(m.toolCallId);
      if (p && !m.isError && ["write", "edit"].includes(p.name) && !sensitivePath.test(p.path)) {
        const full = resolve(ctx.cwd, p.path);
        if (fileExists(full)) artifacts.add(p.path);
      }
    }
  }
  for (let i = selectedMessages.length - 1; i >= 0; i--) {
    const m = selectedMessages[i];
    let raw = "";
    if (m.role === "user" || m.role === "assistant" || m.role === "toolResult") {
      hasImages ||= m.hasImage === true;
      raw = m.text ?? "";
      const toolPathName =
        m.role === "toolResult" && m.toolCallId ? (paths.get(m.toolCallId)?.path ?? "") : "";
      if (m.role === "toolResult" && sensitivePath.test(toolPathName)) {
        raw = "[Sensitive file content excluded]";
        redacted = true;
      }
    } else if (m.role === "hidden_operational") {
      hiddenOperational++;
      continue;
    } else {
      unknownContext = true;
      continue;
    }
    const cleaned = sanitizeText(raw, secrets);
    redacted ||= cleaned.redacted;
    if (m.role === "user") {
      const part = clip(cleaned.text, userBudget);
      if (part.truncated) omittedUsers++;
      if (part.text) users.unshift({ role: "user", text: part.text });
      userBudget = Math.max(0, userBudget - Buffer.byteLength(part.text));
    } else if (i >= selectedMessages.length - RECENT_TAIL_MESSAGES) {
      const part =
        m.role === "toolResult"
          ? clipMiddle(cleaned.text, Math.min(tailBudget, TOOL_RESULT_BUDGET))
          : clip(cleaned.text, Math.min(tailBudget, 8000));
      recentTruncated ||= part.truncated;
      tailBudget = Math.max(0, tailBudget - Buffer.byteLength(part.text));
      recent.unshift({
        role: m.role,
        text: part.text,
        ...(m.role === "toolResult" ? { tool: m.toolName, error: m.isError } : {}),
      });
    }
  }
  const persistent = ctx.sessionManager.getSessionFile();
  const recoveryAvailable = !!persistent && fileExists(persistent);
  const state = {
    userConstraints: users,
    recent,
    previousSummary: summary,
    savedArtifacts: [...artifacts].slice(-8).map((p) => {
      const cleaned = sanitizeText(p, secrets);
      redacted ||= cleaned.redacted;
      return clip(cleaned.text, 256).text;
    }),
    coverage: {
      omittedUserMessages: omittedUsers,
      olderMessagesOmitted: Math.max(0, roleBearingMessages.length - SNAPSHOT_MESSAGE_CAP),
      recentTextTruncated: recentTruncated,
      hasImages,
      redacted,
      unknownContext,
      hiddenOperationalMessagesOmitted: hiddenOperational,
      transcriptRecoverable: recoveryAvailable,
    },
    compaction: {
      description:
        "Lossy summary of older context; default recent tail about 20k tokens; tool results truncated to 2000 characters for summarization. Other compaction hooks/settings may differ.",
    },
  };
  const lastAssistant = recent.filter((m) => m.role === "assistant").at(-1)?.text ?? "";
  // Checkpoint identity binds the hint to this session, leaf, and model as well
  // as the latest exchange, so identical text in another session or under a
  // different model can neither suppress nor duplicate a hint.
  const checkpointKey = createHash("sha256")
    .update(
      JSON.stringify([
        ctx.sessionManager.getSessionId(),
        ctx.sessionManager.getLeafId(),
        ctx.model?.provider,
        ctx.model?.id,
        users.at(-1)?.text,
        lastAssistant,
      ]),
    )
    .digest("hex");

  return {
    state,
    conversationTokens,
    checkpointKey,
  };
}
