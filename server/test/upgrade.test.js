import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openDatabase } from '../src/db.js';

test('v1 database upgrades twice without losing users, pairing, sessions, or messages', () => {
  const dir = mkdtempSync(join(tmpdir(), 'aida-upgrade-'));
  const path = join(dir, 'db.sqlite');
  let db;
  try {
    db = openDatabase(path);
    db.exec(`DROP INDEX messages_by_topic; ALTER TABLE messages DROP COLUMN topic_id;
      DROP TABLE receipts; ALTER TABLE users DROP COLUMN last_seen_at; DROP TABLE topics; DROP TABLE push_outbox; DROP TABLE devices;
      INSERT INTO users (id,email,name,pair_id,created_at) VALUES ('a','a@test.com','A','pair',1),('b','b@test.com','B','pair',1);
      INSERT INTO pairs (id,a_id,b_id,state,created_at) VALUES ('pair','a','b','active',1);
      INSERT INTO sessions VALUES ('existing-session-hash','a',9999999999999);
      INSERT INTO messages (pair_id,sender_id,client_id,kind,text,created_at) VALUES ('pair','a','old-message','text','Keep this message',1);`);
    db.close(); db = null;
    for (let i = 0; i < 2; i++) {
      db = openDatabase(path);
      assert.equal(db.prepare('SELECT pair_id FROM users WHERE id = ?').get('a').pair_id, 'pair');
      assert.equal(db.prepare('SELECT state FROM pairs').get().state, 'active');
      assert.equal(db.prepare('SELECT token_hash FROM sessions').get().token_hash, 'existing-session-hash');
      const message = db.prepare('SELECT * FROM messages').get();
      assert.equal(message.id, 1);
      assert.equal(message.text, 'Keep this message');
      assert.equal(message.topic_id, 'general');
      assert.equal(db.prepare('SELECT last_seen_at FROM users LIMIT 1').get().last_seen_at, null);
      assert.equal(db.prepare('SELECT COUNT(*) AS n FROM receipts').get().n, 0);
      assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
      db.close(); db = null;
    }
  } finally {
    db?.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
