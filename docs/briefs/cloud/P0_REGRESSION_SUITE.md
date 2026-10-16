# Cloud brief: the P0 truth-regression suite (paste this whole file to Claude Code in the cloud)

You are working in the VideoScan repository (Swift/SwiftUI macOS app, Xcode, Swift Testing).
Build a regression suite that catches the five "the app stated an unverified fact" defects
found on 2026-10-16 (GH #327) so they can never come back, and a fixture catalog the suite
grows from. Read these first: `docs/design/integrity_first_2026_10_16.md` (§2 the rules, §5 the
truth contract), GH #327 (the five cases), `docs/practices/testing_retrospective_2026_07_05.md`
(the five test dimensions), `CLAUDE.md` ("Command shape": never `cd … &&`; use absolute paths;
`-only-testing` selects SUITES, never methods).

## Ground rules
- No family media in the repository (privacy): every file in the fixture is synthetic, made by
  ffmpeg at test time (3-second h264/aac, h264/mp3-in-mp4, pcm-in-mov, ffv1+pcm in mkv) or
  empty data files. Fixture lives under a temp directory per test run; nothing under `~`.
- Red first: for each case, run the test against the commit BEFORE its fix (listed below) in a
  separate worktree (`git worktree add <tmp> <sha>`) and quote the failing assertion in your
  report; then on `main` it must pass. A case without a quoted red is not done.
- Every test names its evidence source in its title and asserts the WORDS the surface shows
  (never only a Bool).
- New test FILE → gauntlet manifest entry in `scripts/gauntlet/manifest.json` (copy a sibling's
  shape: `assignments[]` + the matching stage's `blocked[]` entry; stage `regression`); validate:
  `swift scripts/gauntlet/inventory.swift --validate <repo> <repo>/scripts/gauntlet/manifest.json`
  → `"errors": []`.
- SwiftLint clean (no `swiftlint:disable`); every function under CCN 15.

## The fixture: `P0TruthFixtureCatalog` (test support, `VideoScan/VideoScanTests/P0TruthFixture.swift`)
A builder that creates, under a temp root, a fake archive volume folder `FamilyArchive/…/30_Video/1990-1999/1990/`,
a workspace folder, a `~Movies`-like folder, and a `VideoScanModel` (use the existing test
support the audit tests use: `ShowAgainSandbox` in `ShowAgainTests.swift`, `MasterArchiveTestSupport`)
with these rows, built from a TABLE so a new case is one row:
1. `deadLinkSource`: row whose `fullPath` is a dangling symlink (link → a file that was deleted);
   `archiveStage = .master`; an archived copy row (`derivationKind == ArchivePromotion.derivationKind`,
   `derivedFrom == source.id`) on disk under the fake archive with `archiveFixity` (SHA-256 of the real bytes).
2. `sampledOnlyPair`: two byte-identical files on two "volumes" whose rows carry only a `v1:` sampled
   `contentHash` and NO whole-file digest.
3. `mp3InM4V` / `aacInMP4` / `pcmInMOV` / `ffv1InMKV`: real ffmpeg fixtures with the catalog rows'
   `streamTypeRaw = "Video+Audio"` and the right `audioCodec`.
4. `sourceWithoutCopy`: a promotion source whose archived copy row exists but whose file is gone.
5. `silentHeader`: a row saying Video+Audio whose `audioFingerprint` stamp says `analyzedSeconds > 0, landmarks == 0`.
6. `mtimeYearsBeforeCatalogue`: a row whose file mtime is 2024-02-22 and whose `scanContext.scannedAt`
   is 2026-08-12.

## The suite: `P0TruthRegressionTests` (`VideoScan/VideoScanTests/P0TruthRegressionTests.swift`)
One test per fall, named after it, each driving the REAL surface model (not the UI):
- `journeyNeverSaysNowAtForADeadLink` — `buildFileJourney(for:allRecords:resolveVolumeSafety:)` last event
  kind `.notAtPath`, sentence contains "Not at", "link", "the archived copy is at" + the archive path.
  Red commit: the parent of the merge `53c71c593` (first parent).
- `ladderAnswersForTheContent` — `PreservationChecklist.steps(for:archivedCopy:)` on `deadLinkSource`
  → catalogued, signed, archivedLocally done; next = offsite. Red: same.
- `firstJourneyEventIsTheFilesOwnDate` — first event starts "File dated"; a separate "Catalogued" event
  with the scan date; never "Scanned on". Red: same.
- `archivePlayResolvesToTheArchivedCopy` — `archivePlayableRecord(for:)` on `deadLinkSource` → `.record(copy)`;
  on `sourceWithoutCopy` → `.missing(archivePath:…)` whose words name the ARCHIVE path and "Verify Archive",
  never the source path. Red: same.
- `playerNoticesMP3InM4V` — `PlaybackAudioMismatch.avAudioTrackCount` on the mp3 fixture == 0 and
  `words(catalogCodec:"mp3", avAudioTracks:0)` is the notice; aac/pcm → nil; mkv → the not-playable path.
  Red: same.
- `compareMediaAsksForTheHashOnASampledPair` — `RelatedLadder.judge` + `EventRecommendation.recommend`
  over the `sampledOnlyPair` evidence (build `RelatedEvidence` the way `VideoScanModel+RelatedEvidence` does)
  → rule `.r8`, door `.fingerprint`, words start "Fill in full hashes first", never contain "longer";
  the ladder has a `.missing` line "No whole-file SHA-256". Red commit: parent of `f94c392d7`.
- `folderViewNeverCallsASampledPairCopies` — `FootageFolders.index(rows:events:)` over the pair →
  no `.copy` relation between them. Red: write it red by mutating a copy of the predicate in a
  test seam if no commit exists where it failed (state which).
- `auditListsALinkRowForFixLinksAndMarksNothing` — the audit's proof on `deadLinkSource` →
  `couldNotCheck` / `neverSeenByAnAudit`, `removal == nil`; detail contains "link". Red: parent of `572d74bb0`.
- `silentHeaderIsNotHasSound` — the freshness/sound facts (`CatalogFreshnessFacts` or the sound stamp
  reader) report the row as silent, not as having sound. (If no surface exposes this yet, write the
  pure assertion against the stamp and mark the surface as "to build" in the report.)
- Source sensors (same file): no `Text(rec.fullPath)`/"Now at \(…fullPath)" rendered as presence without
  a stat in `Catalog/FileJourneySheet.swift` + `VideoScanModel+Provenance.swift`; no `"v1:"` hash
  in any equality that yields copy/identical under `Catalog/FootageFolders.swift`, `MediaOps/Cleanup/*`,
  `VideoScanCore/RelatedScore.swift`; the player start sites in `Catalog/CatalogHelpers.swift` call
  `checkPlaybackAudio`; `Archive/ArchiveView*.swift` open/reveal only through `archivePlayableRecord`.

## How to run
`xcodebuild test -project <repo>/VideoScan/VideoScan.xcodeproj -scheme VideoScan -configuration Debug -derivedDataPath <repo>/.dd-p0 -only-testing:VideoScanTests/P0TruthRegressionTests` (and the fixture's own small suite). Report executed counts.

## Deliverable
One commit on a branch `test/p0-truth-regression` with: the fixture, the suite, the manifest entry,
and `docs/reviews/p0-regression-2026-10-16.md` containing, per case: the red run's quoted failure
(with the worktree SHA), the green run, and the evidence source the test asserts. Do not merge; do
not push to main. Say plainly which cases could not be shown red and why.
