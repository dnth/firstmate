#!/usr/bin/env node
// Boat launch admission and scoped facade egress share this exact policy.
import { readFileSync } from 'node:fs';
export function providers(value = process.env.FM_BOAT_PROVIDERS) {
  const parsed = value === undefined ? ['openai-codex'] : JSON.parse(value);
  if (!Array.isArray(parsed) || parsed.some(p => typeof p !== 'string' || !/^[a-z0-9][a-z0-9-]*$/u.test(p))) {
    throw new Error('Boat providers must be a JSON array of provider names');
  }
  return new Set(parsed);
}
export function vend(entry, policy) {
  if (!entry || !policy.has(entry.provider) || !Number.isSafeInteger(entry.id) || entry.id < 0 ||
      entry.credential?.type !== 'oauth' || typeof entry.credential.access !== 'string' || !entry.credential.access ||
      !Number.isFinite(entry.credential.expires)) return null;
  return { provider: entry.provider, id: entry.id, identityKey: null, rotatesInMs: null,
    credential: { type: 'oauth', access: entry.credential.access, refresh: '__remote__', expires: entry.credential.expires } };
}
if (process.argv[2] === '--model') {
  try {
    const policy = providers(process.argv[4] === undefined ? undefined : readFileSync(process.argv[4], 'utf8'));
    const match = /^([^/]+)\/(.+)$/u.exec(process.argv[3] ?? '');
    if (!match || !policy.has(match[1])) throw new Error('model is outside the Boat provider allowlist');
    process.stdout.write(`${JSON.stringify([...policy])}\n`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
