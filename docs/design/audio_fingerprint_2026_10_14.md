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

- Hard cap: `-t` is always passed (default 4 h = 14 400 s) AND the sink drops bytes past the cap. Worst case
  in RAM: 4 h × 8 000 × 2 B = 230 MB of Int16; a 16-minute file is 15 MB.
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
`AudioFingerprint { version, sampleRate, hopSamples, frameSize, durationSeconds, hashes: [UInt32], times: [UInt32] }`,
with `encoded() -> Data` (magic `VSAF`, little-endian, versioned) and `init(decoding:)`, and `estimatedBytes`.
The spectrogram is never held whole: a ring of 2×3+1 frames feeds peak picking and a sliding peak window feeds
pairing, so memory is O(seconds), not O(file). The PCM itself is the only O(file) buffer.

## 3. Match — `AudioFingerprintMatcher`

`AudioFingerprintIndex(master:)` builds `[UInt32: [UInt32]]` (hash → anchor frames). `match(query:)` votes
`tMaster − tQuery` into an offset histogram (an array over the possible frame deltas, negative deltas allowed);
the best bin with ±1-frame tolerance wins. (For Rick: a Hough transform on one parameter, the time offset.)
From the winning offset: `matchedLandmarks` (distinct query landmarks in the winning bins), `offsetSeconds`
(centroid of the three bins × hop), `coverage` (fraction of the query's 1-s buckets, within the part of the
query that lies inside the master at that offset, that had a match), `density` (matched ÷ query landmarks),
`span` (the longest run of matched seconds, gaps ≤ 2 s bridged).

`AudioMatchVerdict` is a pure function of those numbers and `AudioMatchPolicy` (one struct of named thresholds):
`.sameRecording` (coverage ≥ bar and both files lie inside the overlap within the edge tolerance),
`.containedInMaster(offset)` (query lies inside the master), `.masterContainedInQuery(offset)` (roles reversed;
offset = where the master starts in the query), `.overlap(offset, seconds)` (coverage below the bar or a
partial overlap, but a matched run ≥ the minimum), `.different` (too few landmarks or no run).

## 4. Out of scope (deliberately)

No persistence, no catalog field, no MFO job, no Cleanup lane. A stored fingerprint is roughly 8 bytes per
landmark; at the chosen density that is hundreds of KB for a 16-minute file, so it cannot live in
`catalog.json` (already 74 MB) — it needs a sidecar store (one file per record, or a small SQLite table keyed
by content identity). That is an architectural decision for Rick, after the numbers below are in.

## Tests (frozen before results)

`Tests/VideoScanCoreTests/AudioFingerprintAcceptanceTests.swift` (+ `AudioFingerprintFixtures.swift`,
`AudioFingerprintEngineTests.swift`). Synthetic "speech-like" audio from a seeded PRNG, written as 8 kHz WAV,
variants made with ffmpeg at test time in a `test_`-prefixed temp dir. Masters A, B, C (180 s), D = [B 0–30 |
A | C 0–30] (240 s), E = A with its last 120 s replaced by C. Positive pairs must give the expected verdict with
|offset error| ≤ 0.1 s; negatives must be `.different`; min positive matchedLandmarks ÷ max negative
matchedLandmarks ≥ 3. The 0.5 % speed-change case is marked expected-but-allowed-to-fail and reported.
Media matrix (exact copy as mov/pcm, mkv/flac, mxf/pcm, avi/pcm), scale (60-min synthetic master with a
measured budget), isolation (bogus ffmpeg path, 0-byte file, video-only file), sensor (engine sources never
open an input for write). Bars are not loosened to go green; misses are reported with the numbers.
