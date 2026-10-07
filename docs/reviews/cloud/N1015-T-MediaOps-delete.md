Brief: N1015-T-MediaOps-delete | Source: main@8e28c793 | Wall clock: 38 | Files read: 42
Finding count: 6 (REAL 5 / NEEDS-MAC 1 / NOISE 0)
Verdict: Most of the b83405e1 fixes have a test that goes red if the fix is reverted, but the one Relocate line that matters most has none: the apply-time witness re-proof call in `runRelocate`. Of the delete-side guards outside C04/N1011, two `deleteQuarantined` final checks and the safety-snapshot fail-safe have no isolating test.

## Scope and method

- **Step 1: did the b83405e1 fixes ship pinned?** For the merge, I diffed the in-scope production files against the first parent: `RelocateReconcile`, `+Relocate`, `+JunkDelete`, `PrunePlan`, `+DeleteScanTarget`, `+Workbench` and `VideoScanModel`. I then read the new or changed tests: `RelocateWitnessLivenessTests`, the `Relocate*` updates, `RemoteViewerReadOnlySensorTests` and `PrunePlanTests`. For each fix line I asked one question: if this line is reverted, which test goes red?
- **Step 2: the T checklist.** It covers the guards that C04 (16 guards) and N1011 (PrunePlan) did not map. Before calling a guard unpinned, I grepped `VideoScanTests/` for its symbol and for its refusal text. `VideoScanCore/Tests` holds only the PrunePlan tests.
- **Callees I followed:** `SignatureVerification.verifyHeld` / `deleteQuarantined` / `restoreOrRetain`, `DeleteDuplicatesDiskWorker.deleteQuarantined` (the final-verdict closure), `DeleteDuplicatesJob.revalidateForResume`, `DeletionTierDecision.decide` / `earnsPermanent`, `VideoScanModel.snapshotCatalogAsync`, `ViewerWriteGuard.refuse`, `StewardActionGate.deleteDuplicates`, `StewardPaneView.actions(for:)`, and `RelocateSheet`'s preview classify.
- **History:** the clone is shallow (`is-shallow-repository = true`, 1,834 commits visible), but `git log --since=2026-09-25` on MediaOps/ and Steward/ reaches back to 2026-10-03. That covers the #258 Delete Duplicates rounds, Read-only volumes, the steward trial and the 10-06 fixes.
- **Not done:** nothing was built or run. Every "goes red" claim comes from reading the assertions, not from a mutation run.

## Step 1: b83405e1 fixes → red-on-revert test

| Fix (production line) | Test that goes red if the line is reverted | Status |
|---|---|---|
| Relocate witness index skips dead rows: `if !other.isLive { continue }` (RelocateReconcile.swift, index loop) | `RelocateWitnessLivenessTests.trashedWitnessRecordIsNotASurvivingCopy`; the witness file is still on disk, so liveness is isolated | Pinned |
| `isLiveRelocateWitness`: each of its 4 clauses (purgedAt, `.trashed`, `.deletedPermanently`, `.manuallyDeleted`) | one test per clause (`trashed…`, `purgedButNotTrashed…`, `permanentlyDeleted…`, `manuallyDeleted…`), each setting only its own field | Pinned |
| Presence probe in `safelyRedundantEntry` (RelocateReconcile.swift:746) | `liveWitnessWhoseFileIsGone…`, `liveWitnessWhoseFileChangedSize…` (production `witnessIsOnDisk`) | Pinned |
| Independence probe, device rule (`witnessIsOffTheSourceDrive`) | `aWitnessOnTheSourceDriveIsNotIndependentEvenIfItIsAnotherFile`, `qaR2ProductionDefaults` | Pinned |
| Independence probe, inode rule (`witnessIsNotTheSourceFile`) | `applyTimeReproofRefusesAWitnessThatIsTheSourceFile`, the symlink and different-case tests | Pinned |
| `reproveSafelyRedundant` (the helper) | `applyTimeReproofRefusesAnEntryWhoseWitnessVanishedSinceClassify`, `reproofOrderIsStable…` | Pinned |
| **The call** `reproveSafelyRedundantBeforeApply(&reconcile, …)` in `runRelocate` (VideoScanModel+Relocate.swift:333) | **none**: every test calls the helper directly (F1) | **Unpinned** |
| Model seam wiring (`witnessIndependent: independence` into the classify) | Dropping it falls back to the stricter production rule, so the same-disk end-to-end tests (`RelocateSafelyRedundantTests`, `RelocateRetireVolumeTests`) stop classifying E and go red. `appCodeNeverWeakens…` blocks the opposite edit | Pinned (indirect) |
| Viewer refusal in `junkDeletionRefusedOnViewer`, `isReadOnly` half | `viewerModeRefusesDeleteConfirmedJunkAndLeavesTheFileOnDisk` (both modes) | Pinned |
| … the `ViewerWriteGuard` (center) half | `everyWritePathRefusesInViewerModeWithALogLine` step 9: model flag false, file still on disk | Pinned |
| … the preflight being the first statement | `everyCallerOfDeleteConfirmedJunkSitsBehindTheViewerGuard` (statement sensor, plus the caller set) | Pinned |
| `workbenchDiscardRefusedOnViewer`, `isReadOnly` half | `qaRedViewerModeRefusesDiscardWorkbenchAndLeavesTheFileOnDisk` | Pinned |
| … the center half (Workbench.swift:45) | none (F2) | **Unpinned** |
| `deleteScanTarget` viewer refusal, `isReadOnly` half | `viewerModeRefusesDeleteFromVolumesList` | Pinned |
| … the center half (DeleteScanTarget.swift:39) | none (F2) | **Unpinned** |
| `PrunePlan.Family.selection`: archive-volume copy is not a device (N1011-F1) | `PrunePlanTests.testSelectionDoesNotCountAnArchiveVolumeCopyAsAnExtraDevice` (`overrideCount == 1`) | Pinned |
| `PrunePlan.plan` rule `locked != .onArchiveVolume` (N1011-F2) | `testAnArchiveVolumeCopyHoldsNoDeviceForTheBar` | Pinned (closes N1011-F2) |
| Steward Reclaim card ↔ Delete flow drive parity (51765076, C01-F1) | `StewardNestedDriveParityTests` (outer-first and inner-first) | Pinned |

## Step 2: Guard → test (guards not mapped in C04 / N1011)

| # | Guard (production) | Test that goes red if the guard line is deleted | Status |
|---|---|---|---|
| 1 | `earnsPermanent`: the `n >= 3` clause (DeleteDuplicatesPlan.swift:580) | `DeleteDuplicatesTwoDrivesTests.theTruthTable`: `tier(2,["A","B"]) == .trash` | Pinned |
| 2 | `earnsPermanent`: `|| countsArchiveCopy` | `theTruthTable`: `tier(3,["A"],archive:true) == .permanent` | Pinned |
| 3 | Steward hand-off gate (viewer, no drive, disconnected, run already going, not offered by the flow) (`StewardActionGate.deleteDuplicates`) | `StewardCaseBuilderTests` 372-387 (exact gate values). The button only opens the shared `deleteDuplicatesFlow` with the drive preselected, so every delete rule is re-asked by the job | Pinned |
| 4 | Steward rule 2 (archive, archive drive, Read only, archive copy, Angel) | `StewardOffMainProtectionTests` (record-for-record parity, 100k), `StewardRulesTests` | Pinned |
| 5 | Removal boundary `facts.recheck()` → re-decide (DeleteDuplicatesJob.swift:453) | `DeleteDuplicatesCodex1619Tests` / `Codex1611Tests` ("evidence changed before removal", "re-checked before removal") | Pinned |
| 6 | "Prefer the Trash" read at the removal (`word?.preferTrash`) | `Codex258Round4Tests.preferTrashTurnedOnDuringPhaseTwoTrashesThePairInFlight` and `…TurnedOff…NeverUpgrades…` | Pinned |
| 7 | Hold asked at the boundary (`word?.holdNote`) | `Codex258HoldBoundaryTests.aHoldAcquiredDuringPhaseTwosReReadStopsTheRemoval`, `aReadOnlyMarkMadeDuringPhaseTwos…` | Pinned |
| 8 | Angel hold at selection, at the copy's turn, after the read, at resume | `DeleteDuplicatesAngelHoldTests`: class2/class3/class5, `aCopyTheAngelChoosesAfterPlanningIsLeftAloneAtItsTurn`, `…WhileItIsBeingReadIsPutBackNotRemoved`, `resumeLeavesAloneWhatWentIntoABatch…` | Pinned |
| 9 | Quarantine full-identity (ctime) check at the unlink (SignatureVerification.swift:710-714, `quarantineMatches`) | `DeleteDuplicatesTierAndSpeedTests.rewriteBetweenHashAndUnlinkIsRefusedAndRestored`. This is the single-read path, so no rehash masks it | Pinned |
| 10 | Read-after-move rehash compare `rehash == proof.fullHash` (:699) | none isolated (F3) | **Unpinned** |
| 11 | Keeper identity at the unlink (`keeperMatches`, :711) | none (F3) | **Unpinned** |
| 12 | `verifyHeld` keeper-stamp and content checks | `keeperStampChangeBetweenHoldAndCompareIsRefusedAndRestored`, `contentThatDiffersIsRefusedAsNotADuplicateAndRestored` | Pinned |
| 13 | Resume from a saved plan: keeper changed, gone before the crash, volume away, stranded put-back | `DeleteDuplicatesJobTests`:365 and :532, `Codex1619Tests` 401-451, `Codex1593Tests`:399, `RecoveryObligationTests` 231-273 | Pinned |
| 14 | Resume: "keeper … is not reachable — refused at resume" (DeleteDuplicatesJob.swift:1957) | No test by text. The phase-1 read refuses an unreadable keeper anyway, so a missed refusal here only moves the refusal one step later | Unpinned (defence in depth; not a finding) |
| 15 | Safety-snapshot fail-safe: working copies left alone when the snapshot cannot be written, at first run (VideoScanModel+Duplicates.swift:492-503) and at resume (DeleteDuplicatesJob.swift:1981-1990) | none (F4) | **Unpinned** |
| 16 | `JunkDeletionGuard` `authorize` / `beforeRemoval`, and a guarded file that vanished counts as refused, not "already gone" | `PruneApplyTests.theJunkDeletionGuardRefusesWithoutTouchingAnything` | Pinned |
| 17 | Junk routine: archive-volume verdict at removal | `ArchiveVolumeProtectionTests.deleteConfirmedJunkLeavesArchiveVolumeFilesOnDisk` (the `.unprovable` branch was not checked) | Pinned |
| 18 | Junk routine: offline volume skipped, not stamped | `JunkDeletionTests.skippedOfflineIsCountedSeparately` | Pinned |

## Findings

### N1015-T-MediaOps-delete-F1 — P2 — REAL — Relocate's apply-time witness re-proof is never called by any test
- **Symbol:** `VideoScanModel.runRelocate(scope:…)`, the call `reproveSafelyRedundantBeforeApply(&reconcile, proof: …)` at MediaOps/VideoScanModel+Relocate.swift:333. This is the fix line for N1007-R F1/F5's "classify can run minutes before the apply" half.
- **Why nothing goes red:**
  - Every test of the re-proof calls `reproveSafelyRedundantBeforeApply` or `reproveSafelyRedundant` directly (RelocateWitnessLivenessTests:182, :316, :327, :344).
  - The end-to-end Bucket E tests (`RelocateSafelyRedundantTests`, `RelocateRetireVolumeTests`) keep the witness on disk the whole time, so classify-time proof alone is enough to make them pass.
  - A grep of the tests for the call site, and for its log text "no safe copy is on disk now", finds nothing.
- **Regression that ships green:** in a refactor of `runRelocate`, the 6-line call is dropped, or moved above the classify. The classify-time stat still runs, so every test passes. In use:
  1. A slow source drive takes minutes to classify.
  2. Meanwhile the witness drive is unplugged, or its copy is emptied from the Trash.
  3. The source record is marked deleted ("safely redundant").
  4. The run ends with "Retire <drive>".
- **Smallest test (existing seam, no new hook):**
  1. Set up `RelocateSafelyRedundantTests`' first case end to end.
  2. Set `model.relocateWitnessIndependence = { w, s, r in try? FileManager.default.removeItem(atPath: w); return RelocateReconcile.witnessIsNotTheSourceFile(w, s, r) }`. `vouches` short-circuits `onDisk && independent`, so the probe runs after a successful classify stat and deletes the witness before the apply.
  3. Expect: the source record is not `.manuallyDeleted`, the file is copied to the destination, `pendingRetireOffer` names no witness, and the log contains "no safe copy is on disk now".

### N1015-T-MediaOps-delete-F2 — P3 — REAL — The ViewerModeCenter half of two new viewer guards is unpinned
- **Symbols:**
  - `VideoScanModel.workbenchDiscardRefusedOnViewer`, Catalog/VideoScanModel+Workbench.swift:45
  - `VideoScanModel.deleteScanTarget`, Volumes/VideoScanModel+DeleteScanTarget.swift:39
- **What the tests cover:** both guards are documented as "either signal refuses on its own". Their tests (`qaRedViewerModeRefusesDiscardWorkbench…`, `viewerModeRefusesDeleteFromVolumesList`) set only `model.isReadOnly = true`. Neither path appears in `everyWritePathRefusesInViewerModeWithALogLine`, which is the only test that installs the center with the flag false. (`deleteConfirmedJunk` does appear there, as step 9.) The `removalSites` sensor checks only that the token `workbenchDiscardRefusedOnViewer(` exists in the file.
- **Regression that ships green:** `let viewer = ViewerWriteGuard.refuse(…)` is replaced by `false`, or the `ViewerWriteGuard.refuse(…) ||` term is dropped. A viewer whose model flag has not been set yet (launch order, or a model built outside VideoScanApp) then trashes workbench files or rewrites the master's scan-target list.
- **Why P3:** in production both signals are set from the same role, so one alone is belt and braces.
- **Smallest test:** add two steps to the serialized step 9 block: `discardWorkbench([rec], trash:)` and `deleteScanTarget(target)` on a model with `isReadOnly == false`. Expect `n == 0`, nothing trashed, the list unchanged, and `sink.has("… VideoScanModel.discardWorkbench — …")` / `"… deleteScanTarget — …"`.

### N1015-T-MediaOps-delete-F3 — P3 — REAL — Two of `deleteQuarantined`'s final checks have no isolating test
- **Symbol:** `SignatureVerification.deleteQuarantined`, MediaOps/SignatureVerification.swift:699 (the read-after-move `rehash == proof.fullHash`) and :711 (`keeperMatches`).
- **The rehash:**
  - The two tests where it could fire are `Codex1593Tests.rewriteThroughOpenDescriptorAfterQuarantine…` and `ticketBaselineIncludesCtimeAndTheUnlinkStepRehashes`. Both write through a descriptor after the baseline, which also moves the ctime, so the identity check at :714 refuses either way.
  - Both assert only `.refused(.changedSinceVerification)`. `restoreOrRetain` returns that same value whatever the reason (:874), so the tests cannot tell which check fired.
  - The happy path's `blocks("quarantine") == 1` pins that the bytes are read, not that they are compared.
- **`keeperMatches`:** no test replaces or rewrites the keeper between the ticket and the unlink. The grep for "keeper changed after verification" in the tests finds nothing. `SignatureConcurrencyScaleTests` 255-290 covers `revalidate`, which runs before the move, not this check.
- **Regression that ships green:** someone keeps the second full read but drops its compare as a "perf" cleanup (it is the most expensive line in the step), or narrows the `guard` to `quarantineMatches, !originalOccupied`. Then:
  - A write in the window between `revalidate` and the rename is not caught. The ctime baseline is taken after the rename and the move check ignores ctime.
  - A keeper replaced after the ticket no longer stops the unlink. In the job, the boundary `facts.recheck()` may still drop the keeper when it is a counted copy. The SignatureVerification-level guard itself has no red test.
- **Smallest tests:**
  - (a) Take a real ticket from `verify` + `quarantine`. Rebuild it with a `VerifiedDuplicate` whose `fullHash` is altered, keeping baseline and identities unchanged. Call `deleteQuarantined`. Expect `.refused`, with the file back at its original path.
  - (b) Take a real ticket, then `AtomicFilePublish.publish` a same-bytes replacement over the keeper (new inode), then `deleteQuarantined`. Expect `.refused` and the duplicate restored.

### N1015-T-MediaOps-delete-F4 — P3 — REAL — The "no safety snapshot → working copies left alone" fail-safe has no test, at first run or at resume
- **Symbols:**
  - first run: the `else` branch at MediaOps/VideoScanModel+Duplicates.swift:492-503
  - resume: `DeleteDuplicatesJob.revalidateForResume`, MediaOps/DeleteDuplicatesJob.swift:1981-1990
- **Why nothing goes red:** the grep of the tests for "safety snapshot could not be written", "could not be retaken" and "no safety snapshot" finds nothing. `DeleteDuplicatesPlanTests` 131-135 pins only `snapshotIsStale`, and `DeleteDuplicatesJobTests`:446 only the success line "Safety snapshot retaken at resume".
- **Regression that ships green:** in either branch the refusal loop is dropped, or changes `.refused` to `.pending`. A cross-volume run whose snapshot write fails (full disk, permissions) then removes working copies with no catalog snapshot to roll back to. The rows say nothing.
- **Why P3:** the files themselves are still covered by the tier rules. What is lost is the catalog's recovery point.
- **Smallest test:**
  - Point `model.catalogStore` at a directory made read-only (`chmod 0555`) after the plan is saved, so `writeSnapshotAsync` fails. Run a cross-volume plan with one working-copy row and one same-drive row.
  - Expect the working-copy row `.refused` with "safety snapshot could not be retaken — working copy left alone" (resume) or skipped with "safety snapshot could not be written" (first run), and its file on disk.
  - `snapshotCatalogAsync` already returns nil on the test host for the shared store (ScanMerge.swift:823). Use that only if the store is isolated.

### N1015-T-MediaOps-delete-F5 — P3 — NEEDS-MAC — The process-wide viewer window now refuses every Trash-routine call in suites running alongside it
- **Symbol:** `RemoteViewerReadOnlySensorTests.everyWritePathRefusesInViewerModeWithALogLine` installs `ViewerModeCenter.shared` as a viewer (`@Suite(.serialized)` serializes only within that suite). Since 49e2283d, `deleteConfirmedJunk` consults that center first (`junkDeletionRefusedOnViewer`).
- **Effect:** while the window is open, any `deleteConfirmedJunk` call in a suite running in parallel gets `refused` and moves nothing. That includes `JunkDeletionTests`, `PruneApplyTests`, `CatalogTrashShortcutTests` and `ReadOnlyVolume*`.
  - The test's own comment admits the hazard: "a second window here could make delete tests in parallel suites refuse".
  - The dev scheme `VideoScan.xcscheme` marks the test target `parallelizable = "YES"`. `VideoScan-CI.xctestplan` says false.
- **Why this is an isolation gap, not a green regression:** it causes intermittent false reds on ⌘U. A false red trains people to rerun, and a rerun hides a real red on the delete paths.
- **Why NEEDS-MAC:** whether Swift Testing suites interleave under the dev scheme on the M4 is for the Mac to confirm.
- **Smallest fix to test:** give `ViewerWriteGuard.refuse` a `@TaskLocal` center override used by the sensor, and drop the process-wide `install`. Or tag every suite that calls a guarded delete with a shared `.serialized` parent. Then add a poisoned-state test: open a viewer window in one task and run a `deleteConfirmedJunk` concurrently on a master model. Expect `succeeded == 1`.

### N1015-T-MediaOps-delete-F6 — P3 — REAL — Relocate Bucket E now stats witnesses during classify, with no scale budget or call-count sensor
- **Symbol:** `RelocateReconcile.safelyRedundantEntry`, MediaOps/RelocateReconcile.swift:729-760. Its callers are `reconcilePlan`, run by `runRelocate` and by RelocateSheet's preview.
- **What changed (feature of 2026-10-06):**
  - For every candidate with a witness key, each host-safe witness now costs a `stat` (`witnessIsOnDisk`). `witnessIsOffTheSourceDrive` adds up to three more.
  - The loop is not capped at `maxWitnessSample`: only the stored lists are.
  - The witness list is built from the whole catalog (`records.map(\.asReconcileInput)`).
- **What tests cover:** no `reconcilePlan` test runs above a handful of records. `RelocateIntegrationTests` has only a suite time limit, and the 100k tests in scope are all Steward, Read-only or Delete Duplicates. Media-matrix does not apply here: the checks are byte- and stat-level and format-agnostic.
- **Regression that ships green:** the "host safety first (cheap), then one stat per safe witness" order is reversed, or the `w.isSafe &&` short-circuit is dropped. A Relocate on a 100k catalog then stats every witness on retired, unreliable and offline network drives, and each stat can block for seconds. The classify heartbeat still ticks and every test stays green.
- **Smallest test:**
  - 100k synthetic witness inputs across 5 fake roots, 1k scope records sharing keys with about 30 witnesses each, a third of them on a retired-host resolver.
  - Inject a counting `witnessOnDisk` and `witnessIndependent`.
  - Assert the probe is never called for a non-safe witness, and calls ≤ safe witnesses of E candidates.
  - Assert `reconcilePlan` finishes within an explicit budget (e.g. `.timeLimit(.minutes(1))` plus a measured `ContinuousClock` bound).

## Vacuous-test sweep (item 2)

- **New tests in b83405e1 (in scope):** I found no `try?`-swallowed assertion, silent early return, empty-loop `allSatisfy` or comment-matching sensor.
  - `qaRedSourceFileSpelledWithDifferentCase…` uses `try #require` on the case-insensitive precondition, so on a case-sensitive volume it fails loudly rather than passing.
  - `appCodeNeverWeakens…` and the `removalSites` count are absence/equality sensors: a comment can only make them go red, never green.
- **The one masking pattern found:** F3. Two checks report the same refusal value, so the tests that would reach either check cannot tell them apart.
- **Noise worth a tidy-up (not a finding):** `RelocateRetireVolumeTests` sets `relocateWitnessIndependence` in six tests that never relocate (`retire_skipDoesNothing`, `reinstate_*`, etc.). Harmless, but it reads as if they depended on it.

## Observations (not findings)

- **Retire offer:** N1007-R F1's fix direction asked for a re-proof "again before the retire offer". `RelocateRetireSheet` / `retireVolume(at:reason:witnesses:)` still only store the witness list; the grep for `WitnessProof`/`witnessIsOnDisk` outside RelocateReconcile.swift hits only the apply call. The window is now short (apply → click), so I did not raise it as a T finding. It is a candidate for the next R/H row on Relocate.
- **C04 findings still open in main:** F1 (Migrate start-time overlap) is still only the substring sensor. F4 (the viewer Delete Duplicates test without `addVerifiedArchiveFamily`) is unchanged at DeleteDuplicatesSafetyTests.swift:223. I did not count them again here.

## Not covered

- `PruneApplyJob` pause/stop/queue internals beyond C04 #15 and the JOB/QUEUE test names. `+PruneVerification` read paths.
- The junk routine's archive-volume `.unprovable` branch: I did not confirm whether it has a test.
- `RelocateEngine` (C04-F3 and N1007-F2/F3 already cover its copy/verify) and `RelocateQueue`.
- Steward Events / Footage lanes: they propose nothing to delete, so they are outside this row's delete theme.
- `DeleteDuplicatesForecast`, `DeleteDuplicatesSiblingProof` internals: covered by name in C04 #11, not re-read.
- No mutation runs (Linux, no Xcode). The M4 should confirm the "Pinned" rows by deleting each line named.

## Blockers & environment

- No Xcode or Swift toolchain on this Linux runner, so nothing was built and no test was run. All pin claims come from reading the code.
- The clone is shallow. `git log --since=2026-09-25` still reached 2026-10-03, which was enough for the five-dimension pass.
- Per this row's brief I did not commit or push (it overrides the standing rule 3 branch push). The report sits only in the working tree at `docs/reviews/cloud/N1015-T-MediaOps-delete.md`.
