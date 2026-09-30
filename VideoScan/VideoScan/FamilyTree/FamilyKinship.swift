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
import VideoScanCore

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
        // Whole-chain shapes first: a left fold forgets WHERE an
        // intermediate word came from, so a chain that is only safe as a
        // whole is named here and never by pairwise folding (codex #795 D).
        if let whole = wholeChains[hops] { return whole }
        for next in hops.dropFirst() {
            guard let folded = compose(current, next) else { return nil }
            current = folded
        }
        return current
    }

    /// Chains with a single word ONLY as a whole. `[spouse, sibling, spouse]`
    /// ("husband Rick → brother Tim → wife Kate") is a sister-in-law, but
    /// its left fold passes through siblingInLaw∘spouse, which is unsafe in
    /// general (see `folds`), so it is pinned here explicitly.
    private static let wholeChains: [[KinshipRelation]: KinshipRelation] = [
        [.spouse, .sibling, .spouse]: .siblingInLaw,
    ]

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
    /// great-grand…) have no single word in this vocabulary → nil. Step and
    /// half relations are deliberately NOT invented (codex #778): spouse∘child,
    /// parent∘spouse and sibling∘sibling fold to nil so the route text shows
    /// the chain instead of asserting "child"/"parent"/"sibling".
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
        Fold(.spouse, .nieceNephew):   .nieceNephew,
        Fold(.parentInLaw, .spouse):   .parentInLaw,
        // NOT siblingInLaw∘spouse (codex #795 D): by the time the fold sees
        // "siblingInLaw" it cannot tell spouse∘sibling (whose spouse IS a
        // sibling-in-law) from sibling∘spouse (whose spouse is the original
        // sibling, or a remarried in-law's new partner — no name at all).
        // `[spouse, sibling, spouse]` is named as a whole chain instead;
        // `[sibling, spouse, spouse]` fails closed to the route text.
    ]
}

/// Who a stored relationship points at.
///   • `.profile(id:)`   — durable: POIProfile.uuid survives a rename.
///   • `.profileName`    — LEGACY input only ({"profile":{"name":"Rick"}},
///                          the 2026-08-27 format); upgraded to `.profile(id:)`
///                          by `POIProfile.upgradingKinshipAnchors` on load
///                          and re-saved as ids the next time the profile
///                          is written.
///   • `.treePerson`     — FamilySearch ID, which survives GEDCOM re-exports.
///   • `.treePointer`    — fallback for exports WITHOUT FamilySearch IDs
///                          (Ancestry): a file-local @I…@ pointer that is only
///                          valid while the tree's content fingerprint matches.
/// Wire shape is one object keyed by case: {"profile":{"id":…}},
/// {"profile":{"name":…}}, {"treePerson":{"familySearchID":…}},
/// {"treePointer":{"pointer":…,"sourceFingerprint":…}}.
enum KinshipAnchor: Hashable, Sendable {
    case profile(id: UUID)
    case profileName(String)
    case treePerson(familySearchID: String)
    case treePointer(pointer: String, sourceFingerprint: String)

    /// Convenience for callers that still think in names (tests, legacy).
    static func profile(name: String) -> KinshipAnchor { .profileName(name) }

    /// Case-insensitive identity key.
    var key: String {
        switch self {
        case .profile(let id):
            return "profile-id:" + id.uuidString.lowercased()
        case .profileName(let name):
            return "profile:" + PersonResolver.normalize(name)
        case .treePerson(let id):
            return "tree:" + id.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        case .treePointer(let pointer, let fingerprint):
            return "tree-pointer:" + pointer + "@" + fingerprint
        }
    }
}

extension KinshipAnchor: Codable {
    private enum Key: String, CodingKey { case profile, treePerson, treePointer }
    private enum ProfileKey: String, CodingKey { case id, name }
    private enum TreePersonKey: String, CodingKey { case familySearchID }
    private enum TreePointerKey: String, CodingKey { case pointer, sourceFingerprint }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if c.contains(.profile) {
            let p = try c.nestedContainer(keyedBy: ProfileKey.self, forKey: .profile)
            if let id = try p.decodeIfPresent(UUID.self, forKey: .id) {
                self = .profile(id: id)
            } else {
                self = .profileName(try p.decode(String.self, forKey: .name))
            }
        } else if c.contains(.treePerson) {
            let t = try c.nestedContainer(keyedBy: TreePersonKey.self, forKey: .treePerson)
            self = .treePerson(familySearchID: try t.decode(String.self, forKey: .familySearchID))
        } else if c.contains(.treePointer) {
            let t = try c.nestedContainer(keyedBy: TreePointerKey.self, forKey: .treePointer)
            self = .treePointer(pointer: try t.decode(String.self, forKey: .pointer),
                                sourceFingerprint: try t.decode(String.self, forKey: .sourceFingerprint))
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "KinshipAnchor: no known case key"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .profile(let id):
            var p = c.nestedContainer(keyedBy: ProfileKey.self, forKey: .profile)
            try p.encode(id, forKey: .id)
        case .profileName(let name):
            var p = c.nestedContainer(keyedBy: ProfileKey.self, forKey: .profile)
            try p.encode(name, forKey: .name)
        case .treePerson(let id):
            var t = c.nestedContainer(keyedBy: TreePersonKey.self, forKey: .treePerson)
            try t.encode(id, forKey: .familySearchID)
        case .treePointer(let pointer, let fingerprint):
            var t = c.nestedContainer(keyedBy: TreePointerKey.self, forKey: .treePointer)
            try t.encode(pointer, forKey: .pointer)
            try t.encode(fingerprint, forKey: .sourceFingerprint)
        }
    }
}

/// A raw JSON fragment, kept verbatim. Used to quarantine kinship rows this
/// build cannot read (written by a newer build, or damaged) so a later save
/// never silently drops them (codex #778). ≈ a tagged-union JSON DOM.
indirect enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unreadable JSON")) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// What a `sibling` row asserts about shared parents (design amendment 2,
/// codex #830, 2026-08-29). The inference engine treats `.unspecified` as
/// "sibling, uncle, in-law composition only" and PROPOSES shared parents
/// for the review sheet; only an attested basis lets ancestry flow through
/// the row. Wire: "attestedFull" | "unspecified" | {"attestedHalf":{"sharedParent":…}}.
enum SiblingBasis: Hashable, Sendable {
    case unspecified
    case attestedFull
    case attestedHalf(sharedParent: KinshipAnchor)
}

extension SiblingBasis: Codable {
    private enum Key: String, CodingKey { case attestedHalf }
    private enum HalfKey: String, CodingKey { case sharedParent }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let word = try? single.decode(String.self) {
            switch word {
            case "unspecified": self = .unspecified; return
            case "attestedFull": self = .attestedFull; return
            default: break
            }
        }
        let c = try decoder.container(keyedBy: Key.self)
        let h = try c.nestedContainer(keyedBy: HalfKey.self, forKey: .attestedHalf)
        self = .attestedHalf(sharedParent: try h.decode(KinshipAnchor.self, forKey: .sharedParent))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .unspecified:
            var c = encoder.singleValueContainer(); try c.encode("unspecified")
        case .attestedFull:
            var c = encoder.singleValueContainer(); try c.encode("attestedFull")
        case .attestedHalf(let shared):
            var c = encoder.container(keyedBy: Key.self)
            var h = c.nestedContainer(keyedBy: HalfKey.self, forKey: .attestedHalf)
            try h.encode(shared, forKey: .sharedParent)
        }
    }
}

/// A profile's durable pin to ONE family-tree person (design amendment 1:
/// identity ≠ relationship). This is the only profile→tree bridge the
/// inference engine accepts; name/alias matching is a review suggestion.
///   • `.familySearchID` survives re-exports (preferred).
///   • `.pointer` is export-local: valid only while the installed tree's
///     content fingerprint matches (Ancestry exports without FSIDs).
/// Wire: {"familySearchID":"GVQV-NW3"} | {"pointer":{"pointer":"@I1@","sourceFingerprint":"…"}}.
enum TreeIdentity: Hashable, Sendable {
    case familySearchID(String)
    case pointer(pointer: String, sourceFingerprint: String)

    /// The anchor form other rows would use for the same person.
    var asAnchor: KinshipAnchor {
        switch self {
        case .familySearchID(let id): return .treePerson(familySearchID: id)
        case .pointer(let p, let f): return .treePointer(pointer: p, sourceFingerprint: f)
        }
    }
}

extension TreeIdentity: Codable {
    private enum Key: String, CodingKey { case familySearchID, pointer }
    private enum PointerKey: String, CodingKey { case pointer, sourceFingerprint }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .familySearchID) {
            self = .familySearchID(id)
        } else if c.contains(.pointer) {
            let p = try c.nestedContainer(keyedBy: PointerKey.self, forKey: .pointer)
            self = .pointer(pointer: try p.decode(String.self, forKey: .pointer),
                            sourceFingerprint: try p.decode(String.self, forKey: .sourceFingerprint))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "TreeIdentity: no known case key"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .familySearchID(let id):
            try c.encode(id, forKey: .familySearchID)
        case .pointer(let pointer, let fingerprint):
            var p = c.nestedContainer(keyedBy: PointerKey.self, forKey: .pointer)
            try p.encode(pointer, forKey: .pointer)
            try p.encode(fingerprint, forKey: .sourceFingerprint)
        }
    }
}

/// One stored fact on a profile: "this profile is `relation` of `relativeTo`".
/// Example on Tim's profile: (.sibling, .profile("Rick")) ⇒ Tim is Rick's
/// sibling; with Tim's sex and both birthdates known this displays as
/// "Rick's younger brother". `basis` matters only for sibling rows; it is
/// written only when set, so older profile.json shapes are unchanged.
struct Kinship: Hashable, Sendable {
    var relation: KinshipRelation
    var relativeTo: KinshipAnchor
    var note: String?
    var basis: SiblingBasis

    init(relation: KinshipRelation, relativeTo: KinshipAnchor, note: String? = nil,
         basis: SiblingBasis = .unspecified) {
        self.relation = relation
        self.relativeTo = relativeTo
        self.note = note
        self.basis = basis
    }
}

extension Kinship: Codable {
    private enum CodingKeys: String, CodingKey { case relation, relativeTo, note, basis }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        relation = try c.decode(KinshipRelation.self, forKey: .relation)
        relativeTo = try c.decode(KinshipAnchor.self, forKey: .relativeTo)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        basis = try c.decodeIfPresent(SiblingBasis.self, forKey: .basis) ?? .unspecified
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(relation, forKey: .relation)
        try c.encode(relativeTo, forKey: .relativeTo)
        try c.encodeIfPresent(note, forKey: .note)
        if basis != .unspecified { try c.encode(basis, forKey: .basis) }
    }
}

/// What is known about when someone was born, at its native precision:
/// a profile carries a full date; a tree record carries a GEDCOM year
/// interval ("ABT 1931", "BET 1930 AND 1932"). Never widened into a fake
/// January 1 (design amendment 6).
enum BirthKnowledge: Equatable, Sendable {
    case date(Date)
    case years(GedcomYearInterval)

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    /// Year interval at the knowledge's precision (a date → its exact year).
    var years: GedcomYearInterval {
        switch self {
        case .date(let d):     return .exact(Self.utcCalendar.component(.year, from: d))
        case .years(let y):    return y
        }
    }

    /// A single year for sentences ("born 1965"), nil when only a bound or
    /// nothing is known.
    var spokenYear: String { years.spoken }

    /// True only when `self` is PROVABLY earlier: full dates that differ, or
    /// year intervals that do not touch.
    func isStrictlyBefore(_ other: BirthKnowledge) -> Bool {
        if case .date(let a) = self, case .date(let b) = other { return a < b }
        return years.endsBefore(other.years)
    }

    /// "older" / "younger" for the subject relative to the anchor; nil unless
    /// the order is provable at the available precision.
    static func ageWord(subject: BirthKnowledge?, anchor: BirthKnowledge?) -> String? {
        guard let subject, let anchor else { return nil }
        if subject.isStrictlyBefore(anchor) { return "older" }
        if anchor.isStrictlyBefore(subject) { return "younger" }
        return nil
    }

    /// The smallest possible gap in years between two births (0 when the
    /// intervals overlap or a bound is open). Used for "born N years apart".
    static func provableGapYears(_ a: BirthKnowledge, _ b: BirthKnowledge) -> Int {
        let ya = a.years, yb = b.years
        var gap = 0
        if let al = ya.lower, let bu = yb.upper { gap = max(gap, al - bu) }
        if let bl = yb.lower, let au = ya.upper { gap = max(gap, bl - au) }
        return gap
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

    /// Same phrase with a precomputed age word ("older"/"younger"/nil) from
    /// `BirthKnowledge.ageWord`, which respects date precision.
    static func phrase(
        relation: KinshipRelation,
        anchorName: String,
        subjectSex: PersonSex?,
        ageWord: String?
    ) -> String {
        let term = relation.term(sex: subjectSex)
        return possessive(anchorName) + " " + (ageWord.map { $0 + " " } ?? "") + term
    }

    static func possessive(_ name: String) -> String {
        name.hasSuffix("s") ? name + "'" : name + "'s"
    }
}
