// AudioFingerprintEngineTests.swift — the other four test dimensions for the
// audio-fingerprint engine (frozen 2026-10-14 with the acceptance matrix):
//
//   Isolation — a bogus ffmpeg path, a 0-byte file and a video-only file are
//               named outcomes, never crashes; the decoder's bytes are the
//               WAV's bytes (the pipe loses nothing); a window is exact.
//   Logic     — hash packing, the pure verdict function.
//   Sensor    — the engine never opens an input for write.
//   Scale     — a 60-minute master fingerprinted and indexed under a budget.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("AudioFingerprint engine")
struct AudioFingerprintEngineTests {

    // MARK: Decoder — pure argument shape

    @Test func decoderArgumentsAreReadOnlyPipeToStdout() throws {
        let whole = AudioPCMDecoder.arguments(path: "/x/y.mov", window: .whole, sampleRate: 8_000,
                                              maxSeconds: 14_400)
        #expect(whole.last == "-", "output must be stdout, never a path")
        #expect(!whole.contains("-y"))
        #expect(whole.contains("-nostdin"))
        for expected in [["-i", "/x/y.mov"], ["-vn"], ["-ac", "1"], ["-ar", "8000"], ["-f", "s16le"],
                         ["-t", "14400"]] {
            #expect(whole.joined(separator: " ").contains(expected.joined(separator: " ")), "\(expected)")
        }
        #expect(!whole.contains("-ss"))

        let window = AudioPCMDecoder.arguments(path: "/x/y.mov",
                                               window: .init(startSeconds: 60, durationSeconds: 20),
                                               sampleRate: 8_000, maxSeconds: 14_400)
        let joined = window.joined(separator: " ")
        #expect(joined.contains("-ss 60"))
        #expect(joined.contains("-t 20"))
        // The window's -ss precedes -i (input seek).
        let seek = try #require(window.firstIndex(of: "-ss"))
        let input = try #require(window.firstIndex(of: "-i"))
        #expect(seek < input)

        let capped = AudioPCMDecoder.arguments(path: "/x/y.mov",
                                               window: .init(startSeconds: nil, durationSeconds: 99_999),
                                               sampleRate: 8_000, maxSeconds: 14_400)
        #expect(capped.joined(separator: " ").contains("-t 14400"), "the cap wins over a larger window")
    }

    // MARK: Decoder — isolation

    @Test func bogusFFmpegPathIsNamed() async {
        let decoder = AudioPCMDecoder(ffmpegPath: "/nonexistent/test_ffmpeg")
        await #expect(throws: AudioPCMDecoder.Failure.ffmpegMissing(path: "/nonexistent/test_ffmpeg")) {
            _ = try await decoder.decode(path: "/nonexistent/test_input.wav")
        }
    }

    @Test(.enabled(if: FFmpegLocator.ffmpegIsAvailable()))
    func zeroByteFileIsDecodeFailed() async throws {
        let fixtures = try await AudioFixtureStore.shared.fixtures()
        do {
            _ = try await AudioPCMDecoder().decode(path: try fixtures.url("empty").path)
            Issue.record("0-byte file decoded?")
        } catch let failure as AudioPCMDecoder.Failure {
            guard case .decodeFailed(let code, let tail) = failure else {
                Issue.record("expected decodeFailed, got \(failure)"); return
            }
            #expect(code != 0)
            #expect(!tail.isEmpty, "stderr tail carries ffmpeg's reason")
        }
    }

    @Test(.enabled(if: FFmpegLocator.ffmpegIsAvailable()))
    func videoOnlyFileIsNoAudioStream() async throws {
        let fixtures = try await AudioFixtureStore.shared.fixtures()
        await #expect(throws: AudioPCMDecoder.Failure.noAudioStream) {
            _ = try await AudioPCMDecoder().decode(path: try fixtures.url("video_only").path)
        }
    }

    @Test(.enabled(if: FFmpegLocator.ffmpegIsAvailable()))
    func decodedBytesAreTheWAVsBytes() async throws {
        let fixtures = try await AudioFixtureStore.shared.fixtures()
        let pcm = try await AudioPCMDecoder().decode(path: try fixtures.url("A").path)
        #expect(pcm.sampleRate == 8_000)
        #expect(pcm.samples == fixtures.a, "the pipe must deliver every sample, in order, unchanged")
        #expect(abs(pcm.durationSeconds - 180) < 0.001)
    }

    @Test(.enabled(if: FFmpegLocator.ffmpegIsAvailable()))
    func decodeWindowIsExact() async throws {
        let fixtures = try await AudioFixtureStore.shared.fixtures()
        let pcm = try await AudioPCMDecoder().decode(path: try fixtures.url("A").path,
                                                     window: .init(startSeconds: 60, durationSeconds: 20))
        #expect(pcm.samples.count == 20 * 8_000)
        #expect(pcm.samples == Array(fixtures.a[(60 * 8_000)..<(80 * 8_000)]))
    }

    // MARK: Decoder + verdict — completeness (codex F2)

    /// A decode that hit the cap is a PREFIX, not the recording. Two 180-s
    /// files decoded with a 10-s cap must not be called the same recording,
    /// and a capped A against a genuine 10-s file is "the 10-s file lies
    /// inside A", never "same".
    @Test(.enabled(if: FFmpegLocator.ffmpegIsAvailable()))
    func cappedDecodeNeverYieldsAWholeRecordingClaim() async throws {
        let fixtures = try await AudioFixtureStore.shared.fixtures()
        let capped = AudioPCMDecoder(maxSeconds: 10)
        let a = try await capped.decode(path: try fixtures.url("A").path)
        let aCopy = try await capped.decode(path: try fixtures.url("A_copy").path)
        #expect(a.samples.count == 10 * 8_000)
        let whole = try await AudioPCMDecoder().decode(path: try fixtures.url("A").path)
        #expect(whole.samples.count == 180 * 8_000)

        #expect(a.reachedCap && aCopy.reachedCap, "a decode that filled the cap says so")
        #expect(!whole.reachedCap, "a decode that ended before the cap is complete")
        #expect(a.analyzedSeconds == 10)

        let fa = AudioFingerprint.compute(a), fCopy = AudioFingerprint.compute(aCopy)
        #expect(!fa.complete && AudioFingerprint.compute(whole).complete)
        #expect(AudioFingerprint(decoding: fa.encoded())?.complete == false, "completeness is in VSAF")
        #expect(AudioFingerprint(decoding: AudioFingerprint.compute(whole).encoded())?.complete == true)
        let both = AudioFingerprintMatcher.match(query: fa, master: fCopy)
        #expect(both.verdict != .sameRecording, "two capped prefixes: \(both.verdict)")
        #expect(both.verdict == .inconclusive(reason: .bothIncomplete))
        #expect(both.evidence.queryComplete == false && both.evidence.masterComplete == false)
        #expect(both.matchedLandmarks > 100 && abs(both.offsetSeconds) < 0.1, "the evidence is still reported")

        let tenSeconds = AudioFingerprint.compute(AudioPCM(sampleRate: 8_000, samples: Array(fixtures.a[0..<(10 * 8_000)])))
        let cappedVsShort = AudioFingerprintMatcher.match(query: fa, master: tenSeconds)
        #expect(cappedVsShort.verdict != .sameRecording, "capped A vs 10-s file: \(cappedVsShort.verdict)")
        #expect(cappedVsShort.verdict == .masterContainedInQuery(offsetSeconds: 0),
                "the complete 10-s file lies inside the capped A — a true, provable claim")
        let shortVsCapped = AudioFingerprintMatcher.match(query: tenSeconds, master: fa)
        #expect(shortVsCapped.verdict == .containedInMaster(offsetSeconds: 0))

        // A window is a part too: not complete, never "same".
        let window = try await AudioPCMDecoder().decode(path: try fixtures.url("A").path,
                                                        window: .init(startSeconds: 60, durationSeconds: 20))
        #expect(window.reachedCap && !AudioFingerprint.compute(window).complete)
    }

    // MARK: Fingerprint — logic

    @Test func hashPackingRoundTrips() {
        for (f1, f2, dt) in [(0, 0, 1), (511, 511, 63), (100, 300, 7), (300, 100, 63)] {
            let h = AudioFingerprint.packHash(f1: f1, f2: f2, dt: dt)
            let u = AudioFingerprint.unpackHash(h)
            #expect(u.f1 == f1 && u.f2 == f2 && u.dt == dt, "\(f1),\(f2),\(dt)")
        }
        #expect(AudioFingerprint.packHash(f1: 1, f2: 2, dt: 3) != AudioFingerprint.packHash(f1: 2, f2: 1, dt: 3))
    }

    @Test func silenceHasNoLandmarks() {
        let pcm = AudioPCM(sampleRate: 8_000, samples: [Int16](repeating: 0, count: 8_000 * 10))
        #expect(AudioFingerprint.compute(pcm).landmarkCount == 0)
    }

    // MARK: Fingerprint — invariants (codex F3)

    /// A VSAF blob whose header says hop 0 (or sample rate 0, or a frame
    /// size that is not a power of two) must be refused at decode time, not
    /// trap later in the matcher's `duration / hopSeconds`.
    @Test func vsafWithHopZeroIsRefused() throws {
        let pcm = AudioPCM(sampleRate: 8_000, samples: tenSecondTone())
        let sound = AudioFingerprint.compute(pcm).encoded()
        #expect(AudioFingerprint(decoding: sound) != nil, "a sound blob decodes")
        func patched(_ offset: Int, _ value: UInt32) -> Data {
            var data = sound
            withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
            return data
        }
        let hopZero = patched(AudioFingerprint.hopFieldOffset, 0)
        #expect(AudioFingerprint(decoding: hopZero) == nil, "hop 0 must not decode")
        #expect(throws: AudioFingerprint.DecodingError.invalidHeader(.hopOutOfRange(hop: 0, frameSize: 1_024))) {
            try AudioFingerprint.decode(hopZero)
        }
        #expect(throws: AudioFingerprint.DecodingError.invalidHeader(.sampleRateNotPositive(0))) {
            try AudioFingerprint.decode(patched(AudioFingerprint.sampleRateFieldOffset, 0))
        }
        #expect(throws: AudioFingerprint.DecodingError.invalidHeader(.frameSizeNotPowerOfTwo(1_000))) {
            try AudioFingerprint.decode(patched(AudioFingerprint.frameSizeFieldOffset, 1_000))
        }
        #expect(throws: AudioFingerprint.DecodingError.invalidHeader(.hopOutOfRange(hop: 512, frameSize: 256))) {
            try AudioFingerprint.decode(patched(AudioFingerprint.frameSizeFieldOffset, 256))
        }
        #expect(throws: AudioFingerprint.DecodingError.badMagic) {
            try AudioFingerprint.decode(Data("VSAX".utf8) + sound.dropFirst(4))
        }
        var versionOne = sound
        versionOne[4] = 1; versionOne[5] = 0
        #expect(throws: AudioFingerprint.DecodingError.unsupportedVersion(1)) {
            try AudioFingerprint.decode(versionOne)
        }
        #expect(throws: AudioFingerprint.DecodingError.sizeMismatch(expected: sound.count, actual: sound.count - 4)) {
            try AudioFingerprint.decode(sound.dropLast(4))
        }
        #expect(throws: AudioFingerprint.DecodingError.tooShort(bytes: 10)) {
            try AudioFingerprint.decode(sound.prefix(10))
        }
    }

    @Test func parametersOutsideTheHashFieldsAreRejected() {
        var p = AudioFingerprintParameters()
        #expect(p.isValid)
        p.maxDeltaFrames = 65
        #expect(throws: AudioFingerprintParameters.ValidationError.deltaFramesOutOfRange(min: 1, max: 65, limit: 63)) {
            try p.validate()
        }
        p = .default; p.frameSize = 2_048; p.hopSamples = 1_024
        #expect(throws: AudioFingerprintParameters.ValidationError.frameSizeExceedsHashField(frameSize: 2_048, limit: 1_024)) {
            try p.validate()
        }
        p = .default; p.hopSamples = 0
        #expect(throws: AudioFingerprintParameters.ValidationError.hopOutOfRange(hop: 0, frameSize: 1_024)) {
            try p.validate()
        }
        p = .default; p.hopSamples = 2_000
        #expect(throws: AudioFingerprintParameters.ValidationError.hopOutOfRange(hop: 2_000, frameSize: 1_024)) {
            try p.validate()
        }
        p = .default; p.frameSize = 1_000; p.hopSamples = 500
        #expect(throws: AudioFingerprintParameters.ValidationError.frameSizeNotPowerOfTwo(1_000)) { try p.validate() }
        p = .default; p.sampleRate = 0
        #expect(throws: AudioFingerprintParameters.ValidationError.sampleRateNotPositive(0)) { try p.validate() }
        p = .default; p.minDeltaFrames = 0
        #expect(!p.isValid)
    }

    /// Sensor: the default recipe's identity. If this changes, a knob (or
    /// `algorithmRevision`) changed and every stored fingerprint is stale —
    /// that must be a decision, not an accident. Value computed
    /// independently (Python FNV-1a over the same words).
    @Test func defaultRecipeIDIsPinned() {
        #expect(AudioFingerprintParameters.default.recipeID == 0x4000_0ADE)
        var p = AudioFingerprintParameters()
        p.maxDeltaBins = 64
        #expect(p.recipeID != AudioFingerprintParameters.default.recipeID)
        let pcm = AudioPCM(sampleRate: 8_000, samples: tenSecondTone())
        let f = AudioFingerprint.compute(pcm)
        #expect(f.recipeID == AudioFingerprintParameters.default.recipeID)
        #expect(f.version == 2)
        #expect(AudioFingerprint(decoding: f.encoded())?.recipeID == f.recipeID)
    }

    /// A fingerprint made by another recipe is refused by the index with a
    /// named reason — its hashes do not mean the same thing.
    @Test func indexRefusesAFingerprintFromAnotherRecipe() {
        let pcm = AudioPCM(sampleRate: 8_000, samples: tenSecondTone())
        let master = AudioFingerprint.compute(pcm)
        var other = AudioFingerprintParameters()
        other.maxDeltaBins = 64
        let foreign = AudioFingerprint.compute(pcm, parameters: other)
        let index = AudioFingerprintIndex(master: master)
        #expect(index.match(foreign).verdict
                == .inconclusive(reason: .incompatibleRecipe(query: other.recipeID, master: master.recipeID)))
        #expect(index.match(foreign).matchedLandmarks == 0)
        #expect(index.match(master).verdict != .inconclusive(reason: .incompatibleRecipe(query: master.recipeID,
                                                                                         master: master.recipeID)))
    }

    private func tenSecondTone() -> [Int16] {
        (0..<(8_000 * 10)).map { Int16(sin(Double($0) * 2 * .pi * 440 / 8_000) * 12_000) }
    }

    // MARK: Matcher — the pure verdict

    private func evidence(matched: Int = 500, coverage: Double = 0.9, overlap: Double, span: Double,
                          offset: Double, query: Double, master: Double, gap: Double = 0) -> AudioMatchEvidence {
        AudioMatchEvidence(matchedLandmarks: matched, coverage: coverage, overlapSeconds: overlap,
                           spanSeconds: span, offsetSeconds: offset, queryDurationSeconds: query,
                           masterDurationSeconds: master, unmatchedGapSeconds: gap)
    }

    @Test func verdictRules() {
        #expect(evidence(overlap: 180, span: 180, offset: 0, query: 180, master: 180).verdict() == .sameRecording)
        #expect(evidence(overlap: 20, span: 20, offset: 60, query: 20, master: 180).verdict()
                == .containedInMaster(offsetSeconds: 60))
        #expect(evidence(overlap: 180, span: 180, offset: -30, query: 240, master: 180).verdict()
                == .masterContainedInQuery(offsetSeconds: 30))
        // Same start, then diverges: coverage below the bar, a 60-s run.
        #expect(evidence(coverage: 0.33, overlap: 180, span: 60, offset: 0, query: 180, master: 180).verdict()
                == .overlap(offsetSeconds: 0, seconds: 60))
        // Query hangs off the master's end: full coverage of the overlap, but neither contains the other.
        #expect(evidence(overlap: 100, span: 100, offset: 80, query: 180, master: 180).verdict()
                == .overlap(offsetSeconds: 80, seconds: 100))
        #expect(evidence(matched: 5, overlap: 180, span: 3, offset: 0, query: 180, master: 180).verdict()
                == .different)
        #expect(evidence(coverage: 0.1, overlap: 180, span: 2, offset: 0, query: 180, master: 180).verdict()
                == .different)
    }

    /// Completeness (codex F2): an incomplete side can be contained, never
    /// "same" or containing. Every (inside, inside, complete, complete)
    /// tuple maps to exactly one case.
    @Test func verdictRefusesWholeRecordingClaimsOnIncompleteSides() {
        var e = evidence(overlap: 180, span: 180, offset: 0, query: 180, master: 180)
        e.queryComplete = false; e.masterComplete = false
        #expect(e.verdict() == .inconclusive(reason: .bothIncomplete))
        e.masterComplete = true
        #expect(e.verdict() == .masterContainedInQuery(offsetSeconds: 0), "complete master inside the query's analysed part")
        e.queryComplete = true; e.masterComplete = false
        #expect(e.verdict() == .containedInMaster(offsetSeconds: 0), "complete query inside the master's analysed part")

        // Query geometrically inside the master, but the query was capped.
        var c = evidence(overlap: 20, span: 20, offset: 60, query: 20, master: 180)
        c.queryComplete = false
        #expect(c.verdict() == .inconclusive(reason: .queryIncomplete))
        c.queryComplete = true; c.masterComplete = false
        #expect(c.verdict() == .containedInMaster(offsetSeconds: 60), "a capped master still contains the clip")

        // Master geometrically inside the query, but the master was capped.
        var m = evidence(overlap: 180, span: 180, offset: -30, query: 240, master: 180)
        m.masterComplete = false
        #expect(m.verdict() == .inconclusive(reason: .masterIncomplete))
        m.masterComplete = true; m.queryComplete = false
        #expect(m.verdict() == .masterContainedInQuery(offsetSeconds: 30))

        // Partial overlap needs no completeness.
        var o = evidence(overlap: 100, span: 100, offset: 80, query: 180, master: 180)
        o.queryComplete = false; o.masterComplete = false
        #expect(o.verdict() == .overlap(offsetSeconds: 80, seconds: 100))
    }

    // MARK: Matcher — distributed evidence (codex F1)

    /// 120 s of A followed by 60 s of C, against A: two thirds of the
    /// timeline match and the files are the same length, but a minute of
    /// audible, unmatched audio is a contradiction — "overlap", never
    /// "same recording".
    @Test func partialMatchIsNeverAWholeRecordingClaim() {
        let sr = 8_000
        let a = SyntheticSpeech.toInt16(SyntheticSpeech.render(seconds: 180, seed: AudioFixtures.seedA, sampleRate: sr))
        let c = SyntheticSpeech.toInt16(SyntheticSpeech.render(seconds: 180, seed: AudioFixtures.seedC, sampleRate: sr))
        let spliced = Array(a[0..<(120 * sr)]) + Array(c[(120 * sr)...])
        let m = AudioFingerprintMatcher.match(query: AudioFingerprint.compute(AudioPCM(sampleRate: sr, samples: spliced)),
                                              master: AudioFingerprint.compute(AudioPCM(sampleRate: sr, samples: a)))
        print(audioMatchLine("A120+C60 vs A", m))
        #expect(m.verdict != .sameRecording)
        guard case .overlap(let offset, let seconds) = m.verdict else {
            Issue.record("expected overlap, got \(m.verdict)"); return
        }
        #expect(abs(offset) <= audioOffsetTolerance)
        #expect((114...126).contains(seconds), "the matched run is the first 120 s, got \(seconds)")
    }

    /// Four seconds of query with two matched seconds against a four-hour
    /// master is noise, not a clip of the master: `minOverlapSeconds`
    /// applies on every branch.
    @Test func tinyQueryWithTwoMatchedSecondsIsNotContained() {
        let e = evidence(matched: 20, coverage: 0.5, overlap: 4, span: 2, offset: 100, query: 4, master: 14_400)
        #expect(e.verdict() == .different, "\(e.verdict())")
    }

    /// The pure rule for distribution (row 3): codex's 120-of-180 case at
    /// coverage 2/3 with a 60-s unmatched gap is overlap, never same; the
    /// same coverage with the misses scattered (gap ≤ 10 s) is same.
    @Test func verdictRequiresDistributedEvidence() {
        let clustered = evidence(coverage: 2.0 / 3.0, overlap: 180, span: 120, offset: 0, query: 180, master: 180, gap: 60)
        #expect(clustered.verdict() == .overlap(offsetSeconds: 0, seconds: 120))
        let scattered = evidence(coverage: 2.0 / 3.0, overlap: 180, span: 180, offset: 0, query: 180, master: 180, gap: 3)
        #expect(scattered.verdict() == .sameRecording)
        let clip = evidence(coverage: 0.9, overlap: 60, span: 40, offset: 10, query: 60, master: 180, gap: 20)
        #expect(clip.verdict() == .overlap(offsetSeconds: 10, seconds: 40), "a 20-s unmatched stretch is not 'contained'")
        let shortRun = evidence(coverage: 1, overlap: 180, span: 4, offset: 0, query: 180, master: 180)
        #expect(shortRun.verdict() == .different, "row 2 beats everything below it")
    }

    /// The audible bitmap rides in VSAF and `estimatedBytes` stays exact.
    @Test func audibleSecondsRoundTripInVSAF() {
        let sr = 8_000
        let quiet = tenSecondTone() + [Int16](repeating: 0, count: 5 * sr) + tenSecondTone().prefix(sr / 2)
        let f = AudioFingerprint.compute(AudioPCM(sampleRate: sr, samples: Array(quiet)))
        #expect(f.activeSeconds.count == 16, "\(f.activeSeconds.count) flags for 15.5 s")
        #expect(f.activeSecondCount == 11, "10 s tone + a half-second tail = 11 audible: \(f.activeSeconds)")
        #expect(f.activeSeconds[0] && !f.activeSeconds[12] && f.activeSeconds[15])
        let data = f.encoded()
        #expect(data.count == f.estimatedBytes)
        #expect(AudioFingerprint(decoding: data) == f)
        #expect(AudioFingerprint(decoding: data)?.activeSeconds == f.activeSeconds)
    }

    /// An exact copy whose last 90 s are digital silence: silence is not
    /// evidence either way, so it leaves the coverage denominator and the
    /// copy is the same recording.
    @Test func digitalSilenceIsExcludedFromCoverage() {
        let sr = 8_000
        let a = SyntheticSpeech.toInt16(SyntheticSpeech.render(seconds: 180, seed: AudioFixtures.seedA, sampleRate: sr))
        let quiet = Array(a[0..<(30 * sr)]) + [Int16](repeating: 0, count: 90 * sr)
        let f = AudioFingerprint.compute(AudioPCM(sampleRate: sr, samples: quiet))
        let m = AudioFingerprintMatcher.match(query: f, master: f)
        print(audioMatchLine("30 s A + 90 s silence vs itself", m))
        #expect(m.verdict == .sameRecording, "\(m.verdict)")
        #expect(m.coverage >= 0.9, "silent seconds must not dilute coverage: \(m.coverage)")
    }

    // MARK: Sensor — the engine never writes beside an input

    @Test func engineSourcesNeverOpenAnInputForWrite() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VideoScanCore", isDirectory: true)
        let forbidden = ["removeItem", "moveItem", "createFile", "replaceItem", "copyItem",
                         "\"-y\"", "write(to:", "forWritingAtPath", "FileHandle(forUpdating"]
        for name in ["AudioPCMDecoder.swift", "AudioFingerprint.swift", "AudioFingerprintMatcher.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for token in forbidden {
                #expect(!text.contains(token), "\(name) contains \(token)")
            }
        }
    }

    // MARK: Scale

    /// 60 minutes of synthetic audio → fingerprint + index, then a 30-s
    /// slice at 1234 s must be found at 1234 s. `VIDEOSCAN_SKIP_SCALE=1`
    /// skips it (the render alone is ~6 s in Debug).
    ///
    /// Measured 2026-10-14, M4 Max, Debug, load ~6/16: fingerprint 2.54 s,
    /// index 0.03 s, match ≈ 0.03 s → 2.6 s total; 99 734 landmarks,
    /// 798 KB (13.3 KB/min); PCM 57.6 MB in RAM. Budget ≈ 2×.
    @Test(.tags(.scale), .enabled(if: ProcessInfo.processInfo.environment["VIDEOSCAN_SKIP_SCALE"] != "1"))
    func sixtyMinuteMasterFingerprintsAndIndexesWithinBudget() throws {
        let budget: Duration = .seconds(6)
        let sampleRate = 8_000
        let render = SyntheticSpeech.toInt16(SyntheticSpeech.render(seconds: 3_600, seed: 0x60_60, sampleRate: sampleRate))
        let master = AudioPCM(sampleRate: sampleRate, samples: render)
        let slice = AudioPCM(sampleRate: sampleRate, samples: Array(render[(1_234 * sampleRate)..<(1_264 * sampleRate)]))

        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let fingerprint = AudioFingerprint.compute(master)
        let afterFingerprint = clock.now
        let index = AudioFingerprintIndex(master: fingerprint)
        let afterIndex = clock.now
        let match = index.match(AudioFingerprint.compute(slice))
        let elapsed = clock.now - start

        print("[audio-fp scale] 60 min: fingerprint \(afterFingerprint - start), index \(afterIndex - afterFingerprint), "
              + "total \(elapsed); \(fingerprint.landmarkCount) landmarks, \(fingerprint.estimatedBytes) bytes "
              + "(\(fingerprint.estimatedBytes / 60) B/min); PCM \(render.count * 2) B in RAM (\(TimingBudget.loadDescription()))")
        print(audioMatchLine("slice@1234 vs 60-min", match))
        #expect(match.verdict == .containedInMaster(offsetSeconds: match.offsetSeconds))
        #expect(abs(match.offsetSeconds - 1_234) <= audioOffsetTolerance)
        expectWithinTimingBudget("60-min fingerprint + index + match", measured: elapsed, budget: budget,
                                 loadBefore: loadBefore)
    }
}
