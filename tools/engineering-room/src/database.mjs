import { DatabaseSync } from "node:sqlite";
import { chmodSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { randomUUID } from "node:crypto";

export class RoomDatabase {
  constructor(path) {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    chmodSync(dirname(path), 0o700);
    this.db = new DatabaseSync(path);
    chmodSync(path, 0o600);
    this.db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;");
    this.migrate();
  }

  migrate() {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS topics (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'parked', 'done')),
        position INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        topic_id TEXT REFERENCES topics(id),
        author TEXT NOT NULL CHECK(author IN ('rick', 'codex', 'system')),
        kind TEXT NOT NULL DEFAULT 'message' CHECK(kind IN ('message', 'status', 'error')),
        body TEXT NOT NULL,
        created_at TEXT NOT NULL,
        reply_to TEXT REFERENCES messages(id)
      );
      CREATE TABLE IF NOT EXISTS agent_sessions (
        provider TEXT PRIMARY KEY,
        external_thread_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS turns (
        id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        request_message_id TEXT NOT NULL REFERENCES messages(id),
        external_turn_id TEXT,
        status TEXT NOT NULL,
        started_at TEXT NOT NULL,
        completed_at TEXT
      );
      CREATE INDEX IF NOT EXISTS messages_created_idx ON messages(created_at, id);
      CREATE INDEX IF NOT EXISTS messages_topic_idx ON messages(topic_id, created_at);
    `);

    const count = this.db.prepare("SELECT COUNT(*) AS count FROM topics").get().count;
    if (count === 0) {
      this.createTopic("Topics of the day");
      this.createTopic("Lounge");
    }
  }

  close() { this.db.close(); }

  snapshot() {
    return {
      topics: this.db.prepare("SELECT * FROM topics ORDER BY position, created_at").all().map(mapTopic),
      messages: this.db.prepare("SELECT * FROM messages ORDER BY created_at, id").all().map(mapMessage),
    };
  }

  createTopic(title) {
    const now = new Date().toISOString();
    const topic = {
      id: randomUUID(), title: title.trim(), status: "active",
      position: Number(this.db.prepare("SELECT COALESCE(MAX(position), -1) + 1 AS next FROM topics").get().next),
      createdAt: now, updatedAt: now,
    };
    this.db.prepare("INSERT INTO topics(id,title,status,position,created_at,updated_at) VALUES(?,?,?,?,?,?)")
      .run(topic.id, topic.title, topic.status, topic.position, now, now);
    return topic;
  }

  updateTopic(id, patch) {
    const current = this.db.prepare("SELECT * FROM topics WHERE id = ?").get(id);
    if (!current) return null;
    const title = patch.title === undefined ? current.title : patch.title.trim();
    const status = patch.status === undefined ? current.status : patch.status;
    const position = patch.position === undefined ? current.position : patch.position;
    const updatedAt = new Date().toISOString();
    this.db.prepare("UPDATE topics SET title=?, status=?, position=?, updated_at=? WHERE id=?")
      .run(title, status, position, updatedAt, id);
    return mapTopic(this.db.prepare("SELECT * FROM topics WHERE id = ?").get(id));
  }

  createMessage({ topicId = null, author, body, kind = "message", replyTo = null }) {
    const message = { id: randomUUID(), topicId, author, body, kind, replyTo, createdAt: new Date().toISOString() };
    this.db.prepare("INSERT INTO messages(id,topic_id,author,kind,body,created_at,reply_to) VALUES(?,?,?,?,?,?,?)")
      .run(message.id, topicId, author, kind, body, message.createdAt, replyTo);
    return message;
  }

  getSession(provider) {
    return this.db.prepare("SELECT external_thread_id AS externalThreadId FROM agent_sessions WHERE provider=?").get(provider) ?? null;
  }

  setSession(provider, externalThreadId) {
    const now = new Date().toISOString();
    this.db.prepare(`
      INSERT INTO agent_sessions(provider,external_thread_id,created_at,updated_at) VALUES(?,?,?,?)
      ON CONFLICT(provider) DO UPDATE SET external_thread_id=excluded.external_thread_id, updated_at=excluded.updated_at
    `).run(provider, externalThreadId, now, now);
  }

  createTurn(requestMessageId) {
    const turn = { id: randomUUID(), provider: "codex", requestMessageId, status: "starting", startedAt: new Date().toISOString() };
    this.db.prepare("INSERT INTO turns(id,provider,request_message_id,status,started_at) VALUES(?,?,?,?,?)")
      .run(turn.id, turn.provider, requestMessageId, turn.status, turn.startedAt);
    return turn;
  }

  reconcileIncompleteTurns() {
    const completedAt = new Date().toISOString();
    const result = this.db.prepare("UPDATE turns SET status='failed', completed_at=? WHERE status IN ('starting','inProgress')").run(completedAt);
    return Number(result.changes);
  }

  updateTurn(id, { externalTurnId = null, status }) {
    const completedAt = ["completed", "failed", "interrupted"].includes(status) ? new Date().toISOString() : null;
    this.db.prepare("UPDATE turns SET external_turn_id=COALESCE(?,external_turn_id), status=?, completed_at=? WHERE id=?")
      .run(externalTurnId, status, completedAt, id);
  }
}

function mapTopic(row) {
  return { id: row.id, title: row.title, status: row.status, position: Number(row.position), createdAt: row.created_at, updatedAt: row.updated_at };
}

function mapMessage(row) {
  return { id: row.id, topicId: row.topic_id, author: row.author, kind: row.kind, body: row.body, createdAt: row.created_at, replyTo: row.reply_to };
}
