# Codex review — P0 doors

- Range: `2cc5808bd..53c71c593`
- Credits spent: unavailable (billing not exposed)
- Tokens: 92220
- Finding count: 6
- Verdict: fix — the specified revision still makes unsupported presence and preservation claims.
- Run: 2026-10-16T23:25:02Z (cycle #87, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (billing not exposed) | Finding count: 6
Verdict: fix — the specified revision still makes unsupported presence and preservation claims.

- **P1 — Unvalidated fixity can complete preservation.** [PreservationChecklist.swift:100](/Users/rickb/dev/VideoScan/VideoScan/Archive/PreservationChecklist.swift:100) accepts any nonnil `archiveFixity` as “Archived locally,” bypassing the digest validation used for “Signed.” **Failure scenario:** give the source a valid SHA-256 signature and an offsite entry, but its promoted copy only `algorithm: "md5", digest: "abcd"`; all four steps become complete and the strip says “safe.” The existing MD5 test checks only Signed.

- **P1 — Permission failures become declarations of loss.** [JourneyPresence.swift:46](/Users/rickb/dev/VideoScan/VideoScan/Catalog/JourneyPresence.swift:46) converts every unsuccessful `lstat` into `.missing` unless the lexical path identifies an offline volume; the leaf-link `stat` branch similarly treats every failure as a broken link. **Failure scenario:** an existing file beneath a directory without search permission produces EACCES and the journey says “the file is gone,” offering Fix Links, instead of reporting unknown presence.

- **P1 — An offline archived copy is reported missing.** [JourneyPresence.swift:124](/Users/rickb/dev/VideoScan/VideoScan/Catalog/JourneyPresence.swift:124) reduces the copy’s presence to `isPresent`; `.volumeOffline` falls through to “not there either — run Verify Archive.” **Failure scenario:** the source is missing and FamilyArchive is disconnected; the probe correctly reports the copy offline, but the final sentence asserts its absence.

- **P2 — Cross-disk ancestor links go undetected:** [JourneyPresence.swift:81](/Users/rickb/dev/VideoScan/VideoScan/Catalog/JourneyPresence.swift:81) compares the resolved directory’s device with the final file’s device; for `~/Movies → /Volumes/Media/Movies`, both are Media, so the journey omits the link. Compare the link’s containing device with its resolved target.

- **P2 — Late audio checks erase the current warning:** [CatalogHelpers.swift:1882](/Users/rickb/dev/VideoScan/VideoScan/Catalog/CatalogHelpers.swift:1882) publishes without checking playback identity; start A, then B, let B’s mismatch finish first and A’s last—the stored notice becomes A’s, and the path filter hides B’s warning. A playback generation is needed beyond the display-time path comparison.

- **P2 — The detail sheet mixes two files’ identities:** [ArchiveView+DetailSheet.swift:138](/Users/rickb/dev/VideoScan/VideoScan/Archive/ArchiveView+DetailSheet.swift:138) substitutes the resolved copy’s path while the title and Volume remain the source’s fields at lines 32 and 68; a same-content fallback from `old.mov` on OldDisk to `holiday.mov` on FamilyArchive displays FamilyArchive’s path beneath `old.mov` while claiming Volume OldDisk.

## Brief

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


## Closure (Manager, 2026-10-16 night — fix `dcf844e7f`, merged `9a5228ddc`)

All six closed RED FIRST (13 tests / 17 issues red on main for the three P1s; compile-red for the three P2s that needed new seams; then 58 tests in 14 suites green, Debug).
1. **P1 unvalidated fixity → "Archived locally"** — needs the copy ON DISK (probe) with a whole-file SHA-256 fixity, the same validation as "Signed"; nil presence = nobody looked = not done. Pins `md5CopyNeverCompletesArchivedLocally`, `archivedCopyGoneFromDiskDoesNotCompleteArchivedLocally`. (The brief's "2 of 4" was 3 of 4 with the source's own signature — the pin asserts the step, not the sum.) Follow-up noted: the legacy `BackupEntry` / `archiveStage == .archived` ticks still read a field — GH #327 list.
2. **P1 permission error → "gone"** — only ENOENT/ENOTDIR are gone; anything else is `.unknown(errno)` "Could not check <path>: … — presence unknown", a grey question-mark event, no Fix Links offer. Pin `permissionDeniedIsUnknownNeverGone` (chmod 000 parent).
3. **P1 offline copy → "missing"** — the copy's presence in its own words (present / offline on <volume> / could not check / not at its path). Pin `archivedCopyPresenceIsSaidInItsOwnWords`.
4. **P2 cross-disk ancestor link** — compares the link's CONTAINING folder's device with the link's resolved device (the old compare could never fire); device lookup is a seam (one physical disk on the M4). Pin `ancestorLinkOntoAnotherDiskIsNamed`.
5. **P2 late audio check** — `PlaybackAudioChecker` generation ticket; a check whose ticket is stale never publishes; stream players take tickets too. Pins `aCheckThatFinishesAfterTheNextStartIsStale`, sensor `everyPlayerStartIsNumbered`.
6. **P2 detail sheet identities** — `ArchiveDetailWords`: "Playing the archived copy: <copy> (this row: <source>, a dead link)" and one labelled Volume line per file. Pins `ArchiveDetailSheetWordsTests` (4).
Also: a `||` inside a closure in `PreservationChecklist.steps` was hoisted into `isAway(_:)` (the CI type-check class).

## Closed

Closed by `9a5228ddc` at 2026-10-16T23:49:43Z. 3 P1 + 3 P2 closed red-first
