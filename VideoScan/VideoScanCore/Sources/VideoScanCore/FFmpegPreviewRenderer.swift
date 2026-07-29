// FFmpegPreviewRenderer.swift (VideoScanCore)
// The out-of-process helper's `PreviewMediaRenderer` (2026-07-28, Stage 1):
// an ffmpeg-only renderer that shells out through the SHARED
// `ffmpegRipPreviewFrame` primitive (so the exact ffmpeg command matches the
// app's) and writes through the SHARED PreviewDiskCache (so entries land
// under the exact keys the app reads). The CLI injects this into the same
// PreviewSweepEngine the app drives in-process.
//
// Scope note (deliberate Stage-1 tradeoff): the app's in-process renderer
// ALSO routes AVFoundation-vs-ffmpeg and CONTENT-SCORES the best still /
// drops near-solid filmstrip frames (PreviewFrameScorer, which pulls in
// CoreGraphics rasterization + AppKit and belongs in the app, not the domain
// package). This renderer does neither: it rips via ffmpeg unconditionally
// and keeps every planned frame. The RESULT is still a valid, complete,
// bit-format-identical, app-READABLE cache entry (readability is keyed on
// path|mtime|size + filename shape, all shared) — the only difference is
// which frame you see, not whether the app finds it. Stage 2 can share the
// scorer if picture quality parity is wanted. Documented in the report.
//
// Memory: renderFilmstrip holds at most `frameConcurrency` in-flight ffmpeg
// children plus the frames collected so far (≤ frameCount CGImages at ≤480
// wide ≈ 8 MB), released when the strip crosses back to the executor and is
// encoded+stored. renderBestStill holds one ≤480-wide frame (~0.5 MB).

import Foundation
import CoreGraphics
import os

private let cliRendererLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                    category: "cli-preview-renderer")

public struct FFmpegPreviewRenderer: PreviewMediaRenderer {

    /// Resolved ffmpeg binary path (FFmpegLocator.ffmpegPath in production).
    public let ffmpegPath: String
    /// Longest payload edge — matches PreviewDiskCache.maxPayloadDimension
    /// so this renderer never produces a frame the cache would downscale.
    public let maxDimension: Int
    /// Frames a full-length strip rips.
    public let frameCount: Int
    /// Max concurrent ffmpeg children WITHIN one filmstrip rip. The engine
    /// already serializes per volume (one worker per spindle) and bounds
    /// parallelism across volumes; this bounds the burst inside a single
    /// strip so 16 offsets don't spawn 16 children at once.
    public let frameConcurrency: Int
    /// Per-rip deadline handed to ffmpegRipPreviewFrame.
    public let perFrameDeadlineSeconds: Double?

    public init(ffmpegPath: String = FFmpegLocator.ffmpegPath,
                maxDimension: Int = PreviewDiskCache.maxPayloadDimension,
                frameCount: Int = previewFilmstripDefaultFrameCount,
                frameConcurrency: Int = 3,
                perFrameDeadlineSeconds: Double? = ffmpegPreviewFrameDeadlineSeconds) {
        self.ffmpegPath = ffmpegPath
        self.maxDimension = maxDimension
        self.frameCount = frameCount
        self.frameConcurrency = max(1, frameConcurrency)
        self.perFrameDeadlineSeconds = perFrameDeadlineSeconds
    }

    // MARK: - PreviewMediaRenderer

    /// Best still: single ffmpeg frame at t=0.5s, falling back to t=0 for
    /// sub-half-second clips (the app's single-frame ladder). Maps a missing
    /// ffmpeg onto PreviewRenderError.ffmpegUnavailable (the executor's
    /// environment-fact class); any other throw is a genuine decode failure.
    public func renderBestStill(_ candidate: PreviewSweepCandidate) async throws -> CGImage {
        do {
            return try await ffmpegRipPreviewFrame(
                path: candidate.path,
                seeks: ["0.5", "0"],
                ffmpegPath: ffmpegPath,
                maxDimension: maxDimension,
                deadlineSeconds: perFrameDeadlineSeconds)
        } catch FFmpegPreviewError.ffmpegUnavailable {
            throw PreviewRenderError.ffmpegUnavailable
        }
        // FFmpegPreviewError.noFrameProduced propagates → executor records a
        // genuine still failure (correct: ffmpeg ran and decoded nothing).
    }

    /// Evenly-spaced filmstrip. Plans offsets from the catalog duration
    /// (shared previewFilmstripOffsets), rips each with bounded concurrency,
    /// keeps every frame that decodes. Throws ffmpegUnavailable if the binary
    /// is missing, noFrameProduced if NO offset yields a frame; a partial
    /// strip (some offsets dry) still returns what decoded (same tolerance as
    /// the app's ripper).
    public func renderFilmstrip(_ candidate: PreviewSweepCandidate) async throws -> [PreviewFilmstripFrame] {
        let offsets = previewFilmstripOffsets(durationSeconds: candidate.durationSeconds,
                                              frameCount: frameCount)
        guard !offsets.isEmpty else {
            // Unknown/garbage duration — one frame beats nothing (matches the
            // app's degeneration to the single-frame ladder at t=0.5s).
            do {
                let image = try await ffmpegRipPreviewFrame(
                    path: candidate.path, seeks: ["0.5", "0"],
                    ffmpegPath: ffmpegPath, maxDimension: maxDimension,
                    deadlineSeconds: perFrameDeadlineSeconds)
                return [PreviewFilmstripFrame(offsetSeconds: 0.5, image: image)]
            } catch FFmpegPreviewError.ffmpegUnavailable {
                throw PreviewRenderError.ffmpegUnavailable
            }
        }

        var collected: [(offset: Double, image: CGImage)] = []
        collected.reserveCapacity(offsets.count)

        @Sendable func ripOne(_ offset: Double) async throws -> (Double, CGImage)? {
            do {
                let image = try await ffmpegRipPreviewFrame(
                    path: candidate.path,
                    seeks: [String(format: "%.3f", offset)],
                    ffmpegPath: ffmpegPath,
                    maxDimension: maxDimension,
                    deadlineSeconds: perFrameDeadlineSeconds)
                return (offset, image)
            } catch {
                // A dry offset (seek past EOF, decoder hiccup) just drops out.
                // Cancellation and a missing binary are about the RUN — rethrow
                // so the whole filmstrip aborts correctly.
                if error is CancellationError
                    || (error as? FFmpegPreviewError) == .ffmpegUnavailable {
                    throw error
                }
                return nil
            }
        }

        do {
            try await withThrowingTaskGroup(of: (Double, CGImage)?.self) { group in
                var iterator = offsets.makeIterator()
                for _ in 0..<frameConcurrency {
                    guard let next = iterator.next() else { break }
                    group.addTask { try await ripOne(next) }
                }
                while let landed = try await group.next() {
                    if let landed { collected.append((landed.0, landed.1)) }
                    try Task.checkCancellation()
                    if let next = iterator.next() {
                        group.addTask { try await ripOne(next) }
                    }
                }
            }
        } catch FFmpegPreviewError.ffmpegUnavailable {
            throw PreviewRenderError.ffmpegUnavailable
        }

        guard !collected.isEmpty else {
            cliRendererLog.notice("filmstrip: no frame decoded at any offset — \((candidate.path as NSString).lastPathComponent, privacy: .public)")
            throw FFmpegPreviewError.noFrameProduced
        }
        // Task-group children land out of order — restore timeline order so
        // the strip's index math and the app's scrubber see a monotonic set.
        collected.sort { $0.offset < $1.offset }
        return collected.map { PreviewFilmstripFrame(offsetSeconds: $0.offset, image: $0.image) }
    }
}
