// PreviewFilmstripOffsets.swift (VideoScanCore)
// The PURE filmstrip rip-offset math, lifted from the app's
// PreviewFilmstripPlan (2026-07-28, Stage 1) so the app and the CLI helper
// plan the SAME evenly-spaced offsets. The app's `PreviewFilmstripPlan.offsets`
// / `.defaultFrameCount` now forward here; near-solid frame SELECTION stays
// app-side (it needs PreviewFrameScorer / CoreGraphics — the CLI just rips
// the full planned set, which is a complete, app-readable strip).

import Foundation

/// How many frames a full-length strip rips. 16 at ~0.65 s/frame gives a
/// ~10 s looping preview — enough to tell a birthday party from a blank
/// tape without approaching real playback cost.
public let previewFilmstripDefaultFrameCount = 16

/// Rip offsets (seconds) for a filmstrip: centered sampling at
/// (i + 0.5)/count fractions of the duration — never the black first frame,
/// never past the end.
///
/// Guard rails (the `Int((x * 10).rounded())` dedupe below TRAPS on
/// non-finite input, and a poisoned catalog duration SIGTRAP'd the prewarm
/// on 2026-07-26): non-finite, ≤ 0, or absurd (> previewMaxSaneDurationSeconds)
/// durations return [] and the caller degenerates to the plain single-frame
/// path. For very short files the offsets collapse; deciseconds-granularity
/// dedupe keeps the result strictly increasing with no near-identical rips.
public func previewFilmstripOffsets(durationSeconds: Double,
                                    frameCount: Int = previewFilmstripDefaultFrameCount) -> [Double] {
    guard durationSeconds.isFinite,
          durationSeconds > 0,
          durationSeconds <= previewMaxSaneDurationSeconds,
          frameCount > 0 else {
        return []
    }
    var seen = Set<Int>()
    var offsets: [Double] = []
    for i in 0..<frameCount {
        let offset = durationSeconds * (Double(i) + 0.5) / Double(frameCount)
        // Dedupe key: offset in deciseconds. Monotonic generation + dedupe
        // ⇒ strictly increasing result; offset ≥ 0 follows from duration > 0.
        if seen.insert(Int((offset * 10).rounded())).inserted {
            offsets.append(offset)
        }
    }
    return offsets
}
