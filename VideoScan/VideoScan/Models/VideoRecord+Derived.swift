// VideoRecord+Derived.swift
// VideoRecord's computed / derived properties — stream-type accessor,
// table sort keys, volume-label derivation, and the value heuristics —
// extracted verbatim from the VideoRecord class body in Models.swift
// (refactor 2026-06-26, model decomposition step 1). In step 2 the
// SwiftUI color / archive-health UI accessors were lifted out into
// ModelsUI/VideoRecord+Presentation.swift, leaving this file
// Foundation-only.
//
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state, methods share the same `self`.)

import Foundation

extension VideoRecord {

    var hasAvidMetadata: Bool {
        !avidClipName.isEmpty || !avidMobID.isEmpty
    }

    /// Convenience: true when this record has been soft-removed from the
    /// catalog. Used by UI filtering + styling. `// guard let` ≈ C++ early
    /// return after a null check.
    var isPurged: Bool { purgedAt != nil }

    /// True when EITHER the stored needsReformat flag is set OR the
    /// codec strings match a known-problematic legacy codec. The
    /// catalog UI's red `!` badge reads this so already-cataloged
    /// files surface immediately, without waiting for the next VLM
    /// run. See UnplayableLegacyCodecs.swift for the criteria.
    var isLikelyUnanalyzable: Bool {
        if needsReformat { return true }
        return hasUnplayableLegacyCodec(videoCodec: videoCodec, audioCodec: audioCodec)
    }

    /// Tooltip text for the badge. nil when the file's codecs are
    /// fine AND no failed-VLM marker is set.
    var unanalyzableReason: String? {
        if let codecReason = unplayableLegacyReason(videoCodec: videoCodec, audioCodec: audioCodec) {
            return codecReason
        }
        if needsReformat {
            return "The analyzer couldn't decode this file's video stream — needs reformat to be analyzed."
        }
        return nil
    }

    /// 0–100 heuristic for "how valuable is this file likely to be?"
    /// Long old QuickTime files with audio score highest — the
    /// signature of deliberately-digitized family footage. Used to
    /// prioritize the reformat queue.
    var analyzeValueScore: Int {
        return VideoScan.analyzeValueScore(
            durationSeconds: durationSeconds,
            hasAudio: streamType == .videoAndAudio || streamType == .audioOnly,
            hasLegacyCodec: hasUnplayableLegacyCodec(videoCodec: videoCodec, audioCodec: audioCodec),
            container: container,
            fileMTime: dateModifiedRaw
        )
    }

    var streamType: StreamType {
        StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed
    }

    // MARK: - Sort keys
    //
    // SwiftUI Table's `value:` parameter on TableColumn requires a KeyPath
    // whose value type conforms to `Comparable`. Date? and parsed strings
    // don't qualify directly, so these computed keys give the table a stable
    // numeric/Date sort field while the cell content keeps showing the
    // human-friendly string.

    /// Sort key for the catalog's People column. Confirmed names come
    /// first (alphabetically), then suspected names with a "~" prefix
    /// so they sort after letters in ASCII. Records with no tags at all
    /// get the highest Unicode replacement char so they sort to the
    /// bottom in ascending order — clicking the column header surfaces
    /// "untagged → tagged" or "Donna → Tim → untagged" depending on
    /// direction. Empty string would have sorted them to the top
    /// instead, which is rarely what users want when the column reads
    /// "People".
    var peopleSortKey: String {
        let confirmed = detectedPeople.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
            .joined(separator: ", ")
        let suspected = suspectedPeople.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
            .joined(separator: ", ")
        if confirmed.isEmpty && suspected.isEmpty {
            return "\u{FFFD}"  // U+FFFD sorts after letters → untagged rows fall to the bottom ascending
        }
        if confirmed.isEmpty {
            return "~" + suspected   // "~" sorts after letters → suspected-only after confirmed
        }
        if suspected.isEmpty {
            return confirmed
        }
        return confirmed + " ~" + suspected
    }

    /// Resolution sorted by total pixel count. Files with no resolution
    /// (audio-only, ffprobe failed) sort to the bottom.
    var pixelCount: Int {
        let parts = resolution.lowercased().split(separator: "x")
        guard parts.count == 2,
              let w = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Int(parts[1].trimmingCharacters(in: .whitespaces))
        else { return 0 }
        return w * h
    }

    /// Non-optional creation date for sorting; missing dates sort to the
    /// far past so descending order surfaces real dates first.
    var dateCreatedSortKey: Date { dateCreatedRaw ?? .distantPast }

    /// Same idea for modification date.
    var dateModifiedSortKey: Date { dateModifiedRaw ?? .distantPast }

    /// Human-readable volume name. Prefers the name captured at scan time
    /// (e.g. "Macintosh HD", "LaCieWorkspace") which works even when the
    /// volume is offline. Falls back to path-component parsing for legacy
    /// records scanned before this field existed.
    var volumeName: String {
        // A relocated record physically lives wherever fullPath now points —
        // not where it was originally scanned. originalFullPath is set only by
        // Relocate, so for those records derive the volume from the CURRENT
        // path. Without this the catalog Volume column keeps showing the origin
        // volume (files moved RicksBackups → LaCie still read "RicksBackups").
        // volumeName(forPath:) is pure string parsing, so it stays correct even
        // when the destination volume is offline. (Bug found 2026-06-19 while
        // spot-testing the RicksBackups → LaCie salvage move: 1,474 relocated
        // files showed their old volume in the Volume column.)
        if originalFullPath != nil {
            let derived = VolumeReachability.volumeName(forPath: fullPath)
            if !derived.isEmpty { return derived }
        }
        if !scanContext.volumeName.isEmpty { return scanContext.volumeName }
        return VolumeReachability.volumeName(forPath: fullPath)
    }

    /// Disambiguated label for the catalog "Volume" column. Returns just
    /// the volume name for whole-volume scans, or "Volume > Folder" for
    /// folder scans. The " > " ASCII breadcrumb reads naturally and is
    /// trivially typeable/searchable — used everywhere subfolder scans need
    /// volume context (catalog column, inspector, scan-target menus).
    ///
    /// Legacy records (no `scanRootLabel`) read the same as before — just
    /// the volume name. Only newly scanned or re-scanned subfolder records
    /// pick up the combined form.
    var displayVolumeLabel: String {
        let vol = volumeName
        let root = scanContext.scanRootLabel
        // Defensive guards:
        //   - empty root  → whole-volume scan or legacy record → vol alone
        //   - root == vol → degenerate case (scan root happened to equal the
        //                   volume name, e.g. capture stamped the volume root)
        //                   → vol alone, no " > " duplication
        //   - empty vol   → fall back to root so the column is never blank
        guard !root.isEmpty, root != vol else { return vol }
        guard !vol.isEmpty else { return root }
        return "\(vol) > \(root)"
    }
}
