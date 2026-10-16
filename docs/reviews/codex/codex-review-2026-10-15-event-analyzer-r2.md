# Codex review — Event Analyzer round 2

- Range: `5187f2be9..c6625b218`
- Credits spent: unavailable
- Tokens: 60792
- Finding count: 5
- Verdict: fix — the recommendation path still mishandles conflicting eras and an archived clip whose master is unarchived. No P1 demonstrated.
- Run: 2026-10-16T01:12:46Z (cycle #77, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 5
Verdict: fix — the recommendation path still mishandles conflicting eras and an archived clip whose master is unarchived. No P1 demonstrated.

Reviewed `5187f2be9..c6625b218`. Cases below are predicted RED from source inspection, **not executed**; no files written.

1. **P2 — Mixed years still bypass era protection.** [EventRecommendation.swift:122](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/EventRecommendation.swift:122)

   Failure: tied transfers dated reliable 1988/2015—or unreliable 1988/2006—produce R3 because `allSatisfy` returns false. A reliable conflict should hold removal pending date resolution. With neither reliable, retaining both when either suggests pre-2000 is conservative; correcting the dates can subsequently permit R3.

   RED in `EventRecommendationTests.swift`, using `side`/`reco`:

   ```swift
   @Test func mixedErasDoNotRecommendRemoval() {
       for reliable in [true, false] {
           var a = side(archived: false, year: 1988, digest: "x")
           var b = side(archived: true,
                        year: reliable ? 2015 : 2006, digest: "y")
           a.dayIsReliable = reliable
           b.dayIsReliable = reliable
           let r = reco(RelatedEvidence(a: a, b: b,
                                        audio: .sameRecording))
           #expect(r.rule != .r3)
       }
   }
   ```

2. **P2 — Protecting the clip suppresses promotion of its unarchived master.** [EventRecommendation.swift:63](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/EventRecommendation.swift:63)

   Failure: an archived 78-second clip and unarchived 2,100-second master get “Both are in the archive. Nothing to do.” Return R6 targeting the master, with wording acknowledging that only the clip is archived.

   RED in `EventRecommendationTests.swift`:

   ```swift
   @Test func archivedClipStillNeedsItsMasterArchived() {
       var clip = side(archived: true, digest: "c")
       clip.durationSeconds = 78
       clip.audibleSeconds = 76
       let r = reco(RelatedEvidence(
           a: clip, b: side(archived: false, digest: "m"),
           audio: .containedInMaster(offsetSeconds: 376)))
       #expect(r.rule == .r6 && r.subject == .b)
       #expect(r.door == .recommendMaster)
       #expect(!r.words.contains("Both are in the archive"))
   }
   ```

3. **P3 — NaN duration traps during bin construction.** [CompareMediaView.swift:212](/Users/rickb/dev/VideoScan/VideoScan/MediaOps/CompareMediaView.swift:212)

   Failure: `Int(Double.nan)` terminates before `max` can select the valid map length. Nonfinite input should fall back to the map length; production reachability is unproven within scope. Ordinary finite negative durations already clamp correctly.

   RED in `CompareMediaTests.swift`, using its `stripBins` bitmap; currently crashes:

   ```swift
   @Test func nonfiniteDurationUsesMapLength() {
       let bins = SoundStripBins(
           active: [false, true, true, false, false, true],
           matched: 1..<3, durationSeconds: .nan)
       #expect(bins.seconds == 6)
   }
   ```

4. **P3 — Mutating `day` leaves `year` stale.** [RelatedScore.swift:118](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/RelatedScore.swift:118)

   Failure: copying a 2015 side and correcting its day to 1988 leaves the era reader seeing 2015. Prefer the current day’s year, retaining a separate fallback for year-only evidence. This is latent: the scoped production mutations change names, presence and audible duration, never dates.

   RED in `EventRecommendationTests.swift`:

   ```swift
   @Test func correctedDayUpdatesEraYear() {
       var a = side(archived: false, year: 2015, digest: "x")
       a.day = day(1988, 4, 22)
       #expect(a.year == 1988)
   }
   ```

5. **P3 — Substantial overlap is described as no shared sound.** [RelatedScore.swift:269](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/RelatedScore.swift:269)

   Failure: identical-byte evidence with 2,000 seconds of overlap says “nothing in common.” Preserve identity, but describe the partial match accurately. Whether the actual matcher emits this for identical bytes cannot be established from the permitted files.

   RED in `RelatedLadderTests.swift`, using `master`/`has`:

   ```swift
   @Test func identicalOverlapIsNotNoSharedSound() {
       let v = RelatedLadder.judge(RelatedEvidence(
           a: master, b: master,
           audio: .overlap(offsetSeconds: 0, seconds: 2000)))
       #expect(v.isIdenticalCopy)
       #expect(!has(v, .contradicts, "nothing in common"))
   }
   ```

Remaining checks hold: **#5**, initialization and subsequent assignment normalize empty digests; the declared types are not Codable, and the explicit initializer suppresses synthesized memberwise initialization. **#6**, crossing the bitmap’s end correctly queries the available portion; Canvas drawing is O(width), although constructing its prefix remains O(seconds). **#7**, line 245 explicitly requires positive size, so zero-size rows cannot say “byte for byte.”

`VideoScanModel+RelatedEvidence.swift`: read, no findings in the projection change. All three named test files: read, no independent findings; their missing cases are above.

## Brief

# Codex brief: Event Analyzer — round 2 (attack the round-1 fixes)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~900 words. For each finding include a RED Swift Testing case using the fixtures in the named test files. This is the LAST round tonight: say "merge" when the core path holds and what is left is P3.

**One sentence (Rick, 2026-10-15):** tell me whether two media files are the same event exactly, how they differ if not, or that they do not represent the same event in any way — then say what to do about it.

**Round 1** (`docs/reviews/codex/codex-review-2026-10-15-event-analyzer-compare-media.md`, closed by `c6625b218`) found six: R2 targeting an archived clip; the era rule defeated by an unreliable newer date and year-only dates lost; empty digests as identity; a contradiction hidden by an early rung; the band's "byte for byte" overclaim; O(seconds) strip drawing. All six were fixed with the red cases adopted. Attack the fixes and what they may have displaced.

**Range:** main `5187f2be9..c6625b218`. Read files with `git show c6625b218:<path>`.
- `VideoScan/VideoScanCore/Sources/VideoScanCore/RelatedScore.swift` — `Side.digest` (`didSet` normalization), `Side.year` (stored; `init` sets `year ?? day?.year`), `identicalCopy` (non-empty digest; the appended sound contradiction).
- `VideoScan/VideoScanCore/Sources/VideoScanCore/EventRecommendation.swift` — the `.clipFromSameEvent` guard (archive-file / archived clip → R7), `isOlderGeneration` (reliable years first).
- `VideoScan/VideoScan/Events/VideoScanModel+RelatedEvidence.swift` — `relatedSide` passes `year: date.year`.
- `VideoScan/VideoScan/MediaOps/CompareMediaView.swift` — `SoundStripBins`, `SoundStrip.init`, `CompareMediaWords.duration`.
- Tests: `RelatedLadderTests.swift` (17), `EventRecommendationTests.swift` (12), `CompareMediaTests.swift` (10).

**Invariants to attack (prove with file:line or say it holds):**
1. `Side.year`: a value type copied and then given a new `day` keeps a STALE `year` (the stored year is set only in `init`) — can the era rule or anything else read a year that disagrees with the day? Where in the app is a `Side` mutated after construction?
2. `isOlderGeneration`: one reliable 1988 side and one reliable 2015 side (a true conflict) — what should the era rule say, and what does it say? Both sides unreliable, one 1988 one 2006 — is "any year counts" the conservative reading (it yields keep-both) or does it block a legitimate R3 forever?
3. The `.clipFromSameEvent` guard returns R7 "Both are in the archive" when the clip is archived but the MASTER is not — is that sentence true? What should a clip that is archived while its longer master is not get (R6 promote the master?).
4. `identicalCopy`'s appended contradiction fires for `.overlap` of ANY length — an overlap of 2,000 s of a 2,280 s identical file is not "nothing in common"; is the wording wrong, and is `.overlap` with large coverage even reachable for identical bytes?
5. `Side.digest` `didSet` does not run inside `init` (Swift) — the init normalizes separately; is there a third path (Codable? memberwise?) that leaves "" in place? `RelatedEvidence` is not Codable today; say whether that holds.
6. `SoundStripBins`: `anyAudible` with `s1 > active.count` and `s0 < active.count` (the map shorter than the duration) — correct partial answers? `seconds` when `durationSeconds` is NaN or negative?
7. `CompareMediaWords.duration(.sameEvent)` for an identical copy with `sizeBytes == 0` (both unhashed-size rows) — "byte for byte" must not appear; the engine's rung 6 requires size > 0, but the words are computed from the band alone.

**Do only this:** findings against 1–7 (P1 first), each with file:line, a one-line failure scenario and the red test; then at most two P2/P3 one-liners. Everything else in these files was reviewed in round 1.

**Do not explore outside the files listed above and their tests.**

## Closure

Branch `feature/compare-media` (worktree), closed the same night; Core 33 tests, CompareMediaTests 11 — green (Debug). The LAST round tonight, as the brief said.

| Finding | Closure | Pinning test |
|---|---|---|
| F1 P2 mixed eras bypass the protection | fixed: `isOlderGeneration` — ANY pre-2000 reading (reliable first) protects: reliable 1988 vs 2015 is a date conflict to resolve, unreliable 1988 vs 2006 keeps both until a date is corrected | `EventRecommendationTests.mixedErasDoNotRecommendRemoval` (codex's case, both reliabilities) |
| F2 P2 an archived clip hides its unarchived master | fixed: `clipRule` — archived clip + unarchived master → R6 promote the master ("the clip stays"); both archived → R7 | `EventRecommendationTests.archivedClipStillNeedsItsMasterArchived` (codex's case) |
| F3 P3 NaN duration traps the strip | fixed: `SoundStripBins` — a non-finite or negative duration falls back to the map's length | `CompareMediaTests.nonfiniteDurationUsesMapLength` (NaN, infinity, negative, empty map) |
| F4 P3 a corrected day leaves `year` stale | fixed: `Side.year` is computed from the day with the year-only hint as the fallback; settable for year-only evidence | `EventRecommendationTests.correctedDayUpdatesEraYear` |
| F5 P3 an overlap on identical bytes reads "nothing in common" | fixed: the rung-6 contradiction names the overlap length ("only 2000 s matched … one fingerprint is stale or partial") | `RelatedLadderTests.identicalCopyOverlapWording` |

## Closed

Closed by `5d827f744` at 2026-10-16T01:20:10Z. 5 findings closed (mixed eras, archived clip → promote master, NaN strip, year follows day, overlap wording); last round tonight
