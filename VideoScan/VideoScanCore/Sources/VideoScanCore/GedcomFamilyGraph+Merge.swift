// GedcomFamilyGraph+Merge.swift
// Union of two FamilySearch exports keyed by FamilySearch ID (2026-08-27).
// Rick's 20-generation pull has Donna only as a spouse — her ancestors
// were never fetched. A second pull rooted on Donna carries them. GEDCOM
// `@I…@` pointers are export-local (Donna is @I14522@ in one file and
// @I1@ in the other), but FamilySearch's `_FSFTID` is the same in both,
// so it is the join key. Design decided 2026-08-26 (memory: enrichments
// keyed by FSID survive re-pulls).
//
// Rules, in one place:
//   • A person is the same person iff both records carry the same FSID.
//     A record WITHOUT an FSID matches only a record with the same
//     pointer, the same name and the same birth date — the "same file
//     re-exported" case. Anything looser would be guessing; those records
//     are added as new people and REPORTED (`unmatched`), never merged.
//   • A family is identified by its (husband, wife) after both are
//     mapped into the merged pointer space; children are unioned.
//   • When both files describe one person, the record with more data
//     wins the scalar fields (parents attached > not; more events; more
//     names) and the links (FAMC/FAMS) are unioned.
//   • Pointers from the first graph are kept verbatim; new people and
//     families from the second get `@IB…@` / `@FB…@` pointers so nothing
//     from the first file is renumbered (photo folders are keyed by it).
//   • Roots: the first graph's roots, then the second's (mapped), so a
//     merged tree knows BOTH home people (Rick, Donna).
//
// Cost: O(|A| + |B|) dictionary work. Memory: one copy of each record plus
// two String→String maps — a 16k + 16k merge is a few tens of MB, and the
// 2×100k scale test in GedcomMergeTests pins it under two seconds.

import Foundation

extension GedcomFamilyGraph {

    /// What the merge did, for the sheet and for Hallie's provenance line.
    public struct MergeOutcome: Sendable {
        public let graph: GedcomFamilyGraph
        /// People present in BOTH files (joined by FSID or by the strict
        /// pointer+name+birth rule).
        public let sharedPeopleCount: Int
        /// People from the second file added as new records.
        public let addedPeopleCount: Int
        /// Second-file people with no FSID that could not be matched with
        /// certainty. They are IN the merged graph as new people (under
        /// their new pointer); this list says who, so a human can look.
        public let unmatched: [Person]
        /// Second-file pointer → merged pointer, for callers that need to
        /// follow a record across the merge (tests, provenance).
        public let pointerMap: [String: String]
    }

    /// `self` ∪ `other`, keyed by FamilySearch ID. Pure; no I/O.
    public func merged(with other: GedcomFamilyGraph) -> GedcomFamilyGraph {
        merge(with: other).graph
    }

    public func merge(with other: GedcomFamilyGraph) -> MergeOutcome {
        var people = self.people
        var families = self.families
        people.reserveCapacity(self.people.count + other.people.count)
        families.reserveCapacity(self.families.count + other.families.count)

        // ---- 1. Map every person of `other` into the merged pointer space.
        var personMap: [String: String] = [:]
        personMap.reserveCapacity(other.people.count)
        var unmatched: [Person] = []
        var shared = 0
        var added = 0
        // Sorted for a deterministic pointer assignment run to run.
        for id in Self.sortedPointers(other.people.keys) {
            let theirs = other.people[id]!
            let match: String?
            if let fsid = theirs.familySearchID {
                match = personIDByFamilySearchID[fsid]
            } else if let mine = self.people[id], mine.familySearchID == nil,
                      mine.name == theirs.name, mine.birthDate == theirs.birthDate {
                match = id
            } else {
                match = nil
            }
            if let match {
                personMap[id] = match
                shared += 1
            } else {
                let fresh = Self.freshPointer(id, prefix: "@IB", taken: people)
                personMap[id] = fresh
                if theirs.familySearchID == nil { unmatched.append(theirs) }
                added += 1
                // Placeholder so later fresh pointers cannot collide;
                // replaced with the relinked record in step 3.
                people[fresh] = theirs
            }
        }

        // ---- 2. Map every family of `other`: same (husband, wife) →
        // same family; otherwise a new record.
        var familyByCouple: [String: String] = [:]
        familyByCouple.reserveCapacity(self.families.count)
        for (fid, fam) in self.families {
            let key = Self.coupleKey(fam.husband, fam.wife)
            if !key.isEmpty, familyByCouple[key] == nil { familyByCouple[key] = fid }
        }
        var familyMap: [String: String] = [:]
        familyMap.reserveCapacity(other.families.count)
        for fid in Self.sortedPointers(other.families.keys) {
            let theirs = other.families[fid]!
            let husband = theirs.husband.flatMap { personMap[$0] }
            let wife = theirs.wife.flatMap { personMap[$0] }
            let key = Self.coupleKey(husband, wife)
            if !key.isEmpty, let existing = familyByCouple[key] {
                familyMap[fid] = existing
                var merged = families[existing]!
                for child in theirs.children.compactMap({ personMap[$0] })
                where !merged.children.contains(child) {
                    merged.children.append(child)
                }
                if merged.marriageDate == nil { merged.marriageDate = theirs.marriageDate }
                families[existing] = merged
            } else {
                let fresh = Self.freshPointer(fid, prefix: "@FB", taken: families)
                familyMap[fid] = fresh
                if !key.isEmpty { familyByCouple[key] = fresh }
                families[fresh] = Family(
                    husband: husband, wife: wife,
                    children: theirs.children.compactMap { personMap[$0] },
                    marriageDate: theirs.marriageDate)
            }
        }

        // ---- 3. Relink and reconcile every person of `other`.
        for (theirID, mergedID) in personMap {
            let theirs = other.people[theirID]!
            let relinked = Self.relink(theirs, as: mergedID, familyMap: familyMap)
            if let mine = self.people[mergedID] {
                people[mergedID] = Self.reconcile(mine, relinked)
            } else {
                people[mergedID] = relinked
            }
        }

        // ---- 4. Roots and provenance.
        var roots = self.rootPersonIDs
        for id in other.rootPersonIDs.compactMap({ personMap[$0] }) where !roots.contains(id) {
            roots.append(id)
        }
        let mineNames = sourceFileNames.isEmpty ? [sourceFileName].compactMap { $0 } : sourceFileNames
        let theirNames = other.sourceFileNames.isEmpty ? [other.sourceFileName].compactMap { $0 } : other.sourceFileNames
        var names = mineNames
        for n in theirNames where !names.contains(n) { names.append(n) }

        var graph = GedcomFamilyGraph(people: people, families: families,
                                      rootPersonIDs: roots, sourceFileNames: names)
        graph.sourceDirectory = sourceDirectory
        return MergeOutcome(graph: graph, sharedPeopleCount: shared, addedPeopleCount: added,
                            unmatched: unmatched, pointerMap: personMap)
    }

    // MARK: Helpers

    /// "@I12@" < "@I100@": numeric where possible, else lexical. The keys
    /// are computed ONCE per pointer (a comparator that re-parsed both
    /// strings cost ~2 s on 100k pointers in Debug).
    static func sortedPointers<S: Sequence>(_ ids: S) -> [String] where S.Element == String {
        ids.map { ($0, pointerNumber($0)) }
            .sorted { x, y in
                if let nx = x.1, let ny = y.1, nx != ny { return nx < ny }
                return x.0 < y.0
            }
            .map(\.0)
    }

    private static func pointerNumber(_ id: String) -> Int? {
        var n = 0
        var any = false
        for scalar in id.utf8 where scalar >= 48 && scalar <= 57 {
            n = n &* 10 &+ Int(scalar - 48)
            any = true
        }
        return any ? n : nil
    }

    /// "@I14522@" → "@IB14522@" (or "@IB14522_@", … if that is taken).
    private static func freshPointer<V>(_ id: String, prefix: String, taken: [String: V]) -> String {
        let body = id.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let digits = body.drop(while: { !$0.isNumber })
        var candidate = prefix + (digits.isEmpty ? body : String(digits)) + "@"
        while taken[candidate] != nil {
            candidate.removeLast()
            candidate += "_@"
        }
        return candidate
    }

    private static func coupleKey(_ husband: String?, _ wife: String?) -> String {
        guard husband != nil || wife != nil else { return "" }
        return (husband ?? "") + "|" + (wife ?? "")
    }

    /// The same record under a new pointer with its FAMC/FAMS rewritten.
    private static func relink(_ p: Person, as id: String, familyMap: [String: String]) -> Person {
        var out = Person(id: id, name: p.name, sex: p.sex, childOfFamily: nil)
        out.alternateNames = p.alternateNames
        out.birthDate = p.birthDate
        out.deathDate = p.deathDate
        out.birthPlace = p.birthPlace
        out.deathPlace = p.deathPlace
        out.surname = p.surname
        out.alternateSurnames = p.alternateSurnames
        out.familySearchID = p.familySearchID
        let famc = (p.childOfFamilies.isEmpty ? [p.childOfFamily].compactMap { $0 } : p.childOfFamilies)
            .compactMap { familyMap[$0] }
        out.childOfFamilies = famc
        out.childOfFamily = famc.first
        out.spouseOfFamilies = p.spouseOfFamilies.compactMap { familyMap[$0] }
        return out
    }

    /// How much a record says: parents attached count most (that is what
    /// the Donna pull adds), then events and names.
    static func richness(_ p: Person) -> Int {
        var score = 0
        if !p.childOfFamilies.isEmpty || p.childOfFamily != nil { score += 100 }
        for fact in [p.birthDate, p.deathDate, p.birthPlace, p.deathPlace] where fact != nil { score += 1 }
        score += p.alternateNames.count
        return score
    }

    /// One person from two records: the richer one's scalars, the other's
    /// filling any gaps, links unioned (richer record's order first).
    static func reconcile(_ a: Person, _ b: Person) -> Person {
        let (lead, fill) = richness(b) > richness(a) ? (b, a) : (a, b)
        var out = Person(id: a.id, name: lead.name.isEmpty ? fill.name : lead.name,
                         sex: lead.sex.isEmpty ? fill.sex : lead.sex, childOfFamily: nil)
        out.surname = lead.surname ?? fill.surname
        out.birthDate = lead.birthDate ?? fill.birthDate
        out.deathDate = lead.deathDate ?? fill.deathDate
        out.birthPlace = lead.birthPlace ?? fill.birthPlace
        out.deathPlace = lead.deathPlace ?? fill.deathPlace
        out.familySearchID = lead.familySearchID ?? fill.familySearchID
        var names = lead.alternateNames
        for n in [fill.name] + fill.alternateNames where n != out.name && !names.contains(n) && !n.isEmpty {
            names.append(n)
        }
        out.alternateNames = names
        var surnames = lead.alternateSurnames
        for s in [fill.surname].compactMap({ $0 }) + fill.alternateSurnames
        where s != out.surname && !surnames.contains(s) {
            surnames.append(s)
        }
        out.alternateSurnames = surnames
        var famc = lead.childOfFamilies.isEmpty ? [lead.childOfFamily].compactMap { $0 } : lead.childOfFamilies
        for f in (fill.childOfFamilies.isEmpty ? [fill.childOfFamily].compactMap { $0 } : fill.childOfFamilies)
        where !famc.contains(f) { famc.append(f) }
        out.childOfFamilies = famc
        out.childOfFamily = famc.first
        var fams = lead.spouseOfFamilies
        for f in fill.spouseOfFamilies where !fams.contains(f) { fams.append(f) }
        out.spouseOfFamilies = fams
        return out
    }
}
