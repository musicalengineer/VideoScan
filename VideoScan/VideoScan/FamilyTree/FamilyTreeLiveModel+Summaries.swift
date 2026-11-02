// FamilyTreeLiveModel+Summaries.swift
// The tree model's pure summary helpers (sidebar rows, references, life
// years, sort order). Moved out of FamilyTreeLiveModel.swift unchanged
// (2026-11-01) — that file is at its length limit. An extension of the
// tree model, not of VideoScanModel.

import Foundation
import VideoScanCore

extension FamilyTreeLiveModel {
    // MARK: Summaries (pure; `nonisolated` so tests and other actors can
    // call them without hopping to the main thread)

    nonisolated static func summary(_ person: GedcomFamilyGraph.Person) -> FamilyTreePersonSummary {
        summary(person, years: years(birth: person.birthDate, death: person.deathDate))
    }

    /// Same, with the life-dates line supplied (the compiled index carries
    /// it per person, so the sidebar build parses no dates).
    nonisolated static func summary(_ person: GedcomFamilyGraph.Person, years: String?) -> FamilyTreePersonSummary {
        FamilyTreePersonSummary(
            id: person.id,
            name: person.name.isEmpty ? "(unnamed)" : person.name,
            surname: person.surname,
            years: years,
            sex: FamilyTreeSex(gedcom: person.sex),
            familySearchID: person.familySearchID,
            reference: reference(for: person.id))
    }

    /// "@I123@" → "I123": the pointer with every leading and trailing "@"
    /// removed (what `trimmingCharacters(in: "@")` did, without building
    /// a CharacterSet per row).
    nonisolated static func reference(for id: String) -> String {
        var scalars = Substring(id).unicodeScalars[...]
        while scalars.first == "@" { scalars.removeFirst() }
        while scalars.last == "@" { scalars.removeLast() }
        return String(scalars)
    }

    /// Life-dates line. Years when both dates carry one ("1929–2008");
    /// otherwise the raw GEDCOM text, prefixed so "b."/"d." is explicit.
    /// Never claims "Living" — absence of a death date is not evidence.
    /// Lives in VideoScanCore (`GedcomFamilyGraph.lifeYearsLabel`) since
    /// 2026-08-29 so the compiled index can carry it per person.
    nonisolated static func years(birth: String?, death: String?) -> String? {
        GedcomFamilyGraph.lifeYearsLabel(birth: birth, death: death)
    }

    /// First four-digit run in a raw GEDCOM date ("ABT 1944", "BET 1930
    /// AND 1931" → 1930).
    nonisolated static func year(in raw: String?) -> Int? {
        GedcomFamilyGraph.year(in: raw)
    }

    /// Surname, then given name, then id. People with no surname go last.
    nonisolated static func sorted(_ people: [GedcomFamilyGraph.Person]) -> [GedcomFamilyGraph.Person] {
        people.sorted { lhs, rhs in
            let ls = lhs.surname?.lowercased() ?? "\u{FFFF}"
            let rs = rhs.surname?.lowercased() ?? "\u{FFFF}"
            if ls != rs { return ls < rs }
            let ln = lhs.name.lowercased(), rn = rhs.name.lowercased()
            if ln != rn { return ln < rn }
            return lhs.id < rhs.id
        }
    }

    /// "status active → retracted (wrong person)" and friends, with quoted
    /// text cut to 80 characters so a log line stays one line.
    nonisolated static func correctionChange(_ receipt: CyberBrainWriter.CorrectionReceipt) -> String {
        func quoted(_ text: String) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            return "\"" + (flat.count > 80 ? String(flat.prefix(79)) + "…" : flat) + "\""
        }
        let old = receipt.archive.people.lazy.flatMap(\.items).first { $0.id == receipt.itemID }
        let why = old?.correction.map { FamilyTreeNoteCorrectionLine.reasonText($0) } ?? "?"
        switch receipt.action {
        case .removed:
            return "status active → retracted (\(why)); text kept \(quoted(receipt.oldText))"
        case .edited:
            return "text \(quoted(receipt.oldText)) → \(quoted(receipt.newText ?? "")); "
                + "\(receipt.itemID) superseded by \(receipt.newItemID ?? "?")"
        case .moved:
            return "person \(receipt.fromPersonID) → \(receipt.toPersonID ?? "?")"
                + " (\(receipt.toPersonName ?? "?")\(receipt.createdTargetPerson ? ", new record" : ""));"
                + " \(receipt.itemID) retracted, copy \(receipt.newItemID ?? "?"); text \(quoted(receipt.oldText))"
        }
    }

    /// Everyone's sidebar summary in sidebar order — O(people), pure,
    /// built in parallel chunks of rows (each slot written once; the
    /// life-years line comes from the compiled index, so no date is
    /// parsed here). Same rows as `sidebarOrder.map { summary($0) }`
    /// (FamilyTreeLaunchBundleTests pins it).
    nonisolated static func sidebarRows(of graph: GedcomFamilyGraph) -> [FamilyTreePersonSummary] {
        let index = graph.index
        let count = index.count
        let chunk = 4096
        let chunks = (count + chunk - 1) / chunk
        return [FamilyTreePersonSummary](unsafeUninitializedCapacity: count) { buffer, initialized in
            // Swift 6: the inout buffer pointer may not be captured by the concurrent closure; each
            // chunk initializes only its disjoint [lo, hi) — no race (the FamilyTreeNameSearch shape).
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * chunk, hi = min(count, lo + chunk)
                for row in lo..<hi {
                    let o = Int(index.sidebarOrder[row])
                    let years = index.lifeYears[o]
                    (slots.baseAddress! + row).initialize(
                        to: summary(graph.people[index.ids[o]]!, years: years.isEmpty ? nil : years))
                }
            }
            initialized = count
        }
    }
}
