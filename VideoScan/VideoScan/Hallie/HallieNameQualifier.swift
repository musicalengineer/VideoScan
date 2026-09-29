// HallieNameQualifier.swift
// "Nathaniel Parker born 1651" / "Nathaniel Parker (b. 1651)" / "Nathaniel
// Parker who died in 1737": a name with a birth- or death-year qualifier
// that picks ONE of several namesakes (live 2026-08-27: "are there any
// photos of Nathaniel Parker born 1651"). Exact years only, against
// UNQUALIFIED GEDCOM dates: "ABT 1651" / "BEF 1651" never match, because
// "before 1651" is not "born 1651". Deterministic, no model.
//
// TEMPORARY: retire when eval category media-by-person passes via proposer
// (the qualifier becomes a typed `personQualifier` in the AST/tool
// contract in phase 0; this text form exists only for the deterministic
// photo shape until then).

import Foundation
import VideoScanCore

struct HallieNameQualifier: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        /// Born in this year ("born 1651", "b. 1651", "(b. 16 May 1651, …)").
        case born(Int)
        /// Died in this year ("died in 1737", "d. 1737").
        case died(Int)

        var description: String {
            switch self {
            case .born(let y): return "born \(y)"
            case .died(let y): return "died \(y)"
            }
        }
    }

    /// The name with the qualifier removed, as typed (case kept).
    let name: String
    let kind: Kind

    // MARK: Parsing

    /// The qualifier on a typed person string, or nil for a plain name. A
    /// generational suffix ("Sr", "Jr") is NOT a qualifier here:
    /// `GedcomFamilyGraph.people(namedLike:)` already honours it.
    static func parse(_ typed: String) -> HallieNameQualifier? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard !lower.isEmpty else { return nil }
        // "<name> (b. 16 May 1651, d. 7 December 1737)" / "<name> (born 1651)".
        if let m = lower.firstMatch(of: /^(.*?)\s*\(([^)]*)\)\s*$/) {
            guard let kind = kind(inQualifier: String(m.2)) else { return nil }
            let name = String(text.prefix(m.1.count)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : HallieNameQualifier(name: name, kind: kind)
        }
        // "<name> born 1651" / "<name> b. 1651" / "<name> who died in 1737" / "<name> d. 1737".
        if let m = lower.firstMatch(of: /^(.*?)\s+((?:who\s+)?(?:born|b\.|died|d\.)\s+(?:in\s+)?(?:1[0-9]{3}|20[0-9]{2}))$/) {
            guard let kind = kind(inQualifier: String(m.2)) else { return nil }
            let name = String(text.prefix(m.1.count)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : HallieNameQualifier(name: name, kind: kind)
        }
        return nil
    }

    /// "b. 16 May 1651, d. 7 December 1737" → born 1651 (birth outranks
    /// death, the way a chip label reads); "died 1737" → died. Nil when
    /// there is no birth/death marker with a year ("Framingham").
    private static func kind(inQualifier phrase: String) -> Kind? {
        let lower = phrase.lowercased()
        if let m = lower.firstMatch(of: /(?:\bb\.|\bborn\b).*?\b(1[0-9]{3}|20[0-9]{2})\b/),
           let year = Int(m.1) {
            return .born(year)
        }
        if let m = lower.firstMatch(of: /(?:\bd\.|\bdied\b).*?\b(1[0-9]{3}|20[0-9]{2})\b/),
           let year = Int(m.1) {
            return .died(year)
        }
        return nil
    }

    // MARK: Selection

    /// The candidates whose recorded year IS the qualifier's year. A GEDCOM
    /// date carrying its own qualifier (ABT / BEF / AFT / EST / CAL / BET)
    /// never matches — honesty over convenience.
    func select(_ candidates: [GedcomFamilyGraph.Person]) -> [GedcomFamilyGraph.Person] {
        func matches(_ date: String?, _ recorded: Int?, _ year: Int) -> Bool {
            guard let date, let recorded, recorded == year else { return false }
            return !Self.isQualifiedDate(date)
        }
        switch kind {
        case .born(let year):
            return candidates.filter { matches($0.birthDate, $0.birthYear, year) }
        case .died(let year):
            return candidates.filter { matches($0.deathDate, $0.deathYear, year) }
        }
    }

    /// "ABT 1651", "BEF 1651", "BET 1650 AND 1652", "EST 1651", "CAL 1651",
    /// "AFT 1651": a date the tree itself is unsure of.
    static func isQualifiedDate(_ date: String) -> Bool {
        date.trimmingCharacters(in: .whitespaces).lowercased()
            .firstMatch(of: /^(?:abt|about|bef|before|aft|after|est|cal|bet|between|circa|c\.)\b/) != nil
    }

    // MARK: Wording

    /// "born 1651 and 1760" — the years the namesakes actually have, in
    /// birth order, for the honest miss ("I have two Nathaniel Parkers,
    /// born 1651 and 1760 — neither born 1660."). A tree-qualified date is
    /// shown as the tree has it ("ABT 1700").
    static func yearsPhrase(_ unsorted: [GedcomFamilyGraph.Person], kind: Kind) -> String {
        let people = unsorted.sorted { ($0.birthYear ?? Int.max, $0.name) < ($1.birthYear ?? Int.max, $1.name) }
        let years: [String]
        let word: String
        switch kind {
        case .died:
            word = "died"
            years = people.map { $0.deathDate ?? "death unrecorded" }
        case .born:
            word = "born"
            years = people.map { $0.birthDate ?? "birth unrecorded" }
        }
        return word + " " + joined(years.map(shortDate))
    }

    /// "16 MAY 1651" → "1651"; "ABT 1700" stays "ABT 1700".
    private static func shortDate(_ raw: String) -> String {
        isQualifiedDate(raw) ? raw : (raw.firstMatch(of: /\b(1[0-9]{3}|20[0-9]{2})\b/).map { String($0.1) } ?? raw)
    }

    static func joined(_ items: [String], conjunction: String = "and") -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + " \(conjunction) " + items[1]
        default: return items.dropLast().joined(separator: ", ") + ", \(conjunction) " + items[items.count - 1]
        }
    }

    static func countWord(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return words.indices.contains(n) ? words[n] : String(n)
    }
}
