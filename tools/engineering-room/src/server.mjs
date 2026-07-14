import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { resolve, dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";
import { hostname as machineHostname, networkInterfaces } from "node:os";
import { RoomDatabase } from "./database.mjs";
import { CodexAppServerClient } from "./codex-client.mjs";
import { RoomAgent } from "./room-agent.mjs";
import { loadOrCreateAccessToken } from "./access-token.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const toolRoot = resolve(here, "..");
const repoRoot = resolve(toolRoot, "../..");
const publicRoot = join(toolRoot, "public");
const port = parsePort(process.env.ENGINEERING_ROOM_PORT ?? "8765");
const lanMode = process.env.ENGINEERING_ROOM_LAN === "1";
const host = lanMode ? "0.0.0.0" : "127.0.0.1";
const lanAddresses = discoverLanAddresses();
const allowedHosts = buildAllowedHosts();
const sessionToken = process.env.ENGINEERING_ROOM_TOKEN || (lanMode
  ? loadOrCreateAccessToken(process.env.ENGINEERING_ROOM_TOKEN_FILE || join(toolRoot, "var", "access-token"))
  : randomBytes(24).toString("base64url"));
const codexBin = findCodex();
const database = new RoomDatabase(process.env.ENGINEERING_ROOM_DB || join(toolRoot, "var", "engineering-room.sqlite3"));
const codex = new CodexAppServerClient({ codexBin, cwd: repoRoot });
const agent = new RoomAgent({ client: codex, database });
const clients = new Set();
let sequence = 0;

agent.on("event", event => publish(event.type, event.data));

const server = createServer(async (request, response) => {
  try {
    applySecurityHeaders(response);
    if (!validHost(request.headers.host) || !validOrigin(request.headers.origin)) return json(response, 403, { error: "Local room request rejected." });
    const url = new URL(request.url, `http://${request.headers.host}`);

    if (request.method === "GET" && url.pathname === "/" && url.searchParams.has("token")) {
      if (url.searchParams.get("token") !== sessionToken) return text(response, 403, "Invalid room token.");
      response.writeHead(302, { "Set-Cookie": `engineering_room=${sessionToken}; HttpOnly; SameSite=Strict; Path=/`, Location: "/" });
      return response.end();
    }

    if (!authorized(request)) return text(response, 401, "Open the startup URL printed by Engineering Room.");
    if (request.method === "GET" && url.pathname === "/healthz") return json(response, 200, { status: "ok", codex: agent.status.connection });
    if (request.method === "GET" && url.pathname === "/api/bootstrap") {
      return json(response, 200, { ...database.snapshot(), agent: agent.status, participants: { rick: "present", codex: agent.status.connection, claude: "not-invited" } });
    }
    if (request.method === "GET" && url.pathname === "/api/events") return openEvents(request, response);
    if (request.method === "POST" && url.pathname === "/api/topics") {
      const body = await readJson(request);
      const title = validateText(body.title, 1, 120, "Topic title");
      const topic = database.createTopic(title);
      publish("topic.created", topic);
      return json(response, 201, topic);
    }
    const topicMatch = url.pathname.match(/^\/api\/topics\/([0-9a-f-]+)$/i);
    if (request.method === "PATCH" && topicMatch) {
      const body = await readJson(request);
      const patch = {};
      if (body.title !== undefined) patch.title = validateText(body.title, 1, 120, "Topic title");
      if (body.status !== undefined) {
        if (!["active", "parked", "done"].includes(body.status)) throw httpError(400, "Invalid topic status.");
        patch.status = body.status;
      }
      if (body.position !== undefined) {
        if (!Number.isSafeInteger(body.position) || body.position < 0) throw httpError(400, "Invalid topic position.");
        patch.position = body.position;
      }
      const topic = database.updateTopic(topicMatch[1], patch);
      if (!topic) throw httpError(404, "Topic not found.");
      publish("topic.updated", topic);
      return json(response, 200, topic);
    }
    if (request.method === "POST" && url.pathname === "/api/messages") {
      const body = await readJson(request);
      const messageText = validateText(body.text, 1, 32768, "Message");
      const target = body.target ?? "codex";
      if (!["codex", "notes"].includes(target)) throw httpError(400, "That participant is not available yet.");
      const topics = database.snapshot().topics;
      const topicId = body.topicId ?? topics[0]?.id ?? null;
      if (topicId && !topics.some(topic => topic.id === topicId)) throw httpError(400, "Unknown topic.");
      if (target === "codex" && agent.status.busy) throw httpError(409, "Codex is still answering. Use Stop or wait for the current turn.");
      const message = database.createMessage({ topicId, author: "rick", body: messageText });
      publish("message.created", message);
      const topicTitle = topics.find(topic => topic.id === topicId)?.title ?? "General discussion";
      if (target === "codex") agent.ask(message, topicTitle).catch(error => {
        if (error.code !== "BUSY") publish("room.error", { message: publicError(error) });
      });
      return json(response, 202, message);
    }
    if (request.method === "POST" && url.pathname === "/api/turns/current/interrupt") {
      const interrupted = await agent.interrupt();
      return json(response, interrupted ? 202 : 409, { interrupted });
    }
    if (request.method === "GET") return await staticFile(url.pathname, response);
    throw httpError(404, "Not found.");
  } catch (error) {
    json(response, error.statusCode ?? 500, { error: error.statusCode ? error.message : "The room hit an internal error." });
  }
});

server.listen(port, host, async () => {
  const roomUrls = lanMode
    ? lanAddresses.map(address => `http://${address}:${port}/?token=${encodeURIComponent(sessionToken)}`)
    : [`http://127.0.0.1:${port}/?token=${encodeURIComponent(sessionToken)}`];
  console.log(`\nEngineering Room is ready${lanMode ? " for the household LAN" : ""}:\n${roomUrls.join("\n")}\n`);
  try {
    await agent.initialize();
    publish("codex.connection", { state: "connected" });
  } catch (error) {
    publish("codex.connection", { state: "disconnected", error: publicError(error) });
    console.error(`Codex is unavailable: ${publicError(error)}`);
  }
});

function publish(type, data) {
  const envelope = { version: 1, sequence: ++sequence, type, data };
  const line = `id: ${envelope.sequence}\nevent: room\ndata: ${JSON.stringify(envelope)}\n\n`;
  for (const client of clients) client.write(line);
}

function openEvents(request, response) {
  response.writeHead(200, {
    "Content-Type": "text/event-stream", "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive", "X-Accel-Buffering": "no",
  });
  response.write(`event: room\ndata: ${JSON.stringify({ version: 1, sequence, type: "snapshot", data: { ...database.snapshot(), agent: agent.status } })}\n\n`);
  clients.add(response);
  const keepalive = setInterval(() => response.write(": keepalive\n\n"), 15000);
  request.on("close", () => { clearInterval(keepalive); clients.delete(response); });
}

async function staticFile(pathname, response) {
  const relative = pathname === "/" ? "index.html" : pathname.slice(1);
  if (!/^[a-zA-Z0-9._/-]+$/.test(relative) || relative.includes("..")) throw httpError(404, "Not found.");
  const path = resolve(publicRoot, relative);
  if (!path.startsWith(`${publicRoot}/`)) throw httpError(404, "Not found.");
  let body;
  try { body = await readFile(path); } catch { throw httpError(404, "Not found."); }
  response.writeHead(200, { "Content-Type": mimeType(path), "Cache-Control": "no-store" });
  response.end(body);
}

function authorized(request) {
  return (request.headers.cookie ?? "").split(/;\s*/).some(value => value === `engineering_room=${sessionToken}`);
}

function validHost(value = "") {
  try {
    const parsed = new URL(`http://${value}`);
    return Number(parsed.port || 80) === port && allowedHosts.has(parsed.hostname.toLowerCase());
  } catch { return false; }
}
function validOrigin(value) {
  if (!value) return true;
  try {
    const parsed = new URL(value);
    return parsed.protocol === "http:" && Number(parsed.port || 80) === port && allowedHosts.has(parsed.hostname.toLowerCase());
  } catch { return false; }
}

function applySecurityHeaders(response) {
  response.setHeader("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("Referrer-Policy", "no-referrer");
  response.setHeader("X-Frame-Options", "DENY");
}

async function readJson(request) {
  if (!(request.headers["content-type"] ?? "").startsWith("application/json")) throw httpError(415, "Expected JSON.");
  let size = 0;
  const chunks = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 33792) throw httpError(413, "Request is too large.");
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); }
  catch { throw httpError(400, "Malformed JSON."); }
}

function validateText(value, min, max, label) {
  if (typeof value !== "string") throw httpError(400, `${label} must be text.`);
  const text = value.trim();
  if (text.length < min || text.length > max) throw httpError(400, `${label} must be ${min}–${max} characters.`);
  return text;
}

function findCodex() {
  const candidates = [process.env.CODEX_BIN, join(process.env.HOME ?? "", ".local/bin/codex"), "/opt/homebrew/bin/codex", "/usr/local/bin/codex"].filter(Boolean);
  const found = candidates.find(path => path.includes("/") && existsSync(path));
  if (found) return found;
  if (process.env.CODEX_BIN && !process.env.CODEX_BIN.includes("/")) return process.env.CODEX_BIN;
  throw new Error("Codex was not found. Set CODEX_BIN to its absolute path.");
}

function discoverLanAddresses() {
  const addresses = [];
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family === "IPv4" && !entry.internal && isPrivateAddress(entry.address)) addresses.push(entry.address);
    }
  }
  return [...new Set(addresses)];
}

function buildAllowedHosts() {
  const name = machineHostname().toLowerCase();
  const configured = (process.env.ENGINEERING_ROOM_PUBLIC_HOSTS ?? "").split(",").map(value => value.trim().toLowerCase()).filter(Boolean);
  return new Set(["127.0.0.1", "localhost", name, `${name}.local`, ...lanAddresses, ...configured]);
}

function isPrivateAddress(address) {
  const octets = address.split(".").map(Number);
  return octets[0] === 10 || (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) || (octets[0] === 192 && octets[1] === 168);
}

function parsePort(value) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 1024 || number > 65535) throw new Error("ENGINEERING_ROOM_PORT must be between 1024 and 65535.");
  return number;
}

function httpError(statusCode, message) { return Object.assign(new Error(message), { statusCode }); }
function publicError(error) { return (error instanceof Error ? error.message : String(error)).replace(/[\r\n]+/g, " ").slice(0, 500); }
function mimeType(path) { return ({ ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".png": "image/png" })[extname(path)] ?? "application/octet-stream"; }
function json(response, status, body) { response.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" }); response.end(JSON.stringify(body)); }
function text(response, status, body) { response.writeHead(status, { "Content-Type": "text/plain; charset=utf-8" }); response.end(body); }

function shutdown() {
  codex.close();
  for (const client of clients) client.end();
  clients.clear();
  server.close(() => { database.close(); process.exit(0); });
  setTimeout(() => process.exit(1), 3000).unref();
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
