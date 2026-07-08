// CleanupMediaMatrixTests.swift
// MEDIA MATRIX dimension for Clean Up Video (feature-test checklist
// item 3): the REAL CleanupFFmpegEngine, end-to-end, against synthetic
// ffmpeg fixtures across the checklist containers — mp4/h264 (interlaced
// AND progressive), mov/prores, mkv/ffv1+pcm, mxf, avi/dv — plus a
// video-only source.
//
// For every case the engine must produce a file that ffprobe confirms is:
//   - ProRes profile LT (the recipe's pinned output codec),
//   - field_order progressive (bwdif on interlaced sources; pass-through
//     on progressive ones),
//   - duration within tolerance of the source,
//   - audio stream-copied VERBATIM (codec identical to the source) or
//     absent for a video-only source,
// and the SOURCE file must be untouched (SHA-256 + size + mtime).
//
// Fixtures are 2 s, generated at test time in temp with the `test_`
// prefix (repo convention — see TestMediaGenerator; CleanupTestMedia adds
// the interlace/dv flags that generator doesn't expose). Verification
// ffprobe runs independently of the app's probe pipeline so a probeFile
// bug can't mask an engine bug.
//
// These render through prores_videotoolbox (the recipe's hardware
// encoder), so this suite requires Apple Silicon — true of every machine
// that runs VideoScanTests (M4/M5/M1 fleet).

import Testing
import Foundation
@testable import VideoScan

// MARK: - Case table

struct CleanupMatrixCase: Sendable, CustomStringConvertible {
    let label: String
    let filename: String
    let size: String
    let rate: String
    let videoCodec: String
    let extraVideoArgs: [String]
    /// nil ⇒ video-only fixture (no audio stream expected in the output).
    let audioCodec: String?
    /// The field_order ffprobe must report for the SOURCE — precondition
    /// pinning that the fixture really exercises the intended bwdif path.
    let expectedSourceFieldOrders: Set<String>

    var description: String { label }
}

private let matrixCases: [CleanupMatrixCase] = [
    CleanupMatrixCase(
        label: "mp4/h264 interlaced (tff)",
        filename: "test_mx_h264_tff.mp4",
        size: "720x480", rate: "30000/1001",
        videoCodec: "libx264",
        extraVideoArgs: ["-flags", "+ilme+ildct", "-x264opts", "tff=1"],
        audioCodec: "aac",
        expectedSourceFieldOrders: ["tt", "tb"]),
    CleanupMatrixCase(
        label: "mp4/h264 progressive",
        filename: "test_mx_h264_prog.mp4",
        size: "640x480", rate: "30",
        videoCodec: "libx264", extraVideoArgs: [],
        audioCodec: "aac",
        expectedSourceFieldOrders: ["progressive"]),
    CleanupMatrixCase(
        label: "mov/prores + pcm",
        filename: "test_mx_prores.mov",
        size: "320x240", rate: "25",
        videoCodec: "prores", extraVideoArgs: [],
        audioCodec: "pcm_s16le",
        expectedSourceFieldOrders: ["progressive", "unknown"]),
    CleanupMatrixCase(
        label: "mkv/ffv1 + pcm",
        filename: "test_mx_ffv1.mkv",
        size: "320x240", rate: "25",
        videoCodec: "ffv1", extraVideoArgs: [],
        audioCodec: "pcm_s16le",
        expectedSourceFieldOrders: ["progressive", "unknown"]),
    CleanupMatrixCase(
        label: "mxf/h264 + pcm",
        filename: "test_mx_x264.mxf",
        size: "720x576", rate: "25",
        videoCodec: "libx264", extraVideoArgs: [],
        audioCodec: "pcm_s16le",
        expectedSourceFieldOrders: ["progressive", "unknown"]),
    CleanupMatrixCase(
        label: "avi/dv + pcm",
        filename: "test_mx_dv.avi",
        size: "720x576", rate: "25",
        videoCodec: "dvvideo", extraVideoArgs: ["-pix_fmt", "yuv420p"],
        audioCodec: "pcm_s16le",
        expectedSourceFieldOrders: ["progressive", "unknown", "bb", "bt"]),
    CleanupMatrixCase(
        label: "mp4/h264 video-only",
        filename: "test_mx_vonly.mp4",
        size: "320x240", rate: "25",
        videoCodec: "libx264", extraVideoArgs: [],
        audioCodec: nil,
        expectedSourceFieldOrders: ["progressive"]),
]

// MARK: - Suite

// .serialized: each case spawns two ffmpeg children and one ffprobe —
// serial keeps subprocess load deterministic on loaded test hosts.
// (Swift Testing note for Rick: `arguments:` runs the ONE test function
// once per element — like gtest's TEST_P value-parameterized tests —
// and each case reports pass/fail under its own name.)
@Suite(.serialized)
struct CleanupMediaMatrixTests {

    private let fixtureDuration = 2.0

    @Test("VHS Quick Clean renders every matrix container faithfully",
          .timeLimit(.minutes(2)),
          arguments: matrixCases)
    func vhsQuickCleanAcrossTheMatrix(testCase: CleanupMatrixCase) async throws {
        try #require(CleanupTestMedia.toolsAvailable,
                     "ffmpeg/ffprobe are required project dependencies")

        let dir = try CleanupTestMedia.makeScratchDir("matrix")
        defer { try? FileManager.default.removeItem(at: dir) }

        // ---- Fixture
        let srcPath = try CleanupTestMedia.generate(
            into: dir,
            name: testCase.filename,
            duration: fixtureDuration,
            size: testCase.size,
            rate: testCase.rate,
            videoCodec: testCase.videoCodec,
            extraVideoArgs: testCase.extraVideoArgs,
            audioCodec: testCase.audioCodec)

        // ---- Source truth (independent ffprobe), used to build the
        // CleanupSource the way the catalog would.
        let sourceProbe = try CleanupTestMedia.probe(srcPath)
        let sourceFieldOrder = sourceProbe.video?.field_order ?? "unknown"
        #expect(testCase.expectedSourceFieldOrders.contains(sourceFieldOrder),
                "[\(testCase)] fixture precondition: field_order \(sourceFieldOrder) not in \(testCase.expectedSourceFieldOrders) — the intended deinterlace path isn't being exercised")
        let sourceAudioCodec = sourceProbe.audio?.codec_name
        #expect((sourceAudioCodec != nil) == (testCase.audioCodec != nil),
                "[\(testCase)] fixture precondition: audio presence mismatch")

        let before = try CleanupTestMedia.fingerprint(srcPath)

        // ---- Render with the REAL engine
        let source = CleanupSource(path: srcPath,
                                   durationSeconds: sourceProbe.durationSeconds,
                                   fieldOrder: sourceFieldOrder,
                                   hasAudio: sourceAudioCodec != nil)
        let scratch = dir.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let rendered = try await CleanupFFmpegEngine().render(
            recipe: CleanupRecipeRegistry.vhsQuickClean,
            source: source,
            scratchDirectory: scratch,
            progress: { _ in })

        // ---- Output invariants
        #expect(rendered.path.hasPrefix(scratch.path),
                "[\(testCase)] engine must render inside the given scratch directory")
        let outAttrs = try FileManager.default.attributesOfItem(atPath: rendered.path)
        #expect(((outAttrs[.size] as? NSNumber)?.int64Value ?? 0) >= 10_000,
                "[\(testCase)] output suspiciously small")

        let outProbe = try CleanupTestMedia.probe(rendered.path)
        #expect(outProbe.video?.codec_name == "prores",
                "[\(testCase)] output video codec: \(outProbe.video?.codec_name ?? "nil")")
        #expect(outProbe.video?.profile == "LT",
                "[\(testCase)] output must be ProRes 422 LT; got profile \(outProbe.video?.profile ?? "nil")")
        #expect(outProbe.video?.field_order == "progressive",
                "[\(testCase)] cleaned output must be progressive; got \(outProbe.video?.field_order ?? "nil")")
        #expect(abs(outProbe.durationSeconds - sourceProbe.durationSeconds) <= 0.5,
                "[\(testCase)] duration drifted: source \(sourceProbe.durationSeconds)s → output \(outProbe.durationSeconds)s")

        if let expectedAudio = sourceAudioCodec {
            #expect(outProbe.audio?.codec_name == expectedAudio,
                    "[\(testCase)] audio must be STREAM-COPIED (\(expectedAudio)); got \(outProbe.audio?.codec_name ?? "nil")")
        } else {
            #expect(outProbe.audio == nil,
                    "[\(testCase)] video-only source must yield a video-only output, not fail and not grow audio")
        }

        // ---- Source untouched — bytes AND mtime
        let after = try CleanupTestMedia.fingerprint(srcPath)
        #expect(after == before,
                "[\(testCase)] SOURCE FILE CHANGED during cleanup — sha/size/mtime: \(before) → \(after)")
    }
}
