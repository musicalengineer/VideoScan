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
