// GedcomFamilyGraph+Siblings.swift (VideoScanCore)
// ONE symmetric sibling verdict per pair (codex #1011). Every surface —
// `relatives(.siblings/.brother/.sister)`, the biography's family-tree
// summary, and `directRelation` — reads the SAME verdict, computed from
// the PRIMARY parent family on BOTH sides, so no answer can call two
// people full siblings while another lists none.
//
//   full       — the same primary family on both sides, or both primary
//                parents shared (duplicate reciprocal FAM records:
//                @F3@ and @F3'@ with the same HUSB and WIFE, one child in
//                each, still one family).
//   half       — exactly one primary parent shared.
//   alternate  — a FAMC shared only through a non-primary family
//                (adoptive / step / duplicate record).
//   one-sided  — listed as a CHIL of a family the other record does not
//                link back to (a one-sided or corrupt file). Never a full
//                sibling; qualified in the basis.
// Symmetric by construction: every test above reads both records the
// same way. Candidates come from the person's FAMC families plus every
// family the two primary parents share, so the duplicate-FAM case is
// found from either side without a reverse index.

import Foundation

extension GedcomFamilyGraph {

    public enum SiblingVerdict: Sendable, Equatable {
        case full
        /// The one shared primary parent's pointer.
        case half(through: String)
        case alternateFamily
        /// The family that lists the other person as a CHIL without a
        /// FAMC link back.
        case oneSided(familyID: String)
    }

    /// What the two records prove about `a` and `b` as siblings, or nil
    /// when nothing links them that way. Symmetric: the same answer for
    /// (a, b) and (b, a).
    public func siblingVerdict(_ a: Person, _ b: Person) -> SiblingVerdict? {
        guard a.id != b.id else { return nil }
        return siblingVerdict(SiblingSide(a, in: self), SiblingSide(b, in: self))
    }

    /// One record's sibling-relevant facts, read once per person so a
    /// list of candidates costs one read per candidate.
    struct SiblingSide {
        let id: String
        let primaryFamilyID: String?
        let primaryParentIDs: [String]
        let familyIDs: [String]

        init(_ person: Person, in graph: GedcomFamilyGraph) {
            id = person.id
            primaryFamilyID = graph.primaryParentFamilyID(of: person)
            primaryParentIDs = graph.relatives(.parents, of: person).map(\.id)
            familyIDs = graph.parentFamilyIDs(of: person)
        }
    }

    func siblingVerdict(_ a: SiblingSide, _ b: SiblingSide) -> SiblingVerdict? {
        let shared = a.primaryParentIDs.filter { b.primaryParentIDs.contains($0) }
        if shared.count >= 2 { return .full }
        if let primary = a.primaryFamilyID, primary == b.primaryFamilyID { return .full }
        if let one = shared.first { return .half(through: one) }
        let setB = Set(b.familyIDs)
        if a.familyIDs.contains(where: { setB.contains($0) }) { return .alternateFamily }
        for id in a.familyIDs where !setB.contains(id) && families[id]?.children.contains(b.id) == true {
            return .oneSided(familyID: id)
        }
        let setA = Set(a.familyIDs)
        for id in b.familyIDs where !setA.contains(id) && families[id]?.children.contains(a.id) == true {
            return .oneSided(familyID: id)
        }
        return nil
    }

    /// Everyone any recorded link could make a sibling of `person`: the
    /// children of the person's FAMC families, and — when both primary
    /// parents are recorded — the children of every family those two
    /// parents share. FAMC order, no repeats, never the person.
    func siblingCandidates(of person: Person) -> [Person] {
        var ids: [String] = []
        for id in parentFamilyIDs(of: person) { ids += families[id]?.children ?? [] }
        let parents = relatives(.parents, of: person)
        if parents.count >= 2 {
            let other = Set(parents[1].spouseOfFamilies)
            for id in parents[0].spouseOfFamilies where other.contains(id) { ids += families[id]?.children ?? [] }
        }
        return uniquePeople(ids.filter { $0 != person.id }.compactMap { people[$0] })
    }

    private func siblings(of person: Person, where keep: (SiblingVerdict) -> Bool) -> [Person] {
        let candidates = siblingCandidates(of: person)
        guard !candidates.isEmpty else { return [] }
        let side = SiblingSide(person, in: self)
        return candidates.filter { candidate in
            siblingVerdict(side, SiblingSide(candidate, in: self)).map(keep) ?? false
        }
    }

    /// Full siblings — the verdict is `.full`.
    public func primarySiblings(of person: Person) -> [Person] {
        siblings(of: person) { $0 == .full }
    }

    /// People recorded as siblings only through a second family record.
    public func alternateFamilySiblings(of person: Person) -> [Person] {
        siblings(of: person) { $0 == .alternateFamily }
    }

    /// People listed as a CHIL beside this person whose own record has no
    /// FAMC link back to that family. Visible from the linked side only —
    /// the other record carries nothing to see.
    public func oneSidedSiblings(of person: Person) -> [Person] {
        siblings(of: person) { if case .oneSided = $0 { return true } else { return false } }
    }

    /// The basis note for people recorded as siblings only through a second
    /// family record or on one side only, or nil when there are none:
    ///   "Also recorded as a sibling through a second family record:
    ///    Adoptive Sibling, @I7@."
    ///   "Recorded as a sibling on one side only (no link back from that
    ///    record): Loose Child, @I9@."
    /// `sex` narrows both lists for a brother / sister question.
    public func alternateSiblingBasisNote(for person: Person, sex: String? = nil) -> String? {
        func matches(_ p: Person) -> Bool { sex == nil || p.sex == sex }
        func listed(_ people: [Person]) -> String {
            people.map { "\($0.name), \(Self.recordCode($0))" }.joined(separator: "; ")
        }
        var notes: [String] = []
        let alternates = alternateFamilySiblings(of: person).filter(matches)
        if !alternates.isEmpty {
            let noun = alternates.count == 1 ? "a sibling" : "siblings"
            notes.append("Also recorded as \(noun) through a second family record: \(listed(alternates)).")
        }
        let oneSided = oneSidedSiblings(of: person).filter(matches)
        if !oneSided.isEmpty {
            let noun = oneSided.count == 1 ? "a sibling" : "siblings"
            let back = oneSided.count == 1 ? "that record" : "those records"
            notes.append("Recorded as \(noun) on one side only (no link back from \(back)): \(listed(oneSided)).")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}
