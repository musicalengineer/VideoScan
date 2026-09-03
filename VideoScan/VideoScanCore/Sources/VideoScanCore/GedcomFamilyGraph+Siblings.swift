// GedcomFamilyGraph+Siblings.swift (VideoScanCore)
// ONE symmetric sibling verdict per pair (codex #1011, #1026), the same
// shape the People-tab overlay adopted for kinship on 2026-09-02: the
// verdict is computed once from BOTH records and every surface reads it —
// `relatives(.siblings/.brother/.sister)`, the biography's family-tree
// summary, the basis note, and `directRelation`. No answer can call two
// people full siblings while another lists none.
//
//   full       — the same primary family on both sides, or both primary
//                parents shared (duplicate reciprocal FAM records:
//                @F3@ and @F3B@ with the same HUSB and WIFE, one child in
//                each, are still one couple).
//   half       — exactly one primary parent shared.
//   alternate  — a FAMC shared only through a non-primary family
//                (adoptive / step / duplicate record).
//   one-sided  — listed as a CHIL of a family the other record does not
//                link back to (a one-sided or corrupt file). Never a full
//                sibling; qualified in the basis.
//
// Symmetric BY CONSTRUCTION, which is the point of the file: every test
// below reads both records the same way, and the one asymmetric case —
// each record listing the other as a loose CHIL of a different family —
// is settled by the lexically smaller family pointer rather than by
// argument order. Candidates come from the person's FAMC families plus
// every family the two primary parents share, so the duplicate-FAM case
// is found from either side without a reverse index.
//
// Cost (the 100k sensor in GedcomParentFamilyTests): ONE walk of the
// candidates per person produces all three groups, and one pair costs
// two string compares in the ordinary case — the same-primary-family
// fast path answers before anything is allocated. No Person value is
// copied per pair. (C++: SiblingSide is a POD of pointers; the graph's
// dictionaries are consulted only when the fast path misses.)

import Foundation

extension GedcomFamilyGraph {

    public enum SiblingVerdict: Sendable, Equatable {
        case full
        /// The one shared primary parent's pointer.
        case half(through: String)
        case alternateFamily
        /// The family that lists the other person as a CHIL without a
        /// FAMC link back. When both records do that to each other, the
        /// lexically smaller pointer, so the verdict is symmetric.
        case oneSided(familyID: String)
    }

    /// What the two records prove about `a` and `b` as siblings, or nil
    /// when nothing links them that way. Symmetric: the same answer for
    /// (a, b) and (b, a).
    public func siblingVerdict(_ a: Person, _ b: Person) -> SiblingVerdict? {
        guard a.id != b.id else { return nil }
        return siblingVerdict(SiblingSide(a, in: self), SiblingSide(b, in: self))
    }

    /// One record's sibling-relevant pointers. Read once per candidate:
    /// no Person value and no Set is copied, so the 100k sensor pays two
    /// dictionary lookups per pair, not two record copies.
    struct SiblingSide {
        let id: String
        let primaryFamilyID: String?
        let familyIDs: [String]

        init(_ person: Person, in graph: GedcomFamilyGraph) {
            id = person.id
            familyIDs = graph.parentFamilyIDs(of: person)
            primaryFamilyID = graph.primaryParentFamilyID(of: person)
        }
    }

    /// The primary family's recorded parents, father then mother, as
    /// pointers — a pointer with no record in the file is not a parent.
    /// Consulted only when the two sides' primary families differ.
    private func primaryParentPointers(_ side: SiblingSide) -> [String] {
        guard let familyID = side.primaryFamilyID, let family = families[familyID] else { return [] }
        var out: [String] = []
        // `index(forKey:)` asks "is it there" without copying the record.
        if let husband = family.husband, people.index(forKey: husband) != nil { out.append(husband) }
        if let wife = family.wife, people.index(forKey: wife) != nil { out.append(wife) }
        return out
    }

    func siblingVerdict(_ a: SiblingSide, _ b: SiblingSide) -> SiblingVerdict? {
        guard a.id != b.id else { return nil }
        // The ordinary sibling: one string compare, nothing allocated.
        if let primary = a.primaryFamilyID, primary == b.primaryFamilyID { return .full }
        let parentsA = primaryParentPointers(a), parentsB = primaryParentPointers(b)
        let shared = parentsA.filter(parentsB.contains)
        if shared.count >= 2 { return .full }
        if let one = shared.first { return .half(through: one) }
        // Small arrays (a FAMC count of 1 or 2): a linear scan beats
        // building a Set, and this runs once per candidate pair.
        if a.familyIDs.contains(where: b.familyIDs.contains) { return .alternateFamily }
        var loose: [String] = []
        for id in a.familyIDs where families[id]?.children.contains(b.id) == true { loose.append(id) }
        for id in b.familyIDs where families[id]?.children.contains(a.id) == true { loose.append(id) }
        if let familyID = loose.min() { return .oneSided(familyID: familyID) }
        return nil
    }

    /// The pointers of everyone any recorded link could make a sibling of
    /// `person`: the children of the person's FAMC families, and — when
    /// both primary parents are recorded — the children of every OTHER
    /// family those same two parents share (the duplicate reciprocal FAM
    /// record). FAMC order first, no repeats, never the person.
    private func siblingCandidateIDs(of person: Person, side: SiblingSide) -> [String] {
        var ids: [String] = []
        var seen: Set<String> = [person.id]
        func add(_ familyID: String) {
            guard let family = families[familyID] else { return }
            for child in family.children where seen.insert(child).inserted { ids.append(child) }
        }
        for familyID in side.familyIDs { add(familyID) }
        guard let primaryID = side.primaryFamilyID, let primary = families[primaryID],
              let husband = primary.husband, let wife = primary.wife,
              let fathersFamilies = people[husband]?.spouseOfFamilies,
              fathersFamilies.count > 1,
              let mothersFamilies = people[wife]?.spouseOfFamilies else { return ids }
        for familyID in fathersFamilies
        where familyID != primaryID && mothersFamilies.contains(familyID) { add(familyID) }
        return ids
    }

    /// The three sibling groups from ONE walk of the candidates and ONE
    /// verdict per pair, so `relatives(.siblings)`, the basis note and
    /// `directRelation` cannot be built from different readings.
    /// Candidate order throughout.
    struct SiblingGroups {
        var full: [Person] = []
        var alternateFamily: [Person] = []
        var oneSided: [Person] = []
    }

    func siblingGroups(of person: Person) -> SiblingGroups {
        var groups = SiblingGroups()
        let side = SiblingSide(person, in: self)
        for id in siblingCandidateIDs(of: person, side: side) {
            guard let candidate = people[id] else { continue }
            switch siblingVerdict(side, SiblingSide(candidate, in: self)) {
            case .full: groups.full.append(candidate)
            case .alternateFamily: groups.alternateFamily.append(candidate)
            case .oneSided: groups.oneSided.append(candidate)
            case .half, nil: break
            }
        }
        return groups
    }

    /// Everyone the graph could read as a sibling — the pair-consistency
    /// sensor walks these from both sides.
    func siblingCandidates(of person: Person) -> [Person] {
        siblingCandidateIDs(of: person, side: SiblingSide(person, in: self)).compactMap { people[$0] }
    }

    /// Full siblings — the verdict is `.full`.
    public func primarySiblings(of person: Person) -> [Person] {
        siblingGroups(of: person).full
    }

    /// People recorded as siblings only through a second family record.
    public func alternateFamilySiblings(of person: Person) -> [Person] {
        siblingGroups(of: person).alternateFamily
    }

    /// People listed as a CHIL beside this person whose own record has no
    /// FAMC link back to that family. Visible from the linked side only —
    /// the other record carries nothing to see.
    public func oneSidedSiblings(of person: Person) -> [Person] {
        siblingGroups(of: person).oneSided
    }

    /// The basis note for people recorded as siblings only through a second
    /// family record or on one side only, or nil when there are none:
    ///   "Also recorded as a sibling through a second family record:
    ///    Adoptive Sibling, @I7@."
    ///   "Recorded as a sibling on one side only (no link back from that
    ///    record): Loose Child, @I9@."
    /// `sex` narrows both lists for a brother / sister question.
    public func alternateSiblingBasisNote(for person: Person, sex: String? = nil) -> String? {
        let groups = siblingGroups(of: person)
        func matches(_ p: Person) -> Bool { sex == nil || p.sex == sex }
        func listed(_ people: [Person]) -> String {
            people.map { "\($0.name), \(Self.recordCode($0))" }.joined(separator: "; ")
        }
        var notes: [String] = []
        let alternates = groups.alternateFamily.filter(matches)
        if !alternates.isEmpty {
            let noun = alternates.count == 1 ? "a sibling" : "siblings"
            notes.append("Also recorded as \(noun) through a second family record: \(listed(alternates)).")
        }
        let oneSided = groups.oneSided.filter(matches)
        if !oneSided.isEmpty {
            let noun = oneSided.count == 1 ? "a sibling" : "siblings"
            let back = oneSided.count == 1 ? "that record" : "those records"
            notes.append("Recorded as \(noun) on one side only (no link back from \(back)): \(listed(oneSided)).")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}
