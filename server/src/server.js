import http from 'node:http';
import { createHash, createHmac, randomBytes, randomInt, randomUUID, timingSafeEqual } from 'node:crypto';
import { createReadStream, createWriteStream, existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';
import { WebSocketServer, WebSocket } from 'ws';
import { AccessToken, RoomServiceClient } from 'livekit-server-sdk';
import { OAuth2Client } from 'google-auth-library';
import { openDatabase, transaction } from './db.js';
import { createPushSender, createPushQueue } from './push.js';

const MAX_JSON = 32 * 1024;
const MAX_MEDIA = 100 * 1024 * 1024;
const REACTIONS = new Set(['❤️', '😂', '😮', '😢', '👍', '🔥']);
const INVITE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const MIME_KINDS = new Map([
  ['image/jpeg', 'image'], ['image/png', 'image'], ['image/webp', 'image'],
  ['image/gif', 'image'], ['video/mp4', 'video'], ['video/webm', 'video'],
  ['video/quicktime', 'video'],
]);

class ApiError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const fail = (status, code, message) => { throw new ApiError(status, code, message); };
const now = () => Date.now();
const hash = value => createHash('sha256').update(value).digest('hex');
const publicUser = user => ({ id: user.id, name: user.name });
const cleanEmail = value => String(value ?? '').trim().toLowerCase();

function inviteCode() {
  return Array.from({ length: 10 }, () => INVITE_ALPHABET[randomInt(INVITE_ALPHABET.length)]).join('');
}

function safeEqual(a, b) {
  const left = Buffer.from(a, 'hex');
  const right = Buffer.from(b, 'hex');
  return left.length === right.length && timingSafeEqual(left, right);
}

async function readJson(request) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > MAX_JSON) fail(413, 'too_large', 'Request is too large');
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
  } catch {
    fail(400, 'bad_json', 'Invalid JSON');
  }
}

function send(response, status, value) {
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
  });
  response.end(JSON.stringify(value));
}

function bearer(request) {
  const match = /^Bearer ([A-Za-z0-9_-]{30,})$/.exec(request.headers.authorization ?? '');
  return match?.[1] ?? null;
}

export function createApp(options = {}) {
  const dataDir = resolve(options.dataDir ?? process.env.DATA_DIR ?? './data');
  const mediaDir = join(dataDir, 'media');
  mkdirSync(mediaDir, { recursive: true });
  const db = openDatabase(join(dataDir, 'aida.sqlite'));
  const secret = options.secret ?? process.env.APP_SECRET ??
    (process.env.NODE_ENV === 'production' ? null : randomBytes(32).toString('hex'));
  if (!secret || secret.length < 32) throw new Error('APP_SECRET must be at least 32 characters');
  const livekitUrl = options.livekitUrl ?? process.env.LIVEKIT_PUBLIC_URL ?? process.env.LIVEKIT_URL;
  const livekitInternalUrl = options.livekitInternalUrl ?? process.env.LIVEKIT_INTERNAL_URL ?? livekitUrl;
  const livekitKey = options.livekitKey ?? process.env.LIVEKIT_API_KEY;
  const livekitSecret = options.livekitSecret ?? process.env.LIVEKIT_API_SECRET;
  const roomService = livekitUrl && livekitInternalUrl && livekitKey && livekitSecret
    ? new RoomServiceClient(livekitInternalUrl.replace(/^ws/, 'http'), livekitKey, livekitSecret)
    : null;
  const clients = new Map();
  let closing = false;
  const presenceStates = new Map();
  const presenceTtl = options.presenceTtl ?? 45_000;
  const typingTtl = options.typingTtl ?? 5_000;
  const pushes = createPushQueue(db, options.sendPush ?? createPushSender());
  const googleClientId = options.googleClientId ?? process.env.GOOGLE_WEB_CLIENT_ID;
  const googleClient = new OAuth2Client();
  const verifyGoogleIdToken = options.verifyGoogleIdToken ?? (async idToken => {
    if (!googleClientId) throw new Error('GOOGLE_WEB_CLIENT_ID is required');
    const ticket = await googleClient.verifyIdToken({ idToken, audience: googleClientId });
    return ticket.getPayload();
  });
  const sendEmail = options.sendEmail ?? (async () => {
    if (process.env.NODE_ENV !== 'production' && process.env.DEV_RETURN_OTP === '1') return;
    throw new Error('Development email-code sign-in is disabled');
  });

  function auth(request) {
    const token = bearer(request);
    if (!token) fail(401, 'unauthorized', 'Sign in required');
    const user = db.prepare(`
      SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id
      WHERE s.token_hash = ? AND s.expires_at > ?
    `).get(hash(token), now());
    if (!user) fail(401, 'unauthorized', 'Session expired');
    return user;
  }

  function currentPair(user) {
    if (!user.pair_id) fail(409, 'not_paired', 'Connect with someone first');
    const pair = db.prepare("SELECT * FROM pairs WHERE id = ? AND state = 'active'").get(user.pair_id);
    if (!pair || (pair.a_id !== user.id && pair.b_id !== user.id)) {
      fail(409, 'not_paired', 'The connection has ended');
    }
    return pair;
  }

  function otherId(pair, userId) {
    return pair.a_id === userId ? pair.b_id : pair.a_id;
  }

  function notify(userIds, type, data = {}) {
    for (const id of userIds) {
      for (const socket of clients.get(id) ?? []) {
        if (socket.readyState === WebSocket.OPEN) {
          const valid = db.prepare('SELECT 1 FROM sessions WHERE token_hash = ? AND expires_at > ?')
            .get(socket.sessionTokenHash, now());
          if (valid) socket.send(JSON.stringify({ type, ...data }));
          else socket.close();
        }
      }
    }
  }

  function ownState(user) {
    const refreshed = db.prepare('SELECT * FROM users WHERE id = ?').get(user.id);
    if (!refreshed.pair_id) {
      const invite = db.prepare(
        'SELECT code, expires_at FROM invites WHERE creator_id = ? AND expires_at > ? ORDER BY created_at DESC LIMIT 1'
      ).get(user.id, now());
      return { user: publicUser(refreshed), pair: null, invite: invite ?? null };
    }
    const pair = currentPair(refreshed);
    const partner = db.prepare('SELECT * FROM users WHERE id = ?').get(otherId(pair, user.id));
    return {
      user: publicUser(refreshed),
      pair: { id: pair.id, partner: { ...publicUser(partner), ...presence(partner) }, createdAt: pair.created_at },
      invite: null,
    };
  }

  function presence(user) {
    return {
      online: [...(clients.get(user.id) ?? [])].some(ws => ws.activeUntil > now() && ws.readyState === WebSocket.OPEN),
      lastSeenAt: user.last_seen_at ?? null,
    };
  }

  function publishPresence(userId) {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (!user) return;
    const status = presence(user);
    if (presenceStates.get(userId) === status.online) return;
    presenceStates.set(userId, status.online);
    if (!status.online) {
      status.lastSeenAt = now();
      db.prepare('UPDATE users SET last_seen_at = ? WHERE id = ?').run(status.lastSeenAt, userId);
    }
    if (user.pair_id) {
      const pair = currentPair(user);
      notify([otherId(pair, userId)], 'presence', { pairId: pair.id, userId, ...status });
    }
  }

  function publishTyping(userId, pairId, topicId) {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (user?.pair_id !== pairId) return;
    const pair = currentPair(user);
    const typing = [...(clients.get(userId) ?? [])].some(ws =>
      ws.activeUntil > now() && ws.typing?.pairId === pairId &&
      ws.typing.topicId === topicId && ws.typing.until > now());
    notify([otherId(pair, userId)], 'typing', { pairId, topicId, userId, typing, expiresIn: typingTtl });
  }

  function stopTyping(ws, userId) {
    const typing = ws.typing;
    ws.typing = null;
    if (typing) publishTyping(userId, typing.pairId, typing.topicId);
  }

  function receipt(pairId, userId, topicId) {
    const row = db.prepare('SELECT * FROM receipts WHERE pair_id = ? AND user_id = ? AND topic_id = ?')
      .get(pairId, userId, topicId);
    return { deliveredThrough: row?.delivered_through ?? 0, readThrough: row?.read_through ?? 0 };
  }

  function messageForClient(row) {
    const quoted = row.reply_to_id == null ? null
      : db.prepare('SELECT id, sender_id, kind, text, deleted_at FROM messages WHERE id = ? AND pair_id = ?')
        .get(row.reply_to_id, row.pair_id);
    const reactions = db.prepare('SELECT user_id, emoji FROM reactions WHERE message_id = ? ORDER BY created_at')
      .all(row.id).map(r => ({ userId: r.user_id, emoji: r.emoji }));
    const kept = db.prepare('SELECT user_id FROM kept WHERE message_id = ?').get(row.id);
    return {
      id: row.id, senderId: row.sender_id, clientId: row.client_id,
      kind: row.kind, text: row.text, mediaId: row.media_id, createdAt: row.created_at,
      topicId: row.topic_id, pairId: row.pair_id, replyToId: row.reply_to_id ?? null,
      editedAt: row.edited_at ?? null, deleted: row.deleted_at != null,
      reactions, kept: Boolean(kept), keptBy: kept?.user_id ?? null,
      ...(quoted ? { replyTo: {
        id: quoted.id, senderId: quoted.sender_id, kind: quoted.kind,
        text: quoted.text == null ? null : quoted.text.slice(0, 280),
        ...(quoted.deleted_at != null ? { deleted: true } : {}),
      } } : {}),
    };
  }

  /** Highest change number in a pair; clients resume the change feed from it. */
  function changeSeq(pairId) {
    return db.prepare('SELECT COALESCE(MAX(updated_seq), 0) AS seq FROM messages WHERE pair_id = ?').get(pairId).seq;
  }

  /** Marks a message as changed so the change feed delivers it again. */
  function bump(pairId, messageId) {
    db.prepare(`UPDATE messages SET updated_seq =
      (SELECT COALESCE(MAX(updated_seq), 0) + 1 FROM messages WHERE pair_id = ?) WHERE id = ?`).run(pairId, messageId);
  }

  /** Replies embed a quote of the original, so they change when it does. */
  function bumpReplies(pairId, messageId) {
    for (const reply of db.prepare('SELECT id FROM messages WHERE pair_id = ? AND reply_to_id = ?').all(pairId, messageId)) {
      bump(pairId, reply.id);
    }
  }

  function messageUpdated(pair, message) {
    notify([pair.a_id, pair.b_id], 'message_updated',
      { pairId: pair.id, topicId: message.topic_id, messageId: String(message.id) });
  }

  /** Validates an optional reply target; it must be in the same pair and topic. */
  function replyTarget(pair, topicId, value) {
    if (value === undefined || value === null || value === '') return null;
    const id = Number(value);
    const target = Number.isSafeInteger(id) && id > 0 &&
      db.prepare('SELECT id FROM messages WHERE id = ? AND pair_id = ? AND topic_id = ?').get(id, pair.id, topicId);
    if (!target) fail(400, 'invalid_reply', 'The message you replied to is unavailable');
    return id;
  }

  function validateTopic(pair, topicId = 'general', expectedPairId) {
    if (!db.prepare("SELECT 1 FROM pairs WHERE id = ? AND state = 'active'").get(pair.id)) fail(409, 'pair_changed', 'This connection has ended');
    if (expectedPairId && expectedPairId !== pair.id) fail(409, 'pair_changed', 'This connection has ended');
    if (typeof topicId !== 'string' || (topicId !== 'general' &&
        !db.prepare('SELECT 1 FROM topics WHERE id = ? AND pair_id = ?').get(topicId, pair.id))) {
      fail(404, 'topic_unavailable', 'This topic is unavailable');
    }
    return topicId;
  }

  function messageChanged(pair, sender, message) {
    const data = { pairId: pair.id, messageId: String(message.id), topicId: message.topic_id };
    notify([pair.a_id, pair.b_id], 'messages_changed', data);
    pushes.enqueue([otherId(pair, sender.id)], { type: 'message', ...data });
  }

  function callForClient(row) {
    return row ? {
      id: row.id, initiatorId: row.initiator_id, kind: row.kind,
      state: row.state, createdAt: row.created_at, pairId: row.pair_id,
    } : null;
  }

  function expireCalls(pairId) {
    db.prepare(
      "UPDATE calls SET state = 'ended', updated_at = ? WHERE pair_id = ? AND state = 'ringing' AND created_at < ?"
    ).run(now(), pairId, now() - 60_000);
    db.prepare(
      "UPDATE calls SET state = 'ended', updated_at = ? WHERE pair_id = ? AND state = 'active' AND created_at < ?"
    ).run(now(), pairId, now() - 2 * 60 * 60 * 1000);
  }

  async function deleteRoom(callId) {
    if (!roomService) return false;
    try {
      await roomService.deleteRoom(callId);
      return true;
    } catch (error) {
      if (String(error.message).includes('not found')) return true;
      console.error('LiveKit room cleanup failed:', error);
      return false;
    }
  }

  async function cleanupRoom(callId) {
    db.prepare('INSERT OR IGNORE INTO room_cleanup (id, created_at) VALUES (?, ?)').run(callId, now());
    if (await deleteRoom(callId)) db.prepare('DELETE FROM room_cleanup WHERE id = ?').run(callId);
  }

  async function retryRoomCleanup() {
    for (const row of db.prepare('SELECT id FROM room_cleanup').all()) {
      if (await deleteRoom(row.id)) db.prepare('DELETE FROM room_cleanup WHERE id = ?').run(row.id);
    }
  }

  function cleanupClosedMedia() {
    for (const name of readdirSync(mediaDir)) {
      const path = join(mediaDir, name);
      if (!statSync(path).isDirectory()) continue;
      const active = db.prepare("SELECT 1 FROM pairs WHERE id = ? AND state = 'active'").get(name);
      if (!active) {
        try { rmSync(path, { recursive: true, force: true }); }
        catch (error) { console.error('Media cleanup failed:', error); }
      }
    }
  }
  cleanupClosedMedia();
  const cleanupTimer = setInterval(() => {
    cleanupClosedMedia();
    retryRoomCleanup().catch(error => console.error('Room cleanup retry failed:', error));
  }, 60_000);
  cleanupTimer.unref();
  retryRoomCleanup().catch(error => console.error('Room cleanup retry failed:', error));

  async function handle(request, response) {
    const url = new URL(request.url, 'http://localhost');
    const path = url.pathname;
    const method = request.method;

    if (method === 'GET' && path === '/health') return send(response, 200, { ok: true });

    if (method === 'POST' && path === '/v1/auth/google') {
      if (!googleClientId && !options.verifyGoogleIdToken) {
        fail(503, 'auth_not_configured', 'Google sign-in is not configured yet');
      }
      const body = await readJson(request);
      const idToken = String(body.idToken ?? '');
      if (idToken.length < 100 || idToken.length > 10000) {
        fail(400, 'invalid_token', 'Google sign-in token is missing');
      }
      let payload;
      try { payload = await verifyGoogleIdToken(idToken); }
      catch { fail(401, 'invalid_token', 'Google sign-in could not be verified'); }
      const email = cleanEmail(payload?.email);
      const subject = String(payload?.sub ?? '');
      if (payload?.email_verified !== true || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ||
          subject.length < 5 || subject.length > 255) {
        fail(401, 'invalid_token', 'Google account email is not verified');
      }
      const result = transaction(db, () => {
        let user = db.prepare('SELECT * FROM users WHERE google_sub = ?').get(subject);
        if (!user) {
          user = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
          if (user?.google_sub && user.google_sub !== subject) {
            fail(409, 'account_conflict', 'This email belongs to another account');
          }
          if (user) {
            db.prepare('UPDATE users SET google_sub = ? WHERE id = ?').run(subject, user.id);
          } else {
            const name = String(payload.name ?? email.split('@')[0]).trim().slice(0, 40) || 'Aida user';
            const id = randomUUID();
            db.prepare('INSERT INTO users (id, email, name, google_sub, created_at) VALUES (?, ?, ?, ?, ?)')
              .run(id, email, name, subject, now());
            user = db.prepare('SELECT * FROM users WHERE id = ?').get(id);
          }
        }
        const token = randomBytes(32).toString('base64url');
        db.prepare('INSERT INTO sessions (token_hash, user_id, expires_at) VALUES (?, ?, ?)')
          .run(hash(token), user.id, now() + 30 * 24 * 60 * 60 * 1000);
        return { token, user: publicUser(user) };
      });
      return send(response, 200, result);
    }

    if (method === 'POST' && path === '/v1/auth/start') {
      if (process.env.NODE_ENV === 'production') fail(404, 'not_found', 'Route not found');
      const body = await readJson(request);
      const email = cleanEmail(body.email);
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
        fail(400, 'invalid_email', 'Enter a valid email address');
      }
      const previous = db.prepare('SELECT sent_at FROM login_codes WHERE email = ?').get(email);
      if (previous && now() - previous.sent_at < 60_000) {
        fail(429, 'try_later', 'Wait a minute before requesting another code');
      }
      const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
      const codeHash = hash(`${secret}:${email}:${code}`);
      await sendEmail(email, code);
      db.prepare(`
        INSERT INTO login_codes (email, code_hash, expires_at, attempts, sent_at)
        VALUES (?, ?, ?, 0, ?)
        ON CONFLICT(email) DO UPDATE SET code_hash=excluded.code_hash,
          expires_at=excluded.expires_at, attempts=0, sent_at=excluded.sent_at
      `).run(email, codeHash, now() + 600_000, now());
      const result = { sent: true };
      if (process.env.NODE_ENV !== 'production' && process.env.DEV_RETURN_OTP === '1') {
        result.devCode = code;
      }
      return send(response, 200, result);
    }

    if (method === 'POST' && path === '/v1/auth/verify') {
      if (process.env.NODE_ENV === 'production') fail(404, 'not_found', 'Route not found');
      const body = await readJson(request);
      const email = cleanEmail(body.email);
      const code = String(body.code ?? '');
      if (!/^\d{6}$/.test(code)) fail(400, 'invalid_code', 'Enter the six-digit code');
      const login = db.prepare('SELECT * FROM login_codes WHERE email = ?').get(email);
      if (!login || login.expires_at <= now() || login.attempts >= 5) {
        fail(401, 'invalid_code', 'Code expired or unavailable');
      }
      db.prepare('UPDATE login_codes SET attempts = attempts + 1 WHERE email = ?').run(email);
      if (!safeEqual(login.code_hash, hash(`${secret}:${email}:${code}`))) {
        fail(401, 'invalid_code', 'Incorrect code');
      }
      const result = transaction(db, () => {
        db.prepare('DELETE FROM login_codes WHERE email = ?').run(email);
        let user = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
        if (!user) {
          const name = email.split('@')[0].slice(0, 30);
          const id = randomUUID();
          db.prepare('INSERT INTO users (id, email, name, created_at) VALUES (?, ?, ?, ?)')
            .run(id, email, name, now());
          user = db.prepare('SELECT * FROM users WHERE id = ?').get(id);
        }
        const token = randomBytes(32).toString('base64url');
        db.prepare('INSERT INTO sessions (token_hash, user_id, expires_at) VALUES (?, ?, ?)')
          .run(hash(token), user.id, now() + 30 * 24 * 60 * 60 * 1000);
        return { token, user: publicUser(user) };
      });
      return send(response, 200, result);
    }

    const user = auth(request);

    if (method === 'POST' && path === '/v1/auth/signout') {
      const tokenHash = hash(bearer(request));
      db.prepare('DELETE FROM sessions WHERE token_hash = ?').run(tokenHash);
      for (const socket of clients.get(user.id) ?? []) {
        if (socket.sessionTokenHash === tokenHash) socket.close();
      }
      return send(response, 200, { ok: true });
    }
    if (path === '/v1/devices' && method === 'POST') {
      const body = await readJson(request);
      const token = String(body.token ?? '');
      if (token.length < 20 || token.length > 4096) fail(400, 'invalid_device', 'Invalid notification token');
      db.prepare(`INSERT INTO devices (token, user_id, session_hash, updated_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(token) DO UPDATE SET user_id = excluded.user_id, session_hash = excluded.session_hash,
        updated_at = excluded.updated_at`).run(token, user.id, hash(bearer(request)), now());
      return send(response, 200, { enabled: pushes.enabled });
    }
    if (path === '/v1/devices' && method === 'DELETE') {
      db.prepare('DELETE FROM devices WHERE session_hash = ?').run(hash(bearer(request)));
      return send(response, 200, { ok: true });
    }
    if (method === 'GET' && path === '/v1/me') return send(response, 200, ownState(user));
    if (method === 'PATCH' && path === '/v1/me') {
      const body = await readJson(request);
      const name = String(body.name ?? '').trim();
      if (name.length < 1 || name.length > 40) fail(400, 'invalid_name', 'Name must be 1–40 characters');
      db.prepare('UPDATE users SET name = ? WHERE id = ?').run(name, user.id);
      return send(response, 200, ownState(user));
    }

    if (method === 'POST' && path === '/v1/invites') {
      if (user.pair_id) fail(409, 'already_paired', 'Disconnect before inviting someone else');
      let code;
      const expires = now() + 24 * 60 * 60 * 1000;
      transaction(db, () => {
        db.prepare('DELETE FROM invites WHERE creator_id = ?').run(user.id);
        do { code = inviteCode(); } while (db.prepare('SELECT 1 FROM invites WHERE code = ?').get(code));
        db.prepare('INSERT INTO invites (code, creator_id, expires_at, created_at) VALUES (?, ?, ?, ?)')
          .run(code, user.id, expires, now());
      });
      return send(response, 201, { code, expiresAt: expires });
    }
    if (method === 'DELETE' && path === '/v1/invites') {
      db.prepare('DELETE FROM invites WHERE creator_id = ?').run(user.id);
      return send(response, 200, { ok: true });
    }
    if (method === 'GET' && path.startsWith('/v1/invites/')) {
      const code = path.slice('/v1/invites/'.length).toUpperCase();
      const invite = db.prepare(`
        SELECT i.*, u.name FROM invites i JOIN users u ON u.id = i.creator_id
        WHERE i.code = ? AND i.expires_at > ? AND u.pair_id IS NULL
      `).get(code, now());
      if (!invite) fail(404, 'invite_unavailable', 'Invite expired or unavailable');
      if (invite.creator_id === user.id) fail(400, 'own_invite', 'You cannot accept your own invite');
      return send(response, 200, {
        code, inviter: { name: invite.name }, expiresAt: invite.expires_at,
      });
    }
    if (method === 'POST' && path === '/v1/invites/accept') {
      const body = await readJson(request);
      const code = String(body.code ?? '').trim().toUpperCase();
      const pair = transaction(db, () => {
        const invite = db.prepare('SELECT * FROM invites WHERE code = ? AND expires_at > ?')
          .get(code, now());
        if (!invite) fail(404, 'invite_unavailable', 'Invite expired or unavailable');
        if (invite.creator_id === user.id) fail(400, 'own_invite', 'You cannot accept your own invite');
        const inviter = db.prepare('SELECT * FROM users WHERE id = ?').get(invite.creator_id);
        const recipient = db.prepare('SELECT * FROM users WHERE id = ?').get(user.id);
        if (inviter.pair_id || recipient.pair_id) {
          fail(409, 'already_paired', 'One of you is already connected');
        }
        const id = randomUUID();
        db.prepare("INSERT INTO pairs (id, a_id, b_id, state, created_at) VALUES (?, ?, ?, 'active', ?)")
          .run(id, inviter.id, recipient.id, now());
        const update = db.prepare('UPDATE users SET pair_id = ? WHERE id = ? AND pair_id IS NULL');
        if (update.run(id, inviter.id).changes !== 1 || update.run(id, recipient.id).changes !== 1) {
          fail(409, 'already_paired', 'One of you is already connected');
        }
        db.prepare('DELETE FROM invites WHERE creator_id IN (?, ?)').run(inviter.id, recipient.id);
        return { id, aId: inviter.id, bId: recipient.id };
      });
      notify([pair.aId, pair.bId], 'pair_changed');
      return send(response, 200, ownState(user));
    }

    if (method === 'DELETE' && path === '/v1/pair') {
      const pair = currentPair(user);
      const callIds = db.prepare(
        "SELECT id FROM calls WHERE pair_id = ? AND state IN ('ringing', 'active')"
      ).all(pair.id).map(row => row.id);
      transaction(db, () => {
        db.prepare('UPDATE users SET pair_id = NULL WHERE id IN (?, ?) AND pair_id = ?')
          .run(pair.a_id, pair.b_id, pair.id);
        db.prepare('DELETE FROM reactions WHERE pair_id = ?').run(pair.id);
        db.prepare('DELETE FROM kept WHERE pair_id = ?').run(pair.id);
        db.prepare('DELETE FROM messages WHERE pair_id = ?').run(pair.id);
        db.prepare('DELETE FROM media WHERE pair_id = ?').run(pair.id);
        db.prepare('DELETE FROM calls WHERE pair_id = ?').run(pair.id);
        db.prepare('DELETE FROM invites WHERE creator_id IN (?, ?)').run(pair.a_id, pair.b_id);
        db.prepare('DELETE FROM topics WHERE pair_id = ?').run(pair.id);
        for (const callId of callIds) db.prepare('INSERT OR IGNORE INTO room_cleanup (id, created_at) VALUES (?, ?)').run(callId, now());
        db.prepare('DELETE FROM pairs WHERE id = ?').run(pair.id);
      });
      notify([pair.a_id, pair.b_id], 'pair_changed');
      pushes.enqueue([pair.a_id, pair.b_id], { type: 'disconnected', pairId: pair.id });
      try { rmSync(join(mediaDir, pair.id), { recursive: true, force: true }); }
      catch (error) { console.error('Media deletion will retry on restart:', error); }
      await Promise.all(callIds.map(cleanupRoom));
      return send(response, 200, { disconnected: true });
    }

    if (path === '/v1/topics' && method === 'GET') {
      const pair = currentPair(user);
      const topics = db.prepare('SELECT id, name FROM topics WHERE pair_id = ? ORDER BY created_at, id').all(pair.id);
      return send(response, 200, { topics: [{ id: 'general', name: 'Everyday' }, ...topics] });
    }
    if (path === '/v1/topics' && method === 'POST') {
      const pair = currentPair(user);
      const body = await readJson(request);
      validateTopic(pair, 'general', body.pairId);
      const name = String(body.name ?? '').trim();
      if (name.length < 1 || name.length > 32) fail(400, 'invalid_topic', 'Use a name from 1 to 32 characters');
      if (name.toLowerCase() === 'everyday' || db.prepare('SELECT 1 FROM topics WHERE pair_id = ? AND name = ?').get(pair.id, name)) {
        fail(409, 'topic_exists', 'A topic with that name already exists');
      }
      if (db.prepare('SELECT COUNT(*) AS n FROM topics WHERE pair_id = ?').get(pair.id).n >= 20) {
        fail(409, 'topic_limit', 'You can create up to 20 topics');
      }
      const id = randomUUID();
      db.prepare('INSERT INTO topics (id, pair_id, name, created_at) VALUES (?, ?, ?, ?)').run(id, pair.id, name, now());
      notify([pair.a_id, pair.b_id], 'topics_changed');
      return send(response, 201, { id, name });
    }
    const messageMatch = /^\/v1\/messages\/(\d+)$/.exec(path);
    if (method === 'GET' && messageMatch) {
      const pair = currentPair(user);
      const message = db.prepare('SELECT * FROM messages WHERE id = ? AND pair_id = ?').get(Number(messageMatch[1]), pair.id);
      if (!message) fail(404, 'not_found', 'Message unavailable');
      const sender = db.prepare('SELECT name FROM users WHERE id = ?').get(message.sender_id);
      const topic = db.prepare('SELECT name FROM topics WHERE id = ? AND pair_id = ?').get(message.topic_id, pair.id);
      return send(response, 200, { ...messageForClient(message), senderName: sender.name, topicName: topic?.name ?? 'Everyday' });
    }
    if (method === 'GET' && path === '/v1/messages/changes') {
      const pair = currentPair(user);
      const since = Number(url.searchParams.get('since') ?? 0);
      if (!Number.isSafeInteger(since) || since < 0) fail(400, 'bad_cursor', 'Invalid change cursor');
      const topic = validateTopic(pair, url.searchParams.get('topicId') ?? 'general');
      const current = changeSeq(pair.id);
      const rows = db.prepare(
        'SELECT * FROM messages WHERE pair_id = ? AND topic_id = ? AND updated_seq > ? ORDER BY updated_seq ASC LIMIT 201'
      ).all(pair.id, topic, since);
      const page = rows.slice(0, 200);
      const hasMore = rows.length > 200;
      return send(response, 200, {
        messages: page.map(messageForClient), hasMore,
        seq: hasMore ? page.at(-1).updated_seq : current,
      });
    }
    if (method === 'GET' && path === '/v1/kept') {
      const pair = currentPair(user);
      const rows = db.prepare(`SELECT m.*, k.created_at AS kept_at, t.name AS topic_name FROM kept k
        JOIN messages m ON m.id = k.message_id LEFT JOIN topics t ON t.id = m.topic_id AND t.pair_id = m.pair_id
        WHERE k.pair_id = ? AND m.deleted_at IS NULL ORDER BY k.created_at DESC, k.message_id DESC LIMIT 500`).all(pair.id);
      return send(response, 200, { kept: rows.map(row => ({
        ...messageForClient(row), keptAt: row.kept_at, topicName: row.topic_name ?? 'Everyday',
      })) });
    }
    const actionMatch = /^\/v1\/messages\/(\d+)(?:\/(reaction|keep))?$/.exec(path);
    if (actionMatch && ['PATCH', 'PUT', 'DELETE'].includes(method)) {
      const pair = currentPair(user);
      const id = Number(actionMatch[1]);
      const action = actionMatch[2] ?? 'message';
      const message = db.prepare('SELECT * FROM messages WHERE id = ? AND pair_id = ?').get(id, pair.id);
      if (!message) fail(404, 'not_found', 'Message unavailable');
      const reload = () => messageForClient(db.prepare('SELECT * FROM messages WHERE id = ?').get(id));
      const own = () => {
        if (message.sender_id !== user.id) fail(403, 'not_yours', 'Only the sender can change this message');
      };
      const alive = () => {
        if (message.deleted_at != null) fail(409, 'message_deleted', 'This message was deleted');
      };
      const change = (apply) => {
        const changed = transaction(db, () => {
          const result = apply();
          if (result) bump(pair.id, id);
          return result;
        });
        if (changed) messageUpdated(pair, message);
        return changed;
      };

      if (action === 'message' && method === 'PATCH') {
        own(); alive();
        if (message.kind !== 'text') fail(400, 'not_text', 'Only text messages can be edited');
        const body = await readJson(request);
        const text = String(body.text ?? '').trim();
        if (text.length < 1 || text.length > 5000) fail(400, 'invalid_message', 'Message must be 1–5000 characters');
        change(() => {
          if (text === message.text) return false;
          db.prepare('UPDATE messages SET text = ?, edited_at = ? WHERE id = ?').run(text, now(), id);
          bumpReplies(pair.id, id);
          return true;
        });
        return send(response, 200, reload());
      }
      if (action === 'message' && method === 'DELETE') {
        own();
        const removed = change(() => {
          if (message.deleted_at != null) return false;
          db.prepare('DELETE FROM reactions WHERE message_id = ?').run(id);
          db.prepare('DELETE FROM kept WHERE message_id = ?').run(id);
          db.prepare('UPDATE messages SET text = NULL, media_id = NULL, deleted_at = ? WHERE id = ?').run(now(), id);
          if (message.media_id) db.prepare('DELETE FROM media WHERE id = ? AND pair_id = ?').run(message.media_id, pair.id);
          bumpReplies(pair.id, id);
          return true;
        });
        if (removed) {
          if (message.media_id) {
            try { rmSync(join(mediaDir, pair.id, message.media_id), { force: true }); }
            catch (error) { console.error('Deleted message media could not be removed:', error.message); }
          }
          pushes.enqueue([otherId(pair, user.id)],
            { type: 'message_deleted', pairId: pair.id, topicId: message.topic_id, messageId: String(id) });
        }
        return send(response, 200, reload());
      }
      if (action === 'reaction' && method === 'PUT') {
        alive();
        const body = await readJson(request);
        if (!REACTIONS.has(body.emoji)) fail(400, 'invalid_reaction', 'Unsupported reaction');
        const changed = change(() => db.prepare(`INSERT INTO reactions (message_id, pair_id, user_id, emoji, created_at)
          VALUES (?, ?, ?, ?, ?) ON CONFLICT(message_id, user_id)
          DO UPDATE SET emoji = excluded.emoji, created_at = excluded.created_at WHERE emoji != excluded.emoji`)
          .run(id, pair.id, user.id, body.emoji, now()).changes > 0);
        if (changed && message.sender_id !== user.id) {
          pushes.enqueue([message.sender_id],
            { type: 'reaction', pairId: pair.id, topicId: message.topic_id, messageId: String(id) });
        }
        return send(response, 200, reload());
      }
      if (action === 'reaction' && method === 'DELETE') {
        change(() => db.prepare('DELETE FROM reactions WHERE message_id = ? AND user_id = ?').run(id, user.id).changes > 0);
        return send(response, 200, reload());
      }
      if (action === 'keep' && method === 'PUT') {
        alive();
        change(() => db.prepare('INSERT OR IGNORE INTO kept (message_id, pair_id, user_id, created_at) VALUES (?, ?, ?, ?)')
          .run(id, pair.id, user.id, now()).changes > 0);
        return send(response, 200, reload());
      }
      if (action === 'keep' && method === 'DELETE') {
        change(() => db.prepare('DELETE FROM kept WHERE message_id = ?').run(id).changes > 0);
        return send(response, 200, reload());
      }
    }
    if (method === 'GET' && path === '/v1/messages') {
      const pair = currentPair(user);
      const changes = changeSeq(pair.id);
      const after = Number(url.searchParams.get('after') ?? 0);
      if (!Number.isSafeInteger(after) || after < 0) fail(400, 'bad_cursor', 'Invalid message cursor');
      const topic = url.searchParams.get('topicId');
      if (topic !== null) validateTopic(pair, topic);
      const rows = topic === null
        ? db.prepare('SELECT * FROM messages WHERE pair_id = ? AND id > ? ORDER BY id ASC LIMIT 101').all(pair.id, after)
        : db.prepare('SELECT * FROM messages WHERE pair_id = ? AND topic_id = ? AND id > ? ORDER BY id ASC LIMIT 101').all(pair.id, topic, after);
      return send(response, 200, {
        messages: rows.slice(0, 100).map(messageForClient), hasMore: rows.length > 100, changeSeq: changes,
        partnerReceipt: receipt(pair.id, otherId(pair, user.id), topic ?? 'general'),
      });
    }
    if (method === 'POST' && path === '/v1/receipts') {
      const body = await readJson(request);
      const pair = currentPair(auth(request));
      if (body.pairId !== pair.id) fail(409, 'pair_changed', 'This connection has ended');
      const topicId = validateTopic(pair, body.topicId, body.pairId);
      const delivered = body.deliveredThrough ?? 0;
      const read = body.readThrough ?? 0;
      for (const id of [delivered, read]) {
        if (!Number.isSafeInteger(id) || id < 0 || (id > 0 && !db.prepare(
          'SELECT 1 FROM messages WHERE id = ? AND pair_id = ? AND topic_id = ?'
        ).get(id, pair.id, topicId))) fail(400, 'bad_receipt', 'Invalid message receipt');
      }
      const previous = receipt(pair.id, user.id, topicId);
      const next = {
        deliveredThrough: Math.max(previous.deliveredThrough, delivered, read),
        readThrough: Math.max(previous.readThrough, read),
      };
      if (next.deliveredThrough !== previous.deliveredThrough || next.readThrough !== previous.readThrough) {
        db.prepare(`INSERT INTO receipts VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(pair_id, user_id, topic_id) DO UPDATE SET
          delivered_through = excluded.delivered_through, read_through = excluded.read_through`)
          .run(pair.id, user.id, topicId, next.deliveredThrough, next.readThrough);
        notify([otherId(pair, user.id)], 'receipts_changed', { pairId: pair.id, topicId, ...next });
      }
      return send(response, 200, next);
    }
    if (method === 'POST' && path === '/v1/messages') {
      const pair = currentPair(user);
      const body = await readJson(request);
      const topicId = validateTopic(pair, body.topicId, body.pairId);
      const refreshed = db.prepare('SELECT pair_id FROM users WHERE id = ?').get(user.id);
      if (refreshed.pair_id !== pair.id) fail(409, 'pair_changed', 'This connection has ended');
      const text = String(body.text ?? '').trim();
      const clientId = String(body.clientId ?? '');
      if (text.length < 1 || text.length > 5000) fail(400, 'invalid_message', 'Message must be 1–5000 characters');
      if (!/^[A-Za-z0-9_-]{8,80}$/.test(clientId)) fail(400, 'invalid_message', 'Invalid message ID');
      const replyToId = replyTarget(pair, topicId, body.replyToId);
      const existing = db.prepare('SELECT * FROM messages WHERE sender_id = ? AND client_id = ?')
        .get(user.id, clientId);
      if (existing) {
        if (existing.pair_id !== pair.id || existing.topic_id !== topicId) fail(409, 'id_conflict', 'Message ID already used');
        return send(response, 200, messageForClient(existing));
      }
      const id = db.prepare(
        "INSERT INTO messages (pair_id, sender_id, client_id, kind, text, created_at, topic_id, reply_to_id) VALUES (?, ?, ?, 'text', ?, ?, ?, ?)"
      ).run(pair.id, user.id, clientId, text, now(), topicId, replyToId).lastInsertRowid;
      const message = db.prepare('SELECT * FROM messages WHERE id = ?').get(id);
      messageChanged(pair, user, message);
      return send(response, 201, messageForClient(message));
    }

    if (method === 'POST' && path === '/v1/media') {
      const pair = currentPair(user);
      const topicId = validateTopic(pair, request.headers['x-topic-id'], request.headers['x-pair-id']);
      const mime = String(request.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
      const kind = MIME_KINDS.get(mime);
      if (!kind) fail(415, 'unsupported_media', 'Unsupported image or video type');
      const replyToId = replyTarget(pair, topicId, request.headers['x-reply-to-id']);
      const declaredSize = Number(request.headers['content-length']);
      if (!Number.isSafeInteger(declaredSize) || declaredSize < 1 || declaredSize > MAX_MEDIA) {
        fail(413, 'too_large', 'File must be 1–100 MB');
      }
      const filename = String(request.headers['x-file-name'] ?? 'attachment').slice(0, 100)
        .replace(/[\r\n/\\]/g, '_');
      const id = randomUUID();
      const pairDir = join(mediaDir, pair.id);
      mkdirSync(pairDir, { recursive: true });
      const file = join(pairDir, id);
      let actual = 0;
      try {
        await pipeline(request, new Transform({
          transform(chunk, encoding, callback) {
            actual += chunk.length;
            callback(actual > MAX_MEDIA ? new Error('file too large') : null, chunk);
          },
        }), createWriteStream(file, { flags: 'wx' }));
        if (actual !== declaredSize) fail(400, 'bad_upload', 'Incomplete upload');
        // A disconnect during upload must not recreate content for a closed pair.
        const current = db.prepare("SELECT 1 FROM pairs WHERE id = ? AND state = 'active'").get(pair.id);
        const sender = db.prepare('SELECT pair_id FROM users WHERE id = ?').get(user.id);
        if (!current || sender.pair_id !== pair.id) fail(409, 'not_paired', 'Connection ended during upload');
        const created = now();
        const message = transaction(db, () => {
          db.prepare(
            'INSERT INTO media (id, pair_id, sender_id, mime, filename, size, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)'
          ).run(id, pair.id, user.id, mime, filename, actual, created);
          const messageId = db.prepare(
            'INSERT INTO messages (pair_id, sender_id, kind, media_id, created_at, topic_id, reply_to_id) VALUES (?, ?, ?, ?, ?, ?, ?)'
          ).run(pair.id, user.id, kind, id, created, topicId, replyToId).lastInsertRowid;
          return db.prepare('SELECT * FROM messages WHERE id = ?').get(messageId);
        });
        messageChanged(pair, user, message);
        return send(response, 201, messageForClient(message));
      } catch (error) {
        rmSync(file, { force: true });
        throw error;
      }
    }

    if (method === 'GET' && path.startsWith('/v1/media/')) {
      const pair = currentPair(user);
      const id = path.slice('/v1/media/'.length);
      const item = db.prepare('SELECT * FROM media WHERE id = ? AND pair_id = ?').get(id, pair.id);
      if (!item) fail(404, 'not_found', 'Media unavailable');
      const file = join(mediaDir, pair.id, id);
      if (!existsSync(file)) fail(404, 'not_found', 'Media unavailable');
      let start = 0;
      let end = item.size - 1;
      const range = request.headers.range;
      if (range) {
        const match = /^bytes=(\d+)-(\d*)$/.exec(range);
        if (!match) fail(416, 'invalid_range', 'Invalid range');
        start = Number(match[1]);
        end = match[2] ? Number(match[2]) : end;
        if (start > end || end >= item.size) fail(416, 'invalid_range', 'Invalid range');
      }
      response.writeHead(range ? 206 : 200, {
        'content-type': item.mime,
        'content-length': end - start + 1,
        'accept-ranges': 'bytes',
        ...(range ? { 'content-range': `bytes ${start}-${end}/${item.size}` } : {}),
        'cache-control': 'private, no-store',
        'x-content-type-options': 'nosniff',
      });
      createReadStream(file, { start, end }).pipe(response);
      return;
    }

    if (method === 'GET' && path === '/v1/calls/current') {
      const pair = currentPair(user);
      expireCalls(pair.id);
      const call = db.prepare(
        "SELECT * FROM calls WHERE pair_id = ? AND state IN ('ringing', 'active') ORDER BY created_at DESC LIMIT 1"
      ).get(pair.id);
      return send(response, 200, { call: callForClient(call) });
    }
    if (method === 'POST' && path === '/v1/calls') {
      const pair = currentPair(user);
      const body = await readJson(request);
      const kind = body.kind;
      if (kind !== 'voice' && kind !== 'video') fail(400, 'invalid_call', 'Choose voice or video');
      if (!roomService) fail(503, 'calls_unavailable', 'Calling server is not configured');
      expireCalls(pair.id);
      const existing = db.prepare(
        "SELECT 1 FROM calls WHERE pair_id = ? AND state IN ('ringing', 'active')"
      ).get(pair.id);
      if (existing) fail(409, 'call_exists', 'A call is already in progress');
      const id = randomUUID();
      try {
        await roomService.createRoom({ name: id, maxParticipants: 2, emptyTimeout: 120 });
      } catch {
        fail(503, 'calls_unavailable', 'Calling server is unavailable');
      }
      let call;
      try {
        call = transaction(db, () => {
          const refreshed = db.prepare('SELECT pair_id FROM users WHERE id = ?').get(user.id);
          if (refreshed.pair_id !== pair.id) fail(409, 'not_paired', 'Connection ended');
          const active = db.prepare(
            "SELECT 1 FROM calls WHERE pair_id = ? AND state IN ('ringing', 'active')"
          ).get(pair.id);
          if (active) fail(409, 'call_exists', 'A call is already in progress');
          const created = now();
          db.prepare(
            "INSERT INTO calls (id, pair_id, initiator_id, kind, state, created_at, updated_at) VALUES (?, ?, ?, ?, 'ringing', ?, ?)"
          ).run(id, pair.id, user.id, kind, created, created);
          return db.prepare('SELECT * FROM calls WHERE id = ?').get(id);
        });
      } catch (error) {
        await cleanupRoom(id);
        throw error;
      }
      notify([pair.a_id, pair.b_id], 'call_changed');
      pushes.enqueue([otherId(pair, user.id)], { type: 'call', pairId: pair.id, callId: call.id }, 60_000);
      return send(response, 201, callForClient(call));
    }

    const callMatch = /^\/v1\/calls\/([a-f0-9-]+)\/(accept|decline|end|join)$/.exec(path);
    if (method === 'POST' && callMatch) {
      const pair = currentPair(user);
      const [, callId, action] = callMatch;
      expireCalls(pair.id);
      const call = db.prepare('SELECT * FROM calls WHERE id = ? AND pair_id = ?').get(callId, pair.id);
      if (!call) fail(404, 'call_unavailable', 'Call unavailable');
      if (action === 'join') {
        if (call.state !== 'active') fail(409, 'call_not_active', 'The call has not been answered');
        if (!roomService) fail(503, 'calls_unavailable', 'Calling server is not configured');
        const token = new AccessToken(livekitKey, livekitSecret, {
          identity: user.id, name: user.name, ttl: '30s',
        });
        token.addGrant({ roomJoin: true, roomCreate: false, room: call.id,
          canPublish: true, canSubscribe: true });
        return send(response, 200, { url: livekitUrl, token: await token.toJwt() });
      }
      if (action === 'accept') {
        if (call.initiator_id === user.id || call.state !== 'ringing') {
          fail(409, 'call_unavailable', 'Call cannot be answered');
        }
        db.prepare("UPDATE calls SET state = 'active', updated_at = ? WHERE id = ?").run(now(), call.id);
      } else if (action === 'decline') {
        if (call.initiator_id === user.id || call.state !== 'ringing') {
          fail(409, 'call_unavailable', 'Call cannot be declined');
        }
        db.prepare("UPDATE calls SET state = 'declined', updated_at = ? WHERE id = ?").run(now(), call.id);
        await cleanupRoom(call.id);
      } else {
        if (!['ringing', 'active'].includes(call.state)) {
          fail(409, 'call_unavailable', 'Call already ended');
        }
        db.prepare("UPDATE calls SET state = 'ended', updated_at = ? WHERE id = ?").run(now(), call.id);
        await cleanupRoom(call.id);
      }
      notify([pair.a_id, pair.b_id], 'call_changed');
      pushes.enqueue([pair.a_id, pair.b_id], { type: 'call_changed', pairId: pair.id, callId: call.id }, 60_000);
      return send(response, 200, { ok: true });
    }

    fail(404, 'not_found', 'Route not found');
  }

  const server = http.createServer((request, response) => {
    handle(request, response).catch(error => {
      if (response.headersSent) {
        response.destroy(error);
        return;
      }
      if (error instanceof ApiError) {
        send(response, error.status, { error: error.code, message: error.message });
      } else {
        console.error(error);
        send(response, 500, { error: 'internal_error', message: 'Something went wrong' });
      }
    });
  });

  const wsServer = new WebSocketServer({ noServer: true, maxPayload: 4096 });
  server.on('upgrade', (request, socket, head) => {
    try {
      if (new URL(request.url, 'http://localhost').pathname !== '/v1/live') throw new Error('Not found');
      const user = auth(request);
      wsServer.handleUpgrade(request, socket, head, ws => {
        ws.sessionTokenHash = hash(bearer(request));
        let set = clients.get(user.id);
        if (!set) clients.set(user.id, set = new Set());
        set.add(ws);
        ws.activeUntil = 0;
        ws.alive = true;
        ws.on('pong', () => { ws.alive = true; });
        ws.on('error', () => {});
        ws.on('message', raw => {
          try {
            const freshUser = auth(request);
            const event = JSON.parse(raw.toString());
            const stamp = now();
            if (stamp - (ws.windowStart ?? 0) > 1000) { ws.windowStart = stamp; ws.eventCount = 0; }
            if (++ws.eventCount > 20) { ws.close(1008, 'Too many events'); return; }
            if (event.type === 'presence' && typeof event.active === 'boolean') {
              ws.activeUntil = event.active ? stamp + presenceTtl : 0;
              if (event.active) db.prepare('UPDATE users SET last_seen_at = ? WHERE id = ?').run(stamp, user.id);
              else stopTyping(ws, user.id);
              publishPresence(user.id);
            } else if (event.type === 'typing' && typeof event.typing === 'boolean') {
              const pair = currentPair(freshUser);
              if (event.pairId !== pair.id) return;
              const topicId = validateTopic(pair, event.topicId, event.pairId);
              if (ws.typing && (ws.typing.pairId !== pair.id || ws.typing.topicId !== topicId)) stopTyping(ws, user.id);
              if (event.typing && ws.activeUntil > stamp) {
                ws.typing = { pairId: pair.id, topicId, until: stamp + typingTtl };
                publishTyping(user.id, pair.id, topicId);
              } else stopTyping(ws, user.id);
            }
          } catch (error) {
            if (error.status === 401) ws.close(1008, 'Session expired');
            // Ignore malformed, stale, or out-of-scope ephemeral events.
          }
        });
        ws.on('close', () => {
          set.delete(ws);
          if (set.size === 0) clients.delete(user.id);
          if (!closing) {
            stopTyping(ws, user.id);
            publishPresence(user.id);
          }
          if (set.size === 0) presenceStates.delete(user.id);
        });
        ws.send(JSON.stringify({ type: 'connected' }));
      });
    } catch {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
    }
  });

  const activityTimer = setInterval(() => {
    for (const [userId, sockets] of clients) {
      for (const ws of sockets) {
        if (ws.typing && (ws.typing.until <= now() || ws.activeUntil <= now())) stopTyping(ws, userId);
      }
      publishPresence(userId);
    }
  }, options.activityInterval ?? 1000);
  const heartbeatTimer = setInterval(() => {
    for (const sockets of clients.values()) for (const ws of sockets) {
      if (!ws.alive) ws.terminate();
      else { ws.alive = false; ws.ping(); }
    }
  }, 25_000);
  activityTimer.unref();
  heartbeatTimer.unref();

  return {
    server,
    close: async () => {
      closing = true;
      clearInterval(cleanupTimer);
      clearInterval(activityTimer);
      clearInterval(heartbeatTimer);
      await pushes.close();
      for (const set of clients.values()) for (const ws of set) ws.close();
      await new Promise(resolveClose => server.close(resolveClose));
      wsServer.close();
      db.close();
    },
  };
}

if (process.argv[1] && import.meta.url === new URL(`file://${resolve(process.argv[1])}`).href) {
  const app = createApp();
  const port = Number(process.env.PORT ?? 8080);
  const host = process.env.HOST ?? '127.0.0.1';
  app.server.listen(port, host, () => console.log(`Aida API listening on ${host}:${port}`));
}
