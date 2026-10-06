Brief: N1009-D-Core | Source: main@9dc177d | Wall clock: 12 | Files read: 36
Finding count: 3 (REAL 2 / NEEDS-MAC 1 / NOISE 0)
Verdict: Core has no new complexity offenders and is mostly well consolidated. There is one real data-loss path: a damaged identity-rulings file loads as empty, and the next Hide click overwrites it. The top debt items are PrunePlan.swift (data risk), the five places that must stay in sync for each VideoRecord field, and the GEDCOM parser init.

Theme D (debt / refactor plan). Scope: `VideoScan/VideoScanCore/Sources/` (145 Swift files, 42,769 lines).
Read-only run. No source, test or project file was changed. Per the caller's instruction this file was
not committed or pushed (the README says to push a `cloud/<id>` branch; the caller said not to).

Callees followed outside scope to settle findings:
`VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift` (`setRecordHidden`, the load sites),
`VideoScan/VideoScan/Shared/ProcessRunner.swift`, `VideoScan/VideoScan/Media/PreviewFrameRoute.swift`,
`VideoScan/VideoScan/MediaOps/DuplicateDetector.swift`, `VideoScan/VideoScan/Archive/ArchiveTimelineModel.swift`,
`VideoScan/VideoScan/People/PersonFinderCache.swift`, `VideoScan/VideoScan/FamilyTree/FamilyKinshipOverlay.swift`,
and the matching tests.

---

## Step 0: the M4's nightly numbers

- `origin/metrics` exists. The latest `metrics/complexity.jsonl` row is from 2026-10-06T11:36Z, sha `a70a3562`, lizard 1.22.1.
  Between `a70a3562` and `origin/main` (`9dc177d`), `git diff` shows **no change under
  `VideoScan/VideoScanCore/Sources`**, so those numbers describe tonight's code exactly.
- Core folder: 145 files, 1,841 functions, **56 offenders** (50 with CCN > 15, 5 with CCN > 30, 17 with NLOC > 80), 8 files over 800 lines, mean CCN 3.72.
  By offender count that is third behind Hallie (118) and MediaOps (48).
- The repo-wide top 15 contains **no Core function**.
- Ratchet (`complexity_debt_latest.json`): new = 3 and worse = 2, all in `scripts/` or `Steward/`.
  **There are no new or worse offenders in this scope**, so step 0 adds nothing to the front of the plan.

## Step 1: lizard

`pip install lizard` was **refused by the permission system** in this session (tried twice).
In its place I used the M4's lizard 1.22.1 output from the same code (see step 0): the per-function
CCN and NLOC in `complexity_baseline_proposed.json`, filtered to Core. I took file sizes from `wc -l`.
lizard undercounts SwiftUI computed properties, but Core has no SwiftUI views, so that gap does not apply here.

### Functions over the gate (CCN > 15 or NLOC > 80): top 20 of 56

| CCN | NLOC | Function | File:line |
|---:|---:|---|---|
| 43 | 114 | `GedcomFamilyGraph.init(gedcomText:)` | GedcomFamilyGraph.swift:407 |
| 36 | 85 | `GedcomFamilyGraph.relatives` (kinship path) | GedcomKinshipPath.swift:99 |
| 34 | 179 | `TreeIndex.init(graph:)` | GedcomFamilyGraph+Index.swift:311 |
| 33 | 73 | `GedcomFamilyGraph.applyingFactOverlay` | PersonFactOverlay.swift:196 |
| 32 | 238 | `Scan.apply` | FamilyMap/BirthplaceUnitResolver.swift:327 |
| 29 | 163 | `CyberBrainWriter.appending(_ testimony:to:)` | CyberBrainWriter.swift:201 |
| 27 | 176 | `VideoRecordDTO.encode(to:)` | VideoRecordDTO.swift:305 |
| 26 | 57 | `EmbeddedDateParser.parseSingle` | EmbeddedCreationDate.swift:68 |
| 26 | 132 | `GedcomFamilyGraph.merge(with:)` | GedcomFamilyGraph+Merge.swift:139 |
| 26 | 53 | `GedcomFamilyGraph.gedcomText` | GedcomFamilyGraph+Writer.swift:28 |
| 26 | 44 | `PrunePlan.Family.logLine` | PrunePlan.swift:744 |
| 24 | 106 | `FamilyTreeNameSearch.init(graph:)` | FamilyTreeNameSearch.swift:126 |
| 23 | 33 | `EventLabeler.scanWords` | EventLabeler.swift:550 |
| 23 | 73 | `GedcomCompiledTree.verify` | GedcomCompiledTree.swift:440 |
| 22 | 100 | `FindTagIngestEngine.pass` | FindTagIngestEngine.swift:79 |
| 20 | 106 | `PreviewSweepEngine.run` | PreviewSweepEngine.swift:117 |
| 17 | 108 | `CyberBrainWriter.correcting` | CyberBrainCorrections.swift:160 |
| 1 | 126 | `VideoRecord.init(from:)` | VideoRecord.swift:665 |
| 1 | 126 | `VideoRecord.snapshotClone` | VideoRecord+Clone.swift:43 |
| 1 | 125 | `VideoRecordDTO.init(_:)` | VideoRecordDTO.swift |

The other 36 have CCN 16–22 and are mostly label switches and classifiers in `LifeAndTimes/` and `FamilyMap/`
(`Country.label`, `Region.label`, `OccupationCategory.label`, `FamilyMapFlag.emoji`). Most of those are flat
`switch` tables: high CCN, low risk, and not worth refactoring.

### Files over 800 lines

| Lines | File |
|---:|---|
| 1262 | GedcomFamilyGraph.swift |
| 1240 | PrunePlan.swift **(data risk: prune)** |
| 1050 | FamilyGraphCompiledStore.swift |
| 1016 | CyberBrainWriter.swift (curated testimony writes) |
| 899 | FamilyMap/BirthplaceUnitResolver.swift |
| 898 | ProcessRunner.swift |
| 855 | VideoRecord.swift |
| 802 | GedcomCompiledTree.swift |

## Step 2: duplication, dead code, leftovers

**Core vs app-target same-named helpers.** I scripted a comparison of every `func` name declared in Core against the app target
and found about 60 shared names. I read each plausible pair:

- `firstExecutable`/`resolve` (FFmpegLocator vs ToolLocator): the app copy **forwards** to Core. One implementation.
- `PreviewRoute` (Core vs app `PreviewFrameRoute.swift`): the route decision exists only in Core. The app file keeps only the negative cache.
- `InMemoryPreviewSweepFailureStore` vs `ThumbnailFailureStore`: these differ on purpose and the difference is documented.
  The CLI's store lives for one process and drops new entries at its cap. The app's store drops the oldest entries and is signature-checked.
- `electKeeper`: `PrunePlan` (archive copy families: most free space, then a new device, then the lower path) vs `DuplicateDetector`
  (volume precedence, then human metadata, then the technical score). These answer two different questions for two features, and both are pinned. Not a finding.
- `plausibleYear`: `RecordDateResolver` (1900 to next year) vs `ArchiveTimelinePath` (1900–2099). The timeline reads the
  archive's own folder layout back; it does not date a record. Not the C01-F1 class.
- `GedcomFamilyGraph.year(in:)` vs `FamilyTreeDuplicates.birthYear`: two "first 4-digit year" scanners that disagree
  only on runs of 5 or more digits and on years below 1000 or from 2200 on. That does not change any duplicate decision, because a group
  still needs a corroborating signal. Backlog consolidation only.
- `FileIdentityStamp` and `ContentFixity`: already consolidated into one `describesSameFile` with explicit rules. Good.

**Dead code.** I counted identifier tokens across all `.swift/.py/.sh` files in the repo (comments stripped, `.git` excluded), then confirmed each hit with a repo-wide grep.
Out of 2,105 public Core names, **7 have no reference anywhere** outside their declaration, including tests and tools. Four were already flagged by
periphery on 2026-09-22 (`docs/ops/metrics/periphery_2026_09_22.md`) and are still there. See F3.

**Leftovers.** Core has no `TODO`, `FIXME`, `HACK` or `TEMPORARY` markers, no `if true` or `if false`, and no always-on static
flags. The one `#if DEBUG` (TimingBudget.swift:28) is intentional. The only `print` calls outside the two CLIs are
`TimingBudget.swift:237` (test-budget reporting), which is fine.

**Write conventions.** `AtomicFilePublish` was introduced so that one entry point owns temp, write, publish and cleanup.
Several Core writers still roll their own. Six use `Data.write(.atomic)`:
`FamilyIdentityDecisions.save`, `FindTagIngestState.save`, `PersonOfTheDayHistory`, `TreeWalkStore`,
and `FamilyGraphCompiledStore` (artifact, manifest and pointer). `CyberBrainWriter.save` uses a hand-rolled temp, `fsync`, backup and `rename`.
`.atomic` does not use RENAME_SWAP (the header measured it as safe), so none of these can wedge the kernel.
The gap is **durability**. See F2, and plan item 5.

---

## Findings

### N1009-D-Core-F1: a damaged identity-rulings file reads as "nothing ruled", and the next ruling overwrites it
- **Severity:** P2. Rick's hand-curated identity rulings can be erased, and the header records some as "weeks" of research.
  The Manager may raise this to P1 under "family record".
- **Class:** REAL. Foundation only, no Apple-specific behaviour involved.
- **Symbols:** `FamilyIdentityDecisions.decode` / `loadWithRevision`, VideoScanCore/Sources/VideoScanCore/FamilyIdentityDecisions.swift:215–256.
  `FamilyIdentityDecisions.save(to:)` at :258–266.
  Caller: `FamilyTreeLiveModel.setRecordHidden`, VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift:2357–2390.
- **Scenario:**
  1. The rulings file exists but will not parse. Either Rick hand-edits it (the save comment says "Rick edits this by hand") and leaves a trailing comma, or the file is torn.
  2. `decode` logs "could not be read, so NO ruling is in force" and returns an empty `FamilyIdentityDecisions()`.
     `FamilyTreeLiveModel` installs it at :596, :823/853 or :1266. `identityRulingsUnsaved` stays false and the revision reads `"unreadable"`, but nobody checks it.
  3. Rick clicks Hide on one record. `setRecordHidden` builds `updated = identityDecisions` (empty) plus the one new ruling, then calls
     `updated.save(to:)`. That does `encoder.encode(ordered).write(to:, options: .atomic)` over the damaged file, with **no backup and no refusal**.
  4. Every earlier ruling is gone for good. The file was damaged but recoverable by hand, and now it holds one entry.
  - The existing tests `anUnparseableFileIsReportedRatherThanTreatedAsEmpty` and `anUnreadableOrMissingFileMeansNothingHasBeenRuledYet`
    check the load side only. Nothing covers what happens on the next save.
- **Guard looked for:** I found no backup in `save`, no "unreadable" check in `setRecordHidden` (the only `save(to:)` caller, :2380), and no fail-closed check on the revision. `FamilyAssetStore`
  reads the revision string but does not write.
- **Smallest pinning test** (`FamilyIdentityDecisionsTests`):
  1. Write `"{ not json"` to `fileURL(in: dir)`.
  2. Load it (empty), `record` one decision, then `save(to: dir)`.
  3. Expect either that `save` throws, or that the original bytes still exist (for example as a `.damaged-<ts>` sibling or a backup).
  - This fails today: the file is overwritten and no copy of the original bytes is left.
- **Fix shape (on the Mac, after Rick's go):** these steps are additive.
  1. `loadWithRevision` keeps returning empty, so the tree still opens.
  2. `save` refuses to overwrite a file whose current bytes do not decode, or moves it aside first (rename, never delete).
  3. Route the write through `AtomicFilePublish.write(…, durability: .fullFsync)`, as `PersonFactOverlay` already does.

### N1009-D-Core-F2: three different durability levels for curated JSON in Core
- **Severity:** P3.
- **Class:** NEEDS-MAC. Losing data on power loss or a forced reboot can only be shown on APFS hardware.
- **Symbols:**
  - `FamilyIdentityDecisions.save(to:)` FamilyIdentityDecisions.swift:265 (`.atomic`, no fsync).
  - `CyberBrainWriter.save` CyberBrainWriter.swift:883/916 (`fsync(2)`, not `F_FULLFSYNC`, plus a backup).
  - `PersonFactOverlay` save PersonFactOverlay.swift:382/392 (`AtomicFilePublish … .fullFsync`).
- **Scenario:** a forced reboot right after a Hide click. AtomicFilePublish's own documentation for `.fast` says APFS "may
  surface the rename ahead of the data", which can leave the rulings file empty or garbled. Combined with F1, the
  next ruling then erases the rest. CyberBrain's `fsync` does not flush the drive cache on macOS (AtomicFilePublish.swift:387
  says why it uses `F_FULLFSYNC` instead). Its backup softens this, but the backup is written with the same weaker call.
- **Pinning test:** a source sensor, in the style of `AtomicFilePublishSensorTests`, that fails if a Core type documented as curated data
  (FamilyIdentityDecisions, CyberBrainWriter, PersonFactOverlay) writes with anything other than `AtomicFilePublish` at `.fullFsync`.
  It is red today for the first two.

### N1009-D-Core-F3: seven public Core symbols have no caller anywhere in the repo
- **Severity:** P3.
- **Class:** REAL (verified with a repo-wide grep including tests, `scripts/` and `tools/`).
- **Symbols:**
  - `ArchiveMedium.isProbeable` ArchiveMedium.swift:78
  - `VideoRecord.footageRole` FootageMembership.swift:193
  - `GauntletFixturePlan.leftOnlyPair` GauntletFixturePlan.swift:47
  - `GedcomFamilyGraph.knownCountries` GedcomFamilyGraph+Lineage.swift:317. Its doc comment says "Used by the question parser"; no parser references it, so the comment is stale too.
  - `TreeLineStatistics…Side.nearestGeneration` TreeLineStatistics.swift:70
  - `VideoRecord.dateCreatedSortKey` VideoRecord+Derived.swift:186
  - `VideoRecord.dateModifiedSortKey` VideoRecord+Derived.swift:189
- **Scenario:** none of these break behaviour today. Each one is API that reads as live. `knownCountries` in particular invites a
  second country list to drift from `BirthplaceClassifier`'s table. The two `*SortKey` properties suggest the catalog sorts dates with a
  nil-means-distant-past rule, and it does not use them.
- **Pinning test:** none needed. The proof is "the build still passes after deleting them". Run periphery again afterwards to confirm the 09-22 list has shrunk.

---

## Step 3: ranked refactor plan

Ranked by data risk, then by how often a change has to touch the code, then by cost.
Every item is behaviour-preserving, lands on a branch on the Mac, and goes through refactor → testing → qa.

### 1. Make identity-rulings saves fail closed (F1 + F2 for this file). **Data-risk: curated family record.** Size S. Risk low.
- Steps:
  1. Add the F1 pinning test (red).
  2. In `save(to:)`, read the current bytes. If they exist and do not decode, rename them to `.damaged-<ISO8601>` beside the original (never delete), then publish.
  3. Swap `.atomic` for `AtomicFilePublish.write(_, to:, durability: .fullFsync)`, keeping the key ordering.
  4. Optionally show an `"unreadable"` revision in the Family Tree UI.
- Pinning tests that must exist first: `FamilyIdentityDecisionsTests.theFileIsWrittenInAStableOrder`,
  `aRulingSurvivesBeingWrittenAndReadBack`, `aRulingsFileWrittenBeforeAFieldExistedStillLoads`,
  `anUnparseableFileIsReportedRatherThanTreatedAsEmpty`. In the app: `VideoScanTests/FamilyTreeIdentityRulingTests`,
  `IdentityRulingsCoherenceTests`. Also add the new test "damaged file survives the next save".
- This is a small, contained fix. It qualifies for a codex pass under the spend policy (a curated-data write path), but the in-house `qa` agent is probably enough.

### 2. Split PrunePlan.swift (1240 lines). **Data-risk: prune / deletion evidence.** Size M. Risk medium.
- Steps (moves only, no logic edits in the same commit):
  1. Move `ArchiveCopySnapshot` to its own file.
  2. Move `ArchiveCopyFamilies` (group, protection, checkingFiles, nameRelated) to `ArchiveCopyFamilies.swift`.
  3. Move `ImportanceBar` and its UserDefaults loader to `ImportanceBar.swift`.
  4. Move `PrunePlan.Family` and `logLine` to `PrunePlan+Family.swift`.
  5. Only after that, break `Family.logLine` (CCN 26) into one small `reasonPhrase(for: KeepReason)` table plus the line assembly.
  6. Rename the stale test `testKeeperElectionPrefersNewDeviceThenFreeSpaceThenUserOverride`. Its assertions, and the code, rank
     free space **before** new device, so the name has the order wrong.
- Pinning tests that must exist first (they do): all 21 in `VideoScanCore/Tests/…/PrunePlanTests.swift`, especially
  `testTheLogLineSaysWhyEachCopyCouldOrCouldNotBeSelected`, `testOfflineAndPairCopiesAreNeverElectedNor…`,
  `testQARedAnArchivedVersionNeverMakesTheUnarchivedOriginalCheckable`, `testUnverifiedArchiveRowsAreShownButNeverCheckable`
  and `testScale100kSnapshotsIn5kFamiliesUnderBudget`. Also `PrunePlanMissingFileTests` and `VideoScanTests/PruneApplyTests`.
- Add first: a **golden logLine snapshot** over a fixed 10-family fixture, so step 5 cannot change any wording that ends up in the log.
- Run `/safety-critical` before step 5, because it touches the code that explains why a copy may be trashed.

### 3. Shrink the five places that must stay in sync for each VideoRecord field. **Data-risk: catalog.json (irreplaceable).** Size L. Risk high.
- Today, adding one persisted field means editing five places:
  1. `CodingKeys`
  2. `VideoRecord.init(from:)` (NLOC 126)
  3. `VideoRecordDTO` stored properties and `init(_:)` (NLOC 125)
  4. `VideoRecordDTO.encode(to:)` (CCN 27, NLOC 176)
  5. `snapshotClone` (NLOC 126)
- Steps:
  1. Build `snapshotClone` as `VideoRecord(dto: VideoRecordDTO(self))`, a new memberwise init from the DTO. That removes place 5 and keeps the
     `sending` guarantee, because the DTO is Sendable.
  2. Generate the per-field encode and decode pairs from one list. Use a Swift macro only if Rick approves a new build dependency; otherwise
     use a single field table the tests walk. That is an escalation item: a new dependency or architecture decision.
- Pinning tests that must exist first (they do): `ModelSchemaTests.videoRecordFullRoundTrip`,
  `decodesLegacyRecordMissingNewerKeysWithDefaults`, `snapshotCloneCopiesEveryStoredProperty` and
  `CatalogStoreAsyncSaveTests.cloneEncodesIdenticallyToOriginal`.
- Add first: a **byte-for-byte golden catalog.json fixture**, with every field populated and the old encoder's output checked in, asserted to be equal after the refactor.
- Step 1 alone is size M and low risk. Step 2 needs Rick's ruling.

### 4. Break up the GEDCOM parse, `GedcomFamilyGraph.init(gedcomText:)` (CCN 43) in a 1262-line file. Size M. Risk medium (read-only, but every tree feature depends on it).
- Steps:
  1. Pull the per-tag branches (INDI/FAM/NAME/BIRT/DEAT/FAMC/FAMS/custom `_` tags) into a `ParseState` struct with one `mutating func handle(level:tag:value:)` per record type.
  2. Move the Lookup section (:705–905) to `GedcomFamilyGraph+Lookup.swift` and the Kinship section (:908–1013) to its own extension file.
- Pinning tests that must exist first (they do): `GedcomParserPropertyTests`, `GedcomFamilyGraphTests`,
  `GedcomIndexEquivalenceTests`, `GedcomLaunchTablesEquivalenceTests`, `GedcomPerfBaselineTests`,
  `GedcomLaunchPerfTests`, `GedcomParseContentionSensorTests`, `HastingsParseProbeTests`, `GedcomDatePropertyTests`.
- Add first: a structural-equality test that parses the bundled synthetic pedigree (`GedcomSyntheticPedigree`) before and after and compares
  people and families field by field, plus a perf budget so the split does not add allocations per line.
- The same pattern then applies to `TreeIndex.init` (CCN 34 / NLOC 179) and `merge` (CCN 26 / NLOC 132).

### 5. One write path for Core JSON stores (F2). **Data-risk: AtomicFilePublish, CyberBrain testimony.** Size M. Risk medium.
- Steps:
  1. Move `FindTagIngestState.save`, `PersonOfTheDayHistory`, `TreeWalkStore` and the `FamilyGraphCompiledStore` pointer and manifest onto
     `AtomicFilePublish.write`, with `.fast` where the data can be regenerated. Name the durability in each call.
  2. Change `CyberBrainWriter.save`'s `fsync` to `F_FULLFSYNC`, or better, keep its probe-load and backup steps but publish through
     `AtomicFilePublish.publish`, the lower-level form described at AtomicFilePublish.swift:304. Its strict-reader probe is worth keeping.
  3. Extend `AtomicFilePublishSensorTests` with the F2 sensor.
- Pinning tests that must exist first: `AtomicFilePublishModeTests`, `VideoScanTests/AtomicFilePublishSensorTests`,
  `CyberBrainWriterTests`, `CyberBrainWriterConcurrencyTests`, `CyberBrainWriterPronunciationGuardTests`,
  `CyberBrainCorrectionTests`, `FindTagJournalTests`, `TreeWalkTests`, `FamilyGraphCompiledStoreBindingTests`,
  `FamilyGraphCompiledRootOverrideTests`.
- Add first: for CyberBrain, a test that a save whose probe-load fails leaves the original file byte-identical. Check whether `CyberBrainWriterTests` already has one.

### Backlog (one line each)
- `CyberBrainWriter.appending(_ testimony:)`: CCN 29 / 163 lines in a 1016-line file. Split it into resolve-subject, build-entry and dedupe steps. **Data risk (testimony).** M.
- `BirthplaceUnitResolver` `Scan.apply`: CCN 32 / 238 lines. Use one table of token kinds to handlers. Pinned by the `FamilyMapResolver*` and `FamilyMapUnits*` adversarial suites. M.
- `GedcomKinshipPath.relatives` (CCN 36) and `GedcomFamilyGraph.relatives` (CCN 17) both answer "relatives of X" by different routes. Check whether one can delegate to the other. Pinned by `GedcomKinshipPathTests`. M.
- `applyingFactOverlay`: CCN 33. Use one handler per fact kind. Pinned by `PersonFactRefreshTests` and `PersonFactOverlay` tests. M.
- `EmbeddedDateParser.parseSingle`: CCN 26. Use a format table. Pinned by `VideoScanTests/EmbeddedCreationDateTests`. S.
- `ProcessRunner.swift`: 898 lines. Move `runProcess` (NLOC 90) deadline and pipe handling into a helper type. Covered by existing ProcessRunner tests in the app target. M.
- Merge `GedcomFamilyGraph.year(in:)` and `FamilyTreeDuplicates.birthYear` into one year scanner (they differ on 5-digit runs and years below 1000). S.
- Delete the 7 dead symbols in F3 and fix the stale `knownCountries` doc comment. S.
- `LifeAndTimes/` and `FamilyMap/` label switches (CCN 16–22): leave them as they are. They are flat tables, and splitting them adds risk for no gain.

---

## Not covered
- **lizard was not run locally.** `pip install` was denied, so the table uses the M4's lizard 1.22.1 numbers at `a70a3562`. That source is identical in scope to `9dc177d`.
- The dead-code scan covered **public** names only. Internal and private dead code in Core was not checked (that is periphery's job).
- Name-normaliser duplication inside Core (`FamilyNameNormalizer`, `FamilyTreeVerification.normalized`, `FamilyTreeDuplicates.normalise`,
  `RecordFinder.normalise`, `normalizedPlaceToken`) was noted but not traced to the decisions that use each one.
- I did not check whether app-target code compares `FileIdentityStamp` or inode values by hand instead of using `describesSameFile`. That needs a grep of the MediaOps and Archive data-risk folders, which are outside this row.
- `FamilyGraphCompiledStore.swift` (1050 lines) and `PreviewSweepEngine.run` were measured but not read.
