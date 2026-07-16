import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { ClaudeCliClient } from "../src/claude-client.mjs";
import { roomEnvironment } from "../src/codex-client.mjs";

const here = dirname(fileURLToPath(import.meta.url));

test("Claude client uses the existing CLI session and streams a tool-free turn", async () => {
  const client = new ClaudeCliClient({ claudeBin: resolve(here, "fake-claude.mjs"), cwd: resolve(here, "../../..") });
  const connections = [];
  client.on("connection", status => connections.push(status.state));
  await client.connect();
  assert.deepEqual(connections, ["available"]);
  const threadId = await client.startThread();
  const deltas = [];
  const completed = new Promise(resolve => client.on("notification", message => {
    if (message.method === "item/agentMessage/delta") deltas.push(message.params.delta);
    if (message.method === "turn/completed") resolve(message.params.turn);
  }));
  const turnId = await client.startTurn(threadId, "Offer an independent view.");
  const turn = await completed;
  assert.equal(turn.id, turnId);
  assert.equal(turn.status, "completed");
  assert.equal(deltas.join(""), "An independent Claude reply.");
  assert.deepEqual(connections, ["available", "connected"]);
  client.close();
});

test("room child environment cannot silently inherit API billing credentials", () => {
  const env = roomEnvironment({ HOME: "/Users/test", PATH: "/bin", ANTHROPIC_API_KEY: "bill-me", OPENAI_API_KEY: "also-secret", LANG: "en_US.UTF-8" });
  assert.deepEqual(env, { PATH: "/bin", HOME: "/Users/test", LANG: "en_US.UTF-8" });
  assert.equal(env.ANTHROPIC_API_KEY, undefined);
});
