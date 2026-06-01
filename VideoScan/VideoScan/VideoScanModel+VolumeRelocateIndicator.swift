import Foundation

// MARK: - VideoScanModel+VolumeRelocateIndicator
//
// "Relocated to <path>" computation for the Volumes-window editor pane.
//
// Pure / nonisolated builder. Given a source volume (`sourceVolumeRootPath`,
// `sourceVolumeName`) and the full catalog, computes whether any records
// that originated on the source have since landed elsewhere, and where
// the dominant destination root is.
//
// "Originated on the source" matches the Provenance rules:
//   1. `r.originVolume == sourceVolumeName`           (post-relocate marker)
//   2. `r.originalFullPath` starts with `sourceRoot/` (fallback when the
//      originVolume string is missing or doesn't match the path leaf)
//
// Records currently still resident on the source (`fullPath` under
// `sourceRoot/`) are excluded — they haven't moved.
//
// The dominant destination is picked by record count: whichever destination
// volume holds the most relocated records wins. Within that dominant
// volume, the path shown is the longest common path prefix of all the
// destination `fullPath`s — ending in '/' when the prefix lands on a
// directory boundary, so '/Volumes/LaCie/Foo/' reads naturally to the user.
//
// Worst-case memory: O(records) walk + a single dictionary keyed by
// destination volume root. Rick's catalogs are O(10⁵) records; transient
// allocation is tens of MB at most. No streaming concerns.
//
// Swift `nonisolated static` ≈ a free C++ function — no instance state,
// no actor hops.

extension VideoScanModel {

    /// What the Volumes-window editor pane should render in the
    /// "Relocated to" indicator. `nil` means no records have moved (the
    /// indicator should not appear at all).
    struct RelocatedDestinationSummary: Equatable {
        /// Total catalog records that originated on the source volume
        /// (current home elsewhere OR still on the source). Denominator
        /// for the "<moved> of <total>" subtitle.
        let totalOriginRecords: Int
        /// Number of those records whose current `fullPath` lives off the
        /// source volume. Numerator for the subtitle.
        let movedRecordCount: Int
        /// Longest common path prefix of all destination `fullPath`s on
        /// the dominant destination volume. Trailing '/' preserved when
        /// the prefix ends on a directory boundary.
        let dominantDestinationPath: String
        /// Friendly volume name of the dominant destination — first path
        /// component under /Volumes/ (e.g. "LaCieWorkspace") or "/" when
        /// the dominant destination lives outside /Volumes/.
        let dominantDestinationVolume: String
        /// Records on the dominant destination volume.
        let dominantDestinationCount: Int
        /// True when relocated records landed on more than one
        /// destination volume — drives the "(... and N more on other
        /// volumes)" subtitle.
        let hasOtherDestinations: Bool
        /// Number of *other* destination volumes (excluding the dominant
        /// one). Surfaced in the subtitle when non-zero.
        let otherDestinationVolumeCount: Int
    }

    /// Compute the relocated-to summary for a single source volume.
    ///
    /// - Parameters:
    ///   - sourceVolumeRootPath: e.g. `/Volumes/ExternalRAID`. Used for
    ///     prefix-match on `fullPath` and `originalFullPath`.
    ///   - sourceVolumeName: friendly leaf name (e.g. `ExternalRAID`).
    ///     Compared against `r.originVolume`.
    ///   - allRecords: the model's full record array (typically `model.records`).
    /// - Returns: `nil` when no records have moved off the source.
    nonisolated static func relocatedDestinationSummary(
        sourceVolumeRootPath: String,
        sourceVolumeName: String,
        allRecords: [VideoRecord]
    ) -> RelocatedDestinationSummary? {

        let srcPrefix = sourceVolumeRootPath.hasSuffix("/")
            ? sourceVolumeRootPath
            : sourceVolumeRootPath + "/"

        // 1. Filter to records that originated on the source volume.
        //    Excludes records with `originVolume == nil` AND whose
        //    `originalFullPath` either doesn't start with the source root
        //    or is also `nil`.
        var originRecords: [VideoRecord] = []
        originRecords.reserveCapacity(min(allRecords.count, 1024))
        for rec in allRecords {
            if let ov = rec.originVolume, ov == sourceVolumeName {
                originRecords.append(rec)
                continue
            }
            if let original = rec.originalFullPath, original.hasPrefix(srcPrefix) {
                originRecords.append(rec)
                continue
            }
        }
        guard !originRecords.isEmpty else { return nil }

        // 2. Partition by current home: still-on-source vs moved-away.
        //    Records still on the source are part of the denominator but
        //    contribute nothing to the destination grouping.
        var moved: [VideoRecord] = []
        moved.reserveCapacity(originRecords.count)
        for rec in originRecords {
            if rec.fullPath.hasPrefix(srcPrefix) { continue }
            if rec.fullPath.isEmpty { continue }
            moved.append(rec)
        }
        guard !moved.isEmpty else { return nil }

        // 3. Group by destination volume root.
        var byVolume: [String: [String]] = [:]
        for rec in moved {
            let vp = volumeRootForPathPublic(rec.fullPath)
            byVolume[vp, default: []].append(rec.fullPath)
        }

        // 4. Pick dominant volume by record count. Ties broken by
        //    alphabetical volume root so the UI is deterministic.
        let ranked = byVolume
            .map { (root: $0.key, paths: $0.value) }
            .sorted {
                if $0.paths.count != $1.paths.count {
                    return $0.paths.count > $1.paths.count
                }
                return $0.root < $1.root
            }
        guard let top = ranked.first else { return nil }

        // 5. Longest common path prefix within the dominant volume.
        let commonPrefix = longestCommonPathPrefix(top.paths)
        let volumeLeaf: String = {
            if top.root.hasPrefix("/Volumes/") {
                return (top.root as NSString).lastPathComponent
            }
            return top.root
        }()

        let otherCount = max(0, ranked.count - 1)
        return RelocatedDestinationSummary(
            totalOriginRecords: originRecords.count,
            movedRecordCount: moved.count,
            dominantDestinationPath: commonPrefix,
            dominantDestinationVolume: volumeLeaf,
            dominantDestinationCount: top.paths.count,
            hasOtherDestinations: otherCount > 0,
            otherDestinationVolumeCount: otherCount
        )
    }

    // MARK: - Pure helpers (visible for testing)

    /// Longest common path prefix of a list of absolute paths. The result
    /// always lands on a `/` boundary so we never show partial filenames
    /// like `/Volumes/Foo/clip` when the inputs are `clip1.mxf` and
    /// `clip2.mxf` — the common prefix in that case is `/Volumes/Foo/`,
    /// not `/Volumes/Foo/clip`.
    ///
    /// Edge cases:
    ///   - Empty input         → "" (caller should not get here)
    ///   - Single input        → its parent directory + "/"
    ///   - No shared root      → "/" (theoretical; all paths in one
    ///                            volume always share at least the volume
    ///                            root)
    nonisolated static func longestCommonPathPrefix(_ paths: [String]) -> String {
        guard let first = paths.first else { return "" }
        if paths.count == 1 {
            // For a single path, the "shared directory" is just its
            // parent. Preserve trailing slash so the indicator reads
            // naturally.
            let parent = (first as NSString).deletingLastPathComponent
            return parent.hasSuffix("/") ? parent : parent + "/"
        }
        // Standard char-by-char prefix scan against the first string.
        var commonCount = first.count
        for path in paths.dropFirst() {
            commonCount = sharedPrefixCount(first, path, upTo: commonCount)
            if commonCount == 0 { break }
        }
        let prefix = String(first.prefix(commonCount))
        // Trim back to the last '/' so we never show a truncated filename.
        if let lastSlash = prefix.lastIndex(of: "/") {
            // Include the '/' itself.
            return String(prefix[...lastSlash])
        }
        return prefix
    }

    /// Count shared leading characters between two strings, capped at
    /// `limit`. Pure helper for `longestCommonPathPrefix`.
    nonisolated private static func sharedPrefixCount(_ a: String,
                                                       _ b: String,
                                                       upTo limit: Int) -> Int {
        // `Swift.zip` ≈ C++ `std::ranges::views::zip` — pairs corresponding
        // elements; iteration stops at the shorter sequence.
        var i = 0
        for (ca, cb) in zip(a, b) {
            if i >= limit { break }
            if ca != cb { break }
            i += 1
        }
        return i
    }

    /// Public-to-the-extension wrapper around the private `volumeRootForPath`
    /// in `+Provenance`. Kept identical to that file's rule so the two
    /// builders agree on "what is this path's volume root?". Inlined here
    /// to avoid an internal access change in the Provenance file.
    nonisolated static func volumeRootForPathPublic(_ path: String) -> String {
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 { return "/Volumes/" + String(parts[1]) }
        }
        if path.hasPrefix("/Users/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 { return "/Users/" + String(parts[1]) }
        }
        return "/"
    }
}
