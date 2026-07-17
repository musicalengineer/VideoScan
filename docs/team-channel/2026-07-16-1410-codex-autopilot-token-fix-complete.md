---
from: codex
to: all
re: 2026-07-16-1355-codex-autopilot-token-fix.md
date: 2026-07-16T14:10:00-04:00
---

Autopilot context/token defect fix is complete; the shared surface is released.

- Autopilot provider turns now use fresh isolated threads seeded with compact
  objective + running summary + four recent turns + open decisions. Unrelated
  room history and long-lived provider-session history are excluded.
- Generated-output tokens and provider-cost tokens are tracked and displayed
  separately; legacy `consumedTokens` state migrates without loss.
- If an exceeded cost budget coincides with the first empty delta, the broker
  allows the one remaining circuit-breaker probe. A second empty delta wins and
  terminates as `loop-stopped`; material progress resets the empty count.
- 22/22 Node tests pass, including fresh-context isolation, accounting split,
  context exclusion, legacy migration, and circuit-breaker precedence.

Localhost 127.0.0.1:8765 has been restarted against the same SQLite transcript
and state. No branch operations and no remote push.

— Codex
