import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RoomDatabase } from "../src/database.mjs";
import { ControlPlane } from "../src/control-plane.mjs";
import { MetricsRefresh, validateRequest, trackedSourceFolders, metricsDocument } from "../src/metrics-refresh.mjs";

const folders = ["VideoScan/VideoScan/Hallie", "tools/engineering-room", "tests"];
const request = overrides => ({ requestId: "refresh-test-001", machine: "m5", areas: ["tests"], ...overrides });

function fixture(t) {
  const repoRoot = mkdtempSync(join(tmpdir(), "metrics-refresh-tests-"));
  const toolRoot = join(repoRoot, "tools", "engineering-room");
  const database = new RoomDatabase(join(repoRoot, "room.sqlite3"));
  const controlPlane = new ControlPlane({ database, repoRoot, toolRoot,
    statusFeed: join(repoRoot, "missing-feed"), reconstructionSeed: join(repoRoot, "missing-seed"),
    teamChannel: join(repoRoot, "team-channel"), clock: () => new Date("2026-10-20T12:00:00.000Z") });
  t.after(() => database.close());
  return { database, controlPlane, refresh: new MetricsRefresh({ controlPlane, repoRoot, listFolders: () => folders }) };
}

function counts(database) {
  return Object.fromEntries(["cp_tasks", "cp_directives", "cp_events", "messages"].map(table =>
    [table, database.db.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get().count]));
}

test("capabilities expose explicit machine routing and unavailable future hardware", t => {
  const { refresh } = fixture(t);
  const { capabilities, requests } = refresh.snapshot();
  assert.equal(capabilities.execution, "manager-queue");
  assert.deepEqual(capabilities.machines.map(m => [m.id, m.available]), [["m4", true], ["m5", true], ["m5Ultra", false]]);
  assert.deepEqual(capabilities.machines[0].requiresQuietWindowFor, ["tests", "hallie"]);
  assert.deepEqual(capabilities.areas, ["tests", "code", "hallie", "reviews"]);
  assert.deepEqual(capabilities.folders, folders);
  assert.deepEqual(requests, []);
});

test("selected tests normalize deterministically and retain revision, folder, and manager", () => {
  assert.deepEqual(validateRequest(request({ areas: ["reviews", "tests", "code", "tests"],
    testScope: "selected", testSelectors: "VideoScanTests/PairTests, tests/test_metrics_dashboard.py\nVideoScanTests/PairTests",
    folder: folders[0], revision: "feature/scoped-metrics", manager: "claude" }), folders), {
    machine: "m5", areas: ["tests", "code", "reviews"], testScope: "selected",
    testSelectors: "VideoScanTests/PairTests\ntests/test_metrics_dashboard.py", folder: folders[0],
    revision: "feature/scoped-metrics", manager: "claude", quietWindow: false,
  });
  assert.equal(validateRequest(request({ folder: "." }), folders).folder, "");
  assert.equal(validateRequest(request(), folders).revision, "working-tree");
});

test("M4 tests and Hallie require a boolean quiet-window declaration; headless code/review do not", () => {
  for (const areas of [["tests"], ["hallie"], ["code", "hallie"]]) {
    assert.throws(() => validateRequest(request({ machine: "m4", areas }), folders), /quiet window/);
    assert.throws(() => validateRequest(request({ machine: "m4", areas, quietWindow: "true" }), folders), /boolean/);
    assert.equal(validateRequest(request({ machine: "m4", areas, quietWindow: true }), folders).quietWindow, true);
  }
  assert.equal(validateRequest(request({ machine: "m4", areas: ["code", "reviews"] }), folders).machine, "m4");
});

test("invalid requests have no queue, event, or message side effects", t => {
  const { refresh, database } = fixture(t);
  const before = counts(database);
  const invalid = [null, [], {}, request({ machine: "m5Ultra" }), request({ machine: "none" }),
    request({ areas: [] }), request({ areas: ["shell"] }), request({ manager: "qwen" }),
    request({ folder: "../private" }), request({ folder: "/Users/rickb" }), request({ folder: "untracked" }),
    request({ revision: "HEAD;touch /tmp/pwn" }), request({ revision: "--help" }), request({ revision: "main..HEAD" }),
    request({ testScope: "selected" }), request({ testScope: "unknown" }), request({ testSelectors: "PairTests" }),
    request({ testScope: "selected", testSelectors: "$(touch /tmp/pwn)" }),
    request({ testScope: "selected", testSelectors: "PairTests\u0000Extra" }),
    request({ testScope: "selected", testSelectors: Array.from({ length: 41 }, (_, i) => `Suite${i}`).join(",") }),
    request({ requestId: "x" }), request({ requestId: "valid-id;bad" }), request({ quietWindow: 1 })];
  for (const input of invalid) {
    assert.throws(() => refresh.enqueue(input), error => error.statusCode === 400, JSON.stringify(input));
    assert.deepEqual(counts(database), before, JSON.stringify(input));
  }
});

test("same request ID queues once and rejects a retry with changed scope", t => {
  const { refresh, database, controlPlane } = fixture(t);
  const input = request({ areas: ["code", "reviews"], manager: "claude", folder: folders[0] });
  const first = refresh.enqueue(input);
  const afterFirst = counts(database);
  assert.equal(first.accepted, true);
  assert.equal(first.queued, true);
  assert.equal(first.reused, false);
  assert.equal(first.task.state, "queued");
  assert.equal(first.task.resultSummary, null);
  assert.equal(first.task.machine, "m5");
  assert.equal(controlPlane.managerQueue("claude").length, 1);
  assert.equal(controlPlane.managerQueue("codex").length, 0);
  const retry = refresh.enqueue(input);
  assert.equal(retry.reused, true);
  assert.equal(retry.task.id, first.task.id);
  assert.deepEqual(counts(database), afterFirst);
  assert.throws(() => refresh.enqueue({ ...input, folder: "tests" }), error => error.statusCode === 409);
  assert.deepEqual(counts(database), afterFirst);
});

test("terminal task result remains separate from queued work and preserves measurement identity", t => {
  const { refresh, controlPlane } = fixture(t);
  const input = request({ testScope: "selected", testSelectors: "PairTests", folder: folders[0], revision: "abc1234" });
  const first = refresh.enqueue(input);
  const agent = controlPlane.registerAgent({ manager: "codex", agent: "metrics-test", sessionId: "isolated-session", state: "idle" });
  controlPlane.claimTask({ taskId: first.task.id, agentId: agent.id, sessionId: "isolated-session" });
  controlPlane.heartbeat({ agentId: agent.id, sessionId: "isolated-session", taskState: "working", progress: "Running selected tests" });
  assert.equal(refresh.snapshot().requests[0].resultSummary, null);
  const runningRetry = refresh.enqueue(input);
  assert.equal(runningRetry.reused, true);
  assert.equal(runningRetry.accepted, true);
  assert.equal(runningRetry.queued, false);
  assert.equal(runningRetry.task.state, "working");
  controlPlane.completeTask({ taskId: first.task.id, agentId: agent.id, sessionId: "isolated-session",
    result: "Selected tests: 2 passed; SHA abc1234; M5; publication blocked; nightly unchanged." });
  const done = refresh.snapshot().requests[0];
  assert.equal(done.state, "done");
  assert.match(done.resultSummary, /publication blocked; nightly unchanged/);
  assert.equal(done.request.revision, "abc1234");
  assert.equal(done.request.folder, folders[0]);
  assert.equal(done.request.testSelectors, "PairTests");
  assert.equal(refresh.enqueue(input).queued, false);
});

test("retry repairs an interrupted directive creation instead of falsely accepting an orphan task", t => {
  const { refresh, controlPlane, database } = fixture(t);
  const original = database.createMessage;
  let failOnce = true;
  database.createMessage = function (...args) {
    if (failOnce) { failOnce = false; throw new Error("Injected request-message persistence failure"); }
    return original.apply(this, args);
  };
  assert.throws(() => refresh.enqueue(request()), /Injected request-message persistence failure/);
  assert.equal(controlPlane.managerQueue("codex").length, 0);
  const retry = refresh.enqueue(request());
  assert.equal(retry.accepted, true);
  assert.equal(retry.queued, true);
  assert.equal(controlPlane.managerQueue("codex").length, 1);
  assert.equal(controlPlane.managerQueue("codex")[0].taskId, retry.task.id);
  const repairedCounts = counts(database);
  assert.equal(repairedCounts.cp_tasks, 1);
  assert.equal(repairedCounts.cp_directives, 1);
  refresh.enqueue(request());
  assert.deepEqual(counts(database), repairedCounts);
});

test("folder discovery excludes untracked paths and tracked folders replaced by outside symlinks", () => {
  const repoRoot = mkdtempSync(join(tmpdir(), "metrics-folders-"));
  const outside = mkdtempSync(join(tmpdir(), "metrics-outside-"));
  mkdirSync(join(repoRoot, "Source", "Hallie"), { recursive: true });
  mkdirSync(join(repoRoot, "Untracked"));
  mkdirSync(join(repoRoot, "Escaped"));
  writeFileSync(join(repoRoot, "Source", "Hallie", "Example.swift"), "// fixture\n");
  writeFileSync(join(repoRoot, "Untracked", "Other.swift"), "// fixture\n");
  writeFileSync(join(repoRoot, "Escaped", "Other.swift"), "// fixture\n");
  execFileSync("git", ["init", "--quiet", repoRoot]);
  execFileSync("git", ["add", "Source", "Escaped"], { cwd: repoRoot });
  renameSync(join(repoRoot, "Escaped"), join(repoRoot, "Escaped-original"));
  symlinkSync(outside, join(repoRoot, "Escaped"));
  assert.deepEqual(trackedSourceFolders(repoRoot), ["Source", "Source/Hallie"]);
});

test("metrics CSP permits its actual inline scripts by fresh nonce without weakening other routes", () => {
  const html = '<style>body { color: red }</style><script>boot()</script><script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js"></script>';
  const first = metricsDocument(html);
  const second = metricsDocument(html);
  const nonce = first.body.match(/nonce="([^"]+)"/)[1];
  assert.equal((first.body.match(new RegExp(`nonce="${nonce.replace(/[+]/g, "\\+")}"`, "g")) || []).length, 3);
  assert.ok(first.csp.includes(`'nonce-${nonce}'`));
  assert.notEqual(first.csp, second.csp);
  const scriptPolicy = first.csp.split(";").find(part => part.trim().startsWith("script-src "));
  assert.equal(scriptPolicy.includes("'unsafe-inline'"), false);
  assert.match(first.csp, /connect-src 'self' https:\/\/api.github.com https:\/\/raw.githubusercontent.com/);
  assert.match(first.csp, /frame-ancestors 'none'/);
});
