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

const socket = net.createConnection(socketPath);
let input = "";
let settled = false;
let requestWritten = false;
const finish = (code, message = "") => {
  if (settled) return;
  settled = true;
  clearTimeout(timeout);
  if (message) process.stderr.write(`${message}\n`);
  socket.destroy();
  process.exit(code);
};
const finishAmbiguous = (reason) => finish(
  255,
  `error: native OMP worker delivery is ambiguous after request write: ${reason}; do not resend`,
);
const requestId = randomUUID();
const timeout = setTimeout(() => {
  if (requestWritten) {
    finishAmbiguous(`receipt timed out (request=${requestId})`);
  } else {
    finish(1, `error: native OMP worker receipt timed out before request write (request=${requestId})`);
  }
}, 3000);
timeout.unref();

socket.setEncoding("utf8");
socket.on("connect", () => {
  try {
    requestWritten = true;
    socket.end(`${JSON.stringify({ version: 1, requestId, taskId, content })}\n`);
  } catch (error) {
    requestWritten = false;
    finish(1, `error: native OMP worker request could not be written: ${error.message}`);
  }
});
socket.on("data", (chunk) => {
  input += chunk;
  const newline = input.indexOf("\n");
  if (newline < 0) return;
  let response;
  try {
    response = JSON.parse(input.slice(0, newline));
  } catch {
    finishAmbiguous("malformed receipt");
    return;
  }
  if (response?.requestId !== requestId || response?.taskId !== taskId) {
    finishAmbiguous("mismatched receipt");
    return;
  }
  if (response?.status === "ambiguous" && typeof response.session === "string" && response.session) {
    finish(255, `error: native OMP worker delivered the message but its receipt is ambiguous: ${response.reason || "receipt persistence failed"}; do not resend`);
    return;
  }
  if (response?.status === "refused") {
    finish(1, `error: native OMP worker refused the message: ${response?.reason || "no reason supplied"}`);
    return;
  }
  if (response?.status === "ambiguous") {
    finishAmbiguous("malformed ambiguous receipt");
    return;
  }
  if (response?.status !== "accepted" || typeof response.session !== "string" || !response.session) {
    finishAmbiguous("malformed receipt");
    return;
  }
  process.stdout.write(`native-queued request=${requestId} session=${response.session}\n`);
  finish(0);
});
socket.on("error", (error) => finish(1, `error: native OMP worker bridge unavailable: ${error.message}`));
socket.on("close", () => {
  if (!settled) {
    if (requestWritten) finishAmbiguous("bridge closed without a receipt");
    else finish(1, "error: native OMP worker closed the bridge before request write");
  }
});
