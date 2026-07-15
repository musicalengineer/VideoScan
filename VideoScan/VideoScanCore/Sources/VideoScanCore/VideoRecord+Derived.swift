// VideoRecord+Derived.swift
// VideoRecord's computed / derived properties — stream-type accessor,
// table sort keys, and the value heuristics — extracted verbatim from the
// VideoRecord class body in Models.swift (refactor 2026-06-26, model
// decomposition step 1). In step 2 the SwiftUI color / archive-health UI
// accessors were lifted out into ModelsUI/VideoRecord+Presentation.swift,
// leaving this file Foundation-only.
//
// Package-extraction note (2026-06-26): when VideoRecord moved into the
// VideoScanCore package, the two volume-LABEL derivations (`volumeName`,
// `displayVolumeLabel`) stayed app-side in
// ModelsUI/VideoRecord+DerivedApp.swift because they depend on
// VolumeReachability — app infrastructure that can't follow into the pure
// domain package. Everything in THIS file is Foundation-only, so it lives
// in the package and is `public` so the app target (which sees the package
// via @_exported) keeps reading these members unchanged.
//
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state, methods share the same `self`.)

import Foundation

extension VideoRecord {

    public var hasAvidMetadata: Bool {
        !avidClipName.isEmpty || !avidMobID.isEmpty
    }

    /// Convenience: true when this record has been soft-removed from the
    /// catalog. Used by UI filtering + styling. `// guard let` ≈ C++ early
    /// return after a null check.
    public var isPurged: Bool { purgedAt != nil }

    /// True when the record was set aside by the video-only catalog scope
    /// (stills / music / audio with no video link — 2026-07-15). Hidden
    /// from default views like purged rows, but a DISTINCT reversible
    /// state: "Show set-aside files" reveals these, "Show removed"
    /// reveals purged. Restore is `setAsideReason = nil`.
    public var isSetAside: Bool { setAsideReason != nil }

    /// True when EITHER the stored needsReformat flag is set OR the
    /// codec strings match a known-problematic legacy codec. The
    /// catalog UI's red `!` badge reads this so already-cataloged
    /// files surface immediately, without waiting for the next VLM
    /// run. See UnplayableLegacyCodecs.swift for the criteria.
    public var isLikelyUnanalyzable: Bool {
        if needsReformat { return true }
        return hasUnplayableLegacyCodec(videoCodec: videoCodec, audioCodec: audioCodec)
    }

    /// Tooltip text for the badge. nil when the file's codecs are
    /// fine AND no failed-VLM marker is set.
    public var unanalyzableReason: String? {
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
    public var analyzeValueScore: Int {
        // Free function now lives in the same module (UnplayableLegacyCodecs.swift
        // moved into the package). Module-qualify so the call resolves to the
        // free function, not this same-named computed property — mirrors the
        // original `VideoScan.analyzeValueScore(...)` disambiguation.
        return VideoScanCore.analyzeValueScore(
            durationSeconds: durationSeconds,
            hasAudio: streamType == .videoAndAudio || streamType == .audioOnly,
            hasLegacyCodec: hasUnplayableLegacyCodec(videoCodec: videoCodec, audioCodec: audioCodec),
            container: container,
            fileMTime: dateModifiedRaw
        )
    }

    public var streamType: StreamType {
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
    public var peopleSortKey: String {
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
    public var pixelCount: Int {
        let parts = resolution.lowercased().split(separator: "x")
        guard parts.count == 2,
              let w = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Int(parts[1].trimmingCharacters(in: .whitespaces))
        else { return 0 }
        return w * h
    }

    /// Non-optional creation date for sorting; missing dates sort to the
    /// far past so descending order surfaces real dates first.
    public var dateCreatedSortKey: Date { dateCreatedRaw ?? .distantPast }

    /// Same idea for modification date.
    public var dateModifiedSortKey: Date { dateModifiedRaw ?? .distantPast }
}
