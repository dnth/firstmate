#!/usr/bin/env node
// Read-only loopback OMP facade. RunPod remains unscoped; Boat sets providers
// and a distinct upstream token file. Scoped responses are rebuilt, never streamed raw.
import { timingSafeEqual } from 'node:crypto';
import { createServer } from 'node:http';
import { lstatSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Readable } from 'node:stream';
import { providers, vend } from './fm-boat-policy.mjs';

const tokenFile = process.env.FM_OMP_AUTH_BROKER_TOKEN_FILE;
const upstreamTokenFile = process.env.FM_OMP_AUTH_BROKER_UPSTREAM_TOKEN_FILE ?? tokenFile;
const scoped = process.env.FM_BOAT_PROVIDERS !== undefined;
const policy = providers();
const upstream = new URL(process.env.FM_OMP_AUTH_BROKER_UPSTREAM_URL ?? 'http://127.0.0.1:8765');
const bind = /^(127\.0\.0\.1|localhost):(\d+)$/u.exec(process.env.FM_OMP_AUTH_BROKER_PROXY_BIND ?? '127.0.0.1:18766');
if (upstream.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(upstream.hostname)) throw new Error('upstream must be loopback HTTP');
if (!bind || Number(bind[2]) < 1 || Number(bind[2]) > 65535) throw new Error('facade bind must be loopback');
const grammar = fileURLToPath(new URL('./fm-omp-auth-token-lib.sh', import.meta.url));
const cache = new Map();
function token(path) {
  if (!path) throw new Error('token file required');
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o777) !== 0o600 || stat.size > 514) throw new Error('unsafe token');
  const identity = `${stat.ino}:${stat.size}:${stat.mtimeMs}:${stat.ctimeMs}`;
  const prior = cache.get(path);
  if (prior?.identity === identity) return prior.value;
  const value = readFileSync(path, 'utf8').replace(/\r?\n$/u, '');
  if (spawnSync('bash', [grammar, '--validate-token'], { input: value }).status !== 0) throw new Error('invalid token');
  cache.set(path, { identity, value });
  return value;
}
token(tokenFile);
token(upstreamTokenFile);
function authorized(request) {
  try {
    const expected = Buffer.from(token(tokenFile));
    const supplied = Buffer.from((request.headers.authorization ?? '').replace(/^Bearer /u, ''));
    return request.headers.authorization?.startsWith('Bearer ') && expected.length === supplied.length && timingSafeEqual(expected, supplied);
  } catch { return false; }
}
function json(response, status, body, headers = {}) {
  response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-fm-auth-broker-facade': 'credential-read-only', ...headers });
  response.end(`${JSON.stringify(body)}\n`);
}
function envelope(input, stream = false) {
  if (!input || typeof input !== 'object' || !Number.isSafeInteger(input.generation) ||
      !Number.isFinite(input.serverNowMs) || !input.refresher) return null;
  const r = input.refresher;
  if (typeof r.enabled !== 'boolean' || ['intervalMs', 'skewMs', 'nextSweepInMs'].some(k => !Number.isFinite(r[k]))) return null;
  const out = { generation: input.generation, serverNowMs: input.serverNowMs,
    refresher: { enabled: r.enabled, intervalMs: r.intervalMs, skewMs: r.skewMs, nextSweepInMs: r.nextSweepInMs } };
  if (!stream || input.kind === 'snapshot') {
    if (!Number.isFinite(input.generatedAt)) return null;
    out.generatedAt = input.generatedAt;
  }
  return out;
}
function snapshot(input) {
  const out = envelope(input);
  if (!out || !Array.isArray(input.credentials)) return null;
  out.credentials = input.credentials.map(e => vend(e, policy)).filter(Boolean);
  return out;
}
async function fetchBroker(path, options = {}) {
  return fetch(new URL(path, upstream), { ...options, headers: { authorization: `Bearer ${token(upstreamTokenFile)}` }, signal: options.signal ?? AbortSignal.timeout(10000) });
}
async function stream(request, response, remote, controller) {
  response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store' });
  // Membership belongs to this reader, not to unrelated snapshots or clients.
  const members = new Set();
  const decoder = new TextDecoder();
  let pending = '';
  for await (const chunk of remote.body) {
    if (!authorized(request)) { controller.abort(); break; }
    pending += decoder.decode(chunk, { stream: true }).replace(/\r\n/gu, '\n');
    if (pending.length > 1048576) throw new Error('oversized broker frame');
    let end;
    while ((end = pending.indexOf('\n\n')) !== -1) {
      const frame = pending.slice(0, end); pending = pending.slice(end + 2);
      try {
        const data = frame.split('\n').filter(l => l.startsWith('data:')).map(l => l.slice(5).trimStart()).join('\n');
        if (!data) continue;
        const input = JSON.parse(data);
        const out = envelope(input, true);
        if (!out || !['snapshot', 'entry', 'removed'].includes(input.kind)) continue;
        out.kind = input.kind;
        if (input.kind === 'snapshot') {
          const body = snapshot(input); if (!body) continue;
          out.credentials = body.credentials; members.clear();
          for (const e of out.credentials) members.add(e.id);
        } else if (input.kind === 'entry') {
          out.entry = vend(input.entry, policy); if (!out.entry) continue;
          members.add(out.entry.id);
        } else {
          if (!Number.isSafeInteger(input.id) || !members.delete(input.id)) continue;
          out.id = input.id;
        }
        response.write(`data: ${JSON.stringify(out)}\n\n`);
      } catch { /* Unknown upstream frames never egress. */ }
    }
  }
  response.end();
}
const server = createServer(async (request, response) => {
  const url = new URL(request.url ?? '/', 'http://127.0.0.1');
  const health = request.method === 'GET' && url.pathname === '/v1/healthz';
  if (!health && !authorized(request)) return json(response, 401, { error: 'unauthorized' });
  const refresh = request.method === 'POST' && /^\/v1\/credential\/\d+\/refresh$/u.test(url.pathname);
  const read = request.method === 'GET' && ['/v1/snapshot', '/v1/snapshot/stream', '/v1/usage', '/v1/usage/history'].includes(url.pathname);
  if (!health && !refresh && !read) return json(response, 403, { error: 'credential mutation is disabled for remote clients' });
  const controller = new AbortController();
  response.once('close', () => controller.abort());
  try {
    if (scoped && refresh) {
      const upstreamSnapshot = await fetchBroker('/v1/snapshot');
      const body = upstreamSnapshot.ok ? snapshot(await upstreamSnapshot.json()) : null;
      const id = Number(url.pathname.split('/')[3]);
      if (!body?.credentials.some(e => e.id === id)) return json(response, 403, { error: 'credential is not vendable' });
    }
    const remote = await fetchBroker(`${url.pathname}${url.search}`, {
      method: request.method, signal: url.pathname.endsWith('/stream') ? controller.signal : AbortSignal.timeout(10000),
      body: request.method === 'POST' ? Readable.toWeb(request) : undefined, duplex: 'half',
    });
    if (scoped && !health) {
      if (!remote.ok) return json(response, 502, { error: 'broker refused request' });
      if (url.pathname.endsWith('/stream')) return await stream(request, response, remote, controller);
      const input = await remote.json();
      let body;
      if (refresh) {
        const out = envelope(input, true); const entry = vend(input.entry, policy);
        body = out && entry && String(entry.id) === url.pathname.split('/')[3] ? { ...out, entry } : null;
      } else if (url.pathname === '/v1/snapshot') body = snapshot(input);
      // Scoped usage has no credential-bearing passthrough; unsupported shapes refuse.
      if (!body) return json(response, 502, { error: 'unsupported broker response' });
      return json(response, 200, body);
    }
    const headers = {};
    for (const [key, value] of remote.headers) {
      if (!['connection', 'keep-alive', 'transfer-encoding'].includes(key)) headers[key] = value;
    }
    if (health) headers['x-fm-auth-broker-facade'] = 'credential-read-only';
    response.writeHead(remote.status, headers);
    if (remote.body) Readable.fromWeb(remote.body).pipe(response); else response.end();
  } catch {
    if (response.headersSent) response.destroy(); else json(response, 502, { error: 'canonical auth broker unavailable' });
  }
});
server.listen(Number(bind[2]), bind[1]);
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => server.close(() => process.exit(0)));
