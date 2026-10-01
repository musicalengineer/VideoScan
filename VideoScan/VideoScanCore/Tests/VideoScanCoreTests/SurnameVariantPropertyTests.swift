// SurnameVariantPropertyTests.swift
// Generated-input properties for SurnameSpellingVariants and the Record
// Finder's given-name / surname split (Rick approved 2026-10-01):
//
//   S1  The original (trimmed) spelling is always first.
//   S2  Deterministic: the same input gives the same list.
//   S3  Never more than `limit`; no duplicates (case-insensitive); no
//       empty or one-letter entries.
//   S4  Irish-form names (Ó / Ní / Nic / Mac / Uí …, lenition, síneadh
//       fada — composed OR decomposed Unicode, any case) are returned
//       exactly as written, never mangled.
//   S5  A record with no surname never sends its given name as one: no
//       Record Finder URL carries the given name in a surname field.
//
// Synthetic: invented English-style surnames built from syllables, and
// Irish forms built from generic stems — no family names.

import Foundation
import Testing
@testable import VideoScanCore

enum SurnameGenerator {
    static let onsets = ["D", "M", "K", "Br", "F", "Gl", "Qu", "T", "R", "Sh", "Mc", "Mac", "O'", "O’", "O "]
    static let middles = ["or", "al", "enn", "ill", "oy", "ar", "ul", "ow", "e", "ann"]
    static let endings = ["an", "ane", "ayne", "aine", "ey", "y", "ly", "ley", "son", "ell", "ick", "in", "agh"]

    /// "Dorran", "McGlowley", "O'Tellan" — English clerk shapes.
    static func anglicised(_ g: inout SeededGenerator) -> String {
        var onset = g.pick(onsets)
        if onset == "Mc" || onset == "Mac" || onset.hasPrefix("O") {
            onset += g.pick(["D", "G", "K", "T", "B"])          // McD…, MacG…, O'K…
        }
        var s = onset + g.pick(middles) + (g.chance(0.4) ? g.pick(middles) : "") + g.pick(endings)
        if g.chance(0.1) { s = s.uppercased() } else if g.chance(0.1) { s = s.lowercased() }
        if g.chance(0.1) { s = " " + s + "\t" }
        return s
    }

    static let irishPrefixes = ["Ó", "Ní", "Nic", "Mac", "Mhic", "Uí", "Ua", "Mag"]
    static let lenitedStems = ["Bhriain", "Dhónaill", "Fhloinn", "Mhaoláin", "Chonaill", "Shúilleabháin",
                               "Giolla Phádraig", "Dhubhthaigh", "Néill", "Cheallaigh", "Ghráda"]

    /// "Ó Shúilleabháin", "NÍ BHRIAIN", "mac giolla phádraig", NFD forms.
    static func irish(_ g: inout SeededGenerator) -> String {
        var s = g.pick(irishPrefixes) + " " + g.pick(lenitedStems)
        if g.chance(0.15) { s = s.uppercased() } else if g.chance(0.15) { s = s.lowercased() }
        // macOS file names and pasted text often arrive DECOMPOSED (NFD):
        // "O" + U+0301 rather than "Ó".
        if g.chance(0.3) { s = s.decomposedStringWithCanonicalMapping }
        return s
    }
}

@Suite("Surname spelling variants — generated inputs")
struct SurnameVariantPropertyTests {

    @Test("S1–S3: original first, deterministic, bounded, unique", arguments: Property.batches)
    func shapeOfTheList(batch: Int) {
        Property.check("surname-variants-shape", batch: batch, generate: { g -> (String, Int) in
            (g.chance(0.85) ? SurnameGenerator.anglicised(&g) : SurnameGenerator.irish(&g), g.int(1...12))
        }, describe: { "\($0.0.debugDescription) limit \($0.1)" }) { input in
            let (name, limit) = input
            let v = SurnameSpellingVariants.variants(of: name, limit: limit)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.first != trimmed { return "first is \(v.first.debugDescription), want \(trimmed.debugDescription)" }
            if v != SurnameSpellingVariants.variants(of: name, limit: limit) { return "not deterministic" }
            if v.count > limit { return "\(v.count) > limit \(limit)" }
            if Set(v.map { $0.lowercased() }).count != v.count { return "duplicates in \(v)" }
            if let bad = v.first(where: { $0.count < 2 }) { return "too short: \(bad.debugDescription) in \(v)" }
            // A prefix of a longer limit's list: the cap only truncates.
            let longer = SurnameSpellingVariants.variants(of: name, limit: limit + 3)
            if Array(longer.prefix(v.count)) != v { return "limit \(limit) is not a prefix of limit \(limit + 3)" }
            return nil
        }
    }

    @Test("S4: Irish-form names are never mangled", arguments: Property.batches)
    func irishFormsUntouched(batch: Int) {
        Property.check("surname-irish-forms", batch: batch, generate: SurnameGenerator.irish,
                       describe: { "\($0.debugDescription) (\($0.unicodeScalars.count) scalars)" }) { name in
            let v = SurnameSpellingVariants.variants(of: name, limit: 10)
            return v == [name] ? nil : "variants \(v)"
        }
    }

    @Test("S5: a record with no surname never sends its given name as one", arguments: Property.batches)
    func givenNameNeverASurname(batch: Int) {
        let surnameFields: Set<String> = ["surname", "q.surname", "lastname", "familyname", "family_names"]
        Property.check("given-not-surname", batch: batch, cases: 250, generate: { g -> RecordFinder.Person in
            let givens = ["Bridget", "Honora", "Cornelius", "Thomasina", "Ansel"]
            let name = (0..<g.int(1...3)).map { _ in g.pick(givens) }.joined(separator: " ")
            let places = [PlaceGenerator.islesPlace(&g).text, PlaceGenerator.usPlace(&g).text]
            return RecordFinder.Person(name: name, surname: g.chance(0.5) ? nil : "", birthYear: g.int(1800...1920),
                                       deathYear: g.chance(0.5) ? g.int(1850...1990) : nil,
                                       birthPlace: g.pick(places), deathPlace: g.pick(places),
                                       servedInMilitary: g.chance(0.3))
        }, describe: { "\($0)" }) { person in
            let context = RecordFinder.Context(person)
            let sites = RecordFinder.ireland + RecordFinder.military + RecordFinder.britain + RecordFinder.burials
            for site in sites {
                guard let link = RecordFinder.link(for: site, in: context),
                      let items = URLComponents(url: link.url, resolvingAgainstBaseURL: false)?.queryItems else { continue }
                for item in items where surnameFields.contains(item.name) {
                    if let value = item.value, !value.isEmpty { return "\(site.id): \(item.name)=\(value)" }
                }
            }
            return nil
        }
    }
}
