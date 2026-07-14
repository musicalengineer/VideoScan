# VideoScan Engineering Room

A private, local discussion room for Rick and Codex. Claude is deliberately deferred until the room has been tested with two participants.

## Start the room

From this directory:

```sh
npm start
```

Open the startup URL printed in the terminal. It remains valid for that server run. The service binds only to `127.0.0.1:8765`; the token becomes a strict, HTTP-only local session cookie and is removed from the address bar.

The first Codex connection uses the existing local Codex login. Set `CODEX_BIN` only if Codex is installed somewhere other than `~/.local/bin/codex`.

### Share it with Macs and iPhones at home

```sh
npm run lan
```

Open the printed `192.168.x.x` link on any device connected to the household network. LAN mode keeps one stable access link in the private `var/` directory, so bookmarks continue working after a restart. It does not require an SSH tunnel.

Turn on **Read replies aloud** in each browser that should speak. To talk, click the message box and use macOS or iOS Dictation from that device's keyboard; the text remains editable before sending.

## What v1 does

- Keeps an append-only SQLite transcript in `var/engineering-room.sqlite3`.
- Creates, parks, and resumes discussion topics.
- Preserves and resumes one Codex discussion thread across room restarts.
- Streams Codex's response and provides a Stop button.
- Stores private room state outside Git.
- Runs Codex with a read-only sandbox and denies every approval request. Codex may still inspect the repository with read-only tools when useful to the discussion.

## Deliberate v1 boundaries

- Household LAN or localhost only; no internet hosting.
- Discussion and inspection only; it cannot approve writes, privilege escalation, or other mutations. Read-only commands remain available to Codex.
- One active Codex turn at a time.
- No autonomous agent-to-agent loops.
- Claude, roundtables, exports, browser-controlled microphone capture, and GitHub integration wait until v2. Spoken replies and OS Dictation work now.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `ENGINEERING_ROOM_PORT` | `8765` | Room port |
| `ENGINEERING_ROOM_DB` | `var/engineering-room.sqlite3` | SQLite database location |
| `ENGINEERING_ROOM_TOKEN` | random locally; stable in LAN mode | Explicit access token |
| `ENGINEERING_ROOM_TOKEN_FILE` | `var/access-token` | Stable LAN token file |
| `CODEX_BIN` | discovered locally | Absolute Codex executable path |

## Tests

```sh
npm test
```

The automated suite uses a fake Codex App Server. It requires no login, API key, or network access.

## Privacy and recovery

The database is ignored by Git. Back it up like any other local project record if the discussions become important. Deleting or moving the database starts a clean room; it does not affect VideoScan or Codex's own stored conversations.
