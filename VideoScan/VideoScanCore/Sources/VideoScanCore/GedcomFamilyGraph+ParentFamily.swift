// GedcomFamilyGraph+ParentFamily.swift (VideoScanCore)
// ONE primary parent family per person (Rick, Director, 2026-09-02 19:55:
// Hallie read out two mothers for Eileen Latta — "for now we just need to
// pick one and not list two Moms for one person").
//
// FamilySearch pulls carry the same parent twice more often than they
// carry a real second family: Eileen's `1 FAMC @F3@` (David Latta Sr +
// Mary Catherine O'Connor, FamilySearch family MT64-4HP) and `1 FAMC
// @F4@` (a wife-only family for "Mary O'Connor" b. 1905 — the same woman,
// entered twice upstream; both Marys are daughters of the same @F6@).
// Until 2026-09-02 `relatives(.mother)` returned both, and so did every
// walk built on the compiled parent table.
//
// The rule is READ-TIME SELECTION ONLY: the GEDCOM, the compiled tree
// and FamilySearch are never edited. Ranking (`ParentFamilyRank`) is one
// pure comparator, table-tested in GedcomParentFamilyTests:
//   (a) both HUSB and WIFE present beats one;
//   (b) a FamilySearch family id (`_FSFTID`) beats none;
//   (c) more recorded facts on the parents (birth/death date and place)
//       beats fewer;
//   (d) stable tie-break: GEDCOM (FAMC) order.
// The top family is PRIMARY: its HUSB is the father, its WIFE the mother.
// A non-primary parent is FOLDED (treated as the same person, said only
// in the basis) when it shares a FAMC with the primary parent of the
// same role, or has the same surname and a birth year within two; an
// unfoldable one (adoption, remarriage with children) is still kept out
// of the prose — the basis says a second family is recorded and to ask
// about it by name.

import Foundation

extension GedcomFamilyGraph {

    /// Which parent slot of a family a person fills.
    public enum ParentRole: String, Sendable, Equatable {
        case father, mother
    }

    /// Why a non-primary parent is treated as the same person as the
    /// primary parent of that role.
    public enum ParentFold: String, Sendable, Equatable {
        /// Both records are children of one family (share a FAMC).
        case sameParents
        /// Same surname, born within two years of each other.
        case sameSurnameCloseBirth

        /// The short reason the basis line quotes.
        public var reason: String {
            switch self {
            case .sameParents: return "same parents"
            case .sameSurnameCloseBirth: return "same surname, born within two years"
            }
        }
    }

    /// The four ranking facts about one candidate parent family, in
    /// precedence order. A plain value type so the table test can build
    /// one directly (C++: a POD with a strict-weak-ordering comparator).
    public struct ParentFamilyRank: Sendable, Equatable {
        public let familyID: String
        public let hasBothParents: Bool
        public let hasFamilySearchID: Bool
        /// Birth/death dates and places recorded on the parents (0…8).
        public let factCount: Int
        /// Position in the person's FAMC list (0 = first in the file).
        public let order: Int

        public init(familyID: String, hasBothParents: Bool, hasFamilySearchID: Bool,
                    factCount: Int, order: Int) {
            self.familyID = familyID
            self.hasBothParents = hasBothParents
            self.hasFamilySearchID = hasFamilySearchID
            self.factCount = factCount
            self.order = order
        }

        /// True when `a` is the better primary family: rules (a)–(d) in
        /// that order, each consulted only when every earlier one ties.
        public static func outranks(_ a: ParentFamilyRank, _ b: ParentFamilyRank) -> Bool {
            if a.hasBothParents != b.hasBothParents { return a.hasBothParents }
            if a.hasFamilySearchID != b.hasFamilySearchID { return a.hasFamilySearchID }
            if a.factCount != b.factCount { return a.factCount > b.factCount }
            return a.order < b.order
        }

        /// The ranks sorted best-first — the primary is `first`.
        public static func ranked(_ ranks: [ParentFamilyRank]) -> [ParentFamilyRank] {
            ranks.sorted(by: outranks)
        }
    }

    /// A parent recorded in a NON-primary family.
    public struct AlternateParent: Sendable, Equatable {
        public let role: ParentRole
        public let person: Person
        public let familyID: String
        /// Nil when this is a genuinely different person (a second
        /// family); otherwise why it is read as the primary parent again.
        public let fold: ParentFold?

        public var isFolded: Bool { fold != nil }
    }

    /// What the graph says about one person's parents once the ruling is
    /// applied: the primary family's father and mother, and everything
    /// the other FAMC families would have added.
    public struct ParentFamilyChoice: Sendable, Equatable {
        public let primaryFamilyID: String
        public let father: Person?
        public let mother: Person?
        /// The ranking the choice was made from, best first (for tests
        /// and the Family Tree inspector).
        public let ranks: [ParentFamilyRank]
        /// Non-primary parents, FAMC order, fathers before mothers within a
        /// family. Empty for the ordinary single-FAMC person.
        public let alternates: [AlternateParent]

        public var parents: [Person] { [father, mother].compactMap { $0 } }
        public var foldedAlternates: [AlternateParent] { alternates.filter(\.isFolded) }
        public var unfoldedAlternates: [AlternateParent] { alternates.filter { !$0.isFolded } }
    }

    /// The ruling applied to one person. Nil when no FAMC family resolves
    /// (no parents recorded). Cost is O(FAMC count) dictionary lookups —
    /// the one-FAMC case (all but ~5% of a FamilySearch pull) takes the
    /// short path with no ranking at all.
    public func parentFamilyChoice(of person: Person) -> ParentFamilyChoice? {
        let ids = parentFamilyIDs(of: person).filter { families[$0] != nil }
        guard let firstID = ids.first else { return nil }
        if ids.count == 1 {
            let family = families[firstID]!
            let rank = rank(of: family, id: firstID, order: 0)
            return ParentFamilyChoice(primaryFamilyID: firstID,
                                      father: family.husband.flatMap { people[$0] },
                                      mother: family.wife.flatMap { people[$0] },
                                      ranks: [rank], alternates: [])
        }
        let ranks = ParentFamilyRank.ranked(ids.enumerated().map { order, id in
            rank(of: families[id]!, id: id, order: order)
        })
        let primaryID = ranks[0].familyID
        let primary = families[primaryID]!
        let father = primary.husband.flatMap { people[$0] }
        let mother = primary.wife.flatMap { people[$0] }
        var alternates: [AlternateParent] = []
        for id in ids where id != primaryID {
            let family = families[id]!
            for (role, pointer, primaryParent) in [(ParentRole.father, family.husband, father),
                                                    (ParentRole.mother, family.wife, mother)] {
                guard let pointer, let person = people[pointer] else { continue }
                if person.id == primaryParent?.id { continue }   // the same record listed twice
                alternates.append(AlternateParent(
                    role: role, person: person, familyID: id,
                    fold: primaryParent.flatMap { Self.fold(person, into: $0) }))
            }
        }
        return ParentFamilyChoice(primaryFamilyID: primaryID, father: father, mother: mother,
                                  ranks: ranks, alternates: alternates)
    }

    private func rank(of family: Family, id: String, order: Int) -> ParentFamilyRank {
        let husband = family.husband.flatMap { people[$0] }
        let wife = family.wife.flatMap { people[$0] }
        return ParentFamilyRank(
            familyID: id,
            hasBothParents: husband != nil && wife != nil,
            hasFamilySearchID: family.familySearchID != nil,
            factCount: Self.factCount(husband) + Self.factCount(wife),
            order: order)
    }

    /// Recorded vital facts on one person: birth date, birth place, death
    /// date, death place (0…4). Nil person = 0.
    public static func factCount(_ person: Person?) -> Int {
        guard let person else { return 0 }
        return [person.birthDate, person.birthPlace, person.deathDate, person.deathPlace]
            .filter { $0 != nil }.count
    }

    /// Whether `candidate` (a non-primary parent) reads as the same person
    /// as `primary` (the primary parent of the same role): they share a
    /// FAMC — the same parents — or carry the same surname with birth
    /// years within two of each other. Both records must actually carry
    /// the evidence; a missing birth year never folds.
    public static func fold(_ candidate: Person, into primary: Person) -> ParentFold? {
        let famcA = Set(candidate.childOfFamilies.isEmpty
                        ? [candidate.childOfFamily].compactMap { $0 } : candidate.childOfFamilies)
        let famcB = Set(primary.childOfFamilies.isEmpty
                        ? [primary.childOfFamily].compactMap { $0 } : primary.childOfFamilies)
        if !famcA.isEmpty, !famcA.isDisjoint(with: famcB) { return .sameParents }
        guard let a = candidate.surname, let b = primary.surname,
              FamilyIdentityText.normalized(a) == FamilyIdentityText.normalized(b),
              let ya = candidate.birthYear, let yb = primary.birthYear,
              abs(ya - yb) <= 2 else { return nil }
        return .sameSurnameCloseBirth
    }

    // MARK: Basis wording

    /// The one short basis note the ruling allows, or nil for the ordinary
    /// person. Folded duplicates:
    ///   "(another record for her mother, Mary O'Connor b. 1905, exists in
    ///    the tree — same parents; treated as the same person)"
    /// A genuine second family:
    ///   "A second parent family is recorded (father Zeke Foster, @I32@);
    ///    ask about it by name."
    /// Both, when a person has both kinds, joined by a space.
    public func parentFamilyBasisNote(for person: Person) -> String? {
        guard let choice = parentFamilyChoice(of: person), !choice.alternates.isEmpty else { return nil }
        var notes: [String] = []
        let possessive: String
        switch person.sex {
        case "M": possessive = "his"
        case "F": possessive = "her"
        default: possessive = "their"
        }
        for alternate in choice.foldedAlternates {
            let born = alternate.person.birthYear.map { " b. \($0)" } ?? ""
            notes.append("(another record for \(possessive) \(alternate.role.rawValue), "
                + "\(alternate.person.name)\(born), exists in the tree — "
                + "\(alternate.fold!.reason); treated as the same person)")
        }
        let second = choice.unfoldedAlternates
        if !second.isEmpty {
            let listed = second.map { "\($0.role.rawValue) \($0.person.name), \(Self.recordCode($0.person))" }
                .joined(separator: "; ")
            notes.append("A second parent family is recorded (\(listed)); ask about it by name.")
        }
        return notes.joined(separator: " ")
    }

    /// The FamilySearch ID when the record has one, else the file-local
    /// pointer — whatever lets Rick find the record upstream.
    static func recordCode(_ person: Person) -> String {
        let fsid = person.familySearchID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return fsid.isEmpty ? person.id : fsid
    }
}
