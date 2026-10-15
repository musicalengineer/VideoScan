# Codex review — Cleanup archive-covered lane

- Range: `12a9f5ee0..4c172ac21`
- Credits spent: unavailable
- Tokens: 107364
- Finding count: 3
- Verdict: fix — the full-read proof holds, but archive protection has gaps under the requested stale/corrupted-plan cases.
- Run: 2026-10-15T18:10:32Z (cycle #74, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3

Verdict: fix — the full-read proof holds, but archive protection has gaps under the requested stale/corrupted-plan cases.

References below are at `4c172ac21`. These are source-level reproductions; tests were not rerun and no files were written.

1. **P1 — A promoted archive file can pass as a target when the archive designation is absent (invariant 1).** [CleanupTrashJob.swift:598](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/Cleanup/CleanupTrashJob.swift:598) checks the target’s identity, path and pair status, but never rejects `isArchiveCopy(rec)`. The archive predicate at line 609 applies only to the keeper. The shared gate does not supply unconditional protection: [VideoScanModel+MasterArchive.swift:784](/Users/rickb/dev/VideoScan/VideoScan/Archive/VideoScanModel+MasterArchive.swift:784) protects promoted copies only when `masterArchive != nil`.

   **Failure scenario:** With no current archive designation, supply a corrupted covered entry targeting promoted file T outside an archive-named folder, with distinct, byte-identical promoted keeper K correctly reserved and flagged; selection, catalog authorization and full proof all permit T.

   Add an unconditional archive-target refusal to Cleanup’s catalog guard. The current corrupted-plan tests cover keeper-as-target, but not a different promoted archive file as target.

2. **P2 — An unusable archive member permits non-archive keeper election (invariants 2–3):** [CleanupPlan.swift:480](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/Cleanup/CleanupPlan.swift:480) searches only the filtered physical members; give archive member M `.missing` or `.sizeChanged` and two usable, differently ranked siblings, and the fallback at line 492 schedules a plain copy without reading M.

3. **P2 — Archive status can change after authorization without invalidating the proof (invariants 2, 6):** [CleanupTrashJob.swift:427](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/Cleanup/CleanupTrashJob.swift:427) checks the catalog before the reads; clear an off-root promoted keeper’s `derivationKind` through `betweenReadsForTesting` on the main actor, and unchanged filesystem identity, paths and bytes still pass—there is no subsequent keeper catalog check.

The remaining reviewed protections hold within the scoped code:

- **Full reads:** [CleanupProof.swift:99](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/Cleanup/CleanupProof.swift:99) and line 108 read both files; equality and final keeper checks follow. No stat-only covered-copy path was found.
- **Exclusions:** Covered candidates call the same `copyExclusion` as ordinary copies. No finding against the plan-time exclusions in invariant 4.
- **Selection and waiver:** Lane-off and individual unticks exclude covered entries. Only `selection.archiveJunk` supplies waiver IDs; invariant 5 holds.
- **Filesystem changes:** The keeper exemption retains real-path, Trash, identity and post-read ancestry checks. Finding 3 concerns catalog state, not a demonstrated filesystem replacement bypass.
- **Ordinary election:** The ranked election and tie refusal remain unchanged when no archive member participates.

`VideoScanModel+Cleanup.swift`, `CleanupPane.swift`, the specified design paragraph, and the new/extended tests and fixture: read, no additional findings.

## Brief

# Codex brief: Cleanup — "Copies the archive already holds" (data-risk)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~900 words.

**One sentence (Rick, 2026-10-14):** move to the Trash every copy, outside the archive, of a file the Master Archive already holds — the archived file stays, and is read in full to prove it.

**Why it matters:** Rick's 2 TB goal. On his catalog (10/15, by stored full SHA-256 + size) 54 files / 1.11 TB outside the archive are byte-identical to an archived file — mostly promoted VHS captures of 60–73 GB on MediaExpansion, LaCie, CrucialX10 and SanDisk. Until this change Cleanup left every one of them out as "already archived — Archive's own lane handles it".

**Range:** `12a9f5ee0..4c172ac21` on branch `feature/cleanup-archive-covered-lane` (one commit). Read files with `git show 4c172ac21:<path>`. Paths under `VideoScan/VideoScan/` unless noted.
- `MediaOps/Cleanup/CleanupPlan.swift` — `CleanupRow.isArchiveFile` (was `isArchived`: "the archive holds this content"; now "this file IS the archive's": a promoted copy or inside the archive root); `CleanupPlan.archiveCovered`, `archiveCoveredBytes`; `Copy.keeperIsArchiveFile`; `CleanupPlanner.planGroup` — the archive-file member becomes the keeper (whatever the volume rank says), other usable members go through `copyExclusion` and into `archiveCovered`; a second archive file is left alone (`.archived`); the ranked election below is unchanged for groups with no archive file.
- `MediaOps/Cleanup/VideoScanModel+Cleanup.swift` — `cleanupInputs()`: `isArchiveFile: isArchiveCopy(r) || isInsideMasterArchive(path:)`.
- `MediaOps/Cleanup/CleanupProof.swift` — `ancestryProblem(path:archiveFileExpected:)`: the by-name "inside the Master Archive folder now" refusal is skipped for the keeper of a covered copy (the plan chose it there); kept for every target and every plain copy's keeper; `verifyCopy` passes the flag at both ancestry checks.
- `MediaOps/Cleanup/CleanupTrashJob.swift` — `CleanupSelection`: `archiveCovered`, `allCopies`, `includeArchiveCovered`; keepers of both lanes reserved; a covered copy whose keeper is not flagged is dropped; `cleanupCopyCatalogProblem`: a covered copy's keeper must still be `isArchiveCopy || isInsideMasterArchive` at the move; the run treats `allCopies` as one lane (`.copy`, `.duplicate`).
- `Catalog/CleanupPane.swift` — the third lane row, tick box, See files…, confirm-sheet line.
- Reference, read-only: `MediaOps/Cleanup/CleanupProof.swift` (the rest), `Archive/VideoScanModel+MasterArchive.swift` (`isArchiveCopy`, `isInsideMasterArchive`, `archivedCopy(of:)`), `docs/design/cleanup_kiss_2026_10_12.md` (the "2026-10-15 — the fold" paragraph).
- Tests: `VideoScan/VideoScanTests/CleanupTrashPlanTests.swift` (7 new/extended, incl. the 2,000-random-catalog invariant), `CleanupTrashRunTests.swift` (`archiveCoveredCopyMoves`, `archiveCoveredKeeperNoLongerArchived`), fixture `CleanupTrashTestSupport.swift`. 83 tests green in the five Cleanup suites (Debug); boundary/source sensors green.

**Invariants to attack (prove with file:line or say it holds):**
1. A file of the Master Archive — a promoted copy (`derivationKind == ArchivePromotion.derivationKind`), anything inside the archive root, anything on the FamilyArchive volume — is never a target: not from the planner, not through a tick, not through a corrupted or stale plan, not through a path spelled differently (case, symlinked folder, hard link, `/./`).
2. Every archive-covered target's keeper is an archive file in the SAME (digest, size) group, reserved for the whole run, still the archive's file at the move (catalog predicate), and read in full before the move; the target is read in full and must equal it (`CleanupProof.verifyCopy`). No stat-only path exists.
3. A group with an archive file in it never elects a non-archive keeper; with no archive file, the v1 ranked election (and its tie refusal) is unchanged.
4. Every Copies exclusion still holds for covered copies: FamilyArchive volume / archive tree (protection), A/V pair halves, Avid MediaFiles, app libraries, Rick's hand marks, a path through a linked folder, two rows naming one physical file.
5. The lane's tick box off, or a file unticked, keeps it out of the frozen selection; the lane never widens the FamilyArchive-junk waiver or the Delete Junk door.
6. Skipping the by-name archive refusal for a covered copy's keeper opens no hole: name a sequence of filesystem or catalog changes between plan and move that moves or replaces an archived keeper and is NOT caught by `plannedFileProblem`, the real-place check, `cleanupCopyCatalogProblem`, or the full reads.

**Do only this:** findings against 1–6 (P1 first), each with file:line and a one-line failure scenario; then at most three P2/P3 one-liners. Known and out of scope (not findings): Archive ▸ Excess copies (untouched, its own proof); the engine (`deleteConfirmedJunk`, #143) and `CleanupProof.read`; the page's wording; the dup keeper precedence settings.

**Do not explore outside the files listed above and their tests.**

## Closure

On main, straight after the merge (983896fee); Debug: 85 tests in the five Cleanup suites green.

| Finding | Closure | Pinning test |
|---|---|---|
| P1 a promoted archive file can pass as a target when no archive is designated | fixed: `cleanupCopyCatalogProblem` refuses the TARGET unconditionally when it is a promoted copy, inside the designated root, or in an archive root folder by name — "is a file of the Master Archive — nothing moved" | `CleanupTrashRunTests.promotedFileAsTargetHeld` ("codex 10/15 P1 …"): no designation, two promoted byte-identical files, a corrupted plan names one as target → held |
| P2 an unusable archive member lets the group elect a non-archive keeper | fixed: `planGroup` leaves the whole group alone (`CleanupExclusion.archiveCopyUnavailable`, "its archived copy can't be read now …") whenever a row of the group is an archive file and no archive member is usable; `reservedSurvivors` stays empty | `CleanupTrashPlanTests.archiveFileUnusableLeavesGroupAlone` ("codex 10/15 P2 …"): drive off / missing / through a link / size changed |
| P2 archive status can change after authorization without invalidating the proof | **declined**: the catalog predicate is asked at `authorize` on the main actor immediately before the reads; the proof then pins the keeper by persistent identity (volume UUID + inode + size + mtime), full bytes and real-path ancestry, re-captured after the reads. No app path clears an archive copy's `derivationKind` (Promote writes it once; Update… touches name and date only). A main-actor hop inside the engine's synchronous disk turn would risk a deadlock for a race only a test seam can produce. Filed as a note on the engine's `RemovalStep` follow-up. | — |

## Closed

Closed by `e006fc804` at 2026-10-15T18:18:34Z. P1 fixed (archive file never a target, designation or not), P2 unusable-archive-member fixed (group left alone), P2 post-authorize catalog race declined with reason; 85 Cleanup tests
