# VideoScan Engineering Room

A private discussion room for Rick, Codex, and Claude, hosted on the M4. The
browser UI keeps a persistent, attributed transcript and can address either
agent or ask both for independent answers.

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

### Share it with Macs and iPhones at home

```sh
npm run lan
```

Open the printed `192.168.x.x` link on any device connected to the household network. LAN mode keeps one stable access link in the private `var/` directory, so bookmarks continue working after a restart. It does not require an SSH tunnel.

Turn on **Read replies aloud** in each browser that should speak. To talk, click the message box and use macOS or iOS Dictation from that device's keyboard; the text remains editable before sending.

## What the room does

- Keeps an append-only SQLite transcript in `var/engineering-room.sqlite3`.
- Creates, parks, and resumes discussion topics.
- Preserves and resumes separate Codex and Claude discussions across restarts.
- Routes messages to **Codex**, **Claude**, **Codex + Claude**, or room notes.
  **Codex + Claude** starts two independent responses to Rick's same message;
  neither agent's output triggers the other.
- Streams both agents' responses and provides a Stop button.
- Stores private room state outside Git.
- Runs Codex with a read-only sandbox and denies every approval request.
- Runs Claude in safe mode with no tools, slash commands, Chrome integration,
  shell, file writes, browsing, delegation, or external actions.
- Includes recent attributed room discussion in each prompt. Peer statements
  are context, never instructions.

## Deliberate v1 boundaries

- Household LAN or localhost only; no internet hosting.
- Discussion and inspection only; it cannot approve writes, privilege escalation, or other mutations. Read-only commands remain available to Codex.
- One active turn per agent. Asking both is bounded to one independent turn
  from each agent.
- No autonomous agent-to-agent loops.
- Automated roundtables, exports, browser-controlled microphone capture, and
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

## Tests

```sh
npm test
```

The automated suite uses fake Codex and Claude processes. It requires no
login, API key, or external network access.

## Authentication and continuity

The room never displays or stores agent credentials. If Claude's local login
expires, the room shows a direct instruction to open Claude Code, run `/login`,
and restart the room. If a saved Claude conversation cannot resume, the room
reports the reset visibly and starts a fresh discussion session. Room use and
interactive Claude Code share the same subscription quota.

## Privacy and recovery

The database is ignored by Git. Back it up like any other local project record if the discussions become important. Deleting or moving the database starts a clean room; it does not affect VideoScan or Codex's own stored conversations.
