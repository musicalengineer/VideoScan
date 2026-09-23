// ArchiveAngelFamilyFacts.swift
// Rick's hand-entered facts keep flowing through the Archive Angel (S4 fix,
// 2026-09-23). The retired Promote Helper stamped the copy family's best
// DATE, PLACE and backup ATTESTATIONS onto the records it promoted; the
// Angel does the same, in two places:
//
//   1. Plan build (ArchiveAngelJob) — `inherited(for:relatives:)` records on
//      the row what it WOULD inherit and from which copy, and the row's
//      proposed date/name use the inherited date, so Review shows
//      "Inherits date 1987-06 from Christmas_copy.dv" before anything is
//      written.
//   2. Promote (ArchiveAngelPromoter) — `stamp(...)` writes them onto the
//      original and its companions just before the Promote job starts (so
//      the manifest row carries them), one log line per fact, and returns
//      what it replaced. If the original never lands (refused, cancelled,
//      failed, interrupted) the promoter RESTORES those values (`restore`);
//      if it lands, the date/place writes get Media Ledger lines by the
//      angel.
//
// WHICH copies may lend a fact (QA on S4): only IDENTITY relatives — the
// same non-empty content signature, `derivedFrom` lineage, an archive copy
// ↔ its promotion source (ArchiveAngelCopyFamily.collectIdentity). A copy
// reached only through the duplicate group is SIMILAR, not proven the same
// (two 00000.MTS of equal length can share a group): its date is shown in
// Review as "a similar copy says …", never applied.
//
// Never overwrites: a record's own hand-entered date or place always wins,
// and an attestation the record answered itself wins a tie. Companions
// promoted with the original take the ORIGINAL's date and place (their
// identity is the original — derivedFrom), own values still winning. At
// promote the relatives are re-read LIVE, the same way plan build reads
// them (`relatives`), and an inherited date is stamped only if the row's
// date is still the inherited one — a date typed in Review is the
// person's decision.
//
// Pure rules live in ArchiveAngelFamilyStamp; this file gathers records
// and words the log lines. Catalog access is through the AngelCatalog seam.

import Foundation
import VideoScanCore

enum ArchiveAngelFamilyFacts {

    /// The copies that may lend facts to `original` (identity) and the ones
    /// only shown (similar). Neither contains the original.
    struct Relatives {
        var identity: [VideoRecord]
        var similar: [VideoRecord] = []
    }

    /// The ONE way plan build and Promote read the relatives (QA nit on S4:
    /// Review and Promote must name the same source).
    @MainActor
    static func relatives(of original: VideoRecord, index: ArchiveAngelCopyFamily.Index,
                          catalog: any AngelCatalog) -> Relatives {
        let identity = ArchiveAngelCopyFamily.collectIdentity(seed: original, index: index, catalog: catalog)
        let full = ArchiveAngelCopyFamily.collect(seed: original, index: index, catalog: catalog)
        return relatives(of: original, identityFamily: identity, fullFamily: full)
    }

    /// Pure split (both lists in the walk's path order).
    @MainActor
    static func relatives(of original: VideoRecord, identityFamily: [VideoRecord],
                          fullFamily: [VideoRecord]) -> Relatives {
        let identity = identityFamily.filter { $0.id != original.id }
        let ids = Set(identity.map(\.id)).union([original.id])
        return Relatives(identity: identity, similar: fullFamily.filter { !ids.contains($0.id) })
    }

    // MARK: Plan build

    struct Inherited {
        var date: ArchiveAngelPlan.InheritedFact?
        var place: ArchiveAngelPlan.InheritedFact?
        var attestationKinds: [String]?
        /// Shown only: a similar copy's date when no identity date applies.
        var similarDate: ArchiveAngelPlan.InheritedFact?
    }

    /// What `rec` would inherit. Only identity relatives lend; a similar
    /// copy's date is reported for Review, never applied.
    @MainActor
    static func inherited(for rec: VideoRecord, relatives: Relatives) -> Inherited {
        var out = Inherited()
        if rec.userDate == nil {
            if let best = ArchiveAngelFamilyStamp.bestUserDateSource(among: relatives.identity) {
                out.date = fact(best)
            } else if let hint = ArchiveAngelFamilyStamp.bestUserDateSource(among: relatives.similar) {
                out.similarDate = fact(hint)
            }
        }
        if rec.userPlace == nil, let best = ArchiveAngelFamilyStamp.bestUserPlaceSource(among: relatives.identity) {
            out.place = fact(best)
        }
        let kinds = addedAttestationKinds(to: rec, from: ArchiveAngelFamilyStamp.familyAttestations(among: relatives.identity))
        out.attestationKinds = kinds.isEmpty ? nil : kinds
        return out
    }

    /// `family` = identity relatives (may include `rec`). For callers and
    /// tests that already have the identity family.
    @MainActor
    static func inherited(for rec: VideoRecord, family: [VideoRecord]) -> Inherited {
        inherited(for: rec, relatives: Relatives(identity: family.filter { $0.id != rec.id }))
    }

    private static func fact(_ v: ArchiveAngelFamilyValue) -> ArchiveAngelPlan.InheritedFact {
        .init(value: v.value, confidence: v.confidence, fromRecordID: v.from.id, fromFilename: v.from.filename)
    }

    /// Kinds whose answer on `rec` would change by merging `family`.
    @MainActor
    static func addedAttestationKinds(to rec: VideoRecord, from family: [BackupAttestation]) -> [String] {
        guard !family.isEmpty else { return [] }
        let merged = BackupAttestation.merged(rec.backupAttestations, with: family)
        return merged.filter { !rec.backupAttestations.contains($0) }.map(\.kind.rawValue)
    }

    /// The Review line for a row ("" when nothing is inherited or hinted).
    static func reviewLine(_ e: ArchiveAngelPlan.Entry) -> String {
        var parts: [String] = []
        if let d = e.inheritedDate { parts.append("date \(d.value) from \(d.fromFilename)") }
        if let p = e.inheritedPlace { parts.append("place \(p.value) from \(p.fromFilename)") }
        if let k = e.inheritedAttestationKinds, !k.isEmpty { parts.append("backup answers (\(k.joined(separator: ", "))) from its copies") }
        var line = parts.isEmpty ? "" : "Inherits " + parts.joined(separator: " · ")
        if let s = e.similarDate {
            line += (line.isEmpty ? "" : " · ") + "a similar copy (\(s.fromFilename)) says \(s.value) — not applied"
        }
        return line
    }

    // MARK: Promote

    struct StampResult {
        var lines: [String] = []
        var facts: [ArchiveAngelPlan.StampedFact] = []
    }

    /// Promote time: stamp the LIVE identity relatives' facts onto
    /// `original`, and the original's facts onto its dateless / placeless
    /// `companions`, never overwriting a record's own value. Returns the
    /// log lines and what was replaced (for `restore`).
    @MainActor
    static func stamp(entry: ArchiveAngelPlan.Entry, original: VideoRecord, companions: [VideoRecord],
                      relatives: Relatives) -> StampResult {
        var out = StampResult()
        let sources = relatives.identity.filter { $0.id != original.id }
        let typed = entry.proposedDate?.trimmingCharacters(in: .whitespaces) ?? ""

        // Date → the original. Only while the row's date is still the one
        // inherited (a date typed in Review is the person's decision).
        if original.userDate == nil, let best = ArchiveAngelFamilyStamp.bestUserDateSource(among: sources) {
            if typed.isEmpty || typed == best.value {
                if let f = stampDate(best.value, best.confidence, onto: original) {
                    out.facts.append(f)
                    out.lines.append("Archive Angel: \(original.filename) — date \(best.value) (\(best.confidence)) inherited from \(best.from.filename)")
                }
            } else if let planned = entry.inheritedDate, typed == planned.value {
                out.lines.append("Archive Angel: \(original.filename) — date not stamped: \(planned.fromFilename) said \(planned.value) at Prepare, "
                                 + "the copies now say \(best.value) (\(best.from.filename)) — check the date in Review")
            } else {
                out.lines.append("Archive Angel: \(original.filename) — date \(best.value) from \(best.from.filename) not stamped: Review set \(typed)")
            }
        }
        // Place → the original.
        if original.userPlace == nil, let best = ArchiveAngelFamilyStamp.bestUserPlaceSource(among: sources),
           let f = stampPlace(best.value, best.confidence, onto: original) {
            out.facts.append(f)
            out.lines.append("Archive Angel: \(original.filename) — place \(best.value) (\(best.confidence)) inherited from \(best.from.filename)")
        }
        // Attestations → the original.
        let fam = ArchiveAngelFamilyStamp.familyAttestations(among: sources)
        let kinds = addedAttestationKinds(to: original, from: fam)
        if let f = stampAttestations(fam, onto: original) {
            out.facts.append(f)
            out.lines.append("Archive Angel: \(original.filename) — backup answers (\(kinds.joined(separator: ", "))) inherited from its copies")
        }
        // The original's facts (own or just inherited) → its companions:
        // their identity IS the original (derivedFrom), so its date keeps a
        // dateless companion in the same archive folder (QA on S4).
        for c in companions where c.id != original.id {
            var what: [String] = []
            if let d = original.userDate, typed.isEmpty || typed == d,
               let f = stampDate(d, original.userDateConfidence ?? UserDateConfidence.estimated.rawValue, onto: c) {
                out.facts.append(f); what.append("date \(d)")
            }
            if let p = original.userPlace,
               let f = stampPlace(p, original.userPlaceConfidence ?? UserPlaceConfidence.estimated.rawValue, onto: c) {
                out.facts.append(f); what.append("place \(p)")
            }
            if let f = stampAttestations(original.backupAttestations, onto: c) {
                out.facts.append(f); what.append("backup answers")
            }
            if !what.isEmpty {
                out.lines.append("Archive Angel: \(c.filename) — \(what.joined(separator: ", ")) from its original \(original.filename)")
            }
        }
        // Record-scoped posts: the model re-indexes and saves each.
        let changed = Set(out.facts.map(\.recordID))
        ArchiveAngelFamilyStamp.announce(([original] + companions).filter { changed.contains($0.id) })
        return out
    }

    /// `family` = identity relatives (may include the original / companions).
    @MainActor
    static func stamp(entry: ArchiveAngelPlan.Entry, original: VideoRecord, companions: [VideoRecord],
                      family: [VideoRecord]) -> StampResult {
        let targets = Set([original.id] + companions.map(\.id))
        return stamp(entry: entry, original: original, companions: companions,
                     relatives: Relatives(identity: family.filter { !targets.contains($0.id) }))
    }

    @MainActor
    private static func stampDate(_ value: String, _ confidence: String, onto r: VideoRecord) -> ArchiveAngelPlan.StampedFact? {
        let before = (r.userDate, r.userDateConfidence)
        guard !ArchiveAngelFamilyStamp.stampDateIfMissing((value, confidence), onto: [r]).isEmpty else { return nil }
        return .init(recordID: r.id, field: .date, previousValue: before.0, previousConfidence: before.1,
                     writtenValue: r.userDate, writtenConfidence: r.userDateConfidence)
    }

    @MainActor
    private static func stampPlace(_ value: String, _ confidence: String, onto r: VideoRecord) -> ArchiveAngelPlan.StampedFact? {
        let before = (r.userPlace, r.userPlaceConfidence)
        guard !ArchiveAngelFamilyStamp.stampPlaceIfMissing((value, confidence), onto: [r]).isEmpty else { return nil }
        return .init(recordID: r.id, field: .place, previousValue: before.0, previousConfidence: before.1,
                     writtenValue: r.userPlace, writtenConfidence: r.userPlaceConfidence)
    }

    @MainActor
    private static func stampAttestations(_ family: [BackupAttestation], onto r: VideoRecord) -> ArchiveAngelPlan.StampedFact? {
        guard !family.isEmpty else { return nil }
        let before = r.backupAttestations
        guard !ArchiveAngelFamilyStamp.stampAttestationsIfMissing(family, onto: [r]).isEmpty else { return nil }
        return .init(recordID: r.id, field: .attestations, previousAttestations: before,
                     writtenAttestations: r.backupAttestations)
    }

    /// Undo `facts` (a promote that did not land). A field is put back ONLY
    /// if it still holds what Promote wrote — an edit made since wins.
    /// Returns the records changed (already announced).
    @MainActor
    @discardableResult
    static func restore(_ facts: [ArchiveAngelPlan.StampedFact], record: (UUID) -> VideoRecord?) -> [VideoRecord] {
        var changed: [UUID: VideoRecord] = [:]
        for f in facts {
            guard let r = record(f.recordID) else { continue }
            switch f.field {
            case .date:
                guard r.userDate == f.writtenValue, r.userDateConfidence == f.writtenConfidence else { continue }
                r.userDate = f.previousValue; r.userDateConfidence = f.previousConfidence
            case .place:
                guard r.userPlace == f.writtenValue, r.userPlaceConfidence == f.writtenConfidence else { continue }
                r.userPlace = f.previousValue; r.userPlaceConfidence = f.previousConfidence
            case .attestations:
                guard r.backupAttestations == (f.writtenAttestations ?? []) else { continue }
                r.backupAttestations = f.previousAttestations ?? []
            }
            changed[r.id] = r
        }
        let list = changed.values.sorted { $0.fullPath < $1.fullPath }
        ArchiveAngelFamilyStamp.announce(list)
        return list
    }
}
