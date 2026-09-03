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
//   (-) the link's STATUS (`2 STAT` under the FAMC — codex #1011, fail
//       closed): proven › unspecified › challenged › disproven. A
//       challenged or disproven link never becomes primary over a
//       proven or unlabelled one, whatever else it has;
//   (0) the link's PEDIGREE (`2 PEDI`): birth › unspecified › adopted ›
//       foster › sealing;
//   (a) both HUSB and WIFE present beats one;
//   (b) a FamilySearch family id (`_FSFTID`) beats none;
//   (c) more recorded facts on the parents (birth/death date and place)
//       beats fewer;
//   (d) stable tie-break: GEDCOM (FAMC) order.
// The top family is PRIMARY: its HUSB is the father, its WIFE the mother.
//
// A non-primary parent is FOLDED (treated as the same person, said only
// in the basis) on IDENTITY, never on relationship alone (codex #1011:
// a shared FAMC proves siblings, not identity — two sisters "Mary
// O'Connor b. 1904" and "Bridget O'Connor b. 1905" must stay two
// people). Either the two records carry the same FamilySearch person id,
// or their full names are compatible (same surname; given names equal,
// or one a prefix / initial of the other — "Mary" ~ "Mary Catherine",
// never "Mary" ~ "Bridget") AND one corroboration holds: a shared FAMC,
// birth years within two, or the same spouse. Anything else (adoption,
// remarriage with children, the two sisters) is kept out of the prose —
// the basis says a second family is recorded and to ask about it by name.
//
// Siblings follow the same selection through ONE symmetric verdict per
// pair — see GedcomFamilyGraph+Siblings.

import Foundation

extension GedcomFamilyGraph {

    /// Which parent slot of a family a person fills.
    public enum ParentRole: String, Sendable, Equatable {
        case father, mother
    }

    /// What the link says about its own standing (`2 STAT` under the
    /// FAMC), in ranking order. Fail closed: a doubted link loses to an
    /// unlabelled one. (C++: an enum whose integer value IS the sort key.)
    public enum ParentLinkStatus: Int, Sendable, Equatable, Comparable {
        case proven = 0
        case unspecified = 1
        case challenged = 2
        case disproven = 3

        /// The raw STAT text as the parser kept it (lowercased, trimmed).
        /// Unknown or missing text is `unspecified`.
        public init(raw: String?) {
            switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "proven": self = .proven
            case "challenged": self = .challenged
            case "disproven": self = .disproven
            default: self = .unspecified
            }
        }

        public static func < (a: ParentLinkStatus, b: ParentLinkStatus) -> Bool { a.rawValue < b.rawValue }

        /// "link challenged" / "link disproven" — nil when there is
        /// nothing to qualify.
        var qualifier: String? {
            switch self {
            case .challenged: return "link challenged"
            case .disproven: return "link disproven"
            case .proven, .unspecified: return nil
            }
        }
    }

    /// How a child belongs to a parent family (`2 PEDI` under the FAMC),
    /// in ranking order: an explicit birth family outranks everything, an
    /// unlabelled link outranks an explicit adoptive / foster / sealing
    /// one. (C++: an enum whose integer value IS the sort key.)
    public enum ParentPedigree: Int, Sendable, Equatable, Comparable {
        case birth = 0
        case unspecified = 1
        case adopted = 2
        case foster = 3
        case sealing = 4

        /// The raw PEDI text as the parser kept it (lowercased, trimmed).
        /// Unknown or missing text is `unspecified`.
        public init(raw: String?) {
            switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "birth": self = .birth
            case "adopted": self = .adopted
            case "foster": self = .foster
            case "sealing": self = .sealing
            default: self = .unspecified
            }
        }

        public static func < (a: ParentPedigree, b: ParentPedigree) -> Bool { a.rawValue < b.rawValue }

        /// "adoptive parents" / "foster parent" / "parents by sealing" —
        /// nil for birth and unspecified, which the basis does not label.
        func parentsPhrase(count: Int) -> String? {
            let noun = count == 1 ? "parent" : "parents"
            switch self {
            case .adopted: return "adoptive \(noun)"
            case .foster: return "foster \(noun)"
            case .sealing: return "\(noun) by sealing"
            case .birth, .unspecified: return nil
            }
        }
    }

    /// Why a non-primary parent is treated as the same person as the
    /// primary parent of that role. Every case except `sameFamilySearchID`
    /// also required a compatible full name.
    public enum ParentFold: String, Sendable, Equatable {
        /// Both records carry the same FamilySearch person id.
        case sameFamilySearchID
        /// Compatible name, and both records are children of one family.
        case sameParents
        /// Compatible name, born within two years of each other.
        case sameNameCloseBirth
        /// Compatible name, married to the same person.
        case sameSpouse

        /// The short reason the basis line quotes.
        public var reason: String {
            switch self {
            case .sameFamilySearchID: return "same FamilySearch record"
            case .sameParents: return "same parents"
            case .sameNameCloseBirth: return "same name, born within two years"
            case .sameSpouse: return "same spouse"
            }
        }
    }

    /// The ranking facts about one candidate parent family, in precedence
    /// order. A plain value type so the table test can build one directly
    /// (C++: a POD with a strict-weak-ordering comparator).
    public struct ParentFamilyRank: Sendable, Equatable {
        public let familyID: String
        /// Rule (-): the child's link status for this family.
        public let status: ParentLinkStatus
        /// Rule (0): the child's link pedigree for this family.
        public let pedigree: ParentPedigree
        public let hasBothParents: Bool
        public let hasFamilySearchID: Bool
        /// Birth/death dates and places recorded on the parents (0…8).
        public let factCount: Int
        /// Position in the person's FAMC list (0 = first in the file).
        public let order: Int

        public init(familyID: String, hasBothParents: Bool, hasFamilySearchID: Bool,
                    factCount: Int, order: Int, pedigree: ParentPedigree = .unspecified,
                    status: ParentLinkStatus = .unspecified) {
            self.familyID = familyID
            self.status = status
            self.pedigree = pedigree
            self.hasBothParents = hasBothParents
            self.hasFamilySearchID = hasFamilySearchID
            self.factCount = factCount
            self.order = order
        }

        /// True when `a` is the better primary family: rules (-), (0),
        /// (a)–(d) in that order, each consulted only when every earlier
        /// one ties.
        public static func outranks(_ a: ParentFamilyRank, _ b: ParentFamilyRank) -> Bool {
            if a.status != b.status { return a.status < b.status }
            if a.pedigree != b.pedigree { return a.pedigree < b.pedigree }
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
        /// The child's link pedigree for `familyID` (adoptive, foster …).
        public let pedigree: ParentPedigree
        /// The child's link status for `familyID` (challenged, disproven …).
        public let status: ParentLinkStatus
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
        /// The primary link's pedigree (rule 0).
        public var primaryPedigree: ParentPedigree { ranks.first?.pedigree ?? .unspecified }
        /// The primary link's status (rule -).
        public var primaryStatus: ParentLinkStatus { ranks.first?.status ?? .unspecified }
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
            let rank = rank(of: family, id: firstID, order: 0, for: person)
            return ParentFamilyChoice(primaryFamilyID: firstID,
                                      father: family.husband.flatMap { people[$0] },
                                      mother: family.wife.flatMap { people[$0] },
                                      ranks: [rank], alternates: [])
        }
        let ranks = rankedParentFamilies(ids, for: person)
        let primaryID = ranks[0].familyID
        let primary = families[primaryID]!
        let father = primary.husband.flatMap { people[$0] }
        let mother = primary.wife.flatMap { people[$0] }
        var alternates: [AlternateParent] = []
        for id in ids where id != primaryID {
            let family = families[id]!
            let pedigree = pedigree(of: person, in: id)
            let status = linkStatus(of: person, in: id)
            for (role, pointer, primaryParent) in [(ParentRole.father, family.husband, father),
                                                    (ParentRole.mother, family.wife, mother)] {
                guard let pointer, let person = people[pointer] else { continue }
                if person.id == primaryParent?.id { continue }   // the same record listed twice
                alternates.append(AlternateParent(
                    role: role, person: person, familyID: id, pedigree: pedigree, status: status,
                    fold: primaryParent.flatMap { fold(person, into: $0) }))
            }
        }
        return ParentFamilyChoice(primaryFamilyID: primaryID, father: father, mother: mother,
                                  ranks: ranks, alternates: alternates)
    }

    /// The PRIMARY parent family's pointer — the ONE FAMC selection every
    /// reader shares (`relatives(.father/.mother/.parents)`,
    /// `primaryMother/primaryFather`, siblings, `directRelation`). The
    /// one-FAMC case is a single dictionary lookup with no ranking and no
    /// allocation; only a multi-FAMC person pays for the rank table.
    /// (C++: the hot inline path; `parentFamilyChoice` is the full report
    /// built on top of it.)
    public func primaryParentFamilyID(of person: Person) -> String? {
        let ids = parentFamilyIDs(of: person)
        switch ids.count {
        case 0: return nil
        case 1: return families[ids[0]] == nil ? nil : ids[0]
        default:
            let known = ids.filter { families[$0] != nil }
            guard let first = known.first else { return nil }
            if known.count == 1 { return first }
            return rankedParentFamilies(known, for: person)[0].familyID
        }
    }

    func primaryParentFamily(of person: Person) -> Family? {
        // One lookup on the hot path (the index builder calls this for
        // every person in a 100k tree); the ranking only for multi-FAMC.
        let ids = parentFamilyIDs(of: person)
        switch ids.count {
        case 0: return nil
        case 1: return families[ids[0]]
        default: return primaryParentFamilyID(of: person).flatMap { families[$0] }
        }
    }

    /// The child's link pedigree for one FAMC family (rule 0).
    public func pedigree(of person: Person, in familyID: String) -> ParentPedigree {
        ParentPedigree(raw: person.parentLinks[familyID]?.pedigree)
    }

    /// The child's link status for one FAMC family (rule -).
    public func linkStatus(of person: Person, in familyID: String) -> ParentLinkStatus {
        ParentLinkStatus(raw: person.parentLinks[familyID]?.status)
    }

    private func rankedParentFamilies(_ ids: [String], for person: Person) -> [ParentFamilyRank] {
        ParentFamilyRank.ranked(ids.enumerated().map { order, id in
            rank(of: families[id]!, id: id, order: order, for: person)
        })
    }

    private func rank(of family: Family, id: String, order: Int, for child: Person) -> ParentFamilyRank {
        let husband = family.husband.flatMap { people[$0] }
        let wife = family.wife.flatMap { people[$0] }
        return ParentFamilyRank(
            familyID: id,
            hasBothParents: husband != nil && wife != nil,
            hasFamilySearchID: family.familySearchID != nil,
            factCount: Self.factCount(husband) + Self.factCount(wife),
            order: order,
            pedigree: pedigree(of: child, in: id),
            status: linkStatus(of: child, in: id))
    }

    /// Recorded vital facts on one person: birth date, birth place, death
    /// date, death place (0…4). Nil person = 0.
    public static func factCount(_ person: Person?) -> Int {
        guard let person else { return 0 }
        return [person.birthDate, person.birthPlace, person.deathDate, person.deathPlace]
            .filter { $0 != nil }.count
    }

    // MARK: Identity fold

    /// Whether `candidate` (a non-primary parent) reads as the same person
    /// as `primary` (the primary parent of the same role). Identity only:
    /// the same FamilySearch person id, or a compatible full name plus one
    /// corroboration (shared FAMC, birth years within two, same spouse).
    /// Both records must actually carry the evidence; a missing birth
    /// year, a missing given name or a missing surname never folds.
    public func fold(_ candidate: Person, into primary: Person) -> ParentFold? {
        if let a = candidate.familySearchID, let b = primary.familySearchID, !a.isEmpty, a == b {
            return .sameFamilySearchID
        }
        guard Self.namesCompatible(candidate, primary) else { return nil }
        let famcA = Set(parentFamilyIDs(of: candidate)), famcB = Set(parentFamilyIDs(of: primary))
        if !famcA.isEmpty, !famcA.isDisjoint(with: famcB) { return .sameParents }
        if let ya = candidate.birthYear, let yb = primary.birthYear, abs(ya - yb) <= 2 {
            return .sameNameCloseBirth
        }
        let spousesA = spouseIDs(of: candidate)
        if !spousesA.isEmpty, !spousesA.isDisjoint(with: spouseIDs(of: primary)) { return .sameSpouse }
        return nil
    }

    /// Same surname, and given names that are the same person's: equal,
    /// or one list a prefix of the other token by token ("Mary" ~ "Mary
    /// Catherine"), where a one-letter token matches the initial of the
    /// other ("M" ~ "Mary"). "Mary" vs "Bridget" is never compatible, nor
    /// is a record with no given name at all.
    public static func namesCompatible(_ a: Person, _ b: Person) -> Bool {
        guard let sa = a.surname, let sb = b.surname,
              FamilyIdentityText.normalized(sa) == FamilyIdentityText.normalized(sb) else { return false }
        let ga = givenNameTokens(a), gb = givenNameTokens(b)
        guard !ga.isEmpty, !gb.isEmpty else { return false }
        let (short, long) = ga.count <= gb.count ? (ga, gb) : (gb, ga)
        for (s, l) in zip(short, long) {
            if s == l { continue }
            if s.count == 1, l.first == s.first { continue }
            if l.count == 1, s.first == l.first { continue }
            return false
        }
        return true
    }

    /// The normalized given-name tokens: the display name's tokens before
    /// the surname run ("David McGill Latta Sr" / "Latta" → ["david",
    /// "mcgill"]). When the surname is not found, everything but the last
    /// token.
    static func givenNameTokens(_ person: Person) -> [String] {
        let tokens = FamilyIdentityText.tokens(person.name)
        guard let surname = person.surname else { return Array(tokens.dropLast()) }
        let run = FamilyIdentityText.tokens(surname)
        guard !run.isEmpty, tokens.count >= run.count else { return Array(tokens.dropLast()) }
        for start in 0...(tokens.count - run.count) where Array(tokens[start..<(start + run.count)]) == run {
            return Array(tokens[..<start])
        }
        return Array(tokens.dropLast())
    }

    /// The other member of every FAMS family the person is in.
    private func spouseIDs(of person: Person) -> Set<String> {
        Set(person.spouseOfFamilies.compactMap { families[$0] }
            .flatMap { [$0.husband, $0.wife].compactMap { $0 } }
            .filter { $0 != person.id })
    }

    // MARK: Basis wording

    /// The one short basis note the ruling allows, or nil for the ordinary
    /// person. Folded duplicates:
    ///   "(another record for her mother, Mary O'Connor b. 1905, exists in
    ///    the tree — same parents; treated as the same person)"
    /// A genuine second family with a stated pedigree:
    ///   "Also recorded: adoptive parents (father Adoptive Father, @I4@;
    ///    mother Adoptive Mother, @I5@); ask about them by name."
    /// A genuine second family with none:
    ///   "A second parent family is recorded (father Zeke Foster, @I32@);
    ///    ask about it by name."
    /// A challenged / disproven link says so inside the parentheses
    /// ("… @I32@ — link disproven"). A merge disagreement on a link:
    ///   "The sources disagree on the link to family @F-BIRTH@ (STAT
    ///    proven vs disproven (kept disproven))."
    /// Several, when a person has more than one kind, joined by a space.
    public func parentFamilyBasisNote(for person: Person) -> String? {
        let choice = parentFamilyChoice(of: person)
        var notes: [String] = []
        if let choice, !choice.alternates.isEmpty {
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
            func listed(_ parents: [AlternateParent]) -> String {
                parents.map { "\($0.role.rawValue) \($0.person.name), \(Self.recordCode($0.person))" }
                    .joined(separator: "; ")
            }
            // Families with a stated pedigree get their own sentence, FAMC
            // order; the unlabelled remainder shares one. A doubted link
            // is qualified inside the parentheses.
            var plain: [String] = []
            var seenFamilies: [String] = []
            for alternate in choice.unfoldedAlternates where !seenFamilies.contains(alternate.familyID) {
                seenFamilies.append(alternate.familyID)
                let inFamily = choice.unfoldedAlternates.filter { $0.familyID == alternate.familyID }
                let qualified = listed(inFamily) + (alternate.status.qualifier.map { " — \($0)" } ?? "")
                if let phrase = alternate.pedigree.parentsPhrase(count: inFamily.count) {
                    notes.append("Also recorded: \(phrase) (\(qualified)); ask about them by name.")
                } else {
                    plain.append(qualified)
                }
            }
            if !plain.isEmpty {
                notes.append("A second parent family is recorded (\(plain.joined(separator: "; "))); ask about it by name.")
            }
        }
        for familyID in parentFamilyIDs(of: person) {
            guard let conflict = person.parentLinks[familyID]?.conflict else { continue }
            notes.append("The sources disagree on the link to family \(familyCode(familyID)) (\(conflict)).")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// The FamilySearch ID when the record has one, else the file-local
    /// pointer — whatever lets Rick find the record upstream.
    static func recordCode(_ person: Person) -> String {
        let fsid = person.familySearchID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return fsid.isEmpty ? person.id : fsid
    }

    /// Same for a family: its FamilySearch family id, else the pointer.
    func familyCode(_ familyID: String) -> String {
        families[familyID]?.familySearchID ?? familyID
    }
}
