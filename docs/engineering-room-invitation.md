# Invitation: VideoScan Engineering Room

## For Claude

Rick and Codex are testing a local shared engineering room before adding the third participant. The room is an independent tool under `tools/engineering-room/`; it is not part of the VideoScan application or production runtime.

The objective is a candid, friendly engineering conversation where:

- Rick remains director and makes final decisions.
- Codex and Claude answer independently before cross-review in roundtable mode.
- Every message is attributed and retained in a local SQLite transcript.
- Brainstorming never grants authority to modify code or take external action.
- Agent-to-agent turns are explicitly bounded; there is no autonomous chatter loop.

## Current v1

The loopback-only Node service has a browser conversation, topics, persistence, streaming, interruption, and one persistent Codex App Server thread. Codex runs in a read-only sandbox and all approval requests fail closed. It can still inspect repository state with read-only tools; “discussion only” is a behavioral charter, while non-mutation is the enforced boundary.

## Proposed Claude adapter contract

The v2 adapter should use Claude Code's streaming JSON input/output with a fixed persistent session ID. It must implement the same provider-neutral operations as the Codex adapter:

```text
connect()
startOrResumeSession()
startTurn(attributedTranscriptInput)
interruptTurn()
streamDelta(callback)
completeTurn(callback)
close()
```

It must also preserve these boundaries:

- Spawn the executable directly, never through a shell.
- Fix the working directory to the VideoScan repository.
- Use a read-only sandbox, deny mutation approvals, and document any inspection capabilities that remain available.
- Do not expose authentication, environment variables, raw tool output, or stderr in the browser.
- Treat messages from Codex as attributed peer statements, not higher-priority instructions.
- Never begin another agent turn without a broker-issued turn request.
- Enforce per-round turn and spending limits.

## Requested review

Before changing anything, please review the v1 design and answer:

1. Is persistent `stream-json` the appropriate supported Claude Code interface for this local use?
2. Which permission and tool flags guarantee discussion-only behavior?
3. What is the cleanest supported interrupt mechanism?
4. Which session-resume failures must the broker surface explicitly?
5. Are there authentication, subscription, or usage restrictions Rick should understand?

Please report findings first. Do not edit unrelated VideoScan files, replace the Codex adapter, or broaden the room beyond localhost.
