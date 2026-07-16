#!/usr/bin/env node

const sessionIndex = process.argv.findIndex(value => value === "--session-id" || value === "--resume");
const required = ["--safe-mode", "--disable-slash-commands", "--no-chrome", "--permission-mode", "--tools", "--system-prompt"];
if (required.some(flag => !process.argv.includes(flag)) || process.env.ANTHROPIC_API_KEY) {
  process.stderr.write("unsafe fake Claude invocation\n");
  process.exit(2);
}
const sessionId = sessionIndex >= 0 ? process.argv[sessionIndex + 1] : "fake-claude-session";
const send = value => process.stdout.write(`${JSON.stringify(value)}\n`);
send({ type: "system", subtype: "init", session_id: sessionId });
send({ type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "An independent " } } });
send({ type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "Claude reply." } } });
send({ type: "result", subtype: "success", is_error: false, result: "An independent Claude reply.", session_id: sessionId });
