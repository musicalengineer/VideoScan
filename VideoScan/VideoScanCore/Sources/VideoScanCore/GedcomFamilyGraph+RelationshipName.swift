// GedcomFamilyGraph+RelationshipName.swift
// "How am I related to X?" answered with the NAME a family uses — "X is
// your second cousin once removed", "your half-great-aunt", "your wife's
// third cousin" — not just the plural pair term ("2nd cousins once
// removed") the common-ancestor sentence already gives (GH #218, Rick
// approved 2026-10-01).
//
// Three pieces, all pure over the recorded links:
//   • `relationshipName(depthA:depthB:sexOfB:half:)` — the word for B as
//     seen from A, given the two depths below the nearest common ancestor
//     (the lowest common ancestor of the DAG, found by `commonAncestry`).
//   • `halfBlood(_:)` — whether the nearest meeting is ONE ancestor whose
//     two lines run through children by DIFFERENT recorded partners. Only
//     then is it "half-": a meeting with one parent unrecorded on either
//     line is not called half (the tree doesn't say).
//   • `bloodRelation(of:to:)` and `relationThroughMarriage(of:to:)` — the
//     whole answer for one pair: blood first; only when there is none, a
//     link through one spouse ("your husband's niece", "married to your
//     second cousin").
//
// Pedigree collapse (several lowest common ancestors) is the caller's to
// tell: `commonAncestry` lists every separate line, nearest first, and the
// name here is always the NEAREST one's.

import Foundation

extension GedcomFamilyGraph {

    // MARK: - Words

    /// "first" … "twelfth", then "13th", "21st" — how cousins are said.
    public static func spelledOrdinal(_ n: Int) -> String {
        let words = ["zeroth", "first", "second", "third", "fourth", "fifth", "sixth",
                     "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth"]
        return words.indices.contains(n) ? words[n] : numericOrdinal(n)
    }

    /// The word for B as seen from A, when their nearest common ancestor is
    /// `depthA` generations above A and `depthB` above B (1 = parent). Nil
    /// when either depth is below 1 (a direct line — not a collateral
    /// relationship; see `directRelation`).
    ///   1/1 sibling · A 2+/B 1 aunt/uncle (great- per step) · A 1/B 2+
    ///   niece/nephew · otherwise cousin: degree = nearer depth − 1,
    ///   removed = the difference.
    public static func relationshipName(depthA: Int, depthB: Int, sexOfB: String, half: Bool = false) -> String? {
        guard depthA >= 1, depthB >= 1 else { return nil }
        let sex = sexOfB.uppercased()
        func word(_ m: String, _ f: String, _ n: String) -> String { sex == "M" ? m : sex == "F" ? f : n }
        func greats(_ n: Int) -> String {
            switch n {
            case ...0: return ""
            case 1: return "great-"
            case 2: return "great-great-"
            default: return numericOrdinal(n) + "-great-"
            }
        }
        let prefix = half ? "half-" : ""
        if depthA == 1, depthB == 1 { return prefix + word("brother", "sister", "sibling") }
        if depthB == 1 { return prefix + greats(depthA - 2) + word("uncle", "aunt", "aunt or uncle") }
        if depthA == 1 { return prefix + greats(depthB - 2) + word("nephew", "niece", "niece or nephew") }
        let degree = min(depthA, depthB) - 1
        let removed = abs(depthA - depthB)
        var name = prefix + spelledOrdinal(degree) + " cousin"
        let counts = ["", "once", "twice", "three times", "four times", "five times", "six times",
                      "seven times", "eight times", "nine times", "ten times"]
        if removed > 0 {
            name += " " + (counts.indices.contains(removed) ? counts[removed] : "\(removed) times") + " removed"
        }
        return name
    }

    // MARK: - Half blood

    /// The nearest meeting is half-blood: one shared ancestor whose two
    /// lines descend through children by different recorded partners.
    public struct HalfBlood: Sendable, Equatable {
        public let ancestor: Person
        /// The other parent on A's line and on B's line.
        public let partnerOnA: Person
        public let partnerOnB: Person
    }

    /// Nil = full blood (the meeting is a couple), or the tree doesn't say
    /// (a line with only the one parent recorded, or two partner records
    /// that look like the same person entered twice).
    public func halfBlood(_ meeting: AncestralMeeting) -> HalfBlood? {
        guard meeting.ancestors.count == 1, meeting.pathA.count > 1, meeting.pathB.count > 1 else { return nil }
        let ancestor = meeting.ancestors[0]
        let childA = meeting.pathA[1], childB = meeting.pathB[1]
        guard childA.id != childB.id,
              let partners = provenDifferentPartners(
                  relatives(.parents, of: childA).filter { $0.id != ancestor.id },
                  relatives(.parents, of: childB).filter { $0.id != ancestor.id }) else { return nil }
        return HalfBlood(ancestor: ancestor, partnerOnA: partners.a, partnerOnB: partners.b)
    }

    /// The tree PROVES two different partners only when each side records
    /// one, no record is on both sides, and no pair looks like one person
    /// entered twice (QA P2-2, 2026-10-01: merged trees are full of
    /// duplicate "Mary Smith, b. 1852" records). Nil = the tree doesn't say.
    func provenDifferentPartners(_ otherA: [Person], _ otherB: [Person]) -> (a: Person, b: Person)? {
        guard let pa = otherA.first, let pb = otherB.first,
              Set(otherA.map(\.id)).isDisjoint(with: otherB.map(\.id)) else { return nil }
        for x in otherA {
            for y in otherB where Self.likelySamePerson(x, y) { return nil }
        }
        return (pa, pb)
    }

    /// Same normalized name, and birth years that do not contradict it
    /// (either unrecorded, or within two years).
    public static func likelySamePerson(_ x: Person, _ y: Person) -> Bool {
        func norm(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .replacingOccurrences(of: "/", with: " ")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        guard norm(x.name) == norm(y.name) else { return false }
        guard let bx = x.birthYear, let by = y.birthYear else { return true }
        return abs(bx - by) <= 2
    }

    // MARK: - One pair

    /// How B is related to A by blood.
    public struct BloodRelation: Sendable, Equatable {
        /// "second cousin once removed", "great-grandmother", "half-sister".
        public let name: String
        /// The nearest meeting, for a collateral relationship (nil for a
        /// direct line or siblings named from the parent links).
        public let meeting: AncestralMeeting?
        public let half: HalfBlood?
        /// Every separate line the two share (pedigree collapse: > 1).
        public let separateLines: Int
        /// Links between the two along the nearest line (parent 1, sibling
        /// 2, first cousin 4 …) — how the in-law path picks the closest.
        public let distance: Int
    }

    /// B's blood relationship to A — direct lines and siblings from the
    /// recorded links, everything else from the nearest common ancestor.
    /// Nil = no recorded blood link (or the same person / unknown ids).
    public func bloodRelation(of bID: String, to aID: String) -> BloodRelation? {
        guard aID != bID, let a = people[aID], let b = people[bID] else { return nil }
        if let direct = directRelation(between: aID, and: bID) {
            let depth = direct.path.count - 1
            switch direct.kind {
            case .parentChild:
                let bIsParent = relatives(.parents, of: a).contains { $0.id == bID }
                let name = bIsParent ? Self.generationLabel(generations: 1, sex: b.sex)
                                     : Self.descendantLabel(generations: 1, sex: b.sex)
                return BloodRelation(name: name, meeting: nil, half: nil, separateLines: 1, distance: 1)
            case .ancestorDescendant:
                // The path ends at B either way; which way it runs is
                // whether B is among A's ancestors.
                let bIsAncestor = AncestorIndex(graph: self, descendantID: aID).path(from: bID) != nil
                let name = bIsAncestor ? Self.generationLabel(generations: depth, sex: b.sex)
                                       : Self.descendantLabel(generations: depth, sex: b.sex)
                return BloodRelation(name: name, meeting: nil, half: nil, separateLines: 1, distance: depth)
            case .siblings, .halfSiblings:
                // directRelation calls one shared parent "half"; the tree
                // only PROVES it when each records a different other parent
                // (QA P2-3) — otherwise they are siblings, half not known.
                let parentsA = relatives(.parents, of: a), parentsB = relatives(.parents, of: b)
                let shared = Set(parentsA.map(\.id)).intersection(parentsB.map(\.id))
                let half = direct.kind == .halfSiblings && provenDifferentPartners(
                    parentsA.filter { !shared.contains($0.id) },
                    parentsB.filter { !shared.contains($0.id) }) != nil
                let name = Self.relationshipName(depthA: 1, depthB: 1, sexOfB: b.sex, half: half)
                    ?? (half ? "half-sibling" : "sibling")
                return BloodRelation(name: name, meeting: nil, half: nil, separateLines: 1, distance: 2)
            case .samePerson:
                return nil
            case .spouses, .parentInLaw, .siblingInLaw:
                break   // not blood: spouses may still be cousins — fall through
            }
        }
        guard let ancestry = commonAncestry(of: aID, and: bID), let nearest = ancestry.nearest else { return nil }
        let half = halfBlood(nearest)
        guard let name = Self.relationshipName(depthA: nearest.depthA, depthB: nearest.depthB,
                                               sexOfB: b.sex, half: half != nil) else { return nil }
        return BloodRelation(name: name, meeting: nearest, half: half, separateLines: ancestry.meetings.count,
                             distance: nearest.depthA + nearest.depthB)
    }

    /// B related to A only through a marriage.
    public struct MarriageRelation: Sendable, Equatable {
        public enum Via: Sendable, Equatable {
            /// B is a blood relative of A's spouse ("your wife's niece").
            case spouseOfA
            /// B is married to a blood relative of A ("married to your cousin").
            case spouseOfB
        }
        public let via: Via
        /// The spouse the link runs through.
        public let spouse: Person
        /// spouseOfA: B's relation to the spouse. spouseOfB: the spouse's
        /// relation to A.
        public let relation: BloodRelation
    }

    /// The in-law path, only for pairs with NO blood link. Every spouse of
    /// A and of B is tried; the CLOSEST blood link wins (QA P3-5: the first
    /// spouse by id gave "wife's first cousin" where "wife's sister" was
    /// recorded). Ties: A's spouses before B's, then id order.
    public func relationThroughMarriage(of bID: String, to aID: String) -> MarriageRelation? {
        guard aID != bID, let a = people[aID], let b = people[bID] else { return nil }
        var best: MarriageRelation?
        func consider(_ m: MarriageRelation) {
            if best.map({ m.relation.distance < $0.relation.distance }) ?? true { best = m }
        }
        for s in relatives(.spouse, of: a).sorted(by: { $0.id < $1.id }) where s.id != bID {
            if let r = bloodRelation(of: bID, to: s.id) { consider(MarriageRelation(via: .spouseOfA, spouse: s, relation: r)) }
        }
        for t in relatives(.spouse, of: b).sorted(by: { $0.id < $1.id }) where t.id != aID {
            if let r = bloodRelation(of: t.id, to: aID) { consider(MarriageRelation(via: .spouseOfB, spouse: t, relation: r)) }
        }
        return best
    }

    /// "husband" / "wife" / "spouse" for a spouse's sex.
    public static func spouseWord(_ sex: String) -> String {
        switch sex.uppercased() {
        case "M": return "husband"
        case "F": return "wife"
        default: return "spouse"
        }
    }
}
