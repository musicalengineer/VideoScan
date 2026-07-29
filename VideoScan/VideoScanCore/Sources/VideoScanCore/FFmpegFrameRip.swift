// FFmpegFrameRip.swift (VideoScanCore)
// The ffmpeg single-frame rip PRIMITIVE — one ffmpeg child → one CGImage —
// lifted out of the app's VideoScanModel.renderPreviewFrameViaFFmpeg
// (2026-07-28, Stage 1). Both the app's routed renderer and the CLI helper's
// FFmpegPreviewRenderer call THIS, so the exact ffmpeg invocation (input
// seek, single frame, ≤maxDimension scale) is written once — no drift on the
// command that produces the pixels the cache stores.
//
// The app keeps its higher-level routing (AVFoundation vs ffmpeg) and
// content scoring where they belong (they pull in AVFoundation/AppKit and
// don't belong in the domain package); only the pure ffmpeg-subprocess-to-
// CGImage core moved down here. The app's renderPreviewFrameViaFFmpeg now
// forwards to this and maps FFmpegPreviewError back onto its own
// PreviewFrameError so its media-matrix tests see the identical contract.
//
// Memory: one ≤maxDimension-wide PNG in RAM per call (~0.5 MB decoded),
// deleted from disk on exit — nothing accumulates.

import Foundation
import CoreGraphics
import ImageIO
import os

private let ffmpegRipLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                  category: "ffmpeg-frame-rip")

/// Failures the ffmpeg rip primitive raises.
public enum FFmpegPreviewError: Error, Equatable {
    /// No executable ffmpeg at the resolved path — an environment fact,
    /// not a verdict about the file.
    case ffmpegUnavailable
    /// ffmpeg ran (every seek attempt) but produced no decodable frame.
    case noFrameProduced
}

/// Default deadline on one ffmpeg single-frame rip (seconds). ffmpeg opens
/// hostile containers in milliseconds; the ceiling guards dead-volume reads
/// (ProcessRunner escalates SIGTERM → SIGKILL → abandon past it). Mirrors
/// the app's `ffmpegPreviewDeadlineSeconds`.
public let ffmpegPreviewFrameDeadlineSeconds: Double = 15

/// Rip exactly one frame to a temp PNG (scaled to ≤`maxDimension` wide,
/// height even for the encoder), then load it via ImageIO. `seeks` is a
/// try-in-order ladder; the caller supplies one offset (filmstrip) or the
/// t=0.5s→t=0 fallback ladder (single thumbnail). Same `-ss` BEFORE `-i`
/// keyframe-seek shape the app has always used.
///
/// Throws `FFmpegPreviewError.ffmpegUnavailable` when the binary is missing,
/// `.noFrameProduced` when no seek yields a decodable frame, and rethrows
/// `CancellationError` untouched so a cancelled rip is never misclassified
/// as a file failure by callers.
public func ffmpegRipPreviewFrame(path: String,
                                  seeks: [String],
                                  ffmpegPath: String,
                                  maxDimension: Int = 480,
                                  deadlineSeconds: Double? = ffmpegPreviewFrameDeadlineSeconds)
    async throws -> CGImage {
    guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
        ffmpegRipLog.notice("ffmpeg preview tier unavailable (no executable at \(ffmpegPath, privacy: .public))")
        throw FFmpegPreviewError.ffmpegUnavailable
    }
    let tmpPNG = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vs_preview_\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: tmpPNG) }

    for seek in seeks {
        try Task.checkCancellation()
        let rip = await ProcessRunner.runProcess(
            executable: ffmpegPath,
            arguments: ["-v", "error",
                        // Input seeking (-ss BEFORE -i): keyframe seek then
                        // decode forward — fast, and frame-exactness doesn't
                        // matter for a preview thumbnail.
                        "-ss", seek,
                        "-i", path,
                        "-frames:v", "1",
                        // The quotes are ffmpeg filtergraph quoting (the
                        // comma in min() would otherwise split the graph) —
                        // no shell involved here.
                        "-vf", "scale='min(\(maxDimension),iw)':-2",
                        "-y", tmpPNG.path],
            deadlineSeconds: deadlineSeconds)
        // CANCELLATION, not failure: when the awaiting task is cancelled
        // mid-rip, ProcessRunner SIGTERMs the child and returns exitCode -1
        // — indistinguishable from a genuine decode failure by exit code
        // alone. Surface it as CancellationError HERE so a cancelled rip can
        // never fall through to noFrameProduced and poison a negative cache.
        try Task.checkCancellation()
        // ffmpeg can exit 0 with no frame written (seek past EOF on a very
        // short clip) — the PNG actually decoding is the real success test.
        if rip.exitCode == 0,
           let data = try? Data(contentsOf: tmpPNG),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return cg
        }
        if rip.exitCode != 0 {
            ffmpegRipLog.notice("ffmpeg preview rip failed (-ss \(seek, privacy: .public)) for \((path as NSString).lastPathComponent, privacy: .public): \(rip.stderr, privacy: .public)")
        }
    }
    throw FFmpegPreviewError.noFrameProduced
}
