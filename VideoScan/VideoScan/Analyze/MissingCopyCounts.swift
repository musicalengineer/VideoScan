// MissingCopyCounts.swift
// "Missing, with no other copy" vs "Missing, another copy is present" —
// two of the Catalog Status band's review items (Rick 2026-10-20). A row
// marked Missing whose file IS missing is reality (the band stays green);
// what a person wants to know is whether that was the only copy.
//
// "Another copy" = a LIVE row (no removal marker, not set aside) in the
// same duplicate group, or carrying the same stored whole-file SHA-256.
// The catalog's own facts only — nothing on disk is read here.
//
// Shape = AnalyzeCoverageCalculator's: ONE main-actor projection pass over
// `records` into Sendable rows (only the rows that matter: Missing ones,
// and live ones with a group or a digest), the count off the main actor in
// the coverage pass's detached task. NO O(records) work in a view body.
//
// Memory: one small struct per projected row (~70 bytes with a digest
// string) ≈ 7 MB at 100k rows, freed when the count ends; two Sets of the
// same size while counting.
//
// (For Rick: a `Set<UUID>` ≈ std::unordered_set; the count is two passes —
// collect what is live, then look each Missing row's group/digest up.)

import Foundation
import VideoScanCore

/// The two counts the band shows.
struct MissingCopyCounts: Sendable, Equatable {
    var noOtherCopy = 0
    var otherCopyPresent = 0
}

/// One record, as the count needs it.
struct MissingCopyInput: Sendable, Equatable {
    var group: UUID?
    var digest: String?
    /// Marked Missing by the file check (removal state `.missing`).
    var isMissing: Bool
}

enum MissingCopyCalculator {

    /// Missing rows, and live rows that could be another copy of one.
    @MainActor
    static func project(_ records: [VideoRecord]) -> [MissingCopyInput] {
        var out: [MissingCopyInput] = []
        for r in records {
            let missing = r.removal?.state == .missing
            let live = r.removal == nil && !r.isSetAside
            guard missing || live else { continue }
            let digest = VideoScanModel.storedFullDigest(r)
            guard missing || r.duplicateGroupID != nil || digest != nil else { continue }
            out.append(MissingCopyInput(group: r.duplicateGroupID, digest: digest, isMissing: missing))
        }
        return out
    }

    /// PURE: split the Missing rows by whether a live row shares their
    /// duplicate group or their whole-file digest.
    nonisolated static func count(_ inputs: [MissingCopyInput]) -> MissingCopyCounts {
        var groups = Set<UUID>()
        var digests = Set<String>()
        for i in inputs where !i.isMissing {
            if let g = i.group { groups.insert(g) }
            if let d = i.digest { digests.insert(d) }
        }
        var counts = MissingCopyCounts()
        for i in inputs where i.isMissing {
            let inGroup = i.group.map(groups.contains) ?? false
            let sameBytes = i.digest.map(digests.contains) ?? false
            if inGroup || sameBytes { counts.otherCopyPresent += 1 } else { counts.noOtherCopy += 1 }
        }
        return counts
    }
}
