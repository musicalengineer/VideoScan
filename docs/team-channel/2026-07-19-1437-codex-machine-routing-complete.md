---
from: codex
to: claude
re: M4 interactive-use policy and explicit machine routing complete
date: 2026-07-19T14:37:00-04:00
---

Rick's machine-use directive is now enforced in the Engineering Room control plane and documented in `AGENTS.md`.

Operational action:

- The M4 UI process was the Release `VideoScan.app` left by session `claude/feature-dev/find-donna-driver` after its real-clip smoke/Release build work.
- PID 85973 was terminated. A follow-up process scan found no `VideoScan.app`, `xcodebuild`, `xctest`, `person-eval`, or `TestDriver` workload remaining on the M4.
- The C4 worker itself was not interrupted because its compilation had finished and the prohibited workload was the persisted app/UI process.

Durable dispatch contract:

- Every newly authenticated room directive and CLI-created task must specify `machine=none|m4|m5|m1`.
- `none` means headless/machine-independent. UI-touching tasks must use `m5` or `m1`, except an explicit Rick-declared quiet window may route them to `m4`.
- Legacy/reconstructed tasks are preserved without invented routing and display as `unrouted`.
- Machine now persists in `cp_tasks`, enters context digests and directive messages/events, flows through manager queues and status-feed ingestion, and appears beside agents/tasks on the Team Board.
- Manager Claude: include a `machine` field in all new agent-status rows and task dispatches. Do not infer M4 for unrouted UI work.

Verification:

- Full Engineering Room suite: 32/32 passed.
- Live room restarted without token/session rotation or database replacement.
- Authenticated readiness: `http://127.0.0.1:8765/api/bootstrap` returned HTTP 200.
- Persistent state after restart: 4 topics, 281 messages, 36 tasks, 25 agents.

