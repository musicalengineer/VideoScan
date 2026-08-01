import test from "node:test";
import assert from "node:assert/strict";
import { QwenResponsesClient, QWEN_ROOM_CHARTER } from "../src/qwen-client.mjs";

test("Qwen client sends a tool-free request to the exact local model and streams provider metadata", async () => {
  const requests = [];
  const fetchImpl = async (url, init = {}) => {
    requests.push({ url, init });
    if (url.endsWith("/models")) return new Response(JSON.stringify({ data: [] }), { status: 200 });
    const events = [
      { type: "response.created", response: { id: "resp_qwen_local_1" } },
      { type: "response.output_text.delta", response_id: "resp_qwen_local_1", delta: "A local " },
      { type: "response.output_text.delta", response_id: "resp_qwen_local_1", delta: "Qwen reply." },
      { type: "response.completed", response: { id: "resp_qwen_local_1", usage: { input_tokens: 23, output_tokens: 7, total_tokens: 30 } } },
    ];
    const stream = `${events.map(event => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`;
    return new Response(stream, { status: 200, headers: { "Content-Type": "text/event-stream" } });
  };
  const client = new QwenResponsesClient({
    baseUrl: "http://127.0.0.1:11434/v1/",
    model: "qwen3.6:35b-a3b-nvfp4",
    apiKey: "local-test-key",
    fetchImpl,
  });

  await client.connect();
  const threadId = await client.startThread();
  const deltas = [];
  const completed = new Promise(resolve => client.on("notification", message => {
    if (message.method === "item/agentMessage/delta") deltas.push(message.params.delta);
    if (message.method === "turn/completed") resolve(message.params);
  }));
  const turnId = await client.startTurn(threadId, "Review the mux plan.");
  const result = await completed;

  assert.equal(requests[0].url, "http://127.0.0.1:11434/v1/models");
  assert.equal(requests[0].init.redirect, "error", "model discovery must not follow a redirect off the local host");
  assert.equal(requests[1].url, "http://127.0.0.1:11434/v1/responses");
  assert.equal(requests[1].init.redirect, "error", "generation must not follow a redirect off the local host");
  const request = JSON.parse(requests[1].init.body);
  assert.deepEqual(request, {
    model: "qwen3.6:35b-a3b-nvfp4",
    instructions: QWEN_ROOM_CHARTER,
    input: "Review the mux plan.",
    stream: true,
    store: false,
    tools: [],
  });
  assert.equal(requests[1].init.headers.Authorization, "Bearer local-test-key");
  assert.match(request.instructions, /strictly discussion-only/i);
  assert.match(request.instructions, /no tools/i);
  assert.deepEqual(Object.getOwnPropertyNames(QwenResponsesClient.prototype).sort(),
    ["close", "connect", "constructor", "interrupt", "resumeThread", "startThread", "startTurn"].sort(),
    "the room seat must expose no approval or action method");
  assert.equal(deltas.join(""), "A local Qwen reply.");
  assert.equal(result.responseId, "resp_qwen_local_1");
  assert.equal(result.turn.id, turnId);
  assert.equal(result.turn.status, "completed");
  assert.deepEqual(result.turn.usage, { input_tokens: 23, output_tokens: 7, total_tokens: 30 });
  assert.equal(result.turn.items[0].text, "A local Qwen reply.");
  client.close();
});

test("Qwen client parses SSE when CRLF is split across transport chunks", async () => {
  const encoder = new TextEncoder();
  const chunks = [
    `data: ${JSON.stringify({ type: "response.created", response: { id: "resp_split_crlf" } })}\r`,
    `\n\r`,
    `\ndata: ${JSON.stringify({ type: "response.output_text.delta", response_id: "resp_split_crlf", delta: "Split-safe." })}\r`,
    `\n\r`,
    `\ndata: ${JSON.stringify({ type: "response.completed", response: { id: "resp_split_crlf", usage: { total_tokens: 9 } } })}\r`,
    "\n\r",
    "\ndata: [DONE]\r",
    "\n\r",
    "\n",
  ];
  const fetchImpl = async () => new Response(new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      controller.close();
    },
  }), { status: 200, headers: { "Content-Type": "text/event-stream" } });
  const client = new QwenResponsesClient({ baseUrl: "http://127.0.0.1:11434/v1", model: "qwen-local", fetchImpl });
  const threadId = await client.startThread();
  const completed = new Promise((resolve, reject) => {
    client.on("turnError", error => reject(new Error(error.message)));
    client.on("notification", message => {
      if (message.method === "turn/completed") resolve(message.params);
    });
  });
  await client.startTurn(threadId, "Exercise split CRLF.");
  const result = await completed;
  assert.equal(result.responseId, "resp_split_crlf");
  assert.equal(result.turn.items[0].text, "Split-safe.");
  assert.deepEqual(result.turn.usage, { total_tokens: 9 });
  client.close();
});

test("Qwen client explicitly interrupts its active local response", async () => {
  let aborted = false;
  const fetchImpl = async (url, init = {}) => {
    if (url.endsWith("/models")) return new Response("{}", { status: 200 });
    return new Promise((_, reject) => {
      init.signal.addEventListener("abort", () => {
        aborted = true;
        reject(Object.assign(new Error("aborted"), { name: "AbortError" }));
      }, { once: true });
    });
  };
  const client = new QwenResponsesClient({ baseUrl: "http://localhost:11434/v1", model: "qwen-local", fetchImpl });
  const threadId = await client.startThread();
  const completed = new Promise(resolve => client.on("notification", message => {
    if (message.method === "turn/completed") resolve(message.params.turn);
  }));
  const turnId = await client.startTurn(threadId, "Wait for Stop.");
  await client.interrupt(threadId, turnId);
  const turn = await completed;
  assert.equal(aborted, true);
  assert.equal(turn.status, "interrupted");
  assert.equal(turn.id, turnId);
  client.close();
});

test("Qwen client rejects cloud and non-local endpoints before making a request", () => {
  for (const baseUrl of [
    "https://127.0.0.1:11434/v1",
    "http://api.openai.com/v1",
    "http://8.8.8.8/v1",
    "http://172.15.0.1/v1",
    "http://192.169.1.1/v1",
  ]) {
    assert.throws(
      () => new QwenResponsesClient({ baseUrl, model: "qwen-local", fetchImpl: () => assert.fail("network must not be called") }),
      /trusted local network|loopback, \.local, or RFC1918/,
      baseUrl,
    );
  }
});
