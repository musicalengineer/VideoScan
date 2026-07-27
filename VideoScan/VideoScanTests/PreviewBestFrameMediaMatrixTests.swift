// PreviewBestFrameMediaMatrixTests.swift
// MEDIA MATRIX + SENSOR dimensions for the content-aware best-frame
// pass (perf/preview-disk-cache commit 2, 2026-07-26) — checklist
// items 3 and 5. Companion to PreviewFrameMediaMatrixTests (which
// covers the single-frame core this pass falls back to).
//
// Runs the REAL renderBestPreviewCGImage — real AVFoundation batch
// generation, real ffmpeg candidate rips — against synthetic fixtures:
//
//   blue-leader mp4/h264 — 3 s of solid blue then 5 s of testsrc: the
//       VHS-lead-in case this feature exists for. The 50% candidate
//       (t=4) lands in content; the pick must skip the leader.
//   all-blue mp4/h264   — wall-to-wall leader: the fallback rule; a
//       decodable file must NEVER come back frameless.
//   mkv/ffv1            — Matroska routes .ffmpegDirect, exercising
//       the per-offset ffmpeg candidate loop (the archival masters).
//   sub-2s mp4          — degenerates to the single-frame path.
//
// Fixture note: the h264 fixtures are encoded with -g 12 (a keyframe
// every ~half second). AVAssetImageGenerator is used with DEFAULT time
// tolerances (nearest keyframe); without dense keyframes every
// candidate request would snap to the file's single leading IDR and
// the test would measure keyframe placement, not frame selection.

import Testing
import Foundation
import CoreGraphics
import Darwin
@testable import VideoScan

@Suite("PreviewBestFrame media matrix",
       .serialized,
       .timeLimit(.minutes(3)),
       .enabled(if: TestMediaGenerator.isAvailable))
struct PreviewBestFrameMediaMatrixTests {

    // MARK: - Fixture generation

    private static let ffmpegPath: String = {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "ffmpeg"
    }()

    /// h264/mp4 fixture: `leaderSeconds` of solid blue, then
    /// `contentSeconds` of testsrc bars, concatenated. Dense keyframes
    /// (-g 12) — see the file-header fixture note.
    private func generateBlueLeaderFixture(leaderSeconds: Double,
                                           contentSeconds: Double) throws -> String {
        let out = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("test_gen_bestframe_\(UUID().uuidString.prefix(8)).mp4")
        var args = ["-y", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "color=c=blue:s=320x240:r=25:d=\(leaderSeconds)"]
        if contentSeconds > 0 {
            args += ["-f", "lavfi", "-i", "testsrc=duration=\(contentSeconds):size=320x240:rate=25",
                     "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]"]
        }
        args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "12", out]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.ffmpegPath)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: out) else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? "?"
            throw TestMediaGenerator.GeneratorError.ffmpegFailed(
                status: proc.terminationStatus, message: msg)
        }
        return out
    }

    // MARK: - Blue leader (the feature's reason to exist)

    @Test("blue-leader mp4: best-frame pass skips the leader and returns content")
    func blueLeaderSkipped() async throws {
        // 8 s total → candidates [0.5, 0.8, 2.0, 4.0]; the first three
        // land in the 3 s leader, only t=4 lands in testsrc content.
        let path = try generateBlueLeaderFixture(leaderSeconds: 3, contentSeconds: 5)
        defer { TestMediaGenerator.cleanup(path) }

        let cg = try await VideoScanModel.renderBestPreviewCGImage(
            path: path,
            container: "QuickTime / MOV",
            videoCodec: "h264",
            likelyUnanalyzable: false,
            durationSeconds: 8.0)

        let score = try #require(PreviewFrameScorer.score(cg))
        #expect(score.combined > PreviewFrameScorer.nearSolidThreshold,
                "best-frame pass returned a near-solid frame (score \(score.combined)) — it cached the blue leader")
        // Belt and suspenders: the frame is visibly not the blue leader.
        let mean = PreviewTestImages.meanRGB(cg)
        #expect(!(mean.b > 180 && mean.r < 80 && mean.g < 80),
                "returned frame is solid blue (\(mean)) — leader not skipped")
    }

    // MARK: - All-blue (the fallback rule)

    @Test("wall-to-wall blue mp4: still returns a frame (never no-preview for decodable files)")
    func allBlueStillReturnsFrame() async throws {
        let path = try generateBlueLeaderFixture(leaderSeconds: 8, contentSeconds: 0)
        defer { TestMediaGenerator.cleanup(path) }

        // Must NOT throw — every candidate is near-solid, so the
        // fallback (25% = t=2) frame is kept.
        let cg = try await VideoScanModel.renderBestPreviewCGImage(
            path: path,
            container: "QuickTime / MOV",
            videoCodec: "h264",
            likelyUnanalyzable: false,
            durationSeconds: 8.0)
        #expect(cg.width > 0 && cg.height > 0)
        // And it IS the boring blue file's honest content.
        let mean = PreviewTestImages.meanRGB(cg)
        #expect(mean.b > 150 && mean.r < 100,
                "all-blue file should yield a blue frame, got \(mean)")
    }

    // MARK: - mkv/ffv1 (ffmpeg candidate route)

    @Test("mkv/ffv1 goes through the per-offset ffmpeg candidate loop and yields a frame")
    func mkvFfv1ThroughCandidateLoop() async throws {
        let path = try TestMediaGenerator.generate(
            container: "mkv",
            streams: .videoOnly,
            videoCodec: "ffv1",
            duration: 8.0,
            prefix: "test_gen_bestframe_ffv1")
        defer { TestMediaGenerator.cleanup(path) }

        let cg = try await VideoScanModel.renderBestPreviewCGImage(
            path: path,
            container: "Matroska / WebM",   // routes .ffmpegDirect
            videoCodec: "ffv1",
            likelyUnanalyzable: false,
            durationSeconds: 8.0)
        #expect(cg.width > 0 && cg.height > 0)
        // testsrc content: every candidate clears the threshold, so the
        // winner must too.
        let score = try #require(PreviewFrameScorer.score(cg))
        #expect(score.combined > PreviewFrameScorer.nearSolidThreshold)
    }

    // MARK: - Sub-2s degeneration

    @Test("sub-2s clip degenerates to the single-frame path and still yields a frame")
    func shortClipDegeneratesToSingleFrame() async throws {
        let path = try TestMediaGenerator.generate(
            container: "mp4",
            streams: .videoOnly,
            videoCodec: "libx264",
            duration: 1.0,
            prefix: "test_gen_bestframe_short")
        defer { TestMediaGenerator.cleanup(path) }

        let cg = try await VideoScanModel.renderBestPreviewCGImage(
            path: path,
            container: "QuickTime / MOV",
            videoCodec: "h264",
            likelyUnanalyzable: false,
            durationSeconds: 1.0)   // < minDurationForCandidates
        #expect(cg.width > 0 && cg.height > 0)
    }

    // MARK: - Cancellation propagation (SENSOR)

    /// REGRESSION SENSOR — a cancelled best-frame pass must surface
    /// CancellationError, never a swallowed failure. This is the same
    /// contract the negative-cache poison fix relies on for the
    /// single-frame path (PreviewCachePoisonSensorTests); the candidate
    /// loop added its own catch site (`catch { if error is
    /// CancellationError ... throw }`) and this pins that rethrow. Uses
    /// the FIFO technique from the poison sensors: ffmpeg blocks
    /// forever reading a named pipe, guaranteeing the cancel lands
    /// MID-RIP. (For Rick: mkfifo(2) — reader blocks until a writer
    /// appears, which never happens.)
    @Test("cancelled best-frame pass propagates CancellationError, not a swallowed failure")
    func cancelledPassPropagatesCancellation() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_gen_bestframe_cancel_\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifoPath = dir.appendingPathComponent("blocking.mkv").path
        try #require(mkfifo(fifoPath, 0o600) == 0)

        let render = Task {
            try await VideoScanModel.renderBestPreviewCGImage(
                path: fifoPath,
                container: "Matroska / WebM",   // ffmpegDirect → candidate loop
                videoCodec: "ffv1",
                likelyUnanalyzable: false,
                durationSeconds: 8.0)           // 4 candidates planned
        }

        // Wait until ffmpeg is observably mid-rip on the fifo before
        // cancelling — cancelling earlier would only exercise the
        // loop-top check, not the mid-rip path.
        var started = false
        for _ in 0..<100 {   // up to 10 s; spawn is normally <100 ms
            if ffmpegAlive(matching: fifoPath) { started = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(started, "ffmpeg never started ripping the fifo — did mkv stop routing ffmpegDirect?")

        render.cancel()

        switch await render.result {
        case .success:
            Issue.record("a rip of a never-delivering fifo cannot succeed")
        case .failure(let error):
            #expect(error is CancellationError,
                    "cancelled best-frame pass must throw CancellationError, got: \(error)")
        }
    }

    /// True while an ffmpeg child whose argv mentions `needle` is
    /// alive — same pgrep -f probe as PreviewCachePoisonSensorTests;
    /// the UUID in the fifo path makes the needle collision-proof.
    private func ffmpegAlive(matching needle: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", needle]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
