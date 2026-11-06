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
enum ScanTileTally {
    /// liveStreamCounts key for files the sniff rejected (not media).
    static let notMediaKey = "notMedia"
    /// liveStreamCounts key for files skipped because they are still being written.
    static let stillBeingWrittenKey = "stillBeingWritten"

    struct Tally: Equatable {
        /// The tile this file counts under (a StreamType raw value or a key above).
        let tileKey: String
        /// ffprobe really ran (a cache miss on a file that passed the sniff).
        let ranFFprobe: Bool
        /// ffprobe ran and failed: counts on the Errors card and the Failed tile.
        let isProbeError: Bool
    }

    static func tally(streamTypeRaw: String, wasCacheHit: Bool,
                      sniffRejected: Bool, stillBeingWritten: Bool) -> Tally {
        if stillBeingWritten {
            return Tally(tileKey: stillBeingWrittenKey, ranFFprobe: false, isProbeError: false)
        }
        if sniffRejected {
            return Tally(tileKey: notMediaKey, ranFFprobe: false, isProbeError: false)
        }
        return Tally(tileKey: streamTypeRaw, ranFFprobe: !wasCacheHit,
                     isProbeError: streamTypeRaw == StreamType.ffprobeFailed.rawValue)
    }
}
