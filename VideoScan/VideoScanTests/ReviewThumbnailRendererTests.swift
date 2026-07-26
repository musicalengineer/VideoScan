// ReviewThumbnailRendererTests.swift
// MEDIA MATRIX + ISOLATION + SENSOR coverage for the review sheet's
// routed thumbnail renderer (fix/review-sheet-performance, 2026-07-26).
//
// Runs the REAL ReviewThumbnailRenderer — real AVFoundation, real
// ffmpeg — against synthetic ffmpeg fixtures (test_* prefix, house
// pattern; see PreviewFrameMediaMatrixTests for the catalog-side twin):
//
//   mp4/h264 + known duration — the catalog-majority case; routes
//     .avFoundation and requests the MIDPOINT frame.
//   mkv/ffv1 + known duration — the archival-master case; routes
//     .ffmpegDirect (AVF has zero Matroska/FFV1 support).
//   STALE duration (catalog says 100 s, file is 2 s) — pins the
//     midpoint → 0.5 → 0 seek ladder: the first ffmpeg rip seeks past
//     EOF (exit 0, no frame written) and the retry must still yield a
//     frame. Without the ladder this throws noFrameProduced.
//   nil meta / sub-1s duration — the shared-core delegation guard
//     (no catalog record, or midpoint indistinct → the routed shared
//     path at t=0.5 s).
//
// ISOLATION: the garbage-file test verifies the failure-recording rules
// the sheet applies (loadRoutedThumbnail is private view code, so the
// testable surface is: the renderer's ERROR TAXONOMY — genuine
// noFrameProduced vs CancellationError vs ffmpegUnavailable — plus a
// PRIVATE ThumbnailFailureStore instance, never the app's shared one).
//
// SENSOR: HoldoutMediaMeta stays a standalone media-facts-only struct —
// the POI-leakage contract's companion pin to the three blindness
// sensors in HoldoutReviewQueueTests (which pin HoldoutReviewRow /
// HoldoutReviewQueue / ConfirmSheetTarget unchanged).

import CoreGraphics
import Foundation
import Testing
@testable import VideoScan

@Suite("Review thumbnail renderer media matrix",
       .serialized,
       .timeLimit(.minutes(4)),
       .enabled(if: TestMediaGenerator.isAvailable))
struct ReviewThumbnailRendererTests {

    /// ffprobe-real container/codec strings (what ScanEngine stamps),
    /// same convention as PreviewFrameMediaMatrixTests.
    private func meta(container: String, codec: String,
                      duration: Double) -> HoldoutMediaMeta {
        HoldoutMediaMeta(container: container, videoCodec: codec,
                         durationSeconds: duration, likelyUnanalyzable: false)
    }

    // MARK: - Matrix: routed midpoint renders

    @Test("mp4/h264 with known duration → midpoint frame via AVFoundation route")
    func mp4KnownDurationRendersMidpoint() async throws {
        let path = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoAndAudio,
            videoCodec: "libx264", audioCodec: "aac",
            duration: 2.0, prefix: "test_gen_review")
        defer { TestMediaGenerator.cleanup(path) }

        let cg = try await ReviewThumbnailRenderer.render(
            path: path, meta: meta(container: "QuickTime / MOV",
                                   codec: "h264", duration: 2.0))
        #expect(cg.width > 0 && cg.height > 0)
        #expect(cg.width <= 480, "review preview must respect the 480px cap (got \(cg.width))")
    }

    @Test("mkv/ffv1 with known duration → frame via ffmpegDirect route")
    func mkvFFV1RendersViaFFmpegDirect() async throws {
        // Route sanity first (pure decision, no I/O): this metadata MUST
        // route away from AVFoundation or the whole test is measuring
        // the wrong tier.
        #expect(PreviewFrameRouter.previewRoute(container: "Matroska / WebM",
                                                videoCodec: "ffv1",
                                                likelyUnanalyzable: false) == .ffmpegDirect)
        let path = try TestMediaGenerator.generate(
            container: "mkv", streams: .videoAndAudio,
            videoCodec: "ffv1", audioCodec: "pcm_s16le",
            duration: 2.0, prefix: "test_gen_review")
        defer { TestMediaGenerator.cleanup(path) }

        let cg = try await ReviewThumbnailRenderer.render(
            path: path, meta: meta(container: "Matroska / WebM",
                                   codec: "ffv1", duration: 2.0))
        #expect(cg.width > 0 && cg.height > 0)
    }

    // MARK: - Stale-duration seek ladder (midpoint → 0.5 → 0)

    @Test("stale catalog duration on the ffmpeg route falls down the seek ladder and still yields a frame")
    func staleDurationFFmpegLadderRecovers() async throws {
        // Catalog says 100 s (midpoint seek = 50 s), real file is 2 s.
        // The first rip seeks past EOF — ffmpeg exits 0 having written
        // NO frame — and the ladder's 0.5 s retry must recover. This is
        // THE pin for the midpoint→0.5→0 ladder; without it, every file
        // whose catalog duration drifted past reality (re-trimmed,
        // re-muxed, corrupt tail) would show the failure placeholder.
        let path = try TestMediaGenerator.generate(
            container: "mkv", streams: .videoOnly,
            videoCodec: "ffv1",
            duration: 2.0, prefix: "test_gen_review_stale")
        defer { TestMediaGenerator.cleanup(path) }

        let cg = try await ReviewThumbnailRenderer.render(
            path: path, meta: meta(container: "Matroska / WebM",
                                   codec: "ffv1", duration: 100.0))
        #expect(cg.width > 0 && cg.height > 0)
    }

    @Test("stale catalog duration on the AVFoundation route still yields a frame")
    func staleDurationAVFRouteStillYieldsFrame() async throws {
        // Same stale-duration hazard on the AVF route: whether AVF
        // clamps the out-of-range request itself or fails into the
        // ffmpeg ladder, the review sheet must get a frame, not a
        // placeholder, for a perfectly healthy file.
        let path = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoOnly,
            videoCodec: "libx264",
            duration: 2.0, prefix: "test_gen_review_stale")
        defer { TestMediaGenerator.cleanup(path) }

        let cg = try await ReviewThumbnailRenderer.render(
            path: path, meta: meta(container: "QuickTime / MOV",
                                   codec: "h264", duration: 100.0))
        #expect(cg.width > 0 && cg.height > 0)
    }

    // MARK: - Shared-core delegation (nil meta / sub-1s duration)

    @Test("nil meta (file not in catalog) → shared routed core still yields a frame")
    func nilMetaDelegatesToSharedCore() async throws {
        let path = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoAndAudio,
            videoCodec: "libx264", audioCodec: "aac",
            duration: 2.0, prefix: "test_gen_review_nilmeta")
        defer { TestMediaGenerator.cleanup(path) }

        let cg = try await ReviewThumbnailRenderer.render(path: path, meta: nil)
        #expect(cg.width > 0 && cg.height > 0)
    }

    @Test("sub-1s duration → shared-core path (midpoint indistinct) yields a frame")
    func subSecondDurationDelegatesToSharedCore() async throws {
        let path = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoOnly,
            videoCodec: "libx264",
            duration: 0.8, prefix: "test_gen_review_short")
        defer { TestMediaGenerator.cleanup(path) }

        let cg = try await ReviewThumbnailRenderer.render(
            path: path, meta: meta(container: "QuickTime / MOV",
                                   codec: "h264", duration: 0.8))
        #expect(cg.width > 0 && cg.height > 0)
    }

    // MARK: - Isolation: failure taxonomy + private failure store

    @Test("garbage file → genuine noFrameProduced, and it qualifies for (private) failure recording")
    func garbageFileRecordsFailureUnderExclusionRules() async throws {
        // A real fixture of non-media bytes with a media extension —
        // routed straight to ffmpeg (mkv meta) so the failure is the
        // deterministic all-three-seeks-fail → noFrameProduced.
        let dir = FileManager.default.temporaryDirectory
        let garbage = dir.appendingPathComponent("test_gen_review_garbage_\(UUID().uuidString.prefix(8)).mkv")
        var junk = Data(capacity: 64 * 1024)
        for i in 0..<(64 * 1024) { junk.append(UInt8((i &* 31) & 0xFF)) }
        try junk.write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }

        var caught: (any Error)?
        do {
            _ = try await ReviewThumbnailRenderer.render(
                path: garbage.path,
                meta: meta(container: "Matroska / WebM", codec: "ffv1", duration: 10.0))
        } catch {
            caught = error
        }
        let err = try #require(caught, "garbage bytes decoded to a frame?!")
        #expect((err as? PreviewFrameError) == .noFrameProduced)

        // The sheet's exclusion rules (loadRoutedThumbnail): record a
        // failure UNLESS it is cancellation or a missing-ffmpeg
        // environment error. This one must qualify…
        let qualifies = !(err is CancellationError)
            && (err as? PreviewFrameError) != .ffmpegUnavailable
        #expect(qualifies, "a genuine decode failure must be negative-cacheable")

        // …and a PRIVATE store instance (never the app's shared one —
        // isolation rule) round-trips it, keyed to the file's identity.
        let store = ThumbnailFailureStore()
        store.recordFailure(forPath: garbage.path)
        #expect(store.isKnownFailure(atPath: garbage.path))
        #expect(!store.isKnownFailure(atPath: garbage.path + ".other"),
                "failure entry leaked onto an unrelated path")

        // Repairing the file (content change → new mtime/size) clears
        // the entry — a fixed file must retry, not rot behind the cache.
        try (junk + Data("repaired".utf8)).write(to: garbage)
        #expect(!store.isKnownFailure(atPath: garbage.path),
                "failure entry survived a file change — repaired files would never retry")
    }

    @Test("cancelled render surfaces CancellationError, never noFrameProduced")
    func cancelledRenderIsNotAFileVerdict() async throws {
        // QA semantic carried from the shared tier: cancellation says
        // NOTHING about the file, so it must never wear the error type
        // that the sheet records into the negative cache.
        let path = try TestMediaGenerator.generate(
            container: "mkv", streams: .videoOnly,
            videoCodec: "ffv1",
            duration: 2.0, prefix: "test_gen_review_cancel")
        defer { TestMediaGenerator.cleanup(path) }

        let task = Task {
            try await ReviewThumbnailRenderer.render(
                path: path, meta: meta(container: "Matroska / WebM",
                                       codec: "ffv1", duration: 2.0))
        }
        task.cancel()
        do {
            _ = try await task.value
            // Won the race and finished — legal; nothing to assert.
        } catch {
            #expect(error is CancellationError,
                    "cancelled render surfaced \(error) — must be CancellationError, or the sheet would poison the negative cache for a good file")
        }
    }
}

// MARK: - Sensor: HoldoutMediaMeta stays media-facts-only

/// Companion to the three blindness sensors in HoldoutReviewQueueTests
/// (row/queue/target field pins, which stay green UNCHANGED on this
/// branch — HoldoutMediaMeta was added as a SEPARATE struct precisely so
/// they wouldn't move). This pins the new struct itself: routing inputs
/// only. If anyone adds a score/prediction field here, the blind holdout
/// pane would gain a model-opinion side channel — fail loudly and force
/// the contract conversation.
@Suite("Holdout media meta sensor")
struct HoldoutMediaMetaSensorTests {

    @Test func mediaMeta_carriesOnlyMediaFacts() {
        let meta = HoldoutMediaMeta(container: "QuickTime / MOV",
                                    videoCodec: "h264",
                                    durationSeconds: 2.0,
                                    likelyUnanalyzable: false)
        let labels = Mirror(reflecting: meta).children.compactMap(\.label)
        #expect(Set(labels) == ["container", "videoCodec",
                                "durationSeconds", "likelyUnanalyzable"])

        let forbidden = ["score", "signal", "candidate", "predict", "detect",
                         "confidence", "rating", "match", "model", "face",
                         "person", "answer", "confirm", "notes"]
        for label in labels {
            for term in forbidden {
                #expect(!label.lowercased().contains(term),
                        "HoldoutMediaMeta.\(label) smells like non-media data (\(term)) — the blind contract allows media facts only")
            }
        }
    }
}
