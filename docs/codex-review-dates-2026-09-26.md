# Codex review — date triangulator resolver + migration (48708aba..bc5a9806) — 2026-09-26 night

Invocation: codex exec --sandbox read-only (direct). Tokens used: 56,869.

Credits spent: unavailable | Finding count: 4
Verdict: merge-after-fixes

**F1 — P1: User-year refinement makes an export stamp shareable**

[VideoScanModel+DateInference.swift:521](/Users/rickb/dev/VideoScan/VideoScan/VideoScanModel+DateInference.swift:521), [RecordDateResolver.swift:224](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/RecordDateResolver.swift:224)

Counterexample: donor A has known user date `2004`, Apple make without model, and export stamp `2004-12-31`. The existing refinement path returns `.embedded`, day precision, confidence `1.0`. The new sharing gate interprets that confidence as camera provenance and copies the export day to an undated sibling. Promote also receives day precision despite the user specifying only a year.

Pinning test: two eligible members in a likely footage group with those fields. Assert the user’s year precision survives resolution and dateHint, and the sibling never inherits the export’s month/day.

Closed by 46442a1a — DateReviewF1Tests (`userYearSurvivesASoftwareStamp`, `siblingNeverInheritsTheExportDay`); red first: 7 issues. Only a camera's stamp refines a user year; a software stamp's day never travels.

**F2 — P1: Retracted or downgraded donor claims leave active shared dates**

[VideoScanModel+DateInference.swift:598](/Users/rickb/dev/VideoScan/VideoScan/VideoScanModel+DateInference.swift:598), same file:543.

Counterexample: A’s user date `1992` is shared to B. Clear A’s user date, leaving neither member with independent date evidence and keeping their group IDs. `isStaleFootageShare` checks only donor presence and group identity. Both independent claims are now absent, so sharing returns without clearing B. Promote continues filing B under the retracted year.

Likewise, lowering both memberships to `.possible` leaves the existing share active: the group is excluded from new sharing but passes stale-share validation.

Pinning test: exercise both transitions after an initial share; assert the unsupported inferred date is removed and dateHint becomes unknown.

Closed by 6c2517d0 — DateReviewF2Tests (`retractedUserDate`, `downgradedGroup`, `notSameDecision`, pin `changedUserDate`); red first: 5 issues. A share is stale unless the donor still holds a shareable claim producing the same date/span/confidence, both memberships ≥ likely, no notSame either way; rule 2b also refuses notSame.

**F3 — P2: Second catch-up erases the recipient’s recorded disagreement**

[VideoScanModel+DateInference.swift:507](/Users/rickb/dev/VideoScan/VideoScan/VideoScanModel+DateInference.swift:507), same file:582.

Counterexample: A has user date `1992`; B has an independent, settled inference `2000 @0.7`, with no embedded or filename date. First catch-up replaces B’s inference and records `own evidence said 2000`. Second catch-up suppresses B’s shared inference when computing its claim, yielding no `ownYear`. The generated reason loses that disagreement, fails the equality guard, and writes B again.

This violates second-pass idempotence and removes the retained explanation of the overwritten claim.

Pinning test: snapshot every inferred field after pass one; pass two must produce zero writes and preserve the original disagreement.

Closed by d545800e — DateReviewF3Tests (`secondPassWritesNothing`); red first: 3 issues. The first share's "own evidence said <year>" is kept; pass two makes zero writes.

**F4 — P2: Displaced stamps hide inferred year ranges**

[VideoRecordUserDate.swift:277](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecordUserDate.swift:277)

Counterexample: software stamp `2008-06-01`, inferred point `2003-01-01 @0.8`, range `2003–2004`. The resolver displaces the stamp, and the Date column immediately returns `moved.isoString`, displaying only `2003`. The range-display branch is never reached. Removing the embedded stamp makes the same inference display `2003–2004`.

Pinning test: assert identical range display with and without a displaced software stamp; retain deterministic year-only dateHint.

Closed by d18ee9d3 — DateReviewF4Tests (`sameDisplayWithAndWithoutStamp`; pin `filesUnderThePointYear`); red first: 1 issue. The displaced-stamp branch shows the range; docs state a range files under the inferred POINT's UTC year (2003 or 2004), never an endpoint.

All five requested per-file diffs were read. No builds or tests were run. `MasterArchive.swift` dateHint: read, no independent findings; it forwards the range and maps `.year` correctly. `InferredDateRange.swift`: read, no independent findings. Placement uses the inferred point’s UTC year—`2003` in F4—not a year selected from the range endpoints. Real-camera metadata behavior and external exclusion predicates remain unverified within this scope.

## Brief

Adversarial code review, SCOPED to the date RESOLVER and the stored-date migration only. Repo /Users/rickb/dev/VideoScan, branch feat/inferred-date-triangulator (origin), range main 48708aba..bc5a9806. Use `git diff 48708aba bc5a9806 -- <file>` per file. Do NOT explore outside these files; do not build or run anything; read-only.

WHY IT MATTERS: the resolved date decides where Promote files a video in the Master Archive (decade/year folders) and what the Date column shows. A wrong date misfiles family media.

FILES IN SCOPE:
- VideoScan/VideoScanCore/Sources/VideoScanCore/RecordDateResolver.swift (namesDevice: make-without-model = software stamp 0.80; rules v13 set-aside of encoder/software stamps by an inferred date ≥0.6 disagreeing >2 y; new inferredDateRange param → YEAR precision)
- VideoScan/VideoScanCore/Sources/VideoScanCore/InferredDateRange.swift
- VideoScan/VideoScan/VideoScanModel+DateInference.swift (load-time catch-up: rule 0 clears mtime-tier legacy inferred dates; rule 1 re-triangulates evidence-bearing rows once; rule 2b footage-group sharing)
- VideoScan/VideoScan/MasterArchive.swift (dateHint only)
- VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecordUserDate.swift (resolvedDateSortKey/Display with ranges)

INVARIANTS TO ATTACK:
1. A user date ALWAYS wins, at its precision, in every path (resolver, Date column, dateHint, footage sharing). Find any path where an inferred or shared date overrides or overwrites a userDate.
2. A device stamp (make AND model, or the named action-cam makers) is never demoted. Find a real camera that `namesDevice` misclassifies as software (e.g. Canon/Sony/Panasonic camcorders writing only `make`, iPhone exports, DJI/GoPro stream handlers).
3. The migration is idempotent and never destructive to evidence: re-running the catch-up twice changes nothing the second time; clearing an mtime-tier inferred date never clears a userDate, an embedded stamp, or a date with evidence; a record on an unreachable volume is left untouched.
4. Footage-group sharing only at `likely`+, never propagates a filename year or an export stamp, and a member's own stronger claim is never overwritten by a weaker sibling claim. A human "not the same" decision blocks sharing.
5. Range → YEAR precision: Promote must file a "2003–2004" range under ONE year deterministically (which?), never under 2003-01-01 day precision, and never crash on a reversed/empty range.

EVIDENCE ALREADY RUN (Debug, M4): 410 tests / 52 suites green incl. RecordDateResolverTests make-only matrix, InferredDatePropagationTests, DateTriangulatorTests (CapeCod → 2004 @0.83, Clip 19 → 1996, 'OK Christmas 2002' + stamp → 2002-12-25 @0.95), DateInferenceSensorTests (user date wins; DV never <1995), resolver 100k 0.60 s.

OUTPUT (stdout, Markdown, under 700 words): first line exactly `Credits spent: <n or unavailable> | Finding count: <n>`; then `Verdict: merge / merge-after-fixes / hold`; then each finding `F<n> — P<1|2|3>: <title>`, file:line, concrete counterexample, pinning test you would accept. If nothing survives, list what you checked.

## Follow-up: in-house QA review (same night)

- M1 — Closed by fcd71063 — `DateTriangulatorQAReviewTests.folderYearPlaceholderGainingEvidenceSettles` (red: 3 issues).
- M2 — Closed by e804a9b5 — `DateTriangulatorQAReviewTests.liveReloadCarriesRangeAndReason` (red: 3 issues).
- M3 — Closed by c18e4bbf — `DateTriangulatorQAReviewTests.reminiscencesAreReferences` (red: 8 issues).
- Minor (unwind) — Closed by e6effe8b — `DateTriangulatorQAReviewTests.unwindClearsRangeAndReason` (red: 2 issues).
- Minors (log sum, comment, scale test, open questions) — 695e70c1 — `logLineBreakdownSums` (added with the fix), `DateTriangulatorScaleTests.hundredThousand` (realistic 2–5 kB, 19.0 s measured, ceiling 25 s load-aware).

## Re-review bb5f52bb (codex, same night)

F1, F4, M1–M3 and the unwind: closed per codex. Two residuals:

Credits spent: unavailable | Finding count: 2
Verdict: merge-after-fixes

**R1 (F2 residual) — P1: Scoped regrouping leaves the old recipient’s share active**

[VideoScanModel+DateInference.swift:683](/Users/rickb/dev/VideoScan/VideoScan/VideoScanModel+DateInference.swift:683), same file:712, 877.

Counterexample: A shares `1992` to B in group G1. Move A to G2, then call `catchUpInferredDates(scope: [A])`, with no content-group link between A and B. Scope expansion includes only A’s current group; B never reaches `isStaleFootageShare`. B retains the unsupported `1992` share until a broader pass. The validation predicate is fixed, but invalidation misses former dependents.

Pinning test: establish A→B, move A into another group, run the donor-scoped catch-up, and assert all B’s inferred fields clear. Also cover downgrading membership before the scoped pass.

Closed by c62f09b4 — DateReviewF2Tests `donorScopedPassAfterRegroupClearsDependents` (red first: 2 issues); pin `donorScopedPassAfterDowngradeClearsDependents` (already green: B's own likely membership kept the old group bucketed). A scoped pass now adds every row whose "footage-shared from <id>" names a scoped record before bucketing.

**R2 (F3 residual) — P2: Confidence-only refresh erases the retained disagreement**

[VideoScanModel+DateInference.swift:718](/Users/rickb/dev/VideoScan/VideoScan/VideoScanModel+DateInference.swift:718), same file:612.

Counterexample: use the F3 fixture: A’s estimated user year `1992` overwrites B’s settled inference `2000`, retaining `own evidence said 2000`. Change only A’s confidence to `known`. F2 correctly detects the changed share value, but housekeeping clears B’s reason and source before re-sharing. F3’s preservation branch can no longer recover the disagreement. The stronger same-year claim re-shares successfully, but its historical explanation is lost.

Pinning test: extend `secondPassWritesNothing` with that confidence transition. Assert B receives the updated confidence, retains `own evidence said 2000`, and the following unchanged pass writes nothing.

Closed by 63e4b578 — DateReviewF3Tests `secondPassWritesNothing`, extended with the estimated → known transition (red first: 1 issue). Rule 0 keeps a stale share's disagreement tail with its year; a same-year re-share re-attaches it.
