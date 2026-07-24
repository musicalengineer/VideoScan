#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const toolRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = parseArgs(process.argv.slice(2));
const command = args._[0];
const baseUrl = process.env.ENGINEERING_ROOM_URL ?? `http://127.0.0.1:${process.env.ENGINEERING_ROOM_PORT ?? "8765"}`;
const token = process.env.ENGINEERING_ROOM_TOKEN ?? readToken(process.env.ENGINEERING_ROOM_TOKEN_FILE ?? join(toolRoot, "var", "access-token"));

if (!command || args.help) usage();
if (!token) fail("No room token found. Set ENGINEERING_ROOM_TOKEN or start Engineering Room in LAN mode once.");

try {
  let result;
  if (command === "board") result = await api("/api/control-plane/board");
  else if (command === "ingest") result = await api("/api/control-plane/ingest", "POST", {});
  else if (command === "queue") result = await api(`/api/control-plane/managers/${encodeURIComponent(required("manager"))}/queue`);
  else if (command === "watch") { await watchQueue(); process.exit(0); }
  else if (command === "register" || command === "resume") result = await register(command === "resume");
  else if (command === "heartbeat") result = await heartbeat();
  else if (command === "complete") result = await complete();
  else if (command === "brief") result = await api("/api/control-plane/briefs", "POST", { kind: args.kind, publishToRoom: Boolean(args.publish), topicId: args["topic-id"] });
  else if (command === "standup") result = await api("/api/control-plane/standups", "POST", { date: args.date, publishToRoom: Boolean(args.publish), topicId: args["topic-id"] });
  else fail(`Unknown command: ${command}`);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} catch (error) { fail(error.message); }

async function register(resume) {
  const manager = required("manager");
  const agent = required("agent");
  const sessionId = required("session");
  const taskId = args["task-id"];
  if (taskId && args["task-title"]) {
    const machine = required("machine");
    const board = await api("/api/control-plane/board");
    if (!board.tasks.some(task => task.id === taskId)) await api("/api/control-plane/tasks", "POST", {
      id: taskId, title: args["task-title"], objective: args.objective, manager,
      machine,
      state: resume ? "working" : (args["task-state"] ?? "queued"), progress: args.progress,
    });
  }
  const registered = await api("/api/control-plane/agents/register", "POST", {
    manager, agent, sessionId, displayName: args["display-name"], taskId,
    state: args.state ?? (taskId ? "working" : "idle"), progress: args.progress,
    blockedOn: args["blocked-on"], leaseSeconds: numberArg("lease-seconds"),
    capabilities: listArg(args.capabilities),
  });
  if (!taskId) return { agent: registered };
  const claimed = await api(`/api/control-plane/tasks/${encodeURIComponent(taskId)}/claim`, "POST", {
    agentId: registered.id, sessionId, leaseSeconds: numberArg("lease-seconds"),
  });
  return { agent: registered, ...claimed };
}

async function heartbeat() {
  const manager = required("manager");
  const agent = required("agent");
  return api("/api/control-plane/agents/heartbeat", "POST", {
    agentId: agent.startsWith(`${manager}/`) ? agent : `${manager}/${agent}`,
    sessionId: required("session"), state: args.state, progress: args.progress,
    blockedOn: args["blocked-on"], taskState: args["task-state"], leaseSeconds: numberArg("lease-seconds"),
  });
}

async function complete() {
  const manager = required("manager");
  const agent = required("agent");
  const result = args["result-file"] ? readFileSync(resolve(args["result-file"]), "utf8") : required("result");
  return api(`/api/control-plane/tasks/${encodeURIComponent(required("task-id"))}/complete`, "POST", {
    agentId: agent.startsWith(`${manager}/`) ? agent : `${manager}/${agent}`,
    sessionId: required("session"), result, state: args.state ?? "done",
  });
}

async function watchQueue() {
  const manager = required("manager");
  const intervalMs = Math.max(1000, Number(args["interval-ms"] ?? 5000));
  let previous = "";
  while (true) {
    const snapshot = await api(`/api/control-plane/managers/${encodeURIComponent(manager)}/queue`);
    const serialized = JSON.stringify(snapshot);
    if (serialized !== previous) { process.stdout.write(`${JSON.stringify(snapshot)}\n`); previous = serialized; }
    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }
}

async function api(path, method = "GET", body) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: { Cookie: `engineering_room=${token}`, ...(body === undefined ? {} : { "Content-Type": "application/json" }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error ?? `Request failed (${response.status}).`);
  return payload;
}

function parseArgs(values) {
  const parsed = { _: [] };
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (!value.startsWith("--")) { parsed._.push(value); continue; }
    const key = value.slice(2);
    const next = values[index + 1];
    if (!next || next.startsWith("--")) parsed[key] = true;
    else { parsed[key] = next; index += 1; }
  }
  return parsed;
}
function required(key) { if (typeof args[key] !== "string" || !args[key].trim()) fail(`--${key} is required.`); return args[key].trim(); }
function numberArg(key) { return args[key] === undefined ? undefined : Number(args[key]); }
function listArg(value) { return typeof value === "string" ? value.split(",").map(item => item.trim()).filter(Boolean) : []; }
function readToken(path) { try { return readFileSync(path, "utf8").trim(); } catch { return ""; } }
function fail(message) { process.stderr.write(`team-control: ${message}\n`); process.exit(1); }
function usage() {
  process.stdout.write(`Usage:
  team-control.mjs board | ingest | brief [--publish] | standup [--publish]
  team-control.mjs queue --manager NAME | watch --manager NAME [--interval-ms 5000]
  team-control.mjs resume --manager NAME --agent NAME --session ID --task-id ID --task-title TITLE --machine none|m4|m5|m1 [--progress TEXT]
  team-control.mjs heartbeat --manager NAME --agent NAME --session ID [--state STATE] [--progress TEXT] [--task-state STATE]
  team-control.mjs complete --manager NAME --agent NAME --session ID --task-id ID (--result TEXT | --result-file PATH)
`);
  process.exit(0);
}
