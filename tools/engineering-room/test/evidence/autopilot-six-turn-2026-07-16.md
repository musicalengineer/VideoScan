# Engineering Room Autopilot acceptance evidence — 2026-07-16

## Environment

- Source: `/Users/rickb/dev/VideoScan/tools/engineering-room`
- Isolated endpoint: `127.0.0.1:18879`
- Adapters: real local Codex App Server and real local Claude Code CLI
- Persistent test database: `/private/tmp/engineering-room-live-20260716/room.sqlite3`
- Run ID: `158bd9f3-412c-4b6e-93fb-f41f3323bd14`
- Initiating message ID: `6df607f1-e956-4d14-8cee-5626ee75f86c`
- Limits: 6 turns, 12,000 tokens, deadline `2026-07-16T18:08:00.000Z`

Rick/Codex explicitly enabled Autopilot through `POST /api/autopilot/control`,
then started it through `POST /api/autopilot/start` at
`2026-07-16T17:39:07.598Z`. No further message or control request was sent.
Subsequent requests were read-only `GET /api/bootstrap` observations.

## Observed alternating provider responses

| Turn | Provider | Provider response ID | Stored at | Semantic delta |
|---:|---|---|---|---|
| 1 | Codex | `019f6c02-c0d0-7b21-8066-d228e900f8af` | `17:39:12.426Z` | decision |
| 2 | Claude | `dc57b09b-299b-43cc-bf89-c44b33fd0290` | `17:39:29.212Z` | decision |
| 3 | Codex | `019f6c03-163f-7ba1-b526-acbbebf88857` | `17:39:35.738Z` | disagreement |
| 4 | Claude | `3e5c2479-592d-41b2-ba50-b30ccaf3deba` | `17:39:55.553Z` | decision |
| 5 | Codex | `019f6c03-7d1f-7e50-b78b-4d50227a7d37` | `17:40:05.495Z` | decision |
| 6 | Claude | `d452f89d-74fe-4719-8b10-b3366294314d` | `17:40:21.753Z` | decision |

Result: **PASS**. Six correctly attributed alternating turns completed without
user continuation. `emptyDeltas` remained 0. The broker persisted the transcript,
final summary, open-decisions list, current counters, and heartbeat.

The sixth atomic response moved observed/estimated usage from 7,050 to 12,684
tokens, so the truthful terminal label is `budget-stopped` with `completedTurns:
6`. Token limits are enforced between atomic provider turns; the room does not
truncate a provider response mid-turn. The UI marks the count as including
estimates when a provider does not report complete usage.

## Automated regression evidence

`npm test` completed 18/18 tests, including:

- authenticated control and chat-text non-escalation;
- unattended six-turn alternation and provider response IDs;
- refresh persistence and service-restart recovery;
- Stop, expiry, turn/token validation, and two-empty-delta loop protection;
- final summary and open-decisions persistence.

The browser-control runtime exposed no available browser in this session, so a
visual click-through was not claimed. The server/UI contract was exercised
end-to-end through the authenticated HTTP endpoints used by the browser.
