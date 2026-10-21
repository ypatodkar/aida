import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { WebSocket } from 'ws';
import { createApp } from '../src/server.js';

async function fixture(t, options = {}) {
  const dataDir = mkdtempSync(join(tmpdir(), 'aida-test-'));
  const codes = new Map();
  const app = createApp({
    dataDir,
    secret: 'test-secret-with-at-least-thirty-two-characters',
    sendEmail: async (email, code) => codes.set(email, code),
    verifyGoogleIdToken: options.verifyGoogleIdToken,
    sendPush: options.sendPush,
    presenceTtl: options.presenceTtl,
    typingTtl: options.typingTtl,
    activityInterval: options.activityInterval,
  });
  await new Promise(resolve => app.server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${app.server.address().port}`;
  t.after(async () => {
    await app.close();
    rmSync(dataDir, { recursive: true, force: true });
  });
  async function request(path, { method = 'GET', token, body, headers = {} } = {}) {
    const response = await fetch(base + path, {
      method,
      headers: {
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(body && !(body instanceof Uint8Array) ? { 'content-type': 'application/json' } : {}),
        ...headers,
      },
      body: body instanceof Uint8Array ? body : body ? JSON.stringify(body) : undefined,
    });
    const contentType = response.headers.get('content-type') ?? '';
    const value = contentType.includes('json') ? await response.json() : new Uint8Array(await response.arrayBuffer());
    return { status: response.status, value };
  }
  async function login(email) {
    assert.equal((await request('/v1/auth/start', { method: 'POST', body: { email } })).status, 200);
    const result = await request('/v1/auth/verify', {
      method: 'POST', body: { email, code: codes.get(email) },
    });
    assert.equal(result.status, 200);
    return result.value.token;
  }
  return { base, request, login, codes, dataDir };
}

test('Google sign-in requires a verified account and links by stable subject', async t => {
  const token = 'a'.repeat(120);
  let identity = { sub: 'google-subject-123', email: 'google@example.com',
    email_verified: true, name: 'Google User' };
  const { request } = await fixture(t, {
    verifyGoogleIdToken: async value => {
      if (value !== token) throw new Error('bad token');
      return identity;
    },
  });
  const login = () => request('/v1/auth/google', { method: 'POST', body: { idToken: token } });
  assert.equal((await request('/v1/auth/google', {
    method: 'POST', body: { idToken: 'invalid' },
  })).status, 400);
  identity = { ...identity, email_verified: false };
  assert.equal((await login()).status, 401);
  identity = { ...identity, email_verified: true };
  const first = await login();
  assert.equal(first.status, 200);
  const second = await login();
  assert.equal(second.value.user.id, first.value.user.id);
  identity = { ...identity, sub: 'different-google-subject' };
  assert.equal((await login()).status, 409);
});

test('exclusive pairing, messaging, media, and disconnect deletion', async t => {
  const { request, login, dataDir } = await fixture(t);
  const alice = await login('alice@example.com');
  const bob = await login('bob@example.com');
  const third = await login('third@example.com');
  const invite = await request('/v1/invites', { method: 'POST', token: alice });
  assert.equal(invite.status, 201);
  const accepted = await request('/v1/invites/accept', {
    method: 'POST', token: bob, body: { code: invite.value.code },
  });
  assert.equal(accepted.status, 200);
  assert.equal(accepted.value.pair.partner.name, 'alice');
  const pairId = accepted.value.pair.id;
  assert.equal((await request('/v1/invites', { method: 'POST', token: alice })).status, 409);
  assert.equal((await request('/v1/messages', { token: third })).status, 409);

  const sent = await request('/v1/messages', {
    method: 'POST', token: alice, body: { text: 'hello', clientId: 'message_123' },
  });
  assert.equal(sent.status, 201);
  const replay = await request('/v1/messages', {
    method: 'POST', token: alice, body: { text: 'hello', clientId: 'message_123' },
  });
  assert.equal(replay.value.id, sent.value.id);
  const upload = await request('/v1/media', {
    method: 'POST', token: bob, body: new Uint8Array([1, 2, 3, 4]),
    headers: { 'content-type': 'image/png', 'x-file-name': 'photo.png' },
  });
  assert.equal(upload.status, 201);
  const mediaId = upload.value.mediaId;
  assert.deepEqual((await request(`/v1/media/${mediaId}`, { token: alice })).value,
    new Uint8Array([1, 2, 3, 4]));
  assert.equal((await request(`/v1/media/${mediaId}`, { token: third })).status, 409);
  assert.equal((await request('/v1/messages', { token: bob })).value.messages.length, 2);

  assert.equal((await request('/v1/pair', { method: 'DELETE', token: alice })).status, 200);
  const db = new DatabaseSync(join(dataDir, 'aida.sqlite'));
  assert.equal(db.prepare('SELECT COUNT(*) AS count FROM pairs WHERE id = ?').get(pairId).count, 0);
  assert.equal(db.prepare('SELECT COUNT(*) AS count FROM messages WHERE pair_id = ?').get(pairId).count, 0);
  assert.equal(db.prepare('SELECT COUNT(*) AS count FROM media WHERE pair_id = ?').get(pairId).count, 0);
  db.close();
  assert.equal(existsSync(join(dataDir, 'media', pairId)), false);
  assert.equal((await request('/v1/messages', { token: bob })).status, 409);
  assert.equal((await request(`/v1/media/${mediaId}`, { token: bob })).status, 409);
  assert.equal((await request('/v1/me', { token: bob })).value.pair, null);
  const again = await request('/v1/invites', { method: 'POST', token: bob });
  assert.equal((await request('/v1/invites/accept', {
    method: 'POST', token: alice, body: { code: again.value.code },
  })).status, 200);
  assert.deepEqual((await request('/v1/messages', { token: alice })).value.messages, []);
});

test('simultaneous invite acceptance creates only one pair', async t => {
  const { request, login } = await fixture(t);
  const owner = await login('owner@example.com');
  const a = await login('a@example.com');
  const b = await login('b@example.com');
  const invite = await request('/v1/invites', { method: 'POST', token: owner });
  const results = await Promise.all([a, b].map(token => request('/v1/invites/accept', {
    method: 'POST', token, body: { code: invite.value.code },
  })));
  assert.deepEqual(results.map(r => r.status).sort(), [200, 404]);
  const paired = await Promise.all([a, b].map(token => request('/v1/me', { token })));
  assert.equal(paired.filter(r => r.value.pair).length, 1);
});

test('live socket receives message changes', async t => {
  const { base, request, login } = await fixture(t);
  const a = await login('socket-a@example.com');
  const b = await login('socket-b@example.com');
  const invite = await request('/v1/invites', { method: 'POST', token: a });
  await request('/v1/invites/accept', { method: 'POST', token: b, body: { code: invite.value.code } });
  const ws = new WebSocket(base.replace('http', 'ws') + '/v1/live', {
    headers: { authorization: `Bearer ${b}` },
  });
  t.after(() => ws.close());
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  const event = new Promise(resolve => {
    ws.on('message', raw => {
      const message = JSON.parse(raw.toString());
      if (message.type === 'messages_changed') resolve(message);
    });
  });
  await request('/v1/messages', {
    method: 'POST', token: a, body: { text: 'ping', clientId: 'socket_msg_1' },
  });
  assert.equal((await event).type, 'messages_changed');
});

test('wrong email codes are limited', async t => {
  const { request } = await fixture(t);
  await request('/v1/auth/start', { method: 'POST', body: { email: 'wrong@example.com' } });
  for (let attempt = 0; attempt < 5; attempt++) {
    assert.equal((await request('/v1/auth/verify', {
      method: 'POST', body: { email: 'wrong@example.com', code: '000000' },
    })).status, 401);
  }
  assert.equal((await request('/v1/auth/verify', {
    method: 'POST', body: { email: 'wrong@example.com', code: '000000' },
  })).status, 401);
});


test('shared topics isolate messages and media; old notification replies cannot cross pair boundaries', async t => {
  const f = await fixture(t);
  const alice = await f.login('topics-a@example.com');
  const bob = await f.login('topics-b@example.com');
  const eve = await f.login('topics-e@example.com');
  const invite = (await f.request('/v1/invites', { method: 'POST', token: alice })).value;
  const paired = await f.request('/v1/invites/accept', { method: 'POST', token: bob, body: { code: invite.code } });
  const pairId = paired.value.pair.id;
  const topic = await f.request('/v1/topics', { method: 'POST', token: alice, body: { name: 'Trip', pairId } });
  assert.equal(topic.status, 201);
  assert.equal((await f.request('/v1/topics', { token: bob })).value.topics[1].name, 'Trip');
  assert.equal((await f.request('/v1/topics', { token: eve })).status, 409);
  assert.equal((await f.request('/v1/topics', { method: 'POST', token: bob, body: { name: 'trip' } })).status, 409);
  const everyday = await f.request('/v1/messages', { method: 'POST', token: alice,
    body: { text: 'Old clients keep working', clientId: 'everyday-123' } });
  assert.equal(everyday.value.topicId, 'general');
  const trip = await f.request('/v1/messages', { method: 'POST', token: bob,
    body: { text: 'Book the tickets', clientId: 'trip-msg-123', topicId: topic.value.id, pairId } });
  assert.equal(trip.status, 201);
  const upload = await f.request('/v1/media', { method: 'POST', token: alice, body: new Uint8Array([1,2,3]),
    headers: { 'content-type': 'image/png', 'x-topic-id': topic.value.id, 'x-pair-id': pairId } });
  assert.equal(upload.status, 201);
  assert.equal(upload.value.topicId, topic.value.id);
  assert.equal((await f.request('/v1/messages?topicId=general', { token: alice })).value.messages.length, 1);
  assert.equal((await f.request('/v1/messages?topicId='+topic.value.id, { token: alice })).value.messages.length, 2);
  assert.equal((await f.request('/v1/messages?topicId=not-a-topic', { token: bob })).status, 404);
  assert.equal((await f.request('/v1/messages/'+trip.value.id, { token: alice })).value.topicName, 'Trip');
  assert.equal((await f.request('/v1/messages', { method: 'POST', token: bob,
    body: { text: 'wrong topic', clientId: 'trip-msg-123', topicId: 'general', pairId } })).status, 409);
  await f.request('/v1/pair', { method: 'DELETE', token: alice });
  const nextInvite = (await f.request('/v1/invites', { method: 'POST', token: alice })).value;
  await f.request('/v1/invites/accept', { method: 'POST', token: eve, body: { code: nextInvite.code } });
  assert.equal((await f.request('/v1/messages', { method: 'POST', token: alice,
    body: { text: 'stale reply', clientId: 'stale-reply-123', pairId, topicId: 'general' } })).status, 409);
  assert.equal((await f.request('/v1/messages/'+trip.value.id, { token: alice })).status, 404);
  assert.equal((await f.request('/v1/topics', { token: alice })).value.topics.length, 1);
  const db = new DatabaseSync(join(f.dataDir, 'aida.sqlite'));
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM topics WHERE pair_id = ?').get(pairId).n, 0);
  db.close();
});

test('notifications target the recipient device, contain no message text, and stop after sign-out', async t => {
  const deliveries = [];
  const f = await fixture(t, { sendPush: async (token, data) => { deliveries.push({token,data}); return true; } });
  const alice = await f.login('push-a@example.com');
  const bob = await f.login('push-b@example.com');
  const device = 'test-notification-device-token-123456789';
  assert.equal((await f.request('/v1/devices', { method: 'POST', token: bob, body: { token: device } })).value.enabled, true);
  const invite = (await f.request('/v1/invites', { method: 'POST', token: alice })).value;
  await f.request('/v1/invites/accept', { method: 'POST', token: bob, body: { code: invite.code } });
  const sent = await f.request('/v1/messages', { method: 'POST', token: alice,
    body: { text: 'Private message', clientId: 'push-message-123' } });
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(deliveries.length, 1);
  assert.equal(deliveries[0].token, device);
  assert.equal(deliveries[0].data.messageId, String(sent.value.id));
  assert.equal(JSON.stringify(deliveries[0]).includes('Private message'), false);
  await f.request('/v1/auth/signout', { method: 'POST', token: bob });
  await f.request('/v1/messages', { method: 'POST', token: alice,
    body: { text: 'No notification after signout', clientId: 'push-message-456' } });
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(deliveries.length, 1);
});

async function liveClient(base, token) {
  const ws = new WebSocket(base.replace('http', 'ws') + '/v1/live', {
    headers: { authorization: `Bearer ${token}` },
  });
  const events = [];
  ws.on('message', raw => events.push(JSON.parse(raw)));
  await new Promise((resolve, reject) => { ws.once('open', resolve); ws.once('error', reject); });
  return {
    ws, events,
    send: event => ws.send(JSON.stringify(event)),
    async take(predicate) {
      const deadline = Date.now() + 3500;
      while (Date.now() < deadline) {
        const index = events.findIndex(predicate);
        if (index >= 0) return events.splice(index, 1)[0];
        await new Promise(resolve => setTimeout(resolve, 10));
      }
      assert.fail('Expected live event did not arrive');
    },
  };
}

test('typing is ephemeral, scoped to the pair/topic, and presence aggregates foreground devices', async t => {
  const f = await fixture(t, { presenceTtl: 1800, typingTtl: 200, activityInterval: 20 });
  const a = await f.login('live-a@example.com');
  const b = await f.login('live-b@example.com');
  const outsider = await f.login('live-e@example.com');
  const invite = (await f.request('/v1/invites', { method: 'POST', token: a })).value;
  const pairId = (await f.request('/v1/invites/accept', { method: 'POST', token: b, body: { code: invite.code } })).value.pair.id;
  const trip = (await f.request('/v1/topics', { method: 'POST', token: a, body: { pairId, name: 'Trip' } })).value.id;
  const [first, second, partner, stranger] = await Promise.all([a, a, b, outsider].map(token => liveClient(f.base, token)));
  try {
    first.send({ type: 'presence', active: true });
    await partner.take(e => e.type === 'presence' && e.online);
    assert.equal((await f.request('/v1/me', { token: b })).value.pair.partner.online, true);
    second.send({ type: 'presence', active: true });
    first.send({ type: 'typing', pairId, topicId: trip, typing: true, userId: 'spoofed-user' });
    const typing = await partner.take(e => e.type === 'typing' && e.typing);
    assert.equal(typing.topicId, trip);
    assert.notEqual(typing.userId, 'spoofed-user');
    await partner.take(e => e.type === 'typing' && !e.typing); // expires even with an open socket
    first.send({ type: 'typing', pairId, topicId: 'general', typing: true });
    await partner.take(e => e.type === 'typing' && e.typing);
    first.send({ type: 'presence', active: false });
    await partner.take(e => e.type === 'typing' && !e.typing);
    assert.equal((await f.request('/v1/me', { token: b })).value.pair.partner.online, true);
    second.ws.close();
    const offline = await partner.take(e => e.type === 'presence' && !e.online);
    assert.ok(offline.lastSeenAt > 0);
    assert.equal((await f.request('/v1/me', { token: b })).value.pair.partner.online, false);
    first.send({ type: 'presence', active: true });
    await partner.take(e => e.type === 'presence' && e.online);
    await partner.take(e => e.type === 'presence' && !e.online); // foreground heartbeat lease expires
    first.send({ type: 'typing', pairId: 'old-pair', topicId: 'general', typing: true });
    first.send({ type: 'typing', pairId, topicId: 'not-a-topic', typing: true });
    first.send({ type: 'presence', active: true });
    await partner.take(e => e.type === 'presence' && e.online); // barrier after invalid events
    assert.equal(partner.events.some(e => e.type === 'typing' && e.typing), false);
    assert.equal(stranger.events.some(e => ['presence', 'typing'].includes(e.type)), false);
    await f.request('/v1/pair', { method: 'DELETE', token: a });
    first.send({ type: 'typing', pairId, topicId: 'general', typing: true });
    await partner.take(e => e.type === 'pair_changed');
    assert.equal(partner.events.some(e => e.type === 'typing' && e.typing), false);
  } finally {
    for (const client of [first, second, partner, stranger]) client.ws.terminate();
  }
});

test('delivery and read receipts advance independently, survive reconnects, and cannot cross topics or connections', async t => {
  const f = await fixture(t);
  const a = await f.login('receipt-a@example.com');
  const b = await f.login('receipt-b@example.com');
  const outsider = await f.login('receipt-e@example.com');
  const invite = (await f.request('/v1/invites', { method: 'POST', token: a })).value;
  const pairId = (await f.request('/v1/invites/accept', { method: 'POST', token: b, body: { code: invite.code } })).value.pair.id;
  const trip = (await f.request('/v1/topics', { method: 'POST', token: a, body: { pairId, name: 'Trip' } })).value.id;
  const send = async (topicId, clientId) => (await f.request('/v1/messages', { method: 'POST', token: a,
    body: { pairId, topicId, clientId, text: 'Receipt test' } })).value.id;
  const firstId = await send('general', 'receipt-first');
  const tripId = await send(trip, 'receipt-trip');
  const secondId = await send('general', 'receipt-second');
  const ack = (token, body) => f.request('/v1/receipts', { method: 'POST', token, body: { pairId, topicId: 'general', ...body } });
  const receipts = async (topicId = 'general') => (await f.request(`/v1/messages?after=${secondId}&topicId=${topicId}`, { token: a })).value.partnerReceipt;
  const live = await liveClient(f.base, a);
  try {
    // Fetching messages alone (e.g. background activity) must never mark them as read.
    await f.request('/v1/messages', { token: b });
    assert.deepEqual(await receipts(), { deliveredThrough: 0, readThrough: 0 });
    assert.equal((await ack(b, { deliveredThrough: secondId })).status, 200);
    const delivered = await live.take(e => e.type === 'receipts_changed');
    assert.equal(delivered.deliveredThrough, secondId);
    assert.equal(delivered.readThrough, 0);
    assert.equal((await ack(b, { deliveredThrough: firstId, readThrough: firstId })).status, 200);
    assert.deepEqual(await receipts(), { deliveredThrough: secondId, readThrough: firstId });
    await ack(b, { deliveredThrough: 0, readThrough: 0 });
    assert.deepEqual(await receipts(), { deliveredThrough: secondId, readThrough: firstId });
    assert.deepEqual(await receipts(trip), { deliveredThrough: 0, readThrough: 0 });
    assert.equal((await ack(b, { deliveredThrough: tripId })).status, 400);
    assert.equal((await ack(b, { readThrough: secondId + 999 })).status, 400);
    assert.equal((await ack(b, { readThrough: 1.5 })).status, 400);
    assert.equal((await ack(outsider, { readThrough: secondId })).status, 409);
    await ack(a, { readThrough: secondId });
    assert.equal((await receipts()).readThrough, firstId); // sender cannot acknowledge for recipient
    await ack(b, { readThrough: secondId });
    assert.deepEqual(await receipts(), { deliveredThrough: secondId, readThrough: secondId });
    live.ws.close();
    const reconnected = await liveClient(f.base, a);
    assert.deepEqual(await receipts(), { deliveredThrough: secondId, readThrough: secondId });
    reconnected.ws.terminate();
    await f.request('/v1/pair', { method: 'DELETE', token: a });
    const db = new DatabaseSync(join(f.dataDir, 'aida.sqlite'));
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM receipts').get().n, 0);
    db.close();
    const nextInvite = (await f.request('/v1/invites', { method: 'POST', token: a })).value;
    await f.request('/v1/invites/accept', { method: 'POST', token: b, body: { code: nextInvite.code } });
    assert.equal((await ack(b, { readThrough: secondId })).status, 409);
    assert.deepEqual(await receipts(), { deliveredThrough: 0, readThrough: 0 });
  } finally { live.ws.terminate(); }
});

test('replies quote a message from the same topic and connection', async t => {
  const f = await fixture(t);
  const alice = await f.login('reply-a@example.com');
  const bob = await f.login('reply-b@example.com');
  const invite = (await f.request('/v1/invites', { method: 'POST', token: alice })).value;
  const pairId = (await f.request('/v1/invites/accept', { method: 'POST', token: bob,
    body: { code: invite.code } })).value.pair.id;
  const topic = (await f.request('/v1/topics', { method: 'POST', token: alice,
    body: { name: 'Plans', pairId } })).value;
  const original = (await f.request('/v1/messages', { method: 'POST', token: alice,
    body: { text: 'Dinner at eight?', clientId: 'reply-original-1', pairId } })).value;
  const photo = (await f.request('/v1/media', { method: 'POST', token: alice, body: new Uint8Array([1, 2, 3]),
    headers: { 'content-type': 'image/png', 'x-pair-id': pairId } })).value;

  const reply = await f.request('/v1/messages', { method: 'POST', token: bob,
    body: { text: 'Perfect', clientId: 'reply-answer-1', pairId, replyToId: original.id } });
  assert.equal(reply.status, 201);
  assert.equal(reply.value.replyToId, original.id);
  assert.deepEqual(reply.value.replyTo,
    { id: original.id, senderId: original.senderId, kind: 'text', text: 'Dinner at eight?' });

  // Replies survive listing, single fetch, and idempotent resend.
  const listed = (await f.request('/v1/messages?topicId=general', { token: alice })).value.messages;
  assert.equal(listed.at(-1).replyTo.text, 'Dinner at eight?');
  assert.equal(listed[0].replyToId, null);
  assert.equal((await f.request('/v1/messages/' + reply.value.id, { token: alice })).value.replyTo.id, original.id);
  const resent = await f.request('/v1/messages', { method: 'POST', token: bob,
    body: { text: 'Perfect', clientId: 'reply-answer-1', pairId, replyToId: original.id } });
  assert.equal(resent.status, 200);
  assert.equal(resent.value.replyTo.id, original.id);

  // A photo can be quoted, and a photo can be the reply.
  const toPhoto = await f.request('/v1/messages', { method: 'POST', token: bob,
    body: { text: 'Love this', clientId: 'reply-photo-1', pairId, replyToId: photo.id } });
  assert.deepEqual(toPhoto.value.replyTo, { id: photo.id, senderId: photo.senderId, kind: 'image', text: null });
  const photoReply = await f.request('/v1/media', { method: 'POST', token: bob, body: new Uint8Array([4, 5]),
    headers: { 'content-type': 'image/png', 'x-pair-id': pairId, 'x-reply-to-id': String(original.id) } });
  assert.equal(photoReply.status, 201);
  assert.equal(photoReply.value.replyTo.id, original.id);

  // Long quotes are trimmed for the bubble; the original is unchanged.
  const long = (await f.request('/v1/messages', { method: 'POST', token: alice,
    body: { text: 'x'.repeat(1000), clientId: 'reply-long-1', pairId } })).value;
  const quoted = await f.request('/v1/messages', { method: 'POST', token: bob,
    body: { text: 'ok', clientId: 'reply-long-2', pairId, replyToId: long.id } });
  assert.equal(quoted.value.replyTo.text.length, 280);

  // Cannot quote across topics, connections, or nonexistent messages.
  for (const replyToId of [999999, 'abc', -1, 1.5]) {
    assert.equal((await f.request('/v1/messages', { method: 'POST', token: bob,
      body: { text: 'nope', clientId: `reply-bad-${String(replyToId).replace(/\W/g, '')}`, pairId, replyToId } })).status, 400);
  }
  assert.equal((await f.request('/v1/messages', { method: 'POST', token: bob,
    body: { text: 'wrong topic', clientId: 'reply-cross-1', pairId, topicId: topic.id, replyToId: original.id } })).status, 400);
  assert.equal((await f.request('/v1/media', { method: 'POST', token: bob, body: new Uint8Array([6]),
    headers: { 'content-type': 'image/png', 'x-pair-id': pairId, 'x-topic-id': topic.id,
      'x-reply-to-id': String(original.id) } })).status, 400);

  await f.request('/v1/pair', { method: 'DELETE', token: alice });
  const eve = await f.login('reply-e@example.com');
  const next = (await f.request('/v1/invites', { method: 'POST', token: alice })).value;
  const newPair = (await f.request('/v1/invites/accept', { method: 'POST', token: eve,
    body: { code: next.code } })).value.pair.id;
  assert.equal((await f.request('/v1/messages', { method: 'POST', token: eve,
    body: { text: 'old quote', clientId: 'reply-old-pair', pairId: newPair, replyToId: original.id } })).status, 400);
});

test('reactions, edits, deletions, and Moments keeps sync through the change feed', async t => {
  const pushed = [];
  const f = await fixture(t, { sendPush: async (token, data) => { pushed.push(data); return true; } });
  const alice = await f.login('actions-a@example.com');
  const bob = await f.login('actions-b@example.com');
  const invite = (await f.request('/v1/invites', { method: 'POST', token: alice })).value;
  const paired = await f.request('/v1/invites/accept', { method: 'POST', token: bob, body: { code: invite.code } });
  const pairId = paired.value.pair.id;
  const bobId = (await f.request('/v1/me', { token: bob })).value.user.id;
  const aliceId = (await f.request('/v1/me', { token: alice })).value.user.id;
  await f.request('/v1/devices', { method: 'POST', token: alice, body: { token: 'alice-device-token-123456789' } });
  const post = (token, text, clientId) => f.request('/v1/messages', { method: 'POST', token,
    body: { text, clientId, pairId } }).then(r => r.value);
  const hello = await post(alice, 'Hello there', 'actions-hello-1');
  const photo = (await f.request('/v1/media', { method: 'POST', token: alice, body: new Uint8Array([1, 2, 3]),
    headers: { 'content-type': 'image/png', 'x-pair-id': pairId } })).value;
  const first = await f.request('/v1/messages?topicId=general', { token: bob });
  const seq = first.value.changeSeq;
  assert.equal(typeof seq, 'number');
  assert.deepEqual(first.value.messages[0].reactions, []);
  assert.equal(first.value.messages[0].kept, false);
  assert.equal(first.value.messages[0].deleted, false);

  // Reactions: one per person, replaceable, removable, from an allow-list.
  const react = (token, id, emoji) => f.request(`/v1/messages/${id}/reaction`, { method: 'PUT', token, body: { emoji } });
  assert.equal((await react(bob, hello.id, '❤️')).status, 200);
  assert.equal((await react(bob, hello.id, '😂')).status, 200);
  assert.equal((await react(bob, hello.id, '<script>')).status, 400);
  const reacted = (await react(alice, hello.id, '👍')).value;
  assert.deepEqual(reacted.reactions.map(r => [r.userId, r.emoji]).sort(),
    [[aliceId, '👍'], [bobId, '😂']].sort());
  assert.equal((await f.request(`/v1/messages/${hello.id}/reaction`, { method: 'DELETE', token: alice })).status, 200);
  await new Promise(resolve => setTimeout(resolve, 2300));
  assert.ok(pushed.some(p => p.type === 'reaction' && p.messageId === String(hello.id)),
    'the author is told about a reaction');
  assert.ok(pushed.every(p => !JSON.stringify(p).includes('Hello there')), 'pushes carry no message text');

  // Keeping a message is shared and listed in Moments, newest first.
  assert.equal((await f.request(`/v1/messages/${photo.id}/keep`, { method: 'PUT', token: bob })).status, 200);
  assert.equal((await f.request(`/v1/messages/${hello.id}/keep`, { method: 'PUT', token: alice })).status, 200);
  const kept = (await f.request('/v1/kept', { token: bob })).value.kept;
  assert.deepEqual(kept.map(m => m.id), [hello.id, photo.id]);
  assert.equal(kept[0].topicName, 'Everyday');
  assert.equal((await f.request(`/v1/messages/${hello.id}/keep`, { method: 'DELETE', token: bob })).status, 200);
  assert.deepEqual((await f.request('/v1/kept', { token: alice })).value.kept.map(m => m.id), [photo.id]);

  // Only the author edits or deletes; edits are marked.
  const edit = (token, id, text) => f.request(`/v1/messages/${id}`, { method: 'PATCH', token, body: { text } });
  assert.equal((await edit(bob, hello.id, 'Hijacked')).status, 403);
  assert.equal((await edit(alice, photo.id, 'Not text')).status, 400);
  assert.equal((await edit(alice, hello.id, '')).status, 400);
  const edited = (await edit(alice, hello.id, 'Hello, love')).value;
  assert.equal(edited.text, 'Hello, love');
  assert.equal(typeof edited.editedAt, 'number');
  assert.equal((await f.request(`/v1/messages/${photo.id}`, { method: 'DELETE', token: bob })).status, 403);

  // The change feed carries every update since the cursor, once, in order.
  const changes = (await f.request(`/v1/messages/changes?since=${seq}&topicId=general`, { token: bob })).value;
  assert.deepEqual(changes.messages.map(m => m.id).sort(), [hello.id, photo.id].sort());
  assert.equal(changes.messages.find(m => m.id === hello.id).text, 'Hello, love');
  assert.equal(changes.hasMore, false);
  const none = (await f.request(`/v1/messages/changes?since=${changes.seq}&topicId=general`, { token: bob })).value;
  assert.deepEqual(none.messages, []);
  assert.equal((await f.request('/v1/messages/changes?since=-1&topicId=general', { token: bob })).status, 400);

  // Deleting removes the content and file for both, leaves a tombstone, and updates quotes.
  const reply = (await f.request('/v1/messages', { method: 'POST', token: bob,
    body: { text: 'Gorgeous', clientId: 'actions-reply-1', pairId, replyToId: photo.id } })).value;
  const mediaFile = join(f.dataDir, 'media', pairId, photo.mediaId);
  assert.ok(existsSync(mediaFile));
  const deleted = await f.request(`/v1/messages/${photo.id}`, { method: 'DELETE', token: alice });
  assert.equal(deleted.status, 200);
  assert.equal(deleted.value.deleted, true);
  assert.equal(deleted.value.mediaId, null);
  assert.ok(!existsSync(mediaFile));
  assert.equal((await f.request(`/v1/media/${photo.mediaId}`, { token: bob })).status, 404);
  assert.equal((await f.request(`/v1/messages/${reply.id}`, { token: bob })).value.replyTo.deleted, true);
  assert.deepEqual((await f.request('/v1/kept', { token: bob })).value.kept, []);
  assert.equal((await react(bob, photo.id, '❤️')).status, 409);
  assert.equal((await f.request(`/v1/messages/${photo.id}`, { method: 'DELETE', token: alice })).status, 200);
  const after = (await f.request(`/v1/messages/changes?since=${changes.seq}&topicId=general`, { token: bob })).value;
  assert.ok(after.messages.some(m => m.id === photo.id && m.deleted && m.text === null));
  assert.ok(after.messages.some(m => m.id === reply.id && m.replyTo.deleted), 'quotes of it refresh too');
  await new Promise(resolve => setTimeout(resolve, 2300));

  // Another connection cannot touch these messages; disconnect erases everything.
  const eve = await f.login('actions-e@example.com');
  assert.equal((await react(eve, hello.id, '❤️')).status, 409);
  await react(bob, hello.id, '🔥');
  await f.request(`/v1/messages/${hello.id}/keep`, { method: 'PUT', token: bob });
  await f.request('/v1/pair', { method: 'DELETE', token: bob });
  const db = new DatabaseSync(join(f.dataDir, 'aida.sqlite'));
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM reactions').get().n, 0);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM kept').get().n, 0);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM messages').get().n, 0);
  db.close();
});

test('private nicknames, profile photos, and unread history for notifications', async t => {
  const f = await fixture(t);
  const alice = await f.login('profile-a@example.com');
  const bob = await f.login('profile-b@example.com');
  const eve = await f.login('profile-e@example.com');
  await f.request('/v1/me', { method: 'PATCH', token: bob, body: { name: 'Bob' } });
  const invite = (await f.request('/v1/invites', { method: 'POST', token: alice })).value;
  const pairId = (await f.request('/v1/invites/accept', { method: 'POST', token: bob,
    body: { code: invite.code } })).value.pair.id;
  const aliceId = (await f.request('/v1/me', { token: alice })).value.user.id;
  const bobId = (await f.request('/v1/me', { token: bob })).value.user.id;

  // A nickname is seen only by the person who set it, and can be cleared.
  const nick = (token, nickname) => f.request('/v1/pair/nickname', { method: 'PUT', token, body: { nickname } });
  assert.equal((await nick(alice, 'x'.repeat(41))).status, 400);
  const named = await nick(alice, '  Love  ');
  assert.equal(named.status, 200);
  assert.equal(named.value.pair.partner.nickname, 'Love');
  assert.equal(named.value.pair.partner.name, 'Bob');
  assert.equal((await f.request('/v1/me', { token: bob })).value.pair.partner.nickname, null);
  const sent = (await f.request('/v1/messages', { method: 'POST', token: bob,
    body: { text: 'Hi', clientId: 'profile-hi-1', pairId } })).value;
  assert.equal((await f.request(`/v1/messages/${sent.id}`, { token: alice })).value.senderName, 'Love');
  assert.equal((await nick(alice, '')).value.pair.partner.nickname, null);
  assert.equal((await f.request(`/v1/messages/${sent.id}`, { token: alice })).value.senderName, 'Bob');
  await nick(alice, 'Love');

  // Profile photos: images only, size-limited, visible to yourself and your partner.
  const png = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3]);
  const upload = (token, body, type = 'image/png') => f.request('/v1/me/photo', { method: 'PUT', token, body,
    headers: { 'content-type': type } });
  assert.equal((await upload(bob, png, 'video/mp4')).status, 415);
  assert.equal((await upload(bob, new Uint8Array(5 * 1024 * 1024 + 1))).status, 413);
  const uploaded = await upload(bob, png);
  assert.equal(uploaded.status, 200);
  const photoAt = uploaded.value.user.photoAt;
  assert.equal(typeof photoAt, 'number');
  assert.equal((await f.request('/v1/me', { token: alice })).value.pair.partner.photoAt, photoAt);
  const seen = await f.request(`/v1/users/${bobId}/photo`, { token: alice });
  assert.equal(seen.status, 200);
  assert.deepEqual([...seen.value], [...png]);
  assert.equal((await f.request(`/v1/users/${bobId}/photo`, { token: bob })).status, 200);
  assert.equal((await f.request(`/v1/users/${bobId}/photo`, { token: eve })).status, 404);
  assert.equal((await f.request(`/v1/users/${aliceId}/photo`, { token: bob })).status, 404);

  // Unread history: everything after my read point, oldest first, without deleted messages.
  for (let i = 1; i <= 14; i++) {
    await f.request('/v1/messages', { method: 'POST', token: bob,
      body: { text: `Note ${i}`, clientId: `profile-note-${i}`, pairId } });
  }
  const mine = (await f.request('/v1/messages', { method: 'POST', token: alice,
    body: { text: 'Replying from the notification', clientId: 'profile-mine-1', pairId } })).value;
  const doomed = (await f.request('/v1/messages', { method: 'POST', token: bob,
    body: { text: 'Never mind', clientId: 'profile-doomed-1', pairId } })).value;
  await f.request(`/v1/messages/${doomed.id}`, { method: 'DELETE', token: bob });
  const unread = (await f.request('/v1/unread?topicId=general', { token: alice })).value;
  assert.equal(unread.unreadCount, 15);
  assert.equal(unread.messages.length, 12);
  assert.equal(unread.messages.at(-1).id, mine.id);
  assert.equal(unread.messages.at(-2).text, 'Note 14');
  assert.ok(unread.messages.every(m => !m.deleted));
  assert.equal(unread.topicName, 'Everyday');
  assert.equal(unread.partnerName, 'Love');
  await f.request('/v1/receipts', { method: 'POST', token: alice,
    body: { pairId, topicId: 'general', deliveredThrough: mine.id, readThrough: mine.id } });
  assert.deepEqual((await f.request('/v1/unread?topicId=general', { token: alice })).value.messages, []);
  assert.equal((await f.request('/v1/unread?topicId=nope', { token: alice })).status, 404);

  // Removing a photo, and disconnecting, clear what the other person can see.
  assert.equal((await f.request('/v1/me/photo', { method: 'DELETE', token: bob })).value.user.photoAt, null);
  assert.equal((await f.request(`/v1/users/${bobId}/photo`, { token: alice })).status, 404);
  await upload(bob, png);
  await f.request('/v1/pair', { method: 'DELETE', token: alice });
  assert.equal((await f.request(`/v1/users/${bobId}/photo`, { token: alice })).status, 404);
  const db = new DatabaseSync(join(f.dataDir, 'aida.sqlite'));
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM nicknames').get().n, 0);
  db.close();
});

test('last seen is the last time the app was open, never a background connection', async t => {
  const f = await fixture(t, { presenceTtl: 600, activityInterval: 20 });
  const a = await f.login('seen-a@example.com');
  const b = await f.login('seen-b@example.com');
  const invite = (await f.request('/v1/invites', { method: 'POST', token: a })).value;
  await f.request('/v1/invites/accept', { method: 'POST', token: b, body: { code: invite.code } });
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const seen = async () => (await f.request('/v1/me', { token: b })).value.pair.partner.lastSeenAt;
  const partner = await liveClient(f.base, b);
  const clients = [partner];
  const connect = async () => { const c = await liveClient(f.base, a); clients.push(c); return c; };
  try {
    // The app running in the background (connected, not open) is never "seen",
    // even across reconnects such as network changes or server restarts.
    let app = await connect();
    app.send({ type: 'presence', active: false });
    await wait(150);
    app.ws.close();
    await wait(150);
    app = await connect();
    app.send({ type: 'presence', active: false });
    await wait(150);
    assert.equal(await seen(), null);
    assert.equal(partner.events.some(e => e.type === 'presence'), false);

    // Opening the app shows Online; leaving it records when they left.
    const opened = Date.now();
    app.send({ type: 'presence', active: true });
    await partner.take(e => e.type === 'presence' && e.online);
    await wait(100);
    app.send({ type: 'presence', active: false });
    const left = Date.now();
    const offline = await partner.take(e => e.type === 'presence' && !e.online);
    const lastSeen = await seen();
    assert.equal(offline.lastSeenAt, lastSeen);
    assert.ok(lastSeen >= opened && lastSeen <= left + 5, 'last seen is the moment they left');

    // Later background reconnects leave it alone.
    app.ws.close();
    await wait(150);
    app = await connect();
    app.send({ type: 'presence', active: false });
    await wait(150);
    assert.equal(await seen(), lastSeen);

    // If the app disappears without saying goodbye, last seen is its last
    // heartbeat, not the moment the server noticed the silence.
    app.send({ type: 'presence', active: true });
    await partner.take(e => e.type === 'presence' && e.online);
    const heartbeat = Date.now();
    const expired = await partner.take(e => e.type === 'presence' && !e.online);
    assert.ok(Date.now() - heartbeat >= 550, 'the lease ran out');
    assert.ok(expired.lastSeenAt <= heartbeat + 5, 'last seen is the final heartbeat');
    assert.equal(await seen(), expired.lastSeenAt);
  } finally {
    for (const client of clients) client.ws.terminate();
  }
});
