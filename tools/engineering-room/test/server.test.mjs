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
  const child = spawn(process.execPath, [join(root, "src/server.mjs")], {
    cwd: root,
    env: { ...process.env, CODEX_BIN: join(here, "fake-codex.mjs"), CLAUDE_BIN: join(here, "fake-claude.mjs"), ENGINEERING_ROOM_PORT: String(port), ENGINEERING_ROOM_TOKEN: token, ENGINEERING_ROOM_DB: join(mkdtempSync(join(tmpdir(), "engineering-room-server-")), "room.sqlite3") },
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
  assert.equal((await fetch(`${base}/favicon.ico`, { headers: { Cookie: cookie } })).status, 404);
  assert.equal((await fetch(`${base}/healthz`, { headers: { Cookie: cookie } })).status, 200);
  room = await waitFor(async () => {
    const value = await (await fetch(`${base}/api/bootstrap`, { headers: { Cookie: cookie } })).json();
    return value.agent.connection === "connected" ? value : null;
  });

  const payload = "<img src=x onerror=alert('nope')>";
  const sent = await fetch(`${base}/api/messages`, { method: "POST", headers, body: JSON.stringify({ topicId: room.topics[0].id, target: "codex", text: payload }) });
  assert.equal(sent.status, 202);
  const after = await waitFor(async () => {
    const value = await (await fetch(`${base}/api/bootstrap`, { headers: { Cookie: cookie } })).json();
    return value.messages.some(message => message.author === "codex") ? value : null;
  });
  assert.equal(after.messages.find(message => message.author === "rick").body, payload);
  assert.equal(after.messages.find(message => message.author === "codex").body, "A measured reply.");

  const both = await fetch(`${base}/api/messages`, { method: "POST", headers, body: JSON.stringify({ topicId: room.topics[0].id, target: "both", text: "Independent views, please." }) });
  assert.equal(both.status, 202);
  const afterBoth = await waitFor(async () => {
    const value = await (await fetch(`${base}/api/bootstrap`, { headers: { Cookie: cookie } })).json();
    return value.messages.some(message => message.author === "claude") && value.messages.filter(message => message.author === "codex").length >= 2 ? value : null;
  });
  assert.equal(afterBoth.messages.find(message => message.author === "claude").body, "An independent Claude reply.");

  const hostile = await fetch(`${base}/api/topics`, { method: "POST", headers: { Cookie: cookie, "Content-Type": "application/json", Origin: "https://evil.example" }, body: JSON.stringify({ title: "Injected" }) });
  assert.equal(hostile.status, 403);
});

test("LAN mode accepts an allowed household host and rejects hostile hosts", async t => {
  const port = 28000 + Math.floor(Math.random() * 8000);
  const token = "automated-lan-room-token-value-12345";
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
      ENGINEERING_ROOM_DB: join(mkdtempSync(join(tmpdir(), "engineering-room-lan-")), "room.sqlite3"),
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
