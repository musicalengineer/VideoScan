
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
