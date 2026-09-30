import Foundation

// MARK: - Derived-file naming convention
//
// Rick 2026-06-14: every Media File Operation that produces a derived
// file uses the same naming convention so they're (a) discoverable in
// Finder via `*.vs.*`, (b) self-describing (codec, timestamp, optional
// purpose), and (c) inheritance-friendly — future recipes get the
// format for free.
//
// Convention:
//   <stem>.vs.<codec>.<YYYYMMDD-HHMMSS>.<ext>
//
// With an optional purpose segment between codec and timestamp:
//   <stem>.vs.<purpose>.<codec>.<YYYYMMDD-HHMMSS>.<ext>
//
// Examples:
//   thanksgiving_1998.vs.hevc.20260614-1645.mov
//   donna_birthday.vs.archive.prores422.20260615-0901.mov
//   xmas_2003.vs.captions.qwen2vl.20260615-1532.srt
//
// `vs` is the namespace tag so `find . -name "*.vs.*"` finds every
// VideoScan-derived file across all volumes.

/// Build a URL for a derived file beside the source, using the
/// project-wide naming convention.
///
/// - Parameters:
///   - source: the original VideoRecord's URL.
///   - codec: short codec tag — "hevc", "h264", "prores422", "aac", etc.
///     Used as the format hint in Finder + as a filter key in the
///     catalog when we surface "show all HEVC derivatives".
///   - purpose: optional verb segment — "archive", "cleanup-vhs",
///     "analyze-source", "captions", "transcript". When nil, the
///     name has no purpose segment.
///   - ext: output extension WITHOUT the leading dot. Defaults to
///     "mp4" for video, but recipes producing other types (srt,
///     json, wav) override.
///   - timestamp: Defaults to the current time. Tests can inject a
///     fixed value for determinism.
///
/// Returns nil if the source URL has no directory or stem (defensive;
/// shouldn't happen on a real catalog record).
func derivedFileURL(
    source: URL,
    codec: String,
    purpose: String? = nil,
    ext: String = "mp4",
    timestamp: Date = Date()
) -> URL {
    let stem = source.deletingPathExtension().lastPathComponent
    guard !stem.isEmpty else { return source }
    let dir = source.deletingLastPathComponent()
    let ts = derivedFileTimestampFormatter.string(from: timestamp)
    let segments: [String]
    if let purpose, !purpose.isEmpty {
        segments = [stem, "vs", purpose, codec, ts]
    } else {
        segments = [stem, "vs", codec, ts]
    }
    let base = segments.joined(separator: ".")
    return dir.appendingPathComponent("\(base).\(ext)")
}

/// Deterministic timestamp formatter: YYYYMMDD-HHMMSS in local time.
/// Local rather than UTC so derived files sort alongside the
/// originals in Finder by the user's wall clock — important for
/// recovery-day photo workflows where the user remembers "I made
/// that at 4:30 yesterday."
private let derivedFileTimestampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    f.timeZone = .current
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()
