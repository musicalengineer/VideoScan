import Foundation

// MARK: - VideoScanModel+Relocate
//
// Implements the "Relocate Volume" feature: copy every catalogued file
// from a flaky source volume (e.g. an aging external HDD) onto a folder
// inside a healthier destination volume, rewrite each VideoRecord's
// fullPath to the new location, and preserve provenance via the new
// originalFullPath / originVolume fields.
//
// Source volume is NEVER deleted by this feature — Rick disconnects the
// old drive at his discretion after verifying the migration. See
// docs/relocate_volume_plan.md for the full spec.

// MARK: - Public types

/// Caller-facing options for a relocate run.
struct RelocateOptions {
    /// Absolute path of the source volume root, e.g. "/Volumes/Mini2TB".
    /// Records whose `fullPath` starts with "<sourceVolumeRootPath>/"
    /// (note trailing slash) are in scope.
    var sourceVolumeRootPath: String

    /// Destination directory under a healthier drive. Subdirectory
    /// structure under the source root is preserved beneath this folder.
    var destinationRoot: URL

    /// Concurrent file copies. Default 1 — the source is assumed slow
    /// and parallel reads make HDD thrashing worse. Caller can raise
    /// for SSD-to-SSD migrations.
    var maxConcurrency: Int = 1

    /// Reconcile + report buckets, then exit without copying or
    /// committing. Useful for previewing the impact before commit.
    var dryRun: Bool = false

    /// Skip records that have already been relocated once
    /// (`originalFullPath != nil`). Set false to force re-attempts on
    /// previously salvage-failed records that you've since worked around.
    var skipAlreadyRelocated: Bool = true
}

/// Error surface for the public relocate entry point.
enum RelocateError: Error, Equatable {
    case sourceUnreachable(String)
    case destinationUnwritable(String)
    case insufficientSpace(needed: Int64, free: Int64)
    case noRecordsInScope
}

// MARK: - Pure helpers (testable without disk)

extension VideoScanModel {

    /// Records whose `fullPath` is under `sourceVolumeRootPath`.
    /// Matching uses a trailing slash so `/Volumes/Mini2TB-backup` does
    /// not false-match `/Volumes/Mini2TB`.
    static func recordsScoped(to sourceVolumeRootPath: String,
                              in all: [VideoRecord]) -> [VideoRecord] {
        let prefix = sourceVolumeRootPath.hasSuffix("/")
            ? sourceVolumeRootPath
            : sourceVolumeRootPath + "/"
        return all.filter { $0.fullPath.hasPrefix(prefix) }
    }

    /// Translate a source file's absolute path to its destination path
    /// under `destRoot`, preserving the subdirectory layout beneath
    /// `sourceRoot`. Trailing slashes on either input are normalized.
    static func rewrittenPath(forSourcePath src: String,
                              sourceRoot: String,
                              destRoot: String) -> String {
        let normalizedSourceRoot = sourceRoot.hasSuffix("/")
            ? String(sourceRoot.dropLast())
            : sourceRoot
        let normalizedDestRoot = destRoot.hasSuffix("/")
            ? String(destRoot.dropLast())
            : destRoot
        // src must start with "<normalizedSourceRoot>/". If not, fall
        // back to placing the bare filename under destRoot (defensive —
        // should never happen given recordsScoped filtering).
        let withSlash = normalizedSourceRoot + "/"
        guard src.hasPrefix(withSlash) else {
            let leaf = (src as NSString).lastPathComponent
            return normalizedDestRoot + "/" + leaf
        }
        let relative = String(src.dropFirst(withSlash.count))
        return normalizedDestRoot + "/" + relative
    }

    /// Suggest a destination folder name like "from-Mini2TB-20260530".
    /// Stable across the same day; collisions are the user's problem to
    /// resolve via the dest-folder picker.
    static func suggestDestinationName(forSourceVolumeName name: String,
                                       now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone.current
        let stamp = fmt.string(from: now)
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
                          .replacingOccurrences(of: " ", with: "_")
        return "from-\(cleaned)-\(stamp)"
    }
}
