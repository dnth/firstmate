#!/usr/bin/env node
// Credential-read-only facade for a workstation-local omp auth broker.
//
// Usage:
//   FM_OMP_AUTH_BROKER_TOKEN_FILE=<mode-600-file> \
//   FM_OMP_AUTH_BROKER_UPSTREAM_URL=http://127.0.0.1:8765 \
//   FM_OMP_AUTH_BROKER_PROXY_BIND=127.0.0.1:18766 \
//     fm-omp-auth-broker-readonly-proxy.mjs
//
// The pod receives the broker bearer but can reach only this loopback facade
// through its SSH reverse tunnel.
// The facade admits snapshots, usage reads, and server-side OAuth refreshes.
// It rejects every credential mutation endpoint, so login, logout, import,
// migrate, upload, replacement, and disable requests never reach the canonical
// workstation broker.
// The refresh endpoint remains allowed because the workstation broker performs
// that refresh and keeps the refresh token; the pod receives only the redacted
// snapshot returned by omp's broker protocol.

import { timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { lstat, readFile } from "node:fs/promises";
import { Readable } from "node:stream";

const tokenFile = process.env.FM_OMP_AUTH_BROKER_TOKEN_FILE;
const upstreamUrl = process.env.FM_OMP_AUTH_BROKER_UPSTREAM_URL ?? "http://127.0.0.1:8765";
const bind = process.env.FM_OMP_AUTH_BROKER_PROXY_BIND ?? "127.0.0.1:18766";

if (!tokenFile) throw new Error("FM_OMP_AUTH_BROKER_TOKEN_FILE is required");

const tokenStat = await lstat(tokenFile);
if (!tokenStat.isFile() || tokenStat.isSymbolicLink()) {
  throw new Error("the auth-broker token path must be a regular file, not a symlink");
}
if ((tokenStat.mode & 0o777) !== 0o600) {
  throw new Error("the auth-broker token file must have mode 0600");
}

const token = (await readFile(tokenFile, "utf8")).trim();
if (!token || token.length > 512 || /[^A-Za-z0-9_-]/u.test(token)) {
  throw new Error("the auth-broker token file does not contain one valid bearer token");
}

const upstream = new URL(upstreamUrl);
if (upstream.protocol !== "http:" || !["127.0.0.1", "localhost", "::1"].includes(upstream.hostname)) {
  throw new Error("the canonical auth broker must be a workstation-loopback HTTP endpoint");
}

const bindMatch = /^([^:]+):(\d+)$/u.exec(bind);
if (!bindMatch) throw new Error("FM_OMP_AUTH_BROKER_PROXY_BIND must be host:port");
const [, bindHost, bindPortText] = bindMatch;
const bindPort = Number.parseInt(bindPortText, 10);
if (!["127.0.0.1", "localhost", "::1"].includes(bindHost) || bindPort < 1 || bindPort > 65535) {
  throw new Error("the read-only auth-broker facade must bind to a valid loopback port");
}

const hopByHopHeaders = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

function authorized(request) {
  const header = request.headers.authorization ?? "";
  const supplied = header.startsWith("Bearer ") ? header.slice(7) : "";
  const expectedBuffer = Buffer.from(token);
  const suppliedBuffer = Buffer.from(supplied);
  return suppliedBuffer.length === expectedBuffer.length && timingSafeEqual(suppliedBuffer, expectedBuffer);
}

function allowed(method, pathname) {
  if (method === "GET" && ["/v1/snapshot", "/v1/snapshot/stream", "/v1/usage", "/v1/usage/history"].includes(pathname)) {
    return true;
  }
  return method === "POST" && /^\/v1\/credential\/\d+\/refresh$/u.test(pathname);
}

function writeJson(response, status, body) {
  const payload = Buffer.from(`${JSON.stringify(body)}\n`);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": String(payload.length),
    "cache-control": "no-store",
  });
  response.end(payload);
}

const server = createServer(async (request, response) => {
  const requestUrl = new URL(request.url ?? "/", "http://127.0.0.1");
  const isHealthz = request.method === "GET" && requestUrl.pathname === "/v1/healthz";
  if (!isHealthz && !authorized(request)) {
    writeJson(response, 401, { error: "unauthorized" });
    return;
  }
  if (!isHealthz && !allowed(request.method ?? "", requestUrl.pathname)) {
    writeJson(response, 403, { error: "credential mutation is disabled for remote clients" });
    return;
  }

  try {
    const target = new URL(`${requestUrl.pathname}${requestUrl.search}`, upstream);
    const headers = new Headers();
    for (const [name, value] of Object.entries(request.headers)) {
      if (value === undefined || hopByHopHeaders.has(name.toLowerCase()) || name.toLowerCase() === "host") continue;
      headers.set(name, Array.isArray(value) ? value.join(", ") : value);
    }
    const hasBody = request.method !== "GET" && request.method !== "HEAD";
    const upstreamResponse = await fetch(target, {
      method: request.method,
      headers,
      body: hasBody ? Readable.toWeb(request) : undefined,
      duplex: hasBody ? "half" : undefined,
    });
    const responseHeaders = {};
    for (const [name, value] of upstreamResponse.headers) {
      if (!hopByHopHeaders.has(name.toLowerCase())) responseHeaders[name] = value;
    }
    // OMP validates the canonical health body strictly, so facade identity belongs only in a response header.
    if (isHealthz) responseHeaders["x-fm-auth-broker-facade"] = "credential-read-only";
    response.writeHead(upstreamResponse.status, responseHeaders);
    if (upstreamResponse.body) Readable.fromWeb(upstreamResponse.body).pipe(response);
    else response.end();
  } catch {
    writeJson(response, 502, { error: "canonical auth broker unavailable" });
  }
});

server.listen(bindPort, bindHost, () => {
  process.stdout.write(`omp auth-broker read-only facade listening on http://${bindHost}:${bindPort}\n`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => server.close(() => process.exit(0)));
}
