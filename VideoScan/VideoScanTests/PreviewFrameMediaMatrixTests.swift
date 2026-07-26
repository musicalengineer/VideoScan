// PreviewFrameMediaMatrixTests.swift
// MEDIA MATRIX + SENSOR dimensions for the catalog-preview routing fix
// (perf/preview-routing, 2026-07-26) — feature-test checklist items 3
// and 5.
//
// Runs the REAL routed single-frame core (renderThumbnailCGImage) —
// real AVFoundation, real ffmpeg — against synthetic ffmpeg fixtures:
//
//   ffv1+pcm / mkv  — the archival-master case this branch exists for;
//                     routes .ffmpegDirect (AVF has zero Matroska/FFV1
//                     support)
//   h264+aac / mp4  — the catalog-majority case; routes .avFoundation
//   prores+pcm / mov — intra-frame QuickTime; routes .avFoundation
//   0.3s ffv1 / mkv — shorter than the 0.5s default seek: exercises the
//                     ffmpeg tier's "-ss 0.5 then -ss 0" retry
//
// Container/codec strings passed to the core are ffprobe's REAL output
// for these fixtures (verified against ffmpeg 8.x: mkv probes as
// format_long_name "Matroska / WebM"; both mp4 and mov probe as
// "QuickTime / MOV") — the same strings ScanEngine stamps into
// record.container / record.videoCodec at scan time.
//
// Pure route-decision logic is covered in PreviewFrameRouteTests; this
// file is the I/O tier.

import Testing
import Foundation
import CoreGraphics
@testable import VideoScan

@Suite("PreviewFrame media matrix",
       .serialized,
       .timeLimit(.minutes(3)),
       .enabled(if: TestMediaGenerator.isAvailable))
struct PreviewFrameMediaMatrixTests {

    // MARK: - Matrix

    @Test("routed core yields a frame for each matrix fixture", arguments: [
        // (fixture container ext, ffmpeg encoder, audio encoder,
        //  ffprobe format_long_name, ffprobe codec_name)
        ("mkv", "ffv1",    "pcm_s16le", "Matroska / WebM", "ffv1"),
        ("mp4", "libx264", "aac",       "QuickTime / MOV", "h264"),
        ("mov", "prores",  "pcm_s16le", "QuickTime / MOV", "prores")
    ])
    func rendersFrameAcrossMatrix(ext: String, encoder: String, audio: String,
                                  probedContainer: String, probedCodec: String) async throws {
        let path = try TestMediaGenerator.generate(
            container: ext,
            streams: .videoAndAudio,
            videoCodec: encoder,
            audioCodec: audio,
            duration: 2.0,
            prefix: "test_gen_preview")
        defer { TestMediaGenerator.cleanup(path) }

        let cg = try await VideoScanModel.renderThumbnailCGImage(
            path: path,
            container: probedContainer,
            videoCodec: probedCodec,
            needsReformat: false)
        // A real decoded frame, scaled within the 480-wide preview cap.
        #expect(cg.width > 0 && cg.height > 0)
        #expect(cg.width <= 480,
                "\(ext)/\(probedCodec): preview must respect the 480px width cap (got \(cg.width))")
    }

    @Test("sub-0.5s clip exercises the -ss 0 retry and still yields a frame")
    func shortClipRetriesFromZero() async throws {
        // 0.3s of FFV1/mkv: the ffmpeg tier's first attempt (-ss 0.5)
        // seeks past EOF and writes no frame; the second attempt (-ss 0)
        // must succeed. Without the retry this throws noFrameProduced.
        let path = try TestMediaGenerator.generate(
            container: "mkv",
            streams: .videoOnly,          // no audio: keeps the fixture tiny
            videoCodec: "ffv1",
            duration: 0.3,
            prefix: "test_gen_preview_short")
        defer { TestMediaGenerator.cleanup(path) }

        let cg = try await VideoScanModel.renderThumbnailCGImage(
            path: path,
            container: "Matroska / WebM",
            videoCodec: "ffv1",
            needsReformat: false)
        #expect(cg.width > 0 && cg.height > 0)
    }

    // MARK: - Sensor (checklist dimension 5)

    /// REGRESSION SENSOR — pins the fix this branch ships. Before the
    /// routing, an FFV1/Matroska record went to AVFoundation, whose
    /// container sniffing ground for 30s to over a minute on real masters
    /// (and forever past the pane's patience) before failing. Routed to
    /// ffmpeg it completes in well under 1s. Budget is a deliberately
    /// generous 10s of wall clock — loose enough for a loaded CI runner
    /// or a Debug build, but orders of magnitude tighter than the old
    /// failure mode. If this test ever trips, the mkv route has fallen
    /// back into AVFoundation (or the ffmpeg tier grew a stall) — do NOT
    /// widen the budget; find the routing regression.
    @Test("mkv/ffv1 preview completes within 10s (was: minutes-long AVF stall)")
    func mkvPreviewNoLongerStalls() async throws {
        let path = try TestMediaGenerator.generate(
            container: "mkv",
            streams: .videoAndAudio,
            videoCodec: "ffv1",
            audioCodec: "pcm_s16le",
            duration: 2.0,
            prefix: "test_gen_preview_sensor")
        defer { TestMediaGenerator.cleanup(path) }

        let clock = ContinuousClock()
        let start = clock.now
        let cg = try await VideoScanModel.renderThumbnailCGImage(
            path: path,
            container: "Matroska / WebM",
            videoCodec: "ffv1",
            needsReformat: false)
        let elapsed = clock.now - start

        #expect(cg.width > 0 && cg.height > 0)
        #expect(elapsed < .seconds(10),
                "mkv/ffv1 preview took \(elapsed) — the routing fix has regressed toward the old AVFoundation stall")
    }
}
