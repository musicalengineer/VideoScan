# Codex brief: one removal marker + one Trash engine (#143), round 1

**Answer contract.** The first line must be `Credits spent: <amount> | Finding count: <N>`. Include a line `Verdict: <merge | fix | block> …`. Write no files; answer only. Stay under about 1,200 words.

**Why this matters:** Rick's new Triage ▸ Cleanup page (`docs/design/cleanup_kiss_2026_10_12.md`, which you reviewed today) is built on this engine. A miss here costs family media.

**Range:** `1f1f39e74..b71331f32` (branch `worktree-agent-aa187de849c116158`; read it with `git show b71331f32:<path>` and `git diff 1f1f39e74 b71331f32 -- <path>`). The design note is on the branch at `docs/design/one_removal_marker_and_trash_engine.md`.

**Files in scope (paths under `VideoScan/`):**
- `VideoScan/MediaOps/VideoScanModel+RemovalMarker.swift`: the only writer of the marker (`stampRemoval`, `clearRemoval`)
- `VideoScan/MediaOps/MediaTrash.swift`: `MediaTrash.move`, the only media `trashItem` call
- `VideoScan/MediaOps/VideoScanModel+JunkDelete.swift`: `applyJunkOutcomes`, `perform`
- `VideoScan/MediaOps/VideoScanModel+Duplicates.swift`: `settleDeletedDuplicate`
- `VideoScan/MediaOps/SignatureVerification.swift`: `deleteQuarantined`
- `VideoScan/MediaOps/VideoScanModel+SoftDelete.swift`
- `VideoScan/Catalog/VideoScanModel+Workbench.swift`
- `VideoScan/Volumes/VideoScanModel+ScanMerge.swift`: `deriveScanMerge`, the hoist
- `VideoScanCore/Sources/VideoScanCore/RemovalMarker.swift`
- `VideoScanCore/Sources/VideoScanCore/VideoRecord.swift`: decode, `removal`, `purgedAt`
- `VideoScan/MediaOps/VideoScanModel+Relocate.swift`: `markSourceNotFound`

**Do not explore outside these files**, except their direct test files on the branch.

**Invariants to attack:**
1. A media file leaves only through `MediaTrash.move` to the Finder Trash. It is never unlinked, and the Trash is never emptied.
2. A held, failed, offline or cancelled file's row is never stamped as removed.
3. A row is never deleted when its file leaves.
4. The load-time conversion never newly hides a row that was visible. The one intended exception is rows carrying the old "Manually Deleted" label, about 968 rows, some on FamilyArchive.
5. A marker meant for a retained or replaced row is never written onto the live row (the snapshot path).
6. Restore never marks a row live while its file is still in the Trash.

**Evidence already run (Debug):**
- 5 new suites: OneEngineDoorCharacterization (8, green on base), RemovalMarkerMigration (9, 100k load in about 1.7 s), OneRemovalShape (7), OneEngineSensor (7), OneEngineMediaMatrixAndScale (6, covering mp4/h264, mov/prores, mkv/ffv1, mxf, avi/dv).
- 1,241 tests in 199 suites, 0 failures.
- T4 and the sensors were shown red on base before the change.

**Known and deliberately out of scope (not findings):**
- Delete Duplicates' per-file quarantine step is not yet inside the engine loop.
- Forget Volume still deletes rows, behind a confirm and a snapshot.
- A complete rescan still deletes active rows whose file is gone.

**Output:** findings ranked:
- **P1:** could lose a file, or hide or misstate one.
- **P2:** wrong marker or count.
- **P3:** at most three, one line each.

For each finding, give the file:line, a concrete scenario, and the smallest fix.
