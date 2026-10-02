# Test-gap audit — production code changed 2026-08-20 → 2026-10-01

Generated 2026-10-01 by the metrics agent at `main` 7f5c5864. Numbers only; recommendations are one line each. No code was changed.

## Headline

- 938 production files changed; **219,306 lines added** (gross, all commits); **145,562 effective lines** (min of lines added and current code lines per file, which removes churn from rewrite rounds).
- 11,493 test functions exist (10,491 `@Test`, 442 XCTest `func test…`, 699 pytest `def test_`).
- Most new code is referenced by tests. The gaps are concentrated in **sheets and views that carry decision logic**, in a few Hallie answer paths reached only indirectly, and in **five long operations that are not MFO jobs**.
- **Coverage is not measurable right now.** The last xccov number in `metrics/history.jsonl` (origin/metrics) is 2026-06-14 (20.8% overall, 38.6% logic). The gauntlet `.xcresult` bundles from 9/28–9/30 contain no coverage data. All density figures below come from source references, not execution.
- `.claude/metrics-baseline.json` does not exist, so there is no baseline to diff against.

## Top 10 by risk

Risk = weight × effective KLOC × (1 − test density), summed per file. Weight: data-risk 3, truthfulness 2, other 1, dev tooling 0.5. See Method.

| # | Folder | Lines added (effective) | Tests: direct (upper bound) | Missing dimensions | Open bugs | Risk | Recommendation |
|---|---|---|---|---|---|---|---|
| 1 | Hallie (answers) (w2) | 45,450 (31,867) | 2,741 (3,957) | none at folder level | #184, #185, #186 | 4.47 | Pin open live misses #184–#186 as red tests; add claim-leak negative cases to HallieGeneralAnswerBoundary (500 lines, 5 tests); give KinshipOverlay/Drill/DateOrdered direct tests (indirect only today). |
| 2 | Archive (w3) | 15,113 (9,587) | 1,215 (2,117) | none at folder level | #167 | 4.39 | Pull the per-row "checkable / disabled + reason" rules out of ArchivedWhatNextSheet (711 lines, 7 incidental tests; it is the delete-choice screen) into a pure type and pin every disabled reason; same for PromoteToArchiveSheet (2 tests). |
| 3 | FamilyTree: views/other (w1) | 23,358 (14,004) | 1,898 (3,038) | none at folder level | – | 2.44 | Mostly UI. Pin the two sheets that start data paths: RecordFinderFoundSheet (0 tests) routes only through RecordFinderFiling; FamilyTreeView (713 lines, 6 tests) tree-swap paths. |
| 4 | MediaOps: destructive (w3) | 10,403 (5,648) | 670 (699) | media | – | 1.27 | Strong negative-path suites (codex rounds). Gap: no media-matrix test; run Delete Duplicates and Prune Apply hash/verify over mp4/mov/mkv/mxf/dv fixtures. RescueFileCopier is not an MFO job. |
| 5 | Hallie/LLM (w2) | 2,581 (2,259) | 236 (352) | none at folder level | – | 1.05 | ArchivistEndpointSettings (508 lines, 9 tests) is mostly happy-path; add endpoint-down / model-missing / stale-tag cases. |
| 6 | ArchiveAngel/UI (w1) | 4,881 (3,128) | 126 (248) | none at folder level | – | 1.00 | ~40 direct tests per 1k lines (project median ~78); ArchiveAngelReviewSheet 620 lines / 7 direct tests; StartSheet has no isolation test though it reads persisted settings. |
| 7 | People (w1) | 5,554 (4,478) | 1,345 (1,708) | none at folder level | #133, #156 | 0.97 | PersonFinderView+People (547 lines, 1 test). Open #133 (People column/tags unreliable) and #156 (Find and Tag wedge) have no pinning test yet. |
| 8 | Core: FamilyTree/GEDCOM (w2) | 14,914 (9,046) | 1,360 (2,707) | none at folder level | – | 0.87 | TreeWalkGraph (192 lines) has no test reference; TreeWalker 353/6; GedcomFamilyGraph+Merge 277/4 feeds tree replacement; add merge conflict cases. |
| 9 | tools (dev tooling) (w0.5) | 6,753 (5,496) | 340 (634) | none at folder level | – | 0.85 | Out-of-app benches (qwen_two_turn.py 1,859 lines / 54 tests). Low weight; no action unless they gate merges. |
| 10 | Core: LifeAndTimes (w2) | 3,053 (2,040) | 109 (169) | none at folder level | – | 0.80 | What Hallie says ancestors lived through. HistoricalTimeline 264/4 and ServiceAge 294/6; add edge-year / uncertain-birth / non-US-region cases. |

Note on #1 and #2: they lead mainly on volume. Hallie (answers) is 31.9k effective lines in 140 files at ~86 direct tests per 1k lines, and Archive is 9.6k lines at ~127. Their risk sits in the specific thin files named above, not across the whole folder.

## Specific flags

### Production files with zero test references (≥60 effective lines)

"Zero" means no test function references any type or unique function in the file, no suite is named for it, and no source sensor names it. Several are exercised indirectly; that is noted where verified.

| Folder | File | Effective lines | Note |
|---|---|---|---|
| FamilyTree: CyberBrain writes/pull/filing | `FamilySearchPersonRefreshSheet.swift` | 203 | data-risk folder; coordinator has tests, sheet has none |
| Archive | `VerifyArchiveDetailView.swift` | 108 | view/UI |
| Archive | `ArchiveLockDetailView.swift` | 74 | view/UI |
| Hallie (answers) | `HallieAppTurnCoordinator+Drill.swift` | 237 | pronunciation drill turn flow |
| Core: FamilyTree/GEDCOM | `TreeWalkGraph.swift` | 192 | Core logic, not UI |
| Hallie (answers) | `HallieAppTurnCoordinator+Telling.swift` | 144 |  |
| Hallie (answers) | `HallieAppTurnCoordinator+PhotoCaption.swift` | 141 |  |
| MediaOps: other | `MissingAudioSheet.swift` | 253 | opens media; no tests |
| FamilyTree: views/other | `FamilyTreeDocumentsUI.swift` | 232 | view/UI |
| FamilyTree: views/other | `RecordFinderFoundSheet.swift` | 203 | view/UI |
| Hallie/Voice | `ArchivistSpeakerSettingsSheet.swift` | 162 | view/UI |
| FamilyTree: views/other | `TreeIdentityPickerSheet.swift` | 159 | view/UI |
| FamilyMusic | `FamilyMusicPane.swift` | 151 | view/UI |
| Catalog | `InspectorPlaceView.swift` | 131 | view/UI |
| FamilyTree: views/other | `FamilyCrestsPane.swift` | 128 | view/UI |
| ArchiveAngel/UI | `ArchiveAngelReadinessSheet.swift` | 107 | view/UI |
| People | `PersonFinderSubviews.swift` | 107 |  |
| MediaOps: other | `VerifyVideoDetailView.swift` | 103 | view/UI |
| ArchiveAngel/Seams | `AppConformances.swift` | 77 |  |
| Catalog | `TidyCatalogSheet.swift` | 64 | view/UI |
| ArchiveAngel/UI | `ArchiveAngelRowActions.swift` | 60 |  |
| tools (dev tooling) | `App.swift` | 204 |  |
| scripts: CI/nightly/gauntlet | `ci_select_xcode.sh` | 174 |  |
| scripts: CI/nightly/gauntlet | `reviewer_bench.py` | 145 |  |
| scripts: CI/nightly/gauntlet | `inventory.swift` | 143 |  |
| scripts: Hallie eval/harness | `install_hallie_kokoro.sh` | 107 |  |
| tools (dev tooling) | `review_status_line.py` | 72 |  |

Removed after manual check: `RecordFinder+Registry.swift`. The matcher reported zero, but `RecordFinderLinkTests.registryIsWellFormed` and 23 link tests exercise it through `RecordFinder.all`.

### Large new types with mostly happy-path tests (spot-checked by test name)

| File | Effective lines | Direct tests | Observation |
|---|---|---|---|
| `ArchivedWhatNextSheet.swift` (Archive) | 711 | 7, all incidental (PruneApplyTests) | Decides which working copies of archived media are deletable. No test pins the disabled-row reasons (offline, A/V half, unverified archive, missing file). |
| `HallieGeneralAnswerBoundary.swift` (Hallie) | 500 | 5 | The fail-closed gate on general-knowledge replies. One fail-closed test; no cases of a family claim slipping through. |
| `AngelRuleLanguage.swift` (ArchiveAngel/Recommend) | 673 | 10 | A rule language with one validation test (`ruleValidation`) and one decoding test; little malformed-input coverage. |
| `ArchivistEndpointSettings.swift` (Hallie/LLM) | 508 | 9 | Round-trip and default-fallback tests; nothing for endpoint down, model missing or a mismatched stored tag. |
| `DateTriangulator.swift` (Catalog: dates) | 631 | 39 | Mostly named real-world cases. Open #166 (OCR/captions/audio say one year, inference another) and #232 (filename month parsed as year) are the conflicting-evidence class and have no pinning test yet. Feeds archive year folders. |
| `PersonFinderView+People.swift` (People) | 547 | 1 | One test reference. |

Checked and **not** happy-path-only: `DeleteDuplicatesJob` (66 tests, mostly resume/stop/quarantine/put-back adversarial), `PruneApplyJob`/`+PruneApply` (20/12, held-copy and collision cases), `VerifyArchiveCopiesJob` (18, unreachable root / fixity moved under verify / path escape), `RecordFinderFiling` (22 + 25 related, refusals and no-half-state), `ResearchPerson` (26), `HallieKinshipApposition` (12), `HallieAncestorStatistics` (21), `LifeAndTimes`/`LivedThrough` (61).

### Long operations that are not MFO jobs (CLAUDE.md "Long operations" rule)

An MFO job is a type conforming to `MediaFileOperationJob`; there are 21. These long-running paths changed in the window and do not conform:

| Code | Lines added | Why it is long | Current progress surface |
|---|---|---|---|
| `FamilySearchPullCoordinator` (FamilyTree, data-risk) | 1,012 | default timeout 7 days (`testDefaultTimeoutCoversAnOvernightPull`); replaces the tree on disk | own sheet + `FamilySearchPullCenter` status |
| `FamilySearchPersonRefreshCoordinator` (FamilyTree, data-risk) | 675 | default timeout 1 h | own sheet |
| `RescueFileCopier` (MediaOps, data-risk) | 377 | copies media off aging drives | `RescueToolbarChip` |
| `ArchiveAngelSweep` (ArchiveAngel/Recommend) | 614 | background scoring of every active record, 500 records per slice | own `@Published` status |
| `ArchiveAngelHygieneSession` buffer Clear (ArchiveAngel/Review) | 423 | removes prepared batches (source comment cites 70+ GB) | Angel card |

Excluded by an explicit ruling: `FamilyTreeWalkCenter`. The source comment records the 2026-09-27 decision that there is "no background MFO walk any more", and it logs START/PROGRESS/OUTCOME. Its runtime on the full tree has not been measured here. Pre-window and unchanged: `VolumeCompare`/Relocate reconcile (#109 records a 1 h+ run) and PersonFinder `ScanJob`.

## Full table

Dimensions: L=logic, S=scale (100k), M=media matrix (≥3 of mp4/mov/mkv/mxf/dv in one test), I=isolation (poisoned state), Sn=sensor. `n/a` = the dimension does not apply to the folder's changed sources. `NO` = it applies and no direct test in the folder shows it. Folder-level "yes" means at least one test in the folder has it, not that every feature does.

| Folder | w | Files | Lines added | Effective | Direct tests | Upper bound | Tests/1k eff. lines | Neg-path name share | L | S | M | I | Sn | Zero-ref files | Bugs | Risk |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Hallie (answers) | 2 | 140 | 45,450 | 31,867 | 2,741 | 3,957 | 86 | 0.49 | yes | yes | yes | yes | yes | 3 | #184, #185, #186 | 4.47 |
| Archive | 3 | 52 | 15,113 | 9,587 | 1,215 | 2,117 | 127 | 0.47 | yes | yes | yes | yes | yes | 2 | #167 | 4.39 |
| FamilyTree: views/other | 1 | 60 | 23,358 | 14,004 | 1,898 | 3,038 | 136 | 0.51 | yes | yes | yes | yes | yes | 4 | – | 2.44 |
| MediaOps: destructive | 3 | 42 | 10,403 | 5,648 | 670 | 699 | 119 | 0.56 | yes | yes | NO | yes | yes | 0 | – | 1.27 |
| Hallie/LLM | 2 | 9 | 2,581 | 2,259 | 236 | 352 | 104 | 0.53 | yes | n/a | n/a | yes | yes | 0 | – | 1.05 |
| ArchiveAngel/UI | 1 | 21 | 4,881 | 3,128 | 126 | 248 | 40 | 0.42 | yes | n/a | yes | yes | yes | 2 | – | 1.00 |
| People | 1 | 71 | 5,554 | 4,478 | 1,345 | 1,708 | 300 | 0.48 | yes | yes | yes | yes | yes | 1 | #133, #156 | 0.97 |
| Core: FamilyTree/GEDCOM | 2 | 49 | 14,914 | 9,046 | 1,360 | 2,707 | 150 | 0.45 | yes | yes | n/a | yes | yes | 1 | – | 0.87 |
| tools (dev tooling) | 0.5 | 19 | 6,753 | 5,496 | 340 | 634 | 62 | 0.49 | yes | yes | yes | yes | yes | 2 | – | 0.85 |
| Core: LifeAndTimes | 2 | 7 | 3,053 | 2,040 | 109 | 169 | 53 | 0.42 | yes | n/a | n/a | n/a | yes | 0 | – | 0.80 |
| Hallie/Voice | 1 | 18 | 7,268 | 4,798 | 440 | 704 | 92 | 0.46 | yes | n/a | n/a | yes | yes | 1 | #187 | 0.75 |
| scripts: CI/nightly/gauntlet | 0.5 | 22 | 4,579 | 3,539 | 336 | 775 | 95 | 0.51 | yes | yes | yes | yes | yes | 3 | #105, #171 | 0.66 |
| FamilyTree: CyberBrain writes/pull/filing | 3 | 13 | 8,847 | 5,453 | 728 | 1,142 | 134 | 0.57 | yes | n/a | NO | yes | yes | 1 | – | 0.61 |
| People: holdout review | 1 | 8 | 2,266 | 1,461 | 293 | 2,092 | 201 | 0.49 | yes | yes | yes | yes | yes | 0 | – | 0.61 |
| Catalog | 1 | 62 | 5,100 | 3,967 | 1,336 | 1,965 | 337 | 0.45 | yes | yes | yes | yes | yes | 2 | – | 0.50 |
| MediaOps: other | 1 | 59 | 6,202 | 5,038 | 1,191 | 1,678 | 236 | 0.49 | yes | yes | yes | yes | yes | 2 | – | 0.47 |
| Hallie/Web | 1 | 7 | 2,589 | 1,934 | 75 | 89 | 39 | 0.41 | yes | yes | yes | yes | NO | 0 | – | 0.45 |
| FootageGroups | 2 | 8 | 2,836 | 1,748 | 368 | 668 | 211 | 0.44 | yes | yes | yes | n/a | yes | 0 | – | 0.31 |
| ArchiveAngel/Recommend | 2 | 15 | 7,967 | 4,252 | 353 | 464 | 83 | 0.29 | yes | yes | yes | n/a | yes | 0 | – | 0.26 |
| FamilyMusic | 1 | 4 | 594 | 415 | 21 | 21 | 51 | 0.24 | yes | yes | n/a | n/a | NO | 1 | – | 0.21 |
| Core: FamilyMap | 2 | 6 | 3,063 | 1,781 | 432 | 827 | 243 | 0.45 | yes | n/a | n/a | n/a | yes | 0 | #235 | 0.21 |
| ArchiveAngel/Prepare | 1 | 7 | 3,681 | 1,983 | 649 | 792 | 327 | 0.37 | yes | yes | yes | n/a | yes | 0 | – | 0.17 |
| Hallie/Shell | 1 | 7 | 2,678 | 2,435 | 142 | 165 | 58 | 0.49 | yes | n/a | n/a | yes | yes | 0 | – | 0.17 |
| Volumes | 1 | 48 | 1,286 | 1,084 | 1,738 | 2,544 | 1603 | 0.42 | yes | yes | yes | yes | yes | 0 | #109, #110, #173 | 0.16 |
| Catalog: dates | 2 | 5 | 2,744 | 1,543 | 148 | 159 | 96 | 0.47 | yes | yes | yes | yes | NO | 0 | #166 | 0.10 |
| scripts: Hallie eval/harness | 0.5 | 7 | 2,428 | 1,661 | 534 | 749 | 321 | 0.45 | yes | yes | n/a | yes | NO | 1 | – | 0.10 |
| ArchiveAngel/Seams | 1 | 2 | 304 | 140 | 3 | 9 | 21 | 0.00 | yes | yes | n/a | yes | NO | 1 | – | 0.08 |
| App | 1 | 20 | 1,348 | 1,252 | 194 | 372 | 155 | 0.47 | yes | yes | yes | yes | yes | 0 | – | 0.07 |
| Shared | 1 | 21 | 337 | 212 | 518 | 1,432 | 2443 | 0.45 | yes | yes | yes | yes | yes | 0 | – | 0.07 |
| Core: dates/events | 2 | 7 | 1,358 | 914 | 557 | 1,012 | 609 | 0.41 | yes | n/a | yes | n/a | yes | 0 | #232 | 0.06 |
| ArchiveAngel/Review | 1 | 5 | 1,361 | 710 | 81 | 127 | 114 | 0.38 | yes | n/a | yes | NO | NO | 0 | #233 | 0.03 |
| Core: other | 1 | 16 | 1,332 | 852 | 1,006 | 1,783 | 1181 | 0.35 | yes | n/a | yes | yes | yes | 0 | – | 0.01 |
| ModelsUI | 1 | 2 | 12 | 12 | 211 | 300 | 17583 | 0.53 | yes | n/a | NO | n/a | yes | 0 | – | 0.01 |
| ArchiveAngel/Facade | 1 | 7 | 1,377 | 690 | 541 | 541 | 784 | 0.37 | yes | n/a | n/a | yes | yes | 0 | – | 0.00 |
| Core: CyberBrain + facts | 3 | 10 | 3,574 | 2,664 | 555 | 1,065 | 208 | 0.51 | yes | n/a | yes | n/a | yes | 0 | #188 | 0.00 |
| Core: RecordFinder | 3 | 3 | 1,630 | 897 | 84 | 84 | 94 | 0.51 | yes | n/a | n/a | n/a | yes | 0 | – | 0.00 |
| Core: Archive/ledger/fixity | 3 | 5 | 1,842 | 862 | 305 | 455 | 354 | 0.47 | yes | n/a | yes | n/a | yes | 0 | – | 0.00 |
| Core: prune/publish/folders | 3 | 3 | 2,034 | 1,086 | 117 | 281 | 108 | 0.56 | yes | n/a | n/a | n/a | yes | 0 | – | 0.00 |
| scripts: family map build | 1 | 1 | 1,104 | 880 | 41 | 112 | 47 | 0.61 | yes | n/a | n/a | n/a | NO | 0 | – | 0.00 |
| scripts: People-folder migration | 3 | 1 | 642 | 510 | 66 | 70 | 129 | 0.65 | yes | n/a | n/a | n/a | NO | 0 | #233 | 0.00 |
| Media | 1 | 56 | 1,071 | 704 | 1,580 | 1,920 | 2244 | 0.42 | yes | yes | yes | yes | yes | 0 | #134 | 0.00 |
| Model | 1 | 3 | 305 | 305 | 1,039 | 1,258 | 3407 | 0.51 | yes | yes | yes | yes | yes | 0 | – | 0.00 |
| People: folders/storage | 3 | 1 | 1,002 | 766 | 85 | 142 | 111 | 0.56 | yes | n/a | n/a | yes | yes | 0 | – | 0.00 |
| Volumes: retire/delete | 3 | 2 | 228 | 163 | 36 | 45 | 221 | 0.56 | yes | yes | n/a | n/a | yes | 0 | – | 0.00 |
| ArchiveAngel/Promote | 3 | 5 | 1,473 | 833 | 153 | 225 | 184 | 0.52 | yes | yes | n/a | n/a | yes | 0 | – | 0.00 |
| ArchiveAngel/Check | 2 | 1 | 582 | 308 | 61 | 73 | 198 | 0.38 | yes | n/a | n/a | n/a | yes | 0 | #231 | 0.00 |
| Core: tree-ingest CLI | 1 | 1 | 202 | 157 | 0 | 105 | 0 | 0.00 | NO | n/a | n/a | n/a | yes | 0 | – | 0.00 |

Open bugs not tied to a folder above: #171 (nightly static analysis), #105 (nightly UI runner), #173 (CI Build & Test, VolumeDetailPane); these are counted under scripts/CI and Volumes.

## Method

**Scope.** `git log --since=2026-08-20 --numstat` on `VideoScan/VideoScan/`, `VideoScan/VideoScanCore/Sources/`, `scripts/`, `tools/`, limited to `.swift`/`.py`/`.sh`, excluding tests, `/.build/` and anything under a `Tests` or `tests` dir. The 2026-09-29 folder reorg (69b616f1) was pure renames, so pre-reorg history recorded under old flat paths was re-attached by basename (names are unique per `docs/guides/source_layout.md`). Files deleted since 8/20 are excluded (≈5k lines, e.g. the retired Refile and Assess Copies code).

**Grouping.** Folders follow `docs/guides/source_layout.md`. The data-risk files it names are split into their own rows: MediaOps destructive lanes, FamilyTree CyberBrain writes / FamilySearch pull / filing, Volumes retire/delete, ArchiveAngel/Promote. People folder storage (`POIStorage`, `migrate_people_folders.py`) is data-risk too. VideoScanCore is split by affinity: CyberBrain + facts, Archive/ledger/fixity, prune/publish/folders, RecordFinder (all data-risk); GEDCOM/tree, FamilyMap, LifeAndTimes, dates/events (truthfulness).

**Weights.** Data-risk 3. Truthfulness 2: Hallie answers and LLM lane, dates, GEDCOM/tree logic, LifeAndTimes, FamilyMap, Angel Recommend/Check, FootageGroups. Other 1. Dev tooling 0.5 (`tools/`, CI/nightly scripts, Hallie eval harness).

**Test references.** Each test function (`@Test`, XCTest `func test…`, pytest `def test_`) is segmented from the 1,006 test files. A test counts for a production file if:
1. its body names a type declared only in that file, or a function name (≥8 chars) declared only in that file; or
2. it sits in a suite named for the file (`FooTests` for `Foo.swift` / `X+Foo.swift`, or a suite whose name is a ≥12-char prefix of the file stem); or
3. (upper bound only) its test file references the file's identifiers at file level, e.g. through helpers.

Source sensors that name the file by string (`SourceTree.appSource(named:)`) are counted separately as sensors. "Direct" = rules 1–2; "upper bound" adds rule 3. Known biases: generic names (e.g. `RecordFinder.all`) hide real references, so every zero above was checked by grep. Rule 3 over-credits.

**Density and risk.** Per file: effective lines = min(lines added, current non-blank non-comment lines). Density = min(1, tests ÷ (effective lines × 50/1000)), i.e. a target of 50 tests per 1k effective lines. The project median for folders ≥500 lines is ~78. Risk = weight × effective KLOC × (1 − density), summed per folder. Open bugs are shown but not in the score.

**Dimensions.** Applicability comes from the changed sources. Scale applies if they iterate `records`. Media applies if they call ffprobe/ffmpeg/AVAsset. Isolation applies if they read `UserDefaults.standard`, Application Support or the home directory. Logic and sensor always apply. Presence is judged from direct test bodies: 100_000-scale literals or names; ≥3 of the five container/codec markers; `poison`/`suiteName:`/isolated defaults; a sensor-named test or `appSource(named:)`.

**Negative-path share** = fraction of direct test names containing refusal/failure/edge words (fail, refuse, never, missing, stale, cancel, …). It is a rough heuristic; the happy-path table was confirmed by reading the names.

**MFO check.** Types conforming to `MediaFileOperationJob` were listed. Changed code holding its own running/progress state, or carrying long timeouts, outside those types was then read by hand.

**Bugs.** `gh issue list --label bug --state open` (19 open), mapped to folders by hand from title and body.

**Not measured.** Execution coverage (no xccov data since 2026-06-14). Cyclomatic complexity (swiftlint not run for this audit). Test runtime.

