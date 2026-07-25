// BalanceAudioProbeTests.swift
// MEDIA-MATRIX dimension for Balance Audio (GH #116): the REAL probe
// (ffprobe shape + ffmpeg astats passes) against synthetic fixtures for
// every channel case, in both the lossy (mp4/h264+aac) and lossless
// (mov/h264+pcm) families. These are the tests Rick explicitly asked
// for — left-only, right-only, etc., verified end-to-end through real
// tools.

import Testing
import Foundation
@testable import VideoScan

@Suite("Balance Audio — probe media matrix", .serialized)
struct BalanceAudioProbeTests {

    // MARK: Error language (QA m2, overnight review 2026-07-24)

    @Test("probe errors speak family language — never raw type soup")
    func probeErrorDescriptionsAreFamilyLanguage() {
        // The #136 giant-file case surfaced through Balance verify's
        // generic catch as "(VideoScan.AudioBalanceProbeError error 3.)".
        // Every case must carry an honest errorDescription; the timeout
        // mirrors VerifyAudioProbe's "ran out of time" wording.
        let timeout = AudioBalanceProbeError.timedOut(afterSeconds: 1800)
        let msg = timeout.localizedDescription
        #expect(msg.contains("ran out of time"))
        #expect(!msg.contains("AudioBalanceProbeError"), "no type names")
        #expect(!msg.contains("VideoScan."), "no module names")
        #expect(!msg.contains("error 3"), "no raw NSError case soup")

        let allCases: [AudioBalanceProbeError] = [
            .toolUnavailable("ffmpeg not found"),
            .noAudioStream,
            .probeFailed("ffprobe exited with status 1"),
            .timedOut(afterSeconds: 60),
        ]
        for error in allCases {
            let described = error.errorDescription ?? ""
            #expect(!described.isEmpty, "every case carries a message: \(error)")
            #expect(!described.contains("AudioBalanceProbeError"))
        }
    }

    @Test("classifies every channel case from real mp4/h264+aac fixtures",
          .timeLimit(.minutes(3)))
    func matrixAAC() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable,
                     "ffmpeg/ffprobe are required project dependencies")
        let dir = try BalanceAudioTestMedia.makeScratchDir("matrix_aac")
        defer { try? FileManager.default.removeItem(at: dir) }

        for channelCase in BalanceAudioTestMedia.ChannelCase.allCases {
            let path = try BalanceAudioTestMedia.generate(
                into: dir, channelCase: channelCase, wrapper: .mp4H264Aac)
            let analysis = try await AudioBalanceProbe.analyze(path: path)
            #expect(analysis.classification == channelCase.expectedClass,
                    "\(channelCase.rawValue) (aac) classified as \(analysis.classification)")
            #expect(analysis.shape.videoCodec == "h264")
            #expect(analysis.shape.audioStreams == 1)
        }
    }

    @Test("classifies every channel case from real mov/h264+pcm fixtures",
          .timeLimit(.minutes(3)))
    func matrixPCM() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable,
                     "ffmpeg/ffprobe are required project dependencies")
        let dir = try BalanceAudioTestMedia.makeScratchDir("matrix_pcm")
        defer { try? FileManager.default.removeItem(at: dir) }

        for channelCase in BalanceAudioTestMedia.ChannelCase.allCases {
            let path = try BalanceAudioTestMedia.generate(
                into: dir, channelCase: channelCase, wrapper: .movH264Pcm)
            let analysis = try await AudioBalanceProbe.analyze(path: path)
            #expect(analysis.classification == channelCase.expectedClass,
                    "\(channelCase.rawValue) (pcm) classified as \(analysis.classification)")
            #expect(analysis.shape.audioCodec.hasPrefix("pcm_"))
        }
    }

    @Test("levels are honest: left-only fixture measures program left, silence right",
          .timeLimit(.minutes(1)))
    func levelsHonest() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("levels")
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = try BalanceAudioTestMedia.generate(
            into: dir, channelCase: .leftOnly, wrapper: .movH264Pcm)
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        try #require(analysis.measurements.channels.count == 2)
        // 0.5-amplitude sine ≈ −9 dBFS RMS; PCM silence is exact −inf.
        #expect(analysis.measurements.channels[0].rmsDBFS > -15)
        #expect(analysis.measurements.channels[1].rmsDBFS
                < AudioBalanceClassifier.programFloorDBFS)
    }

    @Test("file with no audio stream throws noAudioStream",
          .timeLimit(.minutes(1)))
    func noAudioThrows() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("noaudio")
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = dir.appendingPathComponent("test_balance_videoonly.mp4").path
        try BalanceAudioTestMedia.runFFmpeg([
            "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=25",
            "-c:v", "libx264", "-preset", "ultrafast", "-an"
        ], output: out)

        await #expect(throws: AudioBalanceProbeError.noAudioStream) {
            _ = try await AudioBalanceProbe.analyze(path: out)
        }
    }
}

// MARK: - Levels-pass deadline scaling (GH #136 — pure, no I/O)

@Suite("Balance Audio — levels deadline scaling")
struct BalanceAudioLevelsDeadlineTests {

    private func deadline(_ bytes: Int64) -> Double {
        AudioBalanceProbe.levelsDeadlineSeconds(forFileSizeBytes: bytes)
    }

    @Test("small and unknown sizes get the historical 300 s floor")
    func smallFilesGetFloor() {
        #expect(deadline(0) == 300)                       // unknown size
        #expect(deadline(-1) == 300)                      // defensive
        #expect(deadline(1_000_000) == 300)               // 1 MB
        #expect(deadline(10 * 1024 * 1024 * 1024) == 300) // 10 GiB → 103 s scaled, floor wins
    }

    @Test("floor boundary: exactly 300 s of demux budget stays 300, one byte more rounds up")
    func floorBoundary() {
        let floorBytes: Int64 = 300 * 100 * 1024 * 1024   // 300 s at 100 MiB/s
        #expect(deadline(floorBytes) == 300)
        #expect(deadline(floorBytes + 1) == 301)          // ceil
    }

    @Test("the Cape-1992 proof case: 63.7 GB scales to ~653 s — past the old fixed 300 s")
    func capeProofCaseScales() {
        // 63.7 GiB / (100 MiB/s) = 652.3 s → ceil 653. The old fixed
        // 300 s deadline could never finish this file; the scaled one
        // budgets the demux honestly.
        let bytes = Int64(63.7 * 1024 * 1024 * 1024)
        #expect(deadline(bytes) == 653)
        #expect(deadline(bytes) > AudioBalanceProbe.levelsDeadlineFloorSeconds)
        #expect(deadline(bytes) < AudioBalanceProbe.levelsDeadlineCapSeconds)
    }

    @Test("huge archives cap at 1800 s")
    func hugeFilesCap() {
        #expect(deadline(1024 * 1024 * 1024 * 1024) == 1800)  // 1 TiB
        #expect(deadline(Int64.max) == 1800)
    }

    @Test("monotone: a bigger file never gets less time")
    func monotone() {
        var previous = 0.0
        for gib in [1, 20, 40, 64, 100, 200, 500] {
            let d = deadline(Int64(gib) * 1024 * 1024 * 1024)
            #expect(d >= previous, "deadline shrank at \(gib) GiB")
            previous = d
        }
    }
}
