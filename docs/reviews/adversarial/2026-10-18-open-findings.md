# Adversarial review 2026-10-18 — open findings

- Range: `93c72a704..64ea21ac6` (three passes, cycles #104/#105/#107 in `tools/codex_review.py` state)
- Raw run: `~/Library/Logs/VideoScan/adversarial-review/runs/2026-10-18/`
- Status: **all 10 UNCONFIRMED and OPEN.** The red-test confirm step did not run — its build failed outside the drafts (exit 65 / exit 1, round 1), so `confirmedRed: 0` means *not tested*, not *disproved*.
- The cycles were closed on 2026-10-18 only to clear the stale "fixing" rows (no process was running). Each finding below still needs a pinning test or an explicit decline with a reason.
- The range predates the B2.x cutover merges; re-check each claim against current main before fixing.

## 1. [P1] Notes and stars typed while a rescan runs are lost when the scan merges

- File: `VideoScan/VideoScan/Volumes/VideoScanModel+ScanMerge.swift:671` — `commitScanResults`
- Invariant: VOL-4
- Claim: - **Mechanism:** `snapshotPreservedFieldsForRescan` copies a record's curated fields when the scan starts (ScanLifecycle:56). `applyPreservedFieldsAfterRescan` re-reads only `archiveFixity` from the live record. The merge then removes the old instance (:539/:670) and adds the fresh record, which carries the copy taken at scan start. B2.3 now purges the old id in the same turn (:564/:674).
- Proposed red test: `AdvRescanEditDuringScanTests/notesTypedDuringTheScanSurviveTheMerge`
- Disposition: **CONFIRMED and FIXED (2026-10-18, bug-fix agent, branch `worktree-agent-a517ebe73e8e0b54d`).** Re-checked against main 4ce05b520 and the mechanism was still there: `applyPreservedFieldsAfterRescan` wrote the scan-start snapshot, and the merge re-read only `archiveFixity` from the live record (`reconcileLiveArchiveFixityBeforeReplacement`). Red in Debug, including the SQLite relaunch: userNotes and stars came back as the scan-start values; clears were brought back; a Trash made during the scan was undone. Fix: the merge's last-moment reconcile now re-reads the WHOLE preserved set from the live record through `RescanPreservedFields.apply(to:)` (renamed `reconcileLivePreservedFieldsBeforeReplacement`, ScanMerge). It applies the live values when the live record carries something worth keeping or when the fresh record was restored from the snapshot (`pendingRescanRestoredPaths`). It then re-links the lifecycle pointers. Technical values from the scan are left alone; a never-curated record keeps its fresh machine note. Pinned by `AdvRescanEditDuringScanTests` (9 tests: logic, edits during the merge's await, clears, Trash, shared-path active row, scan-derived values refresh, SQLite relaunch sensor, 100k scale). Red → green → revert (8/9 red) → green.

## 2. [P2] After the flip, a volume rename can't be undone: Undo reads the `.sqlite` safety copy as JSON

- File: `VideoScan/VideoScan/Volumes/VideoScanModel+VolumeRenameMigration.swift:827` — `undoVolumeRenameMigration`
- Invariant: VOL-5
- Claim: - **What changed:** before B2.3, `snapshotCatalog` returned nil under catalog.sqlite, so `migrateRenamedVolume` refused at :682 and nothing was rewritten. Now it returns `catalog.pre-volume-rename.<stamp>.sqlite` (ScanMerge.swift:836, sealed by `VACUUM INTO`).
- Proposed red test: `AdvVolumeRenameUndoSQLiteTests/undoReadsTheSafetyCopyItWasGiven`
- Disposition: _open_

## 3. [P2] The SQLite safety copy is the last commit, not what's in memory, so a doomed row's latest edit can't be recovered

- File: `VideoScan/VideoScan/Volumes/VideoScanModel+ScanMerge.swift:876` — `sqliteSnapshot`
- Invariant: VOL-3
- Claim: - **The old contract:** `snapshotCatalog` was written from memory (QA #7: "a disk copy lags by the 2 s save debounce"). `sqliteSnapshot` instead seals the last commit.
- Proposed red test: `AdvSQLiteSafetyCopyTests/safetyCopyCarriesAnEditNotYetCommitted`
- Disposition: _open_

## 4. [P2] Catalog-writing jobs, including Trash-moving ones, can start inside an Import to SQLite run

- File: `VideoScan/VideoScan/MediaOps/ImportToSQLitePhases.swift:145` — `importRunsItsOwn`
- Invariant: MOPS-16
- Claim: The pre-flight refuses "another MFO job running — one job at a time while the catalog is read" (ImportToSQLitePreflight.swift:58), but only once, when the job is made.
- Proposed red test: `ImportHoldWriterGateRedTests/aCatalogWriterLaneRefusesWhileAnImportIsActive`
- Disposition: _open_

## 5. [P2] Import keeps only one volume name per drive UUID; rows scanned after a rename read back the old name

- File: `VideoScan/VideoScanCore/Sources/VideoScanCore/Import/CatalogImporter+Rows.swift:164` — `writeMain`
- Invariant: MOPS-16
- Claim: writeMain` calls `insertVolume` only for the first row of each `volumeUUID` (`pass.volumes.insert(...).inserted`). That row's `scanContext.volumeName` (also `volumeMountType` and `remoteServerName`) becomes `volumes.last_name` for every row with that UUID. Nothing later updates it: `insertVolume` is a plain INSERT, and `FileRow` has no per-row name. Each row's own scan-time name is in no table, no `raw_row`, and no `knowledge_sources`. The comparator has no volume reading, so the import commits.
- Proposed red test: `ImportVolumeNameTests/aRowScannedAfterARenameKeepsItsVolumeName`
- Disposition: _open_

## 6. [P3] A Stop before phase 1 still starts an audit, which overwrites the last completed audit marker

- File: `VideoScan/VideoScan/MediaOps/ImportToSQLiteJob.swift:368` — `runPhase`
- Invariant: MOPS-16
- Claim: Press Stop while `holdWrites` is waiting for earlier saves to finish (up to 60 s). `runPhase` passes the cancel to the audit and then starts it anyway (`if stopFlag.isRaised { child.cancel() }; child.start()`).
- Proposed red test: `ImportStopBeforeAuditRedTests/aStopBeforeTheAuditLeavesTheLastAuditMarkerAsItWas`
- Disposition: _open_

## 7. [P3] After a Stop or refusal, the row and detail words say things that did not happen

- File: `VideoScan/VideoScan/MediaOps/ImportToSQLiteJob.swift:557` — `finish`
- Invariant: MOPS-16
- Claim: Three places:
- Disposition: _open_

## 8. [P3] Junk delete's new "ask the catalog before moving the file" check has no test

- File: `VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:368` — `junkTurn`
- Invariant: MOPS-7
- Claim: B2.3 added `CatalogMarkerRelay.saveRefusal(for:)` before the disk work, so a held or read-only catalog.sqlite should refuse the file rather than leave it in the Trash with a live row. It also added `recordFileLeft`'s "NOT RECORDED" mixed-state branch.
- Disposition: _open_

## 9. [P3] Relocate counts a refused Bucket B row as marked, and logs one line per refused row

- File: `VideoScan/VideoScan/MediaOps/VideoScanModel+Relocate.swift:390` — `markSourceNotFound`
- Invariant: MOPS-9
- Claim: Under a held or read-only catalog.sqlite, `markSourceNotFound` returns without writing anything. The caller still runs `dashboard.relocateManuallyDeleted += 1` and `relocateCompleted += 1`, so the sheet says N rows were "marked" when none were.
- Disposition: _open_

## 10. [P3] Undo of Remove from Catalog while the catalog is held drops the banner silently

- File: `VideoScan/VideoScan/MediaOps/VideoScanModel+SoftDelete.swift:181` — `undoLastPurge`
- Invariant: MOPS-7
- Claim: Since B2.3, `clearRemoval` can refuse while catalog.sqlite is held.
- Disposition: _open_
