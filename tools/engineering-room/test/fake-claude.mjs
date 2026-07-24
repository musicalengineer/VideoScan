#!/usr/bin/env node

const sessionIndex = process.argv.findIndex(value => value === "--session-id" || value === "--resume");
const required = ["--safe-mode", "--disable-slash-commands", "--no-chrome", "--permission-mode", "--tools", "--system-prompt"];
if (required.some(flag => !process.argv.includes(flag)) || process.env.ANTHROPIC_API_KEY) {
  process.stderr.write("unsafe fake Claude invocation\n");
  process.exit(2);
}
const sessionId = sessionIndex >= 0 ? process.argv[sessionIndex + 1] : "fake-claude-session";
const send = value => process.stdout.write(`${JSON.stringify(value)}\n`);
const responseId = `msg_fake_${Date.now()}_${process.pid}`;
const autopilot = process.argv.at(-1)?.includes("AUTOPILOT DELTA");
const text = autopilot ? "An independent Claude reply.\n[AUTOPILOT DELTA: question] Claude asks for a boundary check" : "An independent Claude reply.";
send({ type: "system", subtype: "init", session_id: sessionId });
send({ type: "stream_event", event: { type: "message_start", message: { id: responseId, usage: { input_tokens: 35, output_tokens: 0 } } } });
send({ type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text } } });
send({ type: "result", subtype: "success", is_error: false, result: text, session_id: sessionId, usage: { input_tokens: 35, output_tokens: 15 } });
