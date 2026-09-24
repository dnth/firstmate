#!/usr/bin/env bash
# Unit tests for the OMP compact-adviser adapter: gate chain, judge contract,
# snapshot budgets/privacy, lifecycle, and the person-only hint surface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-compact-adviser)
LIB="$ROOT/.omp/extensions/lib/compact-adviser"
ENTRY="$ROOT/.omp/extensions/fm-compact-adviser-omp.ts"

# A fixture "primary" home: plain git checkout (git-dir == git-common-dir) with
# AGENTS.md, bin/, and a real state dir, so fm_primary_scope_matches accepts it.
# The REAL scope libraries and a REAL copy of the extension tree are installed
# so entrypoint tests exercise the actual gate chain, not a stubbed shell.
PRIMARY_FIXTURE="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_FIXTURE/bin" "$PRIMARY_FIXTURE/state" "$PRIMARY_FIXTURE/config"
echo "# fixture" > "$PRIMARY_FIXTURE/AGENTS.md"
git -C "$PRIMARY_FIXTURE" init -q

install_scope_libs() {  # <fixture-home>
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$1/bin/"
}
install_extension() {  # <fixture-home>
  mkdir -p "$1/.omp/extensions/lib"
  cp "$ENTRY" "$1/.omp/extensions/"
  cp -R "$LIB" "$1/.omp/extensions/lib/"
}
install_scope_libs "$PRIMARY_FIXTURE"
install_extension "$PRIMARY_FIXTURE"

SECONDMATE_FIXTURE="$TMP_ROOT/secondmate-home"
mkdir -p "$SECONDMATE_FIXTURE/bin" "$SECONDMATE_FIXTURE/state" "$SECONDMATE_FIXTURE/config"
echo "mate-1" > "$SECONDMATE_FIXTURE/.fm-secondmate-home"
echo "# fixture" > "$SECONDMATE_FIXTURE/AGENTS.md"
install_scope_libs "$SECONDMATE_FIXTURE"
install_extension "$SECONDMATE_FIXTURE"

# A fixture "worker" home: a linked worktree of the fixture repo, so
# git-dir != git-common-dir and the module-root check refuses it even when
# inherited overrides point at the primary.
git -C "$PRIMARY_FIXTURE" -c user.email=t@t -c user.name=t commit -qm init --allow-empty
git -C "$PRIMARY_FIXTURE" worktree add -q "$TMP_ROOT/worker-home" 2>/dev/null
mkdir -p "$TMP_ROOT/worker-home/state" "$TMP_ROOT/worker-home/config"
cp "$PRIMARY_FIXTURE/AGENTS.md" "$TMP_ROOT/worker-home/AGENTS.md"
mkdir -p "$TMP_ROOT/worker-home/bin"
install_scope_libs "$TMP_ROOT/worker-home"
install_extension "$TMP_ROOT/worker-home"

run_node() {
  FM_LIB="$LIB" FM_ENTRY="$ENTRY" \
  FM_PRIMARY="$PRIMARY_FIXTURE" FM_WORKER="$TMP_ROOT/worker-home" FM_TMP="$TMP_ROOT" \
  FM_SECONDMATE="$SECONDMATE_FIXTURE" \
  node --experimental-strip-types --input-type=module <<'JS'
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, mkdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const LIB = process.env.FM_LIB;
const ENTRY = process.env.FM_ENTRY;
const PRIMARY = process.env.FM_PRIMARY;
const WORKER = process.env.FM_WORKER;
const SECONDMATE = process.env.FM_SECONDMATE;
const TMP = process.env.FM_TMP;

const { installAdviser } = await import(`${LIB}/adviser.ts`);
const { ConfigStore } = await import(`${LIB}/config.ts`);
const { disabledByEnv } = await import(`${LIB}/disable.ts`);
const { snapshot, clipMiddle } = await import(`${LIB}/context.ts`);
const { parseJudgment, requestBody, score, floorFor, qualifies, QUESTIONS, JudgeError } =
  await import(`${LIB}/judge.ts`);
const { restoreState, initialState, STATE_TYPE } = await import(`${LIB}/state.ts`);

function fakePi(appendedEntries = []) {
  const handlers = new Map();
  const appended = [];
  const commands = new Map();
  let seq = 0;
  return {
    handlers, appended, commands,
    on(event, fn) { handlers.set(event, fn); },
    // Mirror OMP: a custom entry lands on the branch where restoreState finds it.
    appendEntry(type, data) {
      appended.push({ type, data });
      appendedEntries.push({
        type: "custom", id: `st${seq++}`, parentId: null, timestamp: "t",
        customType: type, data,
      });
    },
    registerCommand(name, spec) { commands.set(name, spec); },
  };
}

let widgetCalls = [];
let statusCalls = [];
let notifyCalls = [];
let sendMessageCalls = 0;
function fakeCtx(over = {}, appendedEntries = []) {
  widgetCalls = [];
  statusCalls = [];
  notifyCalls = [];
  sendMessageCalls = 0;
  const branch = over.branch ?? [];
  return {
    mode: "tui",
    hasUI: true,
    cwd: over.cwd ?? TMP,
    model: over.model === null ? undefined : (over.model ?? { provider: "p", id: "m", contextWindow: 200000 }),
    sessionManager: {
      getBranch: () => [...branch, ...appendedEntries],
      getSessionId: () => over.sessionId ?? "sess-1",
      getLeafId: () => over.leafId ?? "leaf-1",
      getSessionFile: () => over.sessionFile,
    },
    getContextUsage: () => over.usage === "unknown" ? undefined : (over.usage ?? { tokens: 100000, contextWindow: 200000, percent: 50 }),
    isIdle: () => over.idle ?? true,
    hasPendingMessages: () => over.pending ?? false,
    ui: {
      getEditorText: () => over.editorText ?? "",
      setWidget: (k, c) => widgetCalls.push([k, c]),
      setStatus: (k, t) => statusCalls.push([k, t]),
      notify: (m, t) => notifyCalls.push([m, t]),
    },
    sendMessage: () => { sendMessageCalls++; },
    compact: () => { throw new Error("compact() must never be called"); },
  };
}

function msgEntry(id, message) {
  return { type: "message", id, parentId: null, timestamp: "2026-09-20T00:00:00Z", message };
}
function userMsg(text) {
  return { role: "user", content: text, timestamp: 1 };
}
function assistantMsg(text, stopReason = "stop") {
  return {
    role: "assistant",
    content: [{ type: "text", text }],
    api: "a", provider: "p", model: "m",
    usage: {}, stopReason, timestamp: 2,
  };
}
function toolResultMsg(text, toolCallId = "tc1", toolName = "read", isError = false) {
  return { role: "toolResult", toolCallId, toolName, content: [{ type: "text", text }], isError, timestamp: 3 };
}
function qualifyingJudgment() {
  return {
    done: { choice: "finished", probabilities: { finished: 0.99, not_finished: 0.005, unclear: 0.005 }, confidence: 0.9 },
    shape: { choice: "hands_on", probabilities: { hands_on: 0.99, coordinating: 0.005, unclear: 0.005 }, confidence: 0.9 },
    model: "jev-latest", inputTokens: 10, outputTokens: 5,
  };
}
function writeConfig(dir, cfg) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "compact-adviser.json"), JSON.stringify({ version: 1, ...cfg }));
}
function settledBranch() {
  // Pad past the upstream <=20k-conversation-token skip gate (~84KB of text;
  // snapshot budgets keep the serialized request under the 32KB cap).
  return [
    msgEntry("e0", userMsg("context ".repeat(12000))),
    msgEntry("e1", userMsg("do the thing")),
    msgEntry("e2", assistantMsg("done, PR opened")),
  ];
}
// agent_end fires settled() fire-and-forget; drain the microtask queue so the
// stubbed judge and hint writes complete before asserting.
async function flush() {
  for (let i = 0; i < 10; i++) await new Promise((r) => setImmediate(r));
}

// ---------------------------------------------------------------- AC1: inert by default
// Entrypoint tests run against the fixture copies of the extension so the
// module root is a real plain checkout / linked worktree / secondmate home
// regardless of where this suite itself executes (the repo under test may be
// a linked worktree during validation).
const PRIMARY_ENTRY = `${PRIMARY}/.omp/extensions/fm-compact-adviser-omp.ts`;
const WORKER_ENTRY = `${WORKER}/.omp/extensions/fm-compact-adviser-omp.ts`;
const SECONDMATE_ENTRY = `${SECONDMATE}/.omp/extensions/fm-compact-adviser-omp.ts`;
const EXPECTED_EVENTS = ["agent_end", "turn_end", "session_start", "session_switch",
  "session_before_switch", "session_compact", "session_before_compact",
  "session_shutdown", "input", "before_agent_start", "session_branch",
  "session_before_branch", "session_tree", "session_before_tree"];

// Deterministic environment for entrypoint tests: clear every knob the
// entrypoint consults, then apply the case's overrides.
const ENTRY_ENV_KEYS = [
  "FM_ROOT_OVERRIDE", "FM_STATE_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_HOME",
  "FM_DATA_OVERRIDE", "FM_PROJECTS_OVERRIDE", "COMPACT_ADVISER_DISABLE",
  "FM_OMP_HARNESS", "FM_OMP_TASK_INBOX_DIR", "FM_OMP_TASK_TURN_STARTED",
  "FM_OMP_SESSION_POINTER", "NO_MISTAKES_GATE", "FM_GATE_REFUSE_BYPASS",
];
async function withEntryEnv(overrides, fn) {
  const saved = {};
  for (const k of ENTRY_ENV_KEYS) { saved[k] = process.env[k]; delete process.env[k]; }
  Object.assign(process.env, overrides);
  try { return await fn(); }
  finally {
    for (const k of ENTRY_ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
}
// The entrypoint captures FM_* constants at module evaluation, so the import
// itself must run inside the scoped environment - not just mod.default(pi).
async function runEntry(entry, tag, overrides, pi) {
  await withEntryEnv(overrides, async () => {
    const mod = await import(`${entry}?t=${Date.now()}-${tag}`);
    mod.default(pi);
  });
}

{
  // Positive control FIRST: a genuine opted-in primary activates through the
  // real entrypoint and real scope libraries, so the inert assertions below
  // cannot pass vacuously.
  writeConfig(`${PRIMARY}/config`, { mode: "hint", minContextTokens: 40000, logRequests: false });
  const pi = fakePi();
  await runEntry(PRIMARY_ENTRY, "primary-on", {
    FM_ROOT_OVERRIDE: PRIMARY,
    FM_STATE_OVERRIDE: `${PRIMARY}/state`,
    FM_CONFIG_OVERRIDE: `${PRIMARY}/config`,
  }, pi);
  for (const ev of EXPECTED_EVENTS) assert.ok(pi.handlers.has(ev), `primary opt-in missing handler: ${ev}`);
  assert.equal(pi.handlers.size, EXPECTED_EVENTS.length, "primary opt-in registers the full handler set");
}
{
  // No opt-in file: entry registers nothing even in a primary scope.
  const pi = fakePi();
  await runEntry(PRIMARY_ENTRY, "no-consent", {
    FM_ROOT_OVERRIDE: PRIMARY,
    FM_STATE_OVERRIDE: `${PRIMARY}/state`,
    FM_CONFIG_OVERRIDE: `${TMP}/no-config-here`,
  }, pi);
  assert.equal(pi.handlers.size, 0, "no handlers without opt-in config");
  assert.equal(pi.commands.size, 0, "no command without opt-in config");
}
{
  // Worker scope (linked worktree module root): even with its own config
  // present, nothing registers.
  writeConfig(`${WORKER}/config`, { mode: "hint", minContextTokens: 40000, logRequests: false });
  const pi = fakePi();
  await runEntry(WORKER_ENTRY, "worker-own", {
    FM_ROOT_OVERRIDE: WORKER,
    FM_STATE_OVERRIDE: `${WORKER}/state`,
    FM_CONFIG_OVERRIDE: `${WORKER}/config`,
  }, pi);
  assert.equal(pi.handlers.size, 0, "worker session must never activate the adviser");
}
{
  // F1 regression: a worker that INHERITS the primary's overrides must still
  // be inert - the linked module root is rejected before overrides apply.
  const pi = fakePi();
  await runEntry(WORKER_ENTRY, "worker-inherited", {
    FM_ROOT_OVERRIDE: PRIMARY,
    FM_STATE_OVERRIDE: `${PRIMARY}/state`,
    FM_CONFIG_OVERRIDE: `${PRIMARY}/config`,
  }, pi);
  assert.equal(pi.handlers.size, 0,
    "inherited primary overrides must not activate a worker's adviser");
}
{
  // Explicit spawned-worker identity: FM_OMP_HARNESS=omp (stamped at every
  // worker/secondmate launch) refuses even on a primary module root.
  const pi = fakePi();
  await runEntry(PRIMARY_ENTRY, "worker-marker", {
    FM_OMP_HARNESS: "omp",
    FM_ROOT_OVERRIDE: PRIMARY,
    FM_STATE_OVERRIDE: `${PRIMARY}/state`,
    FM_CONFIG_OVERRIDE: `${PRIMARY}/config`,
  }, pi);
  assert.equal(pi.handlers.size, 0, "FM_OMP_HARNESS=omp identity must refuse");
}
{
  // Task-marker variant of explicit worker identity.
  const pi = fakePi();
  await runEntry(PRIMARY_ENTRY, "worker-task-marker", {
    FM_OMP_TASK_INBOX_DIR: `${TMP}/task.inbox`,
    FM_ROOT_OVERRIDE: PRIMARY,
    FM_STATE_OVERRIDE: `${PRIMARY}/state`,
    FM_CONFIG_OVERRIDE: `${PRIMARY}/config`,
  }, pi);
  assert.equal(pi.handlers.size, 0, "FM_OMP_TASK_INBOX_DIR identity must refuse");
}
{
  // Gate agent: NO_MISTAKES_GATE refuses through the real gate-refuse lib.
  const pi = fakePi();
  await runEntry(PRIMARY_ENTRY, "gate-agent", {
    NO_MISTAKES_GATE: "1",
    FM_ROOT_OVERRIDE: PRIMARY,
    FM_STATE_OVERRIDE: `${PRIMARY}/state`,
    FM_CONFIG_OVERRIDE: `${PRIMARY}/config`,
  }, pi);
  assert.equal(pi.handlers.size, 0, "gate agent must never activate the adviser");
}
{
  // COMPACT_ADVISER_DISABLE wins over everything.
  const pi = fakePi();
  await runEntry(PRIMARY_ENTRY, "disabled", {
    COMPACT_ADVISER_DISABLE: " yes ",
    FM_ROOT_OVERRIDE: PRIMARY,
    FM_STATE_OVERRIDE: `${PRIMARY}/state`,
    FM_CONFIG_OVERRIDE: `${PRIMARY}/config`,
  }, pi);
  assert.equal(pi.handlers.size, 0, "disable env must make the adapter inert");
}
{
  // Secondmate module root: refused by the marker check before overrides.
  writeConfig(`${SECONDMATE}/config`, { mode: "hint", minContextTokens: 40000, logRequests: false });
  const pi = fakePi();
  await runEntry(SECONDMATE_ENTRY, "secondmate", {
    FM_ROOT_OVERRIDE: SECONDMATE,
    FM_STATE_OVERRIDE: `${SECONDMATE}/state`,
    FM_CONFIG_OVERRIDE: `${SECONDMATE}/config`,
  }, pi);
  assert.equal(pi.handlers.size, 0, "secondmate sessions must never activate the adviser");
}
assert.equal(disabledByEnv("1"), true);
assert.equal(disabledByEnv(" TRUE "), true);
assert.equal(disabledByEnv("on"), true);
assert.equal(disabledByEnv("0"), false);
assert.equal(disabledByEnv(undefined), false);
assert.ok(Buffer.byteLength(clipMiddle("é".repeat(1000), 512).text) <= 512);
console.log("AC1 inert-by-default gates: ok");

// ------------------------------------------------- AC2: opt-in end-to-end hint path
{
  const configDir = mkdtempSync(join(TMP, "cfg-"));
  const logDir = mkdtempSync(join(TMP, "log-"));
  writeConfig(configDir, { mode: "hint", minContextTokens: 40000, logRequests: false });
  const appendedEntries = [];
  const pi = fakePi(appendedEntries);
  const judged = [];
  installAdviser(pi, {
    configDir, logDir,
    key: () => "ts-test-key",
    evaluate: async (state, key, signal) => {
      judged.push({ state, key, body: requestBody(state) });
      return qualifyingJudgment();
    },
  });
  for (const ev of ["agent_end", "turn_end", "session_start", "session_switch",
    "session_before_switch", "session_compact", "session_before_compact",
    "session_shutdown", "input", "before_agent_start", "session_branch",
    "session_before_branch", "session_tree", "session_before_tree"]) {
    assert.ok(pi.handlers.has(ev), `missing handler: ${ev}`);
  }
  const ctx = fakeCtx({ branch: settledBranch() }, appendedEntries);
  await pi.handlers.get("agent_end")({ type: "agent_end", messages: [] }, ctx);
  await flush();
  assert.equal(judged.length, 1, "judge called once at a settled checkpoint");
  assert.equal(judged[0].key, "ts-test-key");
  const body = JSON.parse(judged[0].body);
  assert.equal(body.model, "jev-latest");
  assert.deepEqual(body.questions, QUESTIONS, "request must carry the pinned question set");
  assert.ok(body.state.userConstraints.length >= 1);
  assert.ok(body.state.recent.some((m) => m.role === "assistant"));
  assert.equal(widgetCalls.length, 1, "hint shown via setWidget");
  assert.equal(widgetCalls[0][0], "compact-adviser");
  assert.ok(String(widgetCalls[0][1]).includes("/compact"));
  assert.equal(sendMessageCalls, 0, "sendMessage is forbidden for hints");
  assert.ok(pi.appended.some((e) => e.type === STATE_TYPE), "state persisted via appendEntry");

  // Same checkpoint again: no duplicate judge call.
  await pi.handlers.get("agent_end")({ type: "agent_end", messages: [] }, ctx);
  await flush();
  assert.equal(judged.length, 1, "duplicate checkpoint must not re-judge");

  // willContinue auto-retry: not a settled checkpoint.
  const ctx2 = fakeCtx({ branch: settledBranch() });
  await pi.handlers.get("agent_end")({ type: "agent_end", messages: [], willContinue: true }, ctx2);
  await flush();
  assert.equal(judged.length, 1, "willContinue must not trigger a judgment");

  // New user input clears the hint.
  pi.handlers.get("input")({ type: "input", text: "next", source: "interactive" }, ctx);
  assert.ok(widgetCalls.some(([k, c]) => k === "compact-adviser" && c === undefined),
    "input clears the hint widget");
  console.log("AC2 opt-in hint path: ok");
}
{
  // Non-qualifying judgment: no hint.
  const configDir = mkdtempSync(join(TMP, "cfg2-"));
  const logDir = mkdtempSync(join(TMP, "log2-"));
  writeConfig(configDir, { mode: "hint", minContextTokens: 40000, logRequests: false });
  const pi = fakePi();
  installAdviser(pi, {
    configDir, logDir, key: () => "k",
    evaluate: async () => ({
      done: { choice: "not_finished", probabilities: { finished: 0.01, not_finished: 0.98, unclear: 0.01 }, confidence: 0.9 },
      shape: { choice: "hands_on", probabilities: { hands_on: 0.9, coordinating: 0.05, unclear: 0.05 }, confidence: 0.9 },
      model: "jev-latest", inputTokens: 1, outputTokens: 1,
    }),
  });
  const ctx = fakeCtx({ branch: settledBranch() });
  await pi.handlers.get("agent_end")({ type: "agent_end", messages: [] }, ctx);
  await flush();
  assert.equal(widgetCalls.length, 0, "non-qualifying judgment shows no hint");
}
{
  // Removing consent after startup must revoke the data gate before a new evaluation.
  const configDir = mkdtempSync(join(TMP, "cfg-revoke-"));
  const logDir = mkdtempSync(join(TMP, "log-revoke-"));
  writeConfig(configDir, { mode: "hint", minContextTokens: 40000, logRequests: false });
  const pi = fakePi();
  let calls = 0;
  installAdviser(pi, {
    configDir, logDir, key: () => "k",
    evaluate: async () => { calls++; return qualifyingJudgment(); },
  });
  unlinkSync(join(configDir, "compact-adviser.json"));
  const ctx = fakeCtx({ branch: settledBranch() });
  await pi.handlers.get("agent_end")({ type: "agent_end", messages: [] }, ctx);
  await flush();
  assert.equal(calls, 0, "deleted consent must block TypeSafe evaluation");
  assert.equal(widgetCalls.length, 0, "deleted consent must not show a hint");
}
{
  // Judge failure: no hint, backoff recorded, warning notified.
  const configDir = mkdtempSync(join(TMP, "cfg3-"));
  const logDir = mkdtempSync(join(TMP, "log3-"));
  writeConfig(configDir, { mode: "hint", minContextTokens: 40000, logRequests: false });
  const pi = fakePi();
  installAdviser(pi, {
    configDir, logDir, key: () => "k",
    evaluate: async () => { throw new JudgeError("network"); },
  });
  const ctx = fakeCtx({ branch: settledBranch() });
  await pi.handlers.get("agent_end")({ type: "agent_end", messages: [] }, ctx);
  await flush();
  assert.equal(widgetCalls.length, 0, "judge failure shows no hint");
  assert.ok(notifyCalls.some(([m]) => m.includes("did not get a usable judgment")),
    "judge failure notifies a warning");
  assert.ok(pi.appended.some((e) => e.type === STATE_TYPE && e.data.failures === 1),
    "failure backoff persisted");
}
{
  // Eligibility gates: mode off, missing key, low usage, pending messages,
  // editor draft, non-idle, unknown usage - each blocks the judge.
  for (const [name, cfgPatch, ctxOver, keyFn] of [
    ["mode off", { mode: "off" }, {}, () => "k"],
    ["no key", {}, {}, () => undefined],
    ["below minimum", { minContextTokens: 40000 }, { usage: { tokens: 1000, contextWindow: 200000, percent: 1 } }, () => "k"],
    ["pending messages", {}, { pending: true }, () => "k"],
    ["editor draft", {}, { editorText: "typing" }, () => "k"],
    ["not idle", {}, { idle: false }, () => "k"],
    ["unknown usage", {}, { usage: "unknown" }, () => "k"],
    ["no model", {}, { model: null }, () => "k"],
    ["non-tui mode", {}, { }, () => "k"],
  ]) {
    const configDir = mkdtempSync(join(TMP, `cfgx-${name}-`));
    const logDir = mkdtempSync(join(TMP, `logx-${name}-`));
    writeConfig(configDir, { mode: "hint", minContextTokens: 40000, logRequests: false, ...cfgPatch });
    const pi = fakePi();
    let calls = 0;
    installAdviser(pi, {
      configDir, logDir, key: keyFn,
      evaluate: async () => { calls++; return qualifyingJudgment(); },
    });
    const over = { branch: settledBranch(), ...ctxOver };
    if (name === "non-tui mode") over.mode = undefined; // handled below
    const ctx = fakeCtx(over);
    if (name === "non-tui mode") ctx.mode = "rpc";
    await pi.handlers.get("agent_end")({ type: "agent_end", messages: [] }, ctx);
  await flush();
    assert.equal(calls, 0, `gate must block judge: ${name}`);
    assert.equal(widgetCalls.length, 0, `gate must block hint: ${name}`);
  }
  console.log("eligibility gates: ok");
}

// ------------------------------------------------- judge contract lockstep
{
  const body = JSON.parse(requestBody({ hello: "world" }));
  assert.equal(body.model, "jev-latest");
  assert.deepEqual(body.questions, QUESTIONS);
  assert.throws(() => requestBody({ big: "x".repeat(40000) }), JudgeError,
    "32k request cap enforced");
  const j = parseJudgment({
    model: "jev-latest",
    answers: {
      done: { type: "choice", choice: "finished", probabilities: { finished: 0.9, not_finished: 0.05, unclear: 0.05 }, confidence: 0.8 },
      shape: { type: "choice", choice: "hands_on", probabilities: { hands_on: 0.9, coordinating: 0.05, unclear: 0.05 }, confidence: 0.8 },
    },
    usage: { input_tokens: 3, output_tokens: 2 },
  });
  assert.equal(j.done.choice, "finished");
  // Reject malformed: unknown choice, bad probability sum, winner not max.
  for (const bad of [
    { choice: "bogus", probabilities: { finished: 0.9, not_finished: 0.05, unclear: 0.05 } },
    { choice: "finished", probabilities: { finished: 0.5, not_finished: 0.05, unclear: 0.05 } },
    { choice: "finished", probabilities: { finished: 0.4, not_finished: 0.5, unclear: 0.1 } },
  ]) {
    assert.throws(() => parseJudgment({
      model: "m",
      answers: { done: { type: "choice", ...bad },
        shape: { type: "choice", choice: "hands_on", probabilities: { hands_on: 0.9, coordinating: 0.05, unclear: 0.05 }, confidence: 0.8 } },
      usage: { input_tokens: 1, output_tokens: 1 },
    }), JudgeError);
  }
  // Score/floor semantics.
  const finished = parseJudgment({
    model: "m",
    answers: {
      done: { type: "choice", choice: "finished", probabilities: { finished: 1, not_finished: 0, unclear: 0 }, confidence: 1 },
      shape: { type: "choice", choice: "hands_on", probabilities: { hands_on: 1, coordinating: 0, unclear: 0 }, confidence: 1 },
    },
    usage: { input_tokens: 1, output_tokens: 1 },
  });
  assert.equal(score(finished), 1);
  assert.equal(floorFor(0.05), 0.9);
  assert.equal(floorFor(0.95), 0.5);
  assert.equal(floorFor(Number.NaN), 0.9, "unknown usage uses strictest floor");
  assert.equal(qualifies(finished, 0.5), true);
  const coordinating = { ...finished, shape: { ...finished.shape, probabilities: { hands_on: 0, coordinating: 1, unclear: 0 } } };
  assert.equal(score(coordinating), 0.5, "finished+coordinating scores 0.5");
  assert.equal(qualifies(coordinating, 0.05), false, "0.5 below strict floor");
  console.log("judge lockstep semantics: ok");
}

// ------------------------------------------------- snapshot budgets and privacy
{
  const big = "y".repeat(20000);
  const branch = [
    msgEntry("u1", userMsg("first constraint " + big)),
    msgEntry("u2", userMsg("second constraint")),
    { type: "custom_message", id: "op1", parentId: null, timestamp: "t",
      customType: "firstmate-watcher-wake", content: "SECRET-OPS-WAKE-CONTENT", display: false },
    { type: "custom_message", id: "op2", parentId: null, timestamp: "t",
      customType: "visible-note", content: "visible custom text", display: true },
    { type: "message", id: "d1", parentId: null, timestamp: "t",
      message: { role: "developer", content: "DEV-SECRET-INSTRUCTIONS", timestamp: 1 } },
    msgEntry("a1", assistantMsg("working on it")),
    msgEntry("tr1", toolResultMsg("result body")),
    { type: "compaction", id: "c1", parentId: null, timestamp: "t",
      summary: "older work summary", firstKeptEntryId: "u1", tokensBefore: 50000 },
    msgEntry("a2", assistantMsg("all done")),
  ];
  const ctx = fakeCtx({ branch });
  const view = snapshot(ctx, []);
  const serialized = JSON.stringify(view.state);
  assert.ok(!serialized.includes("SECRET-OPS-WAKE-CONTENT"),
    "hidden operational messages never reach the snapshot");
  assert.ok(!serialized.includes("DEV-SECRET-INSTRUCTIONS"),
    "developer messages never reach the snapshot");
  assert.ok(serialized.includes("visible custom text"),
    "visible custom messages are conversation");
  assert.equal(view.state.coverage.hiddenOperationalMessagesOmitted, 1);
  assert.equal(view.state.coverage.unknownContext, true, "developer role flagged as uncovered");
  assert.equal(view.state.previousSummary, "older work summary");
  assert.ok(view.state.coverage.omittedUserMessages >= 1, "user budget enforced");
  const userBytes = view.state.userConstraints.reduce((s, u) => s + Buffer.byteLength(u.text), 0);
  assert.ok(userBytes <= 8000, `user budget 8000 respected, got ${userBytes}`);
  const recentBytes = view.state.recent.reduce((s, m) => s + Buffer.byteLength(m.text), 0);
  assert.ok(recentBytes <= 14000, `recent budget 14000 respected, got ${recentBytes}`);
  assert.ok(view.state.recent.every((m) => m.role !== "toolResult" || Buffer.byteLength(m.text) <= 512 + 64),
    "tool result cap respected");
  // Checkpoint identity varies with session and model.
  const otherSession = snapshot(fakeCtx({ branch, sessionId: "sess-2" }), []);
  const otherModel = snapshot(fakeCtx({ branch, model: { provider: "p", id: "m2", contextWindow: 1 } }), []);
  assert.notEqual(view.checkpointKey, otherSession.checkpointKey, "session id in checkpoint identity");
  assert.notEqual(view.checkpointKey, otherModel.checkpointKey, "model identity in checkpoint identity");
  // Secret scrubbing.
  const secretBranch = [
    msgEntry("u1", userMsg("my key is sk-abcdefghijklmnop1234 ok")),
    msgEntry("a1", assistantMsg("noted MY_API_KEY=supersecretvalue")),
  ];
  const scrubbed = snapshot(fakeCtx({ branch: secretBranch }), ["known-secret-xyz"]);
  const scrubbedText = JSON.stringify(scrubbed.state);
  assert.ok(!scrubbedText.includes("sk-abcdefghijklmnop1234"), "API-key-shaped text redacted");
  assert.ok(!scrubbedText.includes("supersecretvalue"), "KEY=value secrets redacted");
  assert.equal(scrubbed.state.coverage.redacted, true);
  const withSecret = snapshot(fakeCtx({ branch: [msgEntry("u1", userMsg("token known-secret-xyz here"))] }), ["known-secret-xyz"]);
  assert.ok(!JSON.stringify(withSecret.state).includes("known-secret-xyz"), "known secrets scrubbed");
  const manyUsers = Array.from({ length: 65 }, (_, i) => msgEntry(`many-${i}`, userMsg(`constraint ${i}`)));
  const capped = snapshot(fakeCtx({ branch: manyUsers }), []);
  assert.ok(
    capped.state.userConstraints.length + capped.state.recent.length <= 64,
    "total transmitted conversation messages capped at 64",
  );
  const summaryAndMessages = [
    { type: "compaction", id: "summary", parentId: null, timestamp: "t", summary: "retain this summary" },
    ...Array.from({ length: 64 }, (_, i) => msgEntry(`after-${i}`, userMsg(`after ${i}`))),
  ];
  const preservedSummary = snapshot(fakeCtx({ branch: summaryAndMessages }), []);
  assert.equal(preservedSummary.state.previousSummary, "retain this summary",
    "latest summary survives the message cap");
  // F4 regression: a sensitive tool RESULT inside the 64-message window whose
  // initiating CALL fell outside it must still be excluded - provenance is
  // derived from the whole branch, not the transmitted window.
  const crossingBranch = [
    msgEntry("call", {
      role: "assistant",
      content: [{ type: "toolCall", id: "sensitive", name: "read", arguments: { path: ".env" } }],
      api: "a", provider: "p", model: "m", usage: {}, stopReason: "toolUse", timestamp: 2,
    }),
    ...Array.from({ length: 63 }, (_, i) => msgEntry(`middle-${i}`, assistantMsg("ok"))),
    msgEntry("result", toolResultMsg("INTERNAL_DATABASE_URL=postgres://alice:swordfish@private/db", "sensitive")),
  ];
  const crossing = snapshot(fakeCtx({ branch: crossingBranch }), []);
  const crossingText = JSON.stringify(crossing.state);
  assert.ok(!crossingText.includes("swordfish"),
    "sensitive result must be excluded even when its call is outside the window");
  assert.ok(crossingText.includes("[Sensitive file content excluded]"),
    "excluded result keeps the redaction marker");
  assert.equal(crossing.state.coverage.redacted, true);
  console.log("snapshot budgets/privacy: ok");
}

// ------------------------------------------------- state restore + config validation
{
  const branch = [
    { type: "custom", id: "s1", parentId: null, timestamp: "t",
      customType: STATE_TYPE, data: { ...initialState(null), completed: 5 } },
  ];
  assert.equal(restoreState(branch).completed, 5);
  const corrupt = [
    { type: "custom", id: "s2", parentId: null, timestamp: "t",
      customType: STATE_TYPE, data: { version: 1, completed: -1 } },
  ];
  assert.equal(restoreState(corrupt).snoozeUntil, 3, "corrupt state resets with snooze");
  const storeDir = mkdtempSync(join(TMP, "store-"));
  const store = new ConfigStore(storeDir);
  assert.equal(store.exists(), false);
  store.update({ mode: "hint" });
  assert.equal(store.exists(), true);
  assert.equal(store.read().mode, "hint");
  assert.throws(() => store.update({ mode: "auto" }), /hint.*off/,
    "auto mode rejected: hint-only port");
  console.log("state/config: ok");
}
JS
}

run_node || fail "compact-adviser adapter tests failed"
pass "compact-adviser adapter: gates, judge contract, snapshot, lifecycle"
