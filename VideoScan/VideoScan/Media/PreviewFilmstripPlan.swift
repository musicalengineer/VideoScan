// PreviewFilmstripPlan.swift
// Filmstrip preview for AVPlayer-unplayable formats (2026-07-27).
//
// Why: clicking play on an MKV/FFV1 record used to hand the file to
// AVPlayer, which shows AVKit's crossed-out play button — AVFoundation
// has zero Matroska/FFV1 support, ever. Instead of a dead player, the
// catalog preview pane enters "filmstrip mode": ~16 ffmpeg-ripped
// frames evenly spaced across the duration, auto-playing at ~1.5 fps
// with a scrubber.
//
// This file is the PURE planning half (same split as
// PreviewBestFramePlan / PreviewFrameScorer): which offsets to rip,
// and which ripped frames to keep after near-solid scoring. No I/O,
// no CoreGraphics beyond the score struct — trivially unit-testable
// without media files. The I/O side (renderPreviewFilmstrip) lives in
// VideoScanModel+Thumbnail.swift with the other frame generators.

import Foundation

enum PreviewFilmstripPlan {

    /// How many frames a full-length strip rips. Now a forwarder to the
    /// shared VideoScanCore constant so the app and the CLI helper agree
    /// (2026-07-28, Stage 1).
    static let defaultFrameCount = previewFilmstripDefaultFrameCount

    /// If near-solid dropping would leave fewer than this many frames,
    /// selectFrames keeps EVERYTHING instead — a strip of blue leader
    /// still tells Rick "this file decodes and is mostly blank", which
    /// beats an empty pane.
    static let minimumKeptFrames = 4

    /// Rip offsets (seconds) for a filmstrip: centered sampling at
    /// (i + 0.5)/count fractions of the duration — never the black
    /// first frame, never past the end (same convention as TrimSheet's
    /// filmstripTimestamp).
    ///
    /// Guard rails (same class as PreviewBestFramePlan.isPlannable —
    /// the `Int((x * 10).rounded())` dedupe below TRAPS on non-finite
    /// input, and a poisoned catalog duration SIGTRAP'd the prewarm on
    /// 2026-07-26): non-finite, ≤ 0, or absurd (> maxSaneDurationSeconds)
    /// durations return [] and the caller degenerates to the plain
    /// single-frame path. For very short files the offsets collapse;
    /// deciseconds-granularity dedupe keeps the result strictly
    /// increasing with no near-identical rips.
    static func offsets(durationSeconds: Double,
                        frameCount: Int = defaultFrameCount) -> [Double] {
        // Forwards to VideoScanCore's shared planner (2026-07-28, Stage 1)
        // so the app and the CLI helper compute identical offsets.
        previewFilmstripOffsets(durationSeconds: durationSeconds, frameCount: frameCount)
    }

    /// Which ripped frames survive into the strip: indices whose score
    /// clears the near-solid threshold. `scores` is parallel to the
    /// ripped frames (nil = the scorer couldn't rasterize — keep it,
    /// benefit of the doubt). Threshold semantics match the scorer's
    /// contract ("combined at or below nearSolidThreshold is
    /// near-solid") and PreviewBestFramePlan.chooseIndex: content is
    /// strictly ABOVE the threshold.
    ///
    /// If fewer than `minimumKeptFrames` survive, ALL indices come
    /// back — a strip of something beats nothing. Result preserves
    /// input order.
    static func selectFrames(scores: [PreviewFrameScorer.FrameScore?],
                             threshold: Double = PreviewFrameScorer.nearSolidThreshold) -> [Int] {
        let kept = scores.indices.filter { index in
            guard let score = scores[index] else { return true }
            return score.combined > threshold
        }
        if kept.count < minimumKeptFrames {
            return Array(scores.indices)
        }
        return kept
    }
}
