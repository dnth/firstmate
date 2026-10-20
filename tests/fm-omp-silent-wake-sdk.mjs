// Real OMP turn recovery and chat rendering for silent wake turns, with a
// disposable local model endpoint that streams each reply in delayed chunks.
// Launched by test_silent_wake_turn_with_real_sdk.
import assert from "node:assert/strict";
import { createAgentSession, SessionManager } from "@oh-my-pi/pi-coding-agent";
const packageDir = process.env.FM_OMP_PACKAGE_DIR;
const { initializeExtensions } = await import(`${packageDir}/src/modes/runtime-init.ts`);
const { AssistantMessageComponent } = await import(`${packageDir}/../pi-tui/src/chat/assistant-message.ts`);
const { installSilentWakeTurns, SILENT_WAKE_MARKER } = await import(process.env.EXTENSION_PATH);

const RETRY_PROMPTS = ["You said you would continue", "Stopped without actionable output"];
const requests = [];
const replies = [];
const frames = [];
const encoder = new TextEncoder();
const pieces = (text, size) => text ? Array.from({ length: Math.ceil(text.length / size) }, (_, i) => text.slice(i * size, (i + 1) * size)) : [];
const server = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  async fetch(req) {
    const body = await req.json();
    // A recovery retry appends its prompt as the newest message of the request.
    requests.push(JSON.stringify(body.messages.at(-1)));
    const reply = replies.shift() ?? { text: "unscripted provider call" };
    const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({ id: "silent", object: "chat.completion.chunk", created: 1, model: "probe", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
    // reasoning_content parses to a thinking block whose signature is the field
    // name: the signed thinking-only shape OMP's unexpected-stop path retries.
    const events = [
      ...pieces(reply.reasoning, 8).map((part) => chunk({ role: "assistant", reasoning_content: part })),
      ...pieces(reply.text, 3).map((part) => chunk({ role: "assistant", content: part })),
      chunk({}, "stop"),
      "data: [DONE]\n\n",
    ];
    return new Response(new ReadableStream({
      async start(controller) {
        for (const event of events) {
          controller.enqueue(encoder.encode(event));
          await Bun.sleep(5);
        }
        controller.close();
      },
    }), { headers: { "Content-Type": "text/event-stream" } });
  },
});
const provider = (pi) => pi.registerProvider("silent-probe", {
  baseUrl: `http://127.0.0.1:${server.port}/v1`, apiKey: "disposable", api: "openai-completions",
  models: [{ id: "probe", name: "probe", reasoning: true, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 1000, compat: { supportsDeveloperRole: false } }],
});
const visibleLines = (message) =>
  new AssistantMessageComponent(message, true).render(80)
    .map((line) => line.replace(/\x1b\[[0-9;]*m/g, "").trim())
    .filter(Boolean);
// Every streamed frame OMP's chat view would draw for an assistant message.
const frameRecorder = (pi) => pi.on("message_update", (event) => {
  if (event.message.role === "assistant") frames.push(visibleLines(event.message));
});
const home = process.env.FM_HOME;
const { session } = await createAgentSession({
  cwd: home, agentDir: `${home}/agent`, sessionManager: SessionManager.inMemory(home),
  disableExtensionDiscovery: true, extensions: [provider, frameRecorder, (pi) => installSilentWakeTurns(pi)],
  modelPattern: "silent-probe/probe", enableMCP: false, enableLsp: false, skills: [], contextFiles: [],
  promptTemplates: [], toolNames: [], autoApprove: true, systemPrompt: "Main test session",
});

// Runs one turn and returns what the captain would see from it.
async function turn(label, start, scripted) {
  const before = requests.length;
  frames.length = 0;
  replies.push(...scripted);
  await start();
  await session.waitForIdle();
  assert.equal(replies.length, 0, `${label}: not every scripted reply was requested`);
  const sent = requests.slice(before);
  const final = session.messages.at(-1);
  assert.equal(final?.role, "assistant", `${label}: turn did not end on an assistant message`);
  assert(frames.length > 1, `${label}: no streamed frames were observed`);
  return {
    calls: sent.length,
    nudged: sent.some((request) => RETRY_PROMPTS.some((prompt) => request.includes(prompt))),
    text: final.content.filter((block) => block.type === "text").map((block) => block.text).join(""),
    lines: visibleLines(final),
    streamed: frames.filter((lines) => lines.length > 0),
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

  const silent = await turn("marked wake", wake, [{ reasoning: "Nothing new for the captain this time.", text: SILENT_WAKE_MARKER }]);
  assert.deepEqual({ calls: silent.calls, nudged: silent.nudged }, { calls: 1, nudged: false }, "the silent marker drew a recovery retry");
  assert.deepEqual({ lines: silent.lines, streamed: silent.streamed }, { lines: [], streamed: [] },
    `the silent wake turn drew visible chat text: ${JSON.stringify(silent)}`);

  // Backstop: the line streams before the rewrite, but the settled turn shows nothing.
  const noChange = await turn("no-change wake", wake, [{ reasoning: "Routine.", text: "Captain, standing by." }]);
  assert.deepEqual({ calls: noChange.calls, nudged: noChange.nudged, lines: noChange.lines }, { calls: 1, nudged: false, lines: [] },
    `a whole-message no-change line on a wake turn stayed visible: ${JSON.stringify(noChange)}`);

  const outcome = "Captain, the fix is ready for review: https://github.com/example/repo/pull/7";
  const real = await turn("wake with outcome", wake, [{ reasoning: "A PR is ready.", text: outcome }]);
  assert.equal(real.text, outcome, "a real wake outcome was rewritten");
  assert.deepEqual(real.lines, [outcome], "a real wake outcome did not render");
  assert(real.streamed.some((lines) => lines.join(" ") !== outcome), "frame capture never saw a partial streamed reply");

  const asked = await turn("captain no-change", captain("anything new?"), [{ text: "Captain, standing by." }]);
  assert.deepEqual(asked.lines, ["Captain, standing by."], "a captain-initiated reply was hidden");

  const answer = "Captain, CI on main is green.";
  const misuse = await turn("captain marker", captain("status?"), [
    { reasoning: "Nothing to say.", text: SILENT_WAKE_MARKER },
    { reasoning: "Answer the captain.", text: answer },
  ]);
  assert.deepEqual({ calls: misuse.calls, nudged: misuse.nudged, lines: misuse.lines }, { calls: 2, nudged: true, lines: [answer] },
    `the marker silenced a captain-initiated turn: ${JSON.stringify(misuse)}`);

  console.log("ok - real OMP: silent wake turns draw no retry and render nothing in any streamed frame, captain turns and real outcomes stay visible");
} finally {
  await session.dispose();
  server.stop();
}
