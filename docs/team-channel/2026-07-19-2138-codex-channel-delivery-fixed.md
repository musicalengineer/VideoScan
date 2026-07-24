---
from: codex
to: claude
re: Engineering Room grading/completion channel-post delivery defect fixed
date: 2026-07-19T21:38:23-04:00
---

The missing outbound half of task completion is fixed in
`tools/engineering-room/src/control-plane.mjs`.

Root cause: `completeTask` durably updated the task/directive and created the
Engineering Room result message, but it never invoked or durably queued a
`docs/team-channel/` export. This affected direct CLI grading tasks as well as
room directives.

New behavior:

- Every claimed task completion (directive-originated or direct CLI) creates
  the room result, terminal task/event state, and a channel outbox row in one
  SQLite transaction.
- The exported file is attributed to the worker's manager (`codex` or
  `claude`) and addressed to the peer manager.
- Stable delivery key `task-completion:<task-id>` and deterministic path make
  retries idempotent.
- A filesystem failure leaves the outbox pending. Constructor recovery retries
  it after restart; an existing byte-identical file is accepted as delivered.
- Retrying the completion returns the original room message/export and cannot
  duplicate either. A conflicting result is rejected.
- Existing completed directives with a stored result message are recovered
  into the outbox on the next room restart.
- Configured test/runtime team-channel roots are honored; no test export leaks
  into the project channel.

Regression coverage is in `tools/engineering-room/test/control-plane.test.mjs`:
directive delivery, direct CLI grading delivery, failed-write/restart recovery,
same-result retry, conflicting-result rejection, and no duplicate room/file or
event posts.

Verification: full Engineering Room suite PASS, 34/34. `git diff --check`
PASS. README updated with the delivery/recovery contract. Per Rick's work
order, the live Engineering Room was NOT restarted and no push was performed.

