// MissingCopyCounts.swift
// "Missing, with no other copy" / "Missing, another copy is present" /
// "Missing — a possible copy, not proven" — three of the Catalog Status
// band's review items (Rick 2026-10-20; QA 2026-10-20 P2-b). A row marked
// Missing whose file IS missing is reality (the band stays green); what a
// person wants to know is whether that was the only copy.
//
// "Another copy is present" must be PROVEN (the 10/19 ruling: a copy = the
// same stored whole-file SHA-256; delete safety: prove the surviving
// copy): a LIVE row (no removal marker, not set aside) carrying the same
// stored full SHA-256 as the Missing row. Duplicate-group membership alone
// is not proof:
//   • a live group mate with a DIFFERENT full SHA-256 → proven NOT the same
//     bytes → no other copy (unless another live row matches the digest);
//   • a live group mate where either side has no full SHA-256 → "a possible
//     copy, not proven" (door: Fill In Full Hashes, then Validate Catalog).
// The catalog's own facts only — nothing on disk is read here.
//
// Shape = AnalyzeCoverageCalculator's: ONE main-actor projection pass over
// `records` into Sendable rows (only the rows that matter: Missing ones,
// and live ones with a group or a digest), the count off the main actor in
// the coverage pass's detached task. NO O(records) work in a view body.
//
// Memory: one small struct per projected row (~70 bytes with a digest
// string) ≈ 7 MB at 100k rows, freed when the count ends; one Set and one
// dictionary of the same order while counting.
//
// (For Rick: a `Set<String>` ≈ std::unordered_set; the count is two passes —
// collect what is live, then look each Missing row's digest / group up.)

import Foundation
import VideoScanCore

/// The three counts the band shows.
struct MissingCopyCounts: Sendable, Equatable {
    var noOtherCopy = 0
    var otherCopyPresent = 0
    var possibleCopyNotProven = 0
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

    /// What the live group mates of a group tell about a Missing member.
    struct LiveGroup {
        var members = 0
        var withoutDigest = 0
    }

    /// PURE: split the Missing rows — proven copy (same full SHA-256 on a
    /// live row), possible copy (a live group mate, a digest missing on one
    /// side), or none.
    nonisolated static func count(_ inputs: [MissingCopyInput]) -> MissingCopyCounts {
        var digests = Set<String>()
        var groups: [UUID: LiveGroup] = [:]
        for i in inputs where !i.isMissing {
            if let d = i.digest { digests.insert(d) }
            if let g = i.group {
                groups[g, default: LiveGroup()].members += 1
                if i.digest == nil { groups[g, default: LiveGroup()].withoutDigest += 1 }
            }
        }
        var counts = MissingCopyCounts()
        for i in inputs where i.isMissing {
            if let d = i.digest, digests.contains(d) {
                counts.otherCopyPresent += 1
            } else if isPossibleCopy(i, groups) {
                counts.possibleCopyNotProven += 1
            } else {
                counts.noOtherCopy += 1
            }
        }
        return counts
    }

    /// A live group mate exists and the bytes cannot be compared: the
    /// Missing row has no full SHA-256, or a mate has none. (Mates that all
    /// carry a different digest are proven not to be this file.)
    nonisolated static func isPossibleCopy(_ missing: MissingCopyInput, _ groups: [UUID: LiveGroup]) -> Bool {
        guard let g = missing.group, let live = groups[g], live.members > 0 else { return false }
        return missing.digest == nil || live.withoutDigest > 0
    }
}
