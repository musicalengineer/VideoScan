Brief: C04 | Source: main@c86b926 | Wall clock: 9 | Files read: 38
Finding count: 6 (REAL 5 / NEEDS-MAC 0 / NOISE 1)
Verdict: The deletion-side sensors are strong. Of the 16 guards checked by mutation-reading, 13 have a behavioural test that would go red. Two have no red test (Migrate's start-time overlap refusal, and the removal-boundary archive-copy branch). One delete path has no viewer-mode guard at all, so it has nothing to pin.

## Scope and method

- Item 3 first. I took 16 guards on the deletion and prune side (weighted as asked, away from the Archive/ promote, journal and lock guards). For each, I asked one question: "if this line were deleted, which test goes red?" Before calling a guard unpinned, I grepped `VideoScan/VideoScanTests/` for the symbol and for its refusal text. (`VideoScanCore/Tests` holds none of these guards.)
- Items 1 and 2 then ran over the test files item 3 led to, plus a pattern sweep of every in-scope file: early `return`, `try?`, host-dependent `guard … else { return }`, `allSatisfy` over a collection that might be empty, and raw-text source sensors.
- `SourceTree.appSource(named:)` with a name that no longer exists: `appSourceURL` records an `Issue` and returns nil when zero files match, or several do. `appSource` then throws `NotFound`, so the test fails. It cannot pass by reading nothing. `SourceTreeTests.aMissingAppSourceIsRefusedLoudly` pins this with `withKnownIssue`. No in-scope sensor wraps `appSource`/`appCode` in `try?`.
- Callees followed to settle findings: `DeleteDuplicatesJob.run` / `removalBoundary` / `restoreQuarantined`, `DeletionTierDecision.decide`, `DeletionTierFacts.gather`, `VideoScanModel.deleteDuplicates(onVolume:)`, `deleteConfirmedJunk`, `trashSelectedRecords`, `pruneOneCopy` / `pruneSurvivorProblem*`, `SignatureVerification.verify`, `RelocatePathGuard.refusal` / `refuseOverlappingMigrate`, `runRelocate(jobID:)`, `RelocateEngine.runOne`, `CombineOutputPublish.publish`, `TranscodeJob.existingFilePolicy`, the Catalog row context menu (`CatalogContent+Table.swift`), `isArchiveCopy`, `applyReadOnlyMode`.

## Guard → test

| # | Guard (production) | Test that goes red if the guard line is deleted | Status |
|---|---|---|---|
| 1 | Two-drive survivor rule: `DeletionTierDecision.earnsPermanent` / `decide` (`DeleteDuplicatesPlan.swift:579-605`) | `DeleteDuplicatesTwoDrivesTests.theTruthTable` (3 copies on 1 drive → `.trash`), plus the end-to-end `threeCopiesOnOneDriveSendTheCopyToTheTrashNotOutright` | Pinned |
| 2 | Fewer than 2 remaining → left alone (`decide`, `n >= minimumForTrash`) | `theTruthTable` (`tier(1,…) == nil`); `DeleteDuplicatesTierAndSpeedTests` | Pinned |
| 3 | Disk image, unidentified volume or RAID never adds a drive (`DuplicateDrives`, `recheck`) | `DeleteDuplicatesCodex258TierTests` 416-452, `DeleteDuplicatesPhysicalDriveTests` 125-210, Round3/Round4 fresh-resolver tests | Pinned |
| 4 | Viewer-mode refusal in `DeleteDuplicatesJob.run` (`DeleteDuplicatesJob.swift:892`) | `DeleteDuplicatesSafetyTests.readOnlyViewerCannotDeleteDuplicate`, but only through `duplicateStatus.contains("viewer mode")`; see F4 | Pinned (weakly) |
| 5 | Read-only volume: plan never offers it, and every row is left alone at its turn | `ReadOnlyVolumeTests.deleteDuplicatesNeverSelectsOrOffersAReadOnlyDrive`, `deleteDuplicatesRemovesNothingOnAReadOnlyDrive` | Pinned |
| 6 | Read-only volume marked mid-run: re-asked per file in `deleteConfirmedJunk` and at the duplicate removal boundary | `ReadOnlyVolumeCodex258Tests.markingADriveReadOnlyMidRunProtectsTheFilesNotYetRemoved`, `PruneApplyTests` 528-538 | Pinned |
| 7 | Read-only volume on Move to Trash / Junk / Discard / Transcode Replace | `ReadOnlyVolumeTests.moveToTrashJunkDeleteAndDiscardLeaveAReadOnlyDriveAlone`, `DeleteDuplicatesPhysicalDriveTests.transcodeReplaceAsksAtThePublish` | Pinned |
| 8 | Archive-copy / Angel hold, fail-closed on an unreadable Angel buffer (`removalBoundary` `.uncertain` → hold) | `DeleteDuplicatesCodex258Round4Tests` around 440 (file exists, row `skipped` with the "could not be read just now" note), and `theFreshReadingSaysWhatItCouldNotRead` | Pinned |
| 9 | Promoted archive copy held while no Master Archive is designated (`duplicateDeletionHoldRule`) | `StewardRulesTests:413`, `DeleteDuplicatesAngelHoldTests:608`, `Round4.r5aRowOfThisRunNeverEntersTheArchiveCopies` | Pinned |
| 10 | Archive copy at the removal boundary while a Master Archive IS designated (`removalBoundary`, `DeleteDuplicatesJob.swift:1615`) | none (see F2) | **Unpinned** |
| 11 | Fail-closed on sibling and archive evidence in `DeletionTierFacts.gather` (no usable fixity, digest differs, stamp changed, hard link, offline, row of this run) | every `notCounted` reason text is asserted: `DeleteDuplicatesTierAndSpeedTests`, `DeleteDuplicatesSiblingProofTests`, `DeleteDuplicatesCodex1606Tests` | Pinned |
| 12 | Signature verification: same path / hard link, content differs, keeper changed mid-read | `SignatureVerificationOneSidedTests.samePathIsRefused` (+371-375), `DeleteDuplicatesSafetyTests.partialMD5CollisionSurvivesDeletion` (asserts `.review`) | Pinned |
| 13 | Quarantine put-back never clobbers an occupied original path (`restoreQuarantined`, `:2205`) | `DeleteDuplicatesCodex1593Tests` 349-395 (the newcomer's bytes are intact), `Codex1606Tests:418`, `Codex1619Tests:530` | Pinned |
| 14 | Failed move to the Trash puts the file back | `DeleteDuplicatesTrashFailureRedTests` (both tests) | Pinned |
| 15 | Prune apply: unchecked survivor gone, changed or retired between verdict and move; archive copy changed or unverified; Read-only drive; viewer mode | `PruneApplyTests` 1031-1080, 413-422, 1303-1310, 528, 1341 | Pinned |
| 16 | ⌘⌫ Trash selection: pair member, Master Archive and viewer-mode refusals (`trashSelectedRecords`, `:116`) | `CatalogTrashShortcutTests.trashWritesOneCopyTrashedLinePerRow` (pair and archive files exist), `noOpsNeverTouchTheDisk` (viewer `attempted == 0`) | Pinned |
| 17 | Migrate source/destination overlap: enqueue-time refusal | `RelocateSourceDestGuardTests` 191-290 | Pinned |
| 18 | Migrate overlap: start-time refusal in `runRelocate(jobID:)` (`VideoScanModel+Relocate.swift:234-240`) | only the substring sensor `run.contains("refuseOverlappingMigrate(")` (see F1) | **Unpinned** |
| 19 | `RelocateEngine.runOne` destination collision (`:64`) | `RelocateEngineTests.destinationCollisionIsRejected` (squatter's bytes intact) | Pinned (but see F3) |
| 20 | Never-clobber publishers (Combine / Derivative / ExclusivePublish) | `CombineOutputPublishTests.publish_takenNames_goBeside_andNeverTouchExisting`, `fallback_takenName_…`, `PublishNeverOverwritesOrLosesOutputTests` (parameterised over publishers) | Pinned |
| 21 | Viewer mode on the Catalog row menu's Delete File → Move to Trash / Delete Permanently (`deleteConfirmedJunk`) | no guard exists (see F5) | **No guard** |

## Findings

### C04-F1 — P2 — REAL — Migrate's start-time overlap refusal has no red test
- **Symbol:** `VideoScanModel.runRelocate(jobID:)`, `MediaOps/VideoScanModel+Relocate.swift:234-240`. Its only sensor is `RelocateSourceDestGuardTests` "enqueueRelocate, runRelocate(jobID:) and the sheet go through the path guard" (`RelocateSourceDestGuardTests.swift:299-306`).
- **Why the sensor cannot fail:** it asserts only `run.contains("refuseOverlappingMigrate(")`. Each of these edits keeps the call text, so the sensor stays green:
  - the result is ignored (`_ = refuseOverlappingMigrate(…)`);
  - `guard refusal == nil, !scope.isEmpty` is narrowed to `guard !scope.isEmpty`.
  No test calls `runRelocate(jobID:)` with a queued job whose paths now overlap. The grep found no test for `"at start"` outside the log-privacy test, which calls the helper directly.
- **Scenario that ships green:** Migrate A→B is queued while A and B are different folders. Before it runs, a remount makes B resolve inside A, or to A itself (the GH #109 race the comment names). With the guard edited out, the job copies the volume into itself. The enqueue tests stay green.
- **Smallest pinning test:**
  - Enqueue a valid job while busy, so it stays queued.
  - Rewrite `relocateQueue[i].options.destinationRoot` to the source root, or to a folder inside it.
  - `await model.runRelocate(jobID:)`.
  - Expect status `.failed(reason:)` with the overlap message, no files created under the destination, and no catalog path changes.

### C04-F2 — P2 — REAL — The removal boundary's archive-copy branch, with an archive designated, has no red test
- **Symbol:** `DeleteDuplicatesJob.removalBoundary(model:recordID:path:)`, the `if now.isArchiveCopy { answer.archive = (… .archiveTree …) }` branch at `MediaOps/DeleteDuplicatesJob.swift:1615-1618`.
- **What the existing tests cover:**
  - The no-designation case goes through the hold rule (`Round4.r5aRowOfThisRunNeverEntersTheArchiveCopies`, `StewardRulesTests:413`).
  - Every designated-archive boundary test (`Round4.aCopyRetainedAtTheArchiveBoundary…`, `aCopyBothInTheArchiveAndHeld…`, `theBoundaryReadsTheModelOnce…`) designates `targetPath = rig.dir`. That refuses through the archive VOLUME check, so it never reaches this branch.
  - The grep for `now.isArchiveCopy` / `.archiveTree` in tests finds only the Steward off-main ordering sensor.
- **Scenario that ships green:** A Master Archive is designated on another drive. A duplicate under the volume being cleaned passes its turn check, then gains promoted-copy provenance (`isArchiveCopy` = `derivationKind == ArchivePromotion.derivationKind`) during phase two's read. The file is not on the archive volume, so `ArchiveRemovalCheck` clears it. With the branch deleted, the archive copy is unlinked or trashed.
- **Smallest pinning test:**
  - Copy `r5aRowOfThisRunNeverEntersTheArchiveCopies`, but designate the archive on a separate temp root.
  - Use the `MasterArchiveDesignation.$volumeUUIDProbe` / `ArchiveVolumeProtection.$mountIdentityProbe` seams so the rig folder is proven to be another volume.
  - In `during:`, set `rig.a.derivationKind = ArchivePromotion.derivationKind`.
  - Expect A still on disk, with the row refused and the note containing "lives in the Master Archive".

### C04-F3 — P3 — REAL — `RelocateEngine.runOne` deletes whatever is at the destination after any copy error
- **Symbol:** `RelocateEngine.runOne`, `MediaOps/RelocateEngine.swift:64` (the existence check) and `:103` (`try? fileManager.removeItem(atPath: job.destPath)` in the copy `catch`).
- **The problem:** the collision check is check-then-act. If a file appears at `destPath` between `:64` and `copyItem`, `copyItem` throws because the file exists, and the cleanup then removes that other file. The cleanup does not check that it is removing its own half-written output. `destinationCollisionIsRejected` passes only because the stage-1 check catches the squatter first. The same test shows what happens without that check: the squatter would be deleted.
- **Scenario:** a second writer (another app, a Finder copy, a parallel session) creates the destination name in that window. Its file is deleted, and the outcome reads `copy failed`. Narrow, because Migrate runs one job at a time.
- **Smallest pinning test:**
  - Inject a `FileManager` subclass whose `fileExists(atPath:)` returns false for `destPath`, with a real squatter file already at `destPath`.
  - Call `runOne`.
  - Expect `.salvageFailed` and the squatter's bytes intact. This fails today.
  - The fix to pin: an exclusive create or `RescueFileCopier`'s partial + `RENAME_EXCL`, or cleanup only of a partial this call created.

### C04-F4 — P3 — REAL — The viewer-mode Delete Duplicates test's file assertions are vacuous
- **Symbol:** `DeleteDuplicatesSafetyTests.readOnlyViewerCannotDeleteDuplicate`, `VideoScanTests/DeleteDuplicatesSafetyTests.swift:223-246`.
- **Why it cannot fail on the file checks:** the fixture is keeper + one copy, without `addVerifiedArchiveFamily`, unlike the suite's other tests. Delete the viewer guard in `DeleteDuplicatesJob.run` and the copy is quarantined, verified, and then left alone by the tier rule anyway (1 remaining → `tier == nil`) and put back. So `result.deleted == 0`, `fileExists(copy)` and `records.count == 2` all stay green. Only `duplicateStatus.contains("viewer mode")` pins the guard. That pin breaks if the status wording changes, or if the refusal moves later and quarantines the file first, which a viewer must never do.
- **Smallest pinning test:** add `addVerifiedArchiveFamily(to: model, keeper:)` so the copy would earn the Trash without the guard. Also assert that no quarantine folder was created (`SignatureVerification.quarantineDirectoryPrefix`) and `job.wasRefused`.

### C04-F5 — P2 — REAL — The Catalog row's Delete File → Delete Permanently has no viewer-mode guard
- **Symbols:**
  - `VideoScanModel.deleteConfirmedJunk(_:mode:guard:)`, `MediaOps/VideoScanModel+JunkDelete.swift:161-180`: no `isReadOnly` check.
  - Its caller, the Catalog row context menu, `Catalog/CatalogContent+Table.swift:1170-1198`. The menu is shown whenever `deletableRecs` is non-empty. It is not `.disabled(model.isReadOnly)`, unlike the Family Music items at `:1005` and `:1014`.
- **The other entry points do have the guard:** `trashSelectedRecords` (`:116`), prune `applyPrune` (`PruneApply.swift:481`) and `DeleteDuplicatesJob.run` (`:892`). `RemoteViewerReadOnlySensorTests` lists the viewer's write paths, but `deleteConfirmedJunk` is not among them. `DeleteDuplicatesSafetyTests:220-222` states the invariant ("a viewer … must never mutate archive media, even if … a direct caller reaches the model API").
- **Scenario:** a viewer Mac (`applyReadOnlyMode(true)`) that can reach a file's path, for example with the drive mounted under the same name. The person picks Delete File → Delete Permanently on a row and the file is unlinked. `CatalogStore` then refuses the save, so the master's catalog never learns of it.
- **Smallest pinning test:**
  - `model.applyReadOnlyMode(true)`.
  - `await model.deleteConfirmedJunk([rec], mode: .permanent)` on a temp file.
  - Expect `attempted == 0` and the file present. This fails today.
  - Add the guard at the top of `deleteConfirmedJunk`, the choke point all four bulk callers share.

### C04-F6 — P3 — NOISE — Silent passes that depend on the host
- **Where:**
  - `CombineOutputPublishTests.exFAT_realVolume_publishNeverClobbers` (`:290-298`) `print`s "SKIPPED" and `return`s when `hdiutil` is refused, so it reports PASS.
  - `DeleteDuplicatesPhysicalDriveTests.theBootVolumeAndTheDataVolumeAreOneDrive` (`:253-260`) asserts its real claim only `if a.kind == .physical, b.kind == .physical`.
  - `DeleteDuplicatesCodex258Round3Tests.theForecastsResolverFollows…` (`:258`) and `Round2` (`:250`) return early on a failed `stat` or missing UUID.
  - `Round4.theFreshReadingSaysWhatItCouldNotRead` skips its chmod-000 case under root.
- **Why NOISE:** for each one, the seam-based tests next to it carry the guard (the ENOTSUP/EINVAL fallback tests, the `lookupOverride` drive tests). On the Macs that run the suite, the conditions hold. If the exFAT test is meant as real coverage, use `.enabled(if:)` or a recorded known issue so a sandboxed runner reports "skipped", not "passed".

## Item 2 (loose source sensors): what I found

- Several in-scope sensors match raw source text (`SourceTree.appSource`), not `appCode`, so a string that survives in a comment still matches:
  - `DeleteDuplicatesTwoDrivesTests`, `Codex258TierTests`, `Codex258HoldBoundaryTests`, `AngelHoldTests`, `FixityStampVolumeIdentityTests`, `ReadOnlyVolumeCodex258Tests`, `RelocateSourceDestGuardTests`, `CatalogTrashShortcutTests`.
  - `ReadOnlyVolumeSensorTests.code(_:)` strips only whole-line `//` comments, not trailing or `/* */` ones.
- For every guard those sensors name, apart from F1, a behavioural test in the table above goes red on deletion. So the looseness does not yet hide an unpinned guard. Moving them to `appCode(named:)` would close the class (as codex #258 r2/r3 did for the Round2-4 files). I did not count this as a separate finding.
- `CatalogTrashShortcutTests.shortcutSharesTheTrashRoutine` slices `prefix(1_800)` after the handler. If the window ever stops reaching the asserted calls, those `contains` checks fail; they cannot pass silently. Not vacuous.

## Not covered
- The Archive/ guards (promote, journal, index lock, file lock, Update/refile, fixity re-verify): left to the concurrent N1008-T-Archive row. In the `*Promote*`, `*Fixity*` and `*Ledger*` test files I ran only the item 1-2 pattern sweep: `allSatisfy` and early returns are guarded by count checks, and the ledger-rename sensors are absence checks. No finding.
- `RelocateRetireVolumeTests`, `RelocateReconcile*`, `RelocateSafelyRedundantTests`, `RelocateQueueTests`: not read beyond the grep for the start-time refusal. Whether Retire or Reconcile ever removes a file on a drive marked Read only was not checked.
- `DeleteDuplicatesSiblingProofTests`, `OfferShadowTests`, `RecoveryObligationTests`, `Codex1611Tests`: used only to confirm by grep that refusal texts are pinned. Not read in full for item 1.
- `MediaLedger*`, `CorrelateLedgerTests`, `DuplicateLedgerTests`, `HallieNeuralPlaybackLedgerTests`: not reached.
