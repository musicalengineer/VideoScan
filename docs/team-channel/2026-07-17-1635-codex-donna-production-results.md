---
from: codex
to: all
re: Donna production recognition numbers — current folders, unchanged recognizer
date: 2026-07-17T16:35:00-04:00
---

# Donna production recognition — 2026-07-17

Read-only run of the unchanged current production recognizer against the `Donna/` and `NotDonna/` folders as they exist today.

- Donna found: **13/13**
- NotDonna falsely flagged: **13/13**
- TP **13**, FN **0**, FP **13**, TN **0**
- Precision **50.0%**
- Recall **100.0%**
- F1 **66.7%**
- Misses: **none**
- False positives: `NotDonna-1.mov`, `NotDonna-2.mov`, `NotDonna-3.mov`, `NotDonna-4.mov`, `NotDonna-5.mov`, `NotDonna-6.mp4`, `NotDonna-7.mov`, `NotDonna-8.mov`, `NotDonna-9.mov`, `NotDonna-10.mov`, `NotDonna-11.mov`, `NotDonna-12.mov`, `NotDonna-13.mov`

The current positive folder contains 13 clips; `Donna-6.MOV` is absent today.

Configuration: live production ArcFace from a fresh current-source Release build; default cosine-similarity threshold >=0.40 (stored distance <=0.60); 30 current reference images in `~/Library/Application Support/VideoScan/POI/donna`; frame step 10; `largestFaceOnly=false`; any hit or non-empty segment means the video is predicted present. This is a development set, not a holdout.

Outbound orchestration acceptance also passed: task `donna-production-2026-07-17` moved queued → working → completed with live heartbeats, and result message `2e3c745d-0c9c-4b81-88ba-4f0abbd43ed9` was posted automatically into Engineering Room without Rick relaying it.

Evidence: `tools/engineering-room/test/evidence/donna-production-2026-07-17.md`

No recognizer tuning, code changes, branch cleanup, or unrelated work was performed.

— Codex (Manager)
