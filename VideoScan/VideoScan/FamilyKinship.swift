// FamilyKinship.swift
// Typed, local-only family relationships between People-tab profiles (and,
// optionally, family-tree people). Director decision (Rick, 2026-08-27):
// contemporary family — parents, brother Tim, the four sons, in-laws,
// cousins — will NEVER be entered into FamilySearch (living-person
// privacy). The FamilySearch GEDCOM is ancestors-only, so Rick's own
// record there has no siblings or children. These relationships therefore
// live in profile.json, typed, and are never written to a GEDCOM file.
//
// Storage is one row per stored fact: "<this profile> is <relation> of
// <anchor>". Everything else — the inverse ("Tim is Rick's brother" implies
// "Rick is Tim's brother"), gendered words ("brother"/"sister"), older /
// younger, and composed relations (spouse-of-sibling = sibling-in-law) —
// is DERIVED at read time by FamilyKinshipOverlay and never stored, so a
// birthdate or sex edit is reflected immediately with no migration.
//
// C++ readers: these enums with `String` raw values are what lands in
// profile.json — renaming a case is a persistence-format change. `Codable`
// synthesis on the enum-with-payload `KinshipAnchor` writes a one-key
// object ({"profile":{"name":"Tim"}}), which is stable across builds.

import Foundation

/// The closed relation vocabulary. Ungendered on purpose: sex lives on the
/// profile (or the tree record), so the word shown is derived, not stored.
enum KinshipRelation: String, Codable, CaseIterable, Hashable, Sendable {
    case parent, child, sibling, spouse
    case grandparent, grandchild
    case auntUncle, nieceNephew
    case cousin
    case parentInLaw, childInLaw, siblingInLaw

    /// "A is X of B" ⇒ "B is X.inverse of A".
    var inverse: KinshipRelation {
        switch self {
        case .parent:       return .child
        case .child:        return .parent
        case .sibling:      return .sibling
        case .spouse:       return .spouse
        case .grandparent:  return .grandchild
        case .grandchild:   return .grandparent
        case .auntUncle:    return .nieceNephew
        case .nieceNephew:  return .auntUncle
        case .cousin:       return .cousin
        case .parentInLaw:  return .childInLaw
        case .childInLaw:   return .parentInLaw
        case .siblingInLaw: return .siblingInLaw
        }
    }

    /// The word for this relation given the RELATED person's sex (the one
    /// the word describes: for "Tim is Rick's brother" that is Tim). nil ⇒
    /// the neutral term.
    func term(sex: PersonSex?) -> String {
        let words = Self.words[self] ?? (neutral: rawValue, male: rawValue, female: rawValue)
        switch sex {
        case .male?:   return words.male
        case .female?: return words.female
        case nil:      return words.neutral
        }
    }

    /// (neutral, male, female) per relation — one row per case, so a
    /// vocabulary change is a table edit, not a switch edit.
    private static let words: [KinshipRelation: (neutral: String, male: String, female: String)] = [
        .parent:       ("parent", "father", "mother"),
        .child:        ("child", "son", "daughter"),
        .sibling:      ("sibling", "brother", "sister"),
        .spouse:       ("spouse", "husband", "wife"),
        .grandparent:  ("grandparent", "grandfather", "grandmother"),
        .grandchild:   ("grandchild", "grandson", "granddaughter"),
        .auntUncle:    ("aunt or uncle", "uncle", "aunt"),
        .nieceNephew:  ("niece or nephew", "nephew", "niece"),
        .cousin:       ("cousin", "cousin", "cousin"),
        .parentInLaw:  ("parent-in-law", "father-in-law", "mother-in-law"),
        .childInLaw:   ("child-in-law", "son-in-law", "daughter-in-law"),
        .siblingInLaw: ("sibling-in-law", "brother-in-law", "sister-in-law"),
    ]

    /// Neutral label for pickers and menus.
    var label: String { term(sex: nil) }

    /// Only siblings get "older"/"younger" (cousins and in-laws don't read
    /// naturally that way).
    var supportsAgeOrder: Bool { self == .sibling }

    /// The relation named by a gendered/neutral word from the shared graph
    /// vocabulary ("brother", "mother-in-law", "cousins"…), plus the sex the
    /// word implies. nil for words the overlay cannot express (great-grand…).
    static func parse(term raw: String) -> (relation: KinshipRelation, sex: PersonSex?)? {
        Self.termTable[raw.lowercased()]
    }

    /// Every gendered / neutral / plural word the graph vocabulary uses,
    /// built from `words` plus the plural spellings the wire format carries.
    private static let termTable: [String: (relation: KinshipRelation, sex: PersonSex?)] = {
        var table: [String: (relation: KinshipRelation, sex: PersonSex?)] = [:]
        for (relation, w) in words {
            table[w.male] = (relation, .male)
            table[w.female] = (relation, .female)
            table[w.neutral] = (relation, nil)
        }
        let plurals: [String: (relation: KinshipRelation, sex: PersonSex?)] = [
            "parents": (.parent, nil), "children": (.child, nil),
            "sons": (.child, .male), "daughters": (.child, .female),
            "siblings": (.sibling, nil), "brothers": (.sibling, .male), "sisters": (.sibling, .female),
            "spouses": (.spouse, nil), "grandparents": (.grandparent, nil), "grandchildren": (.grandchild, nil),
            "uncles": (.auntUncle, .male), "aunts": (.auntUncle, .female), "aunts-and-uncles": (.auntUncle, nil),
            "nephews": (.nieceNephew, .male), "nieces": (.nieceNephew, .female), "nieces-and-nephews": (.nieceNephew, nil),
            "cousins": (.cousin, nil), "parents-in-law": (.parentInLaw, nil),
        ]
        table.merge(plurals) { _, new in new }
        // "cousin" is unisex: the neutral entry must win over male/female.
        table["cousin"] = (.cousin, nil)
        return table
    }()

    /// Fold a chain of stored relations into one named relation, when the
    /// chain has a single English name. Hops read from the anchor OUTWARD:
    /// `[.sibling, .child]` = "the anchor's sibling's child" = niece/nephew.
    /// The table is applied left-to-right, two hops at a time, so
    /// `[.parent, .sibling, .child]` folds to auntUncle then to cousin.
    /// nil when no single word fits ("your brother's wife's mother").
    static func compose(_ hops: [KinshipRelation]) -> KinshipRelation? {
        guard var current = hops.first else { return nil }
        for next in hops.dropFirst() {
            guard let folded = compose(current, next) else { return nil }
            current = folded
        }
        return current
    }

    /// One fold: "the anchor's `first`'s `second`" → single relation.
    static func compose(_ first: KinshipRelation, _ second: KinshipRelation) -> KinshipRelation? {
        Self.folds[Fold(first, second)]
    }

    private struct Fold: Hashable {
        let first: KinshipRelation
        let second: KinshipRelation
        init(_ first: KinshipRelation, _ second: KinshipRelation) {
            self.first = first
            self.second = second
        }
    }

    /// The fold table. Absent pairs (spouse∘spouse, parent∘grandparent =
    /// great-grand…) have no single word in this vocabulary → nil.
    private static let folds: [Fold: KinshipRelation] = [
        Fold(.parent, .parent):        .grandparent,
        Fold(.child, .child):          .grandchild,
        Fold(.parent, .sibling):       .auntUncle,
        Fold(.sibling, .child):        .nieceNephew,
        Fold(.spouse, .sibling):       .siblingInLaw,
        Fold(.sibling, .spouse):       .siblingInLaw,
        Fold(.spouse, .parent):        .parentInLaw,
        Fold(.child, .spouse):         .childInLaw,
        Fold(.auntUncle, .child):      .cousin,
        Fold(.parent, .child):         .sibling,      // caller drops self
        Fold(.auntUncle, .spouse):     .auntUncle,    // uncle by marriage
        Fold(.spouse, .child):         .child,        // shared child
        Fold(.parent, .spouse):        .parent,       // step-parent, close enough
        Fold(.spouse, .nieceNephew):   .nieceNephew,
        Fold(.siblingInLaw, .spouse):  .siblingInLaw, // brother-in-law's wife
        Fold(.parentInLaw, .spouse):   .parentInLaw,
        Fold(.sibling, .sibling):      .sibling,
    ]
}

/// Who a stored relationship points at. A profile is identified by its
/// canonical name (POIProfile.id is `name.lowercased()` — there is no other
/// stable id today); a tree person by FamilySearch ID, which survives GEDCOM
/// re-exports when `@I…@` pointers move.
enum KinshipAnchor: Codable, Hashable, Sendable {
    case profile(name: String)
    case treePerson(familySearchID: String)

    /// Case-insensitive identity key, comparable with POIProfile.id.
    var key: String {
        switch self {
        case .profile(let name):
            return "profile:" + PersonResolver.normalize(name)
        case .treePerson(let id):
            return "tree:" + id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
    }
}

/// One stored fact on a profile: "this profile is `relation` of `relativeTo`".
/// Example on Tim's profile: (.sibling, .profile("Rick")) ⇒ Tim is Rick's
/// sibling; with Tim's sex and both birthdates known this displays as
/// "Rick's younger brother".
struct Kinship: Codable, Hashable, Sendable {
    var relation: KinshipRelation
    var relativeTo: KinshipAnchor
    var note: String?

    init(relation: KinshipRelation, relativeTo: KinshipAnchor, note: String? = nil) {
        self.relation = relation
        self.relativeTo = relativeTo
        self.note = note
    }
}

// MARK: - Display helpers

enum KinshipDisplay {

    /// "older" / "younger" from two birthdates, nil when either is unknown or
    /// the relation doesn't take an age word. `subjectBirth` is the person
    /// being described (Tim), `anchorBirth` the reference (Rick).
    static func ageWord(
        _ relation: KinshipRelation,
        subjectBirth: Date?, anchorBirth: Date?
    ) -> String? {
        guard relation.supportsAgeOrder,
              let subjectBirth, let anchorBirth,
              subjectBirth != anchorBirth else { return nil }
        return subjectBirth < anchorBirth ? "older" : "younger"
    }

    /// "Rick's younger brother" — possessive anchor name + optional age
    /// word + the gendered term for the subject.
    static func phrase(
        relation: KinshipRelation,
        anchorName: String,
        subjectSex: PersonSex?,
        subjectBirth: Date? = nil,
        anchorBirth: Date? = nil
    ) -> String {
        let age = ageWord(relation, subjectBirth: subjectBirth, anchorBirth: anchorBirth)
        let term = relation.term(sex: subjectSex)
        return possessive(anchorName) + " " + (age.map { $0 + " " } ?? "") + term
    }

    static func possessive(_ name: String) -> String {
        name.hasSuffix("s") ? name + "'" : name + "'s"
    }
}
