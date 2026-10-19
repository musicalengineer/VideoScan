# Adversarial review 2026-10-18 — open findings

- Range: `93c72a704..64ea21ac6` (three passes, cycles #104/#105/#107 in `tools/codex_review.py` state)
- Raw run: `~/Library/Logs/VideoScan/adversarial-review/runs/2026-10-18/`
- Status (updated 2026-10-18 night): #1 #2 #3 #9 #10 confirmed and fixed; #8 tests added; #4–#7 deferred (Import code removal). Originally: **all 10 UNCONFIRMED and OPEN.** The red-test confirm step did not run — its build failed outside the drafts (exit 65 / exit 1, round 1), so `confirmedRed: 0` means *not tested*, not *disproved*.
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
- Disposition: **CONFIRMED and FIXED (2026-10-18, bug-fix agent, branch `worktree-agent-a064e7cb359eff55c`).** Re-checked against main 895a2fd00 and still real: `snapshotCatalog` under the SQLite authority returns `catalog.pre-volume-rename.<stamp>.sqlite`, and `undoVolumeRenameMigration` read it with `CatalogStore.loadRecords(fromSnapshotAtPath:)` (the JSON decoder), so Undo logged "failed to decode catalog", said "Couldn't read the pre-update snapshot" and left every record on the new path. Fix (new file `Volumes/VideoScanModel+VolumeRenameUndo.swift`; Undo moved out of the migration file): `loadSafetyCopy(atPath:)` reads a `.sqlite` copy through `SQLiteCatalogLoader` (JSON copies as before). Undo no longer replaces the whole array: it reverts exactly what the migration wrote (`fullPath`, `directory`, `scanContext.volumeName`) on each record whose live path is still the migration's rewrite (`revertVolumeRenameRewrites`, a compare-and-swap per record). Records added since and edits made since are kept, and a record moved since is left alone and counted. Nothing leaves the catalog, so the B2.3 `purgeCatalogRows(ids: before …)` line, which would have purged every record added since the migration (codex's fix hazard), is gone. Undo is now `async`, because the store read is async; the dialog button wraps it in a `Task`. Behaviour change, JSON included: Undo no longer drops records added after the migration, and no longer reverts later edits. Pinned by `AdvVolumeRenameUndoSQLiteTests` (5 tests: reads the .sqlite copy; SQLite relaunch sensor with an added record and a later note, never purged; moved-since left alone; JSON authority; 100k revert under budget, about 0.34 s Debug). The existing `VolumeRenameMigrationTests.undoRestoresPreMigrationCatalogByteIdentically` still passes on the JSON path. Red (old loader: 3 of 5 red, the original "failed to decode catalog" symptom) → green. Revert to verbatim restore + purge with the new loader: the sensor and the JSON test go red, and the added record is purged from catalog.sqlite. Restore → green.

## 3. [P2] The SQLite safety copy is the last commit, not what's in memory, so a doomed row's latest edit can't be recovered

- File: `VideoScan/VideoScan/Volumes/VideoScanModel+ScanMerge.swift:876` — `sqliteSnapshot`
- Invariant: VOL-3
- Claim: - **The old contract:** `snapshotCatalog` was written from memory (QA #7: "a disk copy lags by the 2 s save debounce"). `sqliteSnapshot` instead seals the last commit.
- Proposed red test: `AdvSQLiteSafetyCopyTests/safetyCopyCarriesAnEditNotYetCommitted`
- Disposition: **CONFIRMED and FIXED (2026-10-18, bug-fix agent, branch `worktree-agent-a064e7cb359eff55c`).** Re-checked against main 895a2fd00 and still real: `sqliteSnapshot` sealed `VACUUM INTO` of catalog.sqlite as committed, so an edit made inside the 2 s debounce was not in the copy. A door that then removed and purged the row lost the edit from both places. Fix, as the Manager suggested (flush, not write-from-memory): the new `CatalogCommitter.commitBeforeSafetyCopy()` runs the same synchronous `.everything` commit `saveCatalogNow` runs, then `sqliteSnapshot` seals the copy. One call covers every door (`snapshotCatalog` and `snapshotCatalogAsync`: pre-merge, pre-target-removal, pre-volume-rename, show-again, dup, purges, notes-repair). When no commit can be written now (held by a job, blocked read-only, being reopened, refused), the copy is REFUSED ("REFUSED safety copy <prefix> — what is in memory could not be committed first: …") and the door fails safe as it already does for a nil snapshot. A row the store itself refuses (for example a CHECK violation) does not block the copy: one line says so, and that row is in the copy at its last stored value. **Rick to confirm this choice**; the stricter rule would block every snapshot-gated door until that row is fixed. Pinned by `AdvSQLiteSafetyCopyTests` (4 tests: sync door, async door, an end-to-end sensor where edit → copy → remove + purge leaves the row gone from catalog.sqlite but in the copy with the edit, and a held catalog that refuses the copy and writes no file). Scale: the extra work is the existing synchronous commit, already pinned by `CatalogCommitScaleTests`. Red (all 4) → green → revert (4/4 red) → green.

## 4. [P2] Catalog-writing jobs, including Trash-moving ones, can start inside an Import to SQLite run

- File: `VideoScan/VideoScan/MediaOps/ImportToSQLitePhases.swift:145` — `importRunsItsOwn`
- Invariant: MOPS-16
- Claim: The pre-flight refuses "another MFO job running — one job at a time while the catalog is read" (ImportToSQLitePreflight.swift:58), but only once, when the job is made.
- Proposed red test: `ImportHoldWriterGateRedTests/aCatalogWriterLaneRefusesWhileAnImportIsActive`
- Disposition: DEFERRED — Import code removal ~Nov 1 (Manager 2026-10-18); re-open only if Import stays.

## 5. [P2] Import keeps only one volume name per drive UUID; rows scanned after a rename read back the old name

- File: `VideoScan/VideoScanCore/Sources/VideoScanCore/Import/CatalogImporter+Rows.swift:164` — `writeMain`
- Invariant: MOPS-16
- Claim: writeMain` calls `insertVolume` only for the first row of each `volumeUUID` (`pass.volumes.insert(...).inserted`). That row's `scanContext.volumeName` (also `volumeMountType` and `remoteServerName`) becomes `volumes.last_name` for every row with that UUID. Nothing later updates it: `insertVolume` is a plain INSERT, and `FileRow` has no per-row name. Each row's own scan-time name is in no table, no `raw_row`, and no `knowledge_sources`. The comparator has no volume reading, so the import commits.
- Proposed red test: `ImportVolumeNameTests/aRowScannedAfterARenameKeepsItsVolumeName`
- Disposition: DEFERRED — Import code removal ~Nov 1 (Manager 2026-10-18); re-open only if Import stays.

## 6. [P3] A Stop before phase 1 still starts an audit, which overwrites the last completed audit marker

- File: `VideoScan/VideoScan/MediaOps/ImportToSQLiteJob.swift:368` — `runPhase`
- Invariant: MOPS-16
- Claim: Press Stop while `holdWrites` is waiting for earlier saves to finish (up to 60 s). `runPhase` passes the cancel to the audit and then starts it anyway (`if stopFlag.isRaised { child.cancel() }; child.start()`).
- Proposed red test: `ImportStopBeforeAuditRedTests/aStopBeforeTheAuditLeavesTheLastAuditMarkerAsItWas`
- Disposition: DEFERRED — Import code removal ~Nov 1 (Manager 2026-10-18); re-open only if Import stays.

## 7. [P3] After a Stop or refusal, the row and detail words say things that did not happen

- File: `VideoScan/VideoScan/MediaOps/ImportToSQLiteJob.swift:557` — `finish`
- Invariant: MOPS-16
- Claim: Three places:
- Disposition: DEFERRED — Import code removal ~Nov 1 (Manager 2026-10-18); re-open only if Import stays.

## 8. [P3] Junk delete's new "ask the catalog before moving the file" check has no test

- File: `VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:368` — `junkTurn`
- Invariant: MOPS-7
- Claim: B2.3 added `CatalogMarkerRelay.saveRefusal(for:)` before the disk work, so a held or read-only catalog.sqlite should refuse the file rather than leave it in the Trash with a live row. It also added `recordFileLeft`'s "NOT RECORDED" mixed-state branch.
- Disposition: **CONFIRMED (coverage gap only) — TESTS ADDED, no code change (2026-10-18, bug-fix agent, branch `worktree-agent-a064e7cb359eff55c`).** The behaviour was already correct on main 895a2fd00; it just had no test. Pinned by `AdvJunkDeleteHeldTests` (4 tests), each running `deleteConfirmedJunk` on a real sandbox file through the test-seam remover: held catalog → file stays, outcome `held` ("… the catalog can't save … — nothing moved"), row untouched; blocked read-only committer → same; a free control → file leaves and the row is marked; `recordFileLeft` on a row whose earlier marker change cannot be stored → "NOT RECORDED: <name> was already gone" and the row keeps its marker. Sensors, so no red step: all 4 pass with and without the other fixes. Not covered: the audit's `couldNotCheck` path (`VideoScanModel+CatalogAudit.swift:152`), which codex also named. Left open as a test gap.

## 9. [P3] Relocate counts a refused Bucket B row as marked, and logs one line per refused row

- File: `VideoScan/VideoScan/MediaOps/VideoScanModel+Relocate.swift:390` — `markSourceNotFound`
- Invariant: MOPS-9
- Claim: Under a held or read-only catalog.sqlite, `markSourceNotFound` returns without writing anything. The caller still runs `dashboard.relocateManuallyDeleted += 1` and `relocateCompleted += 1`, so the sheet says N rows were "marked" when none were.
- Disposition: **CONFIRMED and FIXED (2026-10-18, bug-fix agent, branch `worktree-agent-a064e7cb359eff55c`).** Re-checked against main 895a2fd00 and still real: when the catalog refused, `markSourceNotFound` returned without writing, but the caller still did `relocateManuallyDeleted += 1`, and each refused row wrote its own console line. Fix: `markSourceNotFound` now returns the refusal words. A new `markBucketBSourcesNotFound(_:)` replaces the Bucket B loop: it counts only rows actually marked, still moves `relocateCompleted` for every row (so the bar finishes), and writes ONE line to the console and relocate.log: "Reconcile: N row(s) whose source was not found were NOT marked Missing — <first reason>. The next Reconcile asks again." Pinned by `AdvRelocateBucketBHeldTests` (3 tests: held → 0 marked, 2 completed, one line, no per-row lines; free → 2 marked; scale → 2,000 refused rows give one line, about 1.3 s Debug). Red (2 of 3) → green → revert (2/3 red) → green.

## 10. [P3] Undo of Remove from Catalog while the catalog is held drops the banner silently

- File: `VideoScan/VideoScan/MediaOps/VideoScanModel+SoftDelete.swift:181` — `undoLastPurge`
- Invariant: MOPS-7
- Claim: Since B2.3, `clearRemoval` can refuse while catalog.sqlite is held.
- Disposition: **CONFIRMED and FIXED (2026-10-18, bug-fix agent, branch `worktree-agent-a064e7cb359eff55c`).** Re-checked against main 895a2fd00 and still real: when `clearRemoval` refused (held), `undoLastPurge` saw `restored == 0`, cleared the batch and the error, and the banner vanished with nothing restored. Fix: a refused row stays in `lastPurgedBatch`, and the banner stays armed with `lastPurgeUndoError` = "Undo didn't finish [for N items]: can't restore <name> right now — the catalog can't save (…); try again when …". Rows that did restore are saved and recorded in the ledger as before. Refusals are logged once per Undo, not once per row. Pressing Undo again after the hold lifts finishes the job. Pinned by `AdvUndoPurgeWhileHeldTests` (2 tests: held then released; not held, unchanged). Red (1 of 2) → green → revert (1/2 red) → green.
