import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp } from '../src/server.js';

test('production without Google credentials serves health but cannot sign in', async () => {
  const oldEnv = process.env.NODE_ENV;
  process.env.NODE_ENV = 'production';
  const dataDir = mkdtempSync(join(tmpdir(), 'aida-production-'));
  let app;
  try {
    app = createApp({ dataDir, googleClientId: '', secret: 'test-secret-with-at-least-thirty-two-characters' });
    await new Promise(resolve => app.server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${app.server.address().port}`;
    assert.equal((await fetch(`${base}/health`)).status, 200);
    const google = await fetch(`${base}/v1/auth/google`, { method: 'POST' });
    assert.equal(google.status, 503);
    for (const path of ['/v1/auth/start', '/v1/auth/verify']) {
      assert.equal((await fetch(base + path, { method: 'POST' })).status, 404);
    }
    assert.equal((await fetch(`${base}/v1/me`)).status, 401);
  } finally {
    if (app) await app.close();
    rmSync(dataDir, { recursive: true, force: true });
    if (oldEnv === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = oldEnv;
  }
});
