# Codex brief: Audit Catalog tier 0 — round 3 (the closure of r2's four findings)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words. This is the last round before Rick runs the job on his real catalog (10,978 live rows, 111 of them under ~/Movies on the Data volume, the rest under /Volumes/<drive>); say plainly whether a false Missing mark is still reachable.

**One sentence:** check that every catalog row on a connected drive still points at its file, and mark the ones that are gone as Missing.

**Rounds 1–2:** `docs/reviews/codex/codex-review-audit-catalog-tier-0-freshness-2026-10-16.md`, `…-r2-2026-10-16.md` (each with a Closure section).

**Range:** `ef4f1be69..b9d1f144a` on `main` (the fix is `5769a6647`). Read with `git show b9d1f144a:<path>`. Paths under `VideoScan/VideoScan/`.
- `MediaOps/CatalogAuditPlan.swift` — `CatalogAuditMountIdentity.ofLaneRoot(_:)` (a /Volumes root must BE a mount point, else nil; "/" → the Data volume `/System/Volumes/Data` when it is its own mount, else "/"); `enum CatalogAuditDirectoryWalk` (`prove(directory:filename:root:readParentEntries:)`: `folders(of:below:)` refuses "."/".." and paths off the root → `openNearestExistingAncestor` walks up BY OPENING with `O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC` → `descend(&fd, through:)` one `openat` per remaining folder, `whatIsThere` (`fstatat` NOFOLLOW) before ENOENT/ENOTDIR counts → `statName` → `goneThrough(fd, …)` binds ENOENT to `of(fd:)` (`fstatfs`) and, under "/", `hasEntries(fd)` via `fdopendir` on a `dup`); `CatalogAuditProof.atTheMark` (walk first, then `expectedMount == on`, else drive-not-connected); `stubRule(missingFolders:parentHasEntries:)`; `CatalogAuditRowSnapshot` (+ `supersededByID`).
- `MediaOps/CatalogAuditJob.swift` — `laneRoot` seam, one `statfs` of the lane root per lane (`anchorOffMain`), the mount re-check, apply, save/undo.
- `MediaOps/VideoScanModel+CatalogAudit.swift` — `applyGone` (`.notProvable` → could not check), `markGone`, `CatalogAuditMark.revision`, `revertCatalogAuditMark`.
- `MediaOps/VideoScanModel+RemovalMarker.swift` — `stampRemoval` (bumps `removalRevision` only when the value changes), `clearRemoval` (bumps when a marker was there), `revertRemoval(_:wrote:previous:revision:mirrorsBefore:mirrorsAfter:)`.
- `VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecord.swift` (+ `VideoRecord+Codable.swift`, `VideoRecord+Clone.swift`), `VideoScan/VideoScan/Catalog/VideoRecordDTO.swift` (revision stored only when non-zero), `MediaOps/VideoScanModel+RescanPreservation.swift` (carries the revision with the marker).
- Tests: `VideoScan/VideoScanTests/CatalogAuditRound2Tests.swift` (13), `CatalogAuditJobTests.swift` (suites Logic / Scale / Isolation / Sensor / ProveAtTheMark; sensors `directoryHandleIsTheOnlyOpenAndOnlyInThePlan`, `expectProofAtTheMark`), `OneEngineSensorTests.onlyTheEngineBumpsTheRemovalRevision`.
- `docs/practices/invariants/MediaOps.md` MOPS-14 (rewritten).

**Attack (prove with file:line or say it holds):**
1. With the lane root's identity as the only expected identity: name a path under a MOUNTED `/Volumes/X` whose nearest existing ancestor is on X's filesystem but whose file lives elsewhere (a symlinked subfolder onto another drive that is unmounted; a firmlink; a nested mount under X that is unmounted and leaves a stub) — is it refused (link → not provable) or marked?
2. Under "/": is the Data-volume rule right on a Mac where `/Users` is relocated to another volume, or where the catalog path lives under a mounted DMG / network share mounted under $HOME? (Expected answer: identity mismatch → drive not connected, never a mark — confirm.)
3. The walk: a component that is a symlink to a DIRECTORY on the same filesystem in the REMAINDER (not the existing part) → refused; a hard-linked directory alias (APFS does not allow; HFS+ did) — any path where `openat … O_NOFOLLOW` succeeds on something that is not the cataloged folder? Any fd leak on an early return (every `open`/`openat`/`dup` paired with a close)? `readdir` on a `dup` of an fd whose offset was never read — fine, or does `fdopendir` take ownership and `closedir` close the original?
4. Revision: the DTO omits `removalRevision` when 0 — a row marked once (revision 1) and later restored (revision 2) round-trips as 2; a legacy row reads 0; is there any writer that COPIES a record (rescan preservation, clone, DTO) and drops the revision so a later rollback's ownership check passes falsely? `stampRemoval` not bumping on an identical re-stamp — can a door re-stamp an identical marker after the audit's mark and then a failed audit save undo the door's (identical) mark? (It is the same value; state the consequence.)
5. The window that is left: between the fd-bound ENOENT and `stampRemoval` on the main actor. Say whether it is now only "a file arrives after the observation" (acceptable, the next audit restores it) or anything else.

**Do only this:** findings against 1–5 (P1 first), each with file:line and a one-line failure scenario; then at most two P2/P3 one-liners. Out of scope: GH #323 (headless vs GUI), Fix Links, nightly wiring, the freshness model, wording, the declared limits in the r2 closure.

**Do not explore outside the files listed above and their tests.**
