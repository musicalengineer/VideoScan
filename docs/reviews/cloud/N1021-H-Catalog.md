Brief: N1021-H-Catalog | Source: main@4e3210e5 | Wall clock: ~50 | Files read: 15 (some in part) + 6 callees
Finding count: 5 (REAL 5 / NEEDS-MAC 0 / NOISE 0)
Verdict: The catalog store's write path held up against every attack tried (atomic and fsynced write with read-back, future-schema latch, generation checks, lock re-entry). The holes are one level up, in the model: a one-click wipe of the whole catalog with no confirmation and no snapshot (P1); a live-reload merge that lets an older catalog.json overwrite a newer in-memory dossier; a records index used across an await; a crash when Update Catalog is cancelled mid-apply; and import adding a record whose id already exists.

## Why this row tonight
Rick's paste included the plain `Run docs/briefs/cloud/NIGHTLY.md` line. Tonight's dated row (10-11, N1011) was already done and was re-run as a second pass on request. The earliest row not yet done is N1019-R-week, but its scope is "merged 10-12..10-18", which has not happened yet. So this session took the next runnable row, **N1021-H-Catalog**. The Manager may want to mark N1021 done and leave N1019 in place.

## Scope and method
- Theme H over `VideoScan/VideoScan/Catalog/` plus `Model/`, recently changed files first: catalog save/load, rescan merge, removal, reprobe, import/export.
- **Method:** a subagent drafted the review from the brief. I then re-read **every finding's cited lines on main** before writing it here: F1 `clearResults` and its menu; F2 `pollAndMergeDossierFromDisk` / `mergeDossierFields` plus `applyDossier`'s stamp and debounce, and that live reload starts on the master; F3 `backfillAllProvenance`'s index snapshot and post-await write, and the absence of any scan guard; F4 the `applyUpdateCatalog` loop and the Cancel wiring; F5 `importCatalog` / `identityKey`. All five stand as written. Line numbers are on main@4e3210e5. The local HEAD differs from it only in docs.
- **Files read (in scope):**
  - `Catalog/`:
    - `CatalogStore` (380-1380)
    - `CatalogLock`
    - `CatalogSync` (240-360, 456-1017)
    - `VideoScanModel+LiveReload`
    - `VideoScanModel+CatalogImportExport`
    - `VideoScanModel+TidyCatalog`
    - `VideoScanModel+RecordIdentityRepair`
    - `VideoScanModel+CatalogVerification` (60-280)
    - `VideoScanModel+UpdateCatalog` (155-489)
    - `UpdateCatalogSheet` (1-140)
    - `VideoScanModel+Rename` (170-361)
    - `CatalogToolbar` (200-290)
    - `CatalogPerfMemo` (80-160)
    - `CatalogView+VolumeTable` (585-605)
  - `Model/VideoScanModel.swift` (1-60, 515-555, 1130-1470, 1640-1752)
- **Callees followed (only to settle findings):**
  - `People/VideoScanModel+Dossier.swift` (:125-142)
  - `Volumes/VideoScanModel+ScanMerge.swift` (`commitScanResults`)
  - `Volumes/VideoScanModel+VolumeRenameMigration.swift` (:700-725)
  - `VideoScanCore/ScanContext.swift` (:24-70)
  - `App/ContentView.swift` (:698, :1150-1152)
  - `App/VideoScanApp.swift` (:615-645)
- **Already reported, not re-filed:** N1007-D-Catalog-over-30-F2 (Reset & Re-probe has no confirmation). It is still open (`VideoScanModel.swift:1694-1705`).

## Guards checked that held
- **Lock re-entry while an async save is in flight:**
  - `saveAsync` takes the lock in `writePrecondition()` and then returns early on `saveInFlight` without releasing it.
  - This is safe: the lock does not count (`CatalogLock.swift:105`, `if fd >= 0 { return .acquired }`), and the in-flight completion releases it (`CatalogStore.swift:534`).
- **No torn catalog.json:** `Data.write(.atomic)`, then F_FULLFSYNC on the file and its directory, then a SHA-256 read-back (`CatalogStore.swift:1329-1371`). The snapshot paths share `encodeAndWrite`.
- **A future-schema catalog is never overwritten:** the `writesDisabledReason` latch (`CatalogStore.swift:648`), which every write gate checks (`:431`).
- **The stale check never refuses our own landed async write:** it compares with `max(loadedGeneration, claimedGeneration)` (`:472-476`), and `finishWrite` never moves the generation backwards (`:505`).
- **A failed `.prev` rotation never aborts the load** (`:916-927`).
- **Duplicate ids never trap:**
  - on load (`dedupingByID`, `:842`)
  - in `RecordIDIndex` (`uniquingKeysWith`, `CatalogPerfMemo.swift:121`)
  - within one import file (`CatalogImportExport.swift:81`)
- **Verify Catalog is safe across its await:** it indexes a local array of references (`CatalogVerification.swift:71, 128`).
- **Tidy re-checks at apply time:** pair protection and the archive volume are checked again (`TidyCatalog.swift:292-299`). Remove from Catalog sets records aside and refuses on read-only (`:356-371`).
- **Update Catalog's refresh after its await re-derives the rows and checks a generation** (`UpdateCatalog.swift:255-256`). Parked results are dropped when the sheet closes (`:324`), and Apply refuses a target that is scanning (`:392`).
- **Rename:** it rejects `/` and `:` (`Rename.swift:193`) and checks the destination does not exist (`:216`); `moveItem` never overwrites. An archive rename saves at once (`:333-337`).
- **Viewer sync:** the rsync exit code is checked (`CatalogSync.swift:264, 827`), ssh uses `BatchMode` and `ConnectTimeout=5` (`:720`), and the swap happens only after the manifest verifies (`:856-863`).
- **The launch backfill skips targets explicitly removed** (`.noCatalog`, `VideoScanModel.swift:1174`).

## Findings

### N1021-H-Catalog-F1: P1 · REAL · "Clear ▸ Clear Results" erases the whole catalog on disk in one click, with no confirmation and no snapshot
- **Symbol:** `VideoScanModel.clearResults`, Model/VideoScanModel.swift:1651-1663 (`records = []` … `saveCatalogNow()`).
- **How it is reached:** `CatalogToolbar.body`, Catalog/CatalogToolbar.swift:251 (`Button("Clear Results") { onClearResults() }`, disabled only when there are no records, and the menu only while scanning, :263), wired at App/ContentView.swift:698 (`onClearResults: { model.clearResults() }`). The menu's help text is "Clear catalog results or cached probe data".
- **Scenario:**
  1. On the master, the catalog has 100k records carrying notes, people tags, user dates, fixity and removal tombstones. No scan is running.
  2. Rick opens the toolbar's **Clear** menu and picks **Clear Results**. The name reads like clearing the view, and it sits one line above "Clear All Cache".
  3. `records = []`, and `saveCatalogNow()` writes an empty catalog.json synchronously through `catalogStore.saveNow` (VideoScanModel.swift:1410-1412). It passes every write gate: `writePrecondition` has no shrink check, and the Master Archive designation lives on the store, so the GH #167 refusal does not fire.
  4. `catalog.json.prev` still holds this launch's catalog, but nothing says so. On the **next launch**, `load()` decodes the empty file and `rotateBackup()` copies it over `.prev` (CatalogStore.swift:654-656, 916-927). The last automatic copy is gone.
  5. That launch's cache backfill refills every target from the probe cache, because `clearResults` never set the targets to `.noCatalog` (VideoScanModel.swift:1172-1183). The catalog seems to come back, but the curated fields do not, so the loss is easy to miss.
- **The guard that would make it false, and why it doesn't hold:**
  - The sibling `deleteAllCatalog` is behind a destructive confirmation alert (ContentView.swift:1150-1152); `clearResults` has none.
  - Neither path goes through `removeCatalogRecords`, whose `catalog.pre-target-removal` snapshot (VideoScanModel.swift:1701) would have caught this.
  - No `catalog.pre-*` snapshot is written before either wipe.
  - The only other copy is a manual bundle backup, if one exists.
- **Why P1:** the catalog's curated fields (Rick's notes, people, dates, removal tombstones) are the family record. One click destroys them, and the safety copy is rotated away at the next launch.
- **Pinning test (fails today; `VideoScanTests/CatalogPurgeTests.swift`, next to the `deleteAllCatalog` banner test near :999):** `clearResultsNeverPersistsAnEmptyCatalogWithoutASnapshot`.
  1. Build a model on a temp `CatalogStore(directory:)`, seed 10 records with `userNotes`, and save.
  2. Call `clearResults()`.
  3. Expect catalog.json still to decode to 10 records, **or** a `catalog.pre-*.json` sibling holding 10 records to exist. Today it holds 0 and there is no sibling.
- **Fix direction:**
  - Make Clear Results view-only, or remove it.
  - Route both wholesale wipes through a confirmed plan that writes a `catalog.pre-wipe` snapshot first (fail-closed: no snapshot, no wipe) and sets the targets to `.noCatalog`.
  - Secondary: `deleteAllCatalog` (VideoScanModel.swift:1366-1388) is confirmed but has the same missing snapshot. Fix both together.

### N1021-H-Catalog-F2: P2 · REAL · Live reload trusts whatever catalog.json says: an older file overwrites a newer in-memory dossier, and records removed during its await come back
- **Symbols:**
  - `VideoScanModel.pollAndMergeDossierFromDisk`, Catalog/VideoScanModel+LiveReload.swift:72-107. The only gate is `if let last = lastLiveReloadMtime, mtime <= last { return }`, and `lastLiveReloadMtime` is set only after a merge (:97).
  - `mergeDossierFields(from:)`, :165-229. It copies every dossier channel unless `myAt == theirsAt`, with **no "newer wins" comparison**, and it appends any snapshot record that memory lacks.
  - Live reload runs on the **master** too (App/VideoScanApp.swift:640, `startLiveDossierReload()` outside any viewer check).
- **Scenario A (the older dossier wins):**
  1. On the master, record R's dossier is on disk with stamp t1.
  2. Rick re-analyses R in the app. `applyDossier` stamps `dossierProcessedAt = now` (t2) with new captions, transcript and date (People/VideoScanModel+Dossier.swift:132), then `saveCatalogDebounced()` (:139). Nothing reaches disk until the debounce fires.
  3. Any earlier save of the app's own has already moved the file's mtime past `lastLiveReloadMtime`. The 30 s poll fires inside the debounce window and decodes the file, which still says t1.
  4. t1 ≠ t2, so the scene, transcript and OCR channels and the inferred date are copied back from t1 over the t2 values (`mem.audioTranscript = fresh.audioTranscript` …). The next save persists t1. The re-analysis is lost silently. It is machine data, but costly model time, and a re-run looks "already done".
- **Scenario B (removed records come back across the await):**
  1. A poll is mid-decode. The detached parse of a large catalog takes seconds.
  2. Rick confirms Remove from Catalog for everything (`deleteAllCatalog`).
  3. The decode returns the pre-removal snapshot. No id or path matches, so every record is "brand new" and appended (:228-229). The quit-time save persists it.
- **The guard that would make it false, and why it doesn't hold:** the mtime check cannot tell our own writes from a foreign merger's. Nothing checks for a pending or in-flight catalog save, or for this session's removals. `adoptOnDiskGenerationAfterReconcile` only moves the write baseline; it does not filter the merge. The existing test pins only "same vintage is skipped" (`LiveDossierReloadTests.swift:150`).
- **Pinning tests (`VideoScanTests/LiveDossierReloadTests.swift`):**
  - `olderDiskDossierNeverOverwritesNewerMemory`: memory has `dossierProcessedAt = t2` with transcript "new"; the snapshot has the same id with t1 < t2 and "old". After `mergeDossierFields(from:)`, expect "new". It fails today.
  - `recordsRemovedAfterSnapshotAreNotReappended`: snapshot, `deleteAllCatalog()`, merge, then expect `records.isEmpty`.
- **Fix direction:**
  - Copy only when `fresh.dossierProcessedAt > mem.dossierProcessedAt`, or when memory has none.
  - Skip the poll when the on-disk generation is one this session wrote, and re-check a removal epoch after the await before appending.

### N1021-H-Catalog-F3: P2 · REAL · "Backfill All Volume Names" writes results by a `records` index captured before its await: wrong record, or crash
- **Symbol:** `VideoScanModel.backfillAllProvenance`, Catalog/VideoScanModel+CatalogVerification.swift:169-249.
  - `recIndex: records.firstIndex(where: { $0 === rec }) ?? 0` (:202) is captured before the detached pass.
  - After the await, the write is `self.records[r.recIndex].scanContext = ctx` (:249).
- **Scenario:**
  1. Rick starts a rescan of volume A, then picks **Backfill All Volume Names** from the volume table menu (CatalogView+VolumeTable.swift:595-598). Nothing disables it during a scan, and the function has no scan guard and does not check `isBackfillingProvenance` before starting.
  2. The detached pass captures context for every legacy record, which takes tens of seconds for thousands of files.
  3. A's scan commits. `commitScanResults` removes and appends rows, so the later indices shift.
  4. Each file's volume name, volume UUID, host and scan-root label land on whatever record now sits at the stale index, and that is saved. If the array shrank meanwhile (a removal, a wipe, the id repair), `records[i]` is out of range and the app traps.
  5. Separately, `?? 0` sends any unmatched record's context to `records[0]`.
- **The guard that would make it false, and why it doesn't hold:** the sibling `verifyTarget` is safe because it indexes a local array of references (:128). This function indexes the live `self.records`.
- **Bounded impact:** the volume-rename migration also keys on the path, so a wrong UUID can only exclude a record from it (VolumeRenameMigration.swift:711-713). Hence P2.
- **Also:** `firstIndex` per record is O(needs × records) on the main actor before the Task starts. With 10k legacy rows in a 100k catalog that is about 10⁹ compares, a beachball (the CLAUDE.md scale rule).
- **Pinning test (`VideoScanTests/CatalogTests.swift`, beside `ScanContextTests`):** `provenanceBackfillTargetsTheSameRecordAfterArrayShift`.
  1. Seed [X, Y, Z] with an empty `volumeName`; only Z's file exists in a temp directory.
  2. Call `backfillAllProvenance()` and, before awaiting `backfillTask`, remove X.
  3. Expect Z, not Y, to get the context. Today Y does.
- **Fix direction:** carry the `VideoRecord` reference (or its id, resolved through `record(forID:)`) in `BackfillSnap`, as `verifyTarget` does. Drop `?? 0` and refuse to start while a scan or another backfill runs.

### N1021-H-Catalog-F4: P2 · REAL · Pressing Cancel or Esc during Update Catalog ▸ Apply crashes the app at the next row
- **Symbols:**
  - `VideoScanModel.applyUpdateCatalog`, Catalog/VideoScanModel+UpdateCatalog.swift:364-381. `for i in updateCatalogRows.indices` captures the range once, and `updateCatalogRows[i]` is subscripted again after each `await applyParkedMerge(rowIndex: i)`.
  - `closeUpdateCatalog`, :187-201, does `updateCatalogRows.removeAll()`.
  - The sheet's Cancel button, UpdateCatalogSheet.swift:107-113, stays enabled with `.keyboardShortcut(.cancelAction)` while "Working…" shows.
- **Scenario:**
  1. The sheet lists two or more targets, and the first is previewed. Rick presses Apply.
  2. `applyParkedMerge(0)` awaits `commitScanResults`, which suspends on its detached existence sweep.
  3. Rick presses Cancel or Esc. The rows are emptied.
  4. The commit finishes and the loop moves to `i = 1`. `updateCatalogRows[1]` is out of range, and the app traps.
  5. The merge just committed in memory had only `saveCatalogDebounced()` (:404). It is lost with the crash, along with any other edits not yet saved.
- **Also:** the Cancel help text promises "the catalog stays as it is", but a merge already under way is committed regardless.
- **The guard that would make it false, and why it doesn't hold:** `applyParkedMerge` looks rows up by id after its own await (`setUpdateCatalogPhase`), so it is safe. The outer loop's positional index is not.
- **Pinning test (`VideoScanTests/UpdateCatalogTests.swift`):** `cancelDuringApplyDoesNotCrash`.
  1. Use the `scanMergeDuringExistenceChecksForTesting` hook (already used by `ScanMergeScopeTests`) to call `closeUpdateCatalog()`.
  2. Set up two rows, the first `.previewed`.
  3. Expect `await applyUpdateCatalog()` to return. Today it traps.
- **Fix direction:** iterate over a snapshot of row ids, resolve each row by id after every await, and stop if the session was closed (a generation counter). Disable Cancel while `anyBusy`, or relabel it.

### N1021-H-Catalog-F5: P3 · REAL · Importing an older export of the same catalog appends records whose UUID already exists locally
- **Symbol:** `VideoScanModel.importCatalog(from:)`, Catalog/VideoScanModel+CatalogImportExport.swift:90-134, and `identityKey(for:)`, :167-186.
  - De-duplication is by **content key** only: `md5:…` when `partialMD5` is set, otherwise `fn:name:size:dur`, otherwise nil.
  - A record is appended with no check that its `id` is already in `records`.
- **Scenario:**
  1. Export the catalog while some records lack `partialMD5`; their key is `fn:…`.
  2. The hash backfill later fills `partialMD5`, so the local key becomes `md5:…`.
  3. Import the old export, or a viewer's export, which shares the UUIDs. Those records miss `seen` and are appended with the **same id**. So is any record with no identity at all (size 0).
  4. The session now holds twin UUIDs: duplicate table rows sharing a SwiftUI identity and a selection key. `saveCatalogNow()` (:134) persists them.
  5. The next launch's `dedupingByID` drops one, usually keeping the local record, so most of the damage is transient. An edit made this session on the twin object is lost at that relaunch.
- **Pinning test (`VideoScanTests/CatalogTests.swift`, next to `importSkipsRecordsAlreadyPresentByContentIdentity`, :46):** `importNeverAddsARecordWhoseIDIsAlreadyPresent`.
  1. Local: id X, `partialMD5` "abc", size 100.
  2. Exported: id X, `partialMD5` "", same size and filename.
  3. After import, expect `records.filter { $0.id == X }.count == 1`. Today it is 2.
- **Fix direction:** seed a `Set<UUID>` of local ids, and treat an id hit as a skip (the local record stands in for itself) before the content-key check.

## Looked at, not reported
- Full media paths are logged with `privacy: .public` (for example `UpdateCatalog.swift:462`, `CatalogHelpers.swift:1689/1708/1789`). This is a policy question for Rick on a personal Mac, not a defect.
- The launch backfill's `records.contains { hasPrefix(searchPath) }` (VideoScanModel.swift:1175) has no trailing `/` and is O(targets × records) once per launch. No wrong result: a sibling prefix can only suppress the backfill.
- `CatalogView+VolumeTable.swift:595` calls `records.contains` inside a context-menu builder. It runs on right-click only.

## Not covered
- **`Catalog/` files not reached:**
  - `VideoScanModel+RescanPreservation`, `+DateInference`, `+Provenance`, `+NotesRepair`, `+RecoveredExtension`, `+IgnoredContent` (only its save call), `IgnoredContentStore`
  - `CatalogWriteError` (the journal rotation `try?` at :214-215), `CatalogGenerationSidecar`, `CatalogSearchIndex`, `CatalogHelpers`, `CatalogQueries`
  - `CopiesAdvice*`, `CatalogTrash*`, `ExcessCopiesPane`, `TriageView` / `TriageSnapshot`, the `Inspector*` views, `DateTriangulat*`, the storage and size totals, and the remaining UI files
- No folder-wide sweep of view bodies for O(records) work.
- `Model/Models.swift` and `Model/ProvenanceTypes.swift` were not read.
- Not checked: whether `ProcessRunner.runProcess` has a timeout. A viewer rsync that stalls after ssh connects could leave `CatalogSync.state` stuck at `.syncing`. That needs the Mac or that callee.
- Nothing was built or run.

## Blockers & environment
- **Branch:** README rule 3 names `cloud/N1021-H-Catalog`. This session may push only to its designated branch, so the report is on `claude/compassionate-babbage-kn9mbj`.
- **Row choice:** N1019-R-week is the earliest row not done, but its date window (merges 10-12..10-18) is in the future, so it was skipped. See "Why this row tonight".
- **Method:** a subagent in this session drafted the review. Every finding was re-verified against the source before inclusion.
- No tool failures.
