import { GoogleAuth } from 'google-auth-library';

export function createPushSender() {
  if (!process.env.GOOGLE_APPLICATION_CREDENTIALS) return null;
  const auth = new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/firebase.messaging'] });
  return async (token, data, ttl) => {
    const projectId = await auth.getProjectId();
    const accessToken = await auth.getAccessToken();
    const response = await fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
      method: 'POST',
      headers: { authorization: `Bearer ${accessToken}`, 'content-type': 'application/json' },
      signal: AbortSignal.timeout(10_000),
      body: JSON.stringify({ message: {
        token, data,
        android: { priority: 'high', ttl: `${Math.max(0, Math.floor(ttl / 1000))}s` },
      } }),
    });
    if (response.ok) return true;
    const body = await response.json().catch(() => ({}));
    const invalid = body.error?.details?.some(detail => detail.errorCode === 'UNREGISTERED');
    if (invalid) return false;
    // Do not log tokens, credentials, payloads, or message text.
    throw new Error(`FCM delivery failed (${response.status})`);
  };
}

export function createPushQueue(db, sender) {
  let inFlight;
  let stopped = false;
  async function drain() {
    if (!sender || inFlight || stopped) return;
    inFlight = (async () => {
      db.prepare('DELETE FROM push_outbox WHERE expires_at <= ?').run(Date.now());
      const rows = db.prepare(`SELECT p.* FROM push_outbox p
        JOIN devices d ON d.token = p.token JOIN sessions s ON s.token_hash = d.session_hash
        WHERE p.next_attempt <= ? AND s.expires_at > ? ORDER BY p.id LIMIT 20`).all(Date.now(), Date.now());
      for (const row of rows) {
        if (stopped) break;
        // Recheck after awaits: sign-out may have removed this device or event.
        if (!db.prepare('SELECT 1 FROM push_outbox WHERE id = ?').get(row.id)) continue;
        try {
          const valid = await sender(row.token, JSON.parse(row.payload), row.expires_at - Date.now());
          if (!valid) db.prepare('DELETE FROM devices WHERE token = ?').run(row.token);
          else db.prepare('DELETE FROM push_outbox WHERE id = ?').run(row.id);
        } catch (error) {
          console.error('Push delivery will retry:', error.message);
          db.prepare('UPDATE push_outbox SET attempts = attempts + 1, next_attempt = ? WHERE id = ?')
            .run(Date.now() + Math.min(60_000, 2000 * 2 ** Math.min(row.attempts, 5)), row.id);
        }
      }
    })();
    try { await inFlight; } finally { inFlight = null; }
  }
  const timer = setInterval(() => { void drain(); }, 2000);
  timer.unref();
  return {
    enabled: Boolean(sender),
    enqueue(userIds, data, ttl = 24 * 60 * 60 * 1000) {
      if (!sender) return;
      for (const userId of userIds) {
        const devices = db.prepare(`SELECT d.token FROM devices d JOIN sessions s ON s.token_hash = d.session_hash
          WHERE d.user_id = ? AND s.expires_at > ?`).all(userId, Date.now());
        for (const device of devices) {
          db.prepare('INSERT INTO push_outbox (token, payload, expires_at, next_attempt) VALUES (?, ?, ?, ?)')
            .run(device.token, JSON.stringify(data), Date.now() + ttl, Date.now());
        }
      }
      void drain();
    },
    async close() { stopped = true; clearInterval(timer); await inFlight; },
  };
}
