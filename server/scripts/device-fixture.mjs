// Explicit local device fixture; not selected by node --test (*.test.js).
import { createApp } from '../src/server.js';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const env = Object.fromEntries(readFileSync('deploy/.secrets/server.env', 'utf8').trim().split('\n').map(s => s.split(/=(.*)/s).slice(0,2)));
const codes = new Map();
const dir = mkdtempSync(join(tmpdir(), 'aida-device-fixture-'));
const app = createApp({ dataDir: dir, secret: 'local-fixture-only-secret-at-least-32-chars',
  sendEmail: async (email, code) => codes.set(email, code),
  livekitUrl: env.LIVEKIT_PUBLIC_URL, livekitInternalUrl: 'http://127.0.0.1:17880',
  livekitKey: env.LIVEKIT_API_KEY, livekitSecret: env.LIVEKIT_API_SECRET });
await new Promise(r => app.server.listen(18990, '127.0.0.1', r));
const base = 'http://127.0.0.1:18990';
async function req(path, token, body, method = 'POST') {
  const response = await fetch(base + path, { method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined });
  const data = await response.json();
  if (!response.ok) throw new Error(data.message);
  return data;
}
async function login(email, name) {
  await req('/v1/auth/start', null, { email });
  const { token } = await req('/v1/auth/verify', null, { email, code: codes.get(email) });
  await req('/v1/me', token, { name }, 'PATCH');
  return token;
}
const alice = await login('fixture-a@example.test', 'Yash');
const bob = await login('fixture-b@example.test', 'Sofia');
const invite = await req('/v1/invites', alice);
const state = await req('/v1/invites/accept', bob, { code: invite.code });
const trip = await req('/v1/topics', alice, { name: 'Summer in Italy', pairId: state.pair.id });
await req('/v1/messages', bob, { text: 'Found the little café I told you about ☕', clientId: 'fixture-message-1' });
await req('/v1/messages', bob, { text: 'Saving you a seat for when you get here.', clientId: 'fixture-message-2' });
await req('/v1/messages', alice, { text: 'Already my favorite place. Just because you’re there.', clientId: 'fixture-message-3' });
writeFileSync('deploy/.secrets/device-fixture.json', JSON.stringify({ alice, bob, trip: trip.id, pairId: state.pair.id }), { mode: 0o600 });
console.log('Local synthetic two-person fixture ready on 127.0.0.1:18990');
async function stop() {
  try { await req('/v1/pair', alice, undefined, 'DELETE'); } catch {}
  await app.close(); rmSync(dir, { recursive: true, force: true }); process.exit(0);
}
process.on('SIGTERM', stop); process.on('SIGINT', stop);
