# P0 truth-regression suite — red/green run sheet (2026-10-17)

Brief: `docs/briefs/cloud/P0_REGRESSION_SUITE.md` (GH #327). Written in a Linux cloud
session **without Xcode or a Swift toolchain**: no test in this file has been compiled or
run yet. Every "expected" line below is a prediction from reading the code at the named
commit, not an observed result. The Manager fills the **Observed** lines on the Mac.

- Branch: `test/p0-truth-regression`, cut from `main` @ `58e608f8b1d4676afe78a2aacbd1c0930a4ea6c0`
- Files:
  - `VideoScan/VideoScanTests/P0TruthFixture.swift` — `P0TruthFixtureCatalog` (the table) + suite `P0TruthFixtureTests` (5 tests)
  - `VideoScan/VideoScanTests/P0TruthRegressionTests.swift` — suite `P0TruthRegressionTests` (13 tests: 9 cases + 4 source sensors)
  - `scripts/gauntlet/manifest.json` — both files assigned to stage `regression`, blocked with the sibling reason
    ("filesystem/global-state/subprocess isolation audit pending"), matching `blocked[]` entries
- Syntax check: not done (`swift`/`swiftc` are not installed here).
- Manifest check: `swift scripts/gauntlet/inventory.swift --validate …` could not run (no Swift; the script also
  imports Darwin). A line-for-line Python port of its discover + validate logic reported `"errors": []`
  (1205 files, 14157 declarations) after the entries were added; before them it reported exactly the two new files
  as unassigned. **Re-run the real validator on the Mac.**

## How the red builds compile

Several surfaces did not exist before their fix, so the suite cannot compile unchanged at the red commits.
The suite uses compilation conditions; each red build defines exactly one:

| Condition | Red commit | What it compiles out |
|---|---|---|
| `P0_RED_JOURNEY` | `d864951be` (first parent of merge `53c71c593`) | `JourneyPresence`, `PreservationChecklist.steps(for:archivedCopy:archivedCopyPresence:)`, `archivePlayableRecord`, `PlaybackAudioMismatch` |
| `P0_RED_AUDIT` | `46c66aae9` (first parent of merge `572d74bb0`) | the above + `FootageFolders` |
| `P0_RED_COMPARE` | `b03c3ce6b` (parent of `f94c392d7`) | the above + the audit plan's `laneRoot:` seam |
| `P0_RED_FOLDER_MUTANT` | `main` | nothing — it swaps in a copy of the folder copy-key predicate with its `v1:` guard removed |

A test whose surface is compiled out calls `Issue.record("… does not exist at this commit …")`: its red is
"the surface is absent", not a failed assertion. The report must say which kind of red each case got.

All SHAs were checked with `git log -1 --format='%H %P %s'`:
- `53c71c593…` parents `d864951be…` `cf207bfad…` — "Merge: three P0 doors (GH #327)…"
- `f94c392d7…` parent `b03c3ce6b…` — "fix(compare): a hashless tie asks for the full hash (R8…)"
- `572d74bb0…` parents `46c66aae9…` `6140ea912…` — "Merge: Audit Catalog tier 0 — codex r3 closed (3)…"

The test target uses file-system-synchronized groups at all three red commits
(`PBXFileSystemSynchronized*` present), so copying the two files into a worktree adds them to the target.

### Commands (no `cd`; `<repo>` = the Mac checkout, e.g. `/Users/rickb/dev/VideoScan`)

Green, on the branch:
```
xcodebuild test -project <repo>/VideoScan/VideoScan.xcodeproj -scheme VideoScan -configuration Debug -derivedDataPath <repo>/.dd-p0 -only-testing:VideoScanTests/P0TruthRegressionTests -only-testing:VideoScanTests/P0TruthFixtureTests
```

Red, one worktree per commit (shown for the journey commit; for the others swap the SHA, the folder and the condition):
```
git -C <repo> worktree add /tmp/p0-red-journey d864951be
cp <repo>/VideoScan/VideoScanTests/P0TruthFixture.swift <repo>/VideoScan/VideoScanTests/P0TruthRegressionTests.swift /tmp/p0-red-journey/VideoScan/VideoScanTests/
xcodebuild test -project /tmp/p0-red-journey/VideoScan/VideoScan.xcodeproj -scheme VideoScan -configuration Debug -derivedDataPath /tmp/p0-red-journey/.dd-p0 -only-testing:VideoScanTests/P0TruthRegressionTests 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) P0_RED_JOURNEY'
git -C <repo> worktree remove --force /tmp/p0-red-journey
```
- audit: `/tmp/p0-red-audit`, `46c66aae9`, `P0_RED_AUDIT`
- compare: `/tmp/p0-red-compare`, `b03c3ce6b`, `P0_RED_COMPARE`
- folder mutant: on the branch itself, `-derivedDataPath <repo>/.dd-p0-mutant`, `P0_RED_FOLDER_MUTANT`

`$(inherited)` keeps `DEBUG`. If the command-line setting does not inherit on this Xcode, use
`'OTHER_SWIFT_FLAGS=$(inherited) -DP0_RED_JOURNEY'` instead. To capture the compile-time red as well
(it shows the surface is missing), run each red build once **without** the condition and quote the first
`error: cannot find '…' in scope`.

In a red run, only the assertions listed for that commit are the case's red. Other tests in the suite may
also fail there, because they cover surfaces that commit does not have (e.g. the sensors read files that
did not exist yet).

## Per case

### 1. `journeyNeverSaysNowAtForADeadLink` — File Journey's last event
- Evidence: `VideoScanModel.buildFileJourney(for:allRecords:resolveVolumeSafety:)` + lstat of the row's path; row `deadLinkSource` (a dangling symlink) with `deadLinkArchivedCopy` (real bytes, SHA-256 fixity).
- Red commit: `d864951be`, condition `P0_RED_JOURNEY`.
- Expected red: `String(describing: last.kind) == "notAtPath"` fails with `"currentState"`; `last.sentence.hasPrefix("Not at …")` and `!last.sentence.hasPrefix("Now at")` fail. The old code states `"Now at \(rec.fullPath)"` with no stat.
- Expected green on the branch: the sentence starts `Not at <link path>`, contains `link` and `the archived copy is at <copy path>`.
- Observed red: _(Manager)_ — Observed green: _(Manager)_

### 2. `ladderAnswersForTheContent` — the preservation ladder
- Evidence: `buildFileJourney(…).preservation` (exists at both commits), plus `PreservationChecklist.steps(for:archivedCopy:archivedCopyPresence:)` and `nextAction` on `main` only.
- Red commit: `d864951be`, `P0_RED_JOURNEY`.
- Expected red: `ticked == ["Catalogued", "Signed", "Archived locally"]` fails with `["Catalogued"]`; `next?.title == "Archived offsite"` fails with `"Signed"`. The old `steps(for:)` reads only the row itself.
- Expected green: 3 of 4 ticked; next is "Archived offsite"; `nextAction` contains "out of the building".
- Observed: _(Manager)_

### 3. `firstJourneyEventIsTheFilesOwnDate` — "File dated", never "Scanned on"
- Evidence: `buildFileJourney` over row `mtimeYearsBeforeCatalogue` (file mtime and `dateModifiedRaw` 2024-02-22; `scanContext.scannedAt` 2026-08-12).
- Red commit: `d864951be`, `P0_RED_JOURNEY`.
- Expected red: `first.sentence.hasPrefix("File dated")` fails (old: `"Scanned on <vol> at <path>"`, or `"Scanned at <path>"` when the volume name is empty); `catalogued != nil` fails; `scanned.isEmpty` fails.
- Expected green: the first event says "File dated … (from the file's own clock)" with timestamp 2024-02-22, and a separate "Catalogued by VideoScan…" event has 2026-08-12.
- Observed: _(Manager)_

### 4. `archivePlayResolvesToTheArchivedCopy` — the Archive doors
- Evidence: `VideoScanModel.archivePlayableRecord(for:)` with the default FileManager probe. `deadLinkSource` resolves to `.record(copy)`. `sourceWithoutCopy` (both files gone) resolves to `.missing`, whose words name the archive path and "Verify Archive" but never the source path.
- Red commit: `d864951be`, `P0_RED_JOURNEY`.
- Expected red: **surface absent.** `Issue.record("archivePlayableRecord(for:) does not exist at this commit…")`; without the condition, the compile error is `cannot find … archivePlayableRecord`. The sensor `archiveDoorsGoOnlyThroughTheResolver` also goes red there, because `ArchiveView+Doors.swift` does not exist yet and the read throws.
- Observed: _(Manager)_

### 5. `playerNoticesMP3InM4V` — MP3 in an MPEG-4 container
- Evidence: real ffmpeg fixtures built at test time under the temp root (mp3-in-m4v, aac-in-mp4, pcm-in-mov, ffv1+pcm-in-mkv), checked with `PlaybackAudioMismatch.catalogCodec(of:)`, `avAudioTrackCount(url:)` and `words(catalogCodec:avAudioTracks:)`. MKV goes through `PreviewFrameRouter.previewRoute` → `PreviewPlayAction.filmstrip`. Requires `CleanupTestMedia.toolsAvailable` (ffmpeg).
- Red commit: `d864951be`, `P0_RED_JOURNEY`.
- Expected red: **surface absent** (`Issue.record("PlaybackAudioMismatch does not exist at this commit…")`). Without the condition: `cannot find 'PlaybackAudioMismatch' in scope`. The sensor `everyPlayerStartChecksTheAudio` goes red with `checks >= 2` (0 calls to `checkPlaybackAudio(` in the old CatalogHelpers).
- Expected green: mp3 has 0 tracks and the exact notice text; aac/pcm have 1 track each and no notice (`nil`); mkv routes to the filmstrip and AVFoundation throws.
- Observed: _(Manager)_

### 6. `compareMediaAsksForTheHashOnASampledPair` — Compare Media on a `v1:`-only pair
- Evidence: `VideoScanModel.relatedSide` for each row of `sampledOnlyA` / `sampledOnlyB`. They are byte-identical with only a `v1:` hash, on two folders, with `isOnDisk` from a stat. The sound print's answer is injected as `.sameRecording` with coverage 1.0, because the fingerprint engine is not run. The sides go through `RelatedLadder.judge` and then `EventRecommendation.recommend`.
- Red commit: `b03c3ce6b`, `P0_RED_COMPARE`.
- Expected red: `reco.rule == .r8` fails with `r6`; `reco.door == .fingerprint` fails with `recommendMaster`; `reco.words.hasPrefix("Fill in full hashes first")` fails; `!reco.words.contains("longer")` fails (old: "Nothing is archived. Promote the longer transfer as the master, then revisit the other."); the `.missing` line "No whole-file SHA-256 for either file" is absent.
- Caveat: this assumes the ladder reaches the same-recording rung for these sides. The two folder labels differ ("volumea"/"volumeb"). If the rung differs, the first failing line will say so. Record what it says.
- Observed: _(Manager)_

### 7. `folderViewNeverCallsASampledPairCopies` — Footage folders
- Evidence: `FootageFolders.index(rows: model.footageFolderRows(), events:)` with one event holding both rows' content keys, plus `FootageFolders.Row.copyKey` for each row.
- Red: **no commit ever had this defect.** `FootageFolders` refused `v1:` from its first commit `a1385a8`, and the type does not exist at `b03c3ce6b` / `46c66aae9`. The red is a **seam**: build `main` with `P0_RED_FOLDER_MUTANT`. The test's `copyKey` then becomes a copy of the predicate with the `v1:` guard removed.
- Expected red (mutant): `Self.copyKey(rowA, sampledHash:) == nil` and the same for B fail with `"d:v1:…:4096"`. The real `index` assertions stay green under the mutant, because it only replaces the test's own copy of the predicate.
- Observed: _(Manager)_

### 8. `auditListsALinkRowForFixLinksAndMarksNothing` — Audit Catalog
- Evidence: `model.catalogAuditPlan(laneRoot:)` (the lane is the fixture's physical root), then `CatalogAuditStat.of(path)`, then `model.applyCatalogAudit(_:to:)`. That last call is the proof at the mark, through a directory handle. Two rows: `deadLinkSource` (a link at the name) and `sourceWithoutCopy` (a plain gone file with no where-seen stamp).
- Red commit: `46c66aae9`, `P0_RED_AUDIT`.
- Expected red, **only for the never-seen row**: `unseenResult.result == "neverSeenByAnAudit"` fails with `"couldNotCheck"`; `detail.contains("Fix Links decides")` fails; `!detail.contains("not connected")` fails. Without the job's mount anchor, the old proof returns `.driveNotConnected` and says "the drive it was expected on is not connected", which is false for a connected drive.
- **Expected NOT red: the link row.** The old walk already read the name with `fstatat(…, AT_SYMLINK_NOFOLLOW)` (`46c66aae9:CatalogAuditPlan.swift`, `statName`), so a dead link there was already "could not check … (a folder, device or link is at the path)". The link half of the case cannot be shown red at this commit. It is pinned as a guard only.
- Observed: _(Manager)_

### 9. `silentHeaderIsNotHasSound` — Video+Audio with a silent sound print
- Evidence: the row's `AudioFingerprintStamp` (`outcome == .fingerprinted`, `analyzedSeconds == 3`, `landmarks == 0`) and `VideoScanModel.relatedSide(…).audibleSeconds`.
- **Surface: to build.** No surface says "silent" yet. `CatalogFreshnessFacts` carries no per-row sound fact. The one reader of the stamp, Compare Media's `relatedSide`, counts `analyzedSeconds` as audible seconds when landmarks are 0. That behaviour is pinned under `withKnownIssue`, so the test passes today and fails when someone fixes it. It then has to be turned into a plain expectation.
- Red: none exists (there is no fix commit). The pure stamp assertions are green at every commit.
- Observed: _(Manager)_

### Source sensors (same suite)
| Test | Expected red |
|---|---|
| `journeyRendersNoPathAsPresenceWithoutAStat` | `d864951be`: `"Now at \(rec.fullPath)"` and `"Scanned on …"` in `VideoScanModel+Provenance.swift`; no `JourneyPresence.currentSentence(` |
| `noSampledHashDecidesACopy` | none: no commit read `contentHash` in these files. It throws at `b03c3ce6b`/`46c66aae9` (FootageFolders.swift absent) |
| `everyPlayerStartChecksTheAudio` | `d864951be`: `checks >= 2` fails (0) |
| `archiveDoorsGoOnlyThroughTheResolver` | `d864951be`: `ArchiveView+Doors.swift` absent (read throws); the direct `MediaOpener.open(` in the ArchiveView files |

## What the brief asked for that this run could not do
- **Run anything.** No Xcode, no Swift toolchain (`swift --version`: not found). No red or green is quoted here.
  Each "Observed" line is for the Manager.
- **`swiftc -parse`:** not available. The new files were checked by reading only, against the signatures at `main`
  and at each red commit.
- **Red-first for the audit case's link half and for the silent header:** not possible (see cases 8 and 9).
  The folder case's red is a mutation seam, not a commit.
- **`archiveStage = .master`** (the brief's word) is spelled `.masterAssigned` in the code.
- **ShowAgainSandbox**: used for the model (isolated catalog store, ledger, logs). Its `physical(_:)` helper is not
  at the red commits, so the fixture carries its own `realpath(3)`.
