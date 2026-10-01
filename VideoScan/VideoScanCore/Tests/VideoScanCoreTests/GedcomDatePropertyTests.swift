// GedcomDatePropertyTests.swift
// Generated-input properties for the GEDCOM date readers (Rick approved
// 2026-10-01): GedcomYearInterval.parse, LifeAndTimes.DatedYear.parse,
// TreeWalkDate.parse / AgeAtDeath.between, and the ages Life & Times speaks.
//
// The generator builds a date as DATA (qualifier, day, month, year, a dual
// year like 1710/11, a calendar escape, case and spacing) and renders it;
// the oracle is the header table in GedcomYearInterval.swift. Properties:
//
//   D1  Oracle round trip: every generated date parses to the interval the
//       qualifier table says.
//   D2  For ANY text (fuzzed), a parsed interval has lower ≤ upper.
//   D3  spoken → parse round trip for exact / ABT / BEF / AFT.
//   D4  DatedYear and TreeWalkDate agree with GedcomYearInterval; month
//       bounds are ordered and inside the year bounds.
//   D5  Age at death is never negative for a consistent birth / death.
//   D6  Life & Times never speaks a negative age, and never a hedged zero
//       ("about 0", "at least 0", "no more than 0").
//
// Synthetic only; no person data.

import Foundation
import Testing
@testable import VideoScanCore

// MARK: - The generated date

struct GenDate: CustomStringConvertible {
    enum Shape {
        case exact, about(String), before, after, between, fromTo, from, to
    }
    let shape: Shape
    let year: Int
    /// Second year for BET / FROM…TO.
    let year2: Int
    let day: Int?
    let month: String?
    /// "1710/11": a dual (Old Style / New Style) year.
    let dual: Bool
    let text: String
    var description: String { text.debugDescription }

    /// A dual year counts as sub-year precision: "1710/11" only exists for
    /// 1 January – 24 March, so BEF / AFT keep the same year possible.
    var hasDayOrMonth: Bool { day != nil || month != nil || dual }

    /// GedcomYearInterval.swift's header table.
    var expected: (lower: Int?, upper: Int?, qualifier: GedcomYearInterval.Qualifier) {
        let k = GedcomYearInterval.approximateSlack
        switch shape {
        case .exact: return (year, year, .exact)
        case .about(let word):
            let q: GedcomYearInterval.Qualifier = word == "CAL" ? .calculated : (word == "EST" || word == "INT") ? .estimated : .about
            return (year - k, year + k, q)
        case .before: return (nil, hasDayOrMonth ? year : year - 1, .before)
        case .after: return (hasDayOrMonth ? year : year + 1, nil, .after)
        case .between: return (min(year, year2), max(year, year2), .between)
        case .fromTo: return (min(year, year2), max(year, year2), .range)
        case .from: return (year, nil, .range)
        case .to: return (nil, year, .range)
        }
    }
}

enum DateGenerator {
    static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// "4 MAR 1710", "MAR 1710", "1710", "1710/11" — the date part.
    static func datePart(year: Int, day: Int?, month: String?, dual: Bool) -> String {
        var y = String(year)
        if dual { y += "/" + String(format: "%02d", (year + 1) % 100) }
        return [day.map(String.init), month, y].compactMap { $0 }.joined(separator: " ")
    }

    static func gedcomDate(_ g: inout SeededGenerator) -> GenDate {
        let year = g.int(1000...2025)
        let year2 = g.chance(0.1) ? year : g.int(max(1000, year - 40)...min(2025, year + 40))
        let month: String? = g.chance(0.5) ? g.pick(months) : nil
        let day: Int? = month != nil && g.chance(0.6) ? g.int(1...28) : nil
        let dual = g.chance(0.08)
        let part = datePart(year: year, day: day, month: month, dual: dual)
        let part2 = datePart(year: year2, day: nil, month: g.chance(0.3) ? g.pick(months) : nil, dual: false)
        let shape: GenDate.Shape
        var text: String
        switch g.int(0...7) {
        case 0: shape = .exact; text = part
        case 1:
            let word = g.pick(["ABT", "ABOUT", "CAL", "EST", "INT"])
            shape = .about(word); text = "\(word) \(part)"
        case 2: shape = .before; text = "\(g.pick(["BEF", "BEFORE"])) \(part)"
        case 3: shape = .after; text = "\(g.pick(["AFT", "AFTER"])) \(part)"
        case 4: shape = .between; text = "BET \(part) AND \(part2)"
        case 5: shape = .fromTo; text = "FROM \(part) TO \(part2)"
        case 6: shape = .from; text = "FROM \(part)"
        default: shape = .to; text = "TO \(part)"
        }
        if g.chance(0.1) { text = "@#DJULIAN@ " + text }
        if g.chance(0.15) { text = text.lowercased() }
        if g.chance(0.1) { text = text.replacingOccurrences(of: " ", with: "  ") }
        return GenDate(shape: shape, year: year, year2: year2, day: day, month: month, dual: dual, text: text)
    }

    /// Anything at all: qualifier words, digits, punctuation, unicode.
    static func garbage(_ g: inout SeededGenerator) -> String {
        let atoms = ["ABT", "BEF", "AFT", "BET", "AND", "FROM", "TO", "CAL", "EST", "@#DJULIAN@", "MAR", "/", "-", "?",
                     "1710", "11", "0", "9999", "0000", "1", "12345", "½", "١٩٠٠", "Deceased", "unknown", "(", ")", "c.", " ", "  "]
        return (0..<g.int(0...8)).map { _ in g.pick(atoms) }.joined(separator: g.pick([" ", "", ","]))
    }
}

// MARK: - Suite

@Suite("GEDCOM dates — generated inputs")
struct GedcomDatePropertyTests {

    @Test("D1: every generated date parses to the qualifier table's interval", arguments: Property.batches)
    func oracleRoundTrip(batch: Int) {
        Property.check("date-oracle", batch: batch, generate: DateGenerator.gedcomDate) { d in
            guard let i = GedcomYearInterval.parse(d.text) else { return "nil" }
            let want = d.expected
            if i.lower != want.lower || i.upper != want.upper || i.qualifier != want.qualifier {
                return "got [\(i.lower.map(String.init) ?? "-∞"), \(i.upper.map(String.init) ?? "∞")] \(i.qualifier), "
                    + "want [\(want.lower.map(String.init) ?? "-∞"), \(want.upper.map(String.init) ?? "∞")] \(want.qualifier)"
            }
            // The anchor is the year as written; for a two-year range written
            // backwards ("BET 1148 AND 1140") the parser anchors on the
            // earlier year — either written year is accepted here.
            switch d.shape {
            case .between, .fromTo:
                if i.anchor != d.year, i.anchor != d.year2 { return "anchor \(String(describing: i.anchor))" }
            default:
                if i.anchor != d.year { return "anchor \(String(describing: i.anchor)), want \(d.year)" }
            }
            return nil
        }
    }

    @Test("D2: for any text, a parsed interval has lower ≤ upper", arguments: Property.batches)
    func boundsOrdered(batch: Int) {
        Property.check("date-bounds-ordered", batch: batch, generate: { g -> String in
            g.chance(0.5) ? DateGenerator.gedcomDate(&g).text : DateGenerator.garbage(&g)
        }, shrink: Shrink.text, describe: { $0.debugDescription }) { text in
            guard let i = GedcomYearInterval.parse(text) else { return nil }
            if let l = i.lower, let u = i.upper, l > u { return "lower \(l) > upper \(u)" }
            if let tw = TreeWalkDate.parse(text), let l = tw.lowerMonth, let u = tw.upperMonth, l > u {
                return "TreeWalkDate lowerMonth \(l) > upperMonth \(u)"
            }
            return nil
        }
    }

    @Test("D3: spoken → parse round trip for exact, about, before and after", arguments: Property.batches)
    func spokenRoundTrip(batch: Int) {
        Property.check("date-spoken", batch: batch, generate: { g -> String in
            let y = g.int(1000...2025)
            return g.pick(["\(y)", "ABT \(y)", "BEF \(y)", "AFT \(y)", "EST \(y)", "CAL \(y)"])
        }, describe: { $0.debugDescription }) { text in
            guard let i = GedcomYearInterval.parse(text) else { return "nil" }
            // "about 1700" / "before 1700" / "after 1700" are GEDCOM words too.
            guard let back = GedcomYearInterval.parse(i.spoken.uppercased()) else { return "spoken \(i.spoken) unparseable" }
            if back.lower != i.lower || back.upper != i.upper {
                return "\(text) → \"\(i.spoken)\" → [\(String(describing: back.lower)), \(String(describing: back.upper))]"
            }
            return nil
        }
    }

    @Test("D4: DatedYear and TreeWalkDate agree with the interval", arguments: Property.batches)
    func readersAgree(batch: Int) {
        Property.check("date-readers-agree", batch: batch, generate: DateGenerator.gedcomDate) { d in
            guard let i = GedcomYearInterval.parse(d.text) else { return "nil" }
            guard let dy = LifeAndTimes.DatedYear.parse(d.text) else { return "DatedYear nil" }
            if dy.lower != i.lower || dy.upper != i.upper || dy.anchor != i.anchor { return "DatedYear differs" }
            guard let tw = TreeWalkDate.parse(d.text) else { return "TreeWalkDate nil" }
            if let lm = tw.lowerMonth, let l = i.lower, lm / 12 < l { return "lowerMonth \(lm) before year \(l)" }
            if let um = tw.upperMonth, let u = i.upper, um / 12 > u { return "upperMonth \(um) after year \(u)" }
            if (tw.lowerMonth == nil) != (i.lower == nil) || (tw.upperMonth == nil) != (i.upper == nil) {
                return "open ends differ"
            }
            // A day of the month is never invented ("MAR 1710/11" has none).
            if case .exact = d.shape, tw.day != d.day {
                return "TreeWalkDate.day = \(tw.day.map(String.init) ?? "nil"), recorded day \(d.day.map(String.init) ?? "none")"
            }
            return nil
        }
    }

    @Test("D5: age at death is never negative for a consistent birth and death", arguments: Property.batches)
    func ageAtDeathNeverNegative(batch: Int) {
        Property.check("age-at-death", batch: batch, generate: { g -> (String, String) in
            // Exact-ish dates only (the walk computes ages from these);
            // the death is drawn from the birth year onwards.
            let by = g.int(1600...2000)
            let dy = g.chance(0.3) ? by : g.int(by...by + 100)
            func form(_ y: Int, _ g: inout SeededGenerator) -> String {
                switch g.int(0...2) {
                case 0: return "\(y)"
                case 1: return "\(g.pick(DateGenerator.months)) \(y)"
                default: return "\(g.int(1...28)) \(g.pick(DateGenerator.months)) \(y)"
                }
            }
            return (form(by, &g), form(dy, &g))
        }, describe: { "born \($0.0.debugDescription), died \($0.1.debugDescription)" }) { input in
            guard let b = TreeWalkDate.parse(input.0), let d = TreeWalkDate.parse(input.1),
                  let bLo = b.lowerMonth, let dHi = d.upperMonth else { return nil }
            // Consistent: the death can fall on or after the birth.
            if dHi < bLo { return nil }
            if b.precision == .day, d.precision == .day, b.lowerMonth == d.lowerMonth, (d.day ?? 0) < (b.day ?? 0) { return nil }
            guard let age = AgeAtDeath.between(birth: b, death: d) else { return nil }
            if age.minYears < 0 || age.maxYears < 0 { return "age \(age.spoken) (min \(age.minYears))" }
            if age.minYears > age.maxYears { return "min \(age.minYears) > max \(age.maxYears)" }
            return nil
        }
    }

    @Test("D6: Life & Times never speaks a negative age or a hedged zero", arguments: Property.batches)
    func lifeAndTimesAges(batch: Int) {
        let options = LifeAndTimes.Options(currentYear: 2026)
        Property.check("life-and-times-ages", batch: batch, cases: 250, generate: { g -> LifeAndTimes.Subject in
            let birth = DateGenerator.gedcomDate(&g)
            var death: String?
            if g.chance(0.7) {
                let y = g.int(birth.year...min(2025, birth.year + 100))
                death = g.pick(["\(y)", "ABT \(y)", "BEF \(y)", "AFT \(y)", "Deceased", "\(g.int(1...28)) MAR \(y)"])
            }
            let places = [PlaceGenerator.usPlace(&g).text, PlaceGenerator.islesPlace(&g).text, "Lyon, France"]
            return LifeAndTimes.Subject(id: "@I1@", name: "Ansel Fenlane", surname: "Fenlane", sex: g.pick(["M", "F", ""]),
                                        birthDate: birth.text, deathDate: death,
                                        birthPlace: g.pick(places), deathPlace: g.chance(0.5) ? g.pick(places) : nil,
                                        residences: g.chance(0.4) ? [GedcomLifeDetails.Residence(place: g.pick(places),
                                                                                                  date: "\(g.int(1700...1950))")] : [])
        }, describe: { "born \($0.birthDate.debugDescription) died \($0.deathDate.debugDescription) at \($0.birthPlace ?? "-")" }) { s in
            guard let facts = LifeAndTimes.facts(for: s, options: options) else { return nil }
            var ages: [(String, LifeAndTimes.QualifiedAge)] = []
            for l in facts.livedThrough {
                if let a = l.ageAtStart { ages.append((l.eventID + " start", a)) }
                if let a = l.ageAtEnd { ages.append((l.eventID + " end", a)) }
            }
            for c in facts.service {
                if let a = c.ageAtStart { ages.append((c.warID + " start", a)) }
                if let a = c.ageAtEnd { ages.append((c.warID + " end", a)) }
            }
            for (label, a) in ages {
                if a.nominal < 0 || (a.low ?? 0) < 0 || (a.high ?? 0) < 0 { return "\(label): negative age \(a)" }
                if let l = a.low, let h = a.high, l > h { return "\(label): low \(l) > high \(h)" }
            }
            for line in facts.storyLines {
                if line.firstMatch(of: #/\b(?:about|at least|no more than) 0\b|\bbetween 0 and 0\b/#) != nil { return "says: \(line)" }
                if line.firstMatch(of: #/\s-\d/#) != nil { return "negative: \(line)" }
            }
            return nil
        }
    }
}
