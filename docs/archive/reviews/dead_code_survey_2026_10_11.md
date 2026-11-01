# Dead-code survey — 2026-10-11

Read-only measurement. Nothing was deleted or edited. Numbers only; whether to delete is Rick's call.

- **SHA:** `259640fdf` (main, one commit past 75a279c10)
- **Where:** M5 Pro (`RicksM5.local`), clone `/Users/rickb/dev/VideoScan`. The tracked tree was clean. Untracked `.codex/` build artifacts were present and left alone.
- **Tool:** Periphery 3.8.0. **Installed today on the M5 with Homebrew; it was not present before.** Xcode 27.0.
- **Build:** `xcodebuild build-for-testing`, scheme VideoScan, Debug, index store on, derived data at `build/periphery-dd` inside the clone (gitignored). The default derived-data path on the M5 points to `/Volumes/XcodeRAM`, which is not writable, so the in-clone path was required.
- **Scan flags:** `--retain-public --retain-objc-accessible --retain-swift-ui-previews --retain-codable-properties --skip-schemes-validation`, with `.build/` and SPM checkouts excluded.
- **Two scans:**
  - **A** counts test targets as roots, so its output is code that is dead outright.
  - **B** uses `--exclude-tests`, so its output is code that production never reaches.
  - **B minus A** is code reachable only from tests.
- **Scope:** app source = `VideoScan/VideoScan/` plus `VideoScanCore/Sources`, **369,943 lines** across 1,119 files (physical lines, including comments). The "~377k" headline was not reproduced exactly; the difference is probably counting scope. `swift_cli/`, `scripts/` and `tools/` are not part of the Xcode project, so Periphery cannot see them. They appear only in section 4.
- **Line estimates:** the declaration's span (doc comment plus body, brace-matched), counting only the outermost unused declaration so nested ones are not double counted. Unused parameters count as 0 lines.

## 1. Totals

| | Declarations | Est. lines | % of app |
|---|---:|---:|---:|
| **Dead outright** (unused even counting tests) | 290 | 1,653 | 0.45% |
| **Test-only** (production never reaches it) | 500 | ~5,100 | 1.4% |
| Assign-only properties (written, never read) | 261 (A) / 403 (B) | ~1 each | — |
| Dead SwiftUI views and wiring found by hand (Periphery missed them, see 5) | 7 sites | ~590 | 0.16% |
| **Removable estimate** | | **~7,300–7,600** | **~2%** |

Dead outright, by kind:

| Kind | Count |
|---|---:|
| instance properties | 82 |
| unused parameters | 65 |
| instance methods | 52 |
| static methods | 41 |
| static properties | 26 |
| structs | 9 |
| unused imports | 8 |
| enum cases | 3 |
| other | 4 |

Test-only (B minus A), by kind:

| Kind | Count |
|---|---:|
| static methods | ~140 |
| instance methods | ~136 |
| instance properties | ~120 |
| free functions | ~24 |
| structs | 15 |
| enums | 16 |
| initializers | 14 |

Note: the figures above are the **mechanically detectable** floor. They leave out two larger things:

- **Vestigial features that are still wired up.** The POI Find Person path in section 4 is about 11.8k lines of Swift. It is live code, so no tool can call it dead.
- **Public API in VideoScanCore.** `--retain-public` keeps all of it, so the scans report 0 test-only lines there by construction.

## 2. By feature folder

Dead = A. Test-only = B minus A. Lines are estimates.

| Folder | LOC | Dead decls | Dead lines | Test-only decls | Test-only lines | Combined % | Assign-only |
|---|---:|---:|---:|---:|---:|---:|---:|
| MediaOps | 54,080 | 38 | 118 | 110 | 1,431 | 2.9% | 29 |
| People | 33,303 | 36 | 330 | 62 | 807 | 3.4% | 21 |
| Catalog | 33,616 | 26 | 200 | 64 | 679 | 2.6% | 28 |
| Hallie | 69,822 | 57 | 388 | 51 | 421 | 1.2% | 44 |
| Media | 18,318 | 20 | 33 | 30 | 487 | 2.8% | 24 |
| FamilyTree | 32,456 | 20 | 94 | 61 | 378 | 1.5% | 43 |
| Volumes | 18,096 | 16 | 170 | 21 | 147 | 1.8% | 6 |
| ArchiveAngel | 19,135 | 23 | 137 | 39 | 176 | 1.6% | 14 |
| Archive | 23,377 | 20 | 45 | 32 | 215 | 1.1% | 31 |
| Shared | 2,892 | 5 | 24 | 13 | 174 | 6.8% | 0 |
| FamilyMusic | 594 | 0 | 0 | 4 | 78 | 13.1% | 0 |
| Steward | 3,866 | 1 | 2 | 5 | 58 | 1.6% | 3 |
| VideoScanCore | 44,843 | 13 | 55 | 0* | 0* | 0.1% | 6 |
| App | 8,049 | 9 | 34 | 4 | 20 | 0.7% | 2 |
| ModelsUI | 1,010 | 0 | 0 | 2 | 21 | 2.1% | 4 |
| FootageGroups | 2,475 | 2 | 6 | 2 | 11 | 0.7% | 1 |
| Model | 2,148 | 2 | 12 | 0 | 0 | 0.6% | 4 |
| Analyze | 1,863 | 2 | 5 | 0 | 0 | 0.3% | 1 |

\* The VideoScanCore test-only figure is 0 because `--retain-public` keeps its public API, so the real figure is not measured.

### Largest dead declarations (A)

Each of these was spot-checked by grep: no callers in app or tests.

| Lines | Declaration | Location |
|---:|---|---|
| 85 | `handleKinship(_:)` | Hallie/ArchivistChatWindow.swift:1900 |
| 68 | `exportVolumeInfo()` | Volumes/VideoScanModel+VolumeLifecycle.swift:262 |
| 57 | `struct ReferenceFaceCard` (POI) | People/PersonFinderSubviews.swift:28 |
| 55 | `struct CatalogSizeTotalsBox` | Catalog/CatalogSizeTotals.swift:304 |
| 52 | `RAMAssetLoader.warm(fileURL:)` | Volumes/RAMAssetLoader.swift:207 |
| 46 | `handleGeneralQuestion(_:)` | Hallie/ArchivistChatWindow.swift:1681 |
| 43 / 37 / 36 / 25 | `DialRing`, `MiniRing`, `StatusBadge`, `StageBadge_Removed` | People/DossierDashboardView+Subviews.swift, DossierToolbarChip.swift, DossierDashboardView+Rows.swift |
| 36 | `inspectorThumbnail(for:)` | Catalog/InspectorPanel.swift:315 |
| 28 + 25 | `HallieGeneralKnowledgeLane.decide`, `typedFamilyName` | Hallie/LLM/HallieGeneralKnowledgeLane.swift |
| 26 + 22 + 16 | `answerPlace`, `appendProfileAmbiguity`, `declineForRecompile` | Hallie/ArchivistChatWindow.swift |
| 23 | `machineNotePrefixes` | ArchiveAngel/Recommend/ArchiveAngelCandidate+Record.swift:221 |
| 22 + 19 | `importCatalogViaPanel`, `exportCatalogViaPanel` | Catalog/VideoScanModel+CatalogImportExport.swift |

**ArchivistChatWindow cluster.** The chat window's old kinship and general-question route is about 215 lines and is dead. Because of that, `ArchivistQuestionParser` (138-line file) and its tests are reachable only from the tests.

**Unused imports (8 files):**

- Archive/ArchiveDateEntry
- FamilyTree/FamilyTreeBirthFlagViews
- Hallie/HallieGalleryAnswer
- Hallie/HallieOfferAcceptance
- Hallie/HalliePhotoCaption
- Hallie/Shell/HallieShellCLI+Render
- Hallie/Web/HallieWebPoster
- Hallie/Web/HallieWebProxy

## 3. Whole files (or nearly whole) unreachable, or reachable only from tests

"Code covered" is the share of the file's non-comment code lines that sit inside flagged declarations.

| File | Lines | Status | Code covered |
|---|---:|---|---:|
| Media/MediaPersonLinks.swift | 184 | test-only (MediaPersonLinksTests) | 100% |
| Hallie/ArchivistQuestionParser.swift | 138 | test-only (its only app callers are the dead chat-window handlers above) | 100% |
| People/DossierDashboardView+FleetStats.swift | 291 | test-only (`FleetStats`, FleetStatsTailTests); 15% dead outright | 97% |
| Media/VideoScanModel+AudioTranscript.swift | 146 | test-only (`applyAudioTranscript(s)`) | 96% |
| Shared/TestEnvironment.swift | 58 | **false positive** (see 5) | 93% |
| Archive/VideoScanModel+Archive.swift | 39 | test-only | 91% |
| MediaOps/TrimJob.swift | 741 | test-only. Trim Master's menu item was retired 2026-09-23, and the engine was kept on purpose (comment at Catalog/CatalogRowContextMenu+FileOps.swift:205) | 83% |
| MediaOps/TrimEngine.swift | 349 | test-only for the trim parts. `TrimEngine` is also used by RebuildAudioJob and BalanceAudioJob | 73% |
| MediaOps/Correlator.swift | 190 | `correlate(records:selectedIDs:)` and helpers are test-only. `Correlator.*` constants are live | 73% |
| FamilyMusic/VideoScanModel+FamilyMusic.swift | 64 | test-only (`markFamilyMusic`) | 69% |
| FamilyMusic/FamilyMusicSheet.swift | 125 | the view is never instantiated; `FamilyMusicSheetRequest.make` is test-only | ~100% (by hand) |
| MediaOps/CoverArtMusicPurgeSheet.swift | 69 | never instantiated; its `showCoverArtMusicPurgeSheet` flag is never read | 100% (by hand) |
| MediaOps/UnrelatedAudioPurgeSheet.swift | 143 | never instantiated; its `showUnrelatedAudioPurgeSheet` flag is never read (VideoScanModel.swift:1491-1510 says the Purge surface replaced both) | 100% (by hand) |

Other large test-only blocks inside live files:

| Lines | Declaration | Location |
|---:|---|---|
| 78 | `POIStorage.rollbackUUIDMigration` | People/POIStorage.swift:934 |
| 57 | `CatalogCSVWriter` | Shared/Formatting.swift:58 |
| 46 + 28 | `pfTokenMatches`, `pfTriageDisposition` | Catalog/CatalogQueries.swift |
| 44 | `MediaFileOperationsCenter.startTrim` | MediaOps/MediaFileOperations.swift:1276 |
| 40 | `RelocateReconcile.reconcile` | MediaOps/RelocateReconcile.swift:457 |
| 39 + 39 | `exportCatalog(to:)`, `removeFromCatalog(recordIDs:)` | Catalog/ |
| 36 | `saveCurrentPOI()` | People/PersonFinderModel.swift:674 |
| 36 | `FixtureResearchFetcher` | FamilyTree/ResearchSources.swift:182 |
| 24 | `PythonSubprocessCaptionRunner` (stub) | Media/CaptionRunner.swift:773 |

## 4. Known suspects

### 4a. CatalogDuplicatesMenu (Catalog/CatalogDuplicatesMenu.swift, 134 lines)

**Confirmed: the view is never instantiated in app code.** Its own header says so: "no longer constructed by the app; Phase C removes it".

Parts that are still live:

- the nested `CatalogDuplicatesMenu.Volume` type, used by ContentView, DeleteDuplicatesFlow, DeleteDuplicatesVolumePicker and StorageReclaimableCard
- `title(for:)`, used by the picker

Parts that are test-only:

- `offersDelete`
- `findSimilarFootageTitle` and `findSimilarFootageOfSelectedTitle`
- the `init` and `body`

Removable: about 75 lines of view, plus CatalogDuplicatesMenuTests (the Logic, Structure and Isolation suites). Moving `Volume` and `title(for:)` out first would let the whole file go.

Periphery did **not** flag this one. The struct counts as "referenced" because its nested type is used.

### 4b. Second Delete Duplicates picker (App/ContentView.swift:1035-1062)

**Confirmed dead.** `deleteDuplicatesVolumePicker` is declared at :378 and is only ever set to `nil`, at :1049 and :1053. Nothing in the app sets it to a request, so the sheet can never open. The live picker is `DeleteDuplicatesFlow` (MediaOps/DeleteDuplicatesFlow.swift), used from the Storage card and from Triage.

Everything downstream of the dead sheet is dead too:

| Item | Location |
|---|---|
| `pickedDeleteDuplicatesVolume` | :379 |
| "Delete Duplicates" confirmation alert | :1056-1070 |
| `showDeleteDuplicatesConfirm` | :363 |
| `deleteTargetVolume`, `deleteTargetCount`, `deleteTargetForecast`, `deleteTargetSummary`, `deleteTargetCrossMode` | :366-384 |
| `deleteDuplicatesConfirmMessage` | :1664-1690 |
| `prepareDeleteDuplicatesConfirmation` | :1690-1709 |

That is about 105 lines in all.

**Still live:** the "Resume Deleting Duplicates?" alert at :1071. It is bound to `model.pendingDeleteDuplicatesResume`.

Periphery missed this because the `@State` is read through a binding.

**Caveat:** CatalogDuplicatesMenuTests.swift:134 and :137 are source-text sensors. They assert that this dead `.sheet(item: $deleteDuplicatesVolumePicker …)` and `showDeleteDuplicatesConfirm = true` exist, so deleting the code would turn them red.

### 4c. SignatureVerification (MediaOps/SignatureVerification.swift)

`quarantineAndDelete(_:hooks:)` (:830, 11 lines) is **test-only**. Tests call it in five files: SignatureConcurrencyScaleTests, SignatureVerificationOneSidedTests, DeleteDuplicatesCodex1593Tests, and others. It calls `deleteQuarantined` with the **default disposal `.permanent`** (:681), which is an unlink.

`deleteQuarantined(_:disposal:hooks:finalVerdict:)` (:680) is **live**. Its one production caller is MediaOps/DeleteDuplicatesJob.swift:519, which passes `disposal: .trash` and a `finalVerdict` closure. DeleteDuplicatesTrashOnlyTests:232-235 pins that every app call passes `.trash`.

Fact for the delete-safety owners, not a recommendation: the `.permanent` branch (:754) is reached by:

- `quarantineAndDelete`, which only tests call
- direct test calls
- in production, only if the job's `finalVerdict` returns `.proceed(.permanent)`. The comments at DeleteDuplicatesJob.swift:493 and :628 describe a Trash-only clamp. This survey did not verify that clamp.

Also flagged in the same file:

- `candidateDisclaimer` (:1012) is dead
- `verifiedAt` (:92) is assigned but never read

### 4d. People / Person Finder "Find…" POI face-matching path

The People tab is not a separate module. `PeopleTabView` hosts `PersonFinderView`, and `PersonFinderView` holds **both** the People gallery (the source of truth) and the "New Search…" jobs. `PersonFinderModel` holds both the POI profiles (shared) and the ScanJob engine (POI only). The split below is therefore partly per-file and partly by MARK section.

| Bucket | Swift lines | Other lines | Notes |
|---|---:|---:|---|
| **A. POI reference-photo search, exclusive** — 26 whole files | 10,080 | | ArcFace (Engine/Alignment/Predictor), AdaFaceEngine, PersonFinderDetection, Compilation, EngineDispatch, Cache (SQLite), CatalogFilter, InspectorTypes, PersonFinderModel+JobLifecycle (1,711), +Identity, IdentityNarrowing, EvalPresenceRule, PersonEvaluationCLI (`--evaluate`), PersonFinderView+Jobs/+Results/+Faces/+Helpers, RealtimeFaceDetectionWindow; Volumes/ScanJobRow (4 files), ScanJobsStorage, ScanRingChart |
| A, POI share of mixed files | ~1,710 | | PersonFinderModel.swift: ScanJob class :43-341, job/compile/reference loading :342-604, scan forwarders :1021-1091 ≈ 630. PersonFinderTypes.swift: FramePerf, RecognitionEngine, PersonFinderSettings :25-435 and ScanJobStatus…pfSegment :1306-1523 ≈ 650. PersonFinderView.swift ≈ 170. PersonFinderSubviews.swift: ReferenceFaceCard (already dead), CompactFaceThumbnail, ScanTargetPOIBadge (never instantiated) ≈ 250 |
| **A total (Swift)** | **~11,800** | | about 3.2% of app source |
| Legacy POI scripts and CLI (outside the app) | | 3,432 py + 2,122 Swift | face_recognize.py 462 (dlib; reached only through `--evaluate --engine dlib`), fd_diagnostic 489, fd_scan_volume 375, find_person 620, find_donna_scan 463, is_person_in_video 268, overnight_people_scan 309, convert_arcface_coreml 60, publish_poi_cycle_metrics 149, tests/run_personfinder_tests.py 237; swift_cli/PersonFinder.swift 1,338, FaceDetect 293, FaceDiagnose 491 |
| **B. Find & Tag** (catalog right-click Tags ▸ Find and Tag ▸ Donna; machine-tier recipe) | 3,406 | 582 py | FindPersonJob, FindTagCLI (`--find-tag` daemon), FindTagHelperStatusLine, NativeRecipeScorer, RecipeCalibrationCLI, RecipeGenderAgeGate, RecipeScoring, VideoScanModel+FindTagHelper; tools/donna-recipe/*. This is a second face-matching engine (SCRFD + ArcFace recipe), separate from A |
| **C. Review / holdout / confirm sessions** | 6,260 | | ConfirmPersonSheet (5 files), ConfirmRating, ConfirmationsView, Holdout* (6), UnifiedReviewSession, ValidationLabel(Store), PersonFinderTrainCandidates, Media/ReviewThumbnailRenderer. Humans confirm machine candidates, which produces **confirmed** tags (which Hallie uses) and eval labels |
| **D. Identify Family (face clustering sub-tab)** | 1,178 | 571 py | IdentifyFamilyModel/View, scripts/cluster_faces.py. Not reference-photo search, but the same face technology |
| **Shared, stays (People tab)** | ~7,360 + ~1,670 shared from mixed files | | POIStorage, POI*, PersonEditSheet, PersonFinderView+People (gallery, 931), FamilyGroup/EditSheet, FeaturedVideos, PersonVideosSection, Person*Resolver, PeopleTags, FamilyTagging, etc.; the POIProfile type (~870 lines of PersonFinderTypes); profile management (PersonFinderModel :605-1020); PersonCard. `SpinningRing` lives in PersonFinderSubviews.swift but is used by FamilyTree and Catalog |
| Not face-related, but in People/ | ~3,390 | | the Dossier dashboard, chip, propagation and carry-over (12 files) |
| Tests named for A/B/C | ~12,900 | | filename heuristic (PersonFinder, POI, ArcFace, Holdout, FindPerson, Recipe, ConfirmPerson, ScanJob, …), not hand-classified |

**What depends on POI outputs.** Both A and B write the **machine** person fields `detectedPeople` / `suspectedPeople`:

- A writes them through `PersonFinderModel`'s callback to `VideoScanModel.applyDetectedPeople` (ContentView.swift:182, People/VideoScanModel+FamilyTagging.swift).
- B writes them through `applyRecipeVerdict` (People/VideoScanModel+PeopleTags.swift:186-194).

Consumers of those fields:

- **Archive Angel:** the `machinePeople` scoring rule, which adds points for machine-detected people ("Looks like X (machine)"). ArchiveAngel/Recommend/ArchiveAngelScorer+Rules.swift:185-192, AngelRuleLanguage.swift:85, ArchiveAngelPolicy.default.json.
- **Catalog and Archive display:** the "Donna*" / "Donna?" machine-tier labels in Catalog/CatalogContent+Table.swift, Archive/ArchiveTimelineModel.swift:38, ArchiveView+Categories.swift:389 and MediaOps/MediaFileOperations.swift.
- **Rescan, duplicate and master-archive copy paths:** these carry the fields forward (VideoScanModel+RescanPreservation, +DuplicateEnrichment, +MasterArchive).
- **Hallie:** `ArchivistRecordExecutor` carries the fields as record facts, but presence answers deliberately **exclude** machine-only identity. Per ArchivistPresenceExecutor.swift:2-6, only `humanPersonTag` counts as proof. Hallie's other people dependency is POIStorage (People data), which stays.
- **Date inference:** does **not** use face hits. It reads People-tab birth years from POI profiles (Catalog/VideoScanModel+DateInference.swift:137, GH #201), which stays.

Structural couplings outside People that would need edits if A were removed:

- `PersonFinderModel` is an environment object in App/ContentView, DashboardState, BundleExporter, Shared/GauntletSeams, MediaOps/VideoScanModel+SoftDelete, and Media/CaptionOrchestrator (+Lifecycle).
- `PersonFinderSettings` appears in the bundle export/import models (App/BundleModels, BundleExportImport).
- `RecognitionEngine` is used in Volumes/MemoryPressure.
- `FindPersonJob` (B) is referenced by Shared/StallMonitor, Volumes/PhysicalStoreResolver, MediaOps/MediaFileOperationsWindow (`FindPersonDetailView`), and FootageSpectrumJob/Helper.

## 5. False positives and false negatives

Periphery treats these as live, correctly, so they are **not** in the lists above:

- CLI entry points reached from `main.swift` argv: FindTagCLI, PersonEvaluationCLI, RecipeCalibrationCLI, HallieShellCLI. Python and launchd call into the app through these flags.
- `@main`, `WindowGroup` and `Scene` views, `body`, and `#Preview`s (`--retain-swift-ui-previews`).
- Codable properties (`--retain-codable-properties`), including the keys of `ArchiveAngelPolicy.default.json`.
- `@objc` and NSObject-exposed members (`--retain-objc-accessible`).

Items in the lists that should **not** be trusted as removable:

- **Unused parameters (65).** They are counted, but at 0 lines. Most are required by a protocol or closure signature.
- **Assign-only properties (261/403).** Some are retained on purpose, for example stored `Task` handles kept for cancellation (`backfillTask`, VideoScanModel.swift:943) and diagnostic snapshots (`lastDiscoveryAudit`). Each needs a look; they are not bulk-deletable.
- **Test seams, injection overloads and test drivers in the test-only set:**
  - `TestEnvironment.detect(environment:…)`: production calls a no-argument wrapper, and the file is used in 8 places.
  - `FileHasher.fullHash(path:blockSize:)`
  - `VideoScanModel.deleteDuplicates(onVolume:verificationHooks:)`, a synchronous test driver for the same DeleteDuplicatesJob
  - `CatalogLock.acquire(waitingUpTo:pollInterval:)`
  - `POIStorage.rollbackUUIDMigration`, a recovery tool

  These exist so the tests can drive production logic. Removing them removes test coverage, not dead product code.
- **Deliberately parked code:** TrimJob/TrimEngine (kept after the Trim Master menu was retired), `StageBadge_Removed`, and `PythonSubprocessCaptionRunner` (a documented stub).
- **Source-text sensor tests.** CatalogDuplicatesMenuTests:134/137, AnalyzePanelSensorTests:196 and DeleteDuplicatesTrashOnlyTests read `.swift` files as text. Periphery does not see these as references, and deleting the pinned code turns those tests red.

Things Periphery **missed** (false negatives), found by hand:

- SwiftUI views that are declared but never constructed: CoverArtMusicPurgeSheet, UnrelatedAudioPurgeSheet, FamilyMusicSheet, ScanTargetPOIBadge.
- CatalogDuplicatesMenu: its nested type is used, but the view itself never is.
- `@State`-driven sheets whose trigger is never set (4b).
- Never-read `@Published` show-flags.

A grep pass over all ~600 View structs found only these; others may hide behind the same patterns.

Other limits of this survey:

- **VideoScanCore's public API was not analysed** (`--retain-public`).
- **Only the Debug configuration was indexed.** Code inside `#if !DEBUG` or other Release-only conditional blocks was not seen.
- `swift_cli/`, `scripts/`, `tools/` and UITests were not scanned.
- Line extents are heuristic (brace matching). Expect roughly ±10%.

Raw results: `build/periphery-with-tests.json` and `build/periphery-no-tests.json` in the M5 clone (gitignored, not committed).
