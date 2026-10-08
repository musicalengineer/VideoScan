Brief: N1013-D-FamilyTree | Source: main@c91abaa5 | Wall clock: 14 | Files read: 36
Finding count: 4 (REAL 4 / NEEDS-MAC 0 / NOISE 0)
Verdict: FamilyTree carries no new complexity debt tonight, and the N1012 sidecar fix holds where it was applied; its pattern stops one file short (bookmarks, same folder as the rulings), its errno repair was made in one of three identical publish blocks, and the CyberBrain note link is the one durable FamilyTree record still keyed on the raw GEDCOM pointer that the rest of the folder avoids because a fresh export renumbers it.

Scope note: the working tree (fa4a5dc7) differs from origin/main (c91abaa5) only by one unrelated test file; `FamilyTree/` is byte-identical. This was a read-only review. Nothing was built or changed, and this report is the only file written. Per the caller's instruction, nothing was committed or pushed (README rule 3 is overridden for this row).

## Step 0–1: measurements (M4 numbers, not re-measured)

Sources: `ci/baselines/complexity_debt.json` (447 entries) and `origin/metrics:metrics/complexity.jsonl`, last line (nightly, sha 4b79bbbb, 2026-10-07T11:26Z, lizard 1.22.1).
- FamilyTree folder: 79 files, 1548 functions, mean CCN 3.35 (lowest of the large folders). 15 functions over CCN 15, 1 over CCN 30, 9 over 80 lines, 20 offenders in all, 8 files over 800 lines.
- **New offenders in scope: none.** `debt_new` = 0 app-wide. `debt_worse` = 1 app-wide; the record gives only a count, so I could not tell whether it is in FamilyTree. None of the 20 FamilyTree baseline keys is in tonight's top 15.

### Offender table (scope)

| # | Function | file:line (origin/main) | CCN | NLOC | Data-risk writer? |
|---|---|---|---|---|---|
| 1 | `TreeIdentityDeriver.deriveWithResolvedPointerPins` | TreeIdentityDeriver.swift:301 | 32 | 91 | no (feeds pin writes) |
| 2 | `FamilyKinshipOverlay.init(snapshots:graph:)` | FamilyKinshipOverlay.swift:389 | 20 | 66 | no |
| 3 | `FamilyTreeLiveModel.refilterNow` | FamilyTreeLiveModel.swift:2745 | 20 | 48 | no |
| 4 | `FamilyTreeNotesResolver.corrections` | FamilyTreeNotes.swift:251 | 20 | 50 | feeds CyberBrain corrections |
| 5 | `FamilyTreePersonCard.body` | FamilyTreeCards.swift:188 | 19 | 180 | no (view) |
| 6 | `FamilySearchPullCoordinator.performMerge` | FamilySearchPullCoordinator.swift:657 | 18 | 98 | **yes** (merged GEDCOM install) |
| 7 | `TreeIdentityCenter.pin` | TreeIdentityCenter.swift:358 | 18 | 61 | **yes** (profile pin save) |
| 8 | `FamilyAssetImageValidator.isStructurallyComplete` | FamilyAssetStore.swift:496 | 17 | 34 | gate for imports |
| 9 | `FamilyAssetStore.resolvedPersonFolder` | FamilyAssetStore.swift:1748 | 17 | 39 | **yes** (picks write folder) |
| 10 | `FamilyTreeView.inspector` | FamilyTreeView.swift:1351 | 17 | 127 | no (view) |
| 11 | `FamilyAssetStore.readFolderNames` | FamilyAssetStore.swift:879 | 16 | 35 | read side of #9 |
| 12 | `FamilyKinshipInference.isAncestor` | FamilyKinshipInference.swift:447 | 16 | 33 | no |
| 13 | `FamilyKinshipOverlay.resolvePins` | FamilyKinshipOverlay.swift:1027 | 16 | 59 | no |
| 14 | `FamilySearchPullSheet.footer` | FamilySearchPullSheet.swift:425 | 16 | 77 | no (view) |
| 15 | `FamilyTreePersonMetadata.text` | FamilyTreePersonMetadata.swift:33 | 16 | 47 | no |
| 16 | `FamilyTreeView.sidebar` | FamilyTreeView.swift:38 | 12 | 97 | no (view) |
| 17 | `FamilyTreeView.treeCanvas` | FamilyTreeView.swift:935 | 8 | 133 | no (view) |
| 18 | `RecordFinderFoundSheet.body` | RecordFinderFoundSheet.swift:66 | 8 | 81 | no (view) |
| 19 | `FamilyTreeView.withSheets` | FamilyTreeView.swift:427 | 5 | 81 | no (view) |
| 20 | `FamilySearchPullSheet.optionsForm` | FamilySearchPullSheet.swift:82 | 4 | 105 | no (view) |

Files over 800 lines (`wc -l`): FamilyTreeLiveModel.swift 2990, FamilyTreeView.swift 2241, FamilyAssetStore.swift 2112, FamilyKinshipOverlay.swift 1592, FamilyKinshipInference.swift 1056, RecordFinderFiling.swift 896, FamilySearchPullCoordinator.swift 889, FamilyAssetStore+Documents.swift 825.

## Step 2: duplication, dead code, leftovers

- **The N1012 / b83405e1 fix pattern.** There are now four answers to the same question: "load a hand-curated JSON sidecar, change it, save it". Each has a different safety level:
  - Rulings (`FamilyIdentityDecisions.save`): compare-and-swap, plus set-aside of a damaged file.
  - Photo not-of (`excludePhoto`): a lock, a re-read, set-aside, `AtomicFilePublish` with fullFsync, and the real errno.
  - Documents (`writeDocumentSidecar`): a lock, a re-read, a refusal when the file is unreadable, fullFsync, and a **stale errno** (F3).
  - Bookmarks: a stale in-memory copy, damaged read as empty, `.atomic` (F2).
  - Photo choice (`recordPhotoChoice`) replaces the whole file by design, but it is another copy of the same encoder and catch block, again with a stale errno (F3).
- **Two set-aside routines outside scope** but used by FamilyTree:
  - `DamagedFileSetAside` (`.damaged-<ISO>`, `renamex_np RENAME_EXCL`, at most 99 tries).
  - `PersonFactOverlayStore.setAsideUnreadable` (`.bad-<UTC>`, `fileExists`, then `moveItem`, no upper bound), used by the per-person refresh.
  - The header of `DamagedFileSetAside` says "one helper, not two copies". Behaviour is safe either way, because `moveItem` will not overwrite. Recovery file names differ by feature. This goes in the backlog, not the findings.
- **Identity keys.** The folder's own comments say "a fresh export renumbers @I pointers" (ResearchPerson.swift:11, FamilyAssetStore.swift:580, FamilyTreeLiveModel.swift:672/2354), and the folder keys records two ways because of it:
  - Keyed by FamilySearch ID: rulings, dossiers, documents, choice sidecar, profile pins. Pointer pins on profiles are also fingerprint-checked (`TreeIdentityDeriver.pinnedPerson`).
  - Keyed by raw pointer, with no check: CyberBrain links (F1), bookmarks, and old pointer-suffixed People folders.
- **Pointer-pin resolution is copied** at four sites: `TreeIdentityDeriver.pinnedPerson`, FamilyKinshipOverlay.swift:1056, :1116–1126 and :1552–1556, and PersonPhotoResolver.swift:187 (outside scope). The copies are equivalent today. That is debt, not a bug (plan item 4).
- **Three "which folder is this person's" rules:**
  - `readFolderNames`: every pointer match, then name and alias.
  - `resolvedPersonFolder`: exactly one pointer match, then name plus birth year, no aliases.
  - `familySearchIDFolder`: the strict 4-3 FSID parse via `FamilyPersonFolderName.identity`, while `safeFamilySearchIDComponent` accepts any upper-cased alphanumeric string with dashes.
  - `cardPhotoURL` and `originalPhotoURL` search only `resolvedPersonFolder`, which never matches an FSID-named folder. The adjust flow records a choice sidecar (FamilyTreeView.swift:447), and that sidecar wins, so I could not build a failing user scenario. Plan item 5.
- **The "yyyyMMdd-HHmmss" stamp is built five times.** Three copies use local time (FamilyAssetStore.swift:1345, :1520, +Documents.swift:801) and two use UTC (FamilySearchPersonRefresh.swift:89, FamilySearchPullCoordinator.swift:873). Cosmetic, backlog only.
- **Dead code:** 3 functions (F4).
- **TEMPORARY / diag leftovers, always-on flags:** none found. `grep` for TEMPORARY, FIXME, HACK, XXX, `#if DEBUG`, "remove after" and `static let …enabled = true` found nothing.
- **Stale TODOs:** none. The only TODOs are two `TODO(fragile)` notes on the unofficial web-search endpoint (ResearchSources.swift:12, :591). They are still accurate.

## Findings

### N1013-D-FamilyTree-F1: CyberBrain notes link to a tree person by the raw GEDCOM pointer, which a Replace install renumbers, so old notes show on, and new notes are written into, the wrong person
- **Severity:** P1 under the README definition: a family record is filed under the wrong person, on the write side too. The Manager may calibrate, because it needs a Replace install, not "Add to current tree".
- **Class:** REAL. Plain Swift logic.
- **Symbols:**
  - `FamilyTreeLiveModel.addNote`, FamilyTreeLiveModel.swift:1718. It passes `gedcomPersonID: person.id` at :1735.
  - `FamilyTreeNotesResolver.init`, FamilyTreeNotes.swift:193–196. A CB person whose `gedcomPersonID` exists in the graph is mapped with no other check.
  - Callee followed: `CyberBrainWriter.resolveTestimonySubject`, CyberBrainWriter+Testimony.swift:92–96. "The tree record is already known to the brain: that wins over any name match".
  - Same key, no check: `FamilyAssetIdentityDirectory.init` :117 and `.owner` :145.
- **Why it is duplicated logic:** every other durable FamilyTree record avoids the raw pointer, for the reason the code itself gives:
  - Rulings are keyed by FSID: "survives the re-pull that renumbers every GEDCOM xref" (:672).
  - Dossiers: "never a raw @I pointer, which a fresh export renumbers".
  - Profile pointer pins carry a source fingerprint and fail closed on a replacement tree (`TreeIdentityStaleCoverageTests.pointerOnlyCandidateCannotRebindToReplacementRecord`).
  - `CyberBrainPerson` has no FSID field (CyberBrainModels.swift) and no fingerprint.
- **Scenario:**
  1. Tree T1 has person A at `@I5@`. A note on A's card creates CB person `person.a.i5` with `gedcomPersonID = "@I5@"`.
  2. The user gets a new download (or uses Install from file with another program's export). In the pull sheet they choose the plain install. `FamilySearchPullCoordinator.install` (:531) copies the file in as a new `familysearch-<stamp>.ged`, and the loader takes the newest file. No pointer remap runs. Only `installMerged` keeps the old pointer space.
  3. In T2, `@I5@` is person B. B's card lists A's notes, because the resolver maps `@I5@` to `person.a.i5`. Hallie answers questions about B from A's facts.
  4. A note typed on B's card goes through `addNote` → `record` with pointer `@I5@`. The pointer-wins branch files it in A's CB record. A's record now holds facts about B. No name check, refusal or log line shows the mismatch.
- **Guards looked for:**
  - Replace prompt and sheet text: no warning about pointer-keyed data. `grep` for bookmark, cyberbrain and pointer in the pull coordinator and sheet found only the merge's own pointer handling.
  - `correctNote`: refuses when the row no longer maps to its person, but that mapping is the same pointer map.
  - `CyberBrainWriter`: refuses only a conflicting existing pointer, not a stale one.
  - No drift or renumber guard anywhere in FamilyTree or the CyberBrain sources.
- **Smallest pinning test** (`FamilyTreeNotesTests`, temp brain root, the two-tree pattern used by `TreeIdentityStaleCoverageTests`):
  1. Install graph G1 with `@I5@` = "Alpha Test" (FSID `AAAA-AAA`), then call `addNote("one", about: "@I5@")`.
  2. Install graph G2 with `@I5@` = "Beta Test" (FSID `BBBB-BBB`).
  3. Expect `notes(forGedcomID: "@I5@")` not to contain "one".
  4. Call `addNote("two", about: "@I5@")` and expect "two" not to be in the CB record that holds "one".
  - Both expectations fail today.
  - Existing pin that encodes today's rule and must be revisited on purpose: `CyberBrainWriterCharacterizationTests.pointerWinsOverNameAndConflictingPointersStaySeparate` (Core).
- **Fix shape:** escalation per CLAUDE.md (identity model, additive schema):
  - Record the FSID on the CB link when the tree person has one, and resolve the FSID first.
  - Treat a pointer-only link as valid only when the linked name still agrees, or a tree fingerprint matches.
  - Or, as a minimum, warn and refuse at Replace while pointer-only links exist.

### N1013-D-FamilyTree-F2: bookmarks save a load-time copy and treat a damaged file as empty; the rulings fix was applied to the file beside it but not to this one
- **Severity:** P3. The code calls bookmarks "a convenience layer, not catalog data", but it says they are shared on purpose between two devices on one archive (FamilyTreeLiveModel.swift:578–582, FamilyTreeBookmarks.swift:101).
- **Class:** REAL. Foundation only.
- **Symbols:**
  - `FamilyTreeBookmarks.load(from:)`, FamilyTreeBookmarks.swift:84: unreadable or undecodable is treated as empty.
  - `FamilyTreeBookmarks.save(to:)`, :101: whole-file `.atomic`, no re-read, no set-aside, no fsync.
  - Caller: `FamilyTreeLiveModel.toggleBookmark`, FamilyTreeLiveModel.swift:2145/:2167.
  - The rulings file lives in the same `bookmarksDirectory` (`setRecordHidden` :2378). It got compare-and-swap plus set-aside in b83405e1. Bookmarks got neither.
- **Scenario A (damaged file):**
  1. The bookmarks file holds 40 entries and gets a trailing comma from a hand edit, or a sync conflict copy is written over it.
  2. Launch: `load` returns empty and says nothing.
  3. One toggle writes a 1-entry file over it. The 40 entries are gone, with no backup and no log line.
- **Scenario B (two writers, the stated design):**
  1. The Mac loads {X} at launch.
  2. The second device marks Y, and the file becomes {X, Y}.
  3. The Mac toggles Z and writes {X, Z}. Y is erased. The same happens with File ▸ New Window, which gives each window its own model (N1012-F1 Scenario B).
- **Guard looked for:** `bookmarkSourceTransition` covers only a source switch. `sourceAccess` covers only read-only access. Nothing re-reads the file before saving.
- **Smallest pinning test** (`FamilyTreeBookmarkTests`):
  1. Write `"{ not json"` to `FamilyTreeBookmarks.fileURL(in: dir)`.
  2. Build `FamilyTreeLiveModel(originalsDirectory: dir, bookmarksDirectory: dir)` with a loaded tree, then call `toggleBookmark("@I1@")`.
  3. Expect a sibling `family-tree-bookmarks.json.damaged-*` holding the original bytes. This fails today.
  - Variant: two models on one directory. The first toggles A, the second toggles B, and the file should hold both.
  - Keep `aMissingOrCorruptFileMeansNoBookmarksRatherThanAFailure`: the read may stay lenient, the save may not.

### N1013-D-FamilyTree-F3: the stale-`errno` repair from b83405e1 reached one of three identical publish blocks
- **Severity:** P3. The wrong reason is shown and logged; no data is lost.
- **Class:** REAL.
- **Symbols:**
  - `FamilyAssetStore.recordPhotoChoice`, FamilyAssetStore.swift:1553: `throw StoreError.createFailed(…, errno: errno)`.
  - `FamilyAssetStore.writeDocumentSidecar`, FamilyAssetStore+Documents.swift:728: the same line.
  - The fixed copy is `publishExclusion`, FamilyAssetStore.swift:1145, which uses `Self.posixCode(of: error)`. Its comment reads: "the global `errno` is stale by now (temp-file cleanup ran after the failing syscall)".
  - Callee followed: `AtomicFilePublish.write` (Core :240–276). After a failed temp write or rename it runs `try? FileManager.default.removeItem(at: tmp)` and an `os_log` call before rethrowing. The thrown `Failure` carries the true `errnoValue`. The global `errno` does not.
- **Scenario:**
  1. The chosen-photo folder (`People/<FSID>/`) is not writable: permissions after a restore, or a volume remounted read-only beneath a read-write designation. The cropped image lives in a different People folder.
  2. `recordPhotoChoice` → `.atomic` write fails with EACCES. Cleanup runs before the catch block reads `errno`.
  3. The alert and log read `strerror` of whatever cleanup left behind, not "Permission denied".
  - The documents sidecar has the same code path. It is harder to reach with permissions alone, because the document file is copied first.
- **Smallest pinning test** (`FamilyAssetStoreTests`, modelled on the existing `aFailedExclusionWriteReportsTheRealErrno` at :694):
  1. Put a verified PNG in `People/test_Group/`.
  2. Create the person's FSID folder and `chmod 0555` it.
  3. Call `recordPhotoChoice(png, for: person, source: "test")`.
  4. Expect `StoreError.createFailed("chosen-photo.json", errno: EACCES)`.
  - The `.atomic` write here is Foundation's, not `AtomicFilePublish`, so the same stale-errno risk applies through Foundation's own cleanup. If the test passes today, downgrade this finding to the documents copy only.

### N1013-D-FamilyTree-F4: three functions have no callers anywhere, tests included
- **Severity:** P3. **Class:** REAL.
- **Symbols:**
  - `FamilyTreeLiveModel.sharedAncestors(of:and:limit:)`, FamilyTreeLiveModel.swift:2291. Its doc says it was added to expose common ancestors outside Hallie. Nothing in the UI calls it, so it is either dead or a feature never wired up.
  - `FamilyTreeView.readOnlyField`, FamilyTreeView.swift:1993 (private).
  - `WikipediaVetting.describesNonPerson`, WikipediaVetting.swift:204. Added in 147e264e and never called; `nonPersonLabel` is used directly.
- **Evidence:** I counted identifier tokens across all `.swift`, `.py`, `.json` and `.sh` files in the repo, excluding `.git` and `.trash`. Each name occurs exactly once, at its declaration. Protocol callbacks were checked and excluded (`numberOfPreviewItems`, `previewPanel` are QuickLook data-source methods).
- **Pinning test:** none needed to delete. If `sharedAncestors` is meant to be wired, add a `FamilyKinshipTests` case before wiring it.

## Step 3: ranked refactor plan

### 1. One hand-curated-sidecar helper for FamilyTree (fixes F2 and F3; data-risk: FamilyAssetStore sidecars, bookmarks)
- **Steps (behaviour-preserving except where a finding says otherwise):**
  1. Move `posixCode(of:)` beside `AtomicFilePublish.Failure`, or make it a `StoreError` initializer. Make `recordPhotoChoice` and `writeDocumentSidecar` use it (F3).
  2. Extract a `FamilyJSONSidecar` with `loadForUpdate(url, onDamaged: .setAside | .refuse, log:)` and `publish(_:to:durability:createIntermediates:)`. Port `excludePhoto` first: its tests are the strongest. Then port documents, keeping `.refuse`, which is its current, tested policy. Then port `recordPhotoChoice` (publish only).
  3. Port bookmarks: keep the lenient `load` for display, and add `mutate(in:_:)`, which re-reads under a lock, sets a damaged file aside and publishes. `toggleBookmark` applies its one toggle to the fresh copy and adopts the result (F2).
- **Pins that must exist BEFORE:**
  - `FamilyAssetStoreTests`: `aDamagedExclusionSidecarIsNeverSavedOver`, `aDamagedExclusionSidecarThatCannotBeSetAsideRefusesTheWrite`, `aFailedExclusionWriteReportsTheRealErrno`, `anExcludedPhotoIsNeverShownForThatPersonAgain`, `exclusionsRequireWriteAccessAndAPeoplePhoto`.
  - `FamilyDocumentStoreTests`: `aDamagedSidecarListsNothingAndIsNeverRewrittenByARead`, `sidecarSchemaIsFrozen`, `aSidecarWrittenBeforeMilitaryAndCensusStillLoads`.
  - `FamilyTreeBookmarkTests`: all seven, especially `theFileIsAStableSortedArray`, `aMissingOrCorruptFileMeansNoBookmarksRatherThanAFailure` and `aModelGivenADirectoryPersistsThroughIt`.
  - **Add:** `aFailedChoiceWriteReportsTheRealErrno` (F3), `aDamagedBookmarksFileIsSetAsideBeforeSave`, and `twoModelsOnOneDirectoryKeepBothBookmarks` (F2).
- **Risk:** medium. The two damaged-file policies (set aside, refuse) must stay a parameter, not be unified. The file formats must stay byte-identical (sorted keys, `withoutEscapingSlashes` on the asset sidecars, none on bookmarks). **Size:** M.

### 2. Durable key for CyberBrain links (F1; data-risk: CyberBrainWriter, FamilyTreeNotes). Ask the director first.
- **Steps:**
  1. Characterize first, with no behaviour change: add the F1 two-tree test as a known failure, or as a test of the current behaviour marked for flipping.
  2. Make an additive schema change: an optional `familySearchID` on `CyberBrainPerson`, written by `addNote`, `recordTestimony` and pronunciation when the tree person has one. Old files decode unchanged.
  3. Resolve the FSID first in `FamilyTreeNotesResolver.init`, `FamilyAssetIdentityDirectory` and the testimony subject. Use a pointer-only link only when the FSID is absent and the linked name still agrees with the graph person (reuse `GedcomFamilyGraph.NameIndex`). Otherwise leave the link unattached and surface it, as `ambiguousPersonIDs` already does.
  4. Optional: when Replace would orphan pointer-only links, say so in the sheet.
- **Pins BEFORE:**
  - `FamilyTreeNotesTests`: `linkedPointerAliasAndDiminutiveAllResolveAmbiguityDoesNot`, `addingANoteCreatesALinkedPersonAndHallieCanAnswerFromIt`, `toldMeItemAppearsWithAttributionAndNoteLinksTheExistingPerson`, `sameNameDifferentPointerNeverMerges`, `sixteenThousandPeopleAndFiveHundredItemsResolveFast` (scale).
  - Core: `CyberBrainWriterCharacterizationTests.pointerWinsOverNameAndConflictingPointersStaySeparate`, and `CyberBrainPlannerGedcomIDTests` (all five).
  - `NotesRepairMigrationTests` and `NotesAuthorshipSensorTests` (existing-file compatibility).
- **Risk:** high. This touches every note read and write path and Hallie's planner. It needs the codex pass (data-risk), with the director's go. **Size:** L.

### 3. Split `FamilyTreeLiveModel.swift` (2990 lines) along its existing MARK seams, without moving the writers last
- **Steps:** extensions in new files, no logic edits:
  - `+Bookmarks` (toggle, rebuild, scope)
  - `+IdentityRulings` (`setRecordHidden`, `isSuppressedRecord`, load sites at :596/:823/:1266)
  - `+Notes` (addNote, correctNote, recordTestimony, pronunciation)
  - `+Focus`, and `+Filter` (`refilterNow`, CCN 20)
  - Do this after item 1, so the moved code is already the fixed code.
  - While moving the rulings code, make the three load sites and the one save site name one `rulingsDirectory` property. Today loads use `originalsDirectory` and the save uses `bookmarksDirectory ?? originalsDirectory`. That is the same directory in production, but nothing pins it (every rulings test passes the same directory for both).
- **Pins BEFORE:** `FamilyTreeIdentityRulingTests`, `IdentityRulingsCoherenceTests`, `FamilyTreeModelReuseTests`, `FamilyTreeCardActionTests`, `FamilyTreeBookmarkTests`, `FamilyTreeBookmarkDiscoveryTests`, `FamilyTreeBookmarkProjectionTests`, `FamilyTreeNotesTests`. **Add** `rulingsLoadAndSaveUseOneDirectory`: build the model with distinct originals and bookmarks directories, hide a record, reload, and expect it still hidden.
- **Risk:** low. Pure moves, though the `private` members touched must become `fileprivate`/internal. **Size:** M.

### 4. One pointer-pin resolver (read side; shrinks `resolvePins` CCN 16)
- **Steps:** replace the inline `switch pin` blocks at FamilyKinshipOverlay.swift:1056, :1116–1126 and :1552–1556 with `TreeIdentityDeriver.pinnedPerson(_:graph:fingerprint:)`, or with a shared free function in Core if the overlay must not depend on the deriver. Follow up with PersonPhotoResolver.swift:187 in the People night.
- **Pins BEFORE:** `TreeIdentityDeriverTests.pointerPinHonoursTheFingerprint`, `stalePinsStayStale` and `stalePinIsAProblemNotAGuess`; `TreeIdentityStaleCoverageTests` (all, especially `pointerOnlyCandidateCannotRebindToReplacementRecord`); `FamilyKinshipTests`; `TreeIdentityPinPerformanceTests` (scale). **Add** an overlay-level test: a pointer pin with a mismatched fingerprint yields `pinNotInTree`, and none exists that I could find by name.
- **Risk:** low. Today's semantics are equal: a nil fingerprint never matches a String in either form. **Size:** S.

### 5. One "whose folder is this" rule (`resolvedPersonFolder` CCN 17, `readFolderNames` CCN 16; data-risk: picks the folder imports write into)
- **Steps:**
  1. Add a pure `FolderAttribution.candidates(for:among:)` that returns ranked candidates with a reason: FSID folder, pointer suffix, name plus year, alias.
  2. Re-express `readFolderNames` as "all candidates, ranked".
  3. Re-express `resolvedPersonFolder` as "exactly one top candidate, else nil", keeping its `creatingRequest` refusals.
  4. Then decide, as a behaviour change with its own test, whether `cardPhotoURL`/`originalPhotoURL` should see FSID folders.
  5. Also settle the `safeFamilySearchIDComponent` (lenient) vs `isFamilySearchID` (strict 4-3, upper-case only) split for folder matching.
- **Pins BEFORE:**
  - `FamilyAssetStoreTests`: `gedcomIDFolderWinsAndNameIsOnlyAFallback`, `deployedPersonFolderConventionMatchesPunctuationYearAndID`, `duplicatePhotoRequestFoldersUseBirthYearThenGEDCOMID`, `folderCreationFlattensTraversalAndRejectsEmptyIdentity`, `aPersonUnknownToTheDirectoryFallsBackToNameMatching`.
  - `HalliePersonGalleryStoreTests`: `anotherRecordsPointerFolderIsNeverReadForThisRecord`, `twoSameNameFoldersWithAConflictingPointerAndYearNeverEnterTheGallery`, `anUnsafePointerRejectsAndNeverDegradesToNameAliasOrGroupFolders`.
  - `PersonPhotoOnePerPersonTests`, `POIUUIDFoldersTests`, `FamilyAssetIdentityScaleSensorTests` (scale).
  - **Add:** a table test that runs every folder-name shape through both old functions and the new one, and asserts they agree before the switch.
- **Risk:** medium. The write side must keep refusing an ambiguous folder. **Size:** M.

### Backlog (one line each)
- `FamilyAssetStore.swift` (2112 lines): split images, choice, exclusion and folders into extensions after item 5.
- `TreeIdentityDeriver.deriveWithResolvedPointerPins` (CCN 32): extract the owner-pin branch (:305) and the claim loop. Pins: `TreeIdentityDeriverTests`.
- `FamilySearchPullCoordinator.performMerge` (CCN 18, 98 NLOC; data-risk): split stage, verify and activate. Pins: `FamilySearchPullMergeTests`, `FamilySearchPullLifecycleTests`. Codex pass needed.
- `TreeIdentityCenter.pin` (CCN 18; data-risk): extract the derived-attestation re-check into a function. Pins: `TreeIdentityStaleCoverageTests`.
- `FamilyTreeNotesResolver.corrections` (CCN 20): table-drive the operation cases. Pins: `FamilyTreeNotesTests`, `NotesRepairMigrationTests`.
- `FamilyKinshipOverlay.init` (CCN 20) and `FamilyKinshipInference.isAncestor` (CCN 16): extract a per-row classifier. Pins: `FamilyKinshipTests`, `KinshipInferenceTests`, `KinshipPerformanceGateTests`.
- View bodies over 80 lines (`FamilyTreePersonCard.body` 180, `FamilyTreeView.inspector`/`treeCanvas`/`sidebar`/`withSheets`, `FamilySearchPullSheet.optionsForm`/`footer`, `RecordFinderFoundSheet.body`): extract subviews. UI only, so `qa` plus a spot test, no codex.
- `FamilyAssetImageValidator.isStructurallyComplete` (CCN 17): split per format (PNG, JPEG, HEIC). Pins: `FamilyAssetStoreTests` image tests.
- `FamilyTreePersonMetadata.text` (CCN 16): extract per-field formatters.
- One shared "yyyyMMdd-HHmmss" stamp helper, choosing UTC or local deliberately (5 copies).
- Unify `PersonFactOverlayStore.setAsideUnreadable` (`.bad-`, unbounded loop) onto `DamagedFileSetAside` (Core and Hallie nights). Recovery file names would then be one shape.
- Delete the F4 dead functions (S, no pins needed).

## Not covered
- RecordFinderFiling.swift (896 lines): its write transaction was not re-read. It is outside the duplication target and has had codex rounds.
- FamilyKinshipInference internals, FamilyTreeMemories, CouplePortrait (except the import write) and the Research sources and parsers.
- The full duplicate-block list from the metrics record (`duplicate_blocks` is an integer count in tonight's record: 149, and app-wide rate 1.83%). No per-file list was available to check.
- Callees followed: `FamilyIdentityDecisions` (load, fileState, save, compare-and-swap), `DamagedFileSetAside`, `PersonFactOverlayStore.setAsideUnreadable`, `AtomicFilePublish.write`, `FamilyPersonFolderName.identity`/`component`, `GedcomFamilyGraph.isFamilySearchID`, `CyberBrainWriter+Testimony` (subject resolution), `ViewerWriteGuard`, `publishFamilyAssetConfiguration` (viewer → read-only), `PersonPhotoResolver.candidate`, `FamilyPhotoAdjustSheet.save`, and the adjust `onSaved` path.

## Blockers & environment
- No lizard. Per the brief, I used the M4's `ci/baselines/complexity_debt.json` and the `origin/metrics` record. Both read fine; `git fetch origin metrics main` worked.
- In the metrics record, `debt_new`, `debt_worse`, `debt_fixed` and `duplicate_blocks` are integer counts, not lists. So I could not say which function is the one "worse" offender app-wide, or list the duplicate blocks. A per-key list in the nightly record would help D nights.
- My first dead-code scan (a regex per function over the whole repo) timed out at 120 s. I replaced it with a single token-count pass.
- Nothing was committed or pushed. The caller's instruction overrides README rule 3 for this row.
