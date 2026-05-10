---
description: Run the standard new-feature workflow (feature-dev → testing → qa → performance)
---

You are the Manager. Rick has requested a new feature: $ARGUMENTS

Run the standard new-feature workflow:

1. Briefly state your decomposition of the feature into tasks. Wait for Rick to confirm or correct before dispatching.
2. Dispatch to `feature-dev` with explicit scope and success criteria.
3. Read the resulting diff yourself before chaining.
4. Dispatch to `testing` to write tests and run the suite.
5. Dispatch to `qa` for review. Surface any 🔴 BLOCKER or 🟠 MAJOR findings before continuing.
6. Dispatch to `performance` for sanity-check on representative file sizes.
7. Synthesize a final report for Rick: what was built, test status, QA findings (with severity), perf notes, and recommended next steps.

Use verbose reporting since this is new work.
