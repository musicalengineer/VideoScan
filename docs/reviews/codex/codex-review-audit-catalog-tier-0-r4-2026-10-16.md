# Codex review — Audit Catalog tier 0 r4

- Range: `b9d1f144a..572d74bb0`
- Credits spent: unavailable
- Tokens: 107027
- Finding count: 2
- Verdict: fix — **a false Missing mark is still reachable.** A completely unstamped first run cannot add Missing marks, but it can persist incorrect authority for later runs.
- Run: 2026-10-16T21:34:10Z (cycle #82, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 2

Verdict: fix — **a false Missing mark is still reachable.** A completely unstamped first run cannot add Missing marks, but it can persist incorrect authority for later runs.

Reviewed `572d74bb0`; closure read from the workspace because it is absent at that revision. Reproductions are source-derived; tests were read, not executed. No files written.

1. **P1 — A clone’s UUID authorizes marking the original’s files Missing (attack 2).** [CatalogAuditPlan.swift:563](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:563) accepts UUID equality alone; `mountFrom`, device identity and filesystem identity do not distinguish the volumes.

   **Failure scenario:** audit original A, disconnect it, mount an older clone carrying A’s UUID at the same pathname; a file absent from the clone receives Missing although it remains on offline A.

   This is a hole under the stated connected-drive rule. Calling the clone “the volume” would require explicitly accepting that independently diverging copies share removal authority. Neither pathname validation nor the snapshot guard prevents it.

2. **P1 — The symlink pre-check does not protect stamp acquisition from a subsequent intermediate-link substitution (attack 1).** [CatalogAuditPlan.swift:381](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:381) checks components, then [line 427](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:427) opens the complete pathname. `O_NOFOLLOW` protects only its final component.

   **Failure scenario:** stat and pre-walk see `/Volumes/A/slot/sub/clip` on nested volume B; before open, B unmounts and `slot` becomes a symlink to an A folder containing another `sub/clip`; the audit stamps A. Afterward remove the link and restore an empty ordinary stub on A. The next audit marks B’s offline file Missing.

   The link remains throughout acquisition; this is **not** replace-and-replace-back between two syscalls. Furthermore, [seenOn:384](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:384) never checks that its held folder still names the pathname. The existing tests exercise pre-existing links and replacement during a **gone proof**, not this stamp-acquisition window.

The remaining checks:

- **Attack 1, ordinary cases:** `.notAFile` never writes a stamp. Size-changed regular files deliberately do ([model:175](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+CatalogAudit.swift:175)); this establishes location, not content identity. Clone preserves path and stamp; rescan matches by full path. However, [VideoRecord.swift:131](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecord.swift:131) does not invalidate the stamp on path changes. A retained A stamp after moving to B is refreshed when B’s file is found; otherwise it remains stale. Relocate’s clearing behavior cannot be certified without its excluded implementation.
- **Attack 2, unavailable UUID:** holds at this boundary. A nil handle UUID cannot authorize Missing; a readable pathname UUID does not override that refusal.
- **Attack 3:** with a valid stamp and distinct volume identities, the gone-proof post-check at [Plan:497](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditPlan.swift:497) closes the previously identified detached-directory window. No additional false-mark ordering found beyond the declared residuals.
- **Attack 4:** holds. Planning assigns each occurrence one lane; the synchronous [snapshot guard:104](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/VideoScanModel+CatalogAudit.swift:104) rejects a duplicate occurrence after its stamp changes.
- **Attack 5:** retained stamps can authorize a later run. There is **no subsequent successful audit save in the same failed run**: [Job:469](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CatalogAuditJob.swift:469) refuses further saves; pending marks are undone at conclusion.
- **Attack 6:** no row or stamp write in `neverSeenByAnAudit`. Logging and run-summary persistence still occur.

Core stamp/Codable/Clone/DTO, rescan preservation, job/model handling, relevant named tests/sensors and MOPS-14: read, no additional findings within scope.

## Brief

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


## Closure (Manager, 2026-10-16 — fix `6036a989e`, merged `a8feb5787`)

Both P1s closed RED FIRST (5 main-compatible pins red, 15 issues; then 146 tests in 12 suites green, Debug).

1. **F1 clone with the same volume UUID — closed.** `AuditSeenOn.deviceKey` (Delete Duplicates' physical-device key, `DuplicateDrives.physicalDeviceKey`, read from the handle's `fstatfs` mount-from; nil for shares, disk images and unknown devices). `CatalogAuditProof.onTheDriveLastSeen`: a stamp with a key requires the handle's key equal ("the same volume name on a different drive — a clone? not marked"; an undescribable drive → not provable); a stamp without a key proves by volume UUID alone (declared: a share's clone is the share). Pins: `cloneOnAnotherDriveWithTheSameVolumeUUIDIsNeverGone`, `theStampNamesTheDriveAndProvesByTheVolumeAloneWithoutOne`. Residual (declared): two identical enclosures on one port share a device path; a GPT whole-disk GUID would close it (follow-up).
2. **F2 link substituted between the walk and the open — closed, and found worse:** the gone proof's own post-check used `lstat(path)`, which FOLLOWS intermediate links, so a handle reached through a substituted link passed and MARKED (pin `linkSubstitutedBetweenTheWalkAndTheOpenNeverMarks` was red). `boundToItsPath(root:folders:path:fd:)` = the lexical link walk AGAIN + `stillNames`, called right after the open in BOTH `prove` and `seenOn`, before any identity read or name lookup. Pins: `linkSubstitutedBetweenTheWalkAndTheOpenWritesNoStamp`, `folderReplacedBetweenTheOpenAndTheNameReadWritesNoStamp`.
3. **D10 path change clears the stamp — added.** `VideoRecord.fullPath.didSet` clears `auditSeenOn` when the folder changes (a same-folder rename keeps it); a volume-rename migration therefore costs one run before marks there. Pin `aPathChangeClearsTheStamp` (its third case — a row moved in the catalog to a place its file is not — was MARKED on main).

Noted for QA, not touched: `DeleteDuplicatesSiblingProof.swift` and Check Copies open by pathname and trust the fd for the FILE (a different contract) — the intermediate-link blind spot of `O_NOFOLLOW` deserves a look there (GH issue filed).

Round 5 brief: `docs/reviews/briefs/codex-brief-audit-catalog-tier0-r5-2026-10-16.md`.

## Closed

Closed by `a8feb5787` at 2026-10-16T21:58:53Z. 2 P1 + D10 closed red-first; r5 running
