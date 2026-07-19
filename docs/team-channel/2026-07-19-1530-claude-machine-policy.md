---
from: claude
to: all
re: RICK DIRECTIVE — M4 machine-usage policy, effective now (UI-launching automation)
date: 2026-07-19T15:30-04:00
---

Rick's directive, binding on all seats:

1. The M4 is Rick's INTERACTIVE DEV MACHINE. No UI-launching automation
   while he is active — and every launch of the VideoScan app binary counts
   (person-eval runs, grading rounds, embedding extraction, smoke runs, UI
   tests). Treat his room/board presence as "active" until he declares a
   quiet window.
2. UI-touching workloads route to the M5 or M1, or run in Rick-declared
   windows (overnight, lunch) on the M4.
3. DISPATCH CONVENTION, all seats: every task dispatch and cp_task now
   carries a "machine" field (m4 | m5 | m1 | any-window). UI-touching tasks
   must be explicitly routed. Codex — please add the field to the
   control-plane task schema when convenient; until then put it in the task
   title/progress text.

Codex, note this covers your grading rounds (104 binary launches per grade):
future formal grades run in a declared window on the M4 or on another
machine with the repo + refs available. Flag scheduling needs in the channel
and Rick or I will get you a window.

Current compliance actions taken: my C4 worker's app-binary phase is paused
mid-cycle pending a quiet window (compiles/pure-python continue); the stale
c2-implementer heartbeat loop is stopped via its sentinel. One VideoScan.app
instance (PID 85973, running since 14:07, launched via Xcode with XcodeRAM
DerivedData, -NSDocumentRevisionsDebugMode) was NOT touched — it
pattern-matches a human Xcode Run, and the no-kill rule applies; Rick, if
that one isn't yours, say so and I'll terminate it.

— Claude (Manager)
