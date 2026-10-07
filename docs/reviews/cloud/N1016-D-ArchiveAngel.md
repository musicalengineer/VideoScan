Brief: N1016-D-ArchiveAngel | Source: main@ebcd2f09 | Wall clock: 20 | Files read: 26
Finding count: 3 (REAL 3 / NEEDS-MAC 0 / NOISE 0)
Verdict: The Angel's recommend/prepare debt is ordinary size debt, but its Promote hand-off has a disagreeing duplicate. The quit-recovery settle (`settleStrandedPromotions`) decides "landed, so delete the buffer and keep the inherited facts" with a different, display-only predicate, and it ignores companions. Normal `settle` does neither, and none of the three is pinned by a test. Pin and unify that before splitting `promote`/`settle`.

Scope: `VideoScan/VideoScan/ArchiveAngel/` (67 files, 19,630 lines at ebcd2f09). Read-only review. Per the brief, nothing was committed or pushed; this file is the only output. (The brief's rule overrides README rule 3.)

Callees I followed to settle findings (outside scope): `Archive/PromoteToArchiveJob+Guards.swift` (all of it), `Archive/VideoScanModel+MasterArchive.swift` (`masterArchiveCopy`, `archivedCopy`, `ArchivePromotionIndex.copy(ofContentOf:)`, `promoteRefusal`, `promoteWouldRefusePermanently`), `Catalog/CatalogContent+Promote.swift` (`isArchived`, `isArchivedOrVersionOfArchived`), `Archive/ArchivePromoteJournal.swift` (header), `Archive/MasterArchive.swift` (`ArchiveDateHint.filenamePrefix`), `MediaOps/VerifyAudioProbe.swift` (finding emission), `MediaOps/BalanceAudioJob.swift` (`refusalReason`). Tests read: ArchiveAngelLivenessTests, ArchiveAngelPromoterTests, ArchiveAngelAttentionTests (promote section), ArchiveAngelCharacterizationTests (raw values), plus greps across all 55 `ArchiveAngel*` test files.

## 0. Measurements: source

`pip install lizard` was refused by the permission system again (one attempt). I used the M4 nightly numbers instead: `origin/metrics:metrics/complexity.jsonl` (last line: ts 2026-10-06T11:36Z, sha a70a3562, lizard 1.22.1), `complexity_debt_latest.json` (new/worse lists) and `complexity_baseline_proposed.json` (per-function values).

- **ArchiveAngel folder (nightly):** 64 files, 918 functions, 18 functions over CCN 15 (4 over 30), 5 functions over 80 NLOC, 19 offenders, 4 files over 800 lines, mean CCN 3.6.
- **Nightly new/worse lists:** no entries in this scope. The 3 new and 2 worse are in `scripts/` and `Steward/`.
- **Changes since the nightly sha** (two commits in scope: `c683c085` Catalog hints, `0835ed1a` noSound floor, rules v15). I re-measured these by hand (line counts and reading), not with lizard:
  - **NEW file offender:** `Facade/ArchiveAngel.swift` went from 795 to **814** lines. The +25 lines are the Catalog-hint hooks. This is the cheapest debt tonight (see plan item 5).
  - `ArchiveAngelScorer.floorFires` (baseline CCN 39) got *smaller*: four media cases moved into the new `mediaFloorFires` ("Split out of floorFires (complexity gate)"). I did not re-measure it.
  - `ArchiveAngelRejection.name` (baseline CCN 27) gained one case (`noSound`), so it is now about 28. It is a switch table; see the backlog.
  - The new `Facade/ArchiveAngel+CatalogHints.swift` (99 lines), `UI/ArchiveAngelCatalogHint.swift` (149) and `UI/ArchiveAngelCatalogBadge.swift` (+79) have no function near the thresholds.

## 1. Offenders (nightly values at a70a3562; the file sizes are at ebcd2f09)

| # | Symbol | File:line | CCN | NLOC | Data-risk? |
|---|---|---|---|---|---|
| 1 | `ArchiveAngelJob.selectFromEvidence` | Prepare/ArchiveAngelJob+Evidence.swift:72 | 44 | 180 | no (selection) |
| 2 | `ArchiveAngelScorer.floorFires` | Recommend/ArchiveAngelScorer+Rules.swift:84 | 39 (lower since split) | 52 | no |
| 3 | `ArchiveAngelJob.prepare(index:record:…)` | Prepare/ArchiveAngelJob.swift:674 | 37 | 127 | buffer writes |
| 4 | **`ArchiveAngelPromoter.promote`** | **Promote/ArchiveAngelPromoter.swift:146** | **35** | **141** | **YES (Promote/)** |
| 5 | `ArchiveAngelRejection.name` | Recommend/AngelRuleLanguage.swift:843 | 27 (now ~28) | 30 | no |
| 6 | `ArchiveAngelJob.run` | Prepare/ArchiveAngelJob.swift:374 | 26 | 148 | buffer writes |
| 7 | `ArchiveAngelRecommendations.verdict` | Recommend/ArchiveAngelRecommendations.swift:618 | 24 | 65 | no |
| 8 | **`ArchiveAngelPromoter.settle`** | **Promote/ArchiveAngelPromoter.swift:320** | **23** | **66** | **YES (Promote/, deletes buffer folders)** |
| 9 | `ArchiveAngelReviewSheet.footer` | UI/ArchiveAngelReviewSheet.swift:392 | 20 | 78 | no |
| 10 | `VideoScanModel.forgetArchiveAngelCompanions(scopes:…)` | Prepare/VideoScanModel+ArchiveAngelCompanions.swift:153 | 19 | 69 | catalog records |
| 11 | `VideoScanModel.reconcileArchiveAngelBufferAtLaunch` | Prepare/VideoScanModel+ArchiveAngelCompanions.swift:273 | 18 | 64 | catalog records |
| 12 | `AngelRule.problems` | Recommend/AngelRuleLanguage.swift | 18 | 42 | no |
| 13 | `ArchiveAngelRecommendations.classify` | Recommend/ArchiveAngelRecommendations.swift:545 | 18 | 60 | no |
| 14 | `ArchiveAngelJob.prepareEntries` | Prepare/ArchiveAngelJob.swift:562 | 17 | 62 | buffer writes |
| 15 | `AngelRecommendationPolicy.decodeValidated` | Recommend/AngelRecommendationPolicy.swift | 17 | 66 | no |
| 16 | `AngelEvalContext.candidateFlag` | Recommend/AngelRuleLanguage.swift | 17 | 22 | no |
| 17 | `AngelStemMatcher.matchesNames` | Recommend/AngelStemMatcher.swift | 16 | 34 | no |
| 18 | `ArchiveAngelReadinessExplanation.sentence(forReason:)` | UI/ArchiveAngelReadinessExplanation.swift | 16 | 35 | no |
| 19 | `ArchiveAngelAssessmentPanel.body` | UI/ArchiveAngelAssessmentPanel.swift | 6 | 98 | no |

Files over 800 lines at ebcd2f09: `Prepare/ArchiveAngelJob.swift` 1,141 · `Recommend/ArchiveAngelScorer.swift` 1,018 · `Prepare/ArchiveAngelPlan.swift` 961 · `Recommend/AngelRuleLanguage.swift` 878 · **`Facade/ArchiveAngel.swift` 814 (NEW since the nightly)**. Next to cross 800: `UI/ArchiveAngelReviewSheet.swift` 759.

## 2. Duplicated logic, dead code, leftovers

### Findings

**N1016-D-ArchiveAngel-F1. P2, REAL. A quit-recovery settle deletes the buffer of a row whose companion never reached the archive.**
- **Symbol:** `ArchiveAngelPromoter.settleStrandedPromotions(bufferRoot:model:)`, Promote/ArchiveAngelPromoter.swift:419-433. It disagrees with `ArchiveAngelPromoter.settle`, lines 346-379.
- **Two answers to "is this row finished, so its buffer folder can go?":**
  - `settle` (normal finish) removes the folder only when the original AND every done companion landed. Otherwise the row keeps its buffer "so a retry can finish". This is guardrail 2 in the file header.
  - `settleStrandedPromotions` (after a quit or crash mid-promote, called from `ArchiveAngel.refreshBatches`, Facade/ArchiveAngel.swift:724, and `ArchiveAngelJob.run`, ArchiveAngelJob.swift:381) looks only at the original (`model.isArchived(rec)`). It then calls `removeEntryFolder`, which deletes `<batch>/<entryID>/` with every companion file in it (ArchiveAngelPlan.swift:891).
- **Scenario:**
  1. A batch row has an original plus an access copy and a lossless copy made in the buffer.
  2. Promote starts. The promote list is built original first, then its companions (lines 220-235).
  3. The original lands. Rick quits (or the app crashes) while the lossless copy is copying.
  4. On relaunch, `refreshBatches` sees the original archived, marks the row `.promoted` and deletes the folder.
  5. The lossless copy and access copy are gone without ever reaching the archive. Their catalog records point at deleted files. The report says "1 archived".
- **What is lost:** derived files only (they can be rebuilt by preparing again from the archived original). No family original or archive copy is lost, hence P2. It still breaks the file's own stated guardrail.
- **Guard looked for:** `removeEntryFolder` has no check of its own (only "exists → removeItem"). The Promote intent journal reconciles copies already published, but it cannot bring back a buffer source that was deleted before its copy started. `ArchiveAngelLivenessTests.aStrandedPromoteIsSettledAgainstTheCatalog` uses entries with **no** companion steps, so it does not cover this.
- **Smallest pinning test (fails today):** in ArchiveAngelLivenessTests, add `aStrandedPromoteKeepsTheBufferWhenACompanionDidNotLand`.
  - Setup: record A archived (in the archive root, as in the existing fixture), and companion record C unarchived, whose file is at `<batch>/<A.id>/a_access.mp4`. A's entry has a `.accessCopy` step `{state: .done, recordID: C.id, outputRelPath: "<A.id>/a_access.mp4"}`, and the plan is `.promoting`.
  - Run `settleStrandedPromotions`.
  - Expect: A's row is **not** `.promoted` (it stays `.ready` with a "companion not promoted" reason), and `a_access.mp4` still exists.

**N1016-D-ArchiveAngel-F2. P2, REAL. The settle paths decide "landed" with the content-level archived test, which the code says is for display only.**
- **Symbol:** `ArchiveAngelPromoter.settleStrandedPromotions`, lines 412-414, 424 and 434-436; also `ArchiveAngelPromoter.promote`, lines 195-197 (pending-restore settle).
- **Three answers to "did this record land in the archive?":**
  - `settle` uses the Promote job's own record-keyed outcomes (`.promoted` / `.adopted`).
  - The other two paths use `model.isArchived(rec)` (Catalog/CatalogContent+Promote.swift:114). That is `isArchiveCopy || isInsideMasterArchive || archivedCopy(of:)`, and `archivedCopy` falls back to `ArchivePromotionIndex.copy(ofContentOf:)`: any archive copy with the same segmented content hash, or a high-confidence hash duplicate-group member that was promoted.
  - That function's doc comment (VideoScanModel+MasterArchive.swift:200-201) says: "DISPLAY AND WORKLISTS ONLY. Nothing destructive keys off this". `masterArchiveCopy` (the promote link) is "what the promote/verify/delete engines keep".
- **Scenario:**
  1. Two byte-identical copies of one tape are on two volumes, as records X1 and X2. They are prepared in two different batches, and neither was archived at prepare time, so `.duplicateArchived` did not fire. How the second batch gets X2:
     - The evidence path does block a second copy when the duplicate group is in flight (`ArchiveAngelJob+Evidence.swift:320`).
     - Explicit picks ("Prepare" on a selection, ArchiveAngelJob.swift:147) and the walk path (line 461) check `inFlight` by **record id** only. So X2 gets in when Rick prepares a selection containing it, or when the two copies are not in one duplicate group.
  2. Batch 1 promotes X1.
  3. Batch 2's Promote starts, stamps inherited family date/place onto X2 and its companions, and the app quits before X2 is copied.
  4. On relaunch, `isArchived(X2)` is true through X1's archive copy (same content hash). So X2's row is marked `.promoted`, its buffer folder (companions) is deleted, and `settleStampedFacts(landed: isArchived)` **keeps** the inherited facts on X2 and writes Media Ledger "date set by angel" lines.
  5. Without the quit, normal `settle` would see GH #190's `.skipped` ("identical bytes already in the archive"), undo the stamps and keep the buffer.
- **Result:** a catalog record keeps facts that the rollback journal promised to undo, and derived files are deleted. No original is touched, hence P2.
- **Smallest pinning test (fails today):** in ArchiveAngelLivenessTests or ArchiveAngelCodex1654Tests, add `aStrandedRowWhoseTwinIsArchivedIsNotSettledAsPromoted`.
  - Setup: record X2 (outside the archive, contentHash "h"), and an archive-copy record of a *different* source with contentHash "h". X2's entry is `.ready` and holds one `StampedFact(field: .date, …)`. The plan is `.promoting` and has a buffer folder.
  - Run `settleStrandedPromotions`.
  - Expect: X2 is back to `.ready`, the folder exists, and `rec.userDate` is restored.
- **Fix direction (a behaviour change, so Rick decides):** "landed" = `model.masterArchiveCopy(of: rec) != nil || model.isInsideMasterArchive(path:)`, which is the promote link the engines use, behind one helper shared by all three call sites.

**N1016-D-ArchiveAngel-F3. P2, REAL. Guardrail 2 in normal `settle` is unpinned.**
- **Symbol:** `ArchiveAngelPromoter.settle`, Promote/ArchiveAngelPromoter.swift:346-379, the branch where the original landed but a companion did not.
- **The gap:** the only direct test of `settle` is `ArchiveAngelPromoterTests.twoRowsNamed00000MTSKeepTheirOwnOutcomes` (line 197), and it passes `intended: [a.id: [], b.id: []]`, so there are no companions. The repo-wide grep for `job.record(.promoted|failed|skipped` finds only that test. The end-to-end `promote(plan:…)` tests (Codex1654, Codex1659, FamilyInheritance, Residuals, Attention) build entries without `.done` companion steps. `promotableCompanions` is pinned (ArchiveAngelFamilyFactsTests:121-124), but the settle decision that deletes the folder is not.
- **Scenario:** a refactor of `settle` (plan item 1) that inverts `allCompanions` or moves `removeEntryFolder` above the loop would delete the buffer of a row whose lossless copy failed, and no test would go red.
- **Smallest pinning test:** in ArchiveAngelPromoterTests, add `originalLandedCompanionFailedKeepsBufferAndRow`.
  - Setup: `job.record(.promoted, …, recordID: a.id)` and `job.record(.failed, "a_lossless.mkv", "disk full", recordID: c.id)`. Entry A has a done `.losslessCopy` step for c, and `<batch>/<A.id>/a_lossless.mkv` exists.
  - Run `settle`.
  - Expect: A stays `.ready`, `promotedRelPath` is set, `failure` contains "Lossless copy not promoted", `report.failed` contains A, and the file still exists.
- This should pass today. It is a pin to add before anything moves, not a bug.

### Debt items (not findings)

**Duplicates that agree, or fail closed:**
- **"Already archived" is spelled three ways.**
  - The ways: `ArchiveAngelCandidate.project` (Recommend/ArchiveAngelCandidate+Record.swift:155-157: scan-target role is master-archive, OR inside the root, OR `masterArchiveCopy`), `VideoScanModel.promoteRefusal` / `promoteWouldRefusePermanently` (no scan-target-role arm), and `isRecommendableNow` (AppConformances.swift:29).
  - The Angel is stricter than Promote, so the disagreement fails closed.
  - The comment block at lines 136-154 contradicts itself: "Same function the promote engine refuses with" sits next to "Deliberately NOT the full promoteWouldRefusePermanently". Rewrite it.
- **Angel vs Promote date guards.** The Angel never calls `ArchiveDateAgreement` or `filingYearRefusal`. Its machine proposal is `facts.dateHint`, round-tripped as a string (`filenamePrefix` → `proposedDate` → `ArchiveAngelPromoter.dateHint(from:)`). A decade becomes "xxxx-xx-xx", so there is no override, and Promote places it by its own facts. Promote's refusals stay the last word, so this fails closed (at worst a prepared row is refused at Promote).
  - Debt: the plan should carry the hint, not text that gets parsed again.
- **Angel vs Promote duplicate check.** The Angel uses catalog relations (`isArchivedOrVersionOfArchived`). Promote uses a sha256 lookup plus claim (`claimSourceDigest`, Guards.swift:60-95). They can disagree only in the direction "Angel prepares, Promote skips as a duplicate", which wastes Prepare work and loses no data.

**Stale TODO (twice):**
- `TODO(S4 finding 3, for Rick)` at Prepare/ArchiveAngelAudioOutcome.swift:37 and Prepare/ArchiveAngelJob.swift:757, from 2026-09-23. It says `ArchiveAngelAudioOutcome.from` and the balance step use "two predicates for one question".
- Today they are equivalent: `VerifyAudioProbe` (MediaOps/VerifyAudioProbe.swift:352-366) emits `.channelImbalance` exactly when `programStreamCount ≤ 1`, the class is leftOnly/rightOnly/mono, and `BalanceAudioFix.refusalReason(for: analysis) == nil`. That is the same predicate the job uses.
- They can differ only on a cached diagnosis written under older rules. Either close the TODO with that note, or have both sites call one `ArchiveAngelAudioOutcome.isFixable(analysis)`.

**Dead code.** No references repo-wide, tests included. The count is a whole-word token count across every `.swift` under `VideoScan/`, comments included, so it gives no false "dead":
- `ArchiveAngelGrade.candidateGrades`: Recommend/ArchiveAngelEvidenceStore.swift:48
- `ArchiveAngelEvidenceStore.classCounts()`: Recommend/ArchiveAngelEvidenceStore.swift:279
- `ArchiveAngelCandidate.machineNotePrefixes`: Recommend/ArchiveAngelCandidate+Record.swift:221 (the comment calls it a legacy view)
- `ArchiveAngelScorer.originalityTable`: Recommend/ArchiveAngelScorer.swift:819
- `ArchiveAngelScorer.familyOriginPathMarkers`: Recommend/ArchiveAngelScorer.swift:905
- `ArchiveAngelScorer.appCacheFolderNames`: Recommend/ArchiveAngelScorer.swift:940

The last three are pre-S3b "views onto AngelPolicyTables.standard".

**Other leftovers:**
- TEMPORARY / diag leftovers: none in scope. "DEBUG" appears only in a comment (ArchiveAngelPlan.swift:942).
- Always-on flags: none found.
- Cosmetic: in `ArchiveAngelPromoter.promote`, the doc comment sits between `@discardableResult` and `func` (lines 138-145), so it is split in two.

**Known gap (not counted):** PruneApply does not check the Angel holds. This is relevant to item 1 only in that a later buffer/hold refactor should not assume PruneApply guards the buffer.

## 3. Ranked refactor plan

Order: pin first, then the cheapest. Items 1 and 2 touch **ArchiveAngel/Promote/ (data-risk)**. Each must be its own commit, with the pins below landed and green *before* the move, and under `/safety-critical`.

### 1. One "entry landing" decision for `settle` and `settleStrandedPromotions` (Promote/, data-risk). Size M, risk HIGH.
- **Steps:**
  - (a) Add the F3 pin (passes today) and the F1/F2 tests marked `.disabled("F1/F2 pending Rick")`, so the gap is recorded.
  - (b) Behaviour-preserving: extract a pure `static func landing(of entry: Entry, landed: (UUID) -> Bool) -> EntryLanding` (`.notLanded(reason)`, `.originalOnly(missingCompanion)`, `.complete(counts)`) from `settle` lines 336-379. `settle` calls it with `landed[id] != nil`; `settleStrandedPromotions` keeps its current original-only logic for now.
  - (c) Behaviour change, Rick decides (F1 + F2): `settleStrandedPromotions` and the pending-restore settle call `landing(of:landed:)` with a promote-link predicate (`masterArchiveCopy != nil || isInsideMasterArchive`), and remove folders only on `.complete`. Then enable the F1/F2 tests.
- **Guards to keep, each pinned:**
  - Record-keyed outcomes, never filename (`twoRowsNamed00000MTSKeepTheirOwnOutcomes`).
  - Never-enqueued rows untouched (`intended[entry.id] == nil` → continue). Add a pin.
  - User skips are reported apart from failures (`report.skippedByUser`). Covered by `reportSummary`.
  - A live batch is never settled (`ArchiveAngelLivenessTests.aStrandedPromoteIsSettledAgainstTheCatalog`, the begin/end part).
  - Pending restores are re-applied idempotently (`ArchiveAngelCodex1654Tests`, the relaunch at line 278).
- **Pins before the move:** F3 (new), `twoRowsNamed00000MTSKeepTheirOwnOutcomes`, `aStrandedPromoteIsSettledAgainstTheCatalog`, ArchiveAngelCodex1654Tests (whole suite), ArchiveAngelPlanSettleTests `settleRule` / `settleInterruptedOnDisk`.

### 2. Split `ArchiveAngelPromoter.promote` (CCN 35, 141 NLOC; Promote/, data-risk). Size M, risk HIGH.
- **Steps (behaviour-preserving):** extract, in this order:
  - `settlePriorRestores(plan:model:) -> Bool` (lines 183-206, return false = "not started");
  - `collectInputs(plan:model:freshFixity:) -> PromoteInputs` (ids, titles, dates, sources, roles, intended, plus stamping; lines 210-255);
  - `applySkips(promotePlan.skipped, to:)` (lines 269-278);
  - `journalThenStart(...)` (lines 280-316).
- The batch claim (`ArchiveAngelLiveBatches.claim` plus the `defer` release unless handed to the job) **must stay in `promote`** around all of these, and must not be duplicated into the helpers.
- **Guards to keep:**
  - Claim first; refused = nothing stamped or saved (ArchiveAngelResidualsTests ~322-334, the claim refusal).
  - No master archive → refuse.
  - Identity re-check per row: `ArchiveAngelPromoterTests` "a rewritten source…", "a changed content hash…", "a vanished file…", "a catalog rename is FOLLOWED…", and the SENSOR at line 168.
  - Awaiting restores block a start (Codex1654).
  - The journal (plan.json) must save before the job, and a failed save undoes the stamps: Codex1654, the test around line 222.
  - Only fresh-fixity records lend facts (ArchiveAngelCodex1659Tests 115-160).
  - Family facts are never written over a record's own value (ArchiveAngelFamilyInheritanceTests 122-195).
- **Pin to add first:** `collectInputsMapsCompanionsLikeTheirOriginal`. An entry with one done balance step: the companion gets the original's title, date, source and the role "Balanced audio", and `intended[orig] == [companion]`. Nothing pins these maps today.

### 3. Split `ArchiveAngelJob.selectFromEvidence` (CCN 44, 180 NLOC). Size M, risk MEDIUM (selection only, no writes).
- **Steps:** extract the stages (eligibility filter, ranking/coverage, per-family/event limits, overflow count) as pure `static` functions over the evidence store, and keep the call order exactly.
- **Pins before:** ArchiveAngelEvidencePickTests, ArchiveAngelCharacterizationTests `selectionPinned` and `nudgeCounts`, ArchiveAngelA4DeterminismTests, ArchiveAngelPerfParityTests (`sweepMatchesPurePath`), ArchiveAngelBenchmarkTests (time budget), ArchiveAngelCoverageTests, ArchiveAngelExplicitPickTests.
- **To add:** a 100k-record selection parity sensor that compares picks before and after, if PerfParity does not already cover `selectFromEvidence` with the coverage floors on.

### 4. Break up `Prepare/ArchiveAngelJob.swift` (1,141 lines; `prepare` CCN 37, `run` 26/148, `prepareEntries` 17). Size L, risk MEDIUM (buffer writes, companion records).
- **Steps:**
  - Move the plan-entry builder (lines 472-517) to `ArchiveAngelJob+Entries.swift` as `static func entries(for picks:, model:, fresh:) -> [Entry]`.
  - Move the balance-audio step (about 680-830) to `ArchiveAngelJob+Audio.swift`. Close the S4-3 TODO there (see §2).
  - Leave `run`'s stage order and the `ArchiveAngelLiveBatches.begin/end` pair (lines 378-381) in place.
- **Pins before:** ArchiveAngelWholeJobTests (all 7, especially `aPlanSaveFailingMidBatchStopsTheBatchAndIsNeverReportedAsSuccess` and `readyNeedsEveryStepToReachAVerdict`), ArchiveAngelSkipEntryTests, ArchiveAngelLoggingAndOrderTests, ArchiveAngelFamilyInheritanceTests (inherited date and source on entries), ArchiveAngelAudioOutcomeTests, ArchiveAngelBufferShortTests, ArchiveAngelLifecycleCompanionTests, and the media matrix in ArchiveAngelNoSoundMediaMatrixTests.

### 5. Cheap cleanup: the new file offender, dead code and comments. Size S, risk LOW.
- **Steps:**
  - Move the Catalog-hint hooks added on 10/6 out of `Facade/ArchiveAngel.swift` (814) into the existing `Facade/ArchiveAngel+CatalogHints.swift`, which brings it back under 800.
  - Delete the six dead symbols in §2.
  - Rewrite the self-contradicting comment in `ArchiveAngelCandidate.project`.
  - Close or annotate the S4-3 TODO pair.
  - Join the split doc comment on `promote`.
- **Pins before:** ArchiveAngelCatalogBadgeTests, ArchiveAngelCatalogHintScaleTests, ArchiveAngelFacadeTests, ArchiveAngelCandidateProjectionTests, and a green build. The dead symbols have no callers, tests included.

### Backlog (one line each)
- `ArchiveAngelScorer.floorFires` (39 before the split): re-measure; split the archive/junk/attention groups the way `mediaFloorFires` was. Pins: ArchiveAngelScorerTests, CharacterizationTests `v10AsDataReproducesV10`, ArchiveAngelNoSoundTests. S.
- `ArchiveAngelRejection.name` (~28): a switch table whose names are policy.json identifiers, while the raw values are persisted UI text (pinned by `rejectionRawValues`). Leave it, or derive it from a static `[Self: String]`. Low value. S.
- `ArchiveAngelRecommendations.verdict` (24) and `classify` (18): table-drive them. Pins: ArchiveAngelRecommendationsTests, `unifiedClassesPinned`, ArchiveAngelTruthfulReadinessTests. M.
- `ArchiveAngelReviewSheet.footer` (20/78), and the file at 759 lines: extract a footer view-model. Pin: ArchiveAngelListRowModelTests. S.
- `forgetArchiveAngelCompanions(scopes:)` (19) and `reconcileArchiveAngelBufferAtLaunch` (18): catalog-record writes. Pins: ArchiveAngelCompanionForgetTests, ArchiveAngelBufferReconcileTests. M.
- `AngelRule.problems` (18), `AngelEvalContext.candidateFlag` (17) and `decodeValidated` (17): split per rule kind. Pin: AngelRecommendationPolicyTests. S.
- `Recommend/ArchiveAngelScorer.swift` (1,018): move the pre-S3b table views (after the dead ones go) and the signals into `+Signals.swift`. S.
- `Prepare/ArchiveAngelPlan.swift` (961): move `ArchiveAngelPlanStore` (the save actor and the folder helpers about 880-960) into its own file. Pins: ArchiveAngelUnreadableBatchTests, ArchiveAngelPlanSettleTests. S.
- `Recommend/AngelRuleLanguage.swift` (878): split the evaluator from the validator. S.
- `ArchiveAngelAssessmentPanel.body` (98 NLOC): extract the sub-views. S.
- The plan carries the proposed date as text that gets parsed again; carry an `ArchiveDateHint` alongside it (needs a plan.json additive field, so ask Rick first). M.

## Not covered
- No lizard run: the CCN/NLOC values are the M4's at a70a3562. The figures for the two commits since then are by hand, not measured.
- No duplicate-block (copy-paste) scan of the scope; the nightly reports 1.95% repo-wide, with no per-folder split.
- Not read in full: `Check/ArchiveAngelChecks.swift`, `Review/*` (buffer hygiene and clear), `Promote/ArchiveAngelFamilyFacts.swift`, `ArchiveAngelFactLenders.swift`, `ArchiveAngelFamilyStamp.swift`, `ArchiveAngelFixityCheck.swift`, and the `UI/` folder beyond the offender lines. The fact-lending rules (which relatives may lend through a digest) were not checked against `ArchiveDigestIndex`.
- `Review/VideoScanModel+ArchiveAngelBufferHygiene.swift` (Clear deletes buffer folders) was not compared against F1's "landed" rule. Tonight's suggestion for N1017-H-Archive, or a dedicated R row.
- Nothing was run (no Xcode). The F1/F2 scenarios come from reading the code. The tests above are written to fail today, but they have not been executed.
