import CoreGraphics
import Foundation
import Testing
import Vision
@testable import VideoScan

// Regression sensor for the 2026-08-03 native Donna-search failure.
// Catalog eligibility accepts video-bearing MKV/MXF records, but the first
// native implementation opened every clip exclusively with AVFoundation.
// AVFoundation cannot open Rick's FFV1/PCM Matroska masters, so a selected
// batch could finish 0 scanned / N errors. These tests exercise the real
// decoder transport while injecting identity data only; no family photos,
// CoreML model, or recognition threshold is involved.
@Suite(.serialized)
struct NativeRecipeMediaMatrixTests {
    private func scorer() -> NativeRecipeScorer {
        NativeRecipeScorer(
            testEmbedder: { _, _ in [1, 0] },
            centroids: [RecipeEraCentroid(era: "synthetic", centroid: [1, 0])]
        )
    }

    private func assertDecodes(_ filename: String,
                               sourceLocation: SourceLocation = #_sourceLocation) async {
        let url = URL(fileURLWithPath: testFixturesDir())
            .appendingPathComponent(filename)
        let result = await scorer().score(clip: url)
        let detail = result.error ?? "no error"
        #expect(result.error == nil,
                "\(filename) is catalog-eligible and must be scannable; got: \(detail)",
                sourceLocation: sourceLocation)
        #expect(result.frameCount > 0,
                "\(filename) opened but yielded no sampled frames",
                sourceLocation: sourceLocation)
    }

    private func assertGeneratedDecodes(container: String,
                                        videoCodec: String,
                                        audioCodec: String = "pcm_s16le",
                                        streams: StreamConfig = .videoAndAudio,
                                        resolution: String = "320x240",
                                        frameRate: Int = 25,
                                        sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let path = try TestMediaGenerator.generate(
            container: container,
            streams: streams,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            duration: 2,
            resolution: resolution,
            frameRate: frameRate,
            prefix: "test_native_recipe")
        defer { TestMediaGenerator.cleanup(path) }
        let result = await scorer().score(clip: URL(fileURLWithPath: path))
        let detail = result.error ?? "no error"
        #expect(result.error == nil,
                "\(container)/\(videoCodec) is catalog-eligible and must be scannable; got: \(detail)",
                sourceLocation: sourceLocation)
        #expect(result.frameCount > 0,
                "\(container)/\(videoCodec) opened but yielded no sampled frames",
                sourceLocation: sourceLocation)
    }

    @Test("MP4/H.264 native scorer sanity")
    func mp4Decodes() async { await assertDecodes("test_video_audio.mp4") }

    @Test("MOV native scorer sanity")
    func movDecodes() async { await assertDecodes("test_video_audio.mov") }

    @Test("MKV common-codec regression")
    func mkvDecodes() async { await assertDecodes("test_video_audio.mkv") }

    @Test("MKV/FFV1+PCM archival-master regression")
    func ffv1MKVDecodes() async { await assertDecodes("test_ffv1_pcm_4s.mkv") }

    @Test("MXF video+audio regression")
    func mxfVideoAudioDecodes() async { await assertDecodes("test_video_audio.mxf") }

    @Test("MXF video-only regression")
    func mxfVideoOnlyDecodes() async { await assertDecodes("test_video_only.mxf") }

    // The project checklist's remaining canonical media boundary. Generated
    // at runtime because no personal media is permitted in the public repo.
    @Test("AVI/MPEG-4 regression", .enabled(if: TestMediaGenerator.isAvailable))
    func aviDecodes() async throws {
        try await assertGeneratedDecodes(container: "avi", videoCodec: "mpeg4")
    }

    @Test("raw DV regression", .enabled(if: TestMediaGenerator.isAvailable))
    func dvDecodes() async throws {
        // PAL geometry/frame rate are accepted by ffmpeg's dvvideo encoder.
        try await assertGeneratedDecodes(container: "dv", videoCodec: "dvvideo",
                                         streams: .videoOnly,
                                         resolution: "720x576", frameRate: 25)
    }

    @Test("MPEG transport stream regression", .enabled(if: TestMediaGenerator.isAvailable))
    func transportStreamDecodes() async throws {
        try await assertGeneratedDecodes(container: "mts", videoCodec: "mpeg2video",
                                         audioCodec: "ac3")
    }

    @Test("WebM/VP9 regression", .enabled(if: TestMediaGenerator.isAvailable))
    func webMDecodes() async throws {
        try await assertGeneratedDecodes(container: "webm", videoCodec: "libvpx-vp9",
                                         audioCodec: "libopus")
    }

    @Test("missing media remains an honest error")
    func missingFileFails() async {
        let missing = URL(fileURLWithPath: testFixturesDir())
            .appendingPathComponent("does-not-exist.mkv")
        let result = await scorer().score(clip: missing)
        #expect(result.error != nil)
        #expect(result.frameCount == 0)
    }
}
