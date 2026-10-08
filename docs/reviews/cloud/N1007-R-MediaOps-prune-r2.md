Brief: N1007-R-MediaOps-prune (second pass) | Source: main@b909249 | Wall clock: ~25 | Files read: 6
Finding count: 1 (REAL 1 / NEEDS-MAC 0 / NOISE 0)
Verdict: The fix for the first pass's P1 is sound at relocate time: witnesses must be live, on disk, and a different copy off the source drive, and they are proven again right before the apply. But nothing proves them again at **retire** time, which is the moment that disposes of the drive.

## Why a second pass
This row already ran on 10-06 (`N1007-R-MediaOps-prune.md`, on main; ledger: done, F1 P1 fixed under #287). Rick asked for it again on 10-08, so this pass reviews the **shipped fixes** on current main and does not repeat the first report. Diff reviewed: `c86b926..b909249` over `MediaOps/` and `Volumes/`.

**Read:**
- `RelocateReconcile.swift`: `ReconcileRecordInput.isLive`, `VideoRecord.isLiveRelocateWitness`, `witnessIsOnDisk`, `witnessIsOffTheSourceDrive`, `witnessIsNotTheSourceFile`, `safelyRedundantEntry`, `reproveSafelyRedundant`, `WitnessProof`.
- `VideoScanModel+Relocate.swift`: `reproveSafelyRedundantBeforeApply` and its call site at :333.
- `VideoScanModel+JunkDelete.swift`: `junkDeletionRefusedOnViewer`, `junkDeletionPreflight`.
- `RelocateEngine.swift`: unchanged since the first pass.
- `Volumes/VideoScanModel+RetireVolume.swift`: `retireVolume`, `reinstateVolume`.

## The first pass's findings on current main

| First pass | Status | Notes |
|---|---|---|
| F1 P1: Bucket E accepts trashed, removed or vanished witnesses | **Fixed at relocate time** | `isLive` excludes purged, trashed, deleted and `.manuallyDeleted` rows, so two drives can no longer vouch for each other. A safe witness must also pass `witnessIsOnDisk` (a regular file at the recorded size) and `witnessIsOffTheSourceDrive` (device and inode, symlinks followed, `DeviceID.from`). The re-proof runs immediately before the apply, and anything refused goes down the copy path. N1015 found the re-proof call itself unpinned (N1015-F1). |
| F5 P3: witness not checked for online or present at apply | **Fixed**, by the same on-disk probe. | |
| F2 P2: relocate's copy and match proofs use a head-and-tail digest | **Open.** | `RelocateEngine.runOne` still verifies with `partialMD5`. Buckets C, D and E still key on (size, partialMD5). The new on-disk probe checks size only, not content. |
| F3 P3: RelocateEngine's failure cleanup can delete a destination it did not create | **Open.** | `RelocateEngine.swift` is unchanged (`try? removeItem(atPath: job.destPath)` at :103). |
| F4 P3: an unguarded Trash batch stamps "already gone" when the drive leaves mid-batch | **Open.** | The JunkDelete change added the viewer refusal (C04-F5) and a preflight helper. Reachability is still asked once, before the off-main pass. |

**What holds in the fix, checked adversarially:**
- **The witness is the source file through a symlink, or through a case variant on case-insensitive APFS:** caught by device and inode.
- **The witness is on the source drive under another path:** caught by the same-device test against the source root.
- **The source drive is unmounted:** `stat(root)` fails, the witness is judged off the drive, and the presence probe still has to pass.
- **A witness that can't be stat'd:** the independence probe returns true, but presence fails, so the witness is refused. The combination is fail-closed.
- **A witness on the destination drive outside the destination root:** counted as independent, which is correct; it is a different drive.
- **Mutual vouching across two relocates:** closed. The first relocate marks its rows `.manuallyDeleted`, so those rows are not live for the second.

## Finding

### N1007-R-MediaOps-prune-r2-F1 — P2 · REAL · Retiring a volume does not re-prove the witnesses its relocate recorded, and Delete Duplicates can remove them in between
- **Symbols:**
  - `VideoScanModel.retireVolume(at:reason:witnesses:)` — Volumes/VideoScanModel+RetireVolume.swift:202-218. It stores `retiredWitnesses` and stamps `retiredAt`; there is no stat, no liveness check and no re-proof.
  - It is reached from the post-relocate offer (`RelocateRetireSheet`, "Retire <volume>") and at any later time from the Volumes window's context menu.
- **The guard that would make this false, and why it doesn't hold:**
  1. The relocate-time re-proof (`reproveSafelyRedundantBeforeApply`) runs before the records are marked. It does not run again when the drive is retired, which can be days later.
  2. In between, Delete Duplicates still treats a `.manuallyDeleted` row whose file is physically present as a live keeper and survivor (N1018-F1, confirmed 10-08). Its removal-boundary `recheck()` re-stats that file and finds it.
- **Scenario (each step is an ordinary action):**
  1. Relocate the ageing drive A. File X on A has a live, on-disk witness X′ on drive B. X goes to Bucket E: it is marked `.manuallyDeleted`, never copied, and still sits on A.
  2. Rick picks "Skip for now" on the retire offer.
  3. A week later, Delete Duplicates runs on B. Its duplicate group is {X on A, X′ on B}. X is on disk and read-verified, so it counts as a verified survivor. If the keeper election picks X, X′ goes to B's Trash.
  4. Rick retires A from the Volumes menu. Nothing checks that X′ is still there. The drive is disposed of. The only remaining copy is in B's Trash, and it is gone once that Trash is emptied.
- **Why P2, not P1:** it needs two independent actions in sequence, and the Trash keeps it recoverable until it is emptied. It is still the same "the last copy leaves with the drive" class as the first pass's P1.
- **Pinning test:**
  1. A model with drive targets A and B, and a record on A that is `.manuallyDeleted` with `retiredWitnesses`, or a Bucket E note, naming a witness path on B.
  2. Delete the witness file, or set its record's `purgedAt`.
  3. Call `retireVolume(at: A, …)`.
  4. Expect it to refuse (or return a list needing confirmation) that names the record whose witness is gone, with `retiredAt` still nil. Today it returns true and stamps `retiredAt`.
- **Fix direction:**
  - Before stamping `retiredAt`, re-run `RelocateReconcile.reproveSafelyRedundant` over the drive's `.manuallyDeleted` records, from the witnesses in their Bucket E note or `retiredWitnesses`.
  - List any record without a proven live witness and refuse to retire until it is copied or Rick explicitly accepts.
  - Fixing N1018-F1 (one shared "live copy" rule, so Delete Duplicates never counts a `.manuallyDeleted` row as a survivor) closes the other half.

## Not covered
- The purges, soft delete and trash selection code: unchanged since the first pass, which found them catalog-only and well guarded.
- PruneApply and PruneApplyJob: no diff in this range.
- `ReformatJob`, `CleanupFFmpegEngine` and `Combine*` changes in this range belong to N1014's scope.
- `PerceptualFingerprintBackfillJob` (new, 505 lines) is a read and analysis job, not a delete or relocate path, so it was not read.
- Nothing was built or run.
