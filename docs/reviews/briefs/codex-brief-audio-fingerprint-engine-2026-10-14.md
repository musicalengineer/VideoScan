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
