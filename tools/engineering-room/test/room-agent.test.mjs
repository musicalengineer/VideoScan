import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RoomDatabase } from "../src/database.mjs";
import { RoomAgent } from "../src/room-agent.mjs";

class FakeClient extends EventEmitter {
  constructor(mode) { super(); this.mode = mode; this.interruptions = 0; this.resolveStart = null; this.startThreadCalls = 0; this.lastPrompt = null; }
  async connect() { this.emit("connection", { state: "connected" }); }
  async startThread() { this.startThreadCalls += 1; return `thread-${this.startThreadCalls}`; }
  async resumeThread(id) { return id; }
  async startTurn(threadId, prompt) {
    this.lastPrompt = prompt;
    if (this.mode === "delayed-start") return await new Promise(resolve => { this.resolveStart = resolve; });
    if (this.mode === "same-chunk") {
      this.emit("notification", { method: "item/agentMessage/delta", params: { threadId, turnId: "turn-1", delta: "Race-safe reply." } });
      this.emit("notification", { method: "turn/completed", params: { threadId, turn: { id: "turn-1", status: "completed", usage: { input_tokens: 80, output_tokens: 20, cache_read_input_tokens: 10 }, items: [{ type: "agentMessage", text: "Race-safe reply.", phase: "final_answer" }] } } });
    }
    return "turn-1";
  }
  async interrupt() { this.interruptions += 1; }
}

function fixture(mode) {
  const db = new RoomDatabase(join(mkdtempSync(join(tmpdir(), "engineering-room-agent-")), "room.sqlite3"));
  const client = new FakeClient(mode);
  const agent = new RoomAgent({ client, database: db });
  return { db, client, agent };
}

test("buffers completion notifications that arrive before turn/start resolves", async () => {
  const { db, agent } = fixture("same-chunk");
  await agent.initialize();
  const topic = db.snapshot().topics[0];
  const request = db.createMessage({ topicId: topic.id, author: "rick", body: "Test the race." });
  await agent.ask(request, topic.title);
  assert.equal(agent.status.busy, false);
  assert.equal(db.snapshot().messages.find(message => message.author === "codex").body, "Race-safe reply.");
  const turn = db.db.prepare("SELECT status, token_count, generated_token_count FROM turns").get();
  assert.equal(turn.status, "completed");
  assert.equal(turn.token_count, 110, "provider-cost tokens include input, output, and cache usage");
  assert.equal(turn.generated_token_count, 20, "generated output is tracked separately");
  db.close();
});

test("fresh-context turns start an isolated provider thread", async () => {
  const { db, client, agent } = fixture("same-chunk");
  await agent.initialize();
  const topic = db.snapshot().topics[0];
  const request = db.createMessage({ topicId: topic.id, author: "rick", body: "Use compact context." });
  await agent.ask(request, topic.title, "Compact run state.", { freshContext: true });
  assert.equal(client.startThreadCalls, 2, "initial room thread plus isolated Autopilot thread");
  assert.equal(agent.status.busy, false);
  db.close();
});

test("broker injects verified board and channel context into a room seat", async () => {
  const { db, client, agent } = fixture("same-chunk");
  await agent.initialize();
  const topic = db.snapshot().topics[0];
  const request = db.createMessage({ topicId: topic.id, author: "rick", body: "Report the team." });
  await agent.ask(request, topic.title, "Room transcript.", { roomBrief: "Verified Team Board: claude/worker is not-reporting." });
  assert.match(client.lastPrompt, /Broker-supplied shared control-plane context/);
  assert.match(client.lastPrompt, /claude\/worker is not-reporting/);
  db.close();
});

test("a Codex disconnect fails and clears the active turn", async () => {
  const { db, client, agent } = fixture("wait");
  await agent.initialize();
  const topic = db.snapshot().topics[0];
  const request = db.createMessage({ topicId: topic.id, author: "rick", body: "Stay responsive." });
  await agent.ask(request, topic.title);
  assert.equal(agent.status.busy, true);
  client.emit("connection", { state: "disconnected", error: "simulated crash" });
  assert.equal(agent.status.busy, false);
  assert.equal(db.db.prepare("SELECT status FROM turns").get().status, "failed");
  db.close();
});

test("startup reconciles turns abandoned by an earlier process", async () => {
  const { db, agent } = fixture("wait");
  const topic = db.snapshot().topics[0];
  const request = db.createMessage({ topicId: topic.id, author: "rick", body: "Before restart." });
  db.createTurn(request.id);
  await agent.initialize();
  assert.equal(db.db.prepare("SELECT status FROM turns").get().status, "failed");
  assert.match(db.snapshot().messages.find(message => message.author === "system").body, /unfinished Codex turn/);
  db.close();
});

test("Stop during provider startup latches cancellation and suppresses the late response", async () => {
  const { db, client, agent } = fixture("delayed-start");
  await agent.initialize();
  const topic = db.snapshot().topics[0];
  const request = db.createMessage({ topicId: topic.id, author: "rick", body: "Stop this startup race." });
  const asking = agent.ask(request, topic.title);
  assert.equal(agent.status.busy, true);
  assert.equal(await agent.interrupt(), true);
  client.resolveStart("turn-delayed");
  await asking;
  client.emit("notification", { method: "turn/completed", params: { turn: { id: "turn-delayed", status: "completed", items: [{ type: "agentMessage", text: "Must not appear.", phase: "final_answer" }] } } });
  assert.equal(client.interruptions, 1);
  assert.equal(agent.status.busy, false);
  assert.equal(db.snapshot().messages.some(message => message.body === "Must not appear."), false);
  assert.equal(db.db.prepare("SELECT status FROM turns").get().status, "interrupted");
  db.close();
});
