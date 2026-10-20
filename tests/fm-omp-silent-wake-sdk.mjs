// Real OMP turn recovery and chat rendering for silent wake turns, with a
// disposable local model endpoint. Launched by test_silent_wake_turn_with_real_sdk.
import assert from "node:assert/strict";
import { createAgentSession, SessionManager } from "@oh-my-pi/pi-coding-agent";
const packageDir = process.env.FM_OMP_PACKAGE_DIR;
const { initializeExtensions } = await import(`${packageDir}/src/modes/runtime-init.ts`);
const { AssistantMessageComponent } = await import(`${packageDir}/../pi-tui/src/chat/assistant-message.ts`);
const { installSilentWakeTurns, SILENT_WAKE_MARKER } = await import(process.env.EXTENSION_PATH);

const RETRY_PROMPTS = ["You said you would continue", "Stopped without actionable output"];
const requests = [];
const replies = [];
const server = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  async fetch(req) {
    const body = await req.json();
    // A recovery retry appends its prompt as the newest message of the request.
    requests.push(JSON.stringify(body.messages.at(-1)));
    const reply = replies.shift() ?? { text: "unscripted provider call" };
    const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({ id: "silent", object: "chat.completion.chunk", created: 1, model: "probe", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
    let stream = "";
    // reasoning_content parses to a thinking block whose signature is the field
    // name: the signed thinking-only shape OMP's unexpected-stop path retries.
    if (reply.reasoning) stream += chunk({ role: "assistant", reasoning_content: reply.reasoning });
    if (reply.text) stream += chunk({ role: "assistant", content: reply.text });
    return new Response(`${stream}${chunk({}, "stop")}data: [DONE]\n\n`, { headers: { "Content-Type": "text/event-stream" } });
  },
});
const provider = (pi) => pi.registerProvider("silent-probe", {
  baseUrl: `http://127.0.0.1:${server.port}/v1`, apiKey: "disposable", api: "openai-completions",
  models: [{ id: "probe", name: "probe", reasoning: true, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 1000, compat: { supportsDeveloperRole: false } }],
});
const home = process.env.FM_HOME;
const { session } = await createAgentSession({
  cwd: home, agentDir: `${home}/agent`, sessionManager: SessionManager.inMemory(home),
  disableExtensionDiscovery: true, extensions: [provider, (pi) => installSilentWakeTurns(pi)],
  modelPattern: "silent-probe/probe", enableMCP: false, enableLsp: false, skills: [], contextFiles: [],
  promptTemplates: [], toolNames: [], autoApprove: true, systemPrompt: "Main test session",
});

const visibleLines = (message) =>
  new AssistantMessageComponent(message, true).render(80)
    .map((line) => line.replace(/\x1b\[[0-9;]*m/g, "").trim())
    .filter(Boolean);

// Runs one turn and returns what the captain would see from it.
async function turn(label, start, scripted) {
  const before = requests.length;
  replies.push(...scripted);
  await start();
  await session.waitForIdle();
  assert.equal(replies.length, 0, `${label}: not every scripted reply was requested`);
  const sent = requests.slice(before);
  const final = session.messages.at(-1);
  assert.equal(final?.role, "assistant", `${label}: turn did not end on an assistant message`);
  const text = final.content.filter((block) => block.type === "text").map((block) => block.text).join("");
  return {
    calls: sent.length,
    nudged: sent.some((request) => RETRY_PROMPTS.some((prompt) => request.includes(prompt))),
    text,
    lines: visibleLines(final),
  };
}
const wake = () => session.sendCustomMessage(
  { customType: "firstmate-watcher-wake", content: "FIRSTMATE WATCHER WAKE: heartbeat", display: false, attribution: "agent" },
  { deliverAs: "nextTurn", triggerTurn: true },
);
const captain = (text) => () => session.prompt(text);

try {
  await session.setModel(session.modelRegistry.find("silent-probe", "probe"));
  await initializeExtensions(session, { reportSendError: (_source, error) => { throw error; }, reportRuntimeError: (error) => { throw error; } });

  // Divergence proof: without text, this OMP retries a thinking-only wake turn.
  const unmarked = await turn("thinking-only wake", wake, [
    { reasoning: "Nothing new for the captain." },
    { reasoning: "The retry asks again.", text: SILENT_WAKE_MARKER },
  ]);
  assert.equal(unmarked.calls, 2, "a thinking-only wake turn was not re-prompted, so this OMP no longer needs the marker");
  assert(unmarked.nudged, "the second request did not carry OMP's unexpected-stop retry");
  assert.deepEqual(unmarked.lines, [], `the marker answer after a retry stayed visible: ${JSON.stringify(unmarked)}`);

  const silent = await turn("marked wake", wake, [{ reasoning: "Nothing new for the captain.", text: SILENT_WAKE_MARKER }]);
  assert.deepEqual({ calls: silent.calls, nudged: silent.nudged }, { calls: 1, nudged: false }, "the silent marker drew a recovery retry");
  assert.equal(silent.text, "\u2026", "the silent marker was not rewritten");
  assert.deepEqual(silent.lines, [], `the silent wake turn left visible chat text: ${JSON.stringify(silent.lines)}`);

  const noChange = await turn("no-change wake", wake, [{ reasoning: "Routine.", text: "Captain, standing by." }]);
  assert.deepEqual({ calls: noChange.calls, nudged: noChange.nudged, lines: noChange.lines }, { calls: 1, nudged: false, lines: [] },
    `a whole-message no-change line on a wake turn stayed visible: ${JSON.stringify(noChange)}`);

  const outcome = "Captain, the fix is ready for review: https://github.com/example/repo/pull/7";
  const real = await turn("wake with outcome", wake, [{ reasoning: "A PR is ready.", text: outcome }]);
  assert.equal(real.text, outcome, "a real wake outcome was rewritten");
  assert.deepEqual(real.lines, [outcome], "a real wake outcome did not render");

  const asked = await turn("captain no-change", captain("anything new?"), [{ text: "Captain, standing by." }]);
  assert.deepEqual(asked.lines, ["Captain, standing by."], "a captain-initiated reply was hidden");

  const misuse = await turn("captain marker", captain("status?"), [{ text: SILENT_WAKE_MARKER }]);
  assert.deepEqual(misuse.lines, [SILENT_WAKE_MARKER], "the marker hid a captain-initiated turn");

  console.log("ok - real OMP: silent wake turns draw no retry and render nothing, captain turns and real outcomes stay visible");
} finally {
  await session.dispose();
  server.stop();
}
