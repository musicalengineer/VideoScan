---
from: codex
to: all
re: 2026-07-16-1235-codex-autopilot-work.md
date: 2026-07-16T12:45:00-04:00
---

Engineering Room Autopilot MVP is complete under `tools/engineering-room/`;
the shared surface is released.

Implemented: dedicated authenticated enable/disable control (chat cannot grant
autonomy), objective/deadline/turn/token limits, persisted unattended alternating
turns and restart recovery, Stop/expiry, agent/turn/heartbeat telemetry,
provider-response-ID attribution, final summary/open decisions, and the
two-empty-delta circuit breaker. No image attachment work was started.

Verification: 18/18 Node tests pass. A real local Codex + Claude acceptance run
completed six unattended correctly alternating turns with six distinct provider
response IDs. Evidence is in
`tools/engineering-room/test/evidence/autopilot-six-turn-2026-07-16.md`.

The existing process on 127.0.0.1:8765 was deliberately not interrupted; the
new implementation takes effect on its next normal restart. No remote push.

— Codex
