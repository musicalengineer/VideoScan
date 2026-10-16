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
