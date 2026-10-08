Brief: N1020-D-People | Source: main@c91abaa5 | Wall clock: 20 | Files read: 33
Finding count: 6 (REAL 6 / NEEDS-MAC 0 / NOISE 0)
Verdict: People has the known "damaged file read as empty, then saved over" bug in two curated stores, and the confirmed-vs-suspected split uses a distance cutoff on cosine-engine results, so the ArcFace, AdaFace and hybrid-fallback tag tiers are wrong; the rest is ordinary debt.

Scope: `VideoScan/VideoScan/People/` (85 Swift files, 32,920 lines). The working tree's People folder and tests are identical to `origin/main` c91abaa5 (checked with `git diff --stat`).

## Step 0: measurements

- Source: `ci/baselines/complexity_debt.json` (refreshed by the 2 AM job) and the latest `origin/metrics:metrics/complexity.jsonl` row (ts 2026-10-07T11:26Z, sha 4b79bbbb, lizard 1.22.1).
- People folder: 85 files, 1,198 functions, 35 offenders (26 with CCN > 15, 3 with CCN > 30, 23 longer than 80 lines), 8 files over 800 lines, mean CCN 3.69.
- **New offenders tonight: none.** Repo-wide `debt_new = 0`. `debt_worse = 1` repo-wide, but the jsonl row gives only the count, not which function, so I cannot say whether it is in People.

## Step 1: offender table (CCN > 15 or > 80 lines; baseline entries for People)

No new offenders, so the table is ordered by CCN.

| CCN | NLOC | Function | File |
|---|---|---|---|
| 42 | 214 | `POIStorage.migrateToUUIDFoldersIfNeeded` | POIStorage.swift |
| 37 | 72 | `PersonEvaluationCLI.parse` | PersonEvaluationCLI.swift |
| 32 | 213 | `FindTagCLI.run` | FindTagCLI.swift |
| 30 | 186 | `ActiveJobFaceDetectView.body` | RealtimeFaceDetectionWindow.swift |
| 28 | 48 | `CompatKey.shortLabel` | PersonFinderCompilation.swift |
| 26 | 127 | `pfConfirmRound` | PersonFinderTrainCandidates.swift |
| 24 | 168 | `pfProcessVideoWithArcFace` | ArcFaceEngine.swift |
| 24 | 158 | `PersonFinderModel.scanAllVideos` | PersonFinderModel+JobLifecycle.swift |
| 24 | 40 | `pfExtractAgeBuckets` | IdentityNarrowing.swift |
| 22 | 290 | `PersonFinderView.peopleGallery` | PersonFinderView+People.swift |
| 22 | 91 | `StreamInspectInfo.probe` | PersonFinderInspectorTypes.swift |
| 22 | 83 | `PersonEvaluationCLI.evaluate` | PersonEvaluationCLI.swift |
| 21 | 149 | `pfProcessVideo` | PersonFinderDetection.swift |
| 21 | 50 | `RecipeCalibrationCLI.parse` | RecipeCalibrationCLI.swift |
| 21 | 39 | `CatalogCoverage.init(records:scope:)` | DossierDashboardView+Coverage.swift |
| 20 | 152 | `PersonFinderView.loadedFacesStrip` | PersonFinderView+Faces.swift |
| 20 | 119 | `PersonFinderModel.startJobAfterLoad` | PersonFinderModel+JobLifecycle.swift |
| 20 | 66 | `pfFindVideoFiles` | PersonFinderCatalogFilter.swift |
| 19 | 64 | `VideoScanModel.applyDetectedPeople(confirmed:suspected:person:)` | VideoScanModel+FamilyTagging.swift |
| 18 | 75 | `PersonCard.body` | PersonFinderSubviews.swift |
| 17 | 75 | `pfLoadReferencePhotos` | PersonFinderDetection.swift |
| 17 | 59 | `FindPersonJob.handle` | FindPersonJob.swift |
| 16 | 81 | `PersonFinderModel.processOneVideo` | PersonFinderModel+JobLifecycle.swift |
| 16 | 81 | `FindPersonJob.run` | FindPersonJob.swift |
| 16 | 69 | `pfCandidatesForPerson` | PersonFinderTrainCandidates.swift |
| 16 | 54 | `RecipeCalibrationCLI.summarize` | RecipeCalibrationCLI.swift |
| 15 | 126 | `PersonFinderModel.runScan` | PersonFinderModel+JobLifecycle.swift |
| 15 | 88 | `PersonFinderModel.restoreFromCache` | PersonFinderModel+JobLifecycle.swift |
| 14 | 176 | `PersonEditSheet.body` | PersonEditSheet.swift |
| 13 | 91 | `PersonEditSheet.relationshipsSection` | PersonEditSheet.swift |
| 13 | 82 | `PersonFinderView.inspectorPopover` | PersonFinderView+Results.swift |
| 12 | 122 | `PersonFinderView.personCardEntry` | PersonFinderView+People.swift |
| 12 | 91 | avatar view `.body` (the dedication avatar file) | People/ (avatar view) |
| 9 | 185 | `DossierDashboardView.body` | DossierDashboardView.swift |
| 9 | 96 | `PersonFinderModel.runCompilation` | PersonFinderCompilation.swift |

Files over 800 lines (8, the same as the metrics row): PersonFinderModel+JobLifecycle.swift 1,711 · PersonFinderTypes.swift 1,523 · POIStorage.swift 1,214 · FindPersonJob.swift 1,162 · PersonEditSheet.swift 1,134 · PersonFinderModel.swift 1,091 · PersonFinderView+People.swift 931 · ArcFaceEngine.swift 832.

Note: lizard undercounts SwiftUI `body` and `some View` properties. `peopleGallery` (290 lines) and `ActiveJobFaceDetectView.body` are worse than their CCN suggests.

## Step 2: duplication, dead code, leftovers

**Three ways to update a curated sidecar (the main duplication).** People writes Rick's curated files in three different ways:
1. **Strict merge-on-write.** `HoldoutReviewQueue.recordAnswer` (HoldoutReviewQueue.swift:316) reloads the file from disk and throws on a parse failure, so it never rewrites from memory.
2. **Fail-closed identity check.** `POIProfileFileStore.save` → `checkIdentity` (POIProfileFileStore.swift:70–85) throws `unreadableIdentity` when an existing profile.json will not parse.
3. **Load as empty, then overwrite.** `ValidationLabelStore` and `HoldoutClearStore` do this. See F1 and F4.

`FamilyGroupStore.load` returns nil and `FamilyEditSheet.save` stops, so that one fails closed. The N1009 F1 / N1012 F2 class is present in People twice (F1, F4).

**Two distance conventions for one decision.** Vision results carry a feature-print distance (lower is better; the threshold is a distance). ArcFace and AdaFace results carry `1 − cosine` in `bestDistance` (ArcFaceEngine.swift:551), but their threshold is a cosine similarity. `splitByConfidence` mixes the two (F2). The results table's match colour bands (`matchColor`, PersonFinderView+Results.swift:18, and an inline copy at :223) hard-code the Vision bands 0.5 / 0.65 for every engine. That copy is display-only and is backlogged under F2.

**Two copies of the per-video scan loop.** `pfProcessVideo` (PersonFinderDetection.swift:508) and `pfProcessVideoWithArcFace` (ArcFaceEngine.swift:631) share 175 non-trivial lines verbatim:
- the reader setup (`pfOpenVisionVideoReader` / `openArcFaceVideoReader`, a 47-line identical block)
- the segment clusterer (`pfVisionClusterSegments` / `arcFaceClusterSegments`, a 44-line identical block; the doc comments say "Identical algorithm")
- the milestone logger and the largest-face selection

They have already drifted once (F3).

**Two `thresholdForEngine` functions.** One is on `PersonFinderSettings` (PersonFinderTypes.swift:261, clamped in `didSet`). The other is on `POIProfile` (:1253, clamped on read). They agree today; neither clamps the Vision threshold. Backlog: merge them.

**profile.json is decoded in five places.**
- `POIProfile.load(at:)` throws.
- `decodeProfilesTrackingLegacyUUIDs` skips the file.
- `load(name:)` skips it and moves on.
- `POIStorage.readProfileJSON` returns nil.
- `POIProfileFileStore.checkIdentity` throws.

Their failure handling differs, but I found no write path that turns a failed read into an empty profile and saves it. `write(profileJSONAt:)` keeps its own featured-video list when the on-disk file is unreadable, and its comment says so. Backlog only.

**Dead code.** I counted identifier tokens across every `.swift/.py/.sh` file in the repo (comments stripped; `.git`, `docs` and `.trash` excluded) and confirmed each hit with a repo-wide grep. Eight People declarations have no reference outside their own declaration. Seven of them were already flagged by periphery on 2026-09-22 (`docs/ops/metrics/periphery_2026_09_22.md`). See F6.

**Leftovers.**
- Two TODOs: PeopleTabView.swift:10 (env-object cleanup) and PersonFinderView+Results.swift:253 (inline playback). Both are wishes, not stale markers.
- No `TEMPORARY`, `FIXME`, `HACK`, `if true` or `if false`.
- One flag that is always on: `smearCleanupDryRun = true` (VideoScanModel+DossierPropagation.swift:255), there since 2026-06-30. See F5.

**Python and subprocess calls.**
- `IdentifyFamilyModel` uses `ProcessRunner`, checks the exit status in `handleTermination`, and can be cancelled. Fine.
- `FindPersonJob` has a stall monitor. Fine.
- `PersonEvaluationCLI.legacyDlibProcessVideo` has no deadline and ignores the exit code. That is a P3 note, kept under backlog rather than as a finding because it is an eval-only CLI.

## Findings

### N1020-D-People-F1: a damaged validation-labels file loads as "no labels", and the next rating overwrites it
- **Severity:** P2. Validation labels are Rick's hand-given ratings. They are the seed for the holdout queue (`tools/person-eval/build_holdout_queue_skeleton.py:9` cites "186 seed labels") and drive the Confirm sheet's "already labelled" skip. The Manager may raise this to P1 under "family record".
- **Class:** REAL. Foundation only.
- **Symbols:**
  - `ValidationLabelStore.load` (ValidationLabelStore.swift:54–62) uses `try? decoder.decode([ValidationLabel].self …)`. On failure it does nothing (no log at all) and leaves `labels = []`.
  - `ValidationLabelStore.record` → `save` (:83–103, :64–74) writes `encoder.encode(labels)` with `.atomic` and no backup.
  - Owner: `PersonFinderModel.validationLabels = ValidationLabelStore()` (PersonFinderModel.swift:613), created with the model.
- **Scenario:**
  1. The file holds N labels. One row stops decoding. For example, a newer build adds a `ConfirmRating` case, and an older build (a bisect, a Debug checkout of an older branch, the viewer Mac on an older build) reads the file. `ConfirmRating.init(from:)` throws on an unknown raw value (ConfirmRating.swift:56–60), and the decode is all-or-nothing over the array. A hand edit, a sync-tool conflict copy or a damaged block does the same.
  2. The app opens with `labels = []` and logs nothing.
  3. Rick rates one video. `record` appends it and `save` rewrites the file with exactly one label. All N earlier labels are gone, with no backup.
- **Guard looked for:** the callers, `PersonNameGuard.check` (it only refuses shared names), and any revision or unreadable flag. There is none. The existing test `UnifiedReviewSessionTests.isolation_garbageCSVAndGarbageLabelsDegradeIndependently` (:302–335) **pins today's behaviour**: it opens a junk file, records, and expects `labels.count == 1`. It never checks that the junk bytes survive.
- **Smallest pinning test** (ConfirmVerbTests, temp dir):
  1. Write a labels file holding two valid rows and one row whose `rating` is `"Background"`.
  2. Open `ValidationLabelStore(directory:)` and call `record(...)` once.
  3. Expect the original bytes to survive (unchanged, or renamed beside the file as `.damaged-*`). It fails today.

### N1020-D-People-F2: `splitByConfidence` uses a distance cutoff on cosine thresholds, so cosine-engine tag tiers are wrong
- **Severity:** P2. Every ArcFace, AdaFace or hybrid-fallback search writes the wrong catalog field (`detectedPeople` vs `suspectedPeople`) for the person. Nothing is lost and the tags can be re-run, but this is the person-tag record the People tab and Hallie read.
- **Class:** REAL. Pure arithmetic, no Apple behaviour involved.
- **Symbol:** `PersonFinderModel.splitByConfidence` (PersonFinderModel+JobLifecycle.swift:78–96): `strongCutoff = threshold − margin`, then confirmed iff `min(bestDistance) ≤ strongCutoff`.
- **Callers:**
  - `restoreFromCache` (:434) passes `profile.thresholdForEngine(engine)` (:340).
  - `runScan` (:1397) passes `settings.thresholdForEngine(settings.recognitionEngine)` (:1257).
  - For `.arcface` and `.adaface` that is the **cosine** threshold (PersonFinderTypes.swift:261–266).
  - For those engines `bestDistance` is `1 − cosine` (ArcFaceEngine.swift:551; AdaFace runs the same function through `cosineThresholdOverride`, :647/:668).
- **Scenario** (default knobs, margin 0.05):
  - **AdaFace**, threshold 0.30: cutoff 0.25, so a video is confirmed only when its best cosine is ≥ 0.75. Every match with cosine 0.30–0.75 goes to suspected. The intended rule ("within the margin of the threshold is suspected") would make only 0.30–0.35 suspected.
  - **ArcFace**, threshold 0.40: confirmed needs cosine ≥ 0.65.
  - **ArcFace with the threshold set to 0.60** (inside the 0.05–0.95 clamp): cutoff 0.55. Every match has distance ≤ 0.40, so **everything** is confirmed and the suspected tier disappears. The rule flips depending on the knob.
  - **Hybrid** with the Vision pass empty and the AdaFace fallback used (:1127–1137): the threshold is the Vision 0.52, so the cutoff is 0.47, so AdaFace matches with cosine below 0.53 are suspected.
- **Guard looked for:**
  - a conversion before the split (none; `filterResults` does not look at distances)
  - an engine argument to the split (none)
  - any test with cosine-engine values: the five `FamilyTaggingTests.splitByConfidence*` tests (:300–390) use only Vision distances against 0.52.
- **Smallest pinning test** (FamilyTaggingTests): build a `pfVideoResult` with `bestDistance: 0.40` (cosine 0.60). Call `splitByConfidence([r], threshold: 0.30)` the way the AdaFace path does, and expect it to be **confirmed**. It is suspected today. The fix needs a decision from Rick (see plan item 2).

### N1020-D-People-F3: the 4K detection cap was added to the Vision scan loop only; the ArcFace and AdaFace copy detects at full resolution
- **Severity:** P3. Cost and memory: no data at risk, and no wrong answer is shown.
- **Class:** REAL. The drift is plain in the source. The memory effect on 4K material would need a Mac to measure, but the finding is the drift itself.
- **Symbols:**
  - `pfProcessVideo` calls `pfDetectFacesInBuffer(…, longEdgeCap: pfDetectionLongEdgeCap)` (PersonFinderDetection.swift:607–608).
  - `pfProcessVideoWithArcFace` calls `pfDetectFacesInBuffer(frame.pixelBuffer, orientation: ctx.orientation)` with no cap (ArcFaceEngine.swift, about :727 in the loop).
  - The cap's own comment (PersonFinderDetection.swift:248–256) says it exists "so a converted/upscaled (e.g. 4K) clip can't beachball or exhaust memory".
  - `NativeRecipeScorer.swift:439` also applies the cap.
- **Scenario:** a 3840-wide clip searched with AdaFace, ArcFace or the hybrid fallback runs face detection on the full 33 MB frame, which is about 6x the pixels of the capped frame, on every sampled frame and on every concurrent worker. The same clip under Vision is capped.
- **Guard looked for:** a cap inside `pfDetectFacesInBuffer` when `longEdgeCap` is omitted. It defaults to nil (`PersonFinderDownsampleTests.nilCapReturnsOriginal`), so there is none.
- **Smallest pinning test:** a source sensor in the house style (like `UnifiedReviewSessionTests.sensor_*`). Read `ArcFaceEngine.swift` with `SourceTree.appSource(named:)` and expect every `pfDetectFacesInBuffer(` call to carry `longEdgeCap:`. It fails today. A better pin comes from plan item 3: once there is one loop, the copy can no longer drift.

### N1020-D-People-F4: a damaged or future-version holdout-clear file starts empty, and the next clear or undo overwrites it
- **Severity:** P3. Rows Rick set aside come back into the review badge and sheet. The header calls over-reporting "the safe failure", which holds for the badge. But the store also **saves over** the unreadable file, so the set-aside rulings are lost for good rather than just hidden.
- **Class:** REAL. Foundation only.
- **Symbols:**
  - `HoldoutClearStore.loadOffMain` (HoldoutClearStore.swift:361–377) returns nil on a decode failure and on `storeVersion != currentVersion`.
  - `save` (:349–356) → `saveOffMain` (:382–397) writes `allEntries` through `AtomicFilePublish` with no backup.
  - Writers: `ConfirmPersonSheet.holdoutClearCurrentRow` (ConfirmPersonSheet+HoldoutNavigation.swift:507–518) and `HoldoutReviewBadgePopover.persist` (:302–309).
- **Scenario:**
  1. The sidecar was written by a newer build (`storeVersion` 2), or a hand edit broke it. Its header says the file "is meant to be openable in an editor".
  2. An older build, or the same build, reads it as nothing. The badge over-reports, as designed.
  3. Rick clears one row. The file is rewritten with a single entry at version 1. The earlier clears are lost, and the newer build's file is downgraded.
- **Guard looked for:**
  - `refresh()` keeps memory when the load fails, which doesn't protect the file.
  - `HoldoutClearStoreTests.poison_corruptAndTruncatedFilesStartEmpty` (:176–205) checks only the start-empty half and never what the next save does.
- **Smallest pinning test** (HoldoutClearStoreTests):
  1. Write a valid-JSON file with `storeVersion: 999` and one entry.
  2. `load()`, `clear(...)` one other row, then `save()`.
  3. Expect the original bytes to still exist (unchanged, or as `.damaged-*` / `.v999` beside the file). It fails today.

### N1020-D-People-F5: `smearCleanupDryRun` has been on since 2026-06-30; the live branch it guards blanks records before writing its undo file, and ignores a failed write
- **Severity:** P3 today, because the live branch cannot be reached. If someone flips the flag as its comment invites ("one-line change + rebuild"), this becomes P2/P1: the catalog transcripts, captions and OCR it blanks could not be recovered.
- **Class:** REAL. A latent defect that contradicts its own comment.
- **Symbol:** `VideoScanModel.cleanupSmearedDossiersOnUnreadableRecords` (VideoScanModel+DossierPropagation.swift:255–286) and `writeSmearQuarantine` (:292–302).
- **Scenario with the flag false:**
  1. `clearSmearedDossiers()` blanks the live records.
  2. The gate key is set.
  3. Only then does `writeSmearQuarantine` run, using `try? data.write`. If the logs folder is unwritable, full, or the encode fails, the write fails silently.
  4. `saveCatalogDebounced()` then persists the blanked records.

  The doc comment at :245 says it "Quarantines the prior content … BEFORE blanking". The code does the opposite and does not check the result. In dry-run mode today, the dry-run gate is also set before the review list is written, so a failed write means the list is never produced and never retried.
- **Smallest pinning test:** make the quarantine writer injectable, or point `PersistentLog.logDir` at a read-only temp dir. Run the live path on one smeared record and expect the record **unchanged**, because the quarantine write failed. Today it would be blanked if the flag were false.
- **Recommendation:** ask Rick whether the review ever happened. If the live clean is no longer wanted, delete the live branch (smallest diff). If it is wanted, fix the order (write and verify the quarantine, then blank) before anyone flips the flag.

### N1020-D-People-F6: eight unused declarations, seven of them flagged by periphery on 2026-09-22 and still present
- **Severity:** P3. **Class:** REAL. Each was confirmed with a repo-wide grep of `.swift/.py/.sh`, including tests and scripts.
- **Symbols:**
  - `DialRing`, `StatRow`, `StatusBadge` (DossierDashboardView+Subviews.swift:20/61/111)
  - `StageBadge_Removed` (DossierDashboardView+Rows.swift:312; its own name says removed)
  - `MiniRing` (DossierToolbarChip.swift:109)
  - `ReferenceFaceCard` (PersonFinderSubviews.swift:28)
  - `ScanTargetPOIBadge` (PersonFinderSubviews.swift:324; new since the periphery run)
  - `PersonFinderView.browseForOutput` (PersonFinderView+Helpers.swift:93)
- **Scenario:** none at runtime. They inflate file sizes (DossierDashboardView+Subviews, PersonFinderSubviews) and mislead readers. For example, `RescueToolbarChip.swift:86` says it "mirrors DossierToolbarChip's MiniRing", which is dead.
- **Pinning:** none needed. Removal is a compile-checked delete: move the code to `.trash/` per the agent rules, then build.

## Step 3: ranked refactor plan

### 1. Make curated-sidecar saves fail closed: ValidationLabelStore + HoldoutClearStore (F1, F4). Data risk: curated labels. Size S. Risk low.
- **Steps:**
  1. Add the F1 and F4 pinning tests (red).
  2. Introduce one small shared shape, `SidecarLoad<T> = .missing | .loaded(T) | .unreadable(reason)`, used by both stores. This answers "how do we treat a damaged curated file" in one place. `HoldoutReviewQueue` and `POIProfileFileStore` already answer it fail-closed.
  3. On `.unreadable`, the store remembers it. The first `save` renames the damaged bytes to `<name>.damaged-<ISO8601>` beside the original (never delete), then publishes.
  4. Move `ValidationLabelStore.save` from `.atomic` to `AtomicFilePublish.write(_, to:, durability: .fullFsync)`, keeping `.sortedKeys` and `.prettyPrinted`.
  5. Log the unreadable case in `ValidationLabelStore.load`; it is silent today.
- **Tests that must exist first** (all exist except the two new ones):
  - `ConfirmVerbTests.store_recordPersistsImmediately`, `store_labeledByPathReturnsLatestForPerson`, `store_roundSummaryCountsAndSignalSources`
  - `TwoRichardsConsumerSensorTests` (the label-sink refusal leaves the file byte-identical, :418–438)
  - `UnifiedReviewAdversarialTests` (label custody)
  - `HoldoutClearStoreTests.saveThenLoad_roundTripsThroughJSON`, `theFileIsPlainReadableJSON_notTheReviewCSV`, `poison_corruptAndTruncatedFilesStartEmpty` (keep: the badge still over-reports), `sensor_badgeCountDropsToZeroAfterClearingTheLastRow`
  - `UnifiedReviewSessionTests.isolation_garbageCSVAndGarbageLabelsDegradeIndependently`: update it deliberately so it also checks that the junk bytes survive beside the file.
  - New: "damaged labels survive the next record" and "future-version clear file survives the next save".
- This is a curated-data write path, so it qualifies for a codex pass under the spend policy. The in-house `qa` agent is probably enough for a change this size.

### 2. Engine-aware confidence split (F2). Size S. Risk medium: it changes which field existing searches write. **Needs Rick's ruling on the cosine margin.**
- **Steps:**
  1. Add the F2 test (red) and two more: ArcFace at 0.40 with cosine 0.42 is suspected and 0.50 is confirmed; Hybrid with the AdaFace fallback.
  2. Give `splitByConfidence` the scale of its threshold: `enum MatchScale { case distance(Float), case cosine(Float) }`. For cosine, the confirmed condition is `bestDistance ≤ 1 − (threshold + margin)`.
  3. The two callers (:434, :1397) pass the engine-effective scale.
  4. Hybrid cannot know which pass produced a result today, because `pfVideoResult` has no engine field. Add an additive `matchedBy` field set in `processOneVideo`'s hybrid arm (:1127–1137), or mark fallback results before the split.
  5. Fold `matchColor` and the inline copy at PersonFinderView+Results.swift:223 into one helper on the same scale.
  6. Optional: a one-shot re-tier of existing cosine-engine tags. That one is Rick's call, because it touches the catalog.
- **Tests that must exist first:** `FamilyTaggingTests.splitByConfidencePartitionsAtCutoff`, `…JustBelowCutoffIsConfirmed`, `…JustAboveCutoffIsSuspected`, `…Empty`, `…UsesBestSegmentDistance` (these must keep passing unchanged for Vision); `PersonFinderLifecycleTests.thresholdForEngineSelectsPerEngineKnob`; `PersonFinderArcFaceCosineTests.cosineThresholdBoundaryIsInclusiveAtExactlyThreshold`; `AdaFaceRestoreRegressionTests.endToEnd_globalDrivenAdafaceRowsRehydrate`; `ConfirmedRejectedTagTests`.

### 3. One per-video scan loop for Vision and the cosine engines (F3 and the 175 duplicated lines). Size M. Risk medium: hot path, CoreMedia teardown races.
- **Steps, one commit each, each behaviour-preserving except step 4:**
  1. Make `pfVisionClusterSegments` internal. Point `arcFaceClusterSegments` at it, since they are byte-identical, and delete the copy.
  2. Do the same for the reader-open helpers and the milestone logger. The reader context structs differ only in name.
  3. Turn the loop body into one generic `pfScanVideo(matcher:)`, where the per-frame matcher closure returns `(hits, matched/unmatched rects, bestScoreInFrame, embedDrops)` and the two engine entry points become thin wrappers. Keep the "never `cancelReading()` from the consumer" comment once, at the single loop.
  4. Separate commit, Rick's ruling: apply `pfDetectionLongEdgeCap` to the cosine engines (F3). ArcFace crops from the full-resolution oriented image, as Vision does, so identity accuracy should not move. Confirm with the eval CLI on the holdout set before merging.
- **Tests that must exist first:**
  - New `SegmentClusterTests`: golden hit lists (gap-merge, pad-overlap merge, min-duration drop, clamp to 0 and to duration) run through the one clusterer. Write this before step 1, with both copies made internal, so it proves they are identical first.
  - `PersonFinderPresenceArithmeticTests`, `PersonFinderDownsampleTests`, `PersonFinderWatchdogTests`, `PersonFinderFpsClampTests`, `PersonFinderStopWhilePausedTests`, `PersonFinderEngineDispatchTests`, `ArcFaceMLE5CrashTests`, `StressTests` (the prefetcher teardown at :294–330).
  - The house media matrix (mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv synthetic fixtures) run through both engines on the Mac.

### 4. Split `POIStorage.migrateToUUIDFoldersIfNeeded` (CCN 42 / 214 lines). Data risk: the POI store migration. Size L. Risk high.
- **Ask Rick first:** the migration has run on every machine since 2026-09-12. If it is a no-op everywhere (`secondRunIsANoOpAndTakesNoSecondBackup`), freezing it (no edits) or retiring it behind a "migrated" marker may be cheaper than refactoring it.
- **If it stays, steps:**
  1. Extract a pure `planMigration(root:) -> (planned, skipped)` from the folder walk. No I/O beyond reads.
  2. Keep the existing backup step and its "backup failure means zero writes" gate in place, unchanged.
  3. Extract `executeMoves(plan)`.
  4. Extract `reconcileAndRebaseLinks(report)`.
  5. Extract `writeReport`.
  6. The top-level function then reads as plan → backup → execute → reconcile → report, with each guard still at the same boundary.
- **Tests that must exist first** (all exist, in POIUUIDMigrationTests): `twelveFolderFixtureMigratesSkipsAndAudits`, `secondRunIsANoOpAndTakesNoSecondBackup`, `rollbackRestoresTheLegacyNames`, `hundredProfilesWithAThousandFilesEachRenameInWellUnderASecond`, `refusesALiveShapedRootUnderTheTestHost`, `migrationNeverDeletesAFolder`, `interruptedAfterRenameThenRerunReconciles`, `backupFailureMeansZeroWritesAnywhere`, `rollbackRetainsUnresolvedEntries`, `skippedProfileSaveRefusesWithTheAuditReason`, `internalAbsoluteSymlinksDereferenceAfterMigrationAndRollback`, `faultInjectionBlocksNewEntriesButNotTheFolderRename`, `failedLinkRebaseKeepsTheOriginalLinkAndIsRetriedOnTheNextRun`, `rebaseInternalLinksIsAtomicPerLinkAndThrowsOnFailure`, `rollbackRetainsAFolderWhoseLinksCouldNotBeRebasedBackAndRetriesIt`. Also `POIUUIDFoldersTests.legacyFolderNameIsPersistedAndSurvivesASave`.
- A codex pass is justified here, since a miss costs the people store.

### 5. Thin out `PersonFinderModel+JobLifecycle.swift` (1,711 lines; five offenders). Size M. Risk medium.
- **Steps:**
  1. Extract the duplicated "finish a job's results" tail into one function: `filterResults` → below-floor summary line → `splitByConfidence` → `onComplete` → `onAnnotate`. It appears in `restoreFromCache` (about :410–437) and `runScan` (about :1380–1405). Plan item 2 then changes one call site, not two.
  2. Move the cache-restore family (`restoreFromCache`, `loadFacesForJob`, `referenceCacheIdentifiers`) and the descriptor family (`persistDescriptor`, `makeDescriptor`) into their own extension files. This is a mechanical move.
  3. Break `scanAllVideos` (CCN 24 / 158) at its natural seams: discovery, per-video dispatch, finish.
- **Tests that must exist first:** `JobLifecycleUncoveredPathsTests` (all 14), `PersonFinderLifecycleTests` (all 32), `PersonFinderMatchFloorTests`, `PersonFinderPresenceArithmeticTests`, `PersonFinderCacheTests`, `AdaFaceRestoreRegressionTests.endToEnd_globalDrivenAdafaceRowsRehydrate`, `PersonFinderStopWhilePausedTests`, `PersonFinderCloudPathTests`.

### Backlog (one line each)
- F5: Rick decides the smear cleanup. Delete the live branch, or fix its order (quarantine, verify, then blank) before the flag is ever flipped. Size S.
- F6: move the eight dead declarations to `.trash/`. Size S.
- `IdentifyFamilyModel.executePromotion` (about :575) uses `try? profile.save()` on a create, yet counts it as "created" and writes a `promoted_to_poi` breadcrumb. If the save is refused (viewer guard, settings-pollution guard, disk full), the copied faces sit in a uuid folder with no profile.json, which `listAll` skips. Surface the error and skip the count. Size S.
- Merge the two `thresholdForEngine` functions into one, and decide whether the Vision threshold needs a clamp. Size S.
- Consolidate the five profile.json readers behind one `POIProfileReader` with explicit outcomes (missing / unreadable / decoded). Size M.
- `PersonEvaluationCLI.parse` (CCN 37) and `RecipeCalibrationCLI.parse` (21): one table-driven argument parser. `FindTagCLITests` and the evaluation CLI tests must pin the flags first. Size S each.
- `FindTagCLI.run` (32 / 213): split into argument handling, batch loop and output. Pinned by `FindTagCLITests`. Size M.
- `PersonEvaluationCLI.legacyDlibProcessVideo`: pass `deadlineSeconds` and check `exitCode`, since `runStreaming` drops both. It is eval-only. Size S.
- `ActiveJobFaceDetectView.body` (30 / 186), `peopleGallery` (22 / 290), `loadedFacesStrip` (20 / 152): split the view bodies. Check for any O(records) work while doing it (GH #104 rule). Size M.
- `CompatKey.shortLabel` (28), `pfExtractAgeBuckets` (24): make them lookup tables. Size S.
- `pfConfirmRound` (26 / 127) and `pfCandidatesForPerson`: split along the training-round phases. Size M.
- `StreamInspectInfo.probe` (22 / 91): check it against the Catalog ffprobe parser; it is likely a third ffprobe-to-struct mapper. Size S to investigate.
- `HoldoutClearStore`: in-flight `save` racing `refresh()` → `load()` can, in principle, replace memory with the pre-save disk state. I did not trace this to a real interleaving, so it is not a finding. Worth a look when doing plan item 1.

## Not covered
- I did not read the view files beyond the offender list (PersonEditSheet, PeopleTabView, DossierDashboard*, ConfirmPersonSheet*), `FindPersonJob` in depth, `NativeRecipeScorer`, `RecipeScoring`, `IdentityNarrowing`, `PersonResolver` or `PersonPhotoResolver`.
- The recipe-tier path (`VideoScanModel.recipeThresholds`, FindTag) is a second detected/suspected tiering system that writes the same catalog fields as `splitByConfidence`. It is for a different engine, so it may legitimately differ. I did not compare them.

Callees followed outside scope: `ProcessRunner.runProcess` / `runStreaming` (VideoScanCore), `ConfirmRating.init(from:)`, and `tools/person-eval/build_holdout_queue_skeleton.py` (header only, for how the labels file is used).

## Blockers & environment
- `git fetch origin metrics main` failed for main with "cannot lock ref 'refs/remotes/origin/main'" (the stale local ref). I fetched `main` into `FETCH_HEAD` instead (c91abaa5) and confirmed with `git diff --stat` that the People folder and its tests in the working tree match it. The metrics ref fetched fine.
- I did not run `pip install lizard`, as the brief says. Numbers come from `ci/baselines/complexity_debt.json` and the metrics jsonl. The jsonl row has only the count for `debt_worse = 1`, not the function, so I cannot say whether it is in People.
- The README asks for a commit on a `cloud/<brief-id>` branch and a push. The Manager's launch brief for this row said explicitly **not** to commit or push, so the report is left uncommitted at `docs/reviews/cloud/N1020-D-People.md`.
- The sandbox clock seemed to barely advance between calls (it read 5 minutes elapsed near the end), so the wall-clock figure is an estimate.
- No Xcode, so nothing was built or run. Every claim comes from reading the source.
