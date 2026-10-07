Brief: N1011-D-PrunePlan | Source: main@ebcd2f09 | Wall clock: 30 | Files read: 17
Finding count: 5 (REAL 4 / NEEDS-MAC 0 / NOISE 1)
Verdict: Every rule that can let a copy go in `PrunePlan.plan` is pinned by a test that goes red if its line is deleted; the gaps are the device-count rules: the checklist's verdict counts a copy on the archive volume as an extra device when the plan does not (F1), and that plan rule is unpinned (F2). Pin those, then plan() can be split in five small, behaviour-preserving steps.

## Scope and sources

- **Target:** `PrunePlan.plan(family:related:options:)` and its helpers in `VideoScan/VideoScanCore/Sources/VideoScanCore/PrunePlan.swift` (1240 lines). PrunePlan lives in **VideoScanCore**, not the app target. The brief's "App Swift only" is read as "Swift only, no Python". The app callers were followed to settle findings.
- **Measurements:** I did not install lizard (it was refused last session). The numbers come from the M4 nightly, `origin/metrics:metrics/complexity.jsonl`, last line (ts 2026-10-06T11:36Z, sha a70a3562, lizard 1.22.1), plus `ci/baselines/complexity_debt.json`:

  | Function | CCN | NLOC |
  |---|---|---|
  | `PrunePlan.plan` | 52 | 108 |
  | `PrunePlan.Family.logLine` | 26 | 44 |
  | `ArchiveCopyFamilies.group` | 16 | 41 |
  | `PrunePlan.Family.selection` | 16 | 38 |
  | file length | 1240 lines (threshold 800) | |

  None of these is a NEW offender tonight (debt_new 3 repo-wide, none in this file). Core: 56 offenders, mean CCN 3.72.
- **HEAD vs origin/main:** no diff under `VideoScanCore`, `MediaOps` or `VideoScanTests`, so line numbers hold for main@ebcd2f09.
- **Files read:**
  - Brief rules: README.md and the D theme of NIGHTLY.md.
  - Target and its tests: PrunePlan.swift (all), PrunePlanTests.swift (all), PrunePlanMissingFileTests.swift (all).
  - Callees followed: VideoScanModel+MediaLedger.swift `archiveCopySnapshots` (snapshot builder), VideoScanModel+PruneApply.swift (`pruneTargets`, `pruneSurvivorRequirements`, `preparePrune`, `finishPrune` refs), BackupAttestation.swift (`latestPerKind`, `ProtectionSummary.summarize`), ArchivedWhatNextSheet.swift (header/checklist build), ArchiveVolumeProtectionTests.swift:257-293, CopyFamilyAssessor.swift (header, repair kinds), CatalogContent+Promote.swift `isVersionOfArchived`, VideoRecord+Derived.swift `repairDerivationKinds`.
  - Grepped only: PrunePlanScaleTests.swift, PruneApplyTests.swift, complexity_debt.json.
  - Checked for overlap: N1007 and N1009 (headers only).
- **Already covered elsewhere, not repeated:** N1009-D-Core item 2 already plans splitting the *file* into four. This report plans the *function* and the guards. N1007 covered the relocate/apply side.

## (1) Guard inventory — `plan` and helpers

"Pin" = a test whose assertion goes red if the guard line is deleted. I checked each one by reading the assertion. PPT = `VideoScanCore/Tests/VideoScanCoreTests/PrunePlanTests.swift`, PMF = `…/PrunePlanMissingFileTests.swift`, AVP = `VideoScanTests/ArchiveVolumeProtectionTests.swift`.

### Archive proof (header, never rows)

| # | Line | Rule | Pin |
|---|---|---|---|
| A1 | 1009 | Proof by source only counts a promote link from a non-purged, non-archive, **non-version** member | PPT `testQARedAnArchivedVersionNeverMakesTheUnarchivedOriginalCheckable` (`row.checkable == false`, `archiveVerified == false`): with `!$0.isVersion` gone, the trim's archive copy becomes proof |
| A2 | 1010 | Proof by content only counts the keys of non-version, non-archive members | same test, `byTrimKey` case (`archiveVerified` false, `candidateCount == 0`) |
| A2a | 1010 | `!$0.contentKey.isEmpty` | Redundant: 1015 already requires `!c.contentKey.isEmpty`. Harmless; it is backlog, not a guard |
| A3 | 1013-1016 | An archive-side copy is proof (`archive`) only by source or by content; otherwise it is `versionArchive` (a header note) | `testQARed…` (`f.archive.isEmpty`, `versionArchive == [archivedTrim]`) |
| A4 | 1018 | Family is verified only if a **proof** copy has read-back fixity | PPT `testNoArchiveCopyOrUnverifiedArchiveKeepsEverything` (`shortfall == "archive copy unverified"`) |
| A5 | 1020 | `verifiedArchive` = the first proof copy with fixity (the apply path byte-compares against it) | `testQARed…` (`both.verifiedArchive?.id == archivedOriginal.id`) |
| A6 | 1022 | `originalID` = promote source, which picks the original vs duplicate chip and so the byte-verify count | PPT `testAVersionJoins…` (`.original`), `testRowsAreTheWorkingCopies…` (`.duplicate`), `testQARed…` (`verifyCount == 1`) |

### Working-copy classification (1029-1050) and `lockedReason` (1199-1206)

| # | Line | Rule | Pin |
|---|---|---|---|
| C1 | 1029 | Purged copies are skipped | **UNPINNED at plan level.** Upstream guards hold it twice: `group` drops purged (pinned, PPT `testFamiliesKey…` "purged copies are dropped"), and the snapshot builder skips purged records (pinned, PrunePlanScaleTests "purged records are not snapshotted"). Not a finding. Test to add: `compute(families: [[arch, purgedCopy, a]])` has no row for purgedCopy |
| C2 | 1030 | Never offer the archive copy: kept `.archiveCopy`, never a row | PPT `testOfflineAndPair…` (`reasons["archived.mov"] == .archiveCopy`); `testAVersionJoins…` (`rows` exclude it); rows() 1181 `!c.isArchiveSide` |
| C3 | 1031 | Never offer a copy inside the archive root: kept `.insideArchiveRoot` | PPT `testOfflineAndPair…` (`reasons["inside.mov"]`), `testRowsAreTheWorkingCopies…` (not a row, listed in `archive`) |
| C4 | 1201 | A copy elsewhere on the archive volume is never a candidate (`.onArchiveVolume`) | AVP `moveToTrashNeverOffersOrMovesAnArchiveVolumeCopy` (`!row.checkable`, file still on disk after `applyPrune`). No Core-level pin |
| C5 | 1202 | An offline copy is never a candidate (`.offline`) | PPT `testRowsAreTheWorkingCopies…` (`role == .kept(.offline)`), `testOfflineAndPair…` |
| C6 | 1202-1203 | Offline is judged before missing | PMF `testOfflineIsJudgedBeforeMissing` |
| C7 | 1203 | A missing file is never a candidate (`.fileMissing`) | PMF `testAMissingFileIsListedDisabled…` |
| C8 | 1204 | A recovered pair half is never a candidate (`.pairMember`) | PPT `testRowsAreTheWorkingCopies…` (`.kept(.pairMember)`) |
| C9 | 1201 order | Archive volume is judged first, before offline | **UNPINNED** (low: both outcomes lock the row; only the reason text differs) |
| C10 | 1039 | A missing file holds no device for the bar | PMF `testAMissingFileHoldsNoDeviceForTheBar_ButAnOfflineCopyStillDoes` (`keeperRequired`) |
| C11 | 1039 | A copy on the archive volume holds no device for the bar | **UNPINNED → F2** |
| C12 | 1039-1040 | An offline copy and a pair half do hold a device | offline: PPT `testOfflineCopyCountsAsADeviceAndTheOnlyOnlineCopyMayThenGo`, PMF sensor. Pair: **UNPINNED** (low; deleting the pair case is the conservative direction) |
| C13 | 1042-1046 | A version or noted copy is soft (checkable, never elected, never default-checked) and holds a device | PPT `testKeeperElection…` ("the noted LaCie copy already satisfies +1 device", `keeperRequired == false`), `testOfflineAndPair…` (trash excludes them) |
| C14 | 1210-1213 | `softReason`: version before note | **UNPINNED** order (reason text only) |
| C15 | 1051-1052 | Extra count/bytes = plain + soft | PPT `testOfflineAndPair…` (`extraCount 4`, `extraBytes 4000`), PMF `testAMissingFileIsNotACandidate…` |

### Attestation, related rows, level

| # | Line | Rule | Pin |
|---|---|---|---|
| T1 | 999-1001 | Level = strongest mark in the family (archive copy included) | PPT `testOfflineAndPair…` (`f.level == .important`) |
| T2 | 1056 | Attestation = the **latest** answer per kind across the whole family | **UNPINNED at plan level → F4** (latestPerKind itself is pinned in BackupAttestationTests) |
| T3 | 1057 | Cloud or off-site "yes" meets the want; "no" does not | PPT `testImportantFamilyNeedsDevice…`, `testNotApplicable…` |
| T4 | 1058-1059 | "n/a for these" counts only when there is no yes; it satisfies this batch's advice | PPT `testNotApplicable…` |
| T5 | 1060-1062 | The n/a note appears only when the bar wants cloud/off-site | PPT `testNotApplicable…` (`XCTAssertNil(plan(...bar).note)`) |
| T6 | 1065-1070 | A related row is "different footage" only when the hash kinds compare | PPT `testNameRelatedRecordsAreMightBeCopiesUntilAHashSays` |
| T7 | 1071 | Unhashed members: non-version, online, on disk, not segmented-hashed | PPT `testNameRelated…` (p4), PMF `testAMissingFileIsNeverANameRelatedRow…` |

### THE rule and the bar

| # | Line | Rule | Pin |
|---|---|---|---|
| R1 | 1087-1101 | **No fixity-verified proof copy, nothing is checkable**: every candidate row becomes `.kept(.noArchiveCopy / .archiveUnverified)`, trash is empty, and there is no keeper | PPT `testNoArchiveCopyOrUnverified…`, `testUnverifiedArchiveRowsAreShownButNeverCheckable`, `testQARed…`, `testSelectionAcrossFamilies…` (f3 not checkable) |
| R2 | 1091-1097 | Three advice strings (unverified / only a version archived / none) | the same three tests, exact strings |
| B1 | 1108 | The bar itself requires a keeper when `extraDevices > devicesKept` | PPT `testImportantFamily…` (`keeperRequired`), `testOfflineCopyCounts…` (h) |
| B2 | 1110 | A keeper is elected only among plain copies, and only if required or keep-one | PPT `testOfflineCopyCounts…` (keepOne false → nil keeper), `testAVersionJoins…` ("never a version") |
| B3 | 1114 | The keeper's volume joins devicesAfter | PPT `testOfflineCopyCounts…` (h covered) |
| B4 | 1117-1131 | Bar not met: nothing default-checked, every candidate still checkable, keeper hinted | PPT `testAdviceForAnImportantFamilyWithNoAttestationAndTheOverride` |
| B5 | 1132-1146 | Bar met: trash = plain minus keeper; only those rows are default-checked | PPT `testRowsAreTheWorkingCopies…` (`defaultSelection == trash`), `testImportantFamily…` |
| B6 | 1152-1171 | `barShortfall` strings | PPT `testAdvice…`, `testOfflineCopyCounts…` (i) |
| K1 | 1225-1227 | The user's keeper volume wins outright | PPT `testKeeperElection…` (g) |
| K2 | 1229-1237 | Keeper order: connected working volume, then free space, then a new device, then the lower path | PPT `testKeeperElection…`: all four branches asserted |

### `compute` (feeds plan)

| # | Line | Rule | Pin |
|---|---|---|---|
| P1 | 941 | Keeper volume picker = plain candidates on connected working volumes | PPT `testVolumeChoicesAndTotalsAcrossFamilies` (offline X9 absent), PMF `testAMissingFileIsNotACandidate…` (`keeperVolumes == ["CrucialX9"]`) |
| P2 | 991 | The picker skips versions and noted copies | **UNPINNED** (the picker list only; electKeeper falls back to scoring) |
| P3 | 962 | Skip empty families (`fam[0]` at 997 would trap) | **UNPINNED**, unreachable in production because the snapshot builder never emits purged records. Test to add: `group(batch:[p.id], snapshots:[p])` with p purged, then `compute` gives 0 families and no trap |
| P4 | 971 | Keeper-required count only when covered with a keeper | PPT `testVolumeChoices…` (`keeperRequiredCount == 1`) |

### `Family.selection` (698-737): the verdict the sheet, apply and ledger use

| # | Line | Rule | Pin |
|---|---|---|---|
| S1 | 706 | A missing row is not a remaining copy or device | PMF `testTheSelectionNeverCountsAMissingFileAsARemainingCopy` |
| S2 | 708-710 | Every `.kept` row holds a device, **including `.onArchiveVolume`** | disagrees with plan C11 → **F1** |
| S3 | 715 | Only checked `.duplicate` rows are byte-verified | `testQARed…` (`verifyCount == 1`) |
| S4 | 722-735 | Override and archive-only verdict | PPT `testAdvice…`, `testSelectionAcrossFamilies…` |

## (2) Ranked refactor plan (behaviour-preserving)

Goal: `plan` from CCN 52 to about 12, with no rule changing. The F1 fix *is* a behaviour change, so it ships as its own commit after Rick rules on it, never inside a move.

**Step 0 (before any move, S, risk none): pin and build an oracle.**
- Add the five tests from F1, F2 and F4 and the C1/P3 rows above.
- Copy today's `plan` verbatim into the test target as `legacyPlan` (test-only, with a file comment saying it is deleted when step 5 lands).
- Add a property test: about 2,000 seeded families built from all combinations of the snapshot booleans (archive / inside / onArchiveVolume / online / exists / pair / version / note / fixity / purged), with 0-3 attestations, two bars and keepOne on/off. Assert `PrunePlan.plan(...) == legacyPlan(...)`. Family is `Equatable`, so the whole output (rows, roles, planKeeps, defaultChecked, trash, kept reasons, advice, note) is compared. This is the pin every step below runs against. It is pure and runs on Linux with `swift test --package-path VideoScan/VideoScanCore`.

**Step 1: extract `ArchiveProof` (1009-1022). S, low risk.**
`struct ArchiveProof { archive, versionArchive, verified, verifiedArchive, originalID }`, built by `static func archiveProof(_ fam:)`.
Pins needed first: `testQARed…`, `testNoArchiveCopyOrUnverified…`, `testRowsAreTheWorkingCopies…` (inside-root copy is proof), and the oracle.
Risk: dropping the `!isVersion` filter from one of the two sets. A1 and A2 each have a red test.

**Step 2: extract `classify` (1025-1050) and define `isCandidate` through `lockedReason`. M, medium risk (device counting is the subtle part).**
`static func classify(_ fam:) -> (kept, plain, soft, devicesKept)` plus `static func holdsDevice(_ reason: KeepReason?) -> Bool` (the 1039 rule as a named function). Then `isCandidate(c) = !c.isPurged && !c.isArchiveSide && lockedReason(c) == nil`. That removes the second spelling of the same rule at 985. The two agree today; the oracle plus a 2^6 table test of `isCandidate == (!purged && !archiveSide && lockedReason == nil)` proves it.
Pins needed first: F2's test (C11), PMF `…HoldsNoDevice…` (C10), `testOfflineCopyCounts…` (C12), `testKeeperElection…` (C13), AVP `moveToTrash…` (C4, app-level, Mac only), and the oracle.

**Step 3: extract `attestationState` (1056-1062). S, low risk.**
`(attested, notApplicable, note)`.
Pins needed first: F4's test, `testNotApplicable…`, `testImportantFamily…`.

**Step 4: extract `relatedRows` / `unhashedMembers` (1065-1071). S, low risk.**
Pins needed first: `testNameRelated…`, PMF `…NeverANameRelatedRow…`.

**Step 5: one `Outcome` and one builder for the three return branches (1087-1146). M/L, highest risk. Do it last, alone, with the oracle green before and after.**
`enum Outcome { case locked(KeepReason, advice: String); case barNotMet(shortfall: String, advice: String, keeperID: UUID?); case covered(keeperID: UUID?) }`, decided by one small function. Then a single `build(outcome:)` derives `trash`, `kept` and the row closure from it.
Today each branch hand-builds `kept`/`trash` and, separately, a `candidateRole` closure. That is the same decision written twice per branch, and it is why `defaultSelection == trash` has to be asserted as an invariant in three tests.
Pins needed first: R1/R2, B4, B5 (all pinned), the oracle, and `testScale100kSnapshotsIn5kFamiliesUnderBudget` (the 4 s budget must hold).
Risk: a soft copy's planKeeps or a keeper hint lost in one branch. The oracle catches it.

**Backlog (one line each):**
- `Family.logLine` (CCN 26): extract a `RowCounts` struct shared with `selection` (S).
- `ArchiveCopyFamilies.group` (CCN 16): extract the pass-B climb into `familyKey(ofVersion:)` (S; pins `testAFourHop…`, `testAVersionJoins…`).
- `Family.selection` (CCN 16): reuse step 2's `holdsDevice` once F1 is ruled on (S).
- Split the file (N1009 item 2, already planned; do it after step 5 so the diff is pure moves).
- Stale comments:
  - `lockedReason` doc (1195-1198) says "Offline is judged first", but the archive volume is judged first.
  - The header (49-50) and the `CopyRow` doc (520-521) list the refused rows without the archive-volume case.
  - PPT:328-329 cites `:174-195` and `:902-905`; those lines are now 187-233 and 1018.
- Redundant `!$0.contentKey.isEmpty` at 1010 (A2a).
- Dead or test-only API (app grep finds no callers): `PrunePlan.trashFiles`, `trashCount`, `trashBytes`, `notCoveredFamilies`, `Family.kept`, `Family.cloudOrOffsiteAttested`, `Family.cloudOrOffsiteNotApplicable`, the public `isCandidate`. These are kept alive by tests and the `defaultSelection == trash` invariant. Decide after step 5 whether `trash`/`kept` stay as derived views or go.
- `Family.key` is `fam.first?.contentKey`, not the grouping key. The app uses it only in accessibility identifiers (ArchivedWhatNextSheet:535, 710-757), so it is harmless. Rename it `accessibilityKey` or derive it from the group key.

## (3) Duplicated logic and dead code

- **Same question inside the file, different answers:**
  - "Does this kept copy count as an extra device?": `plan` at 1039 says no for archive-volume copies; `Family.selection` at 708-710 says yes. → F1.
  - "Can this copy be a candidate?" is spelled twice: `isCandidate` (985) and `lockedReason` plus the archive-side checks (1030-1032). They agree today and nothing pins that. Step 2 makes it one rule.
- **Same question in another function:**
  - "Is this family's content archived and verified?": `ProtectionSummary.summarize(family:)` (BackupAttestation.swift:486-488) treats *any* fixity-verified archive-side copy as verified. `plan` (1013-1018) does not count the archive copy of a version. Both are shown on the same sheet. → F3.
  - "Is a balance-audio or cleanup output a repair or a version?" `CopyFamilyAssessor.repairDerivationKinds` (CopyFamilyAssessor.swift:254) includes `balanceAudio`, and its `isRepairDerivative` (262-265) counts cleanup outputs as repairs. `VideoRecord.repairDerivationKinds` (VideoRecord+Derived.swift:54), which the prune snapshot uses, excludes both, so they are versions. → F5 (NOISE: different purposes, no wrong output found).
  - **Checked, no disagreement:** `PruneApply.pruneTargets` / `pruneSurvivorRequirements` re-judge through the *fresh plan's* rows and `Family.selection`; they never restate the rules. The removal boundary re-checks the archive volume itself (`bulkDeleteRefusal`, PruneApply.swift:637-639), so C4 has a second, independent guard. `CatalogContent.isVersionOfArchived` uses the same 4-hop bound and the same repair set as `group`.
  - `DeleteDuplicates` answers a different question (keeper among byte-identical copies) and was not compared in depth.
- **Dead code:** see the backlog list. No `TEMPORARY`, diag code or always-on flags in PrunePlan.swift.

## Findings

### N1011-D-PrunePlan-F1: P3 · REAL · The checklist's verdict counts a copy on the archive volume as an extra device; the plan does not
- **Symbol:** `PrunePlan.Family.selection(_:)`, PrunePlan.swift:708-710 vs `PrunePlan.plan`, PrunePlan.swift:1039.
- **Scenario:**
  - A family has a fixity-verified archive copy promoted from source S on working drive X, and a byte-identical copy Y elsewhere on the archive volume (`isOnArchiveVolume`, online). The bar is ordinary-style: +1 device, no cloud. Defaults: keepOne on, or off.
  - `plan`: Y is `.kept(.onArchiveVolume)` and holds no device (1039, "not an EXTRA device beyond the archive"). `keeperRequired` is true and S is the hinted keeper.
  - The person checks S. `selection` puts Y's volume into `devicesAfter` (709). One device ≥ one required, so `overrideCount` is 0, `overrideSentence` is nil and `archiveOnlyFamilies` is empty.
  - The plan's own rule says this choice leaves no extra device. The confirmation should say "goes against the bar … needs 1 more device", and the ledger's `override` (PruneApply.swift:783-791, `finishPrune` → `judged.overrideText`) should record it. Today neither happens.
  - `pruneTargets`' verdict-changed check (PruneApply.swift:244-251) shares the same blind spot.
- **Not a data-loss path:** the verified archive copy is untouched, and Y physically exists. The cost is an override that is understated on screen and in the family record.
- **Smallest test (fails today):** in PPT, `let y = copy("y.mov", vol: "FamilyArchive")` with `isOnArchiveVolume = true`; `f = plan([src, archiveCopy(promotedFrom: src.id), y], keepOne: false, bar: ordinaryBar)`; `XCTAssertTrue(f.keeperRequired)`; `XCTAssertEqual(f.selection([src.id]).overrideCount, 1)`. Today it is 0.
- **Fix direction (behaviour change, Rick to rule):** `selection` skips `.kept(.onArchiveVolume)` for devices, through the same `holdsDevice` predicate as step 2.

### N1011-D-PrunePlan-F2: P3 · REAL · The plan's "a copy on the archive volume is not an extra device" rule is unpinned
- **Symbol:** `PrunePlan.plan`, PrunePlan.swift:1039 (`locked != .onArchiveVolume`); twin `PrunePlan.isCandidate`, PrunePlan.swift:985 (`!c.isOnArchiveVolume`).
- **Scenario:** delete `locked != .onArchiveVolume,` from 1039. A family with a verified archive copy, one plain copy S and one archive-volume copy Y, keepOne off, ordinary-style bar: `devicesKept = {archive volume}`, so `keeperRequired` is false, the family is covered and S becomes a **default check**. The plan then leaves the family with only the archive copy plus a copy on the same physical drive, which is exactly what the comment at 1036-1038 forbids.
- **Why nothing goes red:** no Core test sets `isOnArchiveVolume`, and AVP `moveToTrash…` asserts only Y's checkability, not S's default check or `keeperRequired`. Removing the 985 clause changes only the picker (the snapshot builder already marks archive-volume drives not-working), so it is low risk.
- **Smallest test (passes today, red on deletion):** the same family with keepOne off, `XCTAssertTrue(f.keeperRequired)`, `XCTAssertFalse(f.defaultSelection.contains(src.id))`, `XCTAssertEqual(f.rows.first { $0.id == y.id }?.role, .kept(.onArchiveVolume))`.

### N1011-D-PrunePlan-F3: P3 · REAL · The protection line says "Archive ✓verified" for a family the plan says has no verified archive copy
- **Symbol:** `ProtectionSummary.summarize(family:)`, BackupAttestation.swift:486-488, fed by `ArchiveCopySnapshot.copyFacts` (PrunePlan.swift:148-153) via `ArchiveCopyFamilies.protection` (238-242). Compare `PrunePlan.plan` 1013-1018.
- **Scenario:** the shape of PPT `testQARed…`. Only the trim of an original was promoted and verified. `group` pulls the trim's archive copy into the original's family. `plan` says `archive ✗ unverified (0) + 1 version archived` and locks every row. `protection(families:)` sees an archive-side copy with fixity and returns `archive == .verified`. ArchivedWhatNextSheet shows `protection.displayLine` (sheet:175) above the same family, so the sheet says "Archive ✓verified" over rows locked for "only a version of this is archived".
- Same root: `copyFacts` has no `isOnArchiveVolume`, so a copy elsewhere on the archive volume is counted as an online *working* copy on that volume.
- **Not a data-loss path:** the rows gate on `plan`. The cost is a wrong protection line on the very sheet that asks the person to decide.
- **Smallest test (fails today):** in `testQARed…` after `let fams = …`, `XCTAssertNotEqual(ArchiveCopyFamilies.protection(families: fams).archive, .verified)`.

### N1011-D-PrunePlan-F4: P3 · REAL · "Latest answer across the whole family" is unpinned at plan level
- **Symbol:** `PrunePlan.plan`, PrunePlan.swift:1056.
- **Scenario:** copy A has cloud "yes" at t1; copy B has cloud "no" (withdrawn) at t2 > t1, important bar. Today the latest is "no": not covered, nothing default-checked. Replace 1056 with "any yes in `fam.flatMap(\.attestations)`" (or take latest per copy, not across the family). The family becomes covered, its extra copies are **default-checked**, and the override is not recorded.
- **Why nothing goes red:** `latestPerKind` is pinned only directly (BackupAttestationTests:57-63, BackupAttestationTimestampTests:36). No PPT case has a later "no" on a different member than an earlier "yes". The apply-side test PruneApplyTests:1401 covers withdrawal *between* show and apply, not this.
- **Smallest test (passes today, red on change):** `plan([arch, a(yes@t1), b(no@t2)])`, then `XCTAssertFalse(covered)` and `XCTAssertTrue(defaultSelection.isEmpty)`.

### N1011-D-PrunePlan-F5: P3 · NOISE · Two "repair kinds" sets disagree about balance-audio and cleanup outputs
- **Symbol:** `CopyFamilyAssessor.repairDerivationKinds` / `isRepairDerivative`, CopyFamilyAssessor.swift:254-265 vs `VideoRecord.repairDerivationKinds`, VideoRecord+Derived.swift:54 (used by the prune snapshot, VideoScanModel+MediaLedger.swift:261).
- **Why NOISE:** the Promote Helper calls a balanced copy a "Repaired copy" that anchors its source. The prune plan calls it a "balanced version": checkable, unchecked by default, and gone on provenance without a byte read, per Rick's 2026-09-20 ruling. I found no input where either produces a wrong keep/go result; both agree the source is the master. Logged as definitional debt only.
- **Possible test:** a sensor asserting the assessor's set equals `VideoRecord.repairDerivationKinds ∪ {"balanceAudio"}`, with a comment saying why. That would at least make a future change deliberate.

## Not covered
- Building and running the tests (Linux, no Xcode). Every "pin" claim comes from reading the assertions, not from mutation runs. Step 0's oracle is the way to confirm them on the M4.
- `DeleteDuplicates` keep/go rules compared in depth.
- `ProtectionSummary` beyond F3.
