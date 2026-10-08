import Foundation

// MARK: - Check Media — picture signals from the full decode (2026-10-07)
//
// Two more things the ONE full-tier picture decode reports on stderr (the
// filters ride along in `CheckMediaRules.signalFilterChain`):
//
//   * LumaRangeScan — `signalstats` + `metadata=print` give each frame's
//     darkest and brightest luma (YMIN / YMAX, in the picture's own bit
//     depth). Compared later with the stream's colour-range label.
//   * DecodeErrorClock — the `metadata` lines also carry each frame's
//     pts_time, so a decoder complaint can be stamped with the time of the
//     last frame that came through (± a few frames: the decoder runs
//     ahead on its threads). "About 12:31" beats "3 errors somewhere".
//
// Both are O(1): running extremes, counts and the first few times.

/// Each frame's darkest/brightest luma, folded into whole-file extremes.
///
/// Only ONE direction is judged from this (CheckMediaRules.checkColour):
/// "labelled full range, but the luma never leaves the limited band".
/// The other direction (full-range content labelled limited) can't be
/// told from YMIN/YMAX: compression ringing pushes single pixels to 0 and
/// 255 on perfectly limited pictures (an mpeg2 SD fixture did, every frame).
struct LumaRangeScan: Sendable, Equatable {
    var frames = 0
    var darkest = Int.max
    var brightest = Int.min

    /// 1 for 8-bit, 4 for 10-bit, 16 for 12-bit… (2^(bits−8)).
    var codeScale = 1

    func adding(line: String) -> LumaRangeScan {
        var s = self
        if let v = MediaSignalScan.int(after: "lavfi.signalstats.YMIN=", in: line) {
            s.darkest = min(s.darkest, v)
        } else if let v = MediaSignalScan.int(after: "lavfi.signalstats.YMAX=", in: line) {
            s.frames += 1
            s.brightest = max(s.brightest, v)
        }
        return s
    }

    /// Luma stays inside the limited (16–235) band on every frame, give or
    /// take lossy-coding overshoot (x264 of a 16–235 picture: 12–240), so
    /// 8–246 at 8 bits. Full-range pictures reach well below 8.
    var staysLimited: Bool {
        frames > 0 && darkest >= 8 * codeScale && brightest <= 246 * codeScale
    }
}

/// Time of the latest decoded frame; error lines stamped with it.
struct DecodeErrorClock: Sendable, Equatable {
    var seconds = 0.0
    var errors = MediaEventLog()

    func adding(line: String) -> DecodeErrorClock {
        var c = self
        if line.contains("[error]") || line.contains("[fatal]") {
            c.errors.note(seconds)
        } else if line.contains(" frame:"), let t = MediaSignalScan.number(after: "pts_time:", in: line) {
            c.seconds = t
        }
        return c
    }
}
