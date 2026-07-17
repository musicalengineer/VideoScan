# Agent Dashboard — Team Comms + Fleet Status (Design Sketch)

*Rick's vision, captured 2026-07-16. Not yet scheduled. Extends the local
engineering room (tools/engineering-room/) — same host, same discipline.*

## The org chart it serves

- **Rick — CTO.** Final say, sets direction, spot-tests.
- **Claude — chief engineer**, with dev subagents (feature-dev, bug-fix,
  refactor, performance, metrics, qa).
- **Codex — chief test engineer**, with its own test/UI-automation underlings.

The managers already coordinate (team channel → engineering room). What's
missing is *visibility into the fleets*: Rick should see what every subagent
is doing without asking.

## One window, two panes

### Pane 1 — Manager chat (exists: engineering room)
The three-seat conversation. Morning **standup ritual**: the three managers
sync — yesterday's results, today's plan, blockers — so Rick gets on the same
page in one place instead of reading two terminals and a log directory.

### Pane 2 — Agent status board (new)
Live table of every agent and subagent across both fleets:

| Column | Example |
|---|---|
| Agent | claude/feature-dev #af99… |
| Manager | Claude |
| Task | "video-only catalog scope" |
| State | **working / idle / blocked / waiting-on-human / done** |
| Progress | "chunk 2 of 3, suite running" |
| Since | 14:32 |
| Blocked on | "needs Rick: schema sign-off" |

Interaction model Rick described: *"Claude, are your dev guys working on
x, y, z? Codex, I see you started testing feature Y."* — i.e., the board is
shared context the chat refers to. **Blocked/waiting-on-human states are the
highest-value signal** — they're where Rick's attention actually unblocks
work.

## Feed mechanics (sketch, cheapest-first)

- Each manager already knows its subagents' states (Claude: Task/Agent
  tracking; Codex: its own harness). Cheapest v1: each manager appends
  status lines to a shared JSONL (`var/agent-status.jsonl` beside the room's
  SQLite) — `{agent, manager, task, state, progress, since, blockedOn}` —
  and the room UI renders the latest row per agent. Append-only, attributed,
  same pattern as everything else we build.
- v2: managers update status as part of dispatching/receiving agent results
  (automatic, no discipline required).
- Standup: a room command (`!standup`) that snapshots the board + asks each
  manager for a three-line summary, archived to the transcript.

## Boundaries (inherited from the room charter)

- Status board is *observability*, not control — no start/stop buttons in v1;
  Rick directs managers in chat, managers direct their fleets.
- Same localhost/LAN-only, attributed, append-only discipline.

## Open questions

1. Codex's subagent model — does its harness expose per-task state cleanly?
2. Claude-side: main session knows its subagents, but sessions end; a session
   handoff means stale rows. TTL + "last seen" honesty beats fake liveness.
3. Where standup notes live (transcript vs docs/) — probably transcript.

## Related

- tools/engineering-room/ (chat pane exists), docs/team-channel/ (interim),
  [[three-way-team-structure]] in Claude's memory, codex's roundtable work.
