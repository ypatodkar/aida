// Run inside the API container before and after deploying an additive migration.
// Saves hashes only, never user data or session tokens. Removes the check file on success.
const { DatabaseSync } = require('node:sqlite');
const { createHash } = require('node:crypto');
const { writeFileSync, readFileSync, unlinkSync } = require('node:fs');
const db = new DatabaseSync('/app/data/aida.sqlite', { readOnly: true });
const queries = {
  users: 'SELECT id,email,name,pair_id,created_at,google_sub FROM users',
  sessions: 'SELECT token_hash,user_id,expires_at FROM sessions',
  pairs: 'SELECT * FROM pairs',
  messages: 'SELECT id,pair_id,sender_id,client_id,kind,text,media_id,created_at,topic_id FROM messages',
  topics: 'SELECT * FROM topics',
  media: 'SELECT * FROM media',
};
const current = Object.fromEntries(Object.entries(queries).map(([table, query]) => [table,
  db.prepare(query).all().map(row => createHash('sha256').update(JSON.stringify(row)).digest('hex'))]));
const path = '/app/data/.v2-preservation-check.json';
if (process.env.CHECK_MODE === 'before') {
  writeFileSync(path, JSON.stringify(current), { mode: 0o600 });
  console.log('Pre-upgrade record counts:', Object.fromEntries(Object.entries(current).map(([k,v]) => [k,v.length])));
} else {
  const before = JSON.parse(readFileSync(path));
  for (const [table, rows] of Object.entries(before)) {
    const after = new Set(current[table]);
    if (!rows.every(row => after.has(row))) throw new Error('Existing records changed in ' + table);
  }
  if (db.prepare('PRAGMA foreign_key_check').all().length) throw new Error('Foreign key check failed');
  unlinkSync(path);
  console.log('Every pre-upgrade user, session, pairing, message, topic, and media record is intact.');
}
db.close();
