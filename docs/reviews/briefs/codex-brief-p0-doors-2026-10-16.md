# Codex brief: the three P0 doors (truth surfaces; not data-risk)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~700 words.

**One sentence (GH #327):** every fact a surface states about a file comes from verified evidence or says "unknown" — never from a row field standing in for a check.

**Range:** `2cc5808bd..53c71c593` on `main` (merge `53c71c593`; the work is `cf207bfad`). Read with `git show 53c71c593:<path>`. Paths under `VideoScan/VideoScan/`.
- `Archive/VideoScanModel+ArchivePlayable.swift` — `archivePlayableRecord(for:fileExists:)` → `.record(copy | row)` / `.missing(archivePath:message:)`; `Archive/ArchiveView+Doors.swift` (`openArchiveItems`, `revealArchiveItem`); `ArchiveView+Timeline.swift`, `ArchiveView+Table.swift`, `ArchiveView.swift`, `ArchiveView+DetailSheet.swift` (every open/reveal through the resolver).
- `Media/PlaybackAudioMismatch.swift` — `words(catalogCodec:avAudioTracks:)`, `catalogCodec(of:)`, `avAudioTrackCount(url:)`, `PlaybackAudioNoticeBar`; `Catalog/CatalogHelpers.swift` (`checkPlaybackAudio` after each local `AVPlayer(url:)`, the overlay).
- `Catalog/JourneyPresence.swift` — `probe(_:isVolumeMounted:)` (lstat + stat; leaf link named; ancestor link only when it crosses disks; unmounted /Volumes/X → volumeOffline), `currentSentence(path:presence:archivedCopy:)`; `Catalog/VideoScanModel+Provenance.swift` (`buildFileJourney(…, archivedCopy:, probe:)`, `originEvent` "File dated … (from the file's own clock)", `cataloguedEvent` from `scanContext.scannedAt`, `currentStateEvent`); `Archive/PreservationChecklist.swift` (`steps(for:archivedCopy:)`, `contentSignature`); `Model/ProvenanceTypes.swift` (`.notAtPath`).
- Tests: `VideoScan/VideoScanTests/ArchivePlayableRecordTests.swift`, `PlaybackAudioMismatchTests.swift`, `FileJourneyTruthTests.swift` (+ `JourneyPresenceTests`, `PreservationChecklistContentTests`), `ProvenanceTests.swift`. 63 tests in 13 suites green (Debug); red-first evidence in the merge's fixer report.

**Attack:**
1. Is there still a door on the Archive tab (card, chip, table, detail sheet, Family Music, keyboard) that opens or reveals a row without `archivePlayableRecord`? Can `archivedCopy(of:)`'s content-hash fallback pick a DIFFERENT archived file (same bytes, other name) and play it as if it were this row — acceptable for play, but is the sheet's path line then misleading?
2. The player check: a local file whose catalog row says Video+Audio but with `audioCodec` empty; a file AVFoundation cannot open at all; a stream; a notice keyed by path when the same path is shown twice; the check is async — can the notice land on a later row's player?
3. The journey: `probe` on a path through a symlinked ancestor on the SAME disk (/var → /private/var) must not say "link"; on another disk it must; an unmounted volume must say offline, not gone; a folder at the path; EACCES. Is the "archived copy" chosen for the ladder ever the row itself? Can the ladder say Signed from a copy whose fixity is MD5 or absent?
4. Which of these surfaces still renders a row field as a fact anywhere (e.g. `fullPath` as presence elsewhere in the sheet, `dateCreated` as "scanned", `streamTypeRaw` as "has sound")?

**Do only this:** findings against 1–4 (P1 first), each with file:line and a one-line failure scenario; then at most three P2/P3 one-liners. Out of scope: the audit job, Footage folders, the SQLite plan, wording.

**Do not explore outside the files listed above and their tests.**
