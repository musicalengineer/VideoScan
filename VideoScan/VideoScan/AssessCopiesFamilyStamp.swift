// AssessCopiesFamilyStamp.swift
// Moved verbatim out of AssessCopiesDetailView.swift when Archive Angel
// consolidation S4 (2026-09-22) retired the Promote Helper panel.
//
// NOTE (S4): the Helper's promote was the only production caller — it
// stamped the copy family's best hand-entered date, place and backup
// attestations onto the records being promoted. The Archive Angel's
// Prepare → Review → Promote path does not do this family-wide
// inheritance today (it carries each record's OWN place/attestations).
// Kept, with its sensors (PlaceInheritanceSensorTests), as the pure rule
// the Angel can adopt; see the S4 report.

import Foundation
import VideoScanCore

// MARK: - Family place stamp (pure)

/// The same-recording family's hand-entered PLACE, chosen and stamped by
/// the same rules the family DATE uses (codex #1374, 2026-09-12). Pure so
/// PlaceInheritanceSensorTests can pin it; the view methods above only
/// gather the records and post the mutation.
enum AssessCopiesFamilyStamp {

    /// Known beats estimated; a longer canonical (more precise, e.g.
    /// "Franklin, MA" over "Franklin") beats shorter; ties lexicographic.
    @MainActor
    static func bestUserPlace(among records: [VideoRecord]) -> (place: String, confidence: String)? {
        var best: (place: String, confidence: String)?
        for r in records {
            guard let p = r.userPlace else { continue }
            let cand = (place: p, confidence: r.userPlaceConfidence ?? UserPlaceConfidence.estimated.rawValue)
            guard let b = best else { best = cand; continue }
            let candKnown = cand.confidence == UserPlaceConfidence.known.rawValue
            let bestKnown = b.confidence == UserPlaceConfidence.known.rawValue
            if candKnown != bestKnown { if candKnown { best = cand }; continue }
            if cand.place.count != b.place.count {
                if cand.place.count > b.place.count { best = cand }; continue
            }
            if cand.place < b.place { best = cand }
        }
        return best
    }

    /// Stamp `family` onto every target that has no place of its own.
    /// Returns the records that changed (the caller announces them).
    @MainActor
    @discardableResult
    static func stampPlaceIfMissing(_ family: (place: String, confidence: String),
                                    onto targets: [VideoRecord]) -> [VideoRecord] {
        var stamped: [VideoRecord] = []
        for r in targets where r.userPlace == nil {
            r.userPlace = family.place
            r.userPlaceConfidence = family.confidence
            stamped.append(r)
        }
        return stamped
    }

    /// The family's merged backup attestations (2026-09-12): union by
    /// kind across every copy, latest answer per kind. Empty when nobody
    /// in the family was ever asked.
    @MainActor
    static func familyAttestations(among records: [VideoRecord]) -> [BackupAttestation] {
        var merged: [BackupAttestation] = []
        for r in records where !r.backupAttestations.isEmpty {
            merged = BackupAttestation.merged(merged, with: r.backupAttestations)
        }
        return merged
    }

    /// Merge `family` onto every target (a target's own, later answer
    /// wins; a kind only the family knows is added). Returns the records
    /// that changed (the caller announces them). Idempotent.
    @MainActor
    @discardableResult
    static func stampAttestationsIfMissing(_ family: [BackupAttestation],
                                           onto targets: [VideoRecord]) -> [VideoRecord] {
        var stamped: [VideoRecord] = []
        for r in targets {
            let merged = BackupAttestation.merged(r.backupAttestations, with: family)
            if merged != r.backupAttestations {
                r.backupAttestations = merged
                stamped.append(r)
            }
        }
        return stamped
    }

    /// One RECORD-SCOPED mutation post per changed record — the same shape
    /// InspectorPlaceView uses — so VideoScanModel re-indexes each one at
    /// once (a record-less post only schedules the save; codex #1380).
    @MainActor
    static func announce(_ changed: [VideoRecord]) {
        for r in changed {
            NotificationCenter.default.post(name: .videoScanCatalogMutated, object: r)
        }
    }
}
