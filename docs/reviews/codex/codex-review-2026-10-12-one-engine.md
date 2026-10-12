# Codex review — One engine #143

- Range: `1f1f39e74..b71331f32`
- Credits spent: unavailable
- Tokens: 130572
- Finding count: 5
- Verdict: fix — Restore and asynchronous settlement can misstate live media; the verifier still contains an executable unlink path.
- Run: 2026-10-12T17:11:48Z (cycle #65, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 5

Verdict: fix — Restore and asynchronous settlement can misstate live media; the verifier still contains an executable unlink path.

References below are to **`b71331f32`**, with paths relative to `VideoScan/`. These are source-traced reproductions; I did not execute tests or write files. Credit usage is not exposed.

1. **P1 — The verifier still permits permanent removal.**  
   **`VideoScan/MediaOps/SignatureVerification.swift:754–759`**

   Given a valid quarantine ticket, `deleteQuarantined(ticket, disposal: .permanent)` directly calls `removeItem`. A `finalVerdict` returning `.proceed(.permanent)` also reaches it, even when the initial disposal is `.trash`. Neither route requires a test host or an injected removal operation.

   This is a **pre-existing execution path left intact**, rather than a newly introduced unlink. Changing the default closes only the omitted-argument route. The new sensor expressly allowlists the remaining implementation; it therefore does not establish invariant 1. The direct tests demonstrate that the DD worker normalizes legacy decisions, but that protection is outside this primitive.

   **Smallest fix:** normalize both initial and final disposal to Trash inside this function, or refuse permanent disposal and restore/retain the file. Move any test-only unlink implementation into the test target.

2. **P1 — Restore clears the authoritative marker while the file remains in Trash.**  
   **`VideoScan/MediaOps/VideoScanModel+RemovalMarker.swift:59–71`**; **`VideoScan/MediaOps/VideoScanModel+SoftDelete.swift:127–133`**

   Trash a file, leave it there, then call `restoreRecord`. `clearRemoval` sets `removal = nil` **before** checking the original path. Consequently `purgedAt` becomes nil, the Trash path is discarded, and `restoreRecord` reports success and records a restoration. Keeping `lifecycleStage == .trashed` does not preserve the new marker contract: nil now means live.

   After Finder Put Back, the instructed “Restore again” also fails: `restoreRecord` requires nonnil `purgedAt`, which the first attempt already cleared.

   **Smallest fix:** for an `inTrash` marker, validate restoration before clearing anything; return failure while the file remains absent. Propagate that result so callers do not log successful restoration. The existing `WorkbenchDiscardTrashFailureTests.swift:223` test explicitly expects premature un-purging and needs revision.

3. **P1 — Batch settlement can stamp a retained live row for a different path.**  
   **`VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:315–329`**; new asynchronous caller at **`VideoScan/Catalog/VideoScanModel+Workbench.swift:92`**

   The disk turn captures a pathname, but outcomes retain mutable `VideoRecord` references and are stamped only after the entire batch finishes.

   **Reproduction:** pause the injected Trash operation after it moves `A.mov`; on the main actor, repoint the same row to an existing `B.mov`; resume the operation. Settlement stamps the row now describing `B.mov` as removed, although only `A.mov` left. A deterministic engine test can also perform the path change in the `settled` callback before `applyJunkOutcomes`.

   The generic engine already had this weakness; converting Workbench Discard from synchronous to asynchronous introduces that exposure there. Unlike DD settlement, this path has no expected-path check or detached snapshot.

   **Smallest fix:** capture each turn’s ID, path and detached snapshot; resolve and validate the current row at settlement. Stamp only a matching row, otherwise use the snapshot for the removal receipt/ledger.

4. **P1 — Some migrated “Manually Deleted” rows cannot stay restored.**  
   **`VideoScan/MediaOps/VideoScanModel+RemovalMarker.swift:62–64`**

   Decode a legacy row containing both `purgedAt` and `archiveStage == .manuallyDeleted`, with lifecycle `.cataloged`. Migration correctly produces `.removedFromCatalog(reason: .legacyPurged)` because the purge takes precedence.

   Restore clears its marker but **does not clear the label**, because this conditional accepts only `.legacyDeletedLabel` or `.missingAtMigrate`. Save and reload: the surviving label creates a fresh removal marker, hiding the row again. The same problem affects a legacy Trashed-plus-label row after its file is put back.

   **Smallest fix:** after a successful explicit Restore, clear `.manuallyDeleted` regardless of which removal reason won migration. Add a restore/save/reload test for the combined legacy fields.

5. **P2 — A stale Trash probe can mark a newer removal as emptied.**  
   **`VideoScan/MediaOps/VideoScanModel+RemovalMarker.swift:97–108,130–131`**

   Probes capture ID and Trash path, but `emptiedTrashCopies` returns only IDs. During the detached sweep, the row can be restored and trashed again, producing a new marker and Trash path. The old probe’s missing result then marks the **new, still-existing Trash copy** as emptied.

   **Reproduction:** collect probes for missing path A; replace that row’s marker with an `inTrash` marker pointing to existing path B; apply the old probe results. B receives `trashEmptiedSeenAt`.

   **Smallest fix:** return the probed marker identity with each result and compare it against the current marker before applying—at least Trash path and removal timestamp.

**Read, no additional findings:** `MediaTrash.swift`, `VideoScanModel+Duplicates.swift`’s snapshot settlement, `VideoScanModel+ScanMerge.swift`’s hoist/derivation, core `RemovalMarker.swift`, `VideoRecord.swift`’s decode/accessors, and `VideoScanModel+Relocate.swift`’s `markSourceNotFound`. The legacy migration preserves visibility apart from the expressly authorized old-label conversion.

The five new suites and relevant direct regression tests were inspected. The supplied 1,241-test green result remains reported evidence, not independently rerun evidence.

## Brief

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
