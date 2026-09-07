// FamilyTreePersonMetadata.swift
// "I want all this text to be copyable via 'copy gedcom data for this
// individual' or just copy metadata, whatever you wanna call it" — Rick,
// 2026-09-07, looking at John Hastings 3rd Earl of Pembroke in the Family
// Tree view.
//
// A plain-text block of everything the app holds about one person, ready for
// the pasteboard. Pure and synchronous so it can be tested without a view.
//
// HONESTY ABOUT WHAT THIS IS NOT. It is the app's record, not the GEDCOM's.
// The parser keeps names, sex, birth and death (date and place), the
// FamilySearch id and the family links — and drops TITL, BURI, NOTE, SOUR and
// OBJE at load. John Hastings' record carries three `1 TITL` lines
// (5th Baron of Abergavenny, 3rd Baron Manny, 3rd Earl of Pembroke), a burial
// at Grey Friars London, a jousting-accident cause of death and four sources;
// none of that reaches `Person`, so none of it can be copied here. Rather
// than let the block look complete, it says so at the bottom. See
// docs/hallie_titled_ancestors_design.md — restoring those fields is the
// parser/schema work codex scoped.

import Foundation
import VideoScanCore

enum FamilyTreePersonMetadata {

    /// The copyable block. `graph` supplies the relatives; everything else
    /// comes off the person record verbatim — raw GEDCOM date and place
    /// strings are never reformatted, matching how the app displays them.
    static func text(for person: GedcomFamilyGraph.Person,
                     in graph: GedcomFamilyGraph) -> String {
        var lines: [String] = [person.name]

        let others = person.alternateNames.filter { $0 != person.name }
        if !others.isEmpty {
            lines.append("Also known as: " + others.joined(separator: "; "))
        }
        switch person.sex {
        case "M": lines.append("Sex: Male")
        case "F": lines.append("Sex: Female")
        default: break
        }

        if let born = event("Born", date: person.birthDate, place: person.birthPlace) {
            lines.append(born)
        }
        if let died = event("Died", date: person.deathDate, place: person.deathPlace) {
            lines.append(died)
        }

        if let fsid = person.familySearchID, !fsid.isEmpty {
            lines.append("FamilySearch ID: \(fsid)")
        }
        lines.append("Record ID: \(person.id)")

        let parents = graph.allRecordedParents(of: person)
        if !parents.isEmpty {
            lines.append("")
            lines.append("Parents:")
            for parent in parents { lines.append("  - " + summary(parent)) }
        }

        let units = graph.familyUnits(of: person)
        for unit in units where unit.spouse != nil || !unit.children.isEmpty {
            lines.append("")
            if let spouse = unit.spouse {
                var header = "Married to " + summary(spouse)
                if let date = unit.marriageDate, !date.isEmpty { header += " — \(date)" }
                lines.append(header)
            } else if let date = unit.marriageDate, !date.isEmpty {
                lines.append("Marriage — \(date)")
            } else {
                lines.append("Family:")
            }
            for child in unit.children { lines.append("  - " + summary(child)) }
        }

        lines.append("")
        lines.append("— Copied from VideoScan. This is what the app holds for this person;")
        lines.append("  titles, burial, notes and sources in the source GEDCOM are not kept.")
        return lines.joined(separator: "\n")
    }

    /// "Born 11 October 1372 (Kenilworth, Warwickshire, England)" — the shape
    /// the Family Tree view already shows, so a copy reads like the screen.
    /// Nil when the record has neither a date nor a place.
    private static func event(_ label: String, date: String?, place: String?) -> String? {
        let date = date?.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = place?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (date?.isEmpty == false ? date : nil, place?.isEmpty == false ? place : nil) {
        case let (date?, place?): return "\(label) \(date) (\(place))"
        case let (date?, nil):    return "\(label) \(date) (place not recorded)"
        case let (nil, place?):   return "\(label) (date not recorded) (\(place))"
        default: return nil
        }
    }

    /// "Philippa de Mortimer (b. 1375, d. 1401)" — one line for a relative.
    private static func summary(_ person: GedcomFamilyGraph.Person) -> String {
        var parts: [String] = []
        if let b = person.birthDate, !b.isEmpty { parts.append("b. \(b)") }
        if let d = person.deathDate, !d.isEmpty { parts.append("d. \(d)") }
        return parts.isEmpty ? person.name : "\(person.name) (\(parts.joined(separator: ", ")))"
    }
}
