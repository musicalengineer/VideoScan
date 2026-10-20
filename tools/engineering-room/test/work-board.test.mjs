import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RoomDatabase } from "../src/database.mjs";
import { ControlPlane } from "../src/control-plane.mjs";
import { WorkBoard, readReviewCycles, readSchedule, scheduleAt } from "../src/work-board.mjs";

const NOW = "2026-10-20T17:00:00.000Z";
const REQUEST = { requestId: "630df9c2-d792-42f3-a60d-70f974274001", title: "Review catalog refactor",
  objective: "Read selected folder and report findings at this revision.", manager: "claude", machine: "none" };

function fixture(t, { cycles = [], processAlive } = {}) {
  const repoRoot = mkdtempSync(join(tmpdir(), "videoscan-work-board-"));
  const toolRoot = join(repoRoot, "tools", "engineering-room");
  mkdirSync(toolRoot, { recursive: true });
  const path = join(repoRoot, "review-cycles.json");
  writeFileSync(path, JSON.stringify(cycles));
  utimesSync(path, new Date(NOW), new Date(NOW));
  let now = new Date(NOW);
  const database = new RoomDatabase(join(repoRoot, "board.sqlite3"));
  t.after(() => database.close());
  const controlPlane = new ControlPlane({ database, repoRoot, toolRoot, clock: () => new Date(now), channelExportsEnabled: false });
  const board = new WorkBoard({ controlPlane, repoRoot, reviewCyclesPath: path, clock: () => new Date(now), ...(processAlive ? { processAlive } : {}) });
  return { repoRoot, toolRoot, path, database, controlPlane, board, advance(seconds) { now = new Date(now.getTime() + seconds * 1000); },
    read: options => readReviewCycles({ path, repoRoot, now: new Date(now), ...options }) };
}

function counts(database) {
  return ["cp_tasks", "cp_directives", "cp_events", "messages", "cp_channel_exports"].map(table => database.db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n);
}

test("review phase uses live PID evidence and never promotes a dead or missing process", async t => {
  const rig = fixture(t, { cycles: [
    { id: 1, title: "Active", phase: "running", phaseSince: NOW, pid: process.pid },
    { id: 2, title: "Exited", phase: "running", phaseSince: NOW, pid: 2147483647 },
    { id: 3, title: "Missing PID", phase: "running", phaseSince: NOW },
    { id: 4, title: "Bad PID", phase: "running", phaseSince: NOW, pid: "123" },
    { id: 5, title: "Interactive review brief", phase: "briefed", phaseSince: NOW },
  ] });
  const before = readFileSync(rig.path, "utf8");
  const reviews = await rig.read();
  assert.equal(reviews.status, "ok");
  const byTitle = Object.fromEntries(reviews.items.map(item => [item.title, item]));
  assert.equal(byTitle.Active.effectiveState, "running");
  assert.equal(byTitle.Active.processAlive, true);
  for (const title of ["Exited", "Missing PID", "Bad PID"]) {
    assert.equal(byTitle[title].effectiveState, "not-reporting", title);
    assert.notEqual(byTitle[title].processAlive, true, title);
  }
  assert.equal(byTitle["Interactive review brief"].effectiveState, "briefed");
  assert.equal(byTitle["Interactive review brief"].processAlive, null);
  assert.equal(readFileSync(rig.path, "utf8"), before, "reading reviews must never mutate runner state");
});

test("missing, malformed, non-file and oversized review state fail closed without private-path leaks", async t => {
  const rig = fixture(t);
  const missing = await rig.read({ path: join(rig.repoRoot, "PRIVATE-MISSING") });
  assert.equal(missing.status, "missing");
  assert.deepEqual(missing.items, []);
  assert.equal(missing.error.includes(rig.repoRoot), false);
  const directory = await rig.read({ path: rig.repoRoot });
  assert.equal(directory.status, "error");
  assert.match(directory.error, /regular file/);
  for (const content of ["{invalid PRIVATE-TOKEN", "null", "42", '{"cycles":{}}']) {
    writeFileSync(rig.path, content);
    const result = await rig.read();
    assert.equal(result.status, "error");
    assert.match(result.error, /malformed/);
    assert.equal(result.error.includes("PRIVATE-TOKEN"), false);
    assert.deepEqual(result.items, []);
  }
  writeFileSync(rig.path, " ".repeat(2 * 1024 * 1024 + 1));
  const oversized = await rig.read();
  assert.equal(oversized.status, "error");
  assert.match(oversized.error, /2 MiB/);
  assert.deepEqual(oversized.items, []);
});

test("review snapshot limits newest records to 20 before probing processes", async t => {
  const cycles = Array.from({ length: 1000 }, (_, i) => ({ id: i + 1, title: `Review ${i + 1}`, phase: "running", pid: i + 1, phaseSince: NOW }));
  const rig = fixture(t, { cycles: { cycles } });
  const checked = [];
  const result = await rig.read({ processAlive(pid) { checked.push(pid); return true; } });
  assert.equal(result.total, 1000);
  assert.equal(result.omitted, 980);
  assert.equal(result.items.length, 20);
  assert.deepEqual(result.items.map(item => item.id), Array.from({ length: 20 }, (_, i) => 1000 - i));
  assert.deepEqual(checked, result.items.map(item => item.id));
});

test("review metadata retains verdict zero-findings and exposes stale or malformed evidence honestly", async t => {
  const rig = fixture(t, { cycles: [null, 12, [],
    { id: 1, title: "Closed", phase: "closed", findings: 0, verdict: "Merge", tokens: 1200, doc: "/private/secret-folder/review.md" },
    { id: 2, title: "Old fixes", phase: "fixing", phaseSince: "2026-10-20T14:00:00Z", findings: 2, doc: "docs/reviews/notes.md" },
    { id: 3, title: "Future phase", phase: "made-up", phaseSince: "nonsense", findings: "0", tokens: -1 },
  ] });
  utimesSync(rig.path, new Date("2026-10-18T12:00:00Z"), new Date("2026-10-18T12:00:00Z"));
  const result = await rig.read();
  assert.equal(result.status, "ok");
  assert.equal(result.total, 3);
  assert.match(result.error, /3 malformed review records/);
  assert.equal(result.stale, true);
  const closed = result.items.find(item => item.id === 1);
  assert.equal(closed.findings, 0);
  assert.equal(closed.verdict, "Merge");
  assert.equal(closed.stale, false);
  assert.equal(closed.document, "review.md");
  assert.equal(result.items.find(item => item.id === 2).document, "docs/reviews/notes.md");
  assert.equal(result.items.find(item => item.id === 2).stale, true);
  const unknown = result.items.find(item => item.id === 3);
  assert.equal(unknown.effectiveState, "unknown");
  assert.equal(unknown.ageSeconds, null);
  assert.equal(unknown.findings, null);
  assert.equal(unknown.tokens, null);
});

test("work board preserves live sessions, decisions and queued requests without inventing activity", async t => {
  const rig = fixture(t);
  const task = rig.board.enqueue(REQUEST).task;
  const worker = rig.controlPlane.registerAgent({ manager: "claude", agent: "testing/live", sessionId: "live-session", state: "idle", leaseSeconds: 60 });
  rig.controlPlane.claimTask({ taskId: task.id, agentId: worker.id, sessionId: "live-session", leaseSeconds: 60 });
  rig.controlPlane.recordDecision({ id: "open-decision", question: "Accept current scope?", taskId: task.id, owner: "rick", source: "control-plane-api" });
  rig.controlPlane.recordDecision({ id: "closed-decision", question: "Old question", status: "decided", owner: "rick", source: "control-plane-api" });
  let snapshot = await rig.board.snapshot();
  assert.equal(snapshot.controlPlane.summary.reportingAgents, 1);
  assert.equal(snapshot.controlPlane.summary.workingTasks, 1);
  assert.equal(snapshot.controlPlane.summary.openDecisions, 1);
  assert.equal(snapshot.controlPlane.tasks.find(item => item.id === task.id).effectiveState, "working");
  assert.deepEqual(snapshot.controlPlane.decisions.map(item => item.id), ["open-decision"]);
  rig.advance(61);
  snapshot = await rig.board.snapshot();
  assert.equal(snapshot.controlPlane.summary.reportingAgents, 0);
  assert.equal(snapshot.controlPlane.summary.workingTasks, 0);
  assert.equal(snapshot.controlPlane.agents[0].effectiveState, "not-reporting");
  assert.equal(snapshot.controlPlane.tasks[0].effectiveState, "not-reporting");
});

test("retired sources and unleased working records cannot imply an active current session", async t => {
  const rig = fixture(t);
  for (const source of ["reconstruction-seed", "agent-status-jsonl", "docs/team-channel/old.md"]) {
    rig.controlPlane.upsertTask({ id: `old-${source}`, title: "POISON historical working", machine: "m5", state: "working", source });
  }
  rig.controlPlane.createTask({ id: "unleased", title: "No worker evidence", machine: "none", state: "working" });
  const snapshot = await rig.board.snapshot();
  assert.equal(snapshot.controlPlane.tasks.length, 1);
  assert.equal(snapshot.controlPlane.tasks[0].effectiveState, "not-reporting");
  assert.equal(snapshot.controlPlane.summary.workingTasks, 0);
  assert.equal(snapshot.controlPlane.summary.omittedHistorical, 3);
  assert.equal(JSON.stringify(snapshot).includes("POISON"), false);
});

test("queue retries retain one task and directive after claim and completion, rejecting changed payload", t => {
  const rig = fixture(t);
  const first = rig.board.enqueue(REQUEST);
  const before = counts(rig.database);
  assert.equal(first.reused, false);
  assert.equal(first.task.state, "queued");
  assert.equal(rig.board.enqueue(REQUEST).reused, true);
  assert.deepEqual(counts(rig.database), before);
  for (const overrides of [{ title: "Changed" }, { objective: "Changed" }, { manager: "codex" }, { machine: "m5" }]) {
    assert.throws(() => rig.board.enqueue({ ...REQUEST, ...overrides }), error => error.statusCode === 409);
  }
  const worker = rig.controlPlane.registerAgent({ manager: "claude", agent: "testing/retry", sessionId: "retry-session", state: "idle" });
  rig.controlPlane.claimTask({ taskId: first.task.id, agentId: worker.id, sessionId: "retry-session" });
  assert.equal(rig.board.enqueue(REQUEST).task.state, "working");
  rig.controlPlane.completeTask({ taskId: first.task.id, agentId: worker.id, sessionId: "retry-session", result: "Read, no findings." });
  assert.equal(rig.board.enqueue(REQUEST).task.state, "done");
  assert.equal(rig.controlPlane.managerQueue("claude").length, 0);
  assert.equal(rig.database.db.prepare("SELECT COUNT(*) AS n FROM cp_directives").get().n, 1);
});

test("interrupted queue creation rolls back fully so unchanged retry creates one complete request", t => {
  const rig = fixture(t);
  const before = counts(rig.database);
  const original = rig.database.createMessage;
  rig.database.createMessage = () => { throw new Error("Injected persistence failure"); };
  assert.throws(() => rig.board.enqueue(REQUEST), /Injected persistence failure/);
  assert.deepEqual(counts(rig.database), before);
  rig.database.createMessage = original;
  const retry = rig.board.enqueue(REQUEST);
  assert.equal(retry.task.state, "queued");
  assert.equal(rig.controlPlane.managerQueue("claude").length, 1);
  assert.equal(rig.controlPlane.managerQueue("claude")[0].taskId, retry.task.id);
});

test("invalid work requests cannot mutate tasks, messages or channel outbox", t => {
  const rig = fixture(t);
  const before = counts(rig.database);
  for (const payload of [null, [], {}, { ...REQUEST, requestId: "not-a-uuid" }, { ...REQUEST, title: " " },
    { ...REQUEST, title: "x".repeat(501) }, { ...REQUEST, objective: "" }, { ...REQUEST, objective: "x".repeat(8001) },
    { ...REQUEST, machine: undefined }, { ...REQUEST, machine: "m5Ultra" }, { ...REQUEST, manager: "qwen" }]) {
    assert.throws(() => rig.board.enqueue(payload), error => error.statusCode === 400);
    assert.deepEqual(counts(rig.database), before);
  }
});

test("synthetic schedule uses Eastern time and never grants an M4 quiet window", () => {
  const markdown = "Timezone: America/New_York\n## Typical day\n- 09:00–10:00 — Synthetic fixture activity\n- 22:00–02:00 — Synthetic overnight activity\n## Notes\n- 10:00–11:00 — Not part of schedule\n";
  const winter = scheduleAt(new Date("2026-12-20T14:30:00Z"), markdown);
  const summer = scheduleAt(new Date("2026-07-20T13:30:00Z"), markdown);
  assert.equal(winter.localTime, "09:30");
  assert.equal(summer.localTime, "09:30");
  assert.equal(winter.currentActivity, "Synthetic fixture activity");
  assert.equal(winter.blocks.length, 2);
  assert.equal(scheduleAt(new Date("2026-12-21T06:00:00Z"), markdown).currentActivity, "Synthetic overnight activity");
  assert.equal(winter.presence, "unknown");
  assert.match(winter.machinePolicy, /explicitly declares a quiet window/);
});

test("local schedule reads are bounded and fail honestly when missing, malformed or oversized", async t => {
  const rig = fixture(t);
  const path = join(rig.repoRoot, "synthetic-schedule.local.md");
  const now = new Date("2026-12-20T14:30:00Z");
  const missing = await readSchedule({ path, now });
  assert.equal(missing.status, "missing");
  assert.equal(missing.presence, "unknown");
  assert.deepEqual(missing.blocks, []);
  writeFileSync(path, "Timezone: Invalid/Zone\n## Typical day\n- 09:00–10:00 — Synthetic fixture activity\n- 25:00–26:00 — Invalid block\n");
  const valid = await readSchedule({ path, now });
  assert.equal(valid.status, "ok");
  assert.equal(valid.timeZone, "America/New_York");
  assert.equal(valid.currentActivity, "Synthetic fixture activity");
  assert.equal(valid.blocks.length, 1);
  assert.ok(valid.lastUpdatedAt);
  writeFileSync(path, "Malformed PRIVATE-SCHEDULE content");
  const malformed = await readSchedule({ path, now });
  assert.equal(malformed.status, "unavailable");
  assert.deepEqual(malformed.blocks, []);
  assert.equal(malformed.error.includes("PRIVATE-SCHEDULE"), false);
  writeFileSync(path, "x".repeat(64 * 1024 + 1));
  const oversized = await readSchedule({ path, now });
  assert.equal(oversized.status, "error");
  assert.deepEqual(oversized.blocks, []);
  assert.equal(oversized.error.includes(path), false);
  const directory = await readSchedule({ path: rig.repoRoot, now });
  assert.equal(directory.status, "error");
});

test("completed work exposes its full persisted result including findings after the progress preview", async t => {
  const rig = fixture(t);
  const task = rig.board.enqueue(REQUEST).task;
  const worker = rig.controlPlane.registerAgent({ manager: "claude", agent: "testing/results", sessionId: "result-session", state: "idle" });
  rig.controlPlane.claimTask({ taskId: task.id, agentId: worker.id, sessionId: "result-session" });
  const result = "Validation detail. ".repeat(120) + " FINAL: 2 FAILURES; EVIDENCE: docs/reviews/failure.md";
  rig.controlPlane.completeTask({ taskId: task.id, agentId: worker.id, sessionId: "result-session", result });
  const completed = (await rig.board.snapshot()).controlPlane.tasks.find(item => item.id === task.id);
  assert.equal(completed.result, result);
  assert.match(completed.result, /FINAL: 2 FAILURES/);
  assert.equal(completed.resultTruncated, false);
  assert.equal(completed.resultOmitted, false);
});

test("completion results are bounded to the newest 50 and explicitly mark oversized legacy evidence", async t => {
  const rig = fixture(t);
  for (let i = 0; i < 52; i += 1) {
    const ts = new Date(Date.parse(NOW) + i * 1000).toISOString();
    rig.controlPlane.upsertTask({ id: `historic-result-${i}`, title: `Historical result ${i}`, state: "done", machine: "none", source: "control-plane-api", ts, priority: i === 0 ? 999 : 0 });
    rig.controlPlane.recordEvent({ kind: "task.completed", taskId: `historic-result-${i}`, source: "test", ts,
      payload: { result: i === 51 ? "x".repeat(33000) : `Result ${i}` } });
  }
  const tasks = (await rig.board.snapshot()).controlPlane.tasks;
  assert.equal(tasks.filter(task => task.result !== null).length, 50);
  for (const id of ["historic-result-0", "historic-result-1"]) {
    assert.equal(tasks.find(task => task.id === id).resultOmitted, true);
    assert.equal(tasks.find(task => task.id === id).result, null);
  }
  const oversized = tasks.find(task => task.id === "historic-result-51");
  assert.equal(oversized.result.length, 32768);
  assert.equal(oversized.resultTruncated, true);
  assert.equal(oversized.resultOmitted, false);
});
