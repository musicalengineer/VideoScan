// GedcomFamilyGraph+DirectRelation.swift
// The near relationships that must be named BEFORE any cousin math
// (codex #776): "how are Rick and Dick related" is father and son, not
// "1st cousins" through a shared grandparent. Precedence, first hit wins:
//   same person → spouses → parent/child → direct ancestor/descendant
//   (grandparent, great-grandparent, … any depth) → full siblings (a
//   shared FAMC) → half-siblings (one shared parent) → parent-in-law →
//   sibling-in-law (spouse's sibling, or sibling's spouse).
// Only when none of these holds does the caller fall to
// `commonAncestors(of:and:)`. Built from the single-hop relations the
// graph records; pure, no I/O.

import Foundation

extension GedcomFamilyGraph {

    public struct DirectRelation: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case samePerson, spouses, parentChild, ancestorDescendant
            case siblings, halfSiblings, parentInLaw, siblingInLaw
        }
        public let kind: Kind
        /// "Richard Harding Breen Sr is Richard Harding Breen Jr’s father"
        /// — a complete sentence fragment ready for prose, always phrased
        /// from `b` toward `a` ("b is a's …").
        public let term: String
        /// The people from `a` to `b` through the hops that prove it.
        public let path: [Person]
    }

    /// The nearest recorded relationship between two people, or nil when
    /// they are none of the direct kinds (then try `commonAncestors`).
    public func directRelation(between aID: String, and bID: String) -> DirectRelation? {
        guard let a = people[aID], let b = people[bID] else { return nil }
        let poss = Self.possessive(a.name)
        func word(_ p: Person, _ m: String, _ f: String, _ n: String) -> String {
            p.sex == "M" ? m : p.sex == "F" ? f : n
        }
        if aID == bID {
            return DirectRelation(kind: .samePerson, term: "\(a.name) and \(b.name) are the same record", path: [a])
        }
        if relatives(.spouse, of: a).contains(where: { $0.id == bID }) {
            return DirectRelation(kind: .spouses, term: "\(b.name) is \(poss) \(word(b, "husband", "wife", "spouse"))", path: [a, b])
        }
        if relatives(.parents, of: a).contains(where: { $0.id == bID }) {
            return DirectRelation(kind: .parentChild, term: "\(b.name) is \(poss) \(word(b, "father", "mother", "parent"))", path: [a, b])
        }
        if relatives(.parents, of: b).contains(where: { $0.id == aID }) {
            return DirectRelation(kind: .parentChild, term: "\(b.name) is \(poss) \(word(b, "son", "daughter", "child"))", path: [a, b])
        }
        // Any-depth ancestor / descendant, shortest recorded line.
        if let up = AncestorIndex(graph: self, descendantID: aID).path(from: bID) {
            let depth = up.count - 1
            return DirectRelation(kind: .ancestorDescendant,
                                  term: "\(b.name) is \(poss) \(Self.generationLabel(generations: depth, sex: b.sex))",
                                  path: Array(up.reversed()))
        }
        if let down = AncestorIndex(graph: self, descendantID: bID).path(from: aID) {
            let depth = down.count - 1
            return DirectRelation(kind: .ancestorDescendant,
                                  term: "\(b.name) is \(poss) \(Self.descendantLabel(generations: depth, sex: b.sex))",
                                  path: down)
        }
        let famcA = Set(a.childOfFamilies.isEmpty ? [a.childOfFamily].compactMap { $0 } : a.childOfFamilies)
        let famcB = Set(b.childOfFamilies.isEmpty ? [b.childOfFamily].compactMap { $0 } : b.childOfFamilies)
        let parentsA = relatives(.parents, of: a), parentsB = relatives(.parents, of: b)
        let sharedParents = parentsA.filter { p in parentsB.contains(where: { $0.id == p.id }) }
        if !famcA.isDisjoint(with: famcB) || (sharedParents.count >= 2) {
            return DirectRelation(kind: .siblings, term: "\(b.name) is \(poss) \(word(b, "brother", "sister", "sibling"))",
                                  path: [a] + sharedParents.prefix(1) + [b])
        }
        if let shared = sharedParents.first {
            return DirectRelation(kind: .halfSiblings, term: "\(b.name) is \(poss) half-\(word(b, "brother", "sister", "sibling")) (through \(shared.name))",
                                  path: [a, shared, b])
        }
        for spouse in relatives(.spouse, of: a) {
            if relatives(.parents, of: spouse).contains(where: { $0.id == bID }) {
                return DirectRelation(kind: .parentInLaw, term: "\(b.name) is \(poss) \(word(b, "father", "mother", "parent"))-in-law (\(spouse.name)’s \(word(b, "father", "mother", "parent")))",
                                      path: [a, spouse, b])
            }
            if relatives(.siblings, of: spouse).contains(where: { $0.id == bID }) {
                return DirectRelation(kind: .siblingInLaw, term: "\(b.name) is \(poss) \(word(b, "brother", "sister", "sibling"))-in-law (\(spouse.name)’s \(word(b, "brother", "sister", "sibling")))",
                                      path: [a, spouse, b])
            }
        }
        for spouse in relatives(.spouse, of: b) {
            if relatives(.parents, of: spouse).contains(where: { $0.id == aID }) {
                return DirectRelation(kind: .parentInLaw, term: "\(b.name) is \(poss) \(word(b, "son", "daughter", "child"))-in-law (married to \(spouse.name))",
                                      path: [a, spouse, b])
            }
            if relatives(.siblings, of: spouse).contains(where: { $0.id == aID }) {
                return DirectRelation(kind: .siblingInLaw, term: "\(b.name) is \(poss) \(word(b, "brother", "sister", "sibling"))-in-law (married to \(spouse.name))",
                                      path: [a, spouse, b])
            }
        }
        return nil
    }

    /// "son"/"grandson"/"great-granddaughter"/"3rd-great-grandchild".
    public static func descendantLabel(generations: Int, sex: String) -> String {
        let base: String
        switch sex.uppercased() {
        case "M": base = generations == 1 ? "son" : "grandson"
        case "F": base = generations == 1 ? "daughter" : "granddaughter"
        default:  base = generations == 1 ? "child" : "grandchild"
        }
        switch generations {
        case ...2: return base
        case 3: return "great-" + base
        case 4: return "great-great-" + base
        default: return numericOrdinal(generations - 2) + "-great-" + base
        }
    }

    static func possessive(_ name: String) -> String {
        name.hasSuffix("s") ? name + "’" : name + "’s"
    }
}
