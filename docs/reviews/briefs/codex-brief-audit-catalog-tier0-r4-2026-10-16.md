# Codex brief: Audit Catalog tier 0 — round 4 (the one rule: last seen on)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words. Say plainly whether a false Missing mark is still reachable; this decides whether Rick runs the job on his real catalog tonight.

**One sentence:** check that every catalog row on a connected drive still points at its file, and mark the ones that are gone as Missing.

**The rule now (r3 closure in `docs/reviews/codex/codex-review-audit-catalog-tier-0-r3-2026-10-16.md`):** a row is marked gone only when its folder is on the volume the file was LAST SEEN on. The audit stamps `VideoRecord.auditSeenOn {volumeUUID, mountFrom, seenAt}` for every row it finds present (identity read through the opened folder handle). A gone proof requires a stamp and `uuid(handle) == stamp.volumeUUID`. No stamp → `neverSeenByAnAudit` (Fix Links; never marked). No symlink anywhere in the path (`lstat` of every existing component). After the ENOENT, `fstat(fd)` dev+ino must equal `lstat(path)` dev+ino and be a directory. The lane-root identity rule and the "/" stub heuristics were removed.

**Range:** `b9d1f144a..572d74bb0` on `main` (the fix is `6140ea912`). Read with `git show 572d74bb0:<path>`. Paths under `VideoScan/VideoScan/`.
- `MediaOps/CatalogAuditPlan.swift` — `CatalogAuditMountIdentity` (+ `volumeUUID` via `VolumeIdentity.uuid(forDescriptor:)`), `CatalogAuditDirectoryWalk` (`linkInTheExistingPath`, `prove`, `descend`, `stillNames`, `goneThrough`, `seenOn(directory:filenames:root:now:)`), `CatalogAuditProof.atTheMark` / `onTheVolumeLastSeen`, `CatalogAuditResult.neverSeenByAnAudit`, `CatalogAuditRowSnapshot` (+ `auditSeenOn`).
- `MediaOps/CatalogAuditJob.swift` — `statOffMain(_:root:_:)` groups a chunk's present files by folder and calls `seenOn`; `CatalogAuditObservation`; `checkpointIfDue` (saves on ≥25 marks or 60 s; stamps flush at lane end / run end).
- `MediaOps/VideoScanModel+CatalogAudit.swift` — proof against the LIVE record's stamp; the ONE stamp write; `.neverSeenByAnAudit` handling.
- `VideoScan/VideoScanCore/Sources/VideoScanCore/AuditSeenOn.swift`, `VideoRecord.swift` (+ Codable, Clone), `Catalog/VideoRecordDTO.swift`, `Catalog/VideoScanModel+RescanPreservation.swift` (`carriesRemovalHistory`).
- Tests: `VideoScan/VideoScanTests/CatalogAuditRound2Tests.swift` (17), `CatalogAuditJobTests.swift` (sensors `expectProofAtTheMark`, `directoryHandleIsTheOnlyOpenAndOnlyInThePlan`), `RescanPreservationTests`.
- `docs/practices/invariants/MediaOps.md` MOPS-14.

**Attack (prove with file:line or say it holds):**
1. THE STAMP AS AUTHORITY: a stamp written in error becomes a licence to mark. Name a way a row gets a stamp for a volume its file is NOT on: the walk's `seenOn` on a folder reached through a link (should be refused), a stamp written for a `.notAFile` or a size-changed file, a stamp copied by rescan/clone/relocate onto a row whose path moved to another volume, a stamp surviving Relocate (move to another drive) so the next audit sees "different volume" forever or, worse, "same volume" after the drive letter is reused.
2. VOLUME UUID: two volumes with the SAME UUID (a cloned drive, a restored image, a DMG of a drive) — an unmounted original with its clone mounted at the same path: the clone's folder has the stamp's UUID; a file absent on the clone is marked. Is that acceptable (the clone IS the volume) or a hole? A volume whose UUID is unreadable through the handle but readable by path, or vice versa.
3. THE WINDOW: `lstat` pre-walk → `open` ancestor → `openat` descend → `fstatat` name → `fstat`/`lstat` post-check → main-actor compare-and-set → `stampRemoval`. Name any ordering of outside renames/mounts that yields ENOENT bound to the right UUID with the file present at the path at the moment of `stampRemoval`, other than the declared residual (replace-and-replace-back between two syscalls; a file arriving after the observation).
4. SNAPSHOT + LIVE: the proof reads the live record's stamp while the snapshot guard compares the planned stamp — can a stamp written by THIS run's earlier chunk (same row seen twice? a row planned twice under two lane roots?) make the guard drop or accept wrongly? Can two lanes stamp the same row?
5. SAVE/UNDO: stamps are not undone on a failed save, marks are — after a failed save the catalog in memory has stamps the disk does not; a crash then loses them (harmless) — but can an in-memory stamp from a failed save license a mark in the SAME run after the next successful save? (State it; probably acceptable.)
6. `neverSeenByAnAudit` counted as needs-a-decision: on Rick's first run every one of the ~135 gone rows lands there and the chip goes red. Is anything in that path a write? (Expected: none.)

**Do only this:** findings against 1–6 (P1 first), each with file:line and a one-line failure scenario; then at most two P2/P3 one-liners. Out of scope: GH #323, Fix Links, nightly wiring, the freshness model, wording, the declared residuals.

**Do not explore outside the files listed above and their tests.**
