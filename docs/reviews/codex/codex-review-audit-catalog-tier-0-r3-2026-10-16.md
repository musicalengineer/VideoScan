# Codex review — Audit Catalog tier 0 r3

- Range: `ef4f1be69..b9d1f144a`
- Credits spent: unavailable
- Tokens: 113406
- Finding count: 3
- Verdict: fix — **a false Missing mark is still reachable.** I would close the two P1s before running against the real catalog.
- Run: 2026-10-16T20:46:32Z (cycle #81, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3
Verdict: fix — **a false Missing mark is still reachable.** I would close the two P1s before running against the real catalog.

Review targets `b9d1f144a`; the r2 closure was read from the workspace because it is absent at that SHA. Reproductions below are source-derived. Tests were read, not executed; no files written.

1. **P1 — An unmounted nested volume passes the outer volume’s identity check (attack 1).** [CatalogAuditPlan.swift:508](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:508) accepts the handle’s identity when it matches the lane root, then unconditionally returns `.gone` outside `/`.

   **Failure scenario:** catalog `/Volumes/X/nested/clip.mov` while another filesystem is mounted at `nested`; unmount that filesystem while X stays mounted. The empty `nested` stub belongs to X, so its ENOENT matches X’s expected identity and the offline file becomes Missing—no race required.

   This is distinct from the accepted limit concerning an unmounted `/Volumes/X` itself. The root mount check cannot establish the historical filesystem of its descendants. Under `/`, a **nonempty** underlying mount-point directory similarly defeats the empty-directory heuristic.

2. **P1 — The opened ancestor can cease to represent the cataloged path before ENOENT is observed (attacks 3/5).** [CatalogAuditPlan.swift:384](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:384) opens a complete pathname; `O_NOFOLLOW` constrains its final component, allowing intermediate symlinks. [The final lookup:439](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:439) then uses that retained directory without validating its current relationship to the cataloged pathname.

   **Failure scenario:** `/Volumes/X/link/sub/clip.mov` initially resolves to `B/sub`, where the clip is absent; after the ancestor opens, retarget `link` to `A`, where `sub/clip.mov` exists, **before** `fstatat`. The old B handle reports ENOENT on X, and the present file becomes Missing.

   Thus the residual is **not only a file arriving after the observation**: the file can already exist at the cataloged path when the decisive lookup occurs. Ordinary directory replacement can likewise detach the retained handle from that pathname.

3. **P2 — Rescan drops revision-only history (attack 4):** [RescanPreservation.swift:276](/Users/rickb/dev/VideoScan/VideoScan/Catalog/VideoScanModel+RescanPreservation.swift:276) omits `removalRevision` from `isWorthRestoring`; mark → restore an otherwise plain row, then rescan, and [the snapshot filter:512](/Users/rickb/dev/VideoScan/VideoScan/Catalog/VideoScanModel+RescanPreservation.swift:512) discards its revision 2, leaving the fresh record at 0. This disproves unconditional preservation; it alone does not demonstrate a false rollback match, because ordinary rescans mint new IDs.

The remaining checks:

- **Attack 2 holds while the other volume remains mounted:** relocated `/Users`, a DMG, or a home-mounted share yields a different handle identity and cannot receive a Missing mark. A present file returns through `.notGone`; a refused symlink reports not provable rather than necessarily “drive not connected.”
- **Remainder symlinks are refused:** [descend:407](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:407) checks failed components with NOFOLLOW. A genuine directory hard link aliases the same directory; historical directory identity is not checked. No fd leak found: successful ancestor/openat handles close through replacement or defer; `closedir` owns the duplicate, not the original. Their shared offset is harmless here because it was unread.
- **DTO/clone/decoding hold:** revision 2 persists even with a nil marker; legacy JSON reads 0. An identical re-stamp leaves the revision unchanged, so failed-save rollback **can clear that identical marker**; it confers no new ownership.
- **Read, no additional findings:** `CatalogAuditJob.swift`, both model mutation files, the four Core record/DTO files, supersession snapshot handling, the named tests/sensors, and MOPS-14.

## Brief

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


## Closure (Manager, 2026-10-16 — fix `6140ea912`, merged `572d74bb0`)

All three closed RED FIRST (main-compatible probes red, then 149 tests in 14 suites green, Debug). The lane-root identity rule and both "/" stub heuristics are GONE, replaced by ONE rule:

**A row is marked gone only when its folder is on the volume the file was LAST SEEN on.** `VideoRecord.auditSeenOn {volumeUUID, mountFrom, seenAt}` (additive; DTO writes it only when present; clone and rescan preservation carry it) is written by the audit for every row it finds present / changed / came back — the identity is read through the opened folder handle (`VolumeIdentity.uuid(forDescriptor:)`, ATTR_VOL_UUID) and flushed on the 60 s clock / lane end / run end, never per row. `CatalogAuditProof.onTheVolumeLastSeen`: no stamp → `neverSeenByAnAudit` (needs a person — Fix Links; counted, never marked); a volume with no UUID → not provable; UUID ≠ stamp → "the folder is on a different volume than the file was last seen on — drive not connected?".

1. **F1 nested unmounted volume / stub — closed.** The stub is on a different volume than the stamp. Pins: `nestedVolumeUnmountedUnderALaneRootIsNeverGone` (under a lane root AND under "/"), `unstampedGoneRowIsNeverSeenByAnAudit`, `stampedGoneRowOnTheSameVolumeIsGone`, `presentRowsAreStampedAndTheStampRoundTrips`, `theSecondRunMarksWhatTheFirstCouldNot`, `stampsFlushOnTheClockNotPerRow`.
2. **F2 retargeted intermediate link / replaced folder — closed.** `linkInTheExistingPath`: every existing component is `lstat`ed, a link anywhere → not provable (no stamp is written through a link either); after the ENOENT, `stillNames(path, fd)`: `fstat(fd)` dev+ino == `lstat(path)` dev+ino and a directory, else "the folder changed under the audit". Test sandboxes use `realpath(3)` (Foundation's `resolvingSymlinksInPath` strips `/private` and is not a realpath). Pins: `linkInTheExistingPartOfThePathIsNeverProvable`, `folderReplacedUnderTheAuditIsNeverProvable` (via a `@TaskLocal` seam).
3. **F3 rescan drops the revision — closed.** `carriesRemovalHistory` (revision > 0 or a stamp) beside `isWorthRestoring`; pin `rescanKeepsTheRevision`.

Accepted, no change: an identical re-stamp leaves the revision unchanged, so a failed-save rollback clears that identical marker (the audit's own value). Declared residuals: a file arriving after the observation; a folder replaced and replaced back between two syscalls. Consequence for the first real run: it marks NOTHING — it stamps every present row and lists the gone rows as "never seen by an audit" for Fix Links; the second run can mark.

Round 4 brief: `docs/reviews/briefs/codex-brief-audit-catalog-tier0-r4-2026-10-16.md`.

## Closed

Closed by `572d74bb0` at 2026-10-16T21:34:10Z. 3/3 closed red-first; one rule (last seen on); r4 running
