// POINameForms.swift
// Last names, maiden names, middle names and generational suffixes for the
// People tab (Rick, 2026-09-04).
//
// WHY THIS EXISTS
// A POI profile's `name` is the SHORT name — what the family actually calls
// the person ("Tim", "Ma", "Dad"). Until now that short name plus `aliases`
// were the only spellings anything matched on, so "how many videos have Tim
// Breen in them" never reached the Tim on the People tab and fell through to
// a transcript keyword search. And the tree knows Rick's mother as Eileen
// Latta while the family called her Ma and her married name is Breen — a
// mismatch that produced a wrong-person answer on 2026-09-03.
//
// TWO RULES, BOTH LOAD-BEARING
//
// 1. A FORM IS ALWAYS BUILT FROM A KNOWN GIVEN NAME. Every generated
//    spelling starts with a name this profile already answers to (its own
//    `name`, or one of its `aliases`). A surname NEVER becomes a spelling on
//    its own: in a 39,250-person tree "Breen" belongs to hundreds of people,
//    and letting a bare surname resolve to one of them would be the worst
//    possible failure — a confident wrong answer. Pinned by
//    `aBareSurnameResolvesToNobodyInParticular`.
//
// 2. TITLES ARE DISPLAY ONLY. "Grampa", "Pops", "Dad" are RELATIONAL — they
//    point at a different person depending on who is speaking. Rick's sons'
//    "Dad" is Rick; Tim's "Dad" is their father. Making them matchable would
//    recreate exactly the Mom/Ma collision that caused the wrong-person
//    answer. `titles` is therefore never read here and never reaches the
//    resolver. A distinctive form Rick DOES want to resolve ("Grampa Dicky")
//    is what `aliases` is for, and that already works.
//
// BLANK IS ABSENT. A field left empty in PersonEditSheet arrives as "", not
// nil. Everything here trims and treats ""/whitespace as absent, so a
// profile with every new field blank behaves byte-identically to one written
// before the fields existed — which is all thirteen live profiles today.
//
// MEMORY: worst case 8 given names x 5 forms = 40 short strings per profile
// (~2 KB), computed on demand, never cached. Thirteen profiles ⇒ noise.

import Foundation
import VideoScanCore

/// Trimming/blank-collapsing helpers shared by the model, the sheet and the
/// form builder, so "" and "   " mean *absent* at every point of use.
/// (C++: free functions in an anonymous-ish namespace — no state.)
enum POINameText {

    /// Trimmed, or nil when the result is empty. The ONE place blank
    /// collapses to absent; call it on every write and every read.
    static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Trims every element, drops blanks, and removes case-insensitive
    /// duplicates while preserving Rick's authored order.
    static func cleaned(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.compactMap { cleaned($0) }
            .filter { seen.insert(PersonResolver.normalize($0)).inserted }
    }

    /// Joins the non-blank parts with single spaces. Guards the whole class
    /// of "Tim  Breen" / "Tim Breen " / "Richard Harding Breen " bugs that a
    /// blank component otherwise produces.
    static func join(_ parts: [String?]) -> String {
        parts.compactMap { cleaned($0) }.joined(separator: " ")
    }

    /// Normalized word tokens ("Breen Jr." → ["breen", "jr"]). Same
    /// tokenization rule the resolver's spelling recovery uses.
    static func tokens(_ raw: String?) -> [String] {
        guard let value = cleaned(raw) else { return [] }
        return PersonResolver.normalize(value)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// A generational suffix as this project spells it everywhere else:
    /// bare token, no trailing period. `FamilyAssetStore.groupFolderMatches`
    /// and `HallieOwnerResolver` both filter `GedcomFamilyGraph.nameSuffixes`
    /// out of name tokens, so "Jr." and "Jr" must not become two conventions.
    /// A non-generational suffix Rick types anyway is kept verbatim.
    static func cleanedSuffix(_ raw: String?) -> String? {
        guard let value = cleaned(raw) else { return nil }
        let stripped = value.hasSuffix(".") ? String(value.dropLast()) : value
        return cleaned(stripped)
    }
}

/// Builds the exact-match spellings a profile's family-name fields imply.
/// Pure and value-typed so it can be tested without profiles on disk.
struct POINameForms: Equatable {

    /// The profile's short name — the display name, never renamed.
    let shortName: String
    /// Given names this profile already answers to: `name` + `aliases`,
    /// minus anything that already carries a family name or is a bare
    /// suffix (an alias "Eileen Latta" must not yield "Eileen Latta Breen").
    let givenNames: [String]
    let middleName: String?
    let surname: String?
    let maidenName: String?
    let suffix: String?

    /// Bounds on the generated set. Aliases are a hand-typed list of a
    /// handful of names; these caps exist so a pathological profile cannot
    /// grow the resolver index without limit.
    static let maxGivenNames = 8
    static let maxForms = 40

    init(name: String,
         aliases: [String] = [],
         middleName: String? = nil,
         surname: String? = nil,
         maidenName: String? = nil,
         suffix: String? = nil) {
        self.shortName = POINameText.cleaned(name) ?? ""
        self.middleName = POINameText.cleaned(middleName)
        self.surname = POINameText.cleaned(surname)
        self.maidenName = POINameText.cleaned(maidenName)
        self.suffix = POINameText.cleanedSuffix(suffix)

        // PERFORMANCE, and it is not academic: the temporal route asks every
        // profile whether it answers to a spelling, and
        // HallieTurnExecutorTests drives that with 100,000 profiles under a
        // 3-second budget. With no family name there is nothing to combine,
        // so skip the tokenizing entirely rather than doing it 100,000 times
        // to produce an empty array. (Callers early-out too; this is the
        // belt to their braces.)
        guard self.surname != nil || self.maidenName != nil else {
            self.givenNames = []
            return
        }

        // Tokens that make a candidate a COMPLETE spelling already. Combining
        // one of these with a surname produces nonsense ("Eileen Latta Breen",
        // "Dad Breen Breen"), and the pieces we would have added are supplied
        // by the field itself anyway.
        var family = Set<String>()
        for part in [self.surname, self.maidenName, self.middleName, self.suffix] {
            family.formUnion(POINameText.tokens(part))
        }
        let generational = GedcomFamilyGraph.nameSuffixes

        let candidates = [self.shortName] + POINameText.cleaned(aliases)
        var seen = Set<String>()
        self.givenNames = candidates.filter { candidate in
            let tokens = POINameText.tokens(candidate)
            guard !tokens.isEmpty else { return false }
            // Not a bare "Jr" / "III".
            guard tokens.contains(where: { !generational.contains($0) }) else { return false }
            guard tokens.allSatisfy({ !family.contains($0) }) else { return false }
            return seen.insert(PersonResolver.normalize(candidate)).inserted
        }
        .prefix(Self.maxGivenNames)
        .map { $0 }
    }

    /// How a profile-derived answer names this person on FIRST mention:
    /// short name + last name (+ generational suffix), e.g. "Tim Breen",
    /// "Richard Breen Sr". Equals the short name when no surname is set, so
    /// every existing profile's prose is unchanged.
    ///
    /// The MIDDLE name is deliberately absent: `name` is a short name, and
    /// "Dad Harding Breen Sr" is not a thing anyone says. Middle name earns
    /// its keep in the matching forms below and, later, in tree bridging.
    var displayFullName: String {
        let full = POINameText.join([shortName, surname, suffix])
        return full.isEmpty ? shortName : full
    }

    /// True when `displayFullName` says more than the short name — the only
    /// case where first-mention phrasing differs from today.
    var hasFullName: Bool {
        PersonResolver.normalize(displayFullName) != PersonResolver.normalize(shortName)
    }

    /// The exact-match spellings this profile's family-name fields imply.
    /// Five shapes per given name G, each emitted only when every component
    /// it needs is present:
    ///
    ///   G + surname                     "Tim Breen"
    ///   G + middle + surname            "Richard Harding Breen"
    ///   G + surname + suffix            "Richard Breen Sr"
    ///   G + middle + surname + suffix   "Richard Harding Breen Sr"
    ///   G + maidenName                  "Eileen Latta"
    ///
    /// Never a bare surname, maiden name or suffix — see rule 1 in the file
    /// header. Order is deterministic (given names in Rick's authored order,
    /// shapes in the order above) so a failing test names one spelling.
    var matchingForms: [String] {
        guard surname != nil || maidenName != nil else { return [] }
        let shortKey = PersonResolver.normalize(shortName)
        var seen = Set<String>()
        var forms: [String] = []
        for given in givenNames {
            let shapes: [[String?]] = [
                [given, surname],
                [given, middleName, surname],
                [given, surname, suffix],
                [given, middleName, surname, suffix],
                [given, maidenName],
            ]
            for shape in shapes {
                // Every named component must be present, or the shape
                // degrades into a shorter one we already emit (and, with a
                // blank surname, into the bare given name).
                guard shape.allSatisfy({ POINameText.cleaned($0) != nil }) else { continue }
                let form = POINameText.join(shape)
                let key = PersonResolver.normalize(form)
                guard key != shortKey, seen.insert(key).inserted else { continue }
                forms.append(form)
                if forms.count == Self.maxForms { return forms }
            }
        }
        return forms
    }
}
