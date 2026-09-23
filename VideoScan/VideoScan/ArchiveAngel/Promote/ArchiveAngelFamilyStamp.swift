// ArchiveAngelFamilyStamp.swift
// A recording's hand-entered facts ride its promote (Rick's rule since the
// Promote Helper, 2026-08-19/20; place + attestations codex #1374,
// 2026-09-12): a record being promoted that has no DATE or PLACE of its own
// inherits the best one any copy of the same recording carries, and it
// merges the family's backup ATTESTATIONS. A record's own hand-entered
// value is NEVER overwritten by a sibling's.
//
// Precedence (unchanged from the Helper): known beats estimated; a longer
// canonical (more precise: "1987-06" over "1987", "Franklin, MA" over
// "Franklin") beats shorter; remaining ties resolve lexicographically so
// the answer is stable. Attestations: union by kind, the latest answer per
// kind, the target's own answer winning a tie.
//
// History: this was AssessCopiesFamilyStamp, inside the Helper panel's
// view (AssessCopiesDetailView). Archive Angel consolidation S4
// (2026-09-22) retired the panel; the Angel now calls it at plan build
// (Review shows the inherited value and the copy it came from —
// ArchiveAngelFamilyFacts) and at promote (ArchiveAngelPromoter stamps and
// logs it). Pure rules here; the callers gather records and announce.

import Foundation
import VideoScanCore

/// The winning family value and the copy it came from.
struct ArchiveAngelFamilyValue {
    let value: String
    let confidence: String
    let from: VideoRecord
}

enum ArchiveAngelFamilyStamp {

    /// The ONE precedence rule for date and place (see the header).
    /// `copies` should be in a stable order (the family walk sorts by
    /// path); an exact tie keeps the first.
    @MainActor
    static func best(among copies: [VideoRecord], value: (VideoRecord) -> String?,
                     confidence: (VideoRecord) -> String?, known: String,
                     defaultConfidence: String) -> ArchiveAngelFamilyValue? {
        var best: ArchiveAngelFamilyValue?
        for r in copies {
            guard let v = value(r) else { continue }
            let cand = ArchiveAngelFamilyValue(value: v, confidence: confidence(r) ?? defaultConfidence, from: r)
            guard let b = best else { best = cand; continue }
            let candKnown = cand.confidence == known
            let bestKnown = b.confidence == known
            if candKnown != bestKnown { if candKnown { best = cand }; continue }
            if cand.value.count != b.value.count {
                if cand.value.count > b.value.count { best = cand }; continue
            }
            if cand.value < b.value { best = cand }
        }
        return best
    }

    /// The family's best hand-entered DATE, with its source copy.
    @MainActor
    static func bestUserDateSource(among copies: [VideoRecord]) -> ArchiveAngelFamilyValue? {
        best(among: copies, value: { $0.userDate }, confidence: { $0.userDateConfidence },
             known: UserDateConfidence.known.rawValue, defaultConfidence: UserDateConfidence.estimated.rawValue)
    }

    /// The family's best hand-entered PLACE, with its source copy.
    @MainActor
    static func bestUserPlaceSource(among copies: [VideoRecord]) -> ArchiveAngelFamilyValue? {
        best(among: copies, value: { $0.userPlace }, confidence: { $0.userPlaceConfidence },
             known: UserPlaceConfidence.known.rawValue, defaultConfidence: UserPlaceConfidence.estimated.rawValue)
    }

    /// Known beats estimated; a longer canonical (more precise, e.g.
    /// "1987-06" over "1987") beats shorter; ties lexicographic.
    @MainActor
    static func bestUserDate(among copies: [VideoRecord]) -> (date: String, confidence: String)? {
        bestUserDateSource(among: copies).map { ($0.value, $0.confidence) }
    }

    /// Known beats estimated; a longer canonical (more precise, e.g.
    /// "Franklin, MA" over "Franklin") beats shorter; ties lexicographic.
    @MainActor
    static func bestUserPlace(among copies: [VideoRecord]) -> (place: String, confidence: String)? {
        bestUserPlaceSource(among: copies).map { ($0.value, $0.confidence) }
    }

    /// Stamp `family` onto every target that has no date of its own (the
    /// Helper's stampFamilyUserDateIfMissing rule). Returns the records
    /// that changed (the caller announces them).
    @MainActor
    @discardableResult
    static func stampDateIfMissing(_ family: (date: String, confidence: String),
                                   onto targets: [VideoRecord]) -> [VideoRecord] {
        var stamped: [VideoRecord] = []
        for r in targets where r.userDate == nil {
            r.userDate = family.date
            r.userDateConfidence = family.confidence
            stamped.append(r)
        }
        return stamped
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
    static func familyAttestations(among copies: [VideoRecord]) -> [BackupAttestation] {
        var merged: [BackupAttestation] = []
        for r in copies where !r.backupAttestations.isEmpty {
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
