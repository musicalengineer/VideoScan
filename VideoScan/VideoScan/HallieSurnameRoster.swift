// HallieSurnameRoster.swift
// LIVE MISS #11 (Rick, 2026-08-29): "tell me about pa oc'connor" → "I don't
// find “pa oc'connor” in the family tree — try a fuller name." The tree has
// O'Connors (Christopher Dennis, Mary b. 1905, Mary Catherine …); the
// SURNAME was one keystroke off ("oc'connor") and the GIVEN token was a
// family nickname ("Pa") no record carries. Every name tier threw the
// surname evidence away: exact and `namedLike` need "pa" as a name token,
// HallieSpellingRecovery makes tokens under four letters exact (and splits
// "oc'connor" into "oc" + "connor"), HallieNameSuggestion needs every typed
// token to land. So the honest answer became a bare decline.
//
// This is the layer between "no person by that name" and "nothing at all":
// a two-token name whose surname resolves — exactly, or by spelling
// recovery (edit distance ≤ 1 on the apostrophe/space-free form, at least
// four letters) — gives the surname roster as a which-one, or resolves
// through a People-tab / CyberBrain alias for the given token ("Pa" →
// Christopher). Pure: names and a graph in, a verdict out; no UI, no model,
// no catalog. The turn executor (HallieTurnExecutor+SurnameRoster) owns the
// re-execution and the reply text's plumbing.
//
// C++ readers: a namespace of static functions over value types. `Verdict`
// is a tagged union (enum with payloads) the caller switches on.

import Foundation
import VideoScanCore

enum HallieSurnameRoster {

    /// The typed name split as "<given> <surname…>". Nil unless there are at
    /// least two words and the first is letters (a nickname or a name, not
    /// a FamilySearch ID or a number).
    struct Split: Equatable {
        let given: String
        let surname: String

        var givenKey: String { FamilyIdentityText.tokens(given).first ?? "" }
    }

    static func split(_ typed: String) -> Split? {
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return nil }
        let given = words[0]
        let givenTokens = FamilyIdentityText.tokens(given)
        guard givenTokens.count == 1, let key = givenTokens.first, key.count >= 2,
              key.allSatisfy(\.isLetter),
              !GedcomFamilyGraph.nameSuffixes.contains(key) else { return nil }
        let surname = words.dropFirst().joined(separator: " ")
        guard !FamilyIdentityText.tokens(surname).isEmpty else { return nil }
        return Split(given: given, surname: surname)
    }

    /// The surname family the typed surname names.
    struct Family: Equatable {
        /// Canonical display spelling from the records ("O'Connor").
        let surname: String
        /// The surname as typed ("oc'connor"), for the basis line.
        let typedSurname: String
        /// True when the spelling had to be recovered (edit distance 1 or
        /// an apostrophe/space difference), false for an exact hit.
        let recovered: Bool
        /// Everyone carrying the surname, name order.
        let people: [GedcomFamilyGraph.Person]

        /// "took “oc'connor” as O'Connor" — only when recovery happened.
        var recoveryNote: String? {
            recovered ? "took “\(typedSurname)” as \(surname)" : nil
        }
    }

    /// Letters and digits only, lowercased and diacritic-folded: "O'Connor"
    /// and "O Connor" and "OConnor" all become "oconnor".
    static func compact(_ value: String) -> String {
        FamilyIdentityText.tokens(value).joined()
    }

    /// Exact surname first; otherwise the ONE surname family whose compact
    /// form equals the typed compact form or is one edit from it (typed
    /// compact form at least four letters — "pa" never recovers). Several
    /// different families at the same distance → nil (a guess would be a
    /// silent substitution). O(surname keys) with a capped edit distance;
    /// only reached after every exact tier failed.
    static func family(forSurname typedSurname: String, in graph: GedcomFamilyGraph) -> Family? {
        let exact = graph.people(withSurname: typedSurname)
        if !exact.isEmpty {
            return Family(surname: displaySurname(of: exact, fallback: typedSurname),
                          typedSurname: typedSurname, recovered: false,
                          people: ArchivistBiographyPolicy.orderedPeople(exact))
        }
        let typedCompact = compact(typedSurname)
        guard typedCompact.count >= 4 else { return nil }
        var sameCompact: [String] = []
        var oneEdit: [String] = []
        for key in graph.index.surnames.keys {
            let keyCompact = compact(key)
            guard !keyCompact.isEmpty else { continue }
            if keyCompact == typedCompact {
                sameCompact.append(key)
            } else if keyCompact.count >= 4,
                      HallieNameSuggestion.editDistance(typedCompact, keyCompact, limit: 1) <= 1 {
                oneEdit.append(key)
            }
        }
        // Keys that differ only by apostrophe/space ("o'connor", "oconnor")
        // are one family; one-edit keys are distinct families unless they
        // share a compact form.
        let chosen: [String]
        if !sameCompact.isEmpty {
            chosen = sameCompact
        } else {
            let families = Set(oneEdit.map(compact))
            guard families.count == 1 else { return nil }
            chosen = oneEdit
        }
        var byID: [String: GedcomFamilyGraph.Person] = [:]
        for key in chosen {
            for person in graph.people(withSurname: key) { byID[person.id] = person }
        }
        let people = ArchivistBiographyPolicy.orderedPeople(Array(byID.values))
        guard !people.isEmpty else { return nil }
        return Family(surname: displaySurname(of: people, fallback: chosen[0]),
                      typedSurname: typedSurname, recovered: true, people: people)
    }

    /// The commonest recorded spelling of the family's surname; the fallback
    /// (capitalized) when no record carries one.
    static func displaySurname(of people: [GedcomFamilyGraph.Person], fallback: String) -> String {
        var counts: [String: Int] = [:]
        for person in people {
            if let surname = person.surname, !surname.isEmpty { counts[surname, default: 0] += 1 }
        }
        if let best = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }) {
            return best.key
        }
        return HallieWhichOne.display(fallback)
    }

    /// Family members whose primary NAME record carries the given token or
    /// one of its diminutive forms (rick ↔ richard) as any non-surname
    /// token — first name or middle name. Empty when the token is a
    /// nickname no record carries ("Pa").
    static func members(named givenKey: String, in family: Family) -> [GedcomFamilyGraph.Person] {
        guard !givenKey.isEmpty else { return [] }
        let forms = Set(GedcomFamilyGraph.givenNameForms(of: givenKey))
        let surnameTokens = Set(FamilyIdentityText.tokens(family.surname))
        return family.people.filter { person in
            let tokens = FamilyIdentityText.tokens(FamilyNameNormalizer.normalizeName(person.name))
                .filter { !surnameTokens.contains($0) }
            return tokens.contains { forms.contains($0) }
        }
    }

    /// "O'Connors", "Joneses", "Lynches".
    static func plural(_ surname: String) -> String {
        let lower = surname.lowercased()
        if lower.hasSuffix("s") || lower.hasSuffix("x") || lower.hasSuffix("z")
            || lower.hasSuffix("ch") || lower.hasSuffix("sh") {
            return surname + "es"
        }
        return surname + "s"
    }

    /// The roster which-one. `labels` are the arranged chips' labels, in
    /// order; `arrangement` says how many were left out.
    static func prose(given: String, family: Family,
                      arrangement: HallieWhichOne.Arrangement, labels: [String]) -> String {
        let givenShown = HallieWhichOne.display(given)
        let plural = plural(family.surname)
        var text = "I don't know a “\(givenShown)” \(family.surname). "
        if arrangement.overflow > 0 {
            text += "The \(plural) in the tree include "
                + HallieNameQualifier.joined(labels, conjunction: "and")
                + "; there are \(arrangement.overflow) more — which one? Add a birth year to narrow it."
        } else {
            text += "The \(plural) in the tree are "
                + HallieNameQualifier.joined(labels, conjunction: "and")
                + " — which one?"
        }
        text += " (Or “let me tell you about \(givenShown) \(family.surname)” and I'll remember the name.)"
        return text
    }

    static func basis(given: String, family: Family,
                      arrangement: HallieWhichOne.Arrangement) -> String {
        var parts: [String] = []
        if let note = family.recoveryNote { parts.append(note) }
        parts.append("no \(family.surname) in the family tree goes by “\(HallieWhichOne.display(given))”")
        parts.append("\(arrangement.shown.count) of \(arrangement.total) \(plural(family.surname)) offered"
                     + (arrangement.anchored ? ", home people first" : ""))
        parts.append("nothing was looked up")
        return "Basis: " + parts.joined(separator: "; ") + "."
    }
}
