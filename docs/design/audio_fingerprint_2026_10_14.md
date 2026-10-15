# Audio fingerprint engine — design (2026-10-14)

Branch `feature/audio-fingerprint`. Rick's one sentence: "demonstrate that we can detect two files are the
same event, or part of the same event, using an audio fingerprint — TDD: create similar, same, different
files and show right out of the gate how well it works."

## Why this shape

The downstream question is containment: "is this 90-second clip cut from that 16-minute master?" so Cleanup
can one day offer "clips of a master" with proof. That is copy detection with time alignment, not semantic
similarity. Rick's clips descend from the same tape/DVD through re-encodes, rewraps, trims and exports, so a
Shazam-style landmark (constellation) fingerprint on the audio is the robust, cheap, local tool. The 10/11
investigation (docs/reviews/night/manually_deleted_959_classification_2026_10_11.md, Method 3) saw audio
survive a container change where video stream hashes did not. `contentHash`/SHA-256 answer "same bytes";
transcripts answer "what is said"; neither answers "same recording, at what offset".

## Where

Swift package `VideoScan/VideoScanCore`, three new source files plus one CLI target. Pure Swift,
`import Accelerate` (vDSP FFT) is allowed here. No app-target change in this step.

| File | Owns |
|---|---|
| `Sources/VideoScanCore/AudioPCMDecoder.swift` | ffmpeg → 8 kHz mono s16le over a pipe; named failures |
| `Sources/VideoScanCore/AudioFingerprint.swift` | STFT, peaks, landmarks, value type + binary encoding |
| `Sources/VideoScanCore/AudioFingerprintMatcher.swift` | inverted index, offset histogram, verdict, policy |
| `Sources/videoscan-audio-match/main.swift` | demo CLI: `fingerprint <file>`, `match <query> <master>` |

## 1. Decode — `AudioPCMDecoder`

`ffmpeg -nostdin -v error [-ss S] [-t T] -i <file> -vn -ac 1 -ar 8000 -f s16le -`, read from stdout through
`ProcessRunner.runProcess(stdoutData:…, stdoutLimitBytes: 0)` — the house runner's raw-bytes callback, so the
pipe is drained continuously, the deadline escalates SIGTERM → SIGKILL → abandon, and no new `Process()` site
appears. No temp file, no output path other than `-`. The result is `AudioPCM { sampleRate, samples: [Int16] }`.

- Hard cap: `-t` is always passed (default 4 h = 14 400 s) AND the sink drops samples past the cap. Worst case
  in RAM: 4 h × 8 000 × 2 B = 230 MB of Int16; a 16-minute file is 15 MB. Bytes are converted to Int16 chunk
  by chunk (one `[Int16]`, capacity reserved for the cap — virtual until written), so the peak is the PCM plus
  one chunk, measured 52 MB for an hour (codex F5). A decode that fills the cap (or a window) says so:
  `AudioPCM.reachedCap` (codex F2) — the fingerprint made from it is `complete == false`.
- Named outcomes (`AudioPCMDecoder.Failure`): `.ffmpegMissing(path)`, `.noAudioStream` (ffmpeg's "does not
  contain any stream", or exit 0 with zero bytes), `.decodeFailed(exitCode, stderrTail)` (0-byte or damaged
  input), `.timedOut`. A video-only file is a named outcome, never a crash.
- Deadline default 300 s per decode; callers may raise it.

## 2. Fingerprint — `AudioFingerprint`

STFT: Hann, N = 1024, hop 512 at 8 kHz → 64 ms frames, 15.6 Hz bins, 512 usable bins (bin 0 ignored).
Log-power spectrogram in dB. A bin is a **peak** when it is the strict maximum of its time × frequency
neighbourhood (±3 frames × ±15 bins, computed with doubling vDSP max-filters, so the Swift loop only tests
equality), is above an absolute floor, and is above the frame's mean dB by a margin; at most K peaks per
frame (strongest first). Silence yields no peaks (strict maximum over a flat field fails).

Landmarks: each peak is an **anchor**; its targets are the next `fanOut` peaks in time order with
`1 ≤ dt ≤ 63` frames and `|Δf| ≤ maxDeltaBins`. One `UInt32` hash packs `(f1: 9 bits, f2: 9 bits, dt: 6 bits)`;
the anchor frame is the `UInt32` time. All knobs live in `AudioFingerprintParameters` (one struct, defaults).

Value type, `Sendable`, deterministic for equal input bytes:
`AudioFingerprint { version, recipeID, sampleRate, hopSamples, frameSize, durationSeconds (= analyzedSeconds),
complete, activeSeconds: [Bool], hashes: [UInt32], times: [UInt32] }`, with `encoded() -> Data` and
`init?(decoding:)` / `decode(_:) throws DecodingError`, and `estimatedBytes` (exactly `encoded().count`).

**VSAF version 2** (codex r1, 2026-10-14; nothing was persisted at v1), little-endian, header 39 B:
`magic "VSAF" | version u16 | recipeID u32 | flags u8 (bit 0 = complete) | sampleRate u32 | hop u32 |
frameSize u32 | analyzedSeconds f64 | landmarkCount u32 | activeSecondCount u32`, then `hashes` (u32 × n),
`times` (u32 × n), then the audible-seconds bitmap (one bit per second, LSB first, byte-padded).
`decode` refuses, by name, a bad magic, another version, a size that disagrees with the counts, and any header
the matcher could trap on (hop 0, sample rate 0, frame size not a power of two or above 1024, hop > frame).

- `recipeID` = FNV-1a over `AudioFingerprintParameters.algorithmRevision` and every knob (codex F3). The
  default recipe is pinned at `0x40000ADE` by a test; the matcher refuses to compare two recipes
  (`.inconclusive(.incompatibleRecipe)`). `AudioFingerprintParameters.validate()` throws the first violated
  invariant (dt 1…63, frame size power of two ≤ 1024, 1 ≤ hop ≤ frame, …); `compute` preconditions on it.
- `activeSeconds` (codex F1): second *i* is **audible** when its RMS after normalisation is above
  `activeFloorDB` (−60 dBFS). The matcher's coverage and gap are measured over audible seconds only; silence
  is evidence for nothing.

The spectrogram is never held whole: the picker allocates its rings (2×3+1 level and dilated frames), FFT
buffers and candidate list once per `compute` and writes every frame in place (codex F5: no per-frame arrays).
Memory is O(seconds), not O(file); fingerprinting an hour grows the process by ≈ 0 MB measured. The PCM
itself is the only O(file) buffer.

## 3. Match — `AudioFingerprintMatcher`

`AudioFingerprintIndex(master:)` builds `[UInt32: [UInt32]]` (hash → anchor frames; ≈ 7 MB measured for an
hour). `match(query:)` votes `tMaster − tQuery` into an offset histogram (an array over the possible frame
deltas, negative deltas allowed); the best bin with ±1-frame tolerance wins. (For Rick: a Hough transform on
one parameter, the time offset.) A hash the master holds more than `policy.maxPostingsPerHash` (64) times is
skipped in both passes — it says nothing about *where* the query is — and the second pass stops at the first
hit, so work per query landmark is bounded (codex F4: 100k × 100k same-hash landmarks match in 0.35 s).
From the winning offset: `matchedLandmarks` (distinct query landmarks in the winning bins), `offsetSeconds`
(centroid of the three bins × hop), `coverage` (matched ÷ **audible** 1-s buckets of the query inside the
master at that offset), `unmatchedGapSeconds` (longest stretch of audible, unmatched query seconds in the
overlap), `density` (matched ÷ query landmarks), `span` (the longest run of matched seconds, ≤ 2 audible gaps
bridged, silence transparent).

`AudioMatchVerdict` is a pure, total function of that evidence and `AudioMatchPolicy` (one struct of named
thresholds; the decision table is in its header comment). Rows, first match wins:
1. too few landmarks → `.different`; 2. span < `minOverlapSeconds` (5 s) → `.different` on every branch;
3. coverage < 0.5 **or** gap > `maxUnmatchedGapSeconds` (10 s) → `.overlap(offset, span)` (real but not
distributed: codex F1); 4. geometry × completeness: both inside and both complete → `.sameRecording`; query
inside → `.containedInMaster(offset)`; master inside → `.masterContainedInQuery(offset)`; neither →
`.overlap`. An **incomplete** side (capped or windowed decode, codex F2) can be contained but never "same"
or containing: those rows become `.inconclusive(.queryIncomplete | .masterIncomplete | .bothIncomplete)`,
evidence still reported. `.inconclusive(.incompatibleRecipe)` when the recipes differ.

## 4. Out of scope (deliberately)

No persistence, no catalog field, no MFO job, no Cleanup lane. A stored fingerprint is roughly 8 bytes per
landmark; at the chosen density that is hundreds of KB for a 16-minute file, so it cannot live in
`catalog.json` (already 74 MB) — it needs a sidecar store (one file per record, or a small SQLite table keyed
by content identity). That is an architectural decision for Rick, after the numbers below are in.

## Tests (frozen before results)

`Tests/VideoScanCoreTests/AudioFingerprintAcceptanceTests.swift` (+ `AudioFingerprintFixtures.swift`,
`AudioFingerprintEngineTests.swift`; the codex r1 pins live in the engine tests — see
`docs/reviews/codex/codex-review-2026-10-14-audio-fingerprint-engine.md` § Closure). Synthetic "speech-like" audio from a seeded PRNG, written as 8 kHz WAV,
variants made with ffmpeg at test time in a `test_`-prefixed temp dir. Masters A, B, C (180 s), D = [B 0–30 |
A | C 0–30] (240 s), E = A with its last 120 s replaced by C. Positive pairs must give the expected verdict with
|offset error| ≤ 0.1 s; negatives must be `.different`; min positive matchedLandmarks ÷ max negative
matchedLandmarks ≥ 3. The 0.5 % speed-change case is marked expected-but-allowed-to-fail and reported.
Media matrix (exact copy as mov/pcm, mkv/flac, mxf/pcm, avi/pcm), scale (60-min synthetic master with a
measured budget), isolation (bogus ffmpeg path, 0-byte file, video-only file), sensor (engine sources never
open an input for write). Bars are not loosened to go green; misses are reported with the numbers.

## Results (2026-10-14, M4 Max, Debug)

Synthetic matrix: 16 tests / 35 cases green; every positive at the expected verdict with |offset error|
≤ 0.014 s; 15/15 negatives `.different` (max 5 matched landmarks); margin 7.6× (weakest positive = the 5-s
PCM clip, 38 of 129); 0.5 % speed change → `.overlap(0.07 s, 31 s)` (expected-but-allowed fail, reported).
Two things had to be added beyond the brief to get there: RMS normalisation before analysis (a −6 dB copy
lost 60 % of its landmarks on an absolute floor) and a `dt ± 1` probe in the matcher (clips cut off the
master's 512-sample frame grid matched at density 0.09; with the probe 0.28–0.37). Scale: a 60-minute
master fingerprints in 2.5 s, indexes in 0.03 s, 99 734 landmarks = 798 KB (13.3 KB/min); budget 6 s.
Real files (read-only): a 16-min 2006 DVD-sourced master vs its derived clips — the DVD VOB itself is
`SAME RECORDING` (density 0.987, offset 0.000); three edited exports are `CLIP OF MASTER` at 6.9 / 376.1 /
490.2 s (density 0.18–0.49); two re-cut clips are `OVERLAP` 12–23 s (coverage 0.30–0.45, under the 0.5
bar — they appear to be re-edits, not straight cuts); a video-only MPEG-2 export is the named
`noAudioStream`; two unrelated 1980s tapes are `DIFFERENT` (4 and 6 matched of 6 327 / 14 784). The
master is 19.7 landmarks/s = 151 KB; decode is the cost (0.7 s cached, 6–27 s cold from disk), the
fingerprint 0.7 s, index + match < 40 ms.
