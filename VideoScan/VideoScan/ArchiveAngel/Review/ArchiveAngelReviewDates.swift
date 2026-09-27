// ArchiveAngelReviewDates.swift
// Angel Review's half of "use the date I already gave its copies" (Rick
// 2026-09-27, PromoteDateChoice.swift). One line per row; only a row whose
// copies DISAGREE (or only estimate) expands to ask, and Promote waits for
// the answer. The answer lives in the plan row itself:
//   • Use a copy's date   → proposedDate = that date, inheritedDate = that
//                           copy (the promoter turns it into
//                           ArchiveDateSource.copy — written on the archived
//                           copy with "from copy <name>");
//   • Enter a date…       → the row's own date field (ArchiveDateSource.typed);
//   • Promote undated     → the machine's own proposal (placement only).
// `dateFromCopiesAnswered` records that the person answered, so a reopened
// Review does not ask again. Pure functions over the plan row — the sheet
// calls them from button handlers and `.onAppear`, never from its body.

import Foundation
import VideoScanCore

enum ArchiveAngelReviewDates {

    /// The row's copy dates: the catalog gather (same bytes / footage group
    /// ≥ likely) plus the identity-inherited date the plan build found
    /// (archive link, whole-file repairs, ancestors — Rick's date either way).
    static func candidates(entry: ArchiveAngelPlan.Entry, gathered: [PromoteCopyDate],
                           volumeOf: (UUID) -> String) -> [PromoteCopyDate] {
        var list = gathered
        if let fact = entry.inheritedDate, !list.contains(where: { $0.recordID == fact.fromRecordID }),
           let canonical = UserDateEntry.canonicalize(fact.value) {
            list.append(PromoteCopyDate(recordID: fact.fromRecordID, filename: fact.fromFilename,
                                        volume: volumeOf(fact.fromRecordID), date: canonical,
                                        known: fact.confidence == UserDateConfidence.known.rawValue,
                                        via: .sameBytes))
        }
        return list
    }

    static func fact(_ d: PromoteCopyDate) -> ArchiveAngelPlan.InheritedFact {
        .init(value: d.date, confidence: d.known ? UserDateConfidence.known.rawValue : UserDateConfidence.estimated.rawValue,
              fromRecordID: d.recordID, fromFilename: d.filename)
    }

    /// At load: a single KNOWN date is pre-selected — unless the person
    /// already typed something of their own (then their date stands).
    /// `machineDefault` = the date the plan build proposed from the machine.
    static func applyPreselection(_ choice: PromoteCopiesDateChoice, to entry: inout ArchiveAngelPlan.Entry,
                                  machineDefault: String?) {
        guard case .preselected(let d, _) = choice, entry.dateFromCopiesAnswered != true else { return }
        let current = entry.proposedDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let untouched = current.isEmpty || current == machineDefault || current == entry.inheritedDate?.value
        guard untouched || current == d.date else { return }
        entry.proposedDate = d.date
        entry.inheritedDate = fact(d)
    }

    static func use(_ d: PromoteCopyDate, on entry: inout ArchiveAngelPlan.Entry) {
        entry.proposedDate = d.date
        entry.inheritedDate = fact(d)
        entry.dateFromCopiesAnswered = true
    }

    /// "Enter a date…": the row's date field is the answer; no copy lends.
    static func enterDate(on entry: inout ArchiveAngelPlan.Entry) {
        entry.inheritedDate = nil
        entry.dateFromCopiesAnswered = true
    }

    /// "Promote undated": back to the machine's own proposal.
    static func decline(on entry: inout ArchiveAngelPlan.Entry, machineDefault: String?) {
        entry.proposedDate = machineDefault
        entry.inheritedDate = nil
        entry.dateFromCopiesAnswered = true
    }

    /// A disagreement the person has not answered yet.
    static func needsAnswer(_ entry: ArchiveAngelPlan.Entry, choice: PromoteCopiesDateChoice?) -> Bool {
        guard case .ask = choice else { return false }
        return entry.dateFromCopiesAnswered != true
    }

    /// The row's one line once answered / pre-selected.
    static func line(_ entry: ArchiveAngelPlan.Entry, choice: PromoteCopiesDateChoice?,
                     machineDefault: String? = nil) -> String? {
        guard let choice, choice != .noCopyDates else { return nil }
        if case .preselected = choice, entry.dateFromCopiesAnswered != true,
           entry.inheritedDate?.value == entry.proposedDate, let l = choice.line {
            return l
        }
        guard entry.dateFromCopiesAnswered == true else { return nil }
        if let f = entry.inheritedDate, f.value == entry.proposedDate {
            return "dated \(UserDateEntry.friendlyDisplay(f.value)) (\(f.confidence)) from \(f.fromFilename)"
        }
        if let p = entry.proposedDate, !p.isEmpty, p != machineDefault { return "dated \(p) — your date" }
        return "no date from its copies — the file's own date stands"
    }
}
