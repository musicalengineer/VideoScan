# Codex review — Event Analyzer engines + Compare Media

- Range: `fbc979a9c..5187f2be9`
- Credits spent: unavailable (no billing meter exposed)
- Tokens: 78799
- Finding count: 6
- Verdict: fix — archived clips can become removal subjects, and invalid identity/date evidence can authorize removal advice.
- Run: 2026-10-16T01:02:40Z (cycle #75, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (no billing meter exposed) | Finding count: 6

Verdict: fix — archived clips can become removal subjects, and invalid identity/date evidence can authorize removal advice.

Reviewed `5187f2be9`. No files written. Tests below are proposed RED cases derived from source; **not executed**. Place them in the named existing test suites.

1. **P1 — R2 can target protected archive content.** [EventRecommendation.swift:62](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/EventRecommendation.swift:62), invariant 3.  
   Scenario: an archived master contains a clip that is itself archived or an archive file; R2 still selects that clip for removal. Guard both protection flags on the subject.

```swift
// EventRecommendationTests
@Test func r2NeverTargetsProtectedClip() {
    for (archiveFile, archived) in [(true, false), (false, true)] {
        var clip = side(archived: false, digest: "c")
        clip.durationSeconds = 78
        clip.isArchiveFile = archiveFile
        clip.isArchived = archived
        let r = reco(RelatedEvidence(
            a: clip, b: side(archived: true, digest: "m"),
            audio: .containedInMaster(offsetSeconds: 376)))
        #expect(r.rule != .r2) // Actual: R2, subject .a
    }
}
```

2. **P1 — The era guard loses valid pre-2000 evidence.** [EventRecommendation.swift:112](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/EventRecommendation.swift:112) and [VideoScanModel+RelatedEvidence.swift:85](/Users/rickb/dev/VideoScan/VideoScan/Events/VideoScanModel+RelatedEvidence.swift:85), invariants 3–4.  
   Scenario: a reliable 1988 recording date plus an unreliable 2006 transfer date yields R3 on a tie; additionally, a year-only 1988 date disappears during projection. Preserve year independently of day precision and prevent unreliable newer dates from defeating the protection.

```swift
// EventRecommendationTests
@Test func transferDateCannotCancelEraProtection() {
    var copy = side(archived: false, year: 2006, digest: "x")
    copy.dayIsReliable = false
    let r = reco(RelatedEvidence(
        a: copy, b: side(archived: true, year: 1988, digest: "y"),
        audio: .sameRecording))
    #expect(r.rule == .r5) // Actual: R3
}

// CompareMediaTests
@Test @MainActor func yearOnlyDatePreservesEraProtection() {
    let record = VideoRecord()
    record.userDate = "1988"
    record.durationSeconds = 2100
    let a = VideoScanModel.relatedSide(
        record, isArchiveFile: false, isArchived: false, now: Date())
    var b = a
    b.isArchiveFile = true
    b.isArchived = true
    let e = RelatedEvidence(a: a, b: b, audio: .sameRecording)
    let r = EventRecommendation.recommend(RelatedLadder.judge(e), evidence: e)
    #expect(r.rule == .r5) // Actual: R3; both years became nil
}
```

3. **P1 — Empty digests establish byte identity.** [RelatedScore.swift:257](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/RelatedScore.swift:257), invariant 1.  
   Scenario: two positive, equal-sized sides with `digest: ""` become `.identicalCopy`, enabling R1 against an archived counterpart. Reject empty digests before equality establishes identity.

```swift
// RelatedLadderTests
@Test func emptyDigestsCannotAuthorizeCopyRemoval() {
    var archived = master
    archived.digest = ""
    var copy = archived
    copy.isArchiveFile = false
    copy.isArchived = false
    let e = RelatedEvidence(a: copy, b: archived)
    let v = RelatedLadder.judge(e)
    #expect(!v.isIdenticalCopy) // Actual: identicalCopy
    #expect(EventRecommendation.recommend(v, evidence: e).rule != .r1)
}
```

4. **P2 — Contradictions disappear after an early winning rung:** [RelatedScore.swift:233](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/RelatedScore.swift:233), invariant 4; identical bytes plus `.different` audio retain rung 6 correctly but hide the sound contradiction—collect contradictory evidence independently of rung selection.

```swift
// RelatedLadderTests
@Test func identicalCopyStillShowsSoundContradiction() {
    let v = RelatedLadder.judge(
        RelatedEvidence(a: master, b: master, audio: .different))
    #expect(v.rung == .identicalCopy)
    #expect(has(v, .contradicts, "Sound:"))
}
```

5. **P2 — The band independently overclaims “byte for byte”:** [CompareMediaView.swift:211](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CompareMediaView.swift:211), invariant 1; matching stored digests with different sizes and `.sameRecording` audio bypass the engine’s size guard in presentation—use the identical-copy verdict or the complete identity predicate.

```swift
// CompareMediaTests
@Test func durationWordsRequireEqualSizesForByteIdentity() {
    let a = RelatedEvidence.Side(
        digest: "x", sizeBytes: 1, durationSeconds: 2280)
    let b = RelatedEvidence.Side(
        digest: "x", sizeBytes: 2, durationSeconds: 2280)
    let e = RelatedEvidence(a: a, b: b, audio: .sameRecording)
    let v = RelatedLadder.judge(e)
    #expect(!CompareMediaWords.duration(v.band, e).contains("byte for byte"))
}
```

6. **P2 — Canvas binning is O(seconds + width), not O(width):** [CompareMediaView.swift:184](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CompareMediaView.swift:184), invariant 6; every redraw traverses every represented second, including seconds beyond `active`—precompute range summaries and query them per pixel.

```swift
// CompareMediaTests; additionally import SwiftUI.
// Synthetic duration stress sensor; run on the routed test machine.
@Test @MainActor func stripDrawCostIsBoundedByWidth() throws {
    let fixture = RelatedEvidence.Side(durationSeconds: 2280)
    let warmup = ImageRenderer(content:
        SoundStrip(active: [], matched: nil, durationSeconds: 1)
            .frame(width: 100, height: 44))
    _ = warmup.cgImage
    let renderer = ImageRenderer(content:
        SoundStrip(active: [], matched: nil,
                   durationSeconds: fixture.durationSeconds * 1_000_000)
            .frame(width: 100, height: 44))
    let clock = ContinuousClock()
    let start = clock.now
    #require(renderer.cgImage != nil)
    #expect(start.duration(to: clock.now) < .milliseconds(250))
}
```

Remaining scoped checks: presence veto/nil distinction, date-conflict rung blocking, transfer ordering, whole-word names and privacy logging: read, no findings. Detached I/O placement and view catalog access: read, no findings. Matcher/store references, `EventsDate.resolve`, design sections and existing tests: read, no findings against those files. Unmounted-volume detection depends on out-of-scope `VolumeReachability`; its behavior was not independently verified.

## Brief

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

## Closure

Branch `feature/compare-media` (worktree), closed the same night. Core: 29 tests in 2 suites; app: CompareMediaTests 10 + CleanupTrashHardeningTests 7 — all green (Debug).

| Finding | Closure | Pinning test |
|---|---|---|
| F1 P1 R2 can target an archived clip | fixed: `EventRecommendation.recommend` — a clip that is an archive file or whose content is archived is never a removal subject; "Both are in the archive" (R7, no subject) | `EventRecommendationTests.r2NeverTargetsProtectedClip` (codex's red case, both flags) |
| F2 P1 the era guard loses pre-2000 evidence | fixed: `isOlderGeneration` reads RELIABLE years first (an unreliable 2006 rip date never defeats a reliable 1988), any year only when none is reliable; `Side.year` is stored (a year-only date carries its year; a day sets it too) and the projection passes `date.year` | `EventRecommendationTests.transferDateCannotCancelEraProtection` (codex's two cases), `RelatedLadderTests.yearOnly`, `CompareMediaTests.yearOnlyDate` |
| F3 P1 empty digests establish identity | fixed: `Side.digest` normalizes "" to nil in `init` and on set (`didSet`); `identicalCopy` also requires a non-empty digest | `RelatedLadderTests.emptyDigestsCannotAuthorizeCopyRemoval` (codex's red case) |
| F4 P2 contradictions hidden by an early rung | fixed: rung 6 appends the sound contradiction ("the bytes are identical, so one fingerprint is stale or partial — fingerprint again") when the audio verdict is different/overlap; the date contradiction was already added before the ladder | `RelatedLadderTests.identicalCopyStillShowsSoundContradiction` (codex's red case) |
| F5 P2 the band overclaims "byte for byte" | fixed: `CompareMediaWords.duration` says "byte for byte" only for equal digest AND equal size > 0 | `CompareMediaTests.durationWordsRequireEqualSizesForByteIdentity` (codex's red case) |
| F6 P2 Canvas binning O(seconds + width) | fixed: `SoundStripBins` — prefix sums over the audible seconds built once per view value; each pixel answers in O(1); the matched range by overlap | `CompareMediaTests.stripBins` (edges, beyond-the-map, matched overlap); codex's ImageRenderer stress sensor declined in favour of the pure bins test (an ImageRenderer timing test is machine-dependent) |

## Closed

Closed by `c6625b218` at 2026-10-16T01:11:47Z. 6 findings closed with codex's red cases adopted (F1 R2 protected clip, F2 era rule/year-only, F3 empty digest, F4 contradiction kept, F5 band words, F6 O(width) strip); Core 29 + app 17 green
