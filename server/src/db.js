import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export function openDatabase(path) {
  mkdirSync(dirname(path), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;');
  db.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      email TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      pair_id TEXT,
      created_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS sessions (
      token_hash TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id),
      expires_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS login_codes (
      email TEXT PRIMARY KEY,
      code_hash TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      sent_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS invites (
      code TEXT PRIMARY KEY,
      creator_id TEXT NOT NULL REFERENCES users(id),
      expires_at INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS pairs (
      id TEXT PRIMARY KEY,
      a_id TEXT NOT NULL REFERENCES users(id),
      b_id TEXT NOT NULL REFERENCES users(id),
      state TEXT NOT NULL CHECK (state IN ('active', 'closed')),
      created_at INTEGER NOT NULL,
      closed_at INTEGER
    );
    CREATE TABLE IF NOT EXISTS media (
      id TEXT PRIMARY KEY,
      pair_id TEXT NOT NULL REFERENCES pairs(id),
      sender_id TEXT NOT NULL REFERENCES users(id),
      mime TEXT NOT NULL,
      filename TEXT NOT NULL,
      size INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      pair_id TEXT NOT NULL REFERENCES pairs(id),
      sender_id TEXT NOT NULL REFERENCES users(id),
      client_id TEXT,
      kind TEXT NOT NULL CHECK (kind IN ('text', 'image', 'video')),
      text TEXT,
      media_id TEXT REFERENCES media(id),
      created_at INTEGER NOT NULL,
      UNIQUE(sender_id, client_id)
    );
    CREATE INDEX IF NOT EXISTS messages_by_pair ON messages(pair_id, id);
    CREATE TABLE IF NOT EXISTS calls (
      id TEXT PRIMARY KEY,
      pair_id TEXT NOT NULL REFERENCES pairs(id),
      initiator_id TEXT NOT NULL REFERENCES users(id),
      kind TEXT NOT NULL CHECK (kind IN ('voice', 'video')),
      state TEXT NOT NULL CHECK (state IN ('ringing', 'active', 'ended', 'declined')),
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS calls_by_pair ON calls(pair_id, updated_at);
    CREATE TABLE IF NOT EXISTS room_cleanup (
      id TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS topics (
      id TEXT PRIMARY KEY,
      pair_id TEXT NOT NULL REFERENCES pairs(id),
      name TEXT NOT NULL COLLATE NOCASE,
      created_at INTEGER NOT NULL,
      UNIQUE(pair_id, name)
    );
    CREATE TABLE IF NOT EXISTS receipts (
      pair_id TEXT NOT NULL REFERENCES pairs(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id),
      topic_id TEXT NOT NULL,
      delivered_through INTEGER NOT NULL DEFAULT 0,
      read_through INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (pair_id, user_id, topic_id)
    );
    CREATE TABLE IF NOT EXISTS devices (
      token TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id),
      session_hash TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS push_outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      token TEXT NOT NULL REFERENCES devices(token) ON DELETE CASCADE,
      payload TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      next_attempt INTEGER NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0
    );
  `);
  // Existing local databases from the email-code preview need this column.
  const columns = db.prepare('PRAGMA table_info(users)').all();
  if (!columns.some(column => column.name === 'google_sub')) {
    db.exec('ALTER TABLE users ADD COLUMN google_sub TEXT');
  }
  if (!columns.some(column => column.name === 'last_seen_at')) {
    db.exec('ALTER TABLE users ADD COLUMN last_seen_at INTEGER');
  }
  db.exec('CREATE UNIQUE INDEX IF NOT EXISTS users_google_sub ON users(google_sub)');
  // Additive migration: v1 messages, sessions, users, and pair IDs stay intact.
  const messageColumns = db.prepare('PRAGMA table_info(messages)').all();
  if (!messageColumns.some(column => column.name === 'topic_id')) {
    db.exec("ALTER TABLE messages ADD COLUMN topic_id TEXT NOT NULL DEFAULT 'general'");
  }
  db.exec('CREATE INDEX IF NOT EXISTS messages_by_topic ON messages(pair_id, topic_id, id)');
  // Additive migration: replies reference an earlier message in the same pair and topic.
  if (!messageColumns.some(column => column.name === 'reply_to_id')) {
    db.exec('ALTER TABLE messages ADD COLUMN reply_to_id INTEGER');
  }
  // Additive migration: edits, deletions, reactions, and keeps change existing
  // messages; updated_seq orders those changes so clients can catch up.
  if (!messageColumns.some(column => column.name === 'updated_seq')) {
    db.exec('ALTER TABLE messages ADD COLUMN updated_seq INTEGER NOT NULL DEFAULT 0');
  }
  if (!messageColumns.some(column => column.name === 'edited_at')) {
    db.exec('ALTER TABLE messages ADD COLUMN edited_at INTEGER');
  }
  if (!messageColumns.some(column => column.name === 'deleted_at')) {
    db.exec('ALTER TABLE messages ADD COLUMN deleted_at INTEGER');
  }
  db.exec(`
    CREATE INDEX IF NOT EXISTS messages_by_change ON messages(pair_id, topic_id, updated_seq);
    CREATE TABLE IF NOT EXISTS reactions (
      message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
      pair_id TEXT NOT NULL REFERENCES pairs(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id),
      emoji TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (message_id, user_id)
    );
    CREATE TABLE IF NOT EXISTS kept (
      message_id INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
      pair_id TEXT NOT NULL REFERENCES pairs(id) ON DELETE CASCADE,
      user_id TEXT NOT NULL REFERENCES users(id),
      created_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS kept_by_pair ON kept(pair_id, created_at);
  `);
  return db;
}

export function transaction(db, action) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = action();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
}
