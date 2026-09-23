// ArchiveAngelFamilyFacts.swift
// Rick's hand-entered facts keep flowing through the Archive Angel (S4 fix,
// 2026-09-23). The retired Promote Helper stamped the copy family's best
// DATE, PLACE and backup ATTESTATIONS onto the records it promoted; the
// Angel does the same, in two places:
//
//   1. Plan build (ArchiveAngelJob) — `inherited(for:family:)` records on
//      the row what it WOULD inherit and from which copy, and the row's
//      proposed date/name use the inherited date, so Review shows
//      "Date 1987-06 — from Christmas_copy.dv" before anything is written.
//   2. Promote (ArchiveAngelPromoter) — `stamp(...)` writes them onto the
//      original and its companions just before the Promote job starts (so
//      the manifest row carries them), one log line per fact.
//
// Never overwrites: a record's own hand-entered date or place always wins,
// and an attestation the record answered itself wins a tie. At promote the
// family is re-read LIVE (an edit made while Review was open counts), and
// an inherited date is stamped only if the row's date is still the
// inherited one — a date typed in Review is the person's decision.
//
// Pure rules live in ArchiveAngelFamilyStamp; this file gathers records
// and words the log lines. Catalog access is through the AngelCatalog seam.

import Foundation
import VideoScanCore

enum ArchiveAngelFamilyFacts {

    /// What `rec` would inherit from `family` (which may include `rec`).
    /// Returns the fields to put on the plan row; all nil when nothing.
    @MainActor
    static func inherited(for rec: VideoRecord, family: [VideoRecord])
        -> (date: ArchiveAngelPlan.InheritedFact?, place: ArchiveAngelPlan.InheritedFact?, attestationKinds: [String]?) {
        let others = family.filter { $0.id != rec.id }
        var date: ArchiveAngelPlan.InheritedFact?
        if rec.userDate == nil, let best = ArchiveAngelFamilyStamp.bestUserDateSource(among: others) {
            date = .init(value: best.value, confidence: best.confidence,
                         fromRecordID: best.from.id, fromFilename: best.from.filename)
        }
        var place: ArchiveAngelPlan.InheritedFact?
        if rec.userPlace == nil, let best = ArchiveAngelFamilyStamp.bestUserPlaceSource(among: others) {
            place = .init(value: best.value, confidence: best.confidence,
                          fromRecordID: best.from.id, fromFilename: best.from.filename)
        }
        let kinds = addedAttestationKinds(to: rec, from: ArchiveAngelFamilyStamp.familyAttestations(among: others))
        return (date, place, kinds.isEmpty ? nil : kinds)
    }

    /// Kinds whose answer on `rec` would change by merging `family`.
    @MainActor
    static func addedAttestationKinds(to rec: VideoRecord, from family: [BackupAttestation]) -> [String] {
        guard !family.isEmpty else { return [] }
        let merged = BackupAttestation.merged(rec.backupAttestations, with: family)
        return merged.filter { !rec.backupAttestations.contains($0) }.map(\.kind.rawValue)
    }

    /// The Review line for a row ("" when nothing is inherited).
    static func reviewLine(_ e: ArchiveAngelPlan.Entry) -> String {
        var parts: [String] = []
        if let d = e.inheritedDate { parts.append("date \(d.value) from \(d.fromFilename)") }
        if let p = e.inheritedPlace { parts.append("place \(p.value) from \(p.fromFilename)") }
        if let k = e.inheritedAttestationKinds, !k.isEmpty { parts.append("backup answers (\(k.joined(separator: ", "))) from its copies") }
        return parts.isEmpty ? "" : "Inherits " + parts.joined(separator: " · ")
    }

    /// Promote time: stamp the LIVE family's facts onto `original` and its
    /// promoted `companions`, never overwriting their own values. Returns
    /// one log line per fact written (the caller notes them).
    @MainActor
    static func stamp(entry: ArchiveAngelPlan.Entry, original: VideoRecord, companions: [VideoRecord],
                      family: [VideoRecord]) -> [String] {
        let targets = [original] + companions
        let ids = Set(targets.map(\.id))
        let others = family.filter { !ids.contains($0.id) }
        var lines: [String] = []
        var changed: [UUID: VideoRecord] = [:]

        // Date — only while the row's date is still the one inherited (a
        // date typed in Review is the person's decision), and only onto
        // records without a date of their own.
        if original.userDate == nil, let best = ArchiveAngelFamilyStamp.bestUserDateSource(among: others) {
            let typed = entry.proposedDate?.trimmingCharacters(in: .whitespaces) ?? ""
            if typed.isEmpty || typed == best.value {
                let stamped = ArchiveAngelFamilyStamp.stampDateIfMissing((best.value, best.confidence), onto: targets)
                stamped.forEach { changed[$0.id] = $0 }
                if !stamped.isEmpty {
                    lines.append("Archive Angel: \(original.filename) — date \(best.value) (\(best.confidence)) inherited from \(best.from.filename)")
                }
            } else {
                lines.append("Archive Angel: \(original.filename) — date \(best.value) from \(best.from.filename) not stamped: Review set \(typed)")
            }
        }
        // Place.
        if original.userPlace == nil, let best = ArchiveAngelFamilyStamp.bestUserPlaceSource(among: others) {
            let stamped = ArchiveAngelFamilyStamp.stampPlaceIfMissing((best.value, best.confidence), onto: targets)
            stamped.forEach { changed[$0.id] = $0 }
            if !stamped.isEmpty {
                lines.append("Archive Angel: \(original.filename) — place \(best.value) (\(best.confidence)) inherited from \(best.from.filename)")
            }
        }
        // Backup attestations.
        let fam = ArchiveAngelFamilyStamp.familyAttestations(among: others)
        let kinds = addedAttestationKinds(to: original, from: fam)
        let stamped = ArchiveAngelFamilyStamp.stampAttestationsIfMissing(fam, onto: targets)
        stamped.forEach { changed[$0.id] = $0 }
        if !kinds.isEmpty {
            lines.append("Archive Angel: \(original.filename) — backup answers (\(kinds.joined(separator: ", "))) inherited from its copies")
        }
        // Record-scoped posts: the model re-indexes and saves each.
        ArchiveAngelFamilyStamp.announce(targets.filter { changed[$0.id] != nil })
        return lines
    }
}
