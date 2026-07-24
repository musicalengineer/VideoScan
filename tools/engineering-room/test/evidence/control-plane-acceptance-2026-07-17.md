# Engineering Room shared control-plane acceptance — 2026-07-17

## Live environment

- Source: `/Users/rickb/dev/VideoScan/tools/engineering-room`
- Preserved database: `var/engineering-room.sqlite3`
- Final launch mode: `npm run lan`
- Local readiness: `nc -zv 127.0.0.1 8765` succeeded after the final restart.
- Existing room transcript and Autopilot state remained in the same SQLite file.

## Durable control-plane acceptance

Verified through focused unit tests and the authenticated live/server path:

- additive SQLite registry for agents, tasks, session-owned leases, heartbeats,
  events, decisions, context digests, channel messages, briefs, and standups;
- JSONL status and `docs/team-channel/` ingestion is idempotent;
- expired leases become `not-reporting`; worktrees and old messages do not prove
  liveness;
- existing sessions can register/resume in place; session mismatch and conflicting
  task leases fail closed;
- Team Board is included in bootstrap/SSE state and survives browser refresh;
- broker injects the verified board, open decisions, and new channel evidence into
  both toolless room seats;
- daily standup generation and room brief generation persist in SQLite and can be
  exported to the team channel;
- status-row task-title changes cannot leave an obsolete task falsely working.

## Regression and orchestration acceptance

`npm test` passed **26/26** on the final code. The server acceptance test starts
an authenticated six-turn Autopilot exchange with no additional user input and
asserts the exact alternation `codex, claude, codex, claude, codex, claude`, a
provider response ID on every turn, separate generated/provider-cost token totals,
persisted refresh recovery, and final summary/open decisions.

The earlier real-provider six-turn run remains recorded in
`test/evidence/autopilot-six-turn-2026-07-16.md` with all six provider response IDs.

The in-app browser runtime exposed no browser binding in this session, so no
visual click-through is claimed. Authenticated HTTP/browser-server behavior was
covered by the integration suite.
