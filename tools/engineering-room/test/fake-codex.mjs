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
    const autopilot = request.params.input?.some(item => item.text?.includes("AUTOPILOT DELTA"));
    const text = autopilot ? `A measured reply.\n[AUTOPILOT DELTA: evidence] Codex evidence ${turnNumber}` : "A measured reply.";
    send({ id: request.id, result: { turn: { id: turnId, status: "inProgress", items: [] } } });
    setTimeout(() => send({ method: "item/agentMessage/delta", params: { threadId: request.params.threadId, turnId, itemId: `item-${turnNumber}`, delta: text } }), 10);
    setTimeout(() => send({ method: "turn/completed", params: { threadId: request.params.threadId, turn: { id: turnId, status: "completed", usage: { input_tokens: 40, output_tokens: 10 }, items: [{ id: `item-${turnNumber}`, type: "agentMessage", text, phase: "final_answer" }] } } }), 20);
    return;
  }
  if (request.method === "turn/interrupt") return send({ id: request.id, result: {} });
  if (request.id !== undefined) send({ id: request.id, error: { code: -32601, message: "Unknown fake method" } });
});
