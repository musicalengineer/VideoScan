# Codex brief: Triage ▸ Cleanup v1, round 1

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~1,200 words.

**What this is.** The Cleanup page and job you reviewed as a design this morning (`docs/reviews/codex/codex-design-cleanup-kiss-2026-10-12.md`, your 7 findings; design `docs/design/cleanup_kiss_2026_10_12.md`, five v1 rules) is now built on the one-engine branch (#143, your two rounds; merged to main today). An in-house QA pass found no P1 and three P2s, all fixed. Rick runs this on his real archive next: ~867 copies, ~630 GB. A miss costs family media.

**Range:** branch `worktree-agent-aa316ffbf0a4f7b2f`, `main..e5d39127` (`git log main..e5d39127`; read files with `git show e5d39127:<path>`). Paths under `VideoScan/VideoScan/` unless noted.

**Files in scope:**
- `MediaOps/Cleanup/CleanupPlan.swift` — planner: groups by stored full SHA-256 + size; keeper = `DuplicateKeeperPolicy` among connected members; exclusions; frozen selection; physical-file index for aliases
- `MediaOps/Cleanup/CleanupDiskProbe.swift` — realpath / identity / mount-present seams
- `MediaOps/Cleanup/CleanupProof.swift` — the proof inside the engine's `beforeRemoval` hook: both files read in full, identity before/after, SHA-256 + length; junk re-check; `mountPresent`
- `MediaOps/Cleanup/CleanupTrashJob.swift` — the MFO job: batches (20 files or 40 GB), confirmed save per batch, Pause between files, Stop settles the rest as cancelled
- `MediaOps/Cleanup/VideoScanModel+Cleanup.swift`, `MediaOps/Cleanup/CleanupTrashJobDetailView.swift`
- `Catalog/CleanupPane.swift` — the page and `CleanupStore` (tick box for FamilyArchive junk, frozen on run, reset after)
- `MediaOps/VideoScanModel+JunkDelete.swift` — the ONE engine change: `JunkDeletionGuard.archiveVolumeJunkWaiver` (lifts only the "elsewhere on the Master Archive volume" refusal, only for listed junk rows, at all three gates; never for the archive tree, an unprovable drive, or a Read-only mark); plus `reportedRecord(_:turn:)` for your r2 P2
- `MediaOps/VideoScanModel+RemovalMarker.swift` (doorVerb table), `MediaOps/DeletionAudit.swift` (new receipt kind), `MediaOps/MediaFileOperations.swift` (new kind), `Catalog/TriageView.swift` (sidebar row only)
- Tests: `VideoScanTests/CleanupTrashPlanTests.swift`, `CleanupTrashRunTests.swift`, `CleanupTrashMediaMatrixTests.swift`, `CleanupTrashSensorTests.swift`, `CleanupTrashTestSupport.swift`

**Do not explore outside these files**, except to confirm what an engine function they call actually does (`deleteConfirmedJunk`, `MediaTrash.move`, `stampRemoval`, `FixityRebind.rehash`, `DuplicateKeeperPolicy`).

**Invariant to attack:** *No file goes to the Trash unless an identical copy provably stays, on a connected drive, outside the Trash, not itself removed in this run. FamilyArchive is never trimmed as a copy. A held, failed, offline or cancelled file's row is never stamped. Nothing is ever unlinked.*

**Check your own design findings landed (cite file:line or say what is open):**
1. fresh full read of BOTH files at each move, no stat-only shortcut;
2. one reserved survivor per group for the whole run, never in the removal set under any alias, keeper loss holds (never re-elects);
3. aliases skipped: same device+inode, hardlinks, symlink-traversing paths, case variants, two rows for one file; physical accounting;
4. junk is a separate lane with its own re-check; FamilyArchive junk only via the explicit tick box;
5. groups from full SHA-256 + size, not sampled hashes;
6. A/V halves and Avid MediaFiles excluded at execution, both lanes;
7. ties excluded; outcome report persists; "GB selected" wording.

**Then attack:**
- the waiver: any way it lifts protection for a non-listed row, a copy, a tree file (spelling/case/symlink of the archive root), or outlives the run;
- the batch checkpoint: can a crash between `MediaTrash.move` and the confirmed save leave moved files unstamped beyond one batch? Is the save awaited before the next batch starts?
- Pause/Stop/crash mid-proof: half-stamped batches, double-counted bytes, a cancelled file that was actually moved;
- the proof→trash window (file hashed at its path, then trashed without quarantine; Delete Duplicates quarantines first): state the exact exposure on a single-user archive and whether v1 may ship with it (#315 tracks the engine RemovalStep split);
- stale mount cache / device-number reuse after remount;
- the page: O(records) in view bodies? `model.records` read? state mutation during layout?
- tests that would pass with the proof removed; name missing cases.

**Evidence already run (Debug):** 173 tests in 21 suites green on the branch (4 Cleanup suites: plan 25+, run 16+, media matrix 5, sensors 6; plus 17 engine/Triage regression suites); media matrix moves real mp4/mov/mkv/mxf/avi to a test Trash and holds a one-byte-changed copy; a 2,000-catalog random sweep checks the keeper invariant; sensors: Cleanup code has no trashItem/removeItem/unlink/rename/moveItem/marker write/row delete.

**Output:** P1 (could trash the last good copy / wrong stamp / unlink) · P2 (wrong result, count, or UX that misleads) · P3 (≤3, one line each). Each with file:line, scenario, smallest fix. End with `Verdict:`.
