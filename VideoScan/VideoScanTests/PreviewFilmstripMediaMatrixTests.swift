// PreviewFilmstripMediaMatrixTests.swift
// MEDIA MATRIX + SENSOR dimensions for renderPreviewFilmstrip
// (feature/filmstrip-preview commit 0b9fa96, 2026-07-27).
//
// Runs the REAL renderer — real ffmpeg rips for .ffmpegDirect routes,
// real AVFoundation batch generation for .avFoundation — against
// synthetic fixtures:
//
//   blue-lead-in mkv/ffv1 — 3 s of solid blue then 5 s of testsrc: the
//       digitized-VHS case the near-solid dropping exists for. The
//       strip's FIRST frame must land past the leader.
//   mkv/ffv1              — the archival-master route (.ffmpegDirect,
//       bounded-concurrency per-offset rips) + the feature's wall-time
//       SENSOR at production-like settings.
//   mp4/h264              — the .avFoundation one-asset batch arm
//       (-g 12 dense keyframes, same rationale as
//       PreviewBestFrameMediaMatrixTests' fixture note).
//   mov/prores            — second .avFoundation container.
//   avi/dv                — routes .avFoundation but AVF can't open
//       AVI: pins the batch-failure → ffmpeg-loop fallback arm.
//
// Plus the failure contracts: per-frame failures tolerated (past-EOF
// offsets just drop out), all-fail throws noFrameProduced, and an
// unplannable duration degenerates to a one-frame strip.

import Testing
import Foundation
import CoreGraphics
@testable import VideoScan

@Suite("PreviewFilmstrip media matrix",
       .serialized,
       .timeLimit(.minutes(5)),
       .enabled(if: TestMediaGenerator.isAvailable))
struct PreviewFilmstripMediaMatrixTests {

    // MARK: - Fixture generation

    private static let ffmpegPath: String = {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "ffmpeg"
    }()

    private func runFFmpeg(_ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.ffmpegPath)
        proc.arguments = ["-y", "-hide_banner", "-loglevel", "error"] + args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? "?"
            throw TestMediaGenerator.GeneratorError.ffmpegFailed(
                status: proc.terminationStatus, message: msg)
        }
    }

    private func tempPath(_ ext: String) -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("test_gen_filmstrip_\(UUID().uuidString.prefix(8)).\(ext)")
    }

    /// mkv/ffv1 with `leaderSeconds` of solid blue then testsrc content —
    /// the digitized-tape shape. All-intra FFV1, so input seeks are exact.
    private func generateBlueLeadFFV1(leaderSeconds: Double,
                                      contentSeconds: Double) throws -> String {
        let out = tempPath("mkv")
        try runFFmpeg([
            "-f", "lavfi", "-i", "color=c=blue:s=320x240:r=25:d=\(leaderSeconds)",
            "-f", "lavfi", "-i", "testsrc=duration=\(contentSeconds):size=320x240:rate=25",
            "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]",
            "-c:v", "ffv1", out
        ])
        return out
    }

    /// avi/dv fixture — TestMediaGenerator can't pass the -pix_fmt DV
    /// needs, so build it directly (same recipe as CleanupMediaMatrixTests'
    /// avi/dv case: 720x576/25 PAL DV, yuv420p).
    private func generateDVAVI(duration: Double) throws -> String {
        let out = tempPath("avi")
        try runFFmpeg([
            "-f", "lavfi", "-i", "testsrc=duration=\(duration):size=720x576:rate=25",
            "-c:v", "dvvideo", "-pix_fmt", "yuv420p", "-an", out
        ])
        return out
    }

    /// mp4/h264 with dense keyframes (-g 12) so the AVF batch arm's
    /// nearest-keyframe rips actually land near the requested offsets.
    private func generateH264MP4(duration: Double) throws -> String {
        let out = tempPath("mp4")
        try runFFmpeg([
            "-f", "lavfi", "-i", "testsrc=duration=\(duration):size=320x240:rate=25",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "12", "-an", out
        ])
        return out
    }

    // MARK: - Shared assertions

    /// Offsets strictly increasing — the UI scrubber's contract.
    private func expectMonotonic(_ frames: [PreviewFilmstrip.Frame],
                                 _ label: String) {
        let offsets = frames.map(\.offsetSeconds)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 },
                "[\(label)] offsets not strictly increasing: \(offsets)")
    }

    // MARK: - Blue lead-in (the near-solid dropping, end to end)

    @Test("blue-lead-in mkv/ffv1: strip fast-forwards past the leader — first frame is content")
    func blueLeadInSkipped() async throws {
        // 8 s total → planned offsets 0.25, 0.75 … 7.75. The six rips at
        // < 3 s land in the leader and must be dropped; ten content
        // frames survive (≥ the keep-all floor, so the floor stays out
        // of the way).
        let path = try generateBlueLeadFFV1(leaderSeconds: 3, contentSeconds: 5)
        defer { TestMediaGenerator.cleanup(path) }

        let strip = try await VideoScanModel.renderPreviewFilmstrip(
            path: path,
            container: "Matroska / WebM",
            videoCodec: "ffv1",
            likelyUnanalyzable: false,
            durationSeconds: 8.0)

        try #require(!strip.frames.isEmpty)
        expectMonotonic(strip.frames, "blue-lead-in")
        #expect(strip.frames.count >= 8 && strip.frames.count <= 12,
                "expected ~10 surviving content frames, got \(strip.frames.count)")

        let first = strip.frames[0]
        #expect(first.offsetSeconds >= 3.0,
                "first frame at t=\(first.offsetSeconds) — the strip did not fast-forward past the 3 s leader")
        let score = try #require(PreviewFrameScorer.score(first.image))
        #expect(score.combined > PreviewFrameScorer.nearSolidThreshold,
                "first frame is near-solid (score \(score.combined)) — leader survived the selection")
        // Belt and suspenders: visibly not the blue leader.
        let mean = PreviewTestImages.meanRGB(first.image)
        #expect(!(mean.b > 180 && mean.r < 80 && mean.g < 80),
                "first frame is solid blue (\(mean))")
    }

    // MARK: - mkv/ffv1 route + wall-time SENSOR

    /// REGRESSION SENSOR (checklist dimension 5b): filmstrip generation
    /// on the FFV1 fixture at PRODUCTION settings (default 16 frames,
    /// concurrency 4) must complete within an explicit budget. Measured
    /// 2026-07-27 on the M4 Max: ~1–3 s for this fixture; budget 20 s
    /// leaves loaded-host headroom while still catching the failure
    /// modes that matter — rips serialized behind a lock, per-frame
    /// full-file decodes, or the concurrency window collapsing to 1.
    @Test("mkv/ffv1 routes .ffmpegDirect and a full 16-frame strip lands within 20 s")
    func ffv1StripWithinBudget() async throws {
        // mkv/ffv1 + pcm — the checklist's exact archival-master shape.
        let path = try TestMediaGenerator.generate(
            container: "mkv",
            streams: .videoAndAudio,
            videoCodec: "ffv1",
            audioCodec: "pcm_s16le",
            duration: 8.0,
            prefix: "test_gen_filmstrip_ffv1")
        defer { TestMediaGenerator.cleanup(path) }

        // Route pin — the reason this file enters filmstrip mode at all.
        try #require(PreviewFrameRouter.previewRoute(container: "Matroska / WebM",
                                                     videoCodec: "ffv1",
                                                     likelyUnanalyzable: false) == .ffmpegDirect)

        let progress = ProgressCollector()
        let clock = ContinuousClock()
        var strip: PreviewFilmstrip?
        let elapsed = try await clock.measure {
            strip = try await VideoScanModel.renderPreviewFilmstrip(
                path: path,
                container: "Matroska / WebM",
                videoCodec: "ffv1",
                likelyUnanalyzable: false,
                durationSeconds: 8.0,
                onFrameProgress: { done, total in progress.record(done: done, total: total) })
        }
        let frames = try #require(strip).frames

        // All 16 planned offsets are testsrc content — every one survives.
        #expect(frames.count == 16, "expected the full 16-frame strip, got \(frames.count)")
        expectMonotonic(frames, "ffv1")
        #expect(frames.map(\.offsetSeconds) ==
                PreviewFilmstripPlan.offsets(durationSeconds: 8.0),
                "surviving offsets must be exactly the planned offsets for all-content input")

        // Honest progress: monotonically nondecreasing, ends at 16/16.
        let seen = progress.snapshot()
        #expect(seen.last?.done == 16 && seen.last?.total == 16,
                "progress must end at 16/16, got \(String(describing: seen.last))")
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.done <= $1.done },
                "progress went backwards: \(seen.map(\.done))")

        #expect(elapsed < .seconds(20),
                "16-frame ffv1 strip took \(elapsed) — generation cost regressed (budget 20 s)")
    }

    // MARK: - .avFoundation batch arm

    @Test("mp4/h264 exercises the AVFoundation one-asset batch arm")
    func h264BatchArm() async throws {
        let path = try generateH264MP4(duration: 8.0)
        defer { TestMediaGenerator.cleanup(path) }

        try #require(PreviewFrameRouter.previewRoute(container: "QuickTime / MOV",
                                                     videoCodec: "h264",
                                                     likelyUnanalyzable: false) == .avFoundation)

        let strip = try await VideoScanModel.renderPreviewFilmstrip(
            path: path,
            container: "QuickTime / MOV",
            videoCodec: "h264",
            likelyUnanalyzable: false,
            durationSeconds: 8.0)

        // The AVF batch reports requested times back — allow a little
        // slack for frames the generator declines near EOF, but a count
        // this low would mean the batch arm silently fell to ffmpeg.
        #expect(strip.frames.count >= 12,
                "AVF batch arm kept only \(strip.frames.count)/16 frames")
        expectMonotonic(strip.frames, "h264-batch")
    }

    @Test("mov/prores yields a full monotonic strip")
    func proresMov() async throws {
        let path = try TestMediaGenerator.generate(
            container: "mov",
            streams: .videoOnly,
            videoCodec: "prores",
            duration: 6.0,
            prefix: "test_gen_filmstrip_prores")
        defer { TestMediaGenerator.cleanup(path) }

        let strip = try await VideoScanModel.renderPreviewFilmstrip(
            path: path,
            container: "QuickTime / MOV",
            videoCodec: "prores",
            likelyUnanalyzable: false,
            durationSeconds: 6.0)
        #expect(strip.frames.count >= 12)
        expectMonotonic(strip.frames, "prores")
    }

    @Test("avi/dv yields a monotonic strip (batch arm or its ffmpeg fallback)")
    func aviDVFallbackArm() async throws {
        let path = try generateDVAVI(duration: 6.0)
        defer { TestMediaGenerator.cleanup(path) }

        // Router says .avFoundation (AVI/dvvideo aren't in the hostile
        // tables). macOS's AVI support is spotty — on hosts where the
        // AVF batch fails to open the container, this pins the
        // batch-failure → ffmpeg-loop fallback; where AVF copes, it's
        // another batch-arm data point. Either way the strip must land.
        try #require(PreviewFrameRouter.previewRoute(
            container: "AVI (Audio Video Interleaved)",
            videoCodec: "dvvideo",
            likelyUnanalyzable: false) == .avFoundation)

        let strip = try await VideoScanModel.renderPreviewFilmstrip(
            path: path,
            container: "AVI (Audio Video Interleaved)",
            videoCodec: "dvvideo",
            likelyUnanalyzable: false,
            durationSeconds: 6.0)
        #expect(strip.frames.count >= 8,
                "fallback arm kept only \(strip.frames.count) frames")
        expectMonotonic(strip.frames, "avi-dv")
    }

    // MARK: - Failure contracts

    @Test("offsets past EOF are tolerated per-frame — the strip is shorter, not an error")
    func pastEOFOffsetsTolerated() async throws {
        // A 4 s file with a catalog duration of 8 s (stale/wrong catalog
        // row): offsets 4.25…7.75 land past EOF. Those rips may fail —
        // the call must still succeed with whatever landed.
        let path = try TestMediaGenerator.generate(
            container: "mkv",
            streams: .videoOnly,
            videoCodec: "ffv1",
            duration: 4.0,
            prefix: "test_gen_filmstrip_short")
        defer { TestMediaGenerator.cleanup(path) }

        let strip = try await VideoScanModel.renderPreviewFilmstrip(
            path: path,
            container: "Matroska / WebM",
            videoCodec: "ffv1",
            likelyUnanalyzable: false,
            durationSeconds: 8.0)
        // The 8 offsets inside the real 4 s must be there; past-EOF
        // behavior (drop vs last-frame snap) is ffmpeg's business.
        #expect(strip.frames.count >= 8,
                "in-range offsets missing — per-frame tolerance broke: \(strip.frames.count)")
        expectMonotonic(strip.frames, "past-EOF")
    }

    @Test("undecodable file throws noFrameProduced (all frames failed)")
    func garbageFileThrowsNoFrameProduced() async throws {
        let path = tempPath("mkv")
        try Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 37) }).write(
            to: URL(fileURLWithPath: path))
        defer { TestMediaGenerator.cleanup(path) }

        await #expect(throws: PreviewFrameError.noFrameProduced) {
            _ = try await VideoScanModel.renderPreviewFilmstrip(
                path: path,
                container: "Matroska / WebM",
                videoCodec: "ffv1",
                likelyUnanalyzable: false,
                durationSeconds: 8.0)
        }
    }

    @Test("unplannable duration degenerates to a one-frame strip at the ladder's 0.5 s")
    func unplannableDurationDegenerates() async throws {
        let path = try TestMediaGenerator.generate(
            container: "mkv",
            streams: .videoOnly,
            videoCodec: "ffv1",
            duration: 3.0,
            prefix: "test_gen_filmstrip_nodur")
        defer { TestMediaGenerator.cleanup(path) }

        // durationSeconds 0 = "catalog doesn't know" — the renderer must
        // fall back to the plain single-frame ladder, not throw.
        let strip = try await VideoScanModel.renderPreviewFilmstrip(
            path: path,
            container: "Matroska / WebM",
            videoCodec: "ffv1",
            likelyUnanalyzable: false,
            durationSeconds: 0)
        #expect(strip.frames.count == 1)
        #expect(strip.frames[0].offsetSeconds == 0.5)
    }
}

/// Lock-boxed progress collector — onFrameProgress is @Sendable and
/// fires off-main. (For Rick: the repo's "tiny box" convention — a
/// final class + NSLock standing in for a std::mutex-guarded vector.)
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(done: Int, total: Int)] = []

    func record(done: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        events.append((done, total))
    }

    func snapshot() -> [(done: Int, total: Int)] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}
