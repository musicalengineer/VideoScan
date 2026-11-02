# Codex review — Auto split after Full Hashes (menu regroup)

- Range: `bc366210..feat/catalog-menu-regroup`
- Credits spent: unavailable
- Tokens: 73625
- Finding count: 2
- Verdict: fix — the trigger accepts mixed online/offline runs, and the automatic split lacks the required before/after row counts.
- Run: 2026-11-01T23:40:32Z (cycle #189, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 2
Verdict: fix — the trigger accepts mixed online/offline runs, and the automatic split lacks the required before/after row counts.

Reviewed `bc366210..17604c18`.

1. **P2 — An offline drive can still permit the automatic split.** [AnalyzerRuns.swift:147](/Users/rickb/dev/VideoScan-wt/catalog-menu/VideoScan/VideoScan/Analyze/AnalyzerRuns.swift:147) copies `totals.planned`, which counts only online lanes. Offline files are recorded separately as `.driveNotConnected`; the predicate at line 140 never checks that count.

   **Reproduction:** provide one eligible file on an online drive and another on an offline drive. Hash the online file successfully. The ending is successful with `planned == hashed == 1`, so the catalog-wide split runs despite the unresolved offline file.

   **Regression needed:** run that mixed-drive fixture through the center; assert `.driveNotConnected > 0` and split count **0**. Current code produces **1**. [AnalyzerRunsTests.swift:153](/Users/rickb/dev/VideoScan-wt/catalog-menu/VideoScan/VideoScanTests/AnalyzerRunsTests.swift:153) makes *every* drive offline, testing only the zero-planned guard. This regression was not executed.

2. **P2 — The automatic split does not satisfy the required row accounting.** [AnalyzerRuns.swift:187](/Users/rickb/dev/VideoScan-wt/catalog-menu/VideoScan/VideoScan/Analyze/AnalyzerRuns.swift:187) delegates without adding accounting. The existing split OUTCOME reports groups and save status at [VideoScanModel+DuplicateDigestSplit.swift:246](/Users/rickb/dev/VideoScan-wt/catalog-menu/VideoScan/VideoScan/MediaOps/VideoScanModel+DuplicateDigestSplit.swift:246); the committer reports landing counts, not catalog rows before/after. Invariant 4’s required counts are absent.

   **Reproduction/test:** complete a successful hash run that actually splits a group; capture the split OUTCOME and assert explicit before/after row counts. That assertion fails against the current format. The integration tests replace the split with a counter at [AnalyzerRunsTests.swift:107](/Users/rickb/dev/VideoScan-wt/catalog-menu/VideoScan/VideoScanTests/AnalyzerRunsTests.swift:107), so they cannot detect this.

`MediaFileOperations.swift` hook: **read, no findings.** Full Hashes writes its own OUTCOME after acknowledged persistence and before terminal state; my preliminary ordering concern is withdrawn. The synchronous main-actor split prevents overlapping split calls. The inspected persistence path forwards through `CatalogCommitter`; the hook writes no catalog fields directly.

Tests do **not** pin real stop/pause-abandon/save-failure transitions, mid-run disconnection, durable ordering, concurrent requests/relaunch, crash consistency, or archived name/date preservation. No red-first evidence was supplied for these cases.

**Validation:** zero tests executed—the session permits no filesystem writes. Scoped `git diff --check` passed. Read scope extended narrowly to `FullHashBackfillJob.swift` for totals and termination evidence, plus the permitted split commit path; the unchanged split algorithm was not reviewed.

## Brief

# Codex brief — the automatic duplicate-group split at the end of Full Hashes (2026-11-01)

## Output contract (first two lines, exactly)
```
Credits spent: <amount> | Finding count: <N>
Verdict: <merge | fix | block> — one sentence
```

## Scope (read only these)
Branch `feat/catalog-menu-regroup`, worktree `/Users/rickb/dev/VideoScan-wt/catalog-menu`, commits `bc366210..HEAD`.
- `VideoScan/VideoScan/Analyze/AnalyzerRuns.swift` (new): `AnalyzerRunFollowUp` — after a whole-catalog Full Hashes MFO job ends with every planned file hashed, it calls `splitDuplicateGroupsKeepingSameFootage` once, automatically, with its own START/OUTCOME.
- The new `onJobTerminal` hook in `VideoScan/VideoScan/MediaOps/MediaFileOperations.swift`.
- `VideoScan/VideoScanTests/AnalyzerRunsTests.swift`.
- For the engine it calls, read `splitDuplicateGroupsKeepingSameFootage` and its commit path only as far as needed to judge the trigger; do not review the split engine itself (unchanged).

## Invariants to attack
1. The split runs at most once per completed run, never for a run that was stopped, paused-then-abandoned, failed, hashed nothing, or lost a drive mid-run (CLAUDE.md rule 2: refuse rather than guess; ARCHITECTURE §10.6 "every outcome is named; none is reported as success").
2. It runs only after the terminal outcome is durable (the job's OUTCOME written, hashes committed through the one door) — never on a partial or in-flight state; a crash between the job's end and the split leaves the catalog consistent and the split simply does not run (no half-split).
3. Two Full Hashes jobs (or a relaunch during one) cannot trigger two overlapping splits; the hook is called exactly once per job termination.
4. The split goes through `CatalogCommitter.commit(as:)` with rows-before/after in its OUTCOME; nothing writes the catalog from the hook directly; archived records' names/dates untouched (rule 3).
5. The tests prove 1–4 red-first where a defect is possible; name any invariant the tests do not pin.

## Do not explore outside these files. Do not propose features. Findings carry file:line.

## Closed

Closed by `claude (main session)` at 2026-11-02T00:23:26Z. both P2s fixed red-first in 0472ed07 (offline lane never splits; OUTCOME carries rows before/after); merged to main 9d6ca34b
