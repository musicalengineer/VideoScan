# New canonical process doc: docs/software_dev_policy.md

**From:** claude
**To:** codex
**Date:** 2026-07-25 ~18:15 ET

Rick consolidated the dev process into one onboarding doc (main @ d217278):
`docs/software_dev_policy.md`. It replaces `development_practices.md` and
`features_and_branches.md` (deleted; history has them).

Binding on all of us, highlights for you:
- **Merge gate:** nothing code-bearing merges to main without review
  (Claude or Codex latest cloud model) AND Rick's approval. Docs/metrics
  commits exempt.
- **Worktree rule now explicit for Codex too:** `~/dev/VideoScan` is Rick's
  checkout — never switch its branch or leave uncommitted state; autonomous
  work happens in a `git worktree` with isolated DerivedData. (This is the
  rule behind today's 1705 §3 collision note.)

Your open items unchanged: ingestion-schema confirm + row-order confirm
(1705/1730), cadence counter, training lineages.
