# Codex review — Audio fingerprint engine

- Range: `1d41cdf0..cc6bc7cc1`
- Credits spent: unavailable (usage meter not exposed)
- Tokens: 70112
- Finding count: 5
- Verdict: fix** before persistence or Cleanup consumes these verdicts. The supplied results demonstrate useful matching; they do not establish safe containment classification.
- Run: 2026-10-14T23:58:48Z (cycle #72, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (usage meter not exposed) | Finding count: 5

Verdict: **fix** before persistence or Cleanup consumes these verdicts. The supplied results demonstrate useful matching; they do not establish safe containment classification.

Reviewed `cc6bc7cc1`, restricted to the named files. No files written or Swift tests rerun. Reproductions below are source-derived; small in-memory checks confirmed the verdict arithmetic and neighbourhood indexing.

1. **P1 — Partial matches become whole-recording claims.** [AudioFingerprintMatcher.swift:98](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/AudioFingerprintMatcher.swift:98)  
   `overlapSeconds` measures geometric timeline intersection, not demonstrated matching content. With equal 180-second durations, offset zero, 500 matched landmarks, coverage `120/180`, and span 120 seconds, the verdict is **`sameRecording`**, although the remaining minute can be unrelated. Likewise, a four-second query with 20 matches covering only two seconds becomes **`containedInMaster`** against a four-hour master. The high-coverage branch bypasses `minOverlapSeconds`.

   Require distributed evidence for containment, including treatment of substantial unmatched regions. Distinguish silence from contradictory audio: currently an exact 120-second copy containing 90 seconds of silence can instead receive only `overlap`, because silent seconds remain in the coverage denominator. The existing divergence fixture tests one-third coverage; add the above-threshold counterpart.

2. **P1 — Capped decoding silently represents a prefix as the complete recording.** [AudioPCMDecoder.swift:104](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/AudioPCMDecoder.swift:104), [AudioFingerprint.swift:161](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/AudioFingerprint.swift:161)  
   `-t` limits decoding to four hours; the returned PCM and fingerprint contain neither original duration nor a completeness indicator. Two five-hour recordings sharing their first four hours but differing afterward therefore produce identical fingerprints and can receive `sameRecording`. A clip from hour five is unsearchable. Persisting this under the complete file’s content hash conceals the incomplete analysis. Preserve analyzed range and completeness, and prohibit whole-recording conclusions from capped input; alternatively return a named limit outcome.

- **P2 — Fingerprint invariants and recipe compatibility are unenforced.** [AudioFingerprint.swift:107](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/AudioFingerprint.swift:107), [:132](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/AudioFingerprint.swift:132), [Matcher:149](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/AudioFingerprintMatcher.swift:149): `dt=65` aliases `1`; frame size 2048 permits frequency aliases; a correctly sized VSAF with hop zero decodes successfully then traps during matching. Validate parameters/serialized values and reject incompatible recipes; every parameter combination currently receives version 1.
- **P2 — Repeated hashes permit quadratic matching work.** [AudioFingerprintMatcher.swift:157](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/AudioFingerprintMatcher.swift:157), [:184](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/AudioFingerprintMatcher.swift:184): 100k same-hash landmarks on each side cause **20 billion posting visits** across two passes; the second never stops after finding a hit. Bound/downweight common hashes and add repetitive-audio negatives against hours-long masters.
- **P2 — Allocation and memory claims understate actual costs.** [AudioFingerprint.swift:310](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/AudioFingerprint.swift:310), [:333](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/AudioFingerprint.swift:333), [:338](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/AudioFingerprint.swift:338): two fresh arrays plus neighbourhood copy-on-write imply roughly 169k frame-buffer materializations/hour, before candidates. [Decoder:167](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/AudioPCMDecoder.swift:167) simultaneously holds Data and PCM: approximately **461 MB** at four hours, excluding overhead. Reuse ring storage and budget concurrent decoding accordingly.

**Which attack areas hold:**

1. **Landmark math: holds for validated defaults, not the unrestricted API.** Packing fields are disjoint; default `dt` and frequency limits fit. Four hours produces 224,999 frames, safely below UInt32. Ring wrapping and frequency dilation preserve the intended neighbourhood. The picker deliberately omits the first/last three frames; clips shorter than 0.512 seconds produce no peaks. RMS arithmetic safely handles silence and full-scale Int16 samples; normalization cannot undo clipping. Same-input repeatability is tested, but bit-identical results across every Mac are not established.

2. **Matcher: partially holds.** Coverage uses the query timeline; final matched counts count each query landmark once. Verdict branches are exhaustive and mutually selected by control flow. Their semantics fail as above. The supplied negatives do **not** quantify false-positive probability for short queries across hours-long masters or 10,000 comparisons.

3. **Performance: demonstrated ordinary-case speed holds; allocation-light and worst-case claims do not.** A reusable dictionary index is reasonable for one 100k-landmark master. Sorted flat postings would reduce per-key allocations, but would not eliminate repeated-hash cross-products. Keep only a bounded number of indexes resident. Streaming STFT would also require revisiting the current whole-file RMS prepass.

4. **API: batch reuse holds; persistence contract needs work.** Decode once, compute once, construct one index, match many. Binary encoding suffices without `Codable`; valid values round-trip and unknown versions are rejected. Recipe changes are not automatically versioned, nor are sample rate/hop/frame size checked before matching. Version the fingerprint recipe separately from policy revisions used to interpret evidence.

5. **Swift quality: mostly holds.** Value types, `Sendable`, named decoder failures, and ProcessRunner usage are appropriate; no new concurrency defect or force unwrap found. The reported temporary-pointer construction is **absent** here: FFT buffers are explicitly allocated. For array-backed buffers, nest `real.withUnsafeMutableBufferPointer` and `imag.withUnsafeMutableBufferPointer`, unwrap their base addresses, and construct/use `DSPSplitComplex` entirely inside both closures. No explicit `nonisolated` is needed under this package’s current isolation configuration.

CLI, executable shim, Package.swift, all three test files, and design document: **read, no additional findings**.

## Brief

# Codex brief: audio fingerprint engine (VideoScanCore) — design, Swift quality, performance

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~1,000 words.

**One sentence (Rick, 2026-10-14):** detect that two files are the same recording, or that one is cut from the other, by an audio landmark fingerprint — and show how well it works before anything depends on it.

**What it is for:** the next step is an overnight MFO backfill ("Fingerprint Sound…", like Fill In Full Hashes) over ~10,000 files / 7.5 TB, storing fingerprints in a SQLite sidecar keyed by content hash, then a "clips of a master" lane in Triage ▸ Cleanup scoped by Events groups. So the engine must be correct, fast, allocation-light, and its API must suit batch use (one master decoded once, many queries) and a stable on-disk encoding. Rick's bar: best-in-class Swift, sound design patterns, performant.

**Range:** main, `1d41cdf0..cc6bc7cc1` (merged as `2802f2197`). Read with `git show cc6bc7cc1:<path>`. Paths under `VideoScan/VideoScanCore/`.
- `Sources/VideoScanCore/AudioPCMDecoder.swift` — ffmpeg → 8 kHz mono s16le over `ProcessRunner`'s raw stdout pipe; `-t` cap 4 h + sink cap; outcomes ffmpegMissing / noAudioStream / decodeFailed / timedOut.
- `Sources/VideoScanCore/AudioFingerprint.swift` — vDSP STFT (Hann 1024 / hop 512 @ 8 kHz), RMS normalisation, ring-buffered time×frequency neighbourhood max (van Herk), ≤ 5 peaks/frame, landmark `(f1:9, f2:9, dt:6)` packed in `UInt32` + anchor frame; `VSAF` little-endian encoding; `AudioFingerprintParameters`.
- `Sources/VideoScanCore/AudioFingerprintMatcher.swift` — `AudioFingerprintIndex` (hash → frames), offset histogram (±1 frame, dt ±1 probe), coverage / density / span, `AudioMatchEvidence.verdict(policy:)` over `AudioMatchPolicy`.
- `Sources/VideoScanCore/AudioFingerprintCLI.swift`, `Sources/videoscan-audio-match/main.swift`, `Package.swift`.
- Tests: `Tests/VideoScanCoreTests/AudioFingerprintFixtures.swift`, `AudioFingerprintAcceptanceTests.swift`, `AudioFingerprintEngineTests.swift`. Design: `docs/design/audio_fingerprint_2026_10_14.md`.

**Measured (do not re-derive):** synthetic suite 15/15 positives, 15/15 negatives, margin 7.6×, worst offset error 0.014 s; 60-min master fingerprints in 2.5 s Debug on an M4 Max (13 KB/min); real demo: 5 of 7 audio-bearing clips of a 16-min master placed to the second, two other-event files ≥ 18× below the weakest positive. Known and out of scope: 0.5 % speed drift fails (piecewise voting later); multi-offset "re-edit" verdict; CLI decodes the master per invocation; CLI has no tests.

**Attack, in this order:**
1. **Correctness of the landmark math:** hash packing collisions or sign/overflow (frames > 2^32? dt bounds, |Δf| limits), peak picking bias at frame edges and at the ring-buffer seams, RMS normalisation on silence / clipped input, determinism across runs, `VSAF` encode/decode round trip and version handling.
2. **Matcher soundness:** offset histogram with ±1 frame and dt ±1 probe — can a short query vote itself into `containedInMaster` on a long master by chance (false-positive rate as the master grows to hours)? Is `coverage` computed on the query's time axis and robust to a silent stretch? Does `verdict` have a hole between `sameRecording`, `containedInMaster`, `overlap`, `different` (every evidence tuple maps to exactly one)?
3. **Performance and memory:** allocations in the per-frame hot loop, `DSPSplitComplex` set-up (the compiler warns at `AudioFingerprint.swift` ~245/251: temporary pointers from `&realp` — say what the right `withUnsafeMutableBufferPointer` shape is), vDSP vs scalar fallbacks, the index as `[UInt32: [UInt32]]` versus sorted flat arrays for a 100k-landmark master and ~10k masters, PCM held in RAM (57 MB per hour) versus streaming STFT.
4. **API shape for what comes next:** one decode → one fingerprint → many matches; a stable `Codable`/binary encoding for a sidecar store keyed by content hash; `Sendable` and `nonisolated` correctness under StrictConcurrency; parameter versioning (`currentVersion` bump when `AudioFingerprintParameters` / `AudioMatchPolicy` change — is it enforced?).
5. **Swift quality:** value types, naming, no force unwraps, errors as named outcomes, no `Process()` outside `ProcessRunner`, header comments honest with the code.

**Do only this:** findings against 1–5 (P1 first), each with file:line and a concrete scenario or a measured claim; then at most three P2/P3 one-liners. Say explicitly which of 1–5 hold.

**Do not explore outside the files listed above.**

## Closure

Branch `fix/audio-fingerprint-codex-r1` off `8789eb987` (bug-fix agent, 2026-10-14). Every finding: red test
shown failing on the pre-fix code, then green. Frozen acceptance bars untouched and re-measured at the tip:
16/16 positives at the expected verdict (|offset error| ≤ 0.014 s), 15/15 negatives `.different`, media matrix
4/4, margin **7.6×** (weakest positive A_sub5_at100 = 38, strongest negative A_reversed = 5) — identical to
before the fixes. Full `--filter AudioFingerprint` run: 30 tests / 2 suites green, 1 known issue (the
pre-existing allowed-to-fail 0.5 % speed case). Debug, M4 Max.

| # | Finding | Commit | Pinning tests | Red → green |
|---|---|---|---|---|
| F1 (P1) | Partial match → whole-recording claim | `e69acae7f` | `partialMatchIsNeverAWholeRecordingClaim`, `tinyQueryWithTwoMatchedSecondsIsNotContained`, `digitalSilenceIsExcludedFromCoverage`, `verdictRequiresDistributedEvidence`, `audibleSecondsRoundTripInVSAF` | A120+C60 vs A: `sameRecording` (coverage 0.66) → `overlap(0, 120 s)`; 4-s/2-matched vs 4 h: `containedInMaster` → `different`; 30 s A + 90 s silence vs itself: `overlap` (coverage 0.25) → `sameRecording` (coverage 1.00) |
| F2 (P1) | Capped decode presented as complete | `d7d7d1c9c` | `cappedDecodeNeverYieldsAWholeRecordingClaim`, `verdictRefusesWholeRecordingClaimsOnIncompleteSides` | two 10-s-capped decodes of A / A_copy: `sameRecording` → `inconclusive(.bothIncomplete)`; capped A vs real 10-s file: `sameRecording` → `masterContainedInQuery(0)` |
| F3 (P2) | Invariants / recipe unenforced | `59e885ca6` | `vsafWithHopZeroIsRefused`, `parametersOutsideTheHashFieldsAreRejected`, `defaultRecipeIDIsPinned`, `indexRefusesAFingerprintFromAnotherRecipe` | hop-0 VSAF decoded → `DecodingError.invalidHeader(.hopOutOfRange(0, 1024))`; `dt = 65` → `ValidationError.deltaFramesOutOfRange`; foreign recipe → `inconclusive(.incompatibleRecipe)` |
| F4 (P2) | Quadratic matching on repeated hashes | `81fcbe840` | `repeatedHashMatchesInBoundedTime`, `metronomeAgainstMetronomeIsBoundedAndNotAClaim`, metronome negative inside the scale test | 100k × 100k same hash: 1-min time limit exceeded, still running at 10 min (killed) → 0.35 s, `.different`; metronome 30 s vs 10 min: 4 ms; metronome 60 s vs 60-min speech: 49 ms, `.different` |
| F5 (P2) | Allocation and memory claims | `2b83d8b87` | `sinkReassemblesSamplesAcrossChunkBoundaries`; decode-peak bound + resident-size prints in `sixtyMinuteMasterFingerprintsAndIndexesWithinBudget` | decode of a 60-min WAV: peak resident growth **112.3 MB → 52.2 MB** for 54.9 MB of PCM (bound PCM + 32 MB); decode 0.35 → 0.32 s; fingerprint 2.58 → 2.48 s with RSS growth +1.5 → 0 MB; index +7.1 → +2.3 MB; fingerprint + index + match 2.64 → 2.53 s (budget 6 s) |
| §5 | `DSPSplitComplex` over `&array` temporaries | — | — | Confirmed absent: both views are built over explicitly allocated FFT buffers; nothing to change. The `&scratch` uses in `normalisingGain` / `activeSeconds` are call-scoped inout conversions, not stored pointers. |

### What changed for consumers (the backfill job)

- **VSAF format version 2** (`AudioFingerprint.currentVersion = 2`; nothing was persisted at v1). Header 39 B:
  `magic | version u16 | recipeID u32 | flags u8 (bit 0 = complete) | sampleRate | hop | frameSize | analyzedSeconds f64 | landmarkCount | activeSecondCount`, then hashes, times, audible bitmap.
  `estimatedBytes` is still exactly `encoded().count`. `init?(decoding:)` keeps its nil contract; `AudioFingerprint.decode(_:) throws DecodingError` says why.
- **Additive fields:** `AudioPCM.reachedCap` / `analyzedSeconds`; `AudioFingerprint.recipeID`, `.complete`, `.activeSeconds` (+ `activeSecondCount`, `analyzedSeconds`); `AudioMatchEvidence.queryComplete`, `.masterComplete`, `.unmatchedGapSeconds`; `AudioMatchPolicy.maxUnmatchedGapSeconds` (10 s), `.maxPostingsPerHash` (64); `AudioFingerprintParameters.activeFloorDB` (−60 dBFS), `.validate()`, `.isValid`, `.recipeID`. Every added `init` parameter has a default.
- **One new verdict case:** `AudioMatchVerdict.inconclusive(reason: AudioMatchInconclusiveReason)` with `.incompatibleRecipe(query:master:)`, `.queryIncomplete`, `.masterIncomplete`, `.bothIncomplete`. An exhaustive `switch` over the verdict needs the new case (the CLI's `describe` has it).
- **Recipe identity:** the default `recipeID` is pinned at `0x40000ADE`. Any knob change (or `algorithmRevision`) changes it and the matcher refuses to compare across recipes — store it with the blob.
- **`overlap(seconds:)`** now always reports the demonstrated matched run (`spanSeconds`), on every branch.
- `AudioFingerprint.compute` preconditions on valid parameters and on `pcm.sampleRate == parameters.sampleRate` (programmer errors; call `validate()` once at start-up to get the reason as a thrown value).

### Known limits left on the table (not loosened, not hidden)

- A clip taken from past the 4-h cap of a master is unsearchable (codex noted; by design of the cap).
- Self-similar audio (a metronome, a hum) is not placeable: with the postings cap it is `.different`, never a claim.
- A genuine copy with a > 10 s stretch of audible audio that yields no matching landmarks (heavily damaged passage) will read `.overlap`, not `.sameRecording` — the conservative side.

## Closed

Closed by `13874ab5` at 2026-10-15T00:45:48Z. All five findings closed on fix/audio-fingerprint-codex-r1 and merged to main 13874ab5 (see Closure above). Frozen bars unchanged, margin 7.6×.
