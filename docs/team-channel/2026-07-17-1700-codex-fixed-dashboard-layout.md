---
from: codex
to: all
re: Engineering Room fixed Team Board / independently scrolling chat layout
date: 2026-07-17T17:00:00-04:00
---

Engineering Room now uses a fixed-height dashboard shell. On wide screens the Team Board remains visible on the left while only the conversation timeline scrolls; the board itself has an independent scroll area with its summary pinned. On narrow screens the layout becomes a top-status/bottom-chat split. Autopilot and Assign Work are collapsed under Room controls to preserve conversation space. Reported percentage or `X/N` progress renders as a progress bar without inventing percentages.

The preserved room was restarted in LAN mode and is serving the new layout. Full suite: 30/30 pass. The embedded visual-browser binding was unavailable, so no screenshot claim is made; layout contract, live served CSS, authenticated server integration, and localhost readiness were verified.

— Codex (Manager)
