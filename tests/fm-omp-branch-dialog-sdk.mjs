// Real OMP event/persistence ordering, with a disposable local model endpoint.
// Launched by test_turn_end_dialog_with_real_sdk in the shell regression.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { createAgentSession, SessionManager } from "@oh-my-pi/pi-coding-agent";
const { initializeExtensions } = await import(`${process.env.FM_OMP_PACKAGE_DIR}/src/modes/runtime-init.ts`);
const { default: extension } = await import(process.env.EXTENSION_PATH);
const home = process.env.FM_HOME;
const state = process.env.FM_STATE_OVERRIDE;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
writeFileSync(`${state}/task-a.meta`, "project=project-a\nwindow=default:wA:p1\n");
writeFileSync(`${state}/task-a.status`, "working: task-a started\n");
const branchRequests = [];
let request = 0;
const server = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  async fetch(req) {
    const body = await req.json();
    const branch = JSON.stringify(body.messages[0]).includes("SUPERVISION BRANCH");
    if (branch) branchRequests.push(body.messages);
    const tool = branch && body.messages.at(-1).role !== "tool";
    const delta = tool
      ? { role: "assistant", tool_calls: [{ index: 0, id: `call_${++request}`, type: "function", function: {
          name: "fm_branch_report", arguments: JSON.stringify({ task: "task-a", verdict: "routine", summary: "saw dialog", wake: "signal: task-a", i: "dialog regression" }),
        } }] }
      : { role: "assistant", content: branch ? "Branch finished" : "Main acknowledged" };
    const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({ id: "dialog", object: "chat.completion.chunk", created: 1, model: "probe", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
    return new Response(chunk(delta) + chunk({}, tool ? "tool_calls" : "stop") + "data: [DONE]\n\n", { headers: { "Content-Type": "text/event-stream" } });
  },
});
const provider = (pi) => pi.registerProvider("dialog-probe", {
  baseUrl: `http://127.0.0.1:${server.port}/v1`, apiKey: "disposable", api: "openai-completions",
  models: [{ id: "probe", name: "probe", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 1000, compat: { supportsDeveloperRole: false } }],
});
let replyWasPending = false;
const created = await createAgentSession({
  cwd: home, agentDir: `${home}/agent`, sessionManager: SessionManager.inMemory(home),
  disableExtensionDiscovery: true, extensions: [provider, extension, (pi) => pi.on("turn_end", (event, ctx) => {
    if (event.message.role === "assistant") {
      replyWasPending ||= !ctx.sessionManager.getEntries().some((entry) => entry.type === "message" && entry.message === event.message);
    }
  })], modelPattern: "dialog-probe/probe", enableMCP: false, enableLsp: false,
  skills: [], contextFiles: [], promptTemplates: [], toolNames: [], autoApprove: true, systemPrompt: "Main test session",
});
const { session } = created;
const dispatch = async () => {
  writeFileSync(`${state}/.wake-queue`, "1\t1\tsignal\ttask-a.status\tsignal: task-a\n");
  const offer = { message: "signal: task-a", projects: [], heartbeat: false, eligible: true, accepted: false,
    accept(settlement) { this.accepted = true; this.settlement = settlement; } };
  created.eventBus.emit("fm-branch-supervision:dispatch", offer);
  assert.equal(offer.accepted, true);
  await offer.settlement;
};
try {
  await session.setModel(session.modelRegistry.find("dialog-probe", "probe"));
  await initializeExtensions(session, { reportSendError: (_source, error) => { throw error; }, reportRuntimeError: (error) => { throw error; } });
  await session.prompt("captain: first ordered item");
  await dispatch();
  assert(replyWasPending, "the real SDK did not expose the pending-persistence timing");
  const first = JSON.stringify(branchRequests[0]);
  assert(first.includes("[captain] captain: first ordered item"));
  assert(first.includes("[main] Main acknowledged"), "completed reply missing before first branch prompt");
  assert(first.indexOf("[captain]") < first.indexOf("[main]"));
  await session.prompt("captain: second ordered item");
  const next = branchRequests.length;
  await dispatch();
  const later = JSON.stringify(branchRequests[next]);
  assert.equal(later.split("[main] Main acknowledged").length - 1, 2, "pending reply was duplicated when persisted");
  const cursor = JSON.parse(readFileSync(`${state}/.branch-mirror-cursor`, "utf8"));
  assert(cursor.index <= session.sessionManager.getEntries().length, "cursor predicted unpersisted entries");
  console.log("ok - real OMP completed replies reach the branch before wakes without duplicates");
} finally {
  await session.dispose();
  server.stop();
}
