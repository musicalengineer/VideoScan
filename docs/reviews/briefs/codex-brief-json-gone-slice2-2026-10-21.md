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
