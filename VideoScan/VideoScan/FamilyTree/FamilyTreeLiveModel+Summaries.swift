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
}
