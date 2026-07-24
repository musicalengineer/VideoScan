import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { RoundtableController, buildCompactAutopilotContext, normalizeDeadline, normalizeTokenBudget, normalizeTurns } from "../src/roundtable-controller.mjs";

test("Autopilot completes an unattended six-turn attributed alternating exchange", async () => {
  const rig = makeRig({ present: false });
  await enableAndStart(rig, 6);

  for (let index = 0; index < 6; index += 1) {
    const provider = index % 2 === 0 ? "codex" : "claude";
    complete(rig, provider, `${provider} reply ${index + 1}.`, index % 2 ? "question" : "evidence", `${provider} delta ${index + 1}`);
    if (index < 5) await rig.scheduler.fireNext();
  }

  assert.equal(rig.controller.snapshot.status, "completed");
  assert.equal(rig.controller.snapshot.completedTurns, 6);
  assert.deepEqual(rig.callsInOrder, ["codex", "claude", "codex", "claude", "codex", "claude"]);
  assert.ok([...rig.agents.codex.calls, ...rig.agents.claude.calls].every(call => call.options.freshContext === true));
  const replies = rig.db.messages.filter(message => ["codex", "claude"].includes(message.author));
  assert.deepEqual(replies.map(message => message.author), ["codex", "claude", "codex", "claude", "codex", "claude"]);
  assert.ok(replies.every(message => message.providerResponseId?.startsWith("provider-response-")));
  assert.match(rig.db.messages.at(-1).body, /Final summary[\s\S]*Open decisions/);
  assert.equal(rig.scheduler.pending, 0);
});

test("Autopilot must be explicitly enabled and disabling it stops an active run", async () => {
  const rig = makeRig({ present: false });
  await assert.rejects(() => rig.controller.start(startArguments(rig, 2)), /Enable Autopilot/);
  await rig.controller.setEnabled(true);
  await rig.controller.start(startArguments(rig, 2));
  assert.equal(rig.controller.active, true);
  await rig.controller.setEnabled(false);
  assert.equal(rig.controller.snapshot.enabled, false);
  assert.equal(rig.controller.snapshot.status, "stopped");
  assert.equal(rig.agents.codex.interruptions, 1);
});

test("presence changes only the intervention delay and Stop cancels continuation", async () => {
  const attended = makeRig({ present: true });
  await enableAndStart(attended, 4);
  complete(attended, "codex", "One.", "decision", "Use one queue");
  assert.equal(attended.scheduler.smallestDelay, 8000);
  assert.equal(await attended.controller.stop("Rick pressed Stop."), true);
  assert.equal(attended.scheduler.pending, 0);
  assert.equal(attended.agents.claude.calls.length, 0);
});

test("loop protection stops after two consecutive empty semantic deltas", async () => {
  const rig = makeRig({ present: false });
  await enableAndStart(rig, 8);
  complete(rig, "codex", "Nothing material yet.", null, null);
  assert.equal(rig.controller.snapshot.emptyDeltas, 1);
  await rig.scheduler.fireNext();
  complete(rig, "claude", "Still nothing material.", null, null);
  assert.equal(rig.controller.snapshot.status, "loop-stopped");
  assert.equal(rig.controller.snapshot.completedTurns, 2);
  assert.match(rig.db.messages.at(-1).body, /two turns added no decision/);
});

test("empty-delta circuit breaker wins when the same turn also crosses provider-cost budget", async () => {
  const rig = makeRig({ present: false });
  await rig.controller.setEnabled(true);
  await rig.controller.start({ ...startArguments(rig, 8), tokenBudget: 256 });
  complete(rig, "codex", "No progress.", null, null, 300, 10);
  assert.equal(rig.controller.snapshot.status, "intervention", "first empty delta gets one circuit-breaker probe despite exceeded provider cost");
  await rig.scheduler.fireNext();
  complete(rig, "claude", "Still no progress.", null, null, 200, 10);
  assert.equal(rig.controller.snapshot.providerCostTokens, 500);
  assert.equal(rig.controller.snapshot.status, "loop-stopped");
  assert.match(rig.controller.snapshot.reason, /two turns added no decision/);
});

test("legacy consumedTokens state migrates to provider-cost tokens", () => {
  const rig = makeRig({ present: false });
  rig.db.setState("autopilot.enabled", true);
  rig.db.setState("autopilot.run", { status: "budget-stopped", consumedTokens: 4321, generatedTokens: 123 });
  const replacement = new RoundtableController({ agents: rig.agents, database: rig.db, publish: () => {}, transcript: rig.transcript });
  assert.equal(replacement.snapshot.providerCostTokens, 4321);
  assert.equal(replacement.snapshot.consumedTokens, 4321);
  assert.equal(replacement.snapshot.generatedTokens, 123);
});

test("compact context contains run state and recent turns but excludes unrelated room history", () => {
  const messages = [
    { id: "old", replyTo: "different-run", author: "codex", body: "UNRELATED HISTORICAL TRANSCRIPT" },
    ...Array.from({ length: 6 }, (_, index) => ({ id: `reply-${index}`, replyTo: "run-1", author: index % 2 ? "claude" : "codex", body: `Run response ${index + 1}` })),
  ];
  const context = buildCompactAutopilotContext({
    initiatorMessageId: "run-1", objective: "Resolve scoring.",
    summary: ["Codex: Adopt interval coverage."], openDecisions: ["Claude: Decide excess-duration penalty."],
  }, messages);
  assert.match(context, /Objective:\nResolve scoring\./);
  assert.match(context, /Running summary:[\s\S]*Adopt interval coverage/);
  assert.match(context, /Recent turns:[\s\S]*Run response 3[\s\S]*Run response 6/);
  assert.doesNotMatch(context, /Run response [12]/);
  assert.match(context, /Open decisions:[\s\S]*excess-duration penalty/);
  assert.doesNotMatch(context, /UNRELATED HISTORICAL TRANSCRIPT/);
  assert.ok(context.length < 12000);
});

test("persisted active state safely recovers with the correct next provider", async () => {
  const rig = makeRig({ present: false });
  await enableAndStart(rig, 4);
  complete(rig, "codex", "First.", "evidence", "First fact");

  const recoveredAgents = { codex: new FakeAgent("codex", []), claude: new FakeAgent("claude", []) };
  const recovered = new RoundtableController({
    agents: recoveredAgents, database: rig.db, publish: () => {}, transcript: rig.transcript,
    presence: () => false, scheduler: new ManualScheduler(),
  });
  assert.equal(await recovered.recover(), true);
  assert.equal(recovered.snapshot.currentProvider, "claude");
  assert.equal(recoveredAgents.claude.calls.length, 1);
});

test("limits reject unsafe values", () => {
  assert.equal(normalizeTurns(undefined), 6);
  assert.equal(normalizeTurns(100), 100);
  assert.throws(() => normalizeTurns(1), /between 2 and 100/);
  assert.throws(() => normalizeTurns(101), /between 2 and 100/);
  assert.equal(normalizeTokenBudget(256), 256);
  assert.throws(() => normalizeTokenBudget(255), /between 256/);
  assert.throws(() => normalizeDeadline(new Date(Date.now() - 1).toISOString()), /future/);
});

async function enableAndStart(rig, turns) {
  await rig.controller.setEnabled(true);
  await rig.controller.start(startArguments(rig, turns));
}

function startArguments(rig, turns) {
  return {
    message: rig.initiator, topicTitle: "Architecture", objective: "Resolve the safest architecture.", turns,
    tokenBudget: 12000, deadlineAt: new Date(Date.now() + 60_000).toISOString(),
  };
}

function makeRig({ present }) {
  const db = new FakeDatabase();
  const initiator = db.createMessage({ topicId: "topic-1", author: "rick", body: "Autopilot objective: Resolve the safest architecture." });
  const callsInOrder = [];
  const agents = { codex: new FakeAgent("codex", callsInOrder), claude: new FakeAgent("claude", callsInOrder) };
  const scheduler = new ManualScheduler();
  const transcript = (topicId, excludingId) => db.messages
    .filter(message => message.topicId === topicId && message.id !== excludingId)
    .map(message => `${({ rick: "Rick", codex: "Codex", claude: "Claude", system: "Room" })[message.author]}: ${message.body}`)
    .join("\n\n");
  const events = [];
  const controller = new RoundtableController({ agents, database: db, publish: (type, data) => events.push({ type, data }), transcript, presence: () => present, scheduler });
  return { db, initiator, agents, scheduler, transcript, events, controller, callsInOrder };
}

function complete(rig, provider, body, deltaKind, deltaDetail, providerCostTokenCount = 100, generatedTokenCount = 20) {
  const providerResponseId = `provider-response-${rig.db.next}`;
  rig.db.createMessage({ topicId: rig.initiator.topicId, author: provider, body, replyTo: rig.initiator.id, providerResponseId, deltaKind, deltaDetail });
  rig.agents[provider].busy = false;
  rig.agents[provider].emit("event", { type: "turn.completed", data: { provider, status: "completed", providerResponseId, tokenCount: providerCostTokenCount, providerCostTokenCount, generatedTokenCount, tokenCountEstimated: false, semanticDelta: { kind: deltaKind, detail: deltaDetail } } });
}

class FakeAgent extends EventEmitter {
  constructor(provider, callsInOrder) { super(); this.provider = provider; this.callsInOrder = callsInOrder; this.calls = []; this.busy = false; this.interruptions = 0; this.connection = "connected"; }
  get status() { return { connection: this.connection, busy: this.busy }; }
  async ask(message, topicTitle, transcript, options) { this.busy = true; this.callsInOrder.push(this.provider); this.calls.push({ message, topicTitle, transcript, options }); }
  async interrupt() { this.interruptions += 1; this.busy = false; return true; }
}

class FakeDatabase {
  constructor() { this.messages = []; this.state = new Map(); this.next = 1; }
  snapshot() { return { topics: [], messages: [...this.messages] }; }
  createMessage(value) {
    const message = {
      id: `message-${this.next++}`, topicId: value.topicId ?? null, author: value.author, body: value.body,
      kind: value.kind ?? "message", replyTo: value.replyTo ?? null, providerResponseId: value.providerResponseId ?? null,
      deltaKind: value.deltaKind ?? null, deltaDetail: value.deltaDetail ?? null, createdAt: new Date().toISOString(),
    };
    this.messages.push(message);
    return message;
  }
  getState(key, fallback = null) { return this.state.has(key) ? structuredClone(this.state.get(key)) : fallback; }
  setState(key, value) { this.state.set(key, structuredClone(value)); }
}

class ManualScheduler {
  constructor() { this.tasks = new Map(); this.next = 1; }
  get pending() { return this.tasks.size; }
  get smallestDelay() { return Math.min(...[...this.tasks.values()].map(task => task.delay)); }
  set(callback, delay) { const id = this.next++; this.tasks.set(id, { callback, delay }); return id; }
  clear(id) { this.tasks.delete(id); }
  async fireNext() {
    const entry = [...this.tasks.entries()].sort((a, b) => a[1].delay - b[1].delay)[0];
    if (!entry) return;
    const [id, task] = entry; this.tasks.delete(id); await task.callback();
  }
}
