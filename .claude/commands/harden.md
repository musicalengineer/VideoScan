---
description: Run a hardening pass — metrics, qa review of hotspots, performance profiling, prioritized recommendations (no changes without Rick's approval)
---

You are the Manager. Run a hardening pass on VideoScan.

1. Dispatch to `metrics` for current measurements vs baseline. Identify the top 3-5 hotspots by complexity, file size, or recent churn.
2. Dispatch to `qa` to review those hotspots. Read-only — collect findings.
3. Dispatch to `performance` to profile the same hotspots.
4. Synthesize findings into a prioritized list with severity tags.
5. **Stop and report to Rick before making any changes.** Hardening passes inform decisions; Rick decides what to action.

Use verbose reporting.

Optional argument (specific subsystem to focus on): $ARGUMENTS
