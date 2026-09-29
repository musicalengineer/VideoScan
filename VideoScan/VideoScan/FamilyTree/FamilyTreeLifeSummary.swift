import Foundation
import VideoScanCore

/// The two genealogy lines under a person's name in the Family Tree
/// inspector (Rick, 2026-08-28):
///
///     Born 1615 (Plymouth, Massachusetts)
///     Died 1690, age 75 (Sudbury, Massachusetts Bay Colony)
///
/// Pure formatting over the GEDCOM strings — no SwiftUI, so the matrix in
/// FamilyTreeLifeSummaryTests runs without a view. Rules:
///   * the year keeps its qualifier: "ABT 1520" → "about 1520",
///     "BEF 13 JAN 1633" → "before 1633", "AFT 1717" → "after 1717"
///   * age = death year − birth year; "age ~N" when either date is not an
///     exact year; omitted when either year is missing or N < 0 or N > 115
///   * place = the recorded string verbatim (FamilySearch already writes
///     "Town, County, State, Country"); the view wraps it
///   * never "Living" — a missing death date is not evidence of anything,
///     so the Died line is simply absent
///
/// A plain `struct` here ≈ a C++ value type with all-const members: build
/// it once from the record, compare by value, pass around freely.
struct FamilyTreeLifeSummary: Equatable {
    /// Oldest plausible lifespan; anything beyond it is a data error in
    /// the record and we would rather say nothing than "age 300".
    static let maximumAge = 115

    let bornLine: String?
    let diedLine: String?

    /// The lines to draw, in order; empty when nothing is recorded.
    var lines: [String] { [bornLine, diedLine].compactMap { $0 } }

    init(birthDate: String?, deathDate: String?,
         birthPlace: String? = nil, deathPlace: String? = nil) {
        let birth = GedcomYearInterval.parse(birthDate)
        let death = GedcomYearInterval.parse(deathDate)

        bornLine = Self.line(prefix: "Born",
                             year: Self.yearPhrase(birth, raw: birthDate),
                             age: nil,
                             place: birthPlace)
        diedLine = Self.line(prefix: "Died",
                             year: Self.yearPhrase(death, raw: deathDate),
                             age: Self.agePhrase(birth: birth, death: death),
                             place: deathPlace)
    }

    /// Convenience over a graph person.
    init(_ person: GedcomFamilyGraph.Person) {
        self.init(birthDate: person.birthDate, deathDate: person.deathDate,
                  birthPlace: person.birthPlace, deathPlace: person.deathPlace)
    }

    // MARK: Pieces

    /// "1615" / "about 1520" / "before 1633" / "between 1700 and 1710".
    /// A date with no four-digit year at all ("BEF 1 MAY") is shown as
    /// recorded, lowercased, rather than dropped — the record said
    /// *something*.
    static func yearPhrase(_ interval: GedcomYearInterval?, raw: String?) -> String? {
        if let interval { return interval.spoken }
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    /// (years, approximate) or nil when the age should be left off.
    static func age(birth: GedcomYearInterval?, death: GedcomYearInterval?) -> (years: Int, approximate: Bool)? {
        guard let b = birth?.anchor, let d = death?.anchor,
              let birth, let death else { return nil }
        let years = d - b
        guard years >= 0, years <= maximumAge else { return nil }
        let approximate = birth.qualifier != .exact || death.qualifier != .exact
        return (years, approximate)
    }

    private static func agePhrase(birth: GedcomYearInterval?, death: GedcomYearInterval?) -> String? {
        guard let age = age(birth: birth, death: death) else { return nil }
        return age.approximate ? "age ~\(age.years)" : "age \(age.years)"
    }

    /// "Born 1615 (Plymouth)" / "Died 1690, age 75 (Sudbury)". A place with
    /// no date still gets a line ("Born (Cork, Ireland)" reads oddly, so
    /// it becomes "Born in Cork, Ireland").
    private static func line(prefix: String, year: String?, age: String?, place: String?) -> String? {
        // Blank/whitespace place → treated as absent.
        let place = place.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        switch (year, place) {
        case (nil, nil):
            return nil
        case (nil, let place?):
            return "\(prefix) in \(place)"
        case (let year?, _):
            var text = "\(prefix) \(year)"
            if let age { text += ", \(age)" }
            if let place { text += " (\(place))" }
            return text
        }
    }
}

/// One marriage of the selected person, for the inspector's Spouses list:
/// who (nil when the tree names no spouse in that family) and the MARR
/// date as a spoken year ("1952", "about 1890"), nil when unrecorded.
struct FamilyTreeMarriage: Identifiable, Equatable {
    let id: String
    let spouse: FamilyTreePersonSummary?
    let marriedYear: String?

    init(id: String, spouse: FamilyTreePersonSummary?, marriageDate: String?) {
        self.id = id
        self.spouse = spouse
        self.marriedYear = FamilyTreeLifeSummary.yearPhrase(
            GedcomYearInterval.parse(marriageDate), raw: marriageDate)
    }
}
