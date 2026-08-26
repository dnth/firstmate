#!/usr/bin/env node
import { randomUUID } from "node:crypto";
import net from "node:net";

const args = process.argv.slice(2);
let socketPath = "";
let taskId = "";
let content;
for (let i = 0; i < args.length; i += 1) {
  const arg = args[i];
  if (arg === "--socket") socketPath = args[++i] ?? "";
  else if (arg === "--task") taskId = args[++i] ?? "";
  else if (arg === "--message") content = args[++i] ?? "";
  else {
    process.stderr.write(`error: unknown fm-omp-send option: ${arg}\n`);
    process.exit(2);
  }
}

if (!socketPath || !taskId || content === undefined) {
  process.stderr.write("usage: fm-omp-send.mjs --socket PATH --task ID --message TEXT\n");
  process.exit(2);
}

const requestId = randomUUID();
const timeout = setTimeout(() => {
  process.stderr.write(`error: native OMP worker receipt timed out (request=${requestId})\n`);
  process.exit(1);
}, 3000);
timeout.unref();

const socket = net.createConnection(socketPath);
let input = "";
let settled = false;
const finish = (code, message = "") => {
  if (settled) return;
  settled = true;
  clearTimeout(timeout);
  if (message) process.stderr.write(`${message}\n`);
  socket.destroy();
  process.exit(code);
};

socket.setEncoding("utf8");
socket.on("connect", () => {
  socket.end(`${JSON.stringify({ version: 1, requestId, taskId, content })}\n`);
});
socket.on("data", (chunk) => {
  input += chunk;
  const newline = input.indexOf("\n");
  if (newline < 0) return;
  let response;
  try {
    response = JSON.parse(input.slice(0, newline));
  } catch {
    finish(1, "error: native OMP worker returned malformed receipt");
    return;
  }
  if (response?.requestId !== requestId || response?.taskId !== taskId) {
    finish(1, "error: native OMP worker returned a mismatched receipt");
    return;
  }
  if (response?.status === "ambiguous" && typeof response.session === "string" && response.session) {
    finish(255, `error: native OMP worker delivered the message but its receipt is ambiguous: ${response.reason || "receipt persistence failed"}; do not resend`);
    return;
  }
  if (response?.status !== "accepted" || typeof response.session !== "string" || !response.session) {
    finish(1, `error: native OMP worker refused the message: ${response?.reason || "no reason supplied"}`);
    return;
  }
  process.stdout.write(`native-queued request=${requestId} session=${response.session}\n`);
  finish(0);
});
socket.on("error", (error) => finish(1, `error: native OMP worker bridge unavailable: ${error.message}`));
socket.on("close", () => {
  if (!settled) finish(1, "error: native OMP worker closed the bridge without a receipt");
});
