Brief: N1018-D-MediaOps | Source: main@c91abaa5 | Wall clock: 10 (container clock; see Blockers) | Files read: 34
Finding count: 7 (REAL 5 / NEEDS-MAC 1 / NOISE 1)
Verdict: MediaOps has no new complexity offenders tonight. The debt that matters is duplicated answers: Delete Duplicates still treats a row that Relocate marked "deleted" (because another drive holds the content) as a surviving keeper, which Relocate itself now refuses (P2). Four jobs still keep their own check-then-move publisher next to the shared no-clobber one. A dead private copy of the Delete Duplicates front door is still in ContentView.

Note on rule 3 of the standing rules: this row's brief said "do not commit or push", so the report is left uncommitted in the working tree.

## Step 0 — measurements used

- `ci/baselines/complexity_debt.json`: 50 MediaOps entries (CCN > 15 or NLOC > 80).
- `origin/metrics:metrics/complexity.jsonl` last line: ts 2026-10-07T11:26Z, sha 4b79bbbb.
  - MediaOps: 110 files, 1,696 functions, 43 over CCN 15, 3 over CCN 30, 32 over 80 lines, 50 offenders, 13 files over 800 lines, mean CCN 3.65.
  - Repo-wide `debt_new` = 0 and `debt_worse` = 1. No MediaOps function is in `top15`.
- **New offenders in scope: none.** The folder count went from 48 to 50 between the 10-06 and 10-07 runs. A diff of the baseline history (8314f8fb → 456d8c1b/082a9eae → de2e0ac9) shows that change is re-keying only (e.g. `DeleteDuplicatesDiskWorker.set.deleteQuarantined` → `DeleteDuplicatesDiskWorker.deleteQuarantined`, `PruneApplyJob.cancel.run` → `PruneApplyJob.run`). Every function and its CCN/NLOC is unchanged.
- **Caveat:** the metrics run (11:26Z) is older than merge b83405e1 (14:19Z). That merge rewrote `ReformatJob.runReformat` (325 lines changed), grew `VideoScanModel+JunkDelete.swift` by 67 lines and changed `RelocateReconcile`/`+Relocate`. The numbers below for those functions predate it. Tonight's 2 AM run will re-measure them.

## Step 1 — offender table (scope `VideoScan/VideoScan/MediaOps/`)

DR = a data-risk file per the brief's list. All rows come from the baseline. Sorted by CCN.

| CCN | NLOC | Function | File | DR |
|---|---|---|---|---|
| 39 | 96 | `DeleteDuplicatesJob.finishRun` | DeleteDuplicatesJob.swift | DR |
| 32 | 235 | `VideoScanModel.runRelocate` | VideoScanModel+Relocate.swift | DR |
| 31 | 114 | `VideoScanModel.pruneOneCopy` | VideoScanModel+PruneApply.swift | DR |
| 30 | 164 | `BalanceAudioJob.runBalance` | BalanceAudioJob.swift | publisher |
| 30 | 95 | `DeleteDuplicatesForecast.compute` | DeleteDuplicatesForecast.swift | DR |
| 30 | 156 | `VideoScanModel.deleteConfirmedJunk` | VideoScanModel+JunkDelete.swift | DR |
| 27 | 138 | `RebuildAudioJob.runRebuild` | RebuildAudioJob.swift | publisher |
| 26 | 86 | `DeleteDuplicatesDiskWorker.deleteQuarantined` | DeleteDuplicatesJob.swift | DR |
| 26 | 51 | `MissingAudioFinder.evaluate` | MissingAudioFinder.swift | |
| 26 | 156 | `TrimJob.runTrim` | TrimJob.swift | publisher |
| 25 | 103 | `DeleteDuplicatesJob.dispatchPairs` | DeleteDuplicatesJob.swift | DR |
| 25 | 95 | `DeleteDuplicatesJob.revalidateForResume` | DeleteDuplicatesJob.swift | DR |
| 25 | 123 | `DeleteDuplicatesJob.runPair` | DeleteDuplicatesJob.swift | DR |
| 25 | 112 | `RelocateReconcile.reconcilePlan` | RelocateReconcile.swift | DR |
| 24 | 27 | `MediaFileOperationKind.badgeText` / `.logVerb` / `.badgeColor` (three parallel switches) | MediaFileOperations.swift, MediaFileOperationsWindow.swift | |
| 24 | 110 | `MediaFileOperationRow.trailingStatus` | MediaFileOperationsWindow.swift | |
| 24 | 95 | `RescueFileCopier.copy` | RescueFileCopier.swift | DR |
| 24 | 42 | `VerifyVideoRules.noteFragment` | VerifyVideoRules.swift | |
| 23 | 80 | `PruneApplyJob.run` | PruneApplyJob.swift | DR |
| 23 | 151 | `TranscodeJob.runTranscode` | TranscodeJob.swift | publisher |
| 20 | 123 | `CleanupJob.runCleanup` | CleanupJob.swift | publisher |
| 20 | 55 | `DeleteDuplicatesDiskWorker.phaseOne` | DeleteDuplicatesJob.swift | DR |
| 20 | 74 | `MissingAudioFinder.scanRootCandidates` | MissingAudioFinder.swift | |
| 20 | 95 | `SignatureVerification.deleteQuarantined` | SignatureVerification.swift | DR |
| 20 | 54 | `SignatureVerification.verify` | SignatureVerification.swift | DR |
| 19 | 69 | `DeletionTierFacts.recheck` | DeleteDuplicatesPlan.swift | DR |
| 19 | 57 | `SiblingProver.prove` | DeleteDuplicatesSiblingProof.swift | DR |
| 19 | 106 | `MediaFileOperationRow.body` | MediaFileOperationsWindow.swift | |
| 19 | 116 | `VideoScanModel.combineAllPairsInternal` | VideoScanModel+Combine.swift | |
| 18 | 81 | `CorrelationScorer.assignPairs` | CorrelationScorer+Snaps.swift | |
| 18 | 88 | `DeletionTierFacts.gather` | DeleteDuplicatesPlan.swift | DR |
| 18 | 85 | `VideoScanModel.preparePrune` | VideoScanModel+PruneApply.swift | DR |
| 17 | 115 | `ReformatJob.runReformat` (pre-b83405e1) | ReformatJob.swift | publisher |
| 17 | 50 | `VideoScanModel.applyEnrichmentInheritance` | VideoScanModel+DuplicateEnrichment.swift | |
| 17 | 55 | `VideoScanModel.authorizeDuplicateDeletion` | VideoScanModel+Duplicates.swift | DR |
| 17 | 65 | `VideoScanModel.settleDeletedDuplicate` | VideoScanModel+Duplicates.swift | DR |
| 16 | 88 | `VideoScanModel.runMuxAndVerify` | VideoScanModel+Combine.swift | |
| 16 | 40 | `VideoScanModel.deletionTierCandidates` | VideoScanModel+Duplicates.swift | DR |
| 16 | 35 | `VideoScanModel.pruneOverlap` | VideoScanModel+PruneApply.swift | DR |
| 16 | 57 | `VideoScanModel.pruneTargets` | VideoScanModel+PruneApply.swift | DR |
| 16 | 54 | `VideoScanModel.applyHumanMetadataInheritance` | VideoScanModel+RepairLifecycle.swift | DR |
| 15 | 127 | `CombinePairSheet.body` | CombineSheet.swift | |
| 15 | 83 | `CombineVerifier.verifyCombineOutput` | CombineVerifier.swift | |
| ≤11 | 83–116 | `VerifyAudioSheet.findingRow`, `MusicTriageSheet.body`, `CombineSheet.pairSelectionSection`, `TranscodeSheet.body`, `DeleteConfirmedJunkConfirmSheet.body` (length only, SwiftUI) | — | |

**Files over 800 lines (`wc -l`):**

| Lines | File |
|---|---|
| 2,599 | DeleteDuplicatesJob.swift (DR) |
| 1,485 | VideoScanModel+Duplicates.swift (DR) |
| 1,407 | MediaFileOperations.swift |
| 1,299 | DeleteDuplicatesPlan.swift (DR) |
| 1,265 | MediaFileOperationsWindow.swift |
| 1,029 | VideoScanModel+Relocate.swift (DR) |
| 1,010 | SignatureVerification.swift (DR) |
| 996 | TranscodeJob.swift |
| 886 | VideoScanModel+Combine.swift |
| 862 | VerifyVideoRules.swift |
| 857 | BalanceAudioJob.swift |
| 850 | RelocateReconcile.swift (DR) |
| 834 | VideoScanModel+PruneApply.swift (DR) |
| 808 | MissingAudioFinder.swift |

## Step 2 — duplicated logic, dead code, leftovers

How each known candidate came out:

| Candidate | Result |
|---|---|
| Partial-file / publish implementations | **Still two.** Transcode, Reformat (since b83405e1) and Combine use `PartialFileNaming.reserve` + `ExclusivePublish.renameNoClobber`. Trim, Cleanup, Rebuild and Balance each carry their own copy of "uniquify, fixed `ReformatJob.partialURL`, `FileManager.moveItem` in a 100-try loop" (F4, F5). |
| "Is this file on the archive / read-only / offline" | Planning goes through one shared `bulkDeleteRefusal` (TrashSelection, PruneApply, Duplicates selection and the survivor rule). At the removal moment there are two forms: `ArchiveRemovalCheck.bulkRefusal` (Delete Duplicates, Transcode) and a hand-rolled copy in `deleteConfirmedJunk` (F7). Offline checks all use `VolumeReachability.isReachable`. A dead third "pick the online copy" rule exists (F3, `bestCopy`). |
| Copy verification | Relocate copy = size + `partialMD5` (head and tail 64 KB). Delete Duplicates = full read in quarantine. Prune = archive fixity + one-sided full read (`verifyAgainstStoredKeeper`). The Relocate weakness is already filed as N1007-R-F2, so it is not re-filed here. It is backlog item B4. |
| Two delete engines | DeleteDuplicates (quarantine → full read → `deleteQuarantined`) and PruneApply → `deleteConfirmedJunk` share the tier constants. `DeleteDuplicatesForecast` uses `DeletionTierDecision` and `duplicateSurvivorStandingRule`, the same as the job. **What they don't share with Relocate is which catalog rows count as a live copy** (F1). |
| Private Delete Duplicates flow in App/ContentView.swift | **Still present, and unreachable** (F2). |
| TEMPORARY / diag leftovers | None in scope. Grep for `TEMPORARY|DIAG|FIXME|XXX|HACK` hits only the word "DIAGNOSES" in two doc comments. |
| TODOs | 2. `RelocateProgressSheet.swift:25` is stale (F6). `VideoScanModel+RepairLifecycle.swift:26` is a deliberate scope note, not stale. |
| Always-on flags | None found. Grep for `static let/var … = true` and `*Enabled = true` in scope finds nothing. |

## Findings

### N1018-D-MediaOps-F1 — P2 · REAL · Delete Duplicates can keep a copy that Relocate already marked deleted (Relocate refuses that same copy as a witness), so the only copy off the retiring drive goes to the Trash
- **Symbols:**
  - `DuplicateDetector.analyze`: DuplicateDetector.swift:35, via `pfActiveRecords`, Catalog/CatalogQueries.swift:756, which filters on `!isPurged && !isSetAside && !isSuperseded`.
  - `VideoScanModel.keepersByGroupID`: VideoScanModel+Duplicates.swift:1251.
  - `VideoScanModel.duplicateDeletionSelection`: :1117.
  - `VideoScanModel.deletionTierCandidates`: :828, which filters on `!r.isPurged` only.
  - The other answer is `VideoRecord.isLiveRelocateWitness`: RelocateReconcile.swift:357, added in b83405e1. It excludes `archiveStage == .manuallyDeleted` with the comment "two drives must never vouch for each other".
  - The Bucket E write: VideoScanModel+Relocate.swift:402 (`r.archiveStage = .manuallyDeleted`; `purgedAt` stays nil and the file is never touched).
  - Grep: no file in the duplicate pipeline (`Duplicate*`, `DeleteDuplicates*`, `+Duplicates`, `+DuplicateEnrichment`) reads `archiveStage`.
- **What's wrong:**
  - The question is "is this catalog row a live copy that can stand for the content?" Relocate says no for a `.manuallyDeleted` row.
  - Duplicate detection, keeper election and the survivor count say yes.
- **Scenario:**
  1. Drive S (workspace role) holds X and a second copy Y of the same content in a backup folder. Drive T (backup role, safe host) holds W. All three are already one duplicate group. X is keeper because workspace (50) outranks backup (10) (`DuplicateKeeperPolicy.precedenceScore`).
  2. Relocate S → D runs with "skip duplicates on other volumes" (the default). W is a live, present, independent witness, so X and Y both go to Bucket E. They are marked `.manuallyDeleted` and are not copied.
  3. Before S is unplugged, the Storage card suggests reclaiming T. Delete Duplicates on T: W is `.extraCopy` and its keeper X is on S, which is online, known and higher-ranked, so cross-volume mode is eligible.
  4. Counted survivors are keeper X plus sibling Y. Both are still on disk with reproducing fixity, so `recheck()` passes. n = 2 on one drive, so the tier is **Trash**. W moves to T's Trash.
  5. The retire offer (`RelocateRetireSheet`) does not re-check witnesses. Rick retires and disconnects S, as Relocate promised the content was safe on T.
  6. The only copy is now in T's Trash. It is lost when the Trash is emptied.
- **Why P2, not P1:** the last step goes through the Trash tier. A permanent delete would need 3 counted copies on 2 drives, and then a copy off S survives. Rick may raise it, since the Relocate summary actively tells him S is safe to retire.
- **Guards checked:**
  - `recheck`/`removalBoundary` only prove the counted copies exist on disk now. They do (S is still mounted).
  - `isLiveRelocateWitness` protects only the Relocate side.
  - Prune is not affected the same way: its required survivor is the verified archive copy (`pruneSurvivorProblemInCatalog`, PruneApply.swift:405).
- **Smallest pinning test (fails today):**
  1. Build three records with one content hash: X and Y under `/Volumes/S` (with `archiveStage = .manuallyDeleted`) and W under `/Volumes/T`. Use a keeper policy ranking S above T.
  2. Call `DuplicateDetector.analyze`.
  3. Assert X is not `.keep`, or that `model.duplicateDeletionSelection(onVolume: "/Volumes/T").targets` does not contain W.
  4. Today X is keeper and W is a target.

### N1018-D-MediaOps-F2 — P3 · REAL · CatalogView's private Delete Duplicates picker and confirmation are dead, diverged code
- **Symbols:**
  - `CatalogView.withDuplicateAlerts`: App/ContentView.swift:1027–1062 (picker sheet and "Delete Duplicates" alert).
  - `CatalogView.prepareDeleteDuplicatesConfirmation`: :1682.
  - `CatalogView.deleteDuplicatesConfirmMessage`: :1656.
  - `@State` :356–372.
- **Evidence:**
  - Repo-wide grep shows `deleteDuplicatesVolumePicker` is only ever set to `nil` (:1041, :1045). Nothing opens the sheet, so the alert and its `startDeleteDuplicates` button can never be reached.
  - `CatalogDuplicatesMenuTests.confirmationIsRaisedFromThePickerOnDismiss` (:128–144) pins the dead copy and says "kept, unreachable … Phase C removes it".
- **Divergence from the live front door (`DeleteDuplicatesFlow.swift`):**
  - no "Not part of this: …" line (GH #258 left-alone copies);
  - no `readOnlyVolumeNames` passed to the picker;
  - the log line doesn't name its source.
  - Anyone who rewires it gets a confirmation that hides held copies and read-only drives.
- **Keep:** the "Resume Deleting Duplicates?" alert in the same modifier (:1063–1090) is live (it is driven by `model.pendingDeleteDuplicatesResume`).
- **Pinning test:** a source sensor that `ContentView.swift` contains no `DeleteDuplicatesVolumePicker(` and no `startDeleteDuplicates(`. It fails today.

### N1018-D-MediaOps-F3 — P3 · REAL · Dead or production-dead functions, two of them on destructive paths
| Symbol | Where | Callers |
|---|---|---|
| `SignatureVerification.quarantineAndDelete` | SignatureVerification.swift:825 | Tests only (SignatureVerificationOneSidedTests, SignatureConcurrencyScaleTests, DeleteDuplicatesCodex1593Tests). It is a plan-less quarantine-then-unlink. A new caller would skip the plan write that crash recovery depends on (the header's "blocker 2"). |
| `ReformatJob.atomicPublish` | ReformatJob.swift:586 | Tests only (StallMonitorTests:410/431). Two stale comments still cite it, wrongly: CleanupJob.swift:395 and TrimJob.swift:566 both say it "replaces an existing destination". It has been no-clobber since 2026-09-22. |
| `CorrelationScorer.bestCopy` | CorrelationScorer.swift:513 | None, in app or tests. It is another "prefer the online copy" rule. |
| `DerivativeOutputPublish.isStalePartial` | DerivativeOutputPublish.swift:233 | None. Its doc says "exposed for tests", but no test calls it. |

- **Scenario:** none today. These are debt. A future caller of `quarantineAndDelete` gets a delete with no recovery record.
- **Pinning:** a dead-symbol sensor (grep the app target) for the four names, after removal. For the two test-only ones, move the tests onto the live paths first (see backlog B1).

### N1018-D-MediaOps-F4 — P3 · NEEDS-MAC · Six check-then-`moveItem` "no-clobber" renames sit next to the shared RENAME_EXCL helper, two of them in quarantine put-back
- **Symbols:**
  - Publishers (N1014-H-F4, still open after b83405e1, which only touched `CleanupFFmpegEngine`):
    - `CleanupJob.publishOffMain`, CleanupJob.swift:435
    - `TrimJob.promoteNonClobbering`, TrimJob.swift:588
    - `RebuildAudioJob.runRebuild`, RebuildAudioJob.swift:555
    - `BalanceAudioJob.runBalance`, BalanceAudioJob.swift:600
  - Put-back (data-risk, new here):
    - `SignatureVerification.restoreOrRetain`: :856 `fileExists(original)`, then :861 `moveItem`.
    - `DeleteDuplicatesJob.restoreQuarantined`: :2206 `fileExists(originalPath)`, then :2209 `moveItem`.
- **Duplicated question:** "put this file at that name, never over anything". `ExclusivePublish.renameNoClobber` (PartialFileNaming.swift:444) already answers it with RENAME_EXCL, then link, then refuse.
- **Scenario:**
  1. During a resume put-back, something creates a file at the original path (e.g. a sync tool restoring it) between the `fileExists` check and the rename.
  2. If Foundation's `moveItem` is check-then-`rename(2)` on Darwin, the new file at that path is replaced.
- **Why NEEDS-MAC:** Darwin's `moveItem` may already refuse atomically. The window is microseconds.
- **Pinning test (Mac):** set the `PartialFileNaming.beforeFallbackPublish`-style seam (or swizzle) to create the destination between the check and the rename. Assert the occupant's inode survives and the quarantined file stays retained. The cheap pin is a source sensor that these six sites call `renameNoClobber`. It fails today.

### N1018-D-MediaOps-F5 — P3 · REAL · Two partial-file conventions: Cleanup, Rebuild and Balance crash leftovers are never swept and silently push the output name along
- **Symbols:**
  - `PartialFileNaming` header (:3–6) claims "the ONE mechanism".
  - Trim, Cleanup, Rebuild and Balance use the fixed `ReformatJob.partialURL` (`<stem>.vs-partial.<ext>`, ReformatJob.swift:573).
  - `PartialFileNaming.isPartialName` (:81) requires the 8-hex token, so `sweepStale` can never match the fixed name.
  - Their `taken()` closures (CleanupJob.swift:410, RebuildAudioJob.swift:460, BalanceAudioJob.swift:493, TrimJob.swift:575) check only the fixed sibling. They cannot see a reserved partial.
- **Scenario:**
  1. The app is force-quit while Cleanup copies its render into `<stem>_cleaned.vs-partial.mov`. The in-process `try? removeItem` never runs.
  2. No sweep removes it. Trim cleans its own leftover on the next run (:283); Cleanup, Rebuild and Balance do not.
  3. Every later Cleanup of that file sees the name as taken and publishes `<stem>_cleaned 2.mov`.
  4. The leftover (a full-size partial copy) stays on the drive indefinitely.
- **Impact:** disk litter and a surprise name. No data loss.
- **Pinning test:**
  1. Create `<stem>_cleaned.vs-partial.mov` with mtime 25 h ago.
  2. Call `CleanupJob.publishOffMain` (or `PartialFileNaming.sweepStale` on the folder).
  3. Expect either the leftover removed, or the planned name kept.
  4. Today the output becomes `… 2.mov` and the leftover stays.

### N1018-D-MediaOps-F6 — P3 · REAL · A stale TODO and a stale lint suppression in RelocateProgressSheet
- **Symbol:** `RelocateProgressSheet.model`, RelocateProgressSheet.swift:25–29.
- **What's stale:**
  - The TODO says "model is declared but the body reads from dashboard.* only", and the line carries `vs-lint:disable-next vs-env-object-unused`.
  - The body's `footer` calls `model.cancelActiveRelocate()` (:73), so both the TODO and the suppression are wrong.
  - The suppression also hides the rule from the next real regression in this file.
- **Pin:** delete both lines. The vs-lint rule then passes on its own.

### N1018-D-MediaOps-F7 — P3 · NOISE · Junk deletion hand-rolls the removal-time archive and read-only check instead of `ArchiveRemovalCheck`
- **Symbols:**
  - `VideoScanModel.deleteConfirmedJunk`: VideoScanModel+JunkDelete.swift:323–372. It calls `archiveVolume.verdictAtRemoval`, then `readOnlyVolumes.verdictAtRemoval`.
  - The shared form is `ArchiveRemovalCheck.bulkRefusal` / `refusal(forPath:)`, Archive/ArchiveVolumeProtection.swift:589–618.
- **The difference:** under a provisional snapshot, `ArchiveRemovalCheck` marks "unprovable" as transient: leave the file and record no refusal. Junk reports a hard "refused" for the same case.
- **Why NOISE:** both leave the file alone, so only the result-sheet wording differs. Junk's per-file fresh read-only snapshot (codex #258 F5) is stricter than a once-captured `ArchiveRemovalCheck.readOnly`. Any merge must keep that.
- **Listed because:** it is the third copy of the removal-boundary logic (with `DeleteDuplicatesJob.removalBoundary` and `ArchiveRemovalCheck`). See backlog B3.

## Step 3 — ranked refactor plan

### R1 — One "live copy" predicate shared by Relocate witnesses and Delete Duplicates survivors (fixes F1) · **DATA-RISK** · M
- **Steps:**
  1. Behaviour-preserving: rename `VideoRecord.isLiveRelocateWitness` to `VideoRecord.isLiveCopy`, moved to a neutral file (e.g. `Catalog/CatalogQueries.swift` beside `pfActiveRecords`) with the same body. Relocate calls it. Nothing else changes.
  2. Behaviour change (Rick decides, under the escalation rule "anything affecting deletion"): `DuplicateDetector.analyze` excludes `!isLiveCopy` rows from keeper election. As a minimum, `deletionTierCandidates` never counts a `.manuallyDeleted` row, and `duplicateDeletionSelection` refuses a target whose keeper is `.manuallyDeleted`, with the reason "keeper was marked deleted by Relocate".
  3. Re-run the detector after a Relocate apply, so old keepers re-elect.
- **Pinning tests that must exist BEFORE the move:**
  - `RelocateWitnessLivenessTests`: `trashedWitnessRecordIsNotASurvivingCopy`, `purgedButNotTrashedWitnessRecordIsNotASurvivingCopy`, `permanentlyDeletedWitnessRecordIsNotASurvivingCopy`, `manuallyDeletedWitnessRecordIsNotASurvivingCopy`, `liveWitnessPresentOnDiskStillMakesTheRecordSafelyRedundant`. These pin step 1.
  - `RelocateSafelyRedundantTests`, `DuplicateDetectorTests.exactDuplicateHashProducesKeeperAndExtraCopy`, `keeperOnSameVolumeIsDeletable`, `DuplicateKeeperPolicyTests`, `DuplicateCrossVolumeDeleteTests`, `DeleteDuplicatesCodex258TierTests`. These pin unchanged election and tiers for live rows.
  - **Add:** the F1 test above (red before step 2).
- **Risk:** re-election changes which copy is "keep" in existing groups, including dossier inheritance (`DuplicateKeeperCarryOverTests` must stay green). It needs a codex pass on the delete path.

### R2 — Delete the dead ContentView Delete Duplicates copy (fixes F2) · S
- **Steps:**
  1. Remove the picker `.sheet`, the "Delete Duplicates" `.alert`, `prepareDeleteDuplicatesConfirmation`, `deleteDuplicatesConfirmMessage` and their `@State` (`showDeleteDuplicatesConfirm`, `deleteDuplicatesVolumePicker`, `pickedDeleteDuplicatesVolume`, `deleteTarget*`).
  2. Keep the volume-rename alert and the Resume alert.
  3. Edit `CatalogDuplicatesMenuTests.confirmationIsRaisedFromThePickerOnDismiss` to keep only its `DeleteDuplicatesFlow` half, and add the F2 absence sensor.
- **Pinning before:**
  - `CatalogDuplicatesMenuTests.toolbarDoesNotBuildVolumeItems`, `confirmationIsRaisedFromThePickerOnDismiss` (flow half), `pickerPreselectsTheGivenDrive`.
  - `StewardSensorTests` (:224, the steward pane opens the shared door).
  - The UI sensor for the Resume alert, if one exists. If not, add a source sensor that `ContentView.swift` still contains `resumeDeleteDuplicates(plan:` and `putBackStrandedDuplicates()`.
- **Risk:** low (unreachable code). Watch the type-checker: `withDuplicateAlerts` shrinks.

### R3 — One no-clobber promote for Trim, Cleanup, Rebuild and Balance (fixes F4 publishers and F5) · M
- **Steps:**
  1. Behaviour-preserving extract: `DerivativeOutputPublish.promoteUniquifying(partialPath:preferred:nextName:taken:) throws -> URL`, holding the bounded 100-try loop that all four copy. Keep `moveItem` inside for this step, so it is a pure move. Each job passes its own `nextName` (`trimmedOutputURL`, `cleanedOutputURL`, `repairedOutputURL`, `balancedOutputURL`). Trim keeps its "own partial does not count" `taken`.
  2. Swap `moveItem` for `ExclusivePublish.renameNoClobber`. This makes the behaviour stricter: a drive with neither RENAME_EXCL nor link now refuses.
  3. Move the four jobs to `DerivativeOutputPublish.reservePartial` / `PartialFileNaming.remove` / `keepUnpublished`, as Reformat did in b83405e1. Then `ReformatJob.partialURL` and `atomicPublish` can go.
- **Pinning before:**
  - Trim: `TrimSensorTests.publishNeverClobbers`, `partialNamingConventionPinned`, `stalePartialFromCrashIsRecovered`, `ffmpegFailureLeavesNothing`, `verifyFailureLeavesNothing`.
  - Cleanup: `CleanupSensorTests.partialNamingConventionPinned`, `finalNameNeverExistsMidRender`, `originalUntouchedAfterFullRealJob`.
  - Naming: `TrimLogicTests.trimmedNameUniquifiesFinderStyle`, `RebuildAudioFixTests.uniquifyCountersAreFinderStyle`, `repairedNameIsAlwaysMovBesideSource`, `BalanceAudioDVOutputTests`.
  - Shared publishers: `PublishNeverOverwritesOrLosesOutputTests`, `ReformatPartialReservationTests`, `PartialRegistryCrossJobTests`, `AtomicFilePublishSensorTests.onlyKnownSitesCallRenameDirectly`.
  - **Add (only CleanupTests matched a clobber grep):** a "pre-existing file at the planned name is never overwritten" test for Rebuild and Balance, and the F5 leftover test (red until step 3).
- **Risk:** the sensors pin the fixed partial name (`ReformatJob.partialURL` in TrimSensorTests:70/98, CleanupSensorTests:103, ArchiveProtectionFollowupTests:720, FFmpegEncodeCheckTests:112). Step 3 must update them in the same commit, and say so.

### R4 — One quarantine put-back primitive (F4 put-back half) · **DATA-RISK** · M
- **Steps:**
  1. Extract `SignatureVerification.putBack(quarantined:to:) -> PutBackResult` (occupied / moved / failed + rmdir-if-empty). Then `restoreOrRetain` (live run) and `DeleteDuplicatesJob.restoreQuarantined` (resume) both call it.
  2. Keep each caller's identity check where it is. Resume checks the recorded stamp; the live run has just stamped.
  3. Move the rename to `ExclusivePublish.renameNoClobber`.
- **Pinning before:**
  - `DeleteDuplicatesCodex1593Tests` (`releaseQuarantine` :188, `quarantineAndDelete` :104/:158), `DeleteDuplicatesCodex1619Tests`, `DeleteDuplicatesRecoveryObligationTests`, `DeleteDuplicatesTrashFailureRedTests`, `DeleteDuplicatesCodex1606Tests`.
  - **Add:** for both callers, an occupied original path leaves the file retained in quarantine, the occupant untouched (same inode), and the plan entry still stranded (`.originalPathOccupied`).
- **Risk:** this is resume/recovery, so it needs a codex pass (spend policy) bundled with R1.

### R5 — Split `DeleteDuplicatesJob.finishRun` (CCN 39, the folder's worst) · **DATA-RISK (plan filing)** · S–M
- **Steps:**
  1. Extract the two pure text builders: `completionLine(tally:plan:) -> String` (the trashed / left-alone / cross-volume / refused clauses) and `summaryParts(tally:plan:) -> [String]`. These hold most of the branches.
  2. Leave the three control branches inline, untouched and in their current order: suspend on quit/stop (keeps the plan), save failure, and stranded → never filed under done.
- **Pinning before:**
  - `DeleteDuplicatesJobTests`, `MFOLogSummaryTests`, `DeleteDuplicatesRecoveryObligationTests` (a stranded plan is never moved to done), `DeleteDuplicatesPlanTests` (`moveToDone`), `DeleteDuplicatesOfferShadowTests` (offer after stop).
  - **Add:** golden-string tests for the completion and summary lines over a tally matrix (0/1/n trashed, left-alone, refused, cross-volume on/off, held line). Capture them from today's code before the extract.
- **Risk:** low if the control flow stays put. The log wording is pinned by sensors, which is why the golden tests come first.

### Backlog (one line each)
- **B1:** remove `quarantineAndDelete`, `atomicPublish` (after R3), `bestCopy` and `isStalePartial`, and fix the stale comments at CleanupJob:395 and TrimJob:566 (F3). Retarget their tests at `holdForSingleRead`/`deleteQuarantined` and `DerivativeOutputPublish.publish`.
- **B2:** delete the stale TODO and lint suppression in RelocateProgressSheet (F6).
- **B3:** route `deleteConfirmedJunk`'s removal check through `ArchiveRemovalCheck.bulkRefusal`, keeping the per-file fresh read-only snapshot (F7). That leaves one removal-boundary helper for Junk, Delete Duplicates and Transcode.
- **B4 (DATA-RISK):** give Relocate's copy verify and its Bucket E witness the same full-content proof Delete Duplicates uses, or a stored whole-file fixity (N1007-R-F2, still open).
- **B5:** `runRelocate` (CCN 32 / 235 lines): split the reconcile-apply loop (Buckets B/D/E mutations, :350–420) from the copy loop.
- **B6:** `pruneOneCopy` (31): extract the hold or go verdict from the disk call.
- **B7:** after R3, extract the shared job skeleton (preflight → watchdog → ffmpeg → verify → promote → catalog) from `runBalance`/`runRebuild`/`runTrim`/`runCleanup`/`runTranscode` (CCN 20–30 each).
- **B8:** `MediaFileOperationKind.badgeText`/`logVerb`/`badgeColor` are three parallel 24-way switches. Use one table keyed by kind, pinned by a test that every kind has all three.
- **B9:** `DeleteDuplicatesForecast.compute` (30) and `RelocateReconcile.reconcilePlan` (25): split per bucket. Each already has a strong suite (`DeleteDuplicatesTierAndSpeedTests`, `RelocateReconcileTests`).
- **B10:** four spellings of "active row" (`pfActiveRecords`, `isLiveRelocateWitness`, `purgedAt == nil`, `!isPurged`) across MediaOps. Fold them into named predicates after R1.
- **B11:** split DeleteDuplicatesJob.swift (2,599 lines) into worker, removal boundary and resume files. Mechanical, after R4/R5.

## Callees followed
- `pfActiveRecords` (Catalog/CatalogQueries.swift)
- `ArchiveRemovalCheck` / `ArchiveVolumeProtection.verdictAtRemoval` (Archive/ArchiveVolumeProtection.swift)
- `VideoScanModel.isMasterArchive` / `isInsideMasterArchive` (Archive/, locations only)
- `PrunePlan` survivor predicates (VideoScanCore, grep only)
- `FileHasher.partialMD5` (via existing tests)
- `StewardPaneView` / `StorageReclaimableCard` (who opens the picker, grep only)

## Not covered
- Bodies of `MissingAudioFinder`, `VerifyVideoRules`, `CorrelationScorer*`, `FootageSpectrum*`, `MusicTriage`, `RescueFileCopier` (beyond N1014), `RipAllFrames`/`ExtractFrames`, and the MFO window views: offender-listed only, not read for duplication.
- Post-b83405e1 complexity of `ReformatJob.runReformat`, `deleteConfirmedJunk` and `RelocateReconcile` (they need the nightly re-measure).
- Whether Darwin `FileManager.moveItem` is atomic no-clobber (F4, Mac).
- Python `tools/`/`scripts/` (out of scope).

## Blockers & environment
- `pip install lizard` was not attempted (the brief forbids it). I used `ci/baselines/complexity_debt.json` and `origin/metrics:metrics/complexity.jsonl` as instructed. The metrics sha (4b79bbbb, 11:26Z) predates merge b83405e1, so some numbers are stale (noted in Step 0). The metrics line carries counts only for `debt_new`/`debt_worse` (ints), not their names. I diffed the baseline's git history to confirm "no new MediaOps offenders".
- The first dead-code scan (a per-name regex over every Swift file) timed out at 120 s and was stopped. I re-ran it as a single token-count pass. It flags functions whose name appears no more often than it is declared. Names that also appear in comments (e.g. `quarantineAndDelete`, `atomicPublish`) were caught by targeted grep instead.
- Wall clock: the container's `date` shows about 10 minutes from first to last command. That looks low for the number of tool calls, so treat it as the container's clock, not a measured effort.
- No build or test run was possible (Linux, no Xcode). Every pinning test named here is proposed, not executed.
