# Codex review — JSON gone slice 2

- Range: `bbe1162c5..04ebe167b`
- Credits spent: unavailable (usage not exposed)
- Tokens: 107812
- Finding count: 3
- Verdict: fix — pending edits can be lost, and viewer initialization can display stale local records.
- Run: 2026-10-21T20:36:38Z (cycle #116, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (usage not exposed) | Finding count: 3

Verdict: fix — pending edits can be lost, and viewer initialization can display stale local records.

1. **P1 — The quit gate discards edits accepted while writable.** [CatalogQuitRecovery.swift:179](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ab2dae7f93cf4baea/VideoScan/VideoScan/App/CatalogQuitRecovery.swift:179) checks only the current read-only facts, then returns before committing or rescuing. `applyReadOnlyMode(true)` does not settle earlier edits.

   **Failure scenario:** Writable SQLite master → edit a note → schedule its debounced save → apply viewer mode → quit; the old note remains on disk and no recovery copy exists.

   Preserve pending master edits before completing the role transition; distinguish this case from a session that began read-only.

2. **P1 — Initialization repopulates an empty viewer launch from the local metadata cache.** [VideoScanModel.swift:1240](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ab2dae7f93cf4baea/VideoScan/VideoScan/Model/VideoScanModel.swift:1240) unconditionally backfills records after `viewerLaunch`, `.noLatch`, or `.refused` returns empty. It checks neither authority nor viewer role. The snapshot `.none` path leaves those records untouched.

   **Failure scenario:** Launch a viewer without a synced snapshot, with a persisted `.cataloged` target and old cached records beneath its path; those records become its displayed catalog.

   Gate this backfill by catalog authority. Existing launch tests call `loadCatalogAtLaunch()` after model construction, bypassing the initializer behavior that defeats their empty-record assertions.

3. **P2 — Side-table commits leave the recovery generation stale.** [CatalogCommitter.swift:370](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ab2dae7f93cf4baea/VideoScan/VideoScan/Catalog/CatalogCommitter.swift:370) receives the committed generation but never updates the new `knownGeneration` cache used by the recovery header.

   **Failure scenario:** Launch at N → commit a folder/ignore change at N+1 → edit a note → final commit fails; the recovery header incorrectly records N.

   Update `knownGeneration` on successful side-table commits. The asynchronous audit-generation path is correct.

Read, no findings within the requested scope: `CatalogAuthorityFlip.swift`, `CatalogStore.swift`, `CatalogReadOnlyFacts.swift`, `CatalogViewerSnapshot.swift`, `VideoScanModel+ViewerCatalog.swift`, `VideoScanModel+MasterArchive.swift`, `VerifyCatalogJob.swift`, `CatalogAuditJob.swift`, `IgnoredContentStore.swift`, `EventsDecisionStore.swift`, `BundleImporter.swift`, and `VideoScanModel+BundleImportExport.swift`.

Reviewed candidate `04ebe167b` against `bbe1162c5`, including relevant tests. These are code-traced failure scenarios; runtime tests were not rerun under the write-free constraint. No files changed.

## Brief

# Codex brief: JSON gone, slice 2 — catalog.json is never the authority once catalog.cutover exists (2026-10-21; data-risk; Rick approved one bundled pass)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words.

**Range:** `bbe1162c5..worktree-agent-ab2dae7f93cf4baea`. The branch is not merged; review it as the candidate. Main `bbe1162c5` already carries the SQLite corner-case matrix (`90496a524`) and the launch preflight core (`bbe1162c5`).

**Context.** Since 10/18, `catalog.sqlite` (GRDB, WAL, schema 12) is the catalog authority, with `catalog.cutover` (the latch) beside it. `catalog.json` is frozen. Rick's rulings (10/21):
- **No quarter for old JSON:** no compatibility fallbacks.
- **#354:** a Mac with no latch refuses loudly and never opens catalog.json, not even read-only.
- **Fail fast:** when anything is fishy, stop writing and say why.
- **Viewer role** (hostname ≠ the master): never writes. Its only catalog is the master's sealed snapshot in `viewer-catalog/` (synced over SSH). It never opens its own top-level catalog.sqlite. It refuses only if neither latch exists.

**What changed.**
- Retired: the JSON live dossier reload, `switchFreeze`, `JSONCatalogRepository`, `CatalogStore.readRecordsWithoutAdopting`, `adoptOnDiskGenerationAfterReconcile`, and Verify's `.auditedFile` source.
- **#353:** the SQLite launch no longer runs `_ = catalogStore.load()`. Before, it decoded the frozen JSON and brought a cleared Master Archive designation back. The designation now comes only from `catalog_state`.
- **#354:** `decide` → `.noLatch` refuses (master), or says "nothing synced yet" (viewer). In both cases it starts empty and read-only.
- **`.refused`** (the latch exists but SQLite refuses the DB) no longer falls back to catalog.json (`loadJSONReadOnly` deleted). `CatalogStore.load()` itself writes no `.prev` or sidecar while read-only.
- **Quit:** a read-only session (a viewer, or opened read-only) writes no recovery copy. Under SQLite, the failure words come from the committer. The copy no longer says "rename to catalog.json".
- **Smaller fixes:**
  - The audit marker and the quit-copy header carry the SQLite generation, not 0.
  - Validate/Verify refuse in sessions with no committer.
  - The ignore-list and folder stores refuse JSON writes when the session is read-only or has no latch.

**Files (only these, under `VideoScan/VideoScan/`):**
- `Catalog/CatalogAuthorityFlip.swift` (decide, loadCatalogAtLaunch, refuse paths, loadFromSQLite, adoptSQLiteAuthority, viewer launch)
- `Catalog/CatalogStore.swift` (load, rotateBackup, saveNow / scheduleSave / writePrecondition / isReadOnly, currentGeneration, recoveryCopyWriter)
- `Catalog/CatalogCommitter.swift` (prepare: designation, admit, saveRefusal, commitNow)
- `Catalog/CatalogReadOnlyFacts.swift`, `Model/VideoScanModel.swift` (updateReadOnlyFacts, saveCatalogNow, saveCatalogDebounced, the init's masterArchive adoption)
- `App/CatalogQuitRecovery.swift`
- `Catalog/CatalogViewerSnapshot.swift`, `Catalog/VideoScanModel+ViewerCatalog.swift`
- `Archive/VideoScanModel+MasterArchive.swift` (clearMasterArchive)
- `Integrity/VerifyCatalogJob.swift` (takeSnapshot), `MediaOps/CatalogAuditJob.swift` (conclude)
- `Catalog/IgnoredContentStore.swift`, `Events/EventsDecisionStore.swift` (the write guards only)
- `App/BundleImporter.swift`, `App/VideoScanModel+BundleImportExport.swift` (bundleImportDecision)

**Evidence already run:**
- Red→green on every fix, including QA r1's red file `QASlice2RedTests`.
- Debug: about 1,000 app Swift Testing tests in about 210 catalog-related suites, plus 46 XCTest; VideoScanCore 238 XCTest plus about 1,600 Swift Testing.
- The corner-case matrix (`CatalogAuthorityCornerTests`, `CatalogQuitCornerTests`): the cases this slice fixes were flipped from known issues to hard assertions.
- On real machines: the M5 viewer synced and showed generation 229 of the SQLite snapshot and never read catalog.json on relaunch (10/21).

**Do only this. Attack three invariants:**
1. **With the latch present, no runtime path reads catalog.json as the catalog or writes catalog.json, `.prev`, the generation sidecar or a JSON side store.** Check master and viewer; launch, refused launch, mid-session and quit.
2. **No pending edit on a writable master is lost.** The new read-only quit gate must never skip the rescue copy for a session that really had unsaved edits. Removing the JSON load must not drop any value the session needs (designation, generation, read-only facts).
3. **A viewer never writes and never shows stale data as current.** It never opens its own top-level catalog.sqlite. With no snapshot it says so. A role switch at onAppear cannot leave a writable store behind.

At most FIVE findings. P0/P1 = a JSON write after the cutover, lost edits, or a viewer that writes or silently shows stale data. One-line failure scenario each.

Known and declared, NOT findings:
- #356: the quit rescue holds the whole catalog, and there is no Keep Open choice.
- #357: a full disk is found only after building the commit, with no free-space floor.
- #338: the high-water marker is raised before COMMIT.
- #358 / #359: wording.
- The latch vanishing mid-session (#354 note).
- Slice 2b leftovers: the viewer `.legacyJSON` label, Verify tier 5 on JSON, legacy bundle import, the VolumeRenameUndo .json safety copy.
- ~120 test files still build JSON sandboxes (slice 3).

**Do not explore outside the files listed above and their tests.**

## Findings closed

Each finding was reproduced by a RED test first (`b163fb8f8`, `CatalogCodexSlice2Tests`, 5 of 6 failing on `d4a359c9b`; the sixth is the SQLite-master control), then fixed in `98201a02d` (6 of 6 green). None was declined.

| # | Finding | Closing test(s) | Fix |
|---|---------|-----------------|-----|
| 1 | P1 — the quit gate dropped edits accepted while writable | `CatalogCodexSlice2Tests.roleSwitchCommitsPendingEdits` (the edit is in catalog.sqlite after the role switch; no copy), `roleSwitchWithFailedCommitKeepsTheRescue` (commit refused at the switch → the quit writes the recovery copy with the edit) | `98201a02d`: `applyReadOnlyMode(true)` commits first (`settleEditsBeforeTheSessionTurnsReadOnly`); a failed commit arms `unsavedFromWritableSession`, which the quit's read-only gate rescues. A session that began read-only still writes no copy (`CatalogQuitRecoveryTests`, `CatalogQuitCornerTests.viewerQuitSavesNothingAndSaysNothing`). |
| 2 | P1 — the launch backfilled stale metadata-cache rows into an empty viewer / no-latch / refused launch | `viewerLaunchDoesNotBackfillFromTheCache`, `noLatchLaunchDoesNotBackfillFromTheCache`, control `sqliteMasterStillBackfills` | `d4a359c9b` moved init's launch restore into `restoreCatalogAtLaunch()` unchanged, so the tests drive the code init runs (a test host's literal `VideoScanModel()` always launches on the shared store with no scan targets); `98201a02d` gates the backfill on a writable catalog.sqlite session (committer installed, no read-only fact). |
| 3 | P2 — side-table commits left `knownGeneration` stale | `sideTableCommitMovesKnownGeneration` (an ignore-list commit; `knownGeneration` and `catalogGenerationForStamp` equal catalog.sqlite's generation) | `98201a02d`: `commitSideTables` sets `knownGeneration` on every successful commit. |

Evidence after the fixes (Debug): 239 app suites — 1244 Swift Testing tests in 236 suites + 46 XCTest, all passing (13 known issues, all pre-declared: #356, Keep Open, slice 2b, #354 mid-session); VideoScanCore run separately.

## Closed

Closed by `98201a02d` at 2026-10-21T21:07:32Z. All 3 findings closed: red b163fb8f8 (CatalogCodexSlice2Tests, 5/6 red) → fix 98201a02d (6/6 green); F2 via the init extraction d4a359c9b. None declined. See Findings closed.
