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
      CREATE TABLE IF NOT EXISTS room_state (
        key TEXT PRIMARY KEY,
        value_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS messages_created_idx ON messages(created_at, id);
      CREATE INDEX IF NOT EXISTS messages_topic_idx ON messages(topic_id, created_at);
    `);

    // `speaker` is additive so existing v1 databases keep their constrained
    // author column intact while v2 can attribute Claude distinctly.
    const columns = this.db.prepare("PRAGMA table_info(messages)").all();
    if (!columns.some(column => column.name === "speaker")) {
      this.db.exec("ALTER TABLE messages ADD COLUMN speaker TEXT");
    }
    if (!columns.some(column => column.name === "provider_response_id")) {
      this.db.exec("ALTER TABLE messages ADD COLUMN provider_response_id TEXT");
    }
    if (!columns.some(column => column.name === "delta_kind")) {
      this.db.exec("ALTER TABLE messages ADD COLUMN delta_kind TEXT");
    }
    if (!columns.some(column => column.name === "delta_detail")) {
      this.db.exec("ALTER TABLE messages ADD COLUMN delta_detail TEXT");
    }
    this.db.exec("CREATE UNIQUE INDEX IF NOT EXISTS messages_provider_response_idx ON messages(provider_response_id) WHERE provider_response_id IS NOT NULL");

    const turnColumns = this.db.prepare("PRAGMA table_info(turns)").all();
    if (!turnColumns.some(column => column.name === "token_count")) {
      this.db.exec("ALTER TABLE turns ADD COLUMN token_count INTEGER NOT NULL DEFAULT 0");
    }
    if (!turnColumns.some(column => column.name === "generated_token_count")) {
      this.db.exec("ALTER TABLE turns ADD COLUMN generated_token_count INTEGER NOT NULL DEFAULT 0");
    }

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

  createMessage({ topicId = null, author, body, kind = "message", replyTo = null, providerResponseId = null, deltaKind = null, deltaDetail = null }) {
    const storedAuthor = author === "claude" ? "system" : author;
    const message = { id: randomUUID(), topicId, author, body, kind, replyTo, providerResponseId, deltaKind, deltaDetail, createdAt: new Date().toISOString() };
    this.db.prepare("INSERT INTO messages(id,topic_id,author,speaker,kind,body,created_at,reply_to,provider_response_id,delta_kind,delta_detail) VALUES(?,?,?,?,?,?,?,?,?,?,?)")
      .run(message.id, topicId, storedAuthor, author, kind, body, message.createdAt, replyTo, providerResponseId, deltaKind, deltaDetail);
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

  createTurn(requestMessageId, provider = "codex") {
    const turn = { id: randomUUID(), provider, requestMessageId, status: "starting", startedAt: new Date().toISOString() };
    this.db.prepare("INSERT INTO turns(id,provider,request_message_id,status,started_at) VALUES(?,?,?,?,?)")
      .run(turn.id, turn.provider, requestMessageId, turn.status, turn.startedAt);
    return turn;
  }

  reconcileIncompleteTurns(provider = "codex") {
    const completedAt = new Date().toISOString();
    const result = this.db.prepare("UPDATE turns SET status='failed', completed_at=? WHERE provider=? AND status IN ('starting','inProgress')").run(completedAt, provider);
    return Number(result.changes);
  }

  updateTurn(id, { externalTurnId = null, status, tokenCount = 0, generatedTokenCount = 0 }) {
    const completedAt = ["completed", "failed", "interrupted"].includes(status) ? new Date().toISOString() : null;
    this.db.prepare("UPDATE turns SET external_turn_id=COALESCE(?,external_turn_id), status=?, token_count=?, generated_token_count=?, completed_at=? WHERE id=?")
      .run(externalTurnId, status, tokenCount, generatedTokenCount, completedAt, id);
  }

  getState(key, fallback = null) {
    const row = this.db.prepare("SELECT value_json AS valueJson FROM room_state WHERE key=?").get(key);
    if (!row) return fallback;
    try { return JSON.parse(row.valueJson); } catch { return fallback; }
  }

  setState(key, value) {
    const now = new Date().toISOString();
    this.db.prepare(`
      INSERT INTO room_state(key,value_json,updated_at) VALUES(?,?,?)
      ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=excluded.updated_at
    `).run(key, JSON.stringify(value), now);
  }
}

function mapTopic(row) {
  return { id: row.id, title: row.title, status: row.status, position: Number(row.position), createdAt: row.created_at, updatedAt: row.updated_at };
}

function mapMessage(row) {
  return {
    id: row.id, topicId: row.topic_id, author: row.speaker ?? row.author, kind: row.kind,
    body: row.body, createdAt: row.created_at, replyTo: row.reply_to,
    providerResponseId: row.provider_response_id ?? null,
    deltaKind: row.delta_kind ?? null, deltaDetail: row.delta_detail ?? null,
  };
}
