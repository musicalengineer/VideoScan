import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { RoundtableController, normalizeTurns } from "../src/roundtable-controller.mjs";

test("roundtable alternates with shared attributed transcript and stops at its budget", async () => {
  const rig = makeRig({ present: true });
  await rig.controller.start({ message: rig.initiator, topicTitle: "Architecture", turns: 4 });
  assert.deepEqual(rig.agents.codex.calls.map(call => call.options.instruction.includes("opening engineering view")), [true]);

  complete(rig, "codex", "Codex proposes a queue.");
  assert.equal(rig.controller.snapshot.status, "intervention");
  assert.equal(rig.scheduler.lastDelay, 8000);
  await rig.scheduler.fire();
  assert.equal(rig.agents.claude.calls.length, 1);
  assert.match(rig.agents.claude.calls[0].transcript, /Codex: Codex proposes a queue\./);

  complete(rig, "claude", "Claude challenges the queue.");
  await rig.scheduler.fire();
  assert.match(rig.agents.codex.calls[1].transcript, /Claude: Claude challenges the queue\./);
  complete(rig, "codex", "Codex narrows the proposal.");
  await rig.scheduler.fire();
  complete(rig, "claude", "Claude agrees with the bounded form.");

  assert.equal(rig.controller.snapshot.status, "completed");
  assert.equal(rig.controller.snapshot.completedTurns, 4);
  assert.equal(rig.agents.codex.calls.length, 2);
  assert.equal(rig.agents.claude.calls.length, 2);
  assert.match(rig.db.messages.at(-1).body, /completed its 4-turn budget/);
  assert.equal(rig.scheduler.pending, 0);
});

test("presence controls an injectable intervention delay and unattended mode stays bounded", async () => {
  const attended = makeRig({ present: true });
  await attended.controller.start({ message: attended.initiator, topicTitle: "Test", turns: 2 });
  complete(attended, "codex", "One.");
  assert.equal(attended.scheduler.lastDelay, 8000);

  const unattended = makeRig({ present: false });
  await unattended.controller.start({ message: unattended.initiator, topicTitle: "Test", turns: 2 });
  complete(unattended, "codex", "One.");
  assert.equal(unattended.scheduler.lastDelay, 250);
  await unattended.scheduler.fire();
  complete(unattended, "claude", "Two.");
  assert.equal(unattended.controller.snapshot.status, "completed");
  assert.equal(unattended.scheduler.pending, 0);
});

test("Stop and Rick interjection cancel scheduled or active continuation", async () => {
  const waiting = makeRig({ present: true });
  await waiting.controller.start({ message: waiting.initiator, topicTitle: "Test", turns: 6 });
  complete(waiting, "codex", "First.");
  assert.equal(waiting.scheduler.pending, 1);
  assert.equal(await waiting.controller.stop("Rick pressed Stop."), true);
  assert.equal(waiting.scheduler.pending, 0);
  await waiting.scheduler.fire();
  assert.equal(waiting.agents.claude.calls.length, 0);

  const active = makeRig({ present: true });
  await active.controller.start({ message: active.initiator, topicTitle: "Test", turns: 4 });
  assert.equal(await active.controller.interject(), true);
  assert.equal(active.agents.codex.interruptions, 1);
  assert.equal(active.controller.snapshot.status, "stopped");
});

test("agent errors stop visibly and ordinary agent events cannot start a loop", async () => {
  const rig = makeRig({ present: false });
  rig.agents.codex.emit("event", { type: "turn.completed", data: { provider: "codex", status: "completed" } });
  assert.equal(rig.agents.claude.calls.length, 0);

  await rig.controller.start({ message: rig.initiator, topicTitle: "Test", turns: 4 });
  rig.agents.codex.emit("event", { type: "room.error", data: { provider: "codex", message: "provider unavailable" } });
  assert.equal(rig.controller.snapshot.status, "error");
  assert.match(rig.db.messages.at(-1).body, /provider unavailable/);
  rig.agents.codex.emit("event", { type: "turn.completed", data: { provider: "codex", status: "completed" } });
  assert.equal(rig.agents.claude.calls.length, 0);
});

test("turn limits are validated with a hard cap and a new controller never resumes", async () => {
  assert.equal(normalizeTurns(undefined), 4);
  assert.equal(normalizeTurns(12), 12);
  assert.throws(() => normalizeTurns(1), /between 2 and 12/);
  assert.throws(() => normalizeTurns(13), /between 2 and 12/);
  assert.throws(() => normalizeTurns(2.5), /between 2 and 12/);

  const rig = makeRig({ present: false });
  await rig.controller.start({ message: rig.initiator, topicTitle: "Test", turns: 2 });
  assert.equal(rig.controller.active, true);
  const replacement = new RoundtableController({
    agents: { codex: new FakeAgent(), claude: new FakeAgent() }, database: rig.db,
    publish: () => {}, transcript: rig.transcript,
  });
  assert.equal(replacement.snapshot.status, "inactive");
  assert.equal(replacement.active, false);
});

function makeRig({ present }) {
  const db = new FakeDatabase();
  const initiator = db.createMessage({ topicId: "topic-1", author: "rick", body: "Discuss the safest architecture." });
  const agents = { codex: new FakeAgent(), claude: new FakeAgent() };
  const scheduler = new ManualScheduler();
  const transcript = (topicId, excludingId) => db.messages
    .filter(message => message.topicId === topicId && message.id !== excludingId)
    .map(message => `${({ rick: "Rick", codex: "Codex", claude: "Claude", system: "Room" })[message.author]}: ${message.body}`)
    .join("\n\n");
  const events = [];
  const controller = new RoundtableController({ agents, database: db, publish: (type, data) => events.push({ type, data }), transcript, presence: () => present, scheduler });
  return { db, initiator, agents, scheduler, transcript, events, controller };
}

function complete(rig, provider, body) {
  rig.db.createMessage({ topicId: rig.initiator.topicId, author: provider, body, replyTo: rig.initiator.id });
  rig.agents[provider].busy = false;
  rig.agents[provider].emit("event", { type: "turn.completed", data: { provider, status: "completed" } });
}

class FakeAgent extends EventEmitter {
  constructor() { super(); this.calls = []; this.busy = false; this.interruptions = 0; this.connection = "connected"; }
  get status() { return { connection: this.connection, busy: this.busy }; }
  async ask(message, topicTitle, transcript, options) { this.busy = true; this.calls.push({ message, topicTitle, transcript, options }); }
  async interrupt() { this.interruptions += 1; this.busy = false; return true; }
}

class FakeDatabase {
  constructor() { this.messages = []; this.next = 1; }
  snapshot() { return { topics: [], messages: [...this.messages] }; }
  createMessage(value) {
    const message = { id: `message-${this.next++}`, topicId: value.topicId ?? null, author: value.author, body: value.body, kind: value.kind ?? "message", replyTo: value.replyTo ?? null, createdAt: new Date().toISOString() };
    this.messages.push(message);
    return message;
  }
}

class ManualScheduler {
  constructor() { this.tasks = new Map(); this.next = 1; this.lastDelay = null; }
  get pending() { return this.tasks.size; }
  set(callback, delay) { const id = this.next++; this.lastDelay = delay; this.tasks.set(id, callback); return id; }
  clear(id) { this.tasks.delete(id); }
  async fire() { const entry = this.tasks.entries().next().value; if (!entry) return; const [id, callback] = entry; this.tasks.delete(id); await callback(); }
}
