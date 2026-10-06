Brief: N1010-H-Volumes | Source: main@c86b926 | Wall clock: 34 | Files read: 19
Finding count: 7 (REAL 6 / NEEDS-MAC 0 / NOISE 1)
Verdict: Retire and record removal are well guarded (plan-then-execute, id-exact removal, snapshot before more than 50, fail-safe degrade); the real gaps are around them: checkpoint files are named in a way that lets two targets share one, Delete-from-list leaves a running scan going, and the no-plan delete path resets target state even when it removed nothing.

Scope: `VideoScan/VideoScan/Volumes/` (theme H). The working tree HEAD (4bba897) has no diff against origin/main in this folder, so line numbers match main@c86b926.

Callees followed (outside the brief's folder, only as far as each finding needed):
- `Media/VideoScanModel+ProbeEngine.swift`: where the checkpoint is saved (about line 186-202), `runResumedProbeGroup` (470-570)
- `Model/VideoScanModel.swift`: `resetTarget` (1686-1696), `records` didSet (12-20), the launch call to `repairCorruptedPhases` (1189)
- `MediaOps/VideoScanModel+SoftDelete.swift`: `clearPurgeUndoState`
- `Catalog/CatalogAuditFixer.swift`: `deleteEmptyTargets` (79-86)
- `Catalog/CatalogView+VolumeTable.swift`: the resume/start buttons (300-330, 400-412)
- Tests, grep only: `DeleteScanTargetTests`, `DeleteVolumeCatalogPlanTests`, `TargetRemovalSafetyTests`, `ScanMergeScopeTests`, `CatalogPurgeTests`

## Findings

### N1010-H-Volumes-F1: two different targets can share one scan-checkpoint file, and resume never checks whose checkpoint it loaded
- **Severity:** P2. **Class:** REAL.
- **Symbol:** `ScanCheckpointStorage.fileURL(for:)`, ScanCheckpoint.swift:56-61; `VideoScanModel.resumeTarget`, VideoScanModel+ScanExecution.swift:597 and 645; `VideoScanModel.commitScanResults`, VideoScanModel+ScanMerge.swift:537 (partial merge: 658).
- **What is wrong:** The file name is the path with every `/` replaced by `_`. So a target at `/Volumes/S/a_b` and a target at `/Volumes/S/a/b` both map to `Volumes_S_a_b.json`. `load(for:)` returns whatever is in that file. `resumeTarget` uses `checkpoint.discoveredPaths` without checking that `checkpoint.volumePath == target.searchPath`. `detectResumableTargets` does compare `volumePath`, but it only decides which target gets marked; it is not consulted when Resume runs.
- **Failing scenario:**
  1. Network target B is interrupted mid-probe. Its checkpoint is kept and B shows `.resumable`.
  2. The user starts a fresh scan of network target A, whose path maps to the same file name. `startTarget(A)` deletes "A's" checkpoint, which is really B's file. A's walk then saves A's checkpoint under the same name.
  3. The user clicks Resume on B (B is still `.resumable` in memory). B probes A's file list.
  4. `finalizeSingleTargetScan` commits with `root = B`. `commitScanResults` never filters `targetRecords` to the root. None of A's paths are under B, so `removeAll` drops nothing and `records.append(contentsOf:)` adds a second record for every A file. The new copies carry no dossier or user fields, because the preservation snapshot was taken for B.
  5. B's existing records are all marked "vanished", but their files exist, so they are retained-invisible. Result: the catalog now has duplicate records with the same `fullPath` and no enrichment. Even in the lighter version, starting A silently destroys B's resume point.
- **Smallest pinning test (fails today):** `ScanCheckpointStorage.save(ScanCheckpoint(volumePath: "/tmp/x/a_b", ...))`, then `#expect(ScanCheckpointStorage.load(for: "/tmp/x/a/b") == nil)`. Today it returns the a_b checkpoint. A second test: when a checkpoint's `volumePath` does not match the target, `resumeTarget` should refuse it or fall back to a fresh scan.
- **Note on the fix:** a collision-free file name (for example a hash of the path) plus a `volumePath` equality check in `load`. The test needs the checkpoint directory to be injectable; see "Not covered".

### N1010-H-Volumes-F2: "Delete from list" works on a target that is mid-scan and does not cancel the scan
- **Severity:** P2. **Class:** REAL.
- **Symbol:** `VideoScanModel.deleteScanTarget`, VideoScanModel+DeleteScanTarget.swift:37-77. Callers: VolumesWindow.swift:485-491 (menu enabled for everything except `/`, VolumesWindow.swift:650-664) and CatalogAuditFixer.swift:83.
- **What is wrong:** `removeScanTarget` (VideoScanModel+ScanTargets.swift:145-152) cancels `scanTask` and stops the timer before delegating. `deleteScanTarget` does neither, and the Volumes window calls it directly.
- **Failing scenario:**
  1. A rescan of a volume is running.
  2. The user picks Delete from list… and confirms. The alert promises "catalog records are kept as orphans".
  3. The target leaves `scanTargets`, but its `scanTask` keeps running. `updateGlobalScanState`/`hasActiveTargets` compute from `scanTargets`, so the app reports no active scan. The row and its Pause/Stop controls are gone, so the user cannot stop it.
  4. At completion, `commitScanResults(root:)` still runs on the de-listed root: it replaces re-seen records and prunes proven-gone ones (tripwire still applies). The scan has written to records the user was just told would be left alone, through a job nobody can see or stop. A network checkpoint for that path can also be left behind and resurrect resume if the path is added again.
- **Smallest pinning test (fails today):** give a target a long-running `scanTask` (a Task awaiting a never-resumed continuation, or `status = .scanning`), call `deleteScanTarget(target)`, then `#expect(target.scanTask == nil || target.scanTask!.isCancelled)`. Alternatively, expect the delete to be refused while `target.status.isActive`.

### N1010-H-Volumes-F3: no-plan `deleteCatalogForTarget(_:)` resets target state and reports success even when the removal degraded
- **Severity:** P3. **Class:** REAL.
- **Symbol:** `VideoScanModel.deleteCatalogForTarget(_:)`, VideoScanModel+VolumeLifecycle.swift:202-215. Caller: `promptRetiredCatalogCleanup`, VideoScanModel+VolumeLifecycle.swift:436-440.
- **What is wrong:** `resetTargetStateForDeletedCatalog` runs before `removeCatalogRecords` and ignores `outcome.degradedNoSnapshot`. The plan-carrying overload (lines 225-233) correctly resets only on `.applied`.
- **Failing scenario:**
  1. A retired volume holds more than 50 records and the catalog directory is not writable, so the snapshot fails.
  2. Remove Catalogs → removal degrades and the records are kept (correct). But `phase = .noCatalog` and `lastScannedDate = nil` are persisted, "Deleted 0 catalog record(s)" is logged, the purge-undo banner is dropped, and the prompt logs "removed catalogs for N volume(s)".
  3. Because `retiredCatalogCleanupCandidates` filters out `.noCatalog`, the nag stays silent until the next launch, when `repairCorruptedPhases` puts the phase back.
- No record is lost, but the state shown to the user is false.
- **Smallest pinning test (fails today):** inject a `CatalogStore` whose `writeSnapshot` fails, add 51 records under a target, call `deleteCatalogForTarget(target)`, then `#expect(model.records.count == 51)` (passes today) and `#expect(target.phase != .noCatalog)` (fails today). No existing test exercises `degradedNoSnapshot` or `refusedNoSnapshot` at all (grep of VideoScanTests).

### N1010-H-Volumes-F4: the retired-cleanup prompt counts records by raw string prefix, so the number the user approves can be larger than what is removed
- **Severity:** P3. **Class:** REAL.
- **Symbol:** `VideoScanModel.retiredCatalogCleanupCandidates`, VideoScanModel+VolumeLifecycle.swift:351-356.
- **What is wrong:** The count uses `r.fullPath.hasPrefix(t.searchPath)`, not `PathScope`/`TargetRemovalScope`.
- **Failing scenario:**
  1. A retired target `/Volumes/Old` sits next to an active target `/Volumes/Old2` that has 10,000 records.
  2. The prompt reads "Old — 10,0xx records".
  3. The removal (`TargetRemovalScope`, which respects component boundaries) deletes only Old's own records.
- The error is in the safe direction (it shows more than it removes), but the shown count is not the one the removal uses. That breaks the codex #1393 rule that the count and the removal share one predicate, and the no-plan path's comment says "there is no dialog whose count could have gone stale", yet this modal is such a dialog.
- **Smallest pinning test (fails today):** retired target "/v/A" plus a record at "/v/AB/x.mov" → `#expect(model.retiredCatalogCleanupCandidates().isEmpty)`. Today it returns A with count 1.

### N1010-H-Volumes-F5: a failed checkpoint save is swallowed and the console still says "Checkpoint saved"
- **Severity:** P3. **Class:** REAL.
- **Symbol:** `ScanCheckpointStorage.save`, ScanCheckpoint.swift:63-73 (NSLog only, returns Void). Caller: ProbeEngine.swift:201-202 logs "Checkpoint saved … scan is resumable" unconditionally. `ScanCheckpoint.directory`, ScanCheckpoint.swift:30, uses `try?` on `createDirectory`.
- **What is wrong:** The write itself is atomic (`.atomic`), so this is not a half-written file. The problem is that the failure is invisible.
- **Failing scenario:**
  1. An overnight network scan runs while App Support is not writable or the disk is full.
  2. The console and catalog.log say the scan is resumable.
  3. After a crash there is no checkpoint, and the resume affordance never appears.
- **Smallest pinning test:** make `save` return `Bool` (or throw), and pin "a save into an unwritable directory returns false and the caller does not log 'Checkpoint saved'". This needs a directory seam; today `directory` is a static on the user's real App Support (an isolation-checklist gap in its own right: tests at ScanMergeScopeTests.swift:484/722/768 write into it).

### N1010-H-Volumes-F6: the UI offers Delete from list for System-tagged volumes; the model silently refuses
- **Severity:** P3. **Class:** REAL.
- **Symbol:** `VideoScanModel.deleteScanTarget`, VideoScanModel+DeleteScanTarget.swift:42 (refuses `role == .system`) vs `VolumesWindow` context menu, VolumesWindow.swift:645-664. Its comment says `.system` is "a user policy tag … does not gate this action", and only disables `/`.
- **Failing scenario:**
  1. The user tags `/Volumes/X` as System.
  2. Delete from list… is enabled. The user confirms the red Delete button.
  3. Nothing happens apart from a log line "is the system volume". The two layers have opposite contracts; Rick should pick one.
- **Smallest pinning test (fails today against the UI's stated contract):** target `/Volumes/X` with `role = .system` → `#expect(model.deleteScanTarget(t) == true)`. Or, if the model's rule wins, a view-model test that the menu item is disabled for `.system`.

### N1010-H-Volumes-F7: in Rescue copy, rsync's stderr is read only after `waitUntilExit`
- **Severity:** P3. **Class:** NOISE.
- **Symbol:** VolumeCompare.swift:465-500.
- **Why NOISE:** A child that writes more than the pipe buffer (about 64 KB) to stderr would block and deadlock. A single-file rsync practically never writes that much. The `--partial` truncated-at-final-name issue in the same block is already documented in place (reported 2026-09-13), so it is not re-filed here.

## Guards checked that held
- **Retire never removes records.** `retireVolume`/`reinstateVolume` only set or clear the three retire fields. `persistScanDates` → `persistMetadata` writes `retiredAt`/`retiredReason`/`retiredWitnesses` (ScanTargetPersistence.swift:252-281). Reinstate is a full reversal and logs it.
- **Retired volumes cannot be rescanned or resumed**, which would destroy the Bucket-E witness records: `startTarget` (ScanLifecycle:31), `resumeTarget` (ScanExecution:585), `startAllTargets` (skips retired).
- **Record removal is id-exact and plan-carrying** (`TargetRemovalPlan.recordIDs`). `applyTargetRemoval` checks, in order: plan target id == object id; the object is still the registered instance (codex #1431, so a stale object cannot delete orphans); root unchanged; revision unchanged, or else a re-plan with an identical id set. Otherwise it refuses with `.refusedStale`/`.cancelledTargetGone`.
- **Coverage check.** Records under another registered target's root (nested or parent, retired included) are never removed (`TargetRemovalScope.claimsNormalized`).
- **Snapshot before more than 50 removals, fail-safe degrade.** `snapshotCatalog` returns nil on failure, and nil means nothing is removed (DeleteScanTarget:295-308). The snapshot is written from memory, not by copying the file.
- **Offline volume / different disk at the same path, for record removal.** Target removal is a catalog-only operation keyed by path string; it never touches the disk, so what is mounted does not matter. For scan-merge pruning: vanished records are existence-checked off-actor, nothing is pruned if the root is unreachable at merge time, and the mass-removal tripwire (more than 50 and more than 20%) snapshots first and degrades to no prune if the snapshot fails. A different disk mounted under the same name would therefore prune behind a snapshot, recoverably. No volume-UUID check guards a scan merge; noted under "Not covered", not filed.
- **`deleteScanTarget` keeps records.** It only rewrites the target list and the per-path dictionaries. It refuses `/`.
- **Checkpoints:** written atomically (`.atomic`); extra fields decode with `decodeIfPresent`; a cancelled or partial scan keeps the checkpoint; a checkpoint is written only after a complete, non-aborted walk; `walkHadEnumerationErrors` carries over so a resumed scan never prunes; resume re-verifies the full list (no "minus cataloged" shrink); preservation snapshot taken on resume.
- **Double start/resume refused** (`status.isActive` guard in both).
- **Mount-table static** `mountedRoots` is accessed under `mountedRootsLock`, and `getmntinfo` is serialized by `getmntinfoLock`.
- **No `try!`, `as!` or `.first!`** anywhere in `Volumes/`.

## Not covered
- **Scan-merge identity:** no volume-UUID check before a complete-scan prune. A different disk mounted under the same name prunes the old disk's records behind a pre-merge snapshot. It is recoverable, so not filed; worth a decision on whether the snapshot alone is enough.
- A stale checkpoint left behind by `deleteScanTarget` when the same path is added again later (resume of a weeks-old list); not traced through `runProbeChild`'s handling of missing files.
- `ScanCheckpoint.directory` is a non-injectable static on the user's real App Support, which blocks the F1/F5 tests and breaks the isolation dimension of the checklist. Needs a seam.
- Not read beyond a grep: `VolumeReachability` (the stat-on-main question; `isNetworkVolume` calls `statfs` directly and its callers were not traced), `FilesystemWalker`, `ScanEngine`, `MemoryPressure`, `DriveHealth`, the `VolumeRenameMigration`/`RoleMigration` files, `VolumeCompare` outside the copy loop, and all view files for O(records) work in view bodies.
- The `RelocateRetireSheet` (MediaOps) commit path, which is outside the brief's folder: whether retire re-checks eligibility at confirm time. Retire itself is non-destructive, but it is the gate into the cleanup nag.
- No build or tests could be run (Linux cloud session).
