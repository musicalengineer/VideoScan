# Codex review — Delete-safety bundle #258

- Range: `8aa4acde..fix/258-delete-planner-honours-angel`
- Credits spent: unavailable
- Tokens: 107924
- Finding count: 11
- Verdict: block — the branch can unlink a copy that baseline would Trash, and held/read-only files remain removable in several cases.
- Run: 2026-10-03T20:02:27Z (cycle #34, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 11
Verdict: block — the branch can unlink a copy that baseline would Trash, and held/read-only files remain removable in several cases.

Reviewed `8aa4acde..4c616916` using Git and the clean branch worktree. Main was not checked out or changed. These are source-derived reproductions; this read-only session could not execute Swift red tests. Credit metering is unavailable.

1. **P1 — Holding an extra can upgrade another copy from Trash to permanent deletion.** [VideoScanModel+Duplicates.swift:1021](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/VideoScanModel+Duplicates.swift:1021), [DeleteDuplicatesJob.swift:916](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:916).

   Reproduction: records ordered `K,A,H,R`, with identical bytes and distinct inodes. `K` is keeper; `A,H` are extras on drive A; `R` is a verified ordinary sibling on drive B. `H` is Angel-prepared; Prefer Trash is off; no archive.

   | Same input | Survivors counted for A | Result |
   |---|---|---|
   | Baseline | K + R; pending H excluded | Trash |
   | Branch | K + H + R; H omitted from plan | Permanent unlink |

   This directly violates invariant 1. Without R, the branch Trashes A where baseline leaves A alone. The hold test’s control changes H to `.review`, so it does not compare identical baseline input.

2. **P1 — Marking an external drive through an alias leaves its canonical path removable.** [ReadOnlyVolumeProtection.swift:357](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/Archive/ReadOnlyVolumeProtection.swift:357).

   Reproduction: a scan target `/Users/test/test_media` symlinks to `/Volumes/TestMarked`. Mark the alias Read only, then permanently delete junk through a second target using `/Volumes/TestMarked`. Classification uses `/Volumes/` spelling, stores no UUID, and protects only the alias. Even a completed snapshot permits deletion through the canonical path. Custom external mount points have the same problem.

3. **P1 — Import can replace an existing mark’s drive identity.** [ScanTargetPersistence.swift:312](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/Volumes/ScanTargetPersistence.swift:312).

   Reproduction: local `/Volumes/TestMarked` has mark UUID `TEST-U`. Import a snapshot carrying `readOnlyMarkedAt` and UUID nil or `TEST-V`. The assignment replaces `TEST-U`. Remount the original drive at `/Volumes/TestRenamed`: its files become removable although the mark remains visibly set. Imports lacking both fields preserve the mark correctly; contradictory imports do not preserve its protection.

4. **P1 — An external-folder mark fails during a rename/remount before rebuilding finishes.** [ReadOnlyVolumeProtection.swift:188](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/Archive/ReadOnlyVolumeProtection.swift:188).

   Reproduction: mark `/Volumes/TestMarked/Clips`, UUID `TEST-U`; remount at `/Volumes/TestRenamed`; delete `/Volumes/TestRenamed/Clips/test_copy.mov` using a provisional snapshot. Old-path matching misses it, and removal-time UUID matching excludes every entry with a nonempty `subpath`. A completed rebuild protects this supported folder target; the interim check does not.

5. **P1 — Setting Read only during Junk Delete does not protect later files.** [VideoScanModel+JunkDelete.swift:291](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:291).

   Reproduction: start permanent deletion of two files on an unmarked target. Pause the first removal through `JunkDeletionGuard.remove`; mark the target Read only on the main actor; release the operation. The second file is removed using the captured `.none` snapshot. Move to Trash delegates to this same loop.

6. **P1 — Angel holds acquired during phase two are not checked at the actual removal boundary.** [DeleteDuplicatesJob.swift:1201](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:1201), [final verdict:355](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:355).

   Reproduction: use a keeper without usable stored fixity, causing phase two to reread the quarantined duplicate. Block that reread with `didReadBlock`; register an active explicit Prepare holding this record; confirm the live hold; release the read. The worker still removes the file. The main-actor hold check precedes that potentially lengthy reread; the final verdict checks archive protection and survivor stamps only.

7. **P1 — Completing Prepare can release its hold before the prepared-batch hold is published.** [ArchiveAngelJob.swift:160](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelJob.swift:160), [ArchiveAngel.swift:511](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/ArchiveAngel/Facade/ArchiveAngel.swift:511).

   Reproduction: Delete plans against an empty buffer. Prepare subsequently creates a ready batch for a pending extra and finishes while the Archive tab remains closed. The running hold disappears at completion, but the cached disk/prepared sets remain empty. Delete authorizes removal of the prepared source.

   A deterministic fixture can save the ready batch after planning, without refreshing the façade: authorization returns `.authorized` despite the disk reader finding its ID. Overlapping disk refreshes can also publish an older empty result because this refresh has no generation guard.

8. **P1 — Mixed UUID/device keys can count one volume twice.** [DeleteDuplicatesPlan.swift:231](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:231).

   Reproduction: three verified survivors on one volume, sharing `st_dev`. The keeper’s gather-time capture returns UUID nil; sibling captures return UUID `TEST-U`. Gather records both `dev:D` and `uuid:TEST-U`, producing two drives and permanent deletion. The keeper capture has no UUID/fixity eligibility guard equivalent to the siblings’.

   A synthetic gather test can use the existing volume resolver seam to withhold only the keeper’s UUID; expected count is three copies, **one drive**, Trash. Current key construction produces two drives.

9. **P1 — A disk image on the survivor drive satisfies “two drives” without independent storage.** [DeleteDuplicatesPlan.swift:232](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:232).

   Reproduction: keeper and sibling on drive A; third verified sibling inside a mounted test disk image whose backing file is also on A. The image has another volume identity, so the duplicate earns permanent deletion although one backing-drive failure loses every survivor. This follows the logical-volume definition, but is an additional physical-independence limitation beyond the explicitly accepted APFS-container case.

10. **P2 — Forecast invents a second drive from path spelling.** [DeleteDuplicatesForecast.swift:419](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesForecast.swift:419).

    Reproduction: keeper and two distinct verified siblings reside on `/Volumes/TestDrive`; one sibling is cataloged through a symlink beneath `/Users/test`. Forecast assigns `"boot"` to that sibling and predicts permanent deletion. Run gathers one volume UUID and chooses Trash. Conversely, separate volumes mounted outside `/Volumes` collapse to `"boot"`.

11. **P2 — Count-only read limits deny an attainable permanent tier.** [DeleteDuplicatesSiblingProof.swift:123](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesSiblingProof.swift:123).

    Reproduction: keeper plus two verified siblings on A; one identical but unverified sibling on B. Count already equals three, so B is never read. The run Trashes the duplicate although proving B would earn permanent deletion. This denies cleanup; it does not weaken safety. The corresponding stops in `prove`, forecast, and job drive reservation must also change.

    Minimal red assertion, not executed:

    ```swift
    #expect(SiblingProver.worthReading(
        count: 3, drives: ["A"], countsArchiveCopy: false,
        candidateDrive: "B", goal: 3))
    // Current result: false.
    ```

| Invariant | Verdict |
|---|---|
| **1. No weakening** | **Finding 1.** For identical facts, the tier is stricter; selection changes those facts. |
| **2. Two drives** | **Findings 8–9.** Hard-link exclusion and missing-stat conservatism hold. Boundary recheck drops lost copies’ drives and re-decides the tier. Scoped production calls use the default `driveOf`. |
| **3. Holds** | **Findings 6–7.** Selection, ordinary turn authorization and resume otherwise check holds; caught holds are skips, not Review. |
| **4. Read-only totality** | **Findings 2–5.** Ordinary unmounted-path, different-drive-name, `..`, firmlink and nested-prefix protection hold. Old decoding and imports without mark fields hold. |
| **5. Forecast / Steward equality** | **Finding 10.** Full Steward proof cannot be certified: `StewardEvidence.swift` is outside scope. |
| **6. Sibling reads** | **Finding 11.** The existing count-three assertion pins the incorrect denial. |
| **7. Ledger / logs** | **Holds.** Final reasons name counted survivors and drive count; boundary decisions replace earlier reasons. No changed log paths/formats or new personal/path exposure beyond existing row conventions found. |
| **8. Concurrency** | **Holds for actor isolation and off-main listing.** No new memory race or deadlock found. Finding 7 concerns cache freshness. |

The launch reader calls `inFlightRecordIDs`, without settling or rewriting in the scoped wrapper. The inspected fingerprint test pins unchanged buffer contents for its covered states; the underlying store implementation was outside scope.

Removal inventory: Junk Delete’s unlink/Trash operations and injected removal callback follow the gate; Trash Selection delegates there. Duplicate quarantine/removal delegates to `SignatureVerification` with the removal check. Recovery moves files back without the bulk gate. Angel Prepare removes generated buffer companions without that gate; plan archival moves metadata directories only. Referenced outside-scope paths include `SignatureVerification`, `ArchiveAngelPlanStore`, `JunkDeleteAction.swift`, Prune Apply, Workbench Discard, `TranscodeJob.swift`, and `ArchiveRefile.swift`; their implementations were not explored.

**Read, no findings in reviewed changes:** `DeleteDuplicatesDetailView.swift`, `DeleteDuplicatesFlow.swift`, `DeleteDuplicatesVolumePicker.swift`, `DuplicateKeeperPolicy.swift`, `ArchiveVolumeProtection.swift`, `VideoScanModel+ArchiveVolumeSnapshot.swift`, `VideoScanModel+MasterArchive.swift`, `VideoScanModel+TrashSelection.swift`, `VideoScanModel+ScanTargetPersistence.swift`, `CatalogScanTarget.swift`, `VideoScanModel.swift`, `BundleModels.swift`, `AngelSeams.swift`, `AppConformances.swift`, and `docs/practices/invariants/MediaOps.md`.

**Tests read, no findings:** `ReadOnlyVolumeTests.swift`, `ArchiveAngelExtraCopyGuardTests.swift`, `DeletionTierRuleTests` within `DeleteDuplicatesTierAndSpeedTests.swift`, `DeleteDuplicatesSiblingProofTests.swift`, `DuplicateKeeperCarryOverTests.swift`, and `FixityStampVolumeIdentityTests.swift`. `DeleteDuplicatesAngelHoldTests.swift` supports finding 1’s changed behavior but misses identical-baseline comparison; `DeleteDuplicatesTwoDrivesTests.swift` pins finding 11’s incorrect read denial.

## Brief

Scoped data-risk pass — delete-safety bundle (GH #258 + Read-only volumes + two-drives rule), 2026-10-03. Range 8aa4acde..fix/258-delete-planner-honours-angel (tip 4c616916). The branch is NOT checked out in ~/dev/VideoScan (main stays on main for the 2 AM nightly): read it with `git diff 8aa4acde..fix/258-delete-planner-honours-angel -- <path>`, `git show fix/258-delete-planner-honours-angel:<path>`, or the worktree at .claude/worktrees/agent-ace49c157d541ff27. Do not check out the branch in ~/dev/VideoScan. Do not explore outside the files below.

What the bundle changes (three rules, one path — what Delete Duplicates and the other bulk remove verbs may take):
A. HOLDS — Delete Duplicates leaves alone a copy that is IN USE by the Archive Angel (in a prepared batch, in a batch being/just promoted, in a batch on disk, or picked for a Prepare still running) and a promoted archive copy when no Master Archive is designated. NOT held (deliberately): copies the Angel merely lists as candidates, and copies whose lifecycleStage is .archived (that label follows the keeper — DuplicateKeeperCarryOver).
B. TWO DRIVES — a copy is deleted OUTRIGHT only when ≥ 3 verified copies remain AND they sit on ≥ 2 different drives, or a verified archive copy is among the COUNTED copies; otherwise (≥ 2) it goes to the Trash; < 2 left alone. "Drive" = the fixity stamp's volumeUUID, else st_dev.
C. READ-ONLY VOLUMES — a user-set per-volume mark (UserDefaults, additive) that every bulk verb which removes files honours through the one gate `bulkDeleteRefusal`; the Master Archive volume is read-only by rule (unchanged). A read-only volume's copies STILL COUNT as surviving copies for other drives' cleanup.

Files in scope:
- VideoScan/VideoScan/MediaOps/VideoScanModel+Duplicates.swift — duplicateDeletionHoldRule (~308), duplicateDeletionSelection, authorizeDuplicateDeletion, volumesWithDeletableDuplicates, deletionTierCandidates
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift — DeletionTierFacts (gather, driveKey, distinctDriveCount, countedDrives, countsArchiveCopy), DeletionTierDecision (minimumDrivesForPermanent, earnsPermanent, decide, ruleSentence), plan additive fields (leftAloneCopies, leftAloneAtPlan)
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift — runPair removal-boundary re-check (~1201), authorize at each copy's turn, revalidateForResume
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesSiblingProof.swift — SiblingProver.worthReading, Allowance.goal
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesForecast.swift — buckets via earnsPermanent / worthReading (must equal the run)
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesDetailView.swift, DeleteDuplicatesFlow.swift, DeleteDuplicatesVolumePicker.swift, DuplicateKeeperPolicy.swift — wording / disabled states only
- VideoScan/VideoScan/Archive/ReadOnlyVolumeProtection.swift (new), ArchiveVolumeProtection.swift, VideoScanModel+ArchiveVolumeSnapshot.swift, VideoScanModel+MasterArchive.swift — bulkDeleteRefusal(forPath:) (~734), readOnlyVolumeRefusal (~763), the two new refusals
- VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift, VideoScanModel+TrashSelection.swift — gate calls
- VideoScan/VideoScan/Volumes/ScanTargetPersistence.swift, VideoScanModel+ScanTargetPersistence.swift, ModelsUI/CatalogScanTarget.swift, Model/VideoScanModel.swift (~987), App/BundleModels.swift — where the mark is stored / imported
- VideoScan/VideoScan/ArchiveAngel/Facade/ArchiveAngel.swift (refreshRecordIDsInBatchesOnDisk ~511, recordIDsInRunningPrepare), Prepare/ArchiveAngelJob.swift (heldRecordIDs), Seams/AngelSeams.swift, Seams/AppConformances.swift
- docs/practices/invariants/MediaOps.md (MOPS-2)
- Tests: VideoScanTests/DeleteDuplicatesAngelHoldTests.swift, DeleteDuplicatesTwoDrivesTests.swift, ReadOnlyVolumeTests.swift, ArchiveAngelExtraCopyGuardTests.swift, and the edited DeletionTierRuleTests / DeleteDuplicatesTierAndSpeedTests / DeleteDuplicatesSiblingProofTests / DuplicateKeeperCarryOverTests / FixityStampVolumeIdentityTests

Invariants to attack, in priority order — answer each "holds" or a finding (file:line + a concrete reproduction, ideally a Swift Testing red test with synthetic data):
1. NO WEAKENING. Find any input for which this branch removes (unlinks OR trashes) a file that main @ 8aa4acde would have left alone or refused, or deletes OUTRIGHT a file main would have Trashed. In particular: the held/read-only copies must never be counted as verified survivors for ANOTHER copy beyond what main's sibling rules already allow; `countsArchiveCopy` vs the old `hasVerifiedArchive`; facts "built without a stat count as one drive" — can a missing stat ever raise the drive count; the `driveOf` test seam must not be reachable in production.
2. TWO DRIVES is real. Can `distinctDriveCount` be ≥ 2 while every counted copy is on ONE physical volume: the same volume mounted or spelled two ways, a firmlink/symlinked path, a hard link, case variants, a disk image or sparsebundle stored ON the same drive, an SMB share of the same disk, volumeUUID nil on one copy and st_dev on another for the same volume (mixed keys counted twice?), a stale stored volumeUUID after a drive was reformatted or its fixity re-bound. Removal-boundary: a counted copy that disappears between gather and unlink drops its drive with it — confirm the tier is re-decided, not just the count.
3. HOLDS are applied at BOTH selection and delete time, and on resume. A copy that enters a batch after planning; a batch that finishes mid-run (hold released — is the copy then correctly an ordinary skip rather than removed without re-verification); `recordIDsInBatchesOnDisk` read at launch must only list/decode (no settle, no folder removal, no rewrite) — confirm; staleness of that set between refreshes (a batch created by another route); a held copy is a skip not a Review mark.
4. READ-ONLY is total for remove verbs. Enumerate every code path in the scoped files (and name any OUTSIDE scope you can see referenced) that unlinks, trashes, moves-out or replaces a media file and does not pass through `bulkDeleteRefusal`. Identity: the marked path refused by string when unmounted; the UUID follows the drive under another mount name; a different drive under the marked name is refused, not inherited — any way to make a marked drive's files removable (rename the volume, remount at another path, path with `..`, symlink into it, a second scan target nested inside or above the marked one, a folder target on the boot disk, a damaged saved entry, an imported bundle that lacks or contradicts the mark)? Persisted mark: additive and old settings decode; "an import never clears a mark" — confirm.
5. FORECAST == RUN and STEWARD PROOF == RUN under rules A–C for the same fixture (the forecast file was changed minimally; show any case where the forecast promises delete/trash and the run does otherwise, or vice versa).
6. Sibling reads: `worthReading` never skips a read that could have lifted a copy to a tier it is entitled to; never reads when it cannot change the outcome (wasted I/O is a P3, a wrongly-denied tier is not a safety issue but report it).
7. Ledger + logs: the ledger row's `detail.reason` still names the counted copies (now with drives); no log format or path changed; no person names or full media paths added beyond the existing per-row convention.
8. Concurrency: the Angel accessors read from the delete job (main actor vs disk worker) — any data race, main-thread blocking (the at-launch batch listing is off-main?), or deadlock between the Angel's batch refresh and a running delete.

Known and accepted (do not report): two APFS volumes in one container count as two drives (documented MOPS-2); the Angel's `extraCopy` exclusion is a switchable policy default pinned by a guard test, not a floor; Catalog Rename and add-a-file verbs (Trim/Balance/Rebuild/Reformat) are not blocked on a read-only drive in this change (ruling pending); "Archived — what next?" wording for marked drives; Prune Apply and Transcode Replace are covered by gate + sensor tests only; the gauntlet manifest is not regenerated; SwiftLint length warnings.

Evidence already run (Debug, by suite, counts confirmed nonzero), on the merged tree (main 8aa4acde merged in): 865 Swift Testing tests / 162 suites + 13 XCTest, 0 failures — all DeleteDuplicates*, ArchiveVolumeProtection*, Steward*, AnalyzeReclaimable*, TriageSnapshot*, every *Sensor*/*Boundary* suite. Two-drives rule: red end to end on the old rule first, then 7 mutants red. Reshaped holds: 8 mutants red (no pre-change red run — tests need the new API). Read-only: 14 mutants red; poisoned-state behavioural tests for Delete Duplicates, Move to Trash, Junk Delete (both modes), Discard. Survival pinned: a copy on a read-only drive still counts. 100k records: selection 0.55 s, menu count 1.14 s (2 s budget). `DuplicateKeeperCarryOverTests` restored to main's expectation.

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>

Wanted: findings ranked by data-loss risk; "holds" per invariant; "read, no findings" per clean file. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.

## Findings closed (branch `fix/258-delete-planner-honours-angel`, 2026-10-03)

Each finding is closed against a pinning test that was RED before its fix (on `4c616916`; F7c, F9 and F10 on `4c616916` plus a behaviour-neutral test seam) and red again when the fix is un-done (36 mutants, all red). Nothing declined.

| # | Fix | Pinning test (suite · test) |
|---|---|---|
| F1 | ONE survivor rule, `duplicateSurvivorStandingRule(in:)` (VideoScanModel+Duplicates.swift): a row still to be decided, a row the run left alone for a hold or a Read-only mark, and an extra copy on the cleaned drive that is not a row of the run are never counted; the job, the forecast and the steward's proof all ask it | DeleteDuplicatesCodex258SurvivorTests · `holdingACopyNeverMakesAnotherCopysFateMorePermissive` (identical inputs, hold on vs off, 4 fixtures × 3 holds), `aCopyTheRunLeavesAloneIsNotASurvivorForAnotherCopy`, `withASiblingOnASecondDriveTheHeldCopyNeverEarnsTheOutrightDelete` (K,A,H,R), `theSurvivorRuleMemberByMember`, `theStewardsProofEqualsTheRunForTheHeldCopyAndTwoDriveFixtures` |
| F2 | the mark resolves its path (realpath) and mount when made and keeps the real volume's UUID; protected by the spelled path, the real path, and the drive wherever it mounts (ReadOnlyVolumeProtection.swift) | ReadOnlyVolumeCodex258Tests · `aMarkMadeThroughAnAliasProtectsTheDriveItself`, `aMarkOnACustomMountPointKeepsTheDrivesIdentity` |
| F3 | an import may add a mark, never alter or clear one (ScanTargetPersistence.applyVolumeSnapshot) | ReadOnlyVolumeCodex258Tests · `anImportNeverChangesAnExistingMarksDriveIdentity` |
| F4 | removal-time check: UUID + the file's place on its own volume, for folder marks too | ReadOnlyVolumeCodex258Tests · `aMarkedFolderIsFoundByIdentityAtRemovalBeforeTheRebuildLands` |
| F5 | the marks are read again for every file of a Junk Delete / Move to Trash batch | ReadOnlyVolumeCodex258Tests · `markingADriveReadOnlyMidRunProtectsTheFilesNotYetRemoved` |
| F6 | the final verdict asks the holds (the buffer on disk, then the model's live word: hold rule + Read-only marks) immediately before the removal | DeleteDuplicatesCodex258HoldBoundaryTests · `aHoldAcquiredDuringPhaseTwosReReadStopsTheRemoval`, `aReadOnlyMarkMadeDuringPhaseTwosReReadStopsTheRemoval` |
| F7 | hand-over at a Prepare's end; the buffer read from disk at every copy's turn; numbered readings (an older one never overwrites a newer) | DeleteDuplicatesCodex258HoldBoundaryTests · `aFinishedPrepareKeepsItsRecordsHeldUntilTheBufferHasBeenReRead`, `aBatchSavedAfterPlanningIsSeenAtTheCopysTurn`, `anOlderReadingOfTheBufferNeverOverwritesANewerOne`, `onlyAReadingBegunAfterThePrepareEndedCompletesTheHandOver` |
| F8 | one key per mounted volume (DeleteDuplicatesDrives.swift) | DeleteDuplicatesCodex258DrivesTests · `oneVolumeKeyedTwoWaysIsOneDrive` |
| F9 | a disk image or an unidentified volume never adds a drive (DiskArbitration, behind `DuplicateDrives.identityOverride`) | DeleteDuplicatesCodex258DrivesTests · `aDiskImageOrAnUnidentifiedVolumeNeverAddsADrive`, `whatTheSystemSaysAboutTheDeviceDecidesTheKind` |
| F10 | the forecast asks the run's resolver (one stat per folder) | DeleteDuplicatesCodex258DrivesTests · `theForecastCountsDrivesAsTheRunDoes` |
| A (after the review) | a drive is a PHYSICAL device: the key is DiskArbitration's device path of the volume's device node, so two volumes of one device (FamilyArchive and Projects on one RAID, two APFS volumes of one container) are one drive; the reason names the devices; MOPS-2 updated — this closes the "two APFS volumes in one container" limit the brief listed as accepted (DeleteDuplicatesDrives.swift) | DeleteDuplicatesPhysicalDriveTests · `twoVolumesOfOnePhysicalDeviceAreOneDrive`, `theForecastAndTheStewardCountPhysicalDevicesAsTheRunDoes`, `aSiblingOnAnotherVolumeOfTheSameDeviceIsNotReadToEarnTheOutrightDelete`, `theKeyIsThePhysicalDevicePath`, `theReasonNamesThePhysicalDevicesAndTheirVolumes` |
| B (after the review) | the F5 class for the other bulk verbs: Workbench Discard now asks the removal-time check for each file before the Trash; Junk Delete's sheet, Prune Apply and Transcode's Replace Existing were found to ask there already and are pinned | BulkVerbRemovalBoundaryTests · `discardAsksTheFilesOwnVolumeBeforeItTrashesIt`, `transcodeReplaceAsksAtThePublish`, `everyBulkVerbAsksTheGateWhereTheFileGoes`; PruneApplyTests · `aReadOnlyMarkMadeAfterTheVerdictHoldsTheCopy` |
| R2-1 (round 2; F1 reopened) | one classification, `BulkDeleteRefusal.leavesAlone`: a Read-only refusal found on the disk thread (the worker's physical check, phase two's captured check) settles as a hold skip — never Review, never counted for another copy; older plans' refused rows classify the same way | DeleteDuplicatesCodex258Round2Tests · `aReadOnlyRefusalFoundOnTheDiskThreadIsAHoldAndIsNeverCountedForAnotherCopy`, `aReadOnlyRefusalClassifiesAsAHoldWhereverItWasFound`; Round3Tests · `phaseTwosCapturedCheckHoldsAReadOnlyFileInsteadOfRefusingIt` |
| R2-2 (round 2; F6 reopened) | the removal boundary takes today's Read-only marks and runs the removal-time identity check on the disk thread | Round2Tests · `aLateIdentityMarkStopsTheRemovalBoundary` |
| R2-3 (round 2) → R3-1 (round 3) | AT THE FINAL VERDICT NOTHING COMES FROM A CACHE (MOPS-2): `recheck` always asks each counted copy's physical device through `Resolver(fresh: true)` / `liveIdentityFresh` and re-decides; the cache (key st_dev + node + volume UUID, with a generation) serves only advisory uses | Round3Tests · `theFinalVerdictAsksTheDrivesAfreshBeforeAnyNotification`, `theFinalVerdictCallsOnlyTheFreshEntryPoints`; Round2Tests · `driveEvidenceGatheredBeforeAMountChangeDoesNotSurviveIt`, `theProductionCacheKeyNamesTheNodeAndTheVolume` |
| R2-4 (round 2; F10 reopened) | the forecast stats the file itself, as the run does | Round2Tests · `aSymlinkedSiblingFileIsPlacedByTheForecastWhereTheRunPlacesIt`; Round3Tests · `theForecastsResolverFollowsAFileSymlinkOntoAnotherVolume` |
| R3-2 (round 3) | the boundary reads the Angel's buffer uncached (`inFlightRecordIDsFresh`); the pre-check's cache (`inFlightRecordIDsCached`) fingerprints ctime too | Round3Tests · `aPlanRewrittenInPlaceIsSeenAtTheRemovalBoundary`, `theUncachedBoundaryReadsStayWithinBudget` |
| after round 3 | the Master Archive rule at the removal boundary is built from the model's CURRENT designation on the disk thread (`removalBoundaryArchiveCheck`) — all six things the final verdict reads are fresh | DeleteDuplicatesCodex258HoldBoundaryTests · `aMasterArchiveDesignatedDuringPhaseTwosReReadStopsTheRemoval`; Round3Tests · `theFinalVerdictCallsOnlyTheFreshEntryPoints` |
| R3-3 (round 3) | `SourceTree.strippingComments` removes nested `/* … */` comments; the three sensor-only branches of round 2 have behaviour tests or were retired | Round3Tests · `theCommentStripperRemovesBlockCommentsToo` |
| F11 | `worthReading` reads a sibling on a second drive once three are counted on one; prove, forecast, steward and the job's drive reservation follow | DeleteDuplicatesCodex258DrivesTests · `aSiblingOnASecondDriveIsWorthReadingEvenWithThreeCounted`, `theRunReadsTheSecondDriveSiblingAndTheForecastSaysItWill` |

