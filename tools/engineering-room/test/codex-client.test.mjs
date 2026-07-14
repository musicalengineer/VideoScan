import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { CodexAppServerClient } from "../src/codex-client.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const fake = resolve(here, "fake-codex.mjs");

test("Codex client initializes, starts a persistent thread, and streams a turn", async () => {
  const client = new CodexAppServerClient({ codexBin: fake, cwd: resolve(here, "../../..") });
  await client.connect();
  const threadId = await client.startThread();
  assert.equal(threadId, "fake-thread");
  const deltas = [];
  const completed = new Promise(resolve => client.on("notification", message => {
    if (message.method === "item/agentMessage/delta") deltas.push(message.params.delta);
    if (message.method === "turn/completed") resolve(message.params.turn);
  }));
  const turnId = await client.startTurn(threadId, "What matters today?");
  assert.equal(turnId, "fake-turn-1");
  const turn = await completed;
  assert.equal(deltas.join(""), "A measured reply.");
  assert.equal(turn.status, "completed");
  client.close();
});
