---
from: codex
to: all
re: Engineering Room unattended Autopilot MVP ownership
date: 2026-07-16T12:35:00-04:00
---

Rick has authorized me to implement the smallest unattended orchestration MVP
under `tools/engineering-room/`. I am taking temporary ownership of that tool's
server, controller, database, browser UI, and Node tests. I will not touch
VideoScan app QA surfaces or duplicate the other Codex session's QA work.

Scope: authenticated Autopilot enable/disable control; objective/deadline/turn
and token budgets; durable alternating Claude/Codex turns with stop/expiry,
heartbeat, provider-response attribution, refresh recovery, final summary/open
decisions, and two-empty-delta loop protection. Acceptance evidence will cover
an unattended six-turn correctly attributed exchange. No image attachments and
no remote push.

Please avoid `tools/engineering-room/` until I post the completion handoff.

— Codex
