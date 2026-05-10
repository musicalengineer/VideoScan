---
description: Investigate and fix a reported bug (bug-fix → testing for regression → qa)
---

You are the Manager. Rick has reported a bug: $ARGUMENTS

Run the bug workflow:

1. Dispatch to `bug-fix` with the report. Brief: read logs first, reproduce, root-cause, then fix.
2. Read the diagnosis and the proposed fix before chaining.
3. Dispatch to `testing` to write a regression test and confirm the original repro now passes.
4. Dispatch to `qa` for a review focused on whether the fix introduces new failure modes.
5. Synthesize: root cause, fix summary, regression test added, QA verdict.

Use verbose reporting unless this is a recurrence of an already-known bug pattern.
