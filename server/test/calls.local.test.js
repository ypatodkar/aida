import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp } from '../src/server.js';

test('a paired caller can create, accept, join, and end a LiveKit room', {
  skip: !process.env.LIVEKIT_TEST_URL,
}, async t => {
  const dir = mkdtempSync(join(tmpdir(), 'aida-call-test-'));
  const codes = new Map();
  const app = createApp({
    dataDir: dir,
    secret: 'test-secret-with-at-least-thirty-two-characters',
    sendEmail: async (email, code) => codes.set(email, code),
    livekitUrl: process.env.LIVEKIT_TEST_URL,
    livekitInternalUrl: process.env.LIVEKIT_TEST_INTERNAL_URL ?? process.env.LIVEKIT_TEST_URL,
    livekitKey: process.env.LIVEKIT_API_KEY ?? 'devkey',
    livekitSecret: process.env.LIVEKIT_API_SECRET ?? 'secret',
  });
  await new Promise(resolve => app.server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
  });
  const base = `http://127.0.0.1:${app.server.address().port}`;
  async function request(path, token, method = 'GET', body) {
    const response = await fetch(base + path, {
      method,
      headers: {
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(body ? { 'content-type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: response.status, value: await response.json() };
  }
  async function login(email) {
    await request('/v1/auth/start', null, 'POST', { email });
    return (await request('/v1/auth/verify', null, 'POST',
      { email, code: codes.get(email) })).value.token;
  }
  const alice = await login('call-a@example.com');
  const bob = await login('call-b@example.com');
  const invite = await request('/v1/invites', alice, 'POST');
  assert.equal((await request('/v1/invites/accept', bob, 'POST',
    { code: invite.value.code })).status, 200);
  const call = await request('/v1/calls', alice, 'POST', { kind: 'video' });
  assert.equal(call.status, 201);
  assert.equal((await request(`/v1/calls/${call.value.id}/accept`, bob, 'POST')).status, 200);
  const joined = await request(`/v1/calls/${call.value.id}/join`, bob, 'POST');
  assert.equal(joined.status, 200);
  const claims = JSON.parse(Buffer.from(joined.value.token.split('.')[1], 'base64url'));
  assert.equal(claims.video.room, call.value.id);
  assert.equal(claims.video.roomJoin, true);
  assert.equal((await request(`/v1/calls/${call.value.id}/end`, alice, 'POST')).status, 200);
  assert.equal((await request('/v1/calls/current', bob)).value.call, null);
});
