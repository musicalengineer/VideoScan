// ReviewThumbnailRenderer.swift
// Routed thumbnail generation for the Confirm/Review sheet
// (fix/review-sheet-performance, 2026-07-26).
//
// The bug this kills: ConfirmPersonSheet had its own PRIVATE
// AVAssetImageGenerator path — no routing, no deadline, no ffmpeg
// fallback. For AVF-hostile files (MKV/FFV1 digitized-tape masters,
// common on the LaCie MASTER volume) AVFoundation ground through
// gigabytes of container sniffing with no way to bail, and asking for
// the MIDPOINT of a 20 GB moov-at-end file is the most expensive
// possible AVF request. The catalog side already cured this disease
// (VideoScanModel+Thumbnail.swift, preview routing 2026-07-26); this
// file brings the review sheet onto the same two-tier design.
//
// Why the midpoint tiers are DUPLICATED here rather than added to
// VideoScanModel.renderThumbnailCGImage: that file (plus
// ThumbnailPrecache.swift / PreviewFrameRoute.swift) is owned by a
// parallel branch and must not be modified from this one. The shared
// core is hardwired to t=0.5 s; the review sheet's framing intent is
// the video MIDPOINT (a mid-video frame is far likelier to show a
// person than the black/leader first half-second). So:
//   - duration UNKNOWN (no catalog record) → call the SHARED routed
//     core unchanged (AVF-with-watchdog + ffmpeg fallback at t=0.5).
//   - duration KNOWN → the same two-tier shape, implemented here with
//     the same primitives (PreviewFrameRouter route decision,
//     AVF watchdog via cancelAllCGImageGeneration, ProcessRunner +
//     ToolLocator ffmpeg input-seek rip), but requesting the midpoint.
// RECONCILE NOTE for the Manager: when the parallel thumbnail branch
// lands, giving renderThumbnailCGImage a `requestedSeconds` parameter
// lets renderMidpoint* below collapse into one call.

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import os

private let reviewThumbLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                    category: "poi.holdout-preview")

// MARK: - Media metadata (routing inputs)

/// Catalog-derived MEDIA metadata for one review file — container,
/// codec, duration, and the derived can't-analyze flag. This is
/// explicitly NOT detection/scoring data: nothing here carries a model
/// opinion, so surfacing it to the blind holdout sheet is within the
/// POI-leakage contract (it only steers which decoder rips the
/// thumbnail frame). Kept as its own tiny value struct so the pinned
/// blind types (HoldoutReviewRow / HoldoutReviewQueue /
/// ConfirmSheetTarget) never grow fields — the blindness sensor stays
/// green untouched.
struct HoldoutMediaMeta: Equatable, Sendable {
    var container: String
    var videoCodec: String
    var durationSeconds: Double
    var likelyUnanalyzable: Bool
}

// MARK: - AVF deadline box
//
// Duplicated from VideoScanModel+Thumbnail.swift's private AVFDeadlineBox
// (that file is off-limits to this branch — see header). Lock-guarded
// @unchecked Sendable tiny box per the repo convention
// (ProcessRunner.DeadlineFlag). For Rick: a mutex-guarded bool riding
// along with a shared object pointer.
private final class ReviewAVFDeadlineBox: @unchecked Sendable {
    let generator: AVAssetImageGenerator
    private let lock = NSLock()
    private var fired = false

    init(_ generator: AVAssetImageGenerator) { self.generator = generator }

    func fireDeadline() {
        lock.lock()
        fired = true
        lock.unlock()
        // Pending generation callbacks complete with
        // AVError.operationCancelled — that resumes the awaiting
        // continuation, which is exactly the unblock we need.
        generator.cancelAllCGImageGeneration()
    }

    var deadlineFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

// MARK: - Renderer

enum ReviewThumbnailRenderer {

    /// One routed single-frame render for the review sheet. Midpoint
    /// framing when the catalog knows the duration; otherwise the shared
    /// core's defaults (t=0.5 s). Throws on failure — the caller decides
    /// placeholder vs negative-cache policy.
    ///
    /// `@concurrent` + compiler guard: house convention — under
    /// Approachable Concurrency a plain `nonisolated async` runs on the
    /// CALLER's actor, and this opens media files.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func render(path: String,
                                   meta: HoldoutMediaMeta?) async throws -> CGImage {
        // No catalog record, or duration too short for a distinct
        // midpoint → shared routed path unchanged. Empty metadata means
        // PreviewFrameRouter picks AVFoundation, which is exactly the
        // AVF-with-watchdog + one-ffmpeg-attempt ladder we want for an
        // unknown file.
        guard let meta, meta.durationSeconds > 1.0 else {
            return try await VideoScanModel.renderThumbnailCGImage(
                path: path,
                container: meta?.container ?? "",
                videoCodec: meta?.videoCodec ?? "",
                likelyUnanalyzable: meta?.likelyUnanalyzable ?? false)
        }

        let midpoint = meta.durationSeconds * 0.5
        let route = PreviewFrameRouter.previewRoute(
            container: meta.container,
            videoCodec: meta.videoCodec,
            likelyUnanalyzable: meta.likelyUnanalyzable)
        let filename = (path as NSString).lastPathComponent

        switch route {
        case .ffmpegDirect:
            reviewThumbLog.debug("review route ffmpegDirect @\(String(format: "%.1f", midpoint), privacy: .public)s — \(filename, privacy: .public)")
            return try await renderMidpointViaFFmpeg(path: path, midpointSeconds: midpoint)

        case .avFoundation:
            reviewThumbLog.debug("review route avFoundation @\(String(format: "%.1f", midpoint), privacy: .public)s — \(filename, privacy: .public)")
            do {
                return try await renderMidpointViaAVFoundation(path: path, midpointSeconds: midpoint)
            } catch {
                // A cancelled task must not burn (or mis-attribute) an
                // ffmpeg attempt — propagate cancellation untouched.
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                reviewThumbLog.notice("AVFoundation review preview failed for \(filename, privacy: .public) (\(error.localizedDescription, privacy: .public)) — one ffmpeg attempt")
                return try await renderMidpointViaFFmpeg(path: path, midpointSeconds: midpoint)
            }
        }
    }

    /// Non-throwing wrapper for the read-ahead prefetcher (best-effort
    /// pre-generation; failure policy belongs to the interactive path).
    /// Returns nil on ANY failure including cancellation — callers must
    /// not treat nil as a fact about the file.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func renderOrNil(path: String,
                                        meta: HoldoutMediaMeta?) async -> CGImage? {
        try? await render(path: path, meta: meta)
    }

    // MARK: AVFoundation midpoint tier

    /// Same shape as the shared renderPreviewFrameViaAVFoundation (which
    /// is private and pinned to t=0.5 s): hard deadline over asset open +
    /// generation, watchdog fires cancelAllCGImageGeneration so hostile
    /// container sniffing can't grind unbounded.
    private nonisolated static func renderMidpointViaAVFoundation(
        path: String, midpointSeconds: Double) async throws -> CGImage {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        let box = ReviewAVFDeadlineBox(generator)
        let deadline = VideoScanModel.avfPreviewDeadlineSeconds
        // Watchdog ≈ an armed one-shot timer; cancelling the Task on the
        // success path disarms it.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(deadline))
            box.fireDeadline()
        }
        defer { watchdog.cancel() }

        let time = CMTime(seconds: max(midpointSeconds, 0.5), preferredTimescale: 600)
        do {
            return try await withCheckedThrowingContinuation { cont in
                box.generator.generateCGImageAsynchronously(for: time) { image, _, error in
                    if let image {
                        cont.resume(returning: image)
                    } else {
                        cont.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    }
                }
            }
        } catch {
            if box.deadlineFired {
                reviewThumbLog.notice("AVFoundation review preview timed out (\(Int(deadline))s) — \((path as NSString).lastPathComponent, privacy: .public)")
            }
            throw error
        }
    }

    // MARK: ffmpeg midpoint tier

    /// Same two-tier ffmpeg rip as the shared renderPreviewFrameViaFFmpeg
    /// (private, pinned to 0.5/0 seeks), with the midpoint as the first
    /// seek. Input seeking (-ss BEFORE -i) = keyframe seek + decode
    /// forward — frame-exactness doesn't matter for a review thumbnail.
    /// Retry ladder midpoint → 0.5 → 0 covers stale catalog durations
    /// (seek past EOF) and sub-second clips.
    private nonisolated static func renderMidpointViaFFmpeg(
        path: String, midpointSeconds: Double) async throws -> CGImage {
        let ffmpeg = ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            reviewThumbLog.notice("ffmpeg review preview tier unavailable (no executable at \(ffmpeg, privacy: .public))")
            throw PreviewFrameError.ffmpegUnavailable
        }
        let tmpPNG = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_review_preview_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpPNG) }

        let seeks = [String(format: "%.3f", max(midpointSeconds, 0.0)), "0.5", "0"]
        for seek in seeks {
            try Task.checkCancellation()
            let rip = await ProcessRunner.runProcess(
                executable: ffmpeg,
                arguments: ["-v", "error",
                            "-ss", seek,
                            "-i", path,
                            "-frames:v", "1",
                            // ffmpeg filtergraph quoting (the comma in
                            // min() would otherwise split the graph) —
                            // no shell involved here.
                            "-vf", "scale='min(480,iw)':-2",
                            "-y", tmpPNG.path],
                deadlineSeconds: VideoScanModel.ffmpegPreviewDeadlineSeconds)
            // Cancellation ≠ failure: a SIGTERMed child exits -1 exactly
            // like a decode failure; surface CancellationError here so a
            // cancelled render never reads as noFrameProduced (same QA
            // finding the shared tier carries).
            try Task.checkCancellation()
            // ffmpeg can exit 0 with no frame written (seek past EOF) —
            // the PNG decoding is the real success test.
            if rip.exitCode == 0,
               let data = try? Data(contentsOf: tmpPNG),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return cg
            }
            if rip.exitCode != 0 {
                reviewThumbLog.notice("ffmpeg review preview rip failed (-ss \(seek, privacy: .public)) for \((path as NSString).lastPathComponent, privacy: .public): \(rip.stderr, privacy: .public)")
            }
        }
        throw PreviewFrameError.noFrameProduced
    }
}
