Brief: N1017-H-Archive | Source: main@fa4a5dc | Wall clock: ~30 | Files read: 10
Finding count: 2 (REAL 1 / NEEDS-MAC 1 / NOISE 0)
Verdict: The Archive jobs this pass covered (Verify Archive Copies, Bind Fixity to Volume, the lock catch-up, the mount re-resolution) handle errors carefully and write compare-and-set. One gap: a designation with no recorded volume UUID protects the archive by path spelling alone, so the real archive mounted under another name is unprotected for deletes.

## Scope and method

**Theme H over `VideoScan/VideoScan/Archive/`.** This pass was weighted to the files earlier passes did not read. C02 covered the promote write path. N1008 covered the tests. The 10/7 batch (`b83405e1`, `c313f32a`) fixed or pinned their findings.

**Read:**
- `VerifyArchiveCopiesJob` (verify loop, match / mismatch / missing writers, compare-and-set fixity writes)
- `FixityRebind` and `BindFixityToVolumeJob` (record, persist, undo)
- `ArchiveLockJob` (outline)
- `VideoScanModel+MasterArchive` (identity refusal, `reresolveMasterArchiveMount`)
- `ArchiveVolumeProtection` (`provisionalIgnoringPending`, `verdictAtRemoval`)
- `VideoScanModel+BackupAttestations` (outline)

**Callees followed:**
- `VideoScanModel.pruneArchiveVerdict` (MediaOps/VideoScanModel+PruneVerification.swift:121-163)
- Delete Duplicates' use of the keeper's `contentFixity` (MediaOps/DeleteDuplicatesJob.swift:986, 1074)
- `noteCatalogRecordsMutated` (MediaOps/VideoScanModel+SoftDelete.swift:56)

**Sweeps run over the folder:**
- `try!` and force-unwraps: one dictionary unwrap, `CopyFamilyAssessor.swift:551`, on a key taken from the same dictionary, so it is safe.
- `try?` on write paths: only the journal `abandoned` and `done` appends, which are by design (C02).
- `Process()`: none in `Archive/`.
- O(records) work in view bodies: none. The Archive tab's caches key on `records.count` + `volumeAggregatesRevision`, and in-place edits bump the revision through `noteCatalogRecordsMutated`.

## Guards checked that held

- **Verify Archive Copies:**
  - A read-only viewer is refused.
  - Every fixity write is compare-and-set against the digest the plan saw (`liveRecordForFixityWrite`).
  - A volume yanked mid-run gives "no verdict" and stops; nothing is cleared.
  - A mismatch or a missing file clears **both** `archiveFixity` and `contentFixity` and never writes one.
  - A catalog path containing `.` or `..` is refused before any byte is read.
  - The general fixity is written only with a stamp taken before the read that the after-read stamp reproduces.
- **Bind Fixity to Volume:**
  - Everything goes through one descriptor (`O_NONBLOCK` open, regular file only).
  - The before stamp must equal the after stamp, down to volume UUID and nanosecond ctime.
  - The bytes hashed must equal the file size.
  - The catalog write is compare-and-set.
  - If the catalog save is not acknowledged, the bindings are undone compare-and-set and the files are re-read on the next run.
- **Prune's archive evidence:** a stored stamp is trusted only when `stored.digest == archiveFixity.digest` (PruneVerification.swift:135). A re-bound digest of changed bytes (see F2) therefore forces a full read, which then refuses. This settles C05-F1's corollary for the rebind path.
- **Delete Duplicates:** a keeper whose `contentFixity` describes changed bytes cannot vouch for a good candidate; the digests differ, so nothing is deleted.
- **Lock catch-up:** each lock change runs under the index lock with `wait: .zero` and refuses when busy. There is no unlock path (`ArchiveFileLock.Reason.mayUnlock`).
- **Mount re-resolution:** when the designation carries a UUID, a different disk at the same path is a hard refusal for every write path, and the real volume is found by UUID and re-homed.

## Status of earlier Archive findings (not re-counted)

| Finding | Status on main@fa4a5dc |
|---|---|
| C02-F1: two concurrent Promote jobs; the second job's reconcile acts on the first's in-flight entries | **Open.** `reconcileJournal` still never consults the Center's active jobs. `startPromote` still refuses only overlapping record sets. |
| C02-F2: a short write leaves a torn index tail, and the next append is glued onto it | **Open.** `appendDurable` neither checks for a trailing newline nor truncates on a short write. |
| N1008-F1…F9 | Pinned in `c313f32a` (the commit message lists each, shown red by mutation). |

## Findings

### N1017-H-Archive-F1 — P2 · NEEDS-MAC · A Master Archive designation with no volume UUID is protected by path spelling only; the real archive mounted under another name is open to deletes
- **Symbols:**
  - `ArchiveVolumeProtection.provisionalIgnoringPending` — Archive/ArchiveVolumeProtection.swift:371-376. Its comment: "No UUID: the path is the whole identity".
  - `ArchiveVolumeProtection.verdictAtRemoval` — :456 (`guard let uuid = expectedUUID else { return .clear }`).
  - `VideoScanModel.masterArchiveIdentityRefusal` — Archive/VideoScanModel+MasterArchive.swift:290-292 (no UUID means identity is OK).
  - `VideoScanModel.reresolveMasterArchiveMount` — :312 (no UUID means no re-home).
- **When a designation lacks a UUID:**
  - it predates UUID capture (codex QA R1) and was never re-initialized; or
  - Initialize ran on a volume that reports no `volumeUUIDString`.
- **No backfill:** a grep found nothing that stamps a UUID onto an existing designation, even when its root is reachable.
- **Scenario:**
  1. The designation is `/Volumes/RAID/<archive>` with `volumeUUID == nil`.
  2. The RAID next mounts as `/Volumes/RAID 1`. macOS adds the suffix when a stale `/Volumes/RAID` directory exists, or when another disk with the same name is already mounted.
  3. The archive-tree check protects only the spelling `/Volumes/RAID/…`, so the archive's own files at `/Volumes/RAID 1/<archive>/…` pass `bulkDeleteRefusal` as ordinary files.
  4. A Delete Duplicates or prune run that reaches them (for example after a rescan catalogues that path) can Trash archive files.
  5. At the same time, a different disk named "RAID" at the old path is accepted as the archive by `masterArchiveIdentityRefusal`, so Promote writes there.
- **Why NEEDS-MAC:**
  - The severity depends on whether the real catalog's `masterArchive.volumeUUID` is set. If it is nil, this is a P1.
  - The RAID mount-name suffix behaviour also needs confirming on the Mac.
- **Check on the Mac:** read `catalog.json` and confirm `masterArchive.volumeUUID` is non-empty.
- **Pinning test:**
  1. Install a designation with `volumeUUID: nil` and a reachable root, using the task-local UUID probe seam.
  2. Call `reresolveMasterArchiveMount()`.
  3. Expect the designation to gain the probed UUID and the catalog to be marked for saving. Today it is unchanged.
  4. Second test: with a nil-UUID designation, `verdictAtRemoval` for a path under an alternate mount whose probe returns the archive's UUID should not be `.clear`. Today it is `.clear`.
- **Fix direction:**
  - At load and on mount, when the root is reachable and the designation has no UUID, capture it once and save.
  - At Initialize, refuse (or warn loudly) when the volume reports no UUID.

### N1017-H-Archive-F2 — P3 · REAL · Bind Fixity to Volume treats an archive file whose bytes changed as routine and stores the new digest; Verify Archive calls the same evidence possible corruption
- **Symbols:**
  - `VideoScanModel.applyFixityRebind` — Archive/FixityRebind.swift:173-179 (`.digestChanged` writes the new `contentFixity`).
  - `BindFixityToVolumeJob.persist` — Archive/BindFixityToVolumeJob.swift:275-281: one warning line, "stored the digest it holds now".
  - Contrast `VerifyArchiveCopiesJob.flagMismatch` (:780-808): "POSSIBLE CORRUPTION … check this file by hand", fixity **cleared**.
- **Scenario:**
  1. A Bind Fixity run scoped to the archive volume re-reads an archive file whose bytes no longer match its old `contentFixity`, for example after silent corruption.
  2. The job stores the new digest with a fresh volume-bound stamp, counts it as "bound", and logs a ⚠️ line.
  3. `archiveFixity` (the manifest-matching digest) stays, so the record now carries two disagreeing digests.
  4. The UI shows the copy as fixity-bound; nothing tells Rick to run Verify or to check the file.
- **Why only P3:** no delete follows from it. Prune and Delete Duplicates compare digests (see "Guards checked that held"), so the changed archive copy blocks its family rather than vouching for it. The cost is a missed alarm on the archive's own bytes, plus a "verified" look on a copy that just failed.
- **Pinning test:**
  1. A record whose `archiveFixity.digest == X` and whose legacy `contentFixity.digest == X`.
  2. The file's bytes now hash to Y.
  3. Run `applyFixityRebind`. Expect it to refuse to bind, or to report `.archiveMismatch` and leave `contentFixity` alone (or clear it, as Verify does).
  4. Expect the job summary to carry a "POSSIBLE CORRUPTION — run Verify Archive Copies" line. Today the result is `.digestChanged`, the new digest is stored, and the summary is routine.
- **Fix direction:** for records under the archive root, or with an `archiveFixity`, treat a changed digest the way Verify does: no bind, a loud outcome, and a pointer to Verify Archive Copies.

## Not covered
- **Not read:** `ArchiveRefile` and `ArchiveIndexRename` (C02 subagent, 10/5), `ArchivedWhatNextSheet`, `PromoteToArchiveSheet`, `ArchiveView*` (UI, outside H's write-path focus), `CopyFamilyAssessor` (N1006 planned it), `ReadOnlyVolumeProtection` beyond its use in removal checks, and the attestation journal internals.
- **Not swept:** cancellation latency in `ArchiveLockJob` beyond the outline (it polls cancel and pause between files).
- Nothing was built or run.
