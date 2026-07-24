import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RoomDatabase } from "../src/database.mjs";
import { ControlPlane } from "../src/control-plane.mjs";

test("transport ingestion reconstructs honest board state idempotently", () => {
  const rig = fixture("2026-07-17T16:00:00.000Z");
  writeFileSync(join(rig.toolRoot, "config", "control-plane-reconstruction.json"), JSON.stringify({
    tasks: [{ id: "unknown-task", title: "Unknown historical session", state: "not-reporting", source: "seed" }],
    agents: [{ manager: "codex", agent: "unknown", state: "not-reporting", taskId: "unknown-task", source: "seed", evidence: "No heartbeat", ts: "2026-07-17T15:00:00Z" }],
  }));
  writeFileSync(join(rig.toolRoot, "var", "agent-status.jsonl"), [
    JSON.stringify({ ts: "2026-07-17T15:55:00Z", manager: "claude", agent: "bug-fix/trim", state: "working", task: "Fix trim", progress: "patching" }),
    JSON.stringify({ ts: "2026-07-17T15:59:00Z", manager: "claude", agent: "bug-fix/trim", state: "done", task: "Fix trim complete", progress: "green", machine: "m5" }),
    JSON.stringify({ ts: "2026-07-17T15:58:00Z", manager: "claude", agent: "qa/trim", state: "done", task: "QA trim", progress: "3 majors" }),
  ].join("\n"));
  writeFileSync(join(rig.repoRoot, "docs", "team-channel", "2026-07-17-1200-claude-note.md"), "---\nfrom: claude\nto: codex\nre: trim\ndate: 2026-07-17T12:00:00-04:00\n---\n\nTrim evidence.\n");

  assert.ok(rig.control.ingestAll() > 0);
  const first = rig.control.board();
  assert.equal(first.agents.find(agent => agent.id === "claude/bug-fix/trim").effectiveState, "done");
  assert.equal(first.agents.find(agent => agent.id === "claude/qa/trim").effectiveState, "done");
  assert.equal(first.agents.find(agent => agent.id === "codex/unknown").effectiveState, "not-reporting");
  assert.equal(first.tasks.find(task => task.title === "Fix trim complete").ownerAgentId, "claude/bug-fix/trim");
  assert.equal(first.tasks.find(task => task.title === "Fix trim complete").machine, "m5");
  assert.equal(first.tasks.some(task => task.title === "Fix trim" && task.state === "working"), false);
  const eventCount = first.events.length;
  assert.equal(rig.control.ingestAll(), 0);
  assert.equal(rig.control.board().events.length, eventCount);
  rig.close();
});

test("registration, task leases, heartbeats, and expiry fail honestly", () => {
  const rig = fixture("2026-07-17T16:00:00.000Z");
  const task = rig.control.createTask({ id: "task-one", title: "Build control plane", manager: "codex", machine: "none", actor: "rick" });
  const agent = rig.control.registerAgent({ manager: "codex", agent: "worker-1", sessionId: "session-a", state: "idle", leaseSeconds: 60 });
  const claimed = rig.control.claimTask({ taskId: task.id, agentId: agent.id, sessionId: "session-a", leaseSeconds: 60 });
  assert.equal(claimed.task.state, "working");
  assert.throws(() => rig.control.heartbeat({ agentId: agent.id, sessionId: "wrong" }), /does not own/);
  rig.advance(30);
  rig.control.heartbeat({ agentId: agent.id, sessionId: "session-a", state: "working", progress: "halfway", leaseSeconds: 60 });
  assert.equal(rig.control.getAgent(agent.id).progress, "halfway");
  assert.equal(rig.database.db.prepare("SELECT expires_at FROM cp_leases WHERE id=?").get(`task:${task.id}`).expires_at, "2026-07-17T16:01:30.000Z");
  rig.advance(61);
  assert.equal(rig.control.expireLeases(), 2);
  const board = rig.control.board();
  assert.equal(board.agents.find(item => item.id === agent.id).effectiveState, "not-reporting");
  assert.equal(board.tasks.find(item => item.id === task.id).state, "not-reporting");
  assert.ok(board.events.some(event => event.kind === "agent.not-reporting"));
  rig.close();
});

test("status feed cannot displace an explicitly leased worker session", () => {
  const rig = fixture("2026-07-17T16:00:00.000Z");
  const task = rig.control.createTask({ id: "formal-grade", title: "Formal grade", manager: "codex", machine: "m4" });
  const agent = rig.control.registerAgent({
    manager: "codex", agent: "testing/grader", sessionId: "explicit-session",
    state: "idle", leaseSeconds: 60,
  });
  rig.control.claimTask({ taskId: task.id, agentId: agent.id, sessionId: "explicit-session", leaseSeconds: 60 });
  rig.advance(5);
  writeFileSync(join(rig.toolRoot, "var", "agent-status.jsonl"), JSON.stringify({
    ts: "2026-07-17T16:00:05.000Z", manager: "codex", agent: "testing/grader",
    state: "working", task: "Legacy feed description", progress: "feed heartbeat", machine: "m4",
  }));

  assert.ok(rig.control.ingestAll() > 0);
  const current = rig.control.getAgent(agent.id);
  assert.equal(current.sessionId, "explicit-session");
  assert.equal(current.taskId, task.id);
  assert.equal(current.source, "control-plane-api");
  assert.equal(rig.control.getTask(task.id).state, "working");
  assert.equal(rig.control.getTask(`feed:${shortAgentHash(agent.id)}`), null);
  assert.ok(rig.control.board().events.some(event => event.kind === "status.reported" && event.agentId === agent.id));
  rig.control.heartbeat({ agentId: agent.id, sessionId: "explicit-session", state: "working", progress: "still owns lease" });
  rig.close();
});

test("room directive queues, leases, heartbeats, and automatically posts worker result", () => {
  const rig = fixture("2026-07-17T16:00:00.000Z");
  const topic = rig.database.snapshot().topics[0];
  const created = rig.control.createDirective({ id: "directive-task", title: "Read-only evaluation", objective: "Run unchanged production evaluator.", manager: "codex", machine: "m5", topicId: topic.id, actor: "rick" });
  assert.equal(created.task.state, "queued");
  assert.equal(created.task.machine, "m5");
  assert.equal(rig.control.managerQueue("codex")[0].machine, "m5");
  assert.match(created.message.body, /Machine: m5/);
  assert.equal(rig.control.managerQueue("codex")[0].taskState, "queued");
  const worker = rig.control.registerAgent({ manager: "codex", agent: "testing/eval", sessionId: "worker-session", state: "idle" });
  rig.control.claimTask({ taskId: created.task.id, agentId: worker.id, sessionId: "worker-session", leaseSeconds: 60 });
  rig.control.heartbeat({ agentId: worker.id, sessionId: "worker-session", state: "working", taskState: "working", progress: "5/10 evaluated", leaseSeconds: 60 });
  assert.equal(rig.control.managerQueue("codex")[0].taskState, "working");
  const completed = rig.control.completeTask({ taskId: created.task.id, agentId: worker.id, sessionId: "worker-session", result: "TP=8 FN=2 FP=1 TN=9" });
  assert.equal(completed.task.state, "done");
  assert.equal(completed.directive.status, "completed");
  assert.equal(rig.control.managerQueue("codex").length, 0);
  assert.match(completed.message.body, /Worker result — codex\/testing\/eval[\s\S]*TP=8/);
  assert.equal(completed.channelDelivery.status, "delivered");
  assert.equal(completed.channelDelivery.author, "codex");
  assert.equal(completed.channelDelivery.recipient, "claude");
  assert.match(readFileSync(join(rig.repoRoot, completed.channelDelivery.path), "utf8"), /from: codex[\s\S]*to: claude[\s\S]*TP=8/);
  assert.equal(rig.database.snapshot().messages.some(message => message.id === completed.message.id), true);
  const kinds = rig.control.board().events.filter(event => event.taskId === created.task.id).map(event => event.kind);
  assert.ok(kinds.includes("directive.queued"));
  assert.ok(kinds.includes("task.claimed"));
  assert.ok(kinds.includes("task.completed"));
  rig.close();
});

test("completion channel delivery retries across restart without duplicate room or channel posts", () => {
  const unavailable = Object.assign(new Error("channel filesystem unavailable"), { code: "EACCES" });
  const rig = fixture("2026-07-17T16:00:00.000Z", { writeChannelFile() { throw unavailable; } });
  const topic = rig.database.snapshot().topics[0];
  const created = rig.control.createDirective({ id: "retryable-result", title: "Grade C1", objective: "Return sealed grade.", manager: "codex", machine: "none", topicId: topic.id });
  const worker = rig.control.registerAgent({ manager: "codex", agent: "testing/grader", sessionId: "grade-session", state: "idle" });
  rig.control.claimTask({ taskId: created.task.id, agentId: worker.id, sessionId: "grade-session", leaseSeconds: 60 });
  const first = rig.control.completeTask({ taskId: created.task.id, agentId: worker.id, sessionId: "grade-session", result: "C1 FAIL: balanced accuracy 0.500" });
  assert.equal(first.task.state, "done");
  assert.equal(first.directive.status, "completed");
  assert.equal(first.channelDelivery.status, "pending");
  assert.equal(first.channelDelivery.attempts, 1);
  const resultMessageId = first.message.id;
  const databasePath = join(rig.toolRoot, "var", "room.sqlite3");
  rig.close();

  const database = new RoomDatabase(databasePath);
  const restarted = new ControlPlane({ database, repoRoot: rig.repoRoot, toolRoot: rig.toolRoot, clock: () => new Date("2026-07-17T16:01:00.000Z") });
  const filesAfterRestart = readdirSync(join(rig.repoRoot, "docs", "team-channel")).filter(name => name.endsWith(".md"));
  assert.equal(filesAfterRestart.length, 1);
  const retried = restarted.completeTask({ taskId: created.task.id, agentId: worker.id, sessionId: "grade-session", result: "C1 FAIL: balanced accuracy 0.500" });
  assert.equal(retried.message.id, resultMessageId);
  assert.equal(retried.channelDelivery.status, "delivered");
  assert.equal(retried.channelDelivery.attempts, 2);
  assert.equal(readdirSync(join(rig.repoRoot, "docs", "team-channel")).filter(name => name.endsWith(".md")).length, 1);
  assert.equal(database.snapshot().messages.filter(message => /Worker result/.test(message.body)).length, 1);
  assert.equal(database.db.prepare("SELECT COUNT(*) AS count FROM cp_events WHERE kind='channel.exported' AND task_id=?").get(created.task.id).count, 1);
  assert.throws(() => restarted.completeTask({ taskId: created.task.id, agentId: worker.id, sessionId: "grade-session", result: "C1 PASS" }), /different result/);
  database.close();
});

test("direct CLI task completion posts to both the room and attributed team channel", () => {
  const rig = fixture("2026-07-17T16:00:00.000Z");
  const task = rig.control.createTask({ id: "cli-grade", title: "C1 sealed grade", objective: "Grade frozen candidate.", manager: "codex", machine: "none" });
  const worker = rig.control.registerAgent({ manager: "codex", agent: "testing/c01", sessionId: "c01-session", state: "idle" });
  rig.control.claimTask({ taskId: task.id, agentId: worker.id, sessionId: "c01-session", leaseSeconds: 60 });
  const completed = rig.control.completeTask({ taskId: task.id, agentId: worker.id, sessionId: "c01-session", result: "FAIL — balanced accuracy 0.500" });
  assert.match(completed.message.body, /Worker result — codex\/testing\/c01/);
  assert.equal(completed.message.topicId, rig.database.snapshot().topics[0].id);
  assert.equal(completed.channelDelivery.status, "delivered");
  assert.match(readFileSync(join(rig.repoRoot, completed.channelDelivery.path), "utf8"), /from: codex[\s\S]*to: claude[\s\S]*balanced accuracy 0.500/);
  const retry = rig.control.completeTask({ taskId: task.id, agentId: worker.id, sessionId: "c01-session", result: "FAIL — balanced accuracy 0.500" });
  assert.equal(retry.message.id, completed.message.id);
  assert.equal(readdirSync(join(rig.repoRoot, "docs", "team-channel")).filter(name => name.endsWith(".md")).length, 1);
  rig.close();
});

test("context digests, decisions, briefs, standups, and channel export are durable", () => {
  const rig = fixture("2026-07-17T16:00:00.000Z");
  const task = rig.control.createTask({ id: "accuracy", title: "Donna aggregation", objective: "Beat always-yes baseline", manager: "codex", machine: "none" });
  rig.control.recordDecision({ id: "decision:gate", taskId: task.id, question: "Adopt F1 gate?", owner: "rick", source: "test" });
  rig.control.updateTask(task.id, { state: "blocked", progress: "baseline measured", blockedOn: "needs Rick: choose gate", actor: "codex" });
  const digest = rig.control.refreshTaskDigest(task.id);
  assert.match(digest.digest, /Beat always-yes baseline/);
  assert.match(digest.digest, /Machine: none/);
  assert.match(digest.digest, /Adopt F1 gate/);

  const brief = rig.control.generateRoomBrief();
  assert.match(brief.digest, /Engineering Room Brief/);
  assert.match(brief.digest, /needs Rick: choose gate/);
  const standup = rig.control.generateStandup({ date: "2026-07-17" });
  assert.match(standup.digest, /VideoScan Daily Standup/);
  assert.match(standup.digest, /Blockers \/ waiting on human/);
  assert.match(standup.digest, /Adopt F1 gate/);

  const exported = rig.control.exportTeamChannel({ from: "codex", to: "claude", re: "brief", slug: "room-brief", body: brief.digest });
  assert.match(exported.path, /^docs\/team-channel\//);
  assert.match(readFileSync(join(rig.repoRoot, exported.path), "utf8"), /from: codex[\s\S]*Engineering Room Brief/);
  assert.ok(rig.control.latestBrief());
  assert.equal(rig.control.latestStandup().date, "2026-07-17");
  const seatBrief = rig.control.seatBrief("claude");
  assert.match(seatBrief, /Verified Team Board snapshot/);
  assert.match(seatBrief, /Adopt F1 gate/);
  assert.match(seatBrief, /Manager-channel messages/);
  assert.match(seatBrief, /Never infer liveness/);
  rig.control.recordEvent({ kind: "large.evidence", source: "test", actor: "codex", payload: { body: "x".repeat(10_000) } });
  const compact = rig.control.board().events.find(event => event.kind === "large.evidence");
  assert.match(compact.payload.summary, /^\{"body":"x+/);
  assert.equal(compact.payload.truncated, true);
  assert.equal(compact.payload.originalBytes, 10_011);
  assert.equal(JSON.parse(rig.database.db.prepare("SELECT payload_json FROM cp_events WHERE kind='large.evidence'").get().payload_json).body.length, 10_000);
  rig.close();
});

test("new task dispatch requires a valid explicit machine route", () => {
  const rig = fixture("2026-07-17T16:00:00.000Z");
  assert.throws(() => rig.control.createTask({ id: "missing-route", title: "Missing route" }), /machine is required/);
  assert.throws(() => rig.control.createTask({ id: "bad-route", title: "Bad route", machine: "m2" }), /machine must be/);
  const task = rig.control.createTask({ id: "headless", title: "Headless test", machine: "NONE" });
  assert.equal(task.machine, "none");
  rig.close();
});

function fixture(initialIso, options = {}) {
  const root = mkdtempSync(join(tmpdir(), "engineering-room-control-plane-"));
  const repoRoot = join(root, "repo");
  const toolRoot = join(repoRoot, "tools", "engineering-room");
  mkdirSync(join(toolRoot, "var"), { recursive: true });
  mkdirSync(join(toolRoot, "config"), { recursive: true });
  mkdirSync(join(repoRoot, "docs", "team-channel"), { recursive: true });
  let now = new Date(initialIso);
  const database = new RoomDatabase(join(toolRoot, "var", "room.sqlite3"));
  const control = new ControlPlane({ database, repoRoot, toolRoot, clock: () => new Date(now), ...options });
  return {
    repoRoot, toolRoot, database, control,
    advance(seconds) { now = new Date(now.getTime() + seconds * 1000); },
    close() { database.close(); },
  };
}

function shortAgentHash(value) {
  return createHash("sha256").update(value).digest("hex").slice(0, 16);
}
