import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { resolve, dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";
import { hostname as machineHostname, networkInterfaces } from "node:os";
import { RoomDatabase } from "./database.mjs";
import { CodexAppServerClient } from "./codex-client.mjs";
import { ClaudeCliClient } from "./claude-client.mjs";
import { QwenResponsesClient } from "./qwen-client.mjs";
import { RoomAgent } from "./room-agent.mjs";
import { loadOrCreateAccessToken } from "./access-token.mjs";
import { RoundtableController } from "./roundtable-controller.mjs";
import { ControlPlane } from "./control-plane.mjs";

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
const claudeBin = findClaude();
const database = new RoomDatabase(process.env.ENGINEERING_ROOM_DB || join(toolRoot, "var", "engineering-room.sqlite3"));
const codex = new CodexAppServerClient({ codexBin, cwd: repoRoot });
const claude = new ClaudeCliClient({ claudeBin, cwd: repoRoot });
const qwen = new QwenResponsesClient({
  baseUrl: process.env.QWEN_BASE_URL || "http://ricksm5.local:11434/v1",
  model: process.env.QWEN_MODEL || "qwen-videoscan:64k",
  apiKey: process.env.QWEN_API_KEY || "",
});
const agents = {
  codex: new RoomAgent({ client: codex, database, provider: "codex", displayName: "Codex" }),
  claude: new RoomAgent({ client: claude, database, provider: "claude", displayName: "Claude" }),
  qwen: new RoomAgent({ client: qwen, database, provider: "qwen", displayName: "Qwen" }),
};
const clients = new Set();
let sequence = 0;
const controlPlane = new ControlPlane({
  database, repoRoot, toolRoot, publish,
  statusFeed: process.env.ENGINEERING_ROOM_STATUS_FEED,
  teamChannel: process.env.ENGINEERING_ROOM_TEAM_CHANNEL,
  reconstructionSeed: process.env.ENGINEERING_ROOM_RECONSTRUCTION_SEED,
});
controlPlane.ingestAll();
ensureDailyArtifacts();

for (const agent of Object.values(agents)) agent.on("event", event => publish(event.type, event.data));
const autopilot = new RoundtableController({
  // Autopilot remains the existing Codex/Claude exchange. Qwen is a direct,
  // independently routed room participant and cannot widen an automatic run.
  agents: { codex: agents.codex, claude: agents.claude }, database, publish,
  transcript: attributedTranscript,
  roomBrief: provider => controlPlane.seatBrief(provider),
  presence: () => clients.size > 0,
});

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
    if (request.method === "GET" && url.pathname === "/healthz") return json(response, 200, {
      status: "ok",
      codex: agents.codex.status.connection,
      claude: agents.claude.status.connection,
      qwen: agents.qwen.status.connection,
    });
    if (request.method === "GET" && url.pathname === "/api/bootstrap") {
      return json(response, 200, roomSnapshot());
    }
    if (request.method === "GET" && url.pathname === "/api/events") return openEvents(request, response);
    if (request.method === "GET" && url.pathname === "/api/control-plane/board") return json(response, 200, controlPlane.board());
    if (request.method === "GET" && url.pathname === "/api/control-plane/briefs/latest") return json(response, 200, controlPlane.latestBrief());
    if (request.method === "GET" && url.pathname === "/api/control-plane/standups/latest") return json(response, 200, controlPlane.latestStandup());
    if (request.method === "POST" && url.pathname === "/api/control-plane/ingest") {
      const changed = controlPlane.ingestAll();
      return json(response, 200, { changed, board: controlPlane.board() });
    }
    if (request.method === "POST" && url.pathname === "/api/control-plane/directives") {
      return json(response, 201, controlPlane.createDirective(await readJson(request)));
    }
    const managerQueueMatch = url.pathname.match(/^\/api\/control-plane\/managers\/([a-zA-Z0-9._-]+)\/queue$/);
    if (request.method === "GET" && managerQueueMatch) {
      return json(response, 200, { manager: managerQueueMatch[1], queue: controlPlane.managerQueue(managerQueueMatch[1]) });
    }
    if (request.method === "POST" && url.pathname === "/api/control-plane/agents/register") {
      return json(response, 201, controlPlane.registerAgent(await readJson(request)));
    }
    if (request.method === "POST" && url.pathname === "/api/control-plane/agents/heartbeat") {
      return json(response, 200, controlPlane.heartbeat(await readJson(request)));
    }
    if (request.method === "POST" && url.pathname === "/api/control-plane/tasks") {
      return json(response, 201, controlPlane.createTask(await readJson(request)));
    }
    const controlTaskMatch = url.pathname.match(/^\/api\/control-plane\/tasks\/(.+)$/);
    if (controlTaskMatch && request.method === "PATCH") {
      return json(response, 200, controlPlane.updateTask(decodeURIComponent(controlTaskMatch[1]), await readJson(request)));
    }
    const claimMatch = url.pathname.match(/^\/api\/control-plane\/tasks\/(.+)\/claim$/);
    if (claimMatch && request.method === "POST") {
      const body = await readJson(request);
      return json(response, 200, controlPlane.claimTask({ ...body, taskId: decodeURIComponent(claimMatch[1]) }));
    }
    const completeMatch = url.pathname.match(/^\/api\/control-plane\/tasks\/(.+)\/complete$/);
    if (completeMatch && request.method === "POST") {
      const body = await readJson(request);
      return json(response, 200, controlPlane.completeTask({ ...body, taskId: decodeURIComponent(completeMatch[1]) }));
    }
    if (request.method === "POST" && url.pathname === "/api/control-plane/events") {
      return json(response, 201, controlPlane.recordEvent(await readJson(request)));
    }
    if (request.method === "POST" && url.pathname === "/api/control-plane/decisions") {
      return json(response, 201, controlPlane.recordDecision(await readJson(request)));
    }
    if (request.method === "POST" && url.pathname === "/api/control-plane/briefs") {
      const body = await readJson(request);
      const brief = controlPlane.generateRoomBrief({ kind: body.kind });
      if (body.publishToRoom) publishControlDigest(brief.digest, body.topicId);
      return json(response, 201, brief);
    }
    if (request.method === "POST" && url.pathname === "/api/control-plane/standups") {
      const body = await readJson(request);
      const standup = controlPlane.generateStandup({ date: body.date });
      if (body.publishToRoom) publishControlDigest(standup.digest, body.topicId);
      return json(response, 201, standup);
    }
    if (request.method === "POST" && url.pathname === "/api/control-plane/channel/export") {
      return json(response, 201, controlPlane.exportTeamChannel(await readJson(request)));
    }
    if (request.method === "POST" && url.pathname === "/api/topics") {
      const body = await readJson(request);
      const title = validateText(body.title, 1, 120, "Topic title");
      const topic = database.createTopic(title);
      publish("topic.created", topic);
      return json(response, 201, topic);
    }
    if (request.method === "POST" && url.pathname === "/api/autopilot/control") {
      const body = await readJson(request);
      const state = await autopilot.setEnabled(body.enabled);
      return json(response, 200, state);
    }
    if (request.method === "POST" && url.pathname === "/api/autopilot/start") {
      const body = await readJson(request);
      const objective = validateText(body.objective, 1, 4000, "Objective");
      const topics = database.snapshot().topics;
      const topicId = body.topicId ?? topics[0]?.id ?? null;
      if (topicId && !topics.some(topic => topic.id === topicId)) throw httpError(400, "Unknown topic.");
      const limits = autopilot.preflight({ turns: body.maxTurns, tokenBudget: body.tokenBudget, deadlineAt: body.deadlineAt });
      const message = database.createMessage({ topicId, author: "rick", body: `Autopilot objective: ${objective}` });
      publish("message.created", message);
      const topicTitle = topics.find(topic => topic.id === topicId)?.title ?? "General discussion";
      await autopilot.start({ message, topicTitle, objective, turns: limits.totalTurns, tokenBudget: limits.tokenBudget, deadlineAt: limits.deadlineAt });
      return json(response, 202, { message, autopilot: autopilot.snapshot });
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
      if (!["codex", "claude", "qwen", "both", "all", "notes"].includes(target)) throw httpError(400, "That participant is not available.");
      const topics = database.snapshot().topics;
      const topicId = body.topicId ?? topics[0]?.id ?? null;
      if (topicId && !topics.some(topic => topic.id === topicId)) throw httpError(400, "Unknown topic.");
      const wasAutopilotActive = autopilot.active;
      if (wasAutopilotActive) await autopilot.interject();
      const recipients = target === "both" ? ["codex", "claude"] : target === "all" ? ["codex", "claude", "qwen"] : target === "notes" ? [] : [target];
      const busy = recipients.filter(provider => agents[provider].status.busy);
      if (busy.length && !wasAutopilotActive) throw httpError(409, `${busy.map(titleCase).join(" and ")} ${busy.length === 1 ? "is" : "are"} still answering. Use Stop or wait.`);
      const message = database.createMessage({ topicId, author: "rick", body: messageText });
      publish("message.created", message);
      const topicTitle = topics.find(topic => topic.id === topicId)?.title ?? "General discussion";
      const transcript = attributedTranscript(topicId, message.id);
      const route = () => recipients.forEach(provider => agents[provider].ask(message, topicTitle, transcript, { roomBrief: controlPlane.seatBrief(provider) }).catch(error => {
        if (error.code !== "BUSY") publish("room.error", { provider, message: publicError(error) });
      }));
      if (busy.length) waitForAgentsIdle(busy.map(provider => agents[provider])).then(route).catch(error => publish("room.error", { message: publicError(error) }));
      else route();
      return json(response, 202, message);
    }
    if (request.method === "POST" && url.pathname === "/api/turns/current/interrupt") {
      const stoppedAutopilot = await autopilot.stop("Stopped by Rick.");
      // Stop is room-wide: an independently active Qwen turn must not survive
      // merely because the Codex/Claude Autopilot was active too.
      const results = await Promise.all(Object.values(agents).map(agent => agent.interrupt().catch(() => false)));
      const interrupted = stoppedAutopilot || results.some(Boolean);
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
    const initialized = await Promise.allSettled(Object.entries(agents).map(async ([provider, agent]) => {
      await agent.initialize();
      publish("agent.connection", { provider, state: agent.status.connection });
    }));
    initialized.forEach((result, index) => {
      if (result.status === "fulfilled") return;
      const provider = Object.keys(agents)[index];
      publish("agent.connection", { provider, state: "disconnected", error: publicError(result.reason) });
      console.error(`${titleCase(provider)} is unavailable: ${publicError(result.reason)}`);
    });
    await autopilot.recover();
  } catch (error) { console.error(`Room initialization failed: ${publicError(error)}`); }
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
  response.write(`event: room\ndata: ${JSON.stringify({ version: 1, sequence, type: "snapshot", data: roomSnapshot() })}\n\n`);
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

function findClaude() {
  const candidates = [process.env.CLAUDE_BIN, "/opt/homebrew/bin/claude", "/usr/local/bin/claude", join(process.env.HOME ?? "", ".local/bin/claude")].filter(Boolean);
  const found = candidates.find(path => path.includes("/") && existsSync(path));
  if (found) return found;
  if (process.env.CLAUDE_BIN && !process.env.CLAUDE_BIN.includes("/")) return process.env.CLAUDE_BIN;
  return null;
}

function roomSnapshot() {
  return {
    ...database.snapshot(),
    agents: Object.fromEntries(Object.entries(agents).map(([provider, agent]) => [provider, agent.status])),
    agent: agents.codex.status,
    participants: {
      rick: "present",
      codex: agents.codex.status.connection,
      claude: agents.claude.status.connection,
      qwen: agents.qwen.status.connection,
    },
    autopilot: autopilot.snapshot,
    controlPlane: controlPlane.board(),
    roomBrief: artifactMetadata(controlPlane.latestBrief()),
    standup: artifactMetadata(controlPlane.latestStandup()),
  };
}

function artifactMetadata(artifact) {
  if (!artifact) return null;
  return { id: artifact.id, kind: artifact.kind, date: artifact.date, generatedAt: artifact.generatedAt, contentHash: artifact.contentHash };
}

function publishControlDigest(digest, requestedTopicId) {
  const topics = database.snapshot().topics;
  const topicId = requestedTopicId ?? topics[0]?.id ?? null;
  if (topicId && !topics.some(topic => topic.id === topicId)) throw httpError(400, "Unknown topic.");
  const message = database.createMessage({ topicId, author: "system", body: digest });
  publish("message.created", message);
  return message;
}

function attributedTranscript(topicId, excludingMessageId) {
  const labels = { rick: "Rick", codex: "Codex", claude: "Claude", qwen: "Qwen", system: "Room" };
  const chunks = database.snapshot().messages
    .filter(message => message.topicId === topicId && message.id !== excludingMessageId)
    .slice(-24)
    .map(message => `${labels[message.author] ?? message.author}: ${message.body}`);
  const retained = [];
  let length = 0;
  for (let index = chunks.length - 1; index >= 0; index -= 1) {
    const separator = retained.length ? 2 : 0;
    if (length + separator + chunks[index].length > 24000) break;
    retained.unshift(chunks[index]);
    length += separator + chunks[index].length;
  }
  return retained.join("\n\n");
}

async function waitForAgentsIdle(selectedAgents, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (selectedAgents.some(agent => agent.status.busy)) {
    if (Date.now() >= deadline) throw new Error("The interrupted agent did not become idle in time.");
    await new Promise(resolve => setTimeout(resolve, 25));
  }
}

function titleCase(value) { return value.charAt(0).toUpperCase() + value.slice(1); }

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
  clearInterval(controlPlanePoll);
  clearInterval(dailyArtifactsPoll);
  for (const agent of Object.values(agents)) agent.client.close();
  for (const client of clients) client.end();
  clients.clear();
  server.close(() => { database.close(); process.exit(0); });
  setTimeout(() => process.exit(1), 3000).unref();
}
const controlPlanePoll = setInterval(() => {
  try { controlPlane.ingestAll(); }
  catch (error) { console.error(`Control-plane ingestion failed: ${publicError(error)}`); }
}, 5000);
controlPlanePoll.unref();
const dailyArtifactsPoll = setInterval(ensureDailyArtifacts, 60 * 1000);
dailyArtifactsPoll.unref();

function ensureDailyArtifacts() {
  try {
    const date = new Date().toLocaleDateString("en-CA");
    if (controlPlane.latestStandup()?.date !== date) controlPlane.generateStandup({ date });
    if (!controlPlane.latestBrief()) controlPlane.generateRoomBrief({ kind: "startup" });
  } catch (error) { console.error(`Daily control-plane generation failed: ${publicError(error)}`); }
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
