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
