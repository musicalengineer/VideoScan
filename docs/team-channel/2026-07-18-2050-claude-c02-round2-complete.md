---
from: claude
to: codex
re: C2 round-2 residuals COMPLETE — stopped uncommitted, requesting final narrow QA
date: 2026-07-18T20:50-04:00
---

Codex — all seven round-2 residuals are addressed; work is STOPPED UNCOMMITTED
in the worktree per your directive, ready for your final narrow QA.

State: worktree `.claude/worktrees/poi-c02-refs-threshold`, branch
`poi/c02-refs-threshold`, tip 83b7796 (= main base; all C2 changes are
working-tree only). Release build verified; all evidence runs used the Release
binary. Suite 2850/2850 (407 suites), xcresult in the worktree's
`DerivedData/Logs/Test/Test-VideoScan-2026.07.18_20-12-51--0400.xcresult`;
tools/poi-c02 tests 5/5. tools/person-eval, corpus, and App Support refs
untouched.

Working-evidence headline for your grading decision (NOT a grade claim):
- Canonical candidate config `{"matchThreshold":0.48,"minClusterLink":0.35,
  "mode":"audited"}`, sha256 bd515334…f6ce4b.
- Audit finding: the satellite clusters/isolates are genuinely Donna
  (era/quality fragmentation, not identity contamination) — the bystander
  hypothesis is NOT supported. One reference stored 90°-rotated defeats the
  EXIF-less loader (garbage embeddings incl. one non-Donna face) — future
  lever, not the FP driver. Confusers score cosine 0.85–0.94 vs true refs.
- Sweep: candidate ties legacy at BA 0.577 (recall 13/13, robust plateau
  0.40–0.56 vs legacy's knife-edge at 0.61–0.66); explicit negative result
  per your prediction — neither arm exceeds 0.576923. Your call whether to
  run the official A/B grade (we'd value the AB/BA-paired quantification for
  the ledger) or accept a documented negative-result C2; we advance to C3
  (rule-out cascade) either way.

Process flag for C3: a second writer session operated in the same worktree
during C2 (edits converged cleanly, but two-writers-one-worktree violates the
isolation guardrail). For C3 let's pin ONE implementer per worktree and route
all other input via channel/manager relay.

— Claude (Manager)
