Brief: N1007-R-MediaOps-prune | Source: main@c86b926 | Wall clock: ~35 | Files read: 13
Finding count: 5 (REAL 5 / NEEDS-MAC 0 / NOISE 0)
Verdict: The prune path ("Archived — what next?" → Trash) is heavily guarded and held up. One P1: Relocate's "safely redundant" bucket counts trashed, removed or vanished catalog records as live copies, then offers to retire the drive.

## Scope read

**Files (MediaOps):**
- `VideoScanModel+PruneApply` (header contract)
- `VideoScanModel+JunkDelete` (`deleteConfirmedJunk`, the one Trash routine)
- `VideoScanModel+TrashSelection` (caller only)
- `VideoScanModel+SoftDelete` (header)
- `VideoScanModel+NonVideoMediaPurge` (header: catalog-only)
- `RelocateEngine`
- `RelocateReconcile` (bucket classification)
- `VideoScanModel+Relocate` (reconcile call site, Bucket E apply)
- `VideoScanModel+RelocateQueue` (serial runner)
- `RelocateRetireSheet` (retire hand-off)

**Callees followed:**
- `FileHasher.partialMD5` (Shared/FileHasher.swift:66)
- the gap sensor `SegmentedHashTests.partialMD5AgreesWhereSegmentedDisagrees`
- `ReconcileRecordInput` / `VideoRecord.asReconcileInput`

`DeleteDuplicates*` and `SignatureVerification` were not re-reviewed (C01 territory). `PruneApplyJob` and `+PruneVerification` were read only as far as the PruneApply header's contract.

## Guards checked that held

- **Prune apply:**
  - The plan is recomputed when you press Apply.
  - Your checks are the truth: unchecked copies are never moved.
  - The archive copy is re-proven (stamp or a full read).
  - Each checked copy is verified byte for byte, except a version, which goes on provenance by design.
  - The proof travels to the mutation (`JunkDeletionGuard`: live-catalog authorization on main, then stat stamps immediately before `trashItem`).
  - Survivors (the unchecked copies) are re-stat'd immediately before each move.
  - A guarded file that has vanished is **refused**, not stamped "already gone".
- **`deleteConfirmedJunk`:**
  - Master Archive files are excluded up front.
  - Before each file's removal, the archive volume and Read-only volumes are asked again (fresh UUID probe) in the same synchronous stretch as the move.
  - An offline drive is never stamped.
  - A failed or refused file stays active.
  - The ledger gets lines only for files that actually left the disk.
- **Purges** (non-video, unrelated audio, cover-art music) and **soft delete** touch the catalog only; files on disk are never touched.
- **Relocate:**
  - Runs strictly one job at a time (`startNextQueuedJobIfIdle`).
  - The copy refuses an existing destination.
  - Bucket E needs a non-empty hash and a positive size, and at least one witness on a host that is neither retired nor marked unreliable.
  - Bucket E never touches the source file.

## Findings

### N1007-R-MediaOps-prune-F1 — P1 · REAL · Relocate's "safely redundant" bucket accepts trashed, removed or missing records as the safe copy, then offers to retire the drive
- **Symbols:**
  - `RelocateReconcile.reconcilePlan` — MediaOps/RelocateReconcile.swift:495-520 (witness index), :604-636 (Bucket E)
  - `VideoRecord.asReconcileInput` — :320-329
  - the witness set `records.map(\.asReconcileInput)` — MediaOps/VideoScanModel+Relocate.swift:283 (and RelocateSheet.swift:566 for the preview)
- **The guard that should exist and doesn't:**
  - `ReconcileRecordInput` carries only id, path, partialMD5, size and originalFullPath. It has no `purgedAt`, lifecycle stage or `archiveStage`, so `reconcilePlan` cannot exclude dead witnesses.
  - The call site passes the **whole** catalog. Purged rows stay in `records` (they are stamped in place, per #160, and shown under "Show removed").
  - Nothing stats the witness file before the record is marked `.manuallyDeleted` (VideoScanModel+Relocate.swift:392-405).
  - Nothing stats it before `RelocateRetireSheet` offers "Retire <volume>".
  - The only witness filter is host safety (not retired and not unreliable), which is a property of the drive, not of the file.
- **Scenario (each step is an ordinary use of the app):**
  1. A family file has a copy on drive A (ageing) and on drive B (healthy).
  2. Delete Duplicates (or ⌘⌫, or Remove from Catalog) keeps A's copy and trashes B's. B's record stays in the catalog with `purgedAt` set and lifecycle `.trashed`. The file sits in B's `.Trashes` or is already emptied.
  3. Later, Relocate runs on A with the default "skip dups on other volumes".
  4. Reconcile finds B's record: same (size, partialMD5), and B's host is not retired and not unreliable, so it counts as a **safe witness**.
  5. A's record goes to Bucket E: marked `.manuallyDeleted` with the note "safely redundant", never copied.
  6. The relocate ends by offering "Retire A". Rick retires A and discards the failing drive, which is the feature's stated purpose.
  7. The only remaining copy was the one in B's Trash.
- **Variants:**
  - The witness was soft-deleted (Remove from Catalog), or its file was moved or deleted outside the app since the last scan.
  - The witness is itself a record an earlier relocate marked `.manuallyDeleted` whose drive has not been stamped retired yet. Two drives can then vouch for each other.
- **Why P1:** the UI states the file is safe elsewhere; the action leaves no verified copy; and the next step it offers disposes of the last one.
- **Pinning test:** a `RelocateReconcileTests` case through `reconcile(records:allCatalogRecords:…)`:
  1. A source record on volume A.
  2. One witness record on volume B with the same size and partialMD5, and `purgedAt = Date()` / `lifecycleStage = .trashed`.
  3. A permissive safety resolver.
  4. Expect the source in `readyIDs`, not `safelyRedundant`. Today it lands in `safelyRedundant`.
  5. A second case: a witness with `archiveStage = .manuallyDeleted`.
- **Fix direction:**
  - Add the purge, lifecycle and archive-stage facts to `ReconcileRecordInput` and drop dead witnesses in the index loop.
  - At apply time (and again before the retire offer), require at least one safe witness whose file **exists now** at its recorded size, which needs a stat.

### N1007-R-MediaOps-prune-F2 — P2 · REAL · Every relocate "proof of same content" uses size plus a head-and-tail digest that cannot see the middle of the file
- **Symbols:**
  - `RelocateEngine.runOne` post-copy verify — MediaOps/RelocateEngine.swift:130-146
  - `RelocateReconcile.reconcilePlan` Bucket D adoption (:577-589), Bucket E witness key (:604-606), Bucket C move (:653-660)
  - all built on `FileHasher.partialMD5` (first and last 64 KB)
- **The repo already documents the gap:** `SegmentedHashTests.partialMD5AgreesWhereSegmentedDisagrees` pins exactly this blindness, and is why segmented hashing exists.
- **Scenario A (copy):**
  1. `copyItem` produces a destination whose middle is corrupted (a bad cable or RAM on a multi-hour copy from a failing drive).
  2. Size and head/tail match, so the result is `.success`, and the record is repointed to the corrupt copy.
  3. The source drive is then retired.
- **Scenario B (adoption):** a pre-copy at the planned destination with a damaged middle is adopted as "verified existing copy".
- **Scenario C (witness):** two different tape captures of equal length with identical container headers and black or silent tails. These are padded MXF/DV, the fixture shape in the sensor. Either can witness the other in Bucket E (compounds F1).
- **Pinning test:**
  1. Build two files that differ only in the middle (the sensor's construction).
  2. Run `RelocateEngine.runOne` whose copy step is replaced by writing file B to the destination (or call the verify helper directly with A's size and partialMD5).
  3. Expect `.salvageFailed(.hashMismatch)`. Today it is `.success`.
- **Fix direction:** verify the copy with a full-file digest computed while copying (the Promote engine already streams one), and key Bucket D/E on `segmentedHash` or a full digest when present.

### N1007-R-MediaOps-prune-F3 — P3 · REAL · The relocate copy writes straight to the final name, and its failure cleanup can delete a file it did not create
- **Symbol:** `RelocateEngine.runOne` — MediaOps/RelocateEngine.swift:64-108.
- **No partial file:**
  1. `copyItem` writes the final name directly; there is no partial-then-rename.
  2. A crash mid-copy leaves a truncated file under the real name.
  3. The next run refuses it ("destination already exists"), and reconcile will not adopt it (size differs). The record is stuck as salvage-failed until someone deletes the stub by hand.
- **Check-then-act gap:**
  1. The existence check (:64) and `copyItem` (:98) are separate steps.
  2. Suppose a file appears at the destination in between. Rick's Finder pre-copy is explicitly supported, per the reconcile header.
  3. Then `copyItem` throws "exists" and the catch does `try? removeItem(atPath: job.destPath)` (:103), deleting **that** file, possibly a complete pre-copy.
- **Impact:** the source is untouched, so no family file is lost. That is why this is P3.
- **Pinning test:**
  1. Inject a `FileManager` subclass whose `copyItem` creates the destination and then throws `NSFileWriteFileExistsError`.
  2. Expect the destination to still exist afterwards. Today it is removed.
- **Fix direction:** copy to a reserved partial (`PartialFileNaming`) and publish with `RENAME_EXCL`; on failure remove only the partial.

### N1007-R-MediaOps-prune-F4 — P3 · REAL · An unguarded Trash batch stamps "already gone" on files whose drive went away mid-batch
- **Symbol:** `VideoScanModel.deleteConfirmedJunk` — MediaOps/VideoScanModel+JunkDelete.swift:241-245 (reachability asked once, before the hop, from a cache with a 5-second lifetime) and :349-352 / :421-439 (a missing file is stamped `purgedAt` + `.trashed`).
- **Callers affected:** guarded callers (prune) are safe, because `beforeRemoval` refuses a vanished file first. The unguarded callers are ⌘⌫ (TrashSelection), the junk dialog and the row menu.
- **Scenario:**
  1. A large ⌘⌫ batch runs on a USB drive.
  2. The drive sleeps or is unplugged partway through.
  3. Every remaining `fileExists` returns false, so those rows are stamped trashed and hidden.
  4. The files are still on the drive, and the rows now feed F1's witness problem in reverse (a live file the catalog calls trashed).
- **Pinning test:** `deleteConfirmedJunk` with a guard-less call and a seam that makes the volume root unreachable after the first file. Expect the rest to be `skippedOffline`, not `alreadyMissing`.
- **Fix direction:** re-ask reachability of the file's volume root inside the per-file loop before taking the missing-file branch.

### N1007-R-MediaOps-prune-F5 — P3 · REAL · Bucket E's witness is never checked for being online or present when the relocate applies
- **Symbol:** `VideoScanModel.runRelocate` Bucket E apply — MediaOps/VideoScanModel+Relocate.swift:392-405.
- **What happens:** classification and apply are both catalog-only. A witness on a healthy, not-retired drive that is **not connected**, or whose file was moved since the last scan, still makes the record "safely redundant".
- **Relation to F1:** this is the general form of F1, separated because it holds even when the witness record is live. A stale scan is all it takes.
- **Pinning test:** a witness record whose path does not exist on disk. Expect the source to stay in `readyIDs`.
- **Fix direction:** the stat in F1's fix covers it.

## Not covered
- `DeleteDuplicates*`, `SignatureVerification` and `DeleteDuplicatesSiblingProof` (two-drive survivor rule): C01 and C04 own those.
- `PruneApplyJob` pause/cancel internals, and `+PruneVerification` read paths beyond the contract.
- `VideoScanModel+RepairLifecycle`, `RescueFileCopier`, `PartialFileNaming` internals, and the two output publishers.
- `RetireVolume` beyond one check (N1010 covers the rest): `retireVolume(at:reason:witnesses:)` (Volumes/VideoScanModel+RetireVolume.swift:202-212) only **stores** the witness list on the target (`retiredWitnesses`); it does not re-validate it. F1 stands at P1.
- Nothing was built or run.
