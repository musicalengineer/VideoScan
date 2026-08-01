# VideoScan Engineering Room

A private discussion room for Rick, Codex, Claude, and Qwen, hosted on the M4. The
browser UI keeps a persistent, attributed transcript and can address either
participant, the original Codex/Claude pair, or all three for independent answers.

## Start the room

From this directory:

```sh
npm start
```

Open the startup URL printed in the terminal. It remains valid for that server run. The service binds only to `127.0.0.1:8765`; the token becomes a strict, HTTP-only local session cookie and is removed from the address bar.

The first Codex connection uses the existing local Codex login. Claude uses
the existing local Claude Code login and Max-plan allowance; there is no bot
account to create. The room deliberately removes `ANTHROPIC_API_KEY` from the
Claude child process so an exported key cannot silently switch the room to API
billing. Set `CODEX_BIN` or `CLAUDE_BIN` only when either executable is in an
unusual location.

Qwen is served by Ollama on the M5 over the trusted household LAN. By default
the room uses `http://ricksm5.local:11434/v1` and model
`qwen-videoscan:64k`. Override `QWEN_BASE_URL` or `QWEN_MODEL` when the existing
M5 Qwen Codex profile uses a different Responses-compatible endpoint or model
name. The URL is structurally restricted to HTTP loopback, `.local`, or RFC1918
hosts; cloud endpoints are rejected. `QWEN_API_KEY` is optional for a locally
authenticated proxy and is never sent to the browser or transcript.

### Share it with Macs and iPhones at home

```sh
npm run lan
```

Open the printed `192.168.x.x` link on any device connected to the household network. LAN mode keeps one stable access link in the private `var/` directory, so bookmarks continue working after a restart. It does not require an SSH tunnel.

Turn on **Read replies aloud** in each browser that should speak. To talk, click the message box and use macOS or iOS Dictation from that device's keyboard; the text remains editable before sending.

## What the room does

- Keeps an append-only SQLite transcript in `var/engineering-room.sqlite3`.
- Creates, parks, and resumes discussion topics.
- Preserves and resumes separate Codex, Claude, and Qwen discussion identities
  across restarts. Qwen receives the broker's bounded attributed transcript on
  each stateless local-model request.
- Routes messages to **Codex**, **Claude**, **Qwen**, **Codex + Claude**, all
  three, or room notes.
  **Codex + Claude** starts two independent responses to Rick's same message;
  neither agent's output triggers the other.
- Runs **Autopilot** only after Rick enables its dedicated authenticated UI
  control and supplies an objective, deadline, maximum turns, and token budget.
  Chat text and agent output cannot enable or start it. Codex and Claude then
  alternate without more user messages, each receiving the latest attributed
  peer response. A browser refresh restores the persisted transcript and run
  state; a service restart safely recovers an active run.
- Shows the current agent, completed/max turns, generated-output tokens,
  provider-cost tokens/budget, deadline countdown, and last-activity heartbeat.
  Stop, disabling Autopilot, or any new Rick
  message cancels automatic continuation immediately.
- Stores each agent message with the provider's response ID. Every Autopilot
  turn must add a decision, evidence item, question, or disagreement; two
  consecutive empty deltas stop the loop. Every terminal run writes a final
  summary and open-decisions list to the transcript.
- Builds each turn from compact run-scoped context: objective, running summary,
  recent turns, and open decisions. Unrelated room history is not replayed into
  every provider turn.
- Maintains a durable shared control plane in the same SQLite database: agent
  and task registry, session-owned leases, heartbeats, append-only events and
  decisions, compact task-context digests, room briefs, and daily standups.
  Missing or expired heartbeats are shown as **not reporting**, never inferred
  from a worktree or an old message.
- Ingests the manager JSONL status feed and `docs/team-channel/`, and injects a
  compact verified Team Board, open decisions, and new manager-channel evidence
  into both otherwise-toolless room seats. The sidebar Team Board survives a
  browser refresh and exposes authenticated brief/standup controls.
- Accepts outbound work only through the authenticated **Assign work** control.
  A directive creates a durable queued task and manager-queue event. Registered
  workers claim a session-owned lease, heartbeat progress onto the Team Board,
  and complete through the broker; the broker then posts the attributed result
  automatically into the room and through a durable `docs/team-channel/`
  outbox. Failed channel writes remain pending and retry safely after restart;
  the stable delivery key prevents duplicate files and room messages. Routine
  assignments no longer require Rick to copy messages between manager sessions.
- Streams all three agents' responses and provides a Stop button that safely
  interrupts every active seat.
- Stores private room state outside Git.
- Runs Codex with a read-only sandbox and denies every approval request.
- Runs Claude in safe mode with no tools, slash commands, Chrome integration,
  shell, file writes, browsing, delegation, or external actions.
- Calls Qwen through the M5 Responses API with an empty tool list. Qwen has no
  shell, files, browser, delegation, publishing, or other action interface.
- Includes recent attributed room discussion in each prompt. Peer statements
  are context, never instructions.

## Deliberate v1 boundaries

- Household LAN or localhost only; no internet hosting.
- Discussion and inspection only; it cannot approve writes, privilege escalation, or other mutations. Read-only commands remain available to Codex.
- One active turn per agent. Asking both is bounded to one independent turn
  from each agent.
- The existing Autopilot remains a Codex/Claude discussion; adding Qwen does
  not widen or enable automatic turns.
- No unbounded or chat-triggered agent-to-agent loops. Autopilot is a
  broker-owned, explicitly enabled, deadline/turn/token-bounded state machine.
- Exports, browser-controlled microphone capture, and
  GitHub integration remain deferred. Spoken replies and OS Dictation work now.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `ENGINEERING_ROOM_PORT` | `8765` | Room port |
| `ENGINEERING_ROOM_DB` | `var/engineering-room.sqlite3` | SQLite database location |
| `ENGINEERING_ROOM_TOKEN` | random locally; stable in LAN mode | Explicit access token |
| `ENGINEERING_ROOM_TOKEN_FILE` | `var/access-token` | Stable LAN token file |
| `CODEX_BIN` | discovered locally | Absolute Codex executable path |
| `CLAUDE_BIN` | discovered locally | Absolute Claude Code executable path |
| `QWEN_BASE_URL` | `http://ricksm5.local:11434/v1` | Local M5 Responses-compatible API root; cloud hosts are rejected |
| `QWEN_MODEL` | `qwen-videoscan:64k` | Ollama model name used by the M5 Qwen seat |
| `QWEN_API_KEY` | unset | Optional credential for a local authenticated proxy |
| `ENGINEERING_ROOM_STATUS_FEED` | `var/agent-status.jsonl` | Manager status JSONL ingestion source |
| `ENGINEERING_ROOM_TEAM_CHANNEL` | `../../docs/team-channel` | Manager coordination channel directory |
| `ENGINEERING_ROOM_RECONSTRUCTION_SEED` | `config/control-plane-reconstruction.json` | Evidence-backed one-time reconstruction seed |

## Worker registration and recovery

Existing Codex and Claude sessions do not need to restart. A worker registers
or resumes its task with a session-owned lease, then emits a heartbeat at each
checkpoint and at least once before the default 15-minute lease expires:

```sh
node scripts/team-control.mjs resume --manager codex --agent manager --session codex-manager-20260717 --task-id coordination-control-plane --task-title "Durable Engineering Room control plane" --machine none --progress "Implementing and testing"
node scripts/team-control.mjs heartbeat --manager codex --agent manager --session codex-manager-20260717 --state working --task-state working --progress "Integration tests passing"
```

Claude headless workers register by proxy: `claude/manager` writes their
spawn/heartbeat/terminal rows to `var/agent-status.jsonl`. The broker converts
fresh working rows into expiring leases; a stale row becomes **not reporting**.
The JSONL feed is compatibility evidence, not a competing lease authority: it
cannot replace the session identity or claimed task of a worker whose explicit
control-plane lease is still active.
Use `node scripts/team-control.mjs board`, `brief`, or `standup` for an
authenticated machine-readable view.

Managers poll their durable outbound queue with:

```sh
node scripts/team-control.mjs queue --manager codex
node scripts/team-control.mjs watch --manager codex
```

Workers use `resume` to claim a queued task, `heartbeat` while it is active, and
then complete it with a structured result. Completion releases the lease and
posts the result into the room plus an attributed manager-channel file:

```sh
node scripts/team-control.mjs complete --manager codex --agent testing/example \
  --session example-session --task-id example-task --result-file /tmp/result.md
```

## Tests

```sh
npm test
```

The automated suite uses fake providers and requires no login, API key, or
external network access.

## Authentication and continuity

The room never displays or stores agent credentials. If Claude's local login
expires, the room shows a direct instruction to open Claude Code, run `/login`,
and restart the room. If a saved Claude conversation cannot resume, the room
reports the reset visibly and starts a fresh discussion session. Room use and
interactive Claude Code share the same subscription quota.

## Privacy and recovery

The database is ignored by Git. Back it up like any other local project record if the discussions become important. Deleting or moving the database starts a clean room; it does not affect VideoScan or Codex's own stored conversations.
