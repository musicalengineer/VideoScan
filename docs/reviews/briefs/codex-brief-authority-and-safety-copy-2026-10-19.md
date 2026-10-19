# Codex brief: the catalog authority at launch, and safety copies (2026-10-19; data-risk; Rick approved)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~600 words.

**Change A: P0 #340, the launch read-only state (range `b90f16015^1..b90f16015 (commit e4b7563b2)`).** `VideoScanModel.init` → `loadCatalogAtLaunch()`. On a refused SQLite launch, `loadJSONReadOnly` set both read-only flags. The window's onAppear then called `applyReadOnlyMode(catalogSync.isReadOnly)` (`App/VideoScanApp.swift:633`), which cleared them on the master. That session would save to catalog.json with no committer, and the edits would be lost at the next good SQLite launch: two writable catalogs. The same reset also cleared read-only after a restoredBelowHighWater SQLite open. Fix: the new value type `CatalogReadOnlyFacts` (`Catalog/CatalogReadOnlyFacts.swift`) holds one fact per owner (`jsonFrozenByLaunch`, `sessionReadOnlyByLaunch`, `viewerRole`, `switchFreeze`). `storeReadOnly = jsonFrozen || viewer || switchFreeze` and `modelReadOnly = sessionReadOnly || viewer || switchFreeze`. `VideoScanModel.updateReadOnlyFacts(_:)` is the only app code that writes either flag; `applyReadOnlyMode` now sets only `viewerRole`. This also fixes a normal SQLite launch un-freezing catalog.json, Adopt's `onWritableAgain` clearing a viewer's read-only, and the Switch's `freezeJSON` restoring a stale snapshot.

**Change B: the adversarial 10/18 fixes, merge `c558d68ca` (range `0a4ee602b^1..c558d68ca`).**
- #3: `CatalogCommitter.commitBeforeSafetyCopy()` commits pending edits before `sqliteSnapshot`'s `VACUUM INTO`; a held, blocked or reopening catalog refuses the copy.
- #2: volume-rename Undo reads a `.sqlite` safety copy through `SQLiteCatalogLoader`, and `revertVolumeRenameRewrites` restores only `fullPath`/`directory`/`scanContext.volumeName` on records that still carry the migration's rewrite. Nothing is purged.
- #10: `undoLastPurge` keeps refused rows and shows their words.
- #9: `markBucketBSourcesNotFound` counts only rows it marked.

Files under `VideoScan/VideoScan/`:
- `Catalog/CatalogAuthorityFlip.swift` (`loadCatalogAtLaunch`, `loadJSONReadOnly`)
- `Model/VideoScanModel.swift` (`applyReadOnlyMode`, the three save wrappers)
- `App/VideoScanApp.swift` (:620-640)
- `App/CatalogAuditCLI.swift` (:81)
- `Catalog/CatalogCommitter.swift`
- `Volumes/VideoScanModel+ScanMerge.swift` (`snapshotCatalog`, `snapshotCatalogAsync`, `sqliteSnapshot`)
- `Volumes/VideoScanModel+VolumeRenameUndo.swift`
- `MediaOps/VideoScanModel+SoftDelete.swift` (`undoLastPurge`)
- `MediaOps/VideoScanModel+Relocate.swift` (`markSourceNotFound`, `markBucketBSourcesNotFound`)
- `Catalog/CatalogReadOnlyFacts.swift` (new)
- `Catalog/CatalogSwitchToSQLite.swift` (`freezeJSON`)

Tests:
- `VideoScanTests/CatalogCutoverReadSideTests.swift` (`CatalogAuthorityFlipTests`: `refusedLaunchSurvivesApplyReadOnlyMode`, `readOnlySQLiteSurvivesApplyReadOnlyMode`, `normalSQLiteLaunchFollowsTheRole`, `jsonLaunchFollowsTheRole`, and the sensor `readOnlyHasOneWriter`)
- `AdvSQLiteSafetyCopyTests.swift`, `AdvVolumeRenameUndoSQLiteTests.swift`, `AdvHeldCatalogDoorsTests.swift`

Evidence: the B fixes went red → green → revert → green; 459 tests in 87 suites passed on the branch and 70 tests in 8 suites on merged main. #340: red before the fix (4 tests / 11 issues; the refused-launch test changed catalog.json's SHA-256), green 15/15 after, red again on revert, green on re-apply. 148 tests in 40 suites on the branch, and 37 tests in 4 suites on merged main b90f16015.

**Do only this.** Attack two invariants:
1. **No session can ever write a catalog that is not the authority** named by `catalog.cutover`. That covers JSON writes under SQLite, read-only cleared by any later call, and a viewer, CLI or headless audit path that opens a writer.
2. **Every safety copy holds what is in memory at the moment of the risky change,** and an Undo restores only what the change wrote.

At most FOUR findings. P0/P1 = an edit lost, a second writable catalog, or an Undo that drops or reverts someone's later work. Give a one-line failure scenario for each.

Check specifically:
- every writer of `isReadOnly` / `catalogStore.isReadOnly` after launch;
- ordering between `init` and onAppear;
- `CatalogAuditCLI`;
- an await between `commitBeforeSafetyCopy` and `VACUUM INTO`;
- a store-refused row at copy time (declared: it goes in at its last stored value, with one log line);
- an Undo after a later scan touched the same rows.

Known and declared, NOT findings: #338 (the near-full high-water is raised before COMMIT); the quarantine has no door (#339); viewer sync still ships JSON (being replaced).

**Do not explore outside the files listed above and their tests.**
