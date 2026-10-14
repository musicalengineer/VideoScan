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

    // MARK: Matcher — the pure verdict

    private func evidence(matched: Int = 500, coverage: Double = 0.9, overlap: Double, span: Double,
                          offset: Double, query: Double, master: Double) -> AudioMatchEvidence {
        AudioMatchEvidence(matchedLandmarks: matched, coverage: coverage, overlapSeconds: overlap,
                           spanSeconds: span, offsetSeconds: offset, queryDurationSeconds: query,
                           masterDurationSeconds: master)
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
