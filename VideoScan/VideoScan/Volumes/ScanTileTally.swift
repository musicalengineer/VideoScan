import Foundation

/// What one finished probe adds to the Realtime Catalog Scan's counters — the
/// one rule for the stream tiles, the ffprobed card and the Errors card.
///
/// Truth (Rick 2026-11-05): the window showed a red "Failed 11,927" beside
/// "Errors 4". 11,923 of those files failed the media sniff — not media, so
/// ffprobe never ran — but they carry `StreamType.ffprobeFailed` internally so
/// the junk gate drops them, and the tiles counted that tag. A file that is
/// not media, or is still being written, is never a failure and never
/// "ffprobed". C++ analogy: a pure classifier function; the view only reads.
///
/// Codex 2026-11-05 (P0): "ffprobed" was derived from `!wasCacheHit`, so a
/// file that vanished between discovery and probe counted as ffprobed and as
/// "ffprobe failed", and a file found changed AFTER ffprobe ran counted zero.
/// `ranFFprobe` now carries the engine's execution evidence
/// (`ProbeOutcome.ffprobeRan`, set at the one ffprobe call), separately from
/// the classification. A vanished file is "Gone": not media ffprobe judged,
/// not an error the scan made — the next scan looks again, and the
/// unmount-abort trail still runs on its "File not found" note.
enum ScanTileTally {
    /// liveStreamCounts key for files the sniff rejected (not media).
    static let notMediaKey = "notMedia"
    /// liveStreamCounts key for files skipped because they are still being written.
    static let stillBeingWrittenKey = "stillBeingWritten"
    /// liveStreamCounts key for files that vanished between discovery and probe.
    static let goneKey = "gone"

    struct Tally: Equatable {
        /// The tile this file counts under (a StreamType raw value or a key above).
        let tileKey: String
        /// ffprobe really ran on this file (the engine's evidence, never inferred).
        let ranFFprobe: Bool
        /// ffprobe ran and failed: counts on the Errors card and the Failed tile.
        let isProbeError: Bool
    }

    /// - Parameters:
    ///   - ffprobeRan: `ProbeOutcome.ffprobeRan` — did the engine launch ffprobe.
    ///   - fileNotFound: the file was gone before the probe (`ProbeOutcome.fileNotFound`).
    static func tally(streamTypeRaw: String, ffprobeRan: Bool,
                      sniffRejected: Bool, stillBeingWritten: Bool, fileNotFound: Bool) -> Tally {
        if stillBeingWritten {
            // Skipped, never a failure — but ffprobe may have run before the
            // second stat caught the change: that execution still counts.
            return Tally(tileKey: stillBeingWrittenKey, ranFFprobe: ffprobeRan, isProbeError: false)
        }
        if fileNotFound {
            return Tally(tileKey: goneKey, ranFFprobe: false, isProbeError: false)
        }
        if sniffRejected {
            return Tally(tileKey: notMediaKey, ranFFprobe: false, isProbeError: false)
        }
        return Tally(tileKey: streamTypeRaw, ranFFprobe: ffprobeRan,
                     isProbeError: streamTypeRaw == StreamType.ffprobeFailed.rawValue)
    }
}
