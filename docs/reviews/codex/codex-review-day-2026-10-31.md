# Codex review — 2026-10-31 day: Confirmed Date filter table, timing judge, gated pause test

- Range: `30e41529..d3d46db0`
- Credits spent: unavailable
- Tokens: 95470
- Finding count: 1
- Verdict: merge — No introduced defects found; the universal timing-failure claim has one pre-existing caller exception.
- Run: 2026-11-01T01:23:57Z (cycle #186, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 1
Verdict: merge — No introduced defects found; the universal timing-failure claim has one pre-existing caller exception.

1. **P2 — Reference-only callers suppress failures above 3× outside pinned runs.** [Core TimingBudgetExpectations.swift:47](/Users/rickb/dev/VideoScan/VideoScan/VideoScanCore/Tests/VideoScanCoreTests/TimingBudgetExpectations.swift:47) and [app TimingBudgetExpectations.swift:53](/Users/rickb/dev/VideoScan/VideoScan/VideoScanTests/TimingBudgetExpectations.swift:53).

   Reproduction: with strict mode and sanitizers unset, call `expectWithinReferenceTimingBudget` with budget **100 ms**, measured **400 ms**. `judge` returns `.fail`, but the wrapper only logs it; no test failure is recorded. This affects callers such as `AudioCatalogIndexScaleTests`. Both wrappers’ behavior is unchanged from `30e41529`, so this is not a regression introduced by the range.

Remaining scope:

- **Catalog files and confirmed-date tests:** read, no findings. Existing filter combinations preserve rows and order; the stated archived-search banner exception holds. Confirmed Date uses `userDateStatus`, `userDate`, and `UserDateEntry.canonicalize`. No record scan moved into a view body.
- **TimingBudget and remaining changed timing tests:** read, no findings. Ordinary assertion wrappers preserve failures above 3×. The sanitizer branch is byte-identical, retaining its scaled thresholds.
- **BackgroundTestSupport and JobSupervisorTests:** read, no findings. The gate checks cancellation and uses cancellable sleep without holding its lock. `JobSupervisor.swift` is byte-identical across the range.

Swift tests were not run: the read-only sandbox prevents creating the required isolated worktree and build artifacts. No files changed.

## Brief

# Codex review brief — 2026-10-31 day's Swift changes (second pair of eyes; nothing data-risk)

Range: 30e41529..d3d46db0 on main. Review ONLY the Swift under VideoScan/ (ignore docs/, tools/, tests/*.py).

Three changes to look at, each with its stated intent:
1. `CatalogViewFilter.recordPredicate` (App/ContentView.swift) + `CatalogContent.computeFiltered` (Catalog/CatalogHelpers.swift) + `pfRecordHasConfirmedDate` (Catalog/CatalogQueries.swift): the nine pure per-record Show filters became a predicate table applied in one loop, and a new "Confirmed Date" filter (Rick's own dates only, never a machine date). Claim: rows are identical to before for every filter combination; only the archived-hits banner count under search + Not yet archived + No place yet can differ. Check the claim; check the predicate reads only `userDateStatus`/`userDate` and `UserDateEntry.canonicalize`; check nothing O(records) moved into a view body.
2. `VideoScanCore/Sources/VideoScanCore/TimingBudget.swift` `judge`: a budget is strict only under VIDEOSCAN_TIMING_STRICT=1; otherwise a miss ≤ 3× is a known issue, beyond 3× fails. Check every caller still gets a failure for a hang (> 3×) in every mode, and that the sanitizer branch is unchanged.
3. `VideoScanCore/Tests/VideoScanCoreTests/Background/BackgroundTestSupport.swift` `UnitGate`/`GatedJob` and the pause/resume test: check the gate cannot deadlock the lane under cancellation, and that `JobSupervisor` itself was not changed.

Output contract (the tool parses it): your FIRST line must be exactly
`Credits spent: <amount> | Finding count: <N>`
and you must include a line `Verdict: <merge | fix | block> — <one sentence>`.
Then the findings: as RED tests where you can (a test that fails on this range), else a numbered list with file:line and the failure scenario. No fixes.

## Closed

Closed by `33a41214` at 2026-11-01T01:30:58Z. P2 fixed: reference-only wrapper records a hang off the reference run
