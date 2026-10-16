# Codex brief: Event Analyzer engines + Compare Media step 1 (logic that will feed deletes)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~1,100 words. For each finding, include a RED Swift Testing test case (a `@Test` function body, using the fixtures already in the test files) that would fail at the reviewed SHA.

**One sentence (Rick, 2026-10-15):** tell me whether two media files are the same event exactly, how they differ if not, or that they do not represent the same event in any way — then say what to do about it.

**Why it matters:** the verdict band and the recommendation will, in later steps, hand files to Cleanup lanes ("clips of a master", "superseded transfers"). A wrong word here becomes a wrong delete later. Tonight the view only shows; nothing moves.

**Range:** main `fbc979a9c..5187f2be9` (three merges: f7e57bf09 engines, 85158ed9e view, 5187f2be9 presence veto). Read files with `git show 5187f2be9:<path>`.
- `VideoScan/VideoScanCore/Sources/VideoScanCore/RelatedScore.swift` — `RelatedEvidence` (+ `Side`), `RelatedLadder.judge` and its rungs (`notOnDisk`, `identicalCopy`, `whatTheSoundSays`, `clip`, `sameMoment`, `soundAbsence`, `whatTheFramesSay`, `calendarAndPeople`), `dateRelation`, `peopleAndWords`, `betterTransfer`, `evidenceAvailable`, words.
- `VideoScan/VideoScanCore/Sources/VideoScanCore/EventRecommendation.swift` — `recommend`, `sameEvent`, the era rule.
- `VideoScan/VideoScan/Events/VideoScanModel+RelatedEvidence.swift` — `relatedAnswer(a:b:)` (main actor projection; `soundEvidence` + `isOnDisk` off-main), `relatedSide`, `namesSaid`, `occasionWords`, `folderLabel`, `codecGeneration`, `frameHeight`, `bitRate`, `soundEvidence` (sidecar load + `AudioFingerprintMatcher.match`, the strips).
- `VideoScan/VideoScan/MediaOps/CompareMediaView.swift` — `CompareMediaStore`, the band/lines/recommendation, the spools, `SoundStrip`, `CompareMediaWords`.
- Reference, read-only: `AudioFingerprintMatcher.swift` (`AudioMatchVerdict`, `AudioMatchEvidence.verdict`), `AudioFingerprintStore.swift` (`Key`, `fingerprint(for:)`), `Events/EventsPlan.swift` (`EventsDate.resolve`), `docs/design/event_analyzer_compare_media_2026_10_15.md` (§2 bands, §4 rules, §8 rulings).
- Tests: `VideoScanCore/Tests/VideoScanCoreTests/RelatedLadderTests.swift` (14), `EventRecommendationTests.swift` (10), `VideoScan/VideoScanTests/CompareMediaTests.swift` (7).

**Invariants to attack (prove with file:line or say it holds):**
1. No band stronger than its evidence: `.sameEvent` or `.clipFromSameEvent` only from an equal whole-file digest + equal size > 0, an audio verdict of sameRecording / contained, or a video alignment ≥ 0.5 — never from dates, people, folder or words alone; `.identicalCopy` never from digests of different sizes or empty digests.
2. A side with `isOnDisk == false` never gets a rung; `isOnDisk == nil` (drive not mounted) never counts as gone. The projection's `isOnDisk` returns nil for an unmounted external volume and false for a path that is a directory or missing.
3. Recommendations: R1/R2/R3 never name as `subject` a side with `isArchiveFile` or `isArchived`; R2/R3 require the OTHER side archived; neither R1 nor R3 fires when both sides are archived; a pre-2000 tie never yields R3; `.differentCapture` and `.differentEvents` never yield a removal rule; `.notEnoughEvidence` always yields R8.
4. Contradictions are shown, never subtracted: a reliable date conflict blocks rungs 4 and 3 only (never 5/6); an unreliable date never contradicts; occasion words in common never raise a rung.
5. `betterTransfer`: the ordered list (audible length > 5 %, codec generation, frame height, bit rate) and `.tie` otherwise; never prefers a delivery re-encode over an original capture of the same length.
6. Concurrency and perf: `relatedAnswer` touches the catalog only on the main actor; the sidecar open, fingerprint loads, matching and the two stats run in the detached task; `CompareMediaStore.load` computes once per pair; no view body walks `records` or touches the disk; the Canvas strip binning is O(width) per draw.
7. Words/privacy: nothing here logs a path, a name or a transcript; `namesSaid` matches whole words only (not "markers" for "Mark").
8. Edge cases: empty `activeSeconds` (older fingerprint) → every second audible; a `.overlap` of < 5 s is "nothing in common"; `.inconclusive` never becomes a verdict; a side with duration 0.

**Do only this:** findings against 1–8 (P1 first), each with file:line, a one-line failure scenario and the red test; then at most three P2/P3 one-liners. Out of scope: the Compare tiers (`MediaPairComparator`, `PairCompareJob`), Compare Footage, the Events page, the film frames (not built).

**Do not explore outside the files listed above and their tests.**
