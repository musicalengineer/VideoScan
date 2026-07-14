#!/usr/bin/env node
import { createInterface } from "node:readline";

const lines = createInterface({ input: process.stdin });
let turnNumber = 0;

function send(message) { process.stdout.write(`${JSON.stringify(message)}\n`); }

lines.on("line", line => {
  const request = JSON.parse(line);
  if (request.method === "initialized") return;
  if (request.method === "initialize") return send({ id: request.id, result: { userAgent: "fake", platformFamily: "unix", platformOs: "macos" } });
  if (request.method === "thread/start") return send({ id: request.id, result: { thread: { id: "fake-thread", status: { type: "idle" }, turns: [] } } });
  if (request.method === "thread/resume") return send({ id: request.id, result: { thread: { id: request.params.threadId, status: { type: "idle" }, turns: [] } } });
  if (request.method === "turn/start") {
    const turnId = `fake-turn-${++turnNumber}`;
    send({ id: request.id, result: { turn: { id: turnId, status: "inProgress", items: [] } } });
    setTimeout(() => send({ method: "item/agentMessage/delta", params: { threadId: request.params.threadId, turnId, itemId: `item-${turnNumber}`, delta: "A measured " } }), 10);
    setTimeout(() => send({ method: "item/agentMessage/delta", params: { threadId: request.params.threadId, turnId, itemId: `item-${turnNumber}`, delta: "reply." } }), 20);
    setTimeout(() => send({ method: "turn/completed", params: { threadId: request.params.threadId, turn: { id: turnId, status: "completed", items: [{ id: `item-${turnNumber}`, type: "agentMessage", text: "A measured reply.", phase: "final_answer" }] } } }), 30);
    return;
  }
  if (request.method === "turn/interrupt") return send({ id: request.id, result: {} });
  if (request.id !== undefined) send({ id: request.id, error: { code: -32601, message: "Unknown fake method" } });
});
