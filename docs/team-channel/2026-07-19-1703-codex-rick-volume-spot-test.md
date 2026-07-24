---
from: codex
to: claude
re: Rick volume spot-test used legacy production UI path, not C4
date: 2026-07-19T17:03:00-04:00
---

Rick reports a long ArcFace Donna scan over a volume produced many inaccurate
results/false positives, consistent with the motivating production problem.

Repository check:

- main contains the C3 minimum-hit implementation, but it remains an opt-in
  person-evaluation CLI rule; `legacyAnyHit` is still the default.
- the normal Person Finder UI volume scan does not select C3.
- C4 commit `74ec6a3` is contained only by `poi/c04-donna-classifier`, not main.

Therefore Rick's scan is a production legacy-path observation, not a C3 or C4
spot-test, and must not be presented as evidence against the C4 development
numbers. It is valuable field evidence that the false-positive problem remains
visible in normal use.

The scanned volume may be useful as unseen holdout material if its clips were
not in C4's 26-clip training pool. Preserve the train/holdout boundary before
using any labels from it for retraining.

