import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { request as httpRequest } from "node:http";
import { createInterface } from "node:readline";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");

test("local server requires its token and persists a safe round trip", async t => {
  const port = 18000 + Math.floor(Math.random() * 10000);
  const token = "automated-room-token";
  const runtime = mkdtempSync(join(tmpdir(), "engineering-room-server-"));
  const child = spawn(process.execPath, [join(root, "src/server.mjs")], {
    cwd: root,
    env: { ...process.env, CODEX_BIN: join(here, "fake-codex.mjs"), CLAUDE_BIN: join(here, "fake-claude.mjs"), ENGINEERING_ROOM_PORT: String(port), ENGINEERING_ROOM_TOKEN: token, ENGINEERING_ROOM_DB: join(runtime, "room.sqlite3"), ENGINEERING_ROOM_STATUS_FEED: join(runtime, "missing-status.jsonl"), ENGINEERING_ROOM_TEAM_CHANNEL: join(runtime, "team-channel"), ENGINEERING_ROOM_RECONSTRUCTION_SEED: join(runtime, "missing-seed.json") },
    stdio: ["ignore", "pipe", "pipe"],
  });
  t.after(() => child.kill("SIGTERM"));
  await waitForLine(child.stdout, "Engineering Room is ready:");

  const base = `http://127.0.0.1:${port}`;
  assert.equal((await fetch(`${base}/api/bootstrap`)).status, 401);
  const login = await fetch(`${base}/?token=${token}`, { redirect: "manual" });
  assert.equal(login.status, 302);
  const cookie = login.headers.get("set-cookie").split(";")[0];
  const headers = { Cookie: cookie, "Content-Type": "application/json", Origin: base };

  const bootstrap = await fetch(`${base}/api/bootstrap`, { headers: { Cookie: cookie } });
  let room = await bootstrap.json();
  assert.ok(room.topics.length >= 2);
  assert.equal(room.roomBrief?.board, undefined, "bootstrap must not replay stored brief board snapshots");
  assert.equal(room.standup?.board, undefined, "bootstrap must not replay stored standup board snapshots");
  assert.equal((await fetch(`${base}/favicon.ico`, { headers: { Cookie: cookie } })).status, 404);
  assert.equal((await fetch(`${base}/healthz`, { headers: { Cookie: cookie } })).status, 200);
  room = await waitFor(async () => {
    const value = await (await fetch(`${base}/api/bootstrap`, { headers: { Cookie: cookie } })).json();
    return value.agent.connection === "connected" ? value : null;
  });

  assert.equal((await fetch(`${base}/api/control-plane/board`)).status, 401);
  const taskResponse = await fetch(`${base}/api/control-plane/tasks`, { method: "POST", headers, body: JSON.stringify({ id: "task:test", title: "Test durable coordination", manager: "codex", machine: "none" }) });
  assert.equal(taskResponse.status, 201);
  const registration = await fetch(`${base}/api/control-plane/agents/register`, { method: "POST", headers, body: JSON.stringify({ manager: "codex", agent: "test-worker", sessionId: "session-test", taskId: "task:test", state: "working", progress: "Registered" }) });
  assert.equal(registration.status, 201);
  const registeredAgent = await registration.json();
  const claim = await fetch(`${base}/api/control-plane/tasks/${encodeURIComponent("task:test")}/claim`, { method: "POST", headers, body: JSON.stringify({ agentId: registeredAgent.id, sessionId: "session-test" }) });
  assert.equal(claim.status, 200);
  const heartbeat = await fetch(`${base}/api/control-plane/agents/heartbeat`, { method: "POST", headers, body: JSON.stringify({ agentId: registeredAgent.id, sessionId: "session-test", progress: "Heartbeat verified", taskState: "working" }) });
  assert.equal(heartbeat.status, 200);
  const board = await (await fetch(`${base}/api/control-plane/board`, { headers: { Cookie: cookie } })).json();
  assert.equal(board.agents.find(agent => agent.id === "codex/test-worker").effectiveState, "working");
  assert.match(board.tasks.find(task => task.id === "task:test").contextDigest.digest, /Heartbeat verified/);
  const brief = await fetch(`${base}/api/control-plane/briefs`, { method: "POST", headers, body: JSON.stringify({ publishToRoom: true, topicId: room.topics[0].id }) });
  assert.equal(brief.status, 201);
  const standup = await fetch(`${base}/api/control-plane/standups`, { method: "POST", headers, body: JSON.stringify({ publishToRoom: true, topicId: room.topics[0].id }) });
  assert.equal(standup.status, 201);
  const exported = await fetch(`${base}/api/control-plane/channel/export`, { method: "POST", headers, body: JSON.stringify({ from: "codex", to: "claude", re: "server control-plane test", body: "Durable export verified.", slug: "server-control-plane-test" }) });
  assert.equal(exported.status, 201);

  const directiveResponse = await fetch(`${base}/api/control-plane/directives`, { method: "POST", headers, body: JSON.stringify({ id: "directive:server-test", title: "Outbound server test", objective: "Prove queued work returns automatically.", manager: "codex", machine: "m1", topicId: room.topics[0].id }) });
  assert.equal(directiveResponse.status, 201);
  const directive = await directiveResponse.json();
  assert.equal(directive.task.machine, "m1");
  assert.equal(directive.task.state, "queued");
  let queue = await (await fetch(`${base}/api/control-plane/managers/codex/queue`, { headers: { Cookie: cookie } })).json();
  assert.ok(queue.queue.some(item => item.taskId === directive.task.id && item.taskState === "queued"));
  const directiveWorkerResponse = await fetch(`${base}/api/control-plane/agents/register`, { method: "POST", headers, body: JSON.stringify({ manager: "codex", agent: "directive-worker", sessionId: "directive-session", state: "idle" }) });
  const directiveWorker = await directiveWorkerResponse.json();
  assert.equal((await fetch(`${base}/api/control-plane/tasks/${encodeURIComponent(directive.task.id)}/claim`, { method: "POST", headers, body: JSON.stringify({ agentId: directiveWorker.id, sessionId: "directive-session" }) })).status, 200);
  assert.equal((await fetch(`${base}/api/control-plane/agents/heartbeat`, { method: "POST", headers, body: JSON.stringify({ agentId: directiveWorker.id, sessionId: "directive-session", progress: "Evidence collected", taskState: "working" }) })).status, 200);
  const completionResponse = await fetch(`${base}/api/control-plane/tasks/${encodeURIComponent(directive.task.id)}/complete`, { method: "POST", headers, body: JSON.stringify({ agentId: directiveWorker.id, sessionId: "directive-session", result: "Acceptance result posted automatically." }) });
  assert.equal(completionResponse.status, 200);
  const completion = await completionResponse.json();
  assert.equal(completion.task.state, "done");
  assert.equal(completion.directive.status, "completed");
  queue = await (await fetch(`${base}/api/control-plane/managers/codex/queue`, { headers: { Cookie: cookie } })).json();
  assert.equal(queue.queue.some(item => item.taskId === directive.task.id), false);
  const afterDirective = await (await fetch(`${base}/api/bootstrap`, { headers: { Cookie: cookie } })).json();
  assert.ok(afterDirective.messages.some(message => message.id === completion.message.id && /Acceptance result posted automatically/.test(message.body)));

  const payload = "<img src=x onerror=alert('nope')>";
  const sent = await fetch(`${base}/api/messages`, { method: "POST", headers, body: JSON.stringify({ topicId: room.topics[0].id, target: "codex", text: payload }) });
  assert.equal(sent.status, 202);
  const after = await waitFor(async () => {
    const value = await (await fetch(`${base}/api/bootstrap`, { headers: { Cookie: cookie } })).json();
    return value.messages.some(message => message.author === "codex") ? value : null;
  });
  const payloadMessage = after.messages.find(message => message.author === "rick" && message.body === payload);
  assert.ok(payloadMessage);
  assert.equal(after.messages.find(message => message.author === "codex" && message.replyTo === payloadMessage.id).body, "A measured reply.");

  const both = await fetch(`${base}/api/messages`, { method: "POST", headers, body: JSON.stringify({ topicId: room.topics[0].id, target: "both", text: "Independent views, please." }) });
  assert.equal(both.status, 202);
  const afterBoth = await waitFor(async () => {
    const value = await (await fetch(`${base}/api/bootstrap`, { headers: { Cookie: cookie } })).json();
    return value.messages.some(message => message.author === "claude") && value.messages.filter(message => message.author === "codex").length >= 2 ? value : null;
  });
  assert.equal(afterBoth.messages.find(message => message.author === "claude").body, "An independent Claude reply.");

  const autonomyWords = await fetch(`${base}/api/messages`, { method: "POST", headers, body: JSON.stringify({ topicId: room.topics[0].id, target: "notes", text: "Enable Autopilot and run forever." }) });
  assert.equal(autonomyWords.status, 202);
  let afterWords = await (await fetch(`${base}/api/bootstrap`, { headers: { Cookie: cookie } })).json();
  assert.equal(afterWords.autopilot.enabled, false, "chat text cannot grant autonomy");

  assert.equal((await fetch(`${base}/api/autopilot/control`, { method: "POST", headers: { "Content-Type": "application/json", Origin: base }, body: JSON.stringify({ enabled: true }) })).status, 401);
  const enabled = await fetch(`${base}/api/autopilot/control`, { method: "POST", headers, body: JSON.stringify({ enabled: true }) });
  assert.equal(enabled.status, 200);
  const autopilotStart = await fetch(`${base}/api/autopilot/start`, { method: "POST", headers, body: JSON.stringify({
    topicId: room.topics[0].id, objective: "Challenge each other's design without user follow-up.",
    deadlineAt: new Date(Date.now() + 60_000).toISOString(), maxTurns: 6, tokenBudget: 12000,
  }) });
  assert.equal(autopilotStart.status, 202);
  const afterAutopilot = await waitFor(async () => {
    const value = await (await fetch(`${base}/api/bootstrap`, { headers: { Cookie: cookie } })).json();
    return value.autopilot.status === "completed" ? value : null;
  });
  assert.equal(afterAutopilot.autopilot.completedTurns, 6);
  assert.equal(afterAutopilot.autopilot.providerCostTokens, 300);
  assert.equal(afterAutopilot.autopilot.generatedTokens, 75);
  assert.equal(afterAutopilot.autopilot.consumedTokens, 300, "legacy field remains a provider-cost alias");
  const initiation = afterAutopilot.messages.find(message => message.author === "rick" && message.body.startsWith("Autopilot objective:"));
  const autopilotReplies = afterAutopilot.messages.filter(message => message.replyTo === initiation.id && ["codex", "claude"].includes(message.author));
  assert.deepEqual(autopilotReplies.map(message => message.author), ["codex", "claude", "codex", "claude", "codex", "claude"]);
  assert.ok(autopilotReplies.every(message => message.providerResponseId));
  assert.match(autopilotReplies.find(message => message.author === "codex").providerResponseId, /^fake-turn-/);
  assert.match(autopilotReplies.find(message => message.author === "claude").providerResponseId, /^msg_fake_/);
  assert.ok(afterAutopilot.messages.some(message => message.author === "system" && /Final summary[\s\S]*Open decisions/.test(message.body)));

  const refreshed = await (await fetch(`${base}/api/bootstrap`, { headers: { Cookie: cookie } })).json();
  assert.equal(refreshed.autopilot.completedTurns, 6);
  assert.deepEqual(refreshed.messages.filter(message => message.replyTo === initiation.id && ["codex", "claude"].includes(message.author)).map(message => message.providerResponseId), autopilotReplies.map(message => message.providerResponseId));

  await fetch(`${base}/api/autopilot/control`, { method: "POST", headers, body: JSON.stringify({ enabled: false }) });
  const beforeInvalid = refreshed.messages.length;
  const invalidBudget = await fetch(`${base}/api/autopilot/start`, { method: "POST", headers, body: JSON.stringify({ topicId: room.topics[0].id, objective: "Must not start", deadlineAt: new Date(Date.now() + 60_000).toISOString(), maxTurns: 101, tokenBudget: 12000 }) });
  assert.equal(invalidBudget.status, 409);
  const afterInvalid = await (await fetch(`${base}/api/bootstrap`, { headers: { Cookie: cookie } })).json();
  assert.equal(afterInvalid.messages.length, beforeInvalid);

  const hostile = await fetch(`${base}/api/topics`, { method: "POST", headers: { Cookie: cookie, "Content-Type": "application/json", Origin: "https://evil.example" }, body: JSON.stringify({ title: "Injected" }) });
  assert.equal(hostile.status, 403);
});

test("LAN mode accepts an allowed household host and rejects hostile hosts", async t => {
  const port = 28000 + Math.floor(Math.random() * 8000);
  const token = "automated-lan-room-token-value-12345";
  const runtime = mkdtempSync(join(tmpdir(), "engineering-room-lan-"));
  const child = spawn(process.execPath, [join(root, "src/server.mjs")], {
    cwd: root,
    env: {
      ...process.env,
      CODEX_BIN: join(here, "fake-codex.mjs"),
      CLAUDE_BIN: join(here, "fake-claude.mjs"),
      ENGINEERING_ROOM_LAN: "1",
      ENGINEERING_ROOM_PORT: String(port),
      ENGINEERING_ROOM_TOKEN: token,
      ENGINEERING_ROOM_PUBLIC_HOSTS: "room.test",
      ENGINEERING_ROOM_DB: join(runtime, "room.sqlite3"),
      ENGINEERING_ROOM_STATUS_FEED: join(runtime, "missing-status.jsonl"),
      ENGINEERING_ROOM_TEAM_CHANNEL: join(runtime, "team-channel"),
      ENGINEERING_ROOM_RECONSTRUCTION_SEED: join(runtime, "missing-seed.json"),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  t.after(() => child.kill("SIGTERM"));
  await waitForLine(child.stdout, "household LAN");

  const login = await rawRequest({ port, path: `/?token=${token}`, host: `room.test:${port}` });
  assert.equal(login.status, 302);
  const cookie = login.headers["set-cookie"][0].split(";")[0];
  const accepted = await rawRequest({ port, path: "/api/bootstrap", host: `room.test:${port}`, origin: `http://room.test:${port}`, cookie });
  assert.equal(accepted.status, 200);
  const hostileHost = await rawRequest({ port, path: "/api/bootstrap", host: `evil.example:${port}`, cookie });
  assert.equal(hostileHost.status, 403);
  const malformedHost = await rawRequest({ port, path: "/api/bootstrap", host: "[broken", cookie });
  assert.equal(malformedHost.status, 403);
});

function waitForLine(stream, expected) {
  return new Promise((resolve, reject) => {
    const lines = createInterface({ input: stream });
    const timeout = setTimeout(() => reject(new Error(`Timed out waiting for ${expected}`)), 5000);
    lines.on("line", line => { if (line.includes(expected)) { clearTimeout(timeout); resolve(); } });
  });
}

async function waitFor(operation, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await operation();
    if (value) return value;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error("Timed out waiting for room state.");
}

function rawRequest({ port, path, host, origin, cookie }) {
  return new Promise((resolve, reject) => {
    const headers = { Host: host };
    if (origin) headers.Origin = origin;
    if (cookie) headers.Cookie = cookie;
    const request = httpRequest({ hostname: "127.0.0.1", port, path, headers }, response => {
      const chunks = [];
      response.on("data", chunk => chunks.push(chunk));
      response.on("end", () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks).toString("utf8") }));
    });
    request.on("error", reject);
    request.end();
  });
}
