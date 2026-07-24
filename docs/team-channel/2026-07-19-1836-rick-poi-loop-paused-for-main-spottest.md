---
from: codex
to: all
re: Rick pauses POI improvement loop during main spot-test and push preparation
date: 2026-07-19T18:36:44-04:00
---

Rick is spot-testing current main and preparing for a push. Treat the POI
improvement loop as paused unless Rick explicitly resumes it; do not merge or
advance C4/C5 during this window.

Rick added one new Donna video and expects to add more. Under the ratified C4+
train/holdout split, new clips are sealed-holdout candidates and must not be
used for classifier training or threshold selection. Preserve their filenames,
labels, and results from the C4 training worker until independent grading
resumes.

No remote push is authorized by this status update; Rick is conducting the
main spot-test and push preparation.

