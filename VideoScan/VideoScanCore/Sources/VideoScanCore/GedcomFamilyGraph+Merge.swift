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
//     A record WITHOUT an FSID from a DIFFERENT source is NEVER matched
//     (codex #775: "@I42@ John Smith" in two independent exports are two
//     people; pointer + name is not identity). It is added as a new
//     person and REPORTED (`unmatched`). Only when both graphs carry the
//     same `sourceFingerprint` (the identical file re-read) does the
//     pointer alone identify it — that keeps self-merge idempotent.
//   • A family is the same family iff BOTH spouses carry an FSID and both
//     match (a couple key). A family with a missing or FSID-less partner
//     is keyed by (its known parent(s), its sorted children) and merges
//     ONLY with an identical key — two unknown-partner families of one
//     parent are never conflated (codex #773/#774); such near-misses are
//     listed in `conflicts` for a human.
//   • When both files describe one person, the FIRST graph's non-nil
//     values are kept, nils are filled from the second, a differing
//     second value is REPORTED (`fieldDisagreement`, codex #780), and the
//     links (FAMC/FAMS) are unioned. The same rule applies to a matched
//     family's MARR DATE (codex #794): first kept, disagreement reported.
//   • Deterministic (codex #794): every table is walked in pointer order
//     (`sortedPointers`), never in Dictionary order, so the same two
//     graphs — or the same records in a different file order — give a
//     byte-identical `gedcomText()` and the same conflict list. Pinned by
//     a sensor in GedcomMergeTests.
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

    /// One thing the merge could not decide by rule and left as it found
    /// it, for the verification step and the HEAD NOTE.
    public struct ConflictReport: Sendable, Equatable {
        public enum Kind: String, Sendable {
            /// Second-file person with no FSID: added as new, never matched.
            case unmatchedPerson
            /// A family sharing a parent with an existing one but not the
            /// same couple/children key: kept as its own record.
            case familyKeptSeparate
            /// Both sources give a different non-nil value for one field
            /// of the same person — or the MARR DATE of the same family
            /// (codex #794) — or two provenance entries for the SAME file
            /// (name + sha) disagree on its dropped-line count (codex
            /// #810, `ids` = [file name]): the FIRST source's value is kept
            /// (codex #780), the other is recorded here (and a second NAME
            /// survives as an alternate name).
            case fieldDisagreement
        }
        public let kind: Kind
        /// Pointers involved: `[person]` (merged space); `[existing FAM,
        /// new FAM]` for a family kept separate; `[merged FAM, the second
        /// file's own FAM pointer]` for a matched-family MARR disagreement
        /// (the second family has no merged pointer — it folded into the
        /// first).
        public let ids: [String]
        public let resolution: String
    }

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
        /// Everything left undecided by rule (see `ConflictReport`).
        public let conflicts: [ConflictReport]
        /// How many `fieldDisagreement` entries `conflicts` holds.
        public var fieldConflictCount: Int { conflicts.filter { $0.kind == .fieldDisagreement }.count }
        /// Lines lost from EVERY source on the way to `graph` — equal to
        /// `graph.totalDroppedLineCount` (each source counted once, codex
        /// #810). Per-source detail is in `graph.sourceProvenance`.
        public let droppedLineCount: Int
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
        let sameSource = sourceFingerprint != nil && sourceFingerprint == other.sourceFingerprint
        var shared = 0
        var added = 0
        // Sorted for a deterministic pointer assignment run to run.
        for id in Self.sortedPointers(other.people.keys) {
            let theirs = other.people[id]!
            let match: String?
            if let fsid = theirs.familySearchID {
                match = personIDByFamilySearchID[fsid]
            } else if sameSource, let mine = self.people[id], mine.familySearchID == nil {
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

        // ---- 2. Map every family of `other`: identical key → same
        // family; otherwise a new record (and a conflict note when it
        // shares a parent with an existing one).
        var conflicts: [ConflictReport] = unmatched.map {
            ConflictReport(kind: .unmatchedPerson, ids: [personMap[$0.id] ?? $0.id],
                           resolution: "\($0.name): no FamilySearch ID, added as a new person (not matched)")
        }
        var familyByKey: [String: String] = [:]
        var familiesByParent: [String: [String]] = [:]
        familyByKey.reserveCapacity(self.families.count)
        func index(_ fid: String, _ fam: Family, in people: [String: Person]) {
            let key = Self.familyKey(fam, people: people)
            if familyByKey[key.key] == nil { familyByKey[key.key] = fid }
            for parent in key.parents { familiesByParent[parent, default: []].append(fid) }
        }
        // Pointer order, not Dictionary order: which record wins a
        // duplicate key and which neighbour a near-miss names must be the
        // same every run (codex #794).
        for fid in Self.sortedPointers(self.families.keys) { index(fid, self.families[fid]!, in: people) }
        var familyMap: [String: String] = [:]
        familyMap.reserveCapacity(other.families.count)
        for fid in Self.sortedPointers(other.families.keys) {
            let theirs = other.families[fid]!
            let mapped = Family(
                husband: theirs.husband.flatMap { personMap[$0] },
                wife: theirs.wife.flatMap { personMap[$0] },
                children: theirs.children.compactMap { personMap[$0] },
                marriageDate: theirs.marriageDate,
                familySearchID: theirs.familySearchID)
            let key = Self.familyKey(mapped, people: people)
            if let existing = familyByKey[key.key] {
                familyMap[fid] = existing
                var merged = families[existing]!
                for child in mapped.children where !merged.children.contains(child) {
                    merged.children.append(child)
                }
                // First source's family id wins; the second fills a blank.
                if merged.familySearchID == nil { merged.familySearchID = mapped.familySearchID }
                if let mine = merged.marriageDate, !mine.isEmpty {
                    if let theirDate = mapped.marriageDate, !theirDate.isEmpty, theirDate != mine {
                        let who = key.parents.compactMap { people[$0]?.name }.joined(separator: " & ")
                        conflicts.append(ConflictReport(
                            kind: .fieldDisagreement, ids: [existing, fid],
                            resolution: "\(who) MARR DATE: kept “\(mine)” (first source, \(existing)); second source (\(fid)) says “\(theirDate)”"))
                    }
                } else {
                    merged.marriageDate = mapped.marriageDate
                }
                families[existing] = merged
            } else {
                let fresh = Self.freshPointer(fid, prefix: "@FB", taken: families)
                familyMap[fid] = fresh
                families[fresh] = mapped
                // A near-miss: same parent already has a family here that
                // this one did not key-match (unknown partner, different
                // children, or a partner without an FSID). Kept separate.
                let neighbours = key.parents.flatMap { familiesByParent[$0] ?? [] }
                if let near = neighbours.first {
                    let who = key.parents.compactMap { people[$0]?.name }.joined(separator: " & ")
                    conflicts.append(ConflictReport(
                        kind: .familyKeptSeparate, ids: [near, fresh],
                        resolution: "\(who): family \(fresh) kept separate from \(near) — "
                            + (key.isCouple ? "same couple but partner FSIDs differ" : "partner unknown or without FSID; children/marriage not merged")))
                }
                index(fresh, mapped, in: people)
            }
        }

        // ---- 3. Relink and reconcile every person of `other`
        // (sorted so the conflict list is stable run to run).
        for theirID in Self.sortedPointers(personMap.keys) {
            let mergedID = personMap[theirID]!
            let theirs = other.people[theirID]!
            let relinked = Self.relink(theirs, as: mergedID, familyMap: familyMap)
            if let mine = self.people[mergedID] {
                let (person, disagreements) = Self.reconcile(mine, relinked)
                people[mergedID] = person
                conflicts.append(contentsOf: disagreements)
            } else {
                people[mergedID] = relinked
            }
        }

        // ---- 4. Roots and provenance.
        var roots = self.rootPersonIDs
        for id in other.rootPersonIDs.compactMap({ personMap[$0] }) where !roots.contains(id) {
            roots.append(id)
        }
        // Provenance (codex #810): union of the two CANONICAL lists, first
        // side first, by identity (name, sha256). One entry per identity;
        // its loss counted ONCE. Two entries of one identity disagreeing on
        // the count → reported, first kept. Local loss = both sides' local
        // (only a nameless text side has any: it cannot be listed, so its
        // loss stays unattributed and the total never under-counts).
        let mine = canonicalized(), theirs = other.canonicalized()
        var provenance = mine.sourceProvenance
        var seen: [String: Int] = [:]
        for (i, p) in provenance.enumerated() where seen[p.identity] == nil { seen[p.identity] = i }
        for p in theirs.sourceProvenance {
            if let i = seen[p.identity] {
                if provenance[i].droppedLineCount != p.droppedLineCount {
                    conflicts.append(ConflictReport(
                        kind: .fieldDisagreement, ids: [p.name],
                        resolution: "\(p.name) dropped lines: kept \(provenance[i].droppedLineCount) (first source); "
                            + "second source says \(p.droppedLineCount) for the same file (sha \(p.sha256.map { String($0.prefix(12)) } ?? "none"))"))
                }
            } else {
                seen[p.identity] = provenance.count
                provenance.append(p)
            }
        }
        var names: [String] = []
        for p in provenance where !names.contains(p.name) { names.append(p.name) }
        var graph = GedcomFamilyGraph(people: people, families: families,
                                      rootPersonIDs: roots, sourceFileNames: names,
                                      isMergedArtifact: true,
                                      droppedLineCount: mine.droppedLineCount + theirs.droppedLineCount,
                                      sourceProvenance: provenance)
        graph.sourceDirectory = sourceDirectory
        let dropped = graph.totalDroppedLineCount
        return MergeOutcome(graph: graph, sharedPeopleCount: shared, addedPeopleCount: added,
                            unmatched: unmatched, pointerMap: personMap, conflicts: conflicts,
                            droppedLineCount: dropped)
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

    /// The identity of a family record. A COUPLE key ("C:h|w") needs both
    /// partners present AND both carrying an FSID; anything else is a
    /// PARTIAL key ("P:<parents>|K:<sorted children>") that matches only
    /// an identical record. `parents` are the merged pointers used for the
    /// near-miss report. Identity keys are FSIDs where present so the same
    /// person under two pointers still keys the same.
    static func familyKey(_ fam: Family, people: [String: Person]) -> (key: String, parents: [String], isCouple: Bool) {
        func identity(_ id: String) -> String { people[id]?.familySearchID ?? id }
        let parents = [fam.husband, fam.wife].compactMap { $0 }
        if let h = fam.husband, let w = fam.wife,
           let hf = people[h]?.familySearchID, let wf = people[w]?.familySearchID {
            return ("C:\(hf)|\(wf)", parents, true)
        }
        let p = (fam.husband.map { "H=" + identity($0) } ?? "H=") + "," + (fam.wife.map { "W=" + identity($0) } ?? "W=")
        let kids = fam.children.map(identity).sorted().joined(separator: ",")
        return ("P:\(p)|K:\(kids)", parents, false)
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

    /// One person from two records (codex #780): the FIRST source's
    /// value wins wherever both sources give a different non-nil value,
    /// and that disagreement is reported; a nil on the first side is
    /// filled from the second. A differing second NAME is kept as an
    /// alternate name. Links (FAMC/FAMS) are unioned, first source's
    /// order first.
    static func reconcile(_ a: Person, _ b: Person) -> (Person, [ConflictReport]) {
        var conflicts: [ConflictReport] = []
        let who = a.familySearchID ?? a.id
        func pick(_ field: String, _ x: String?, _ y: String?) -> String? {
            guard let x, !x.isEmpty else { return (y?.isEmpty ?? true) ? nil : y }
            if let y, !y.isEmpty, y != x {
                conflicts.append(ConflictReport(
                    kind: .fieldDisagreement, ids: [a.id],
                    resolution: "\(who) \(field): kept “\(x)” (first source); second source says “\(y)”"))
            }
            return x
        }
        var out = Person(id: a.id, name: pick("NAME", a.name, b.name) ?? "",
                         sex: pick("SEX", a.sex, b.sex) ?? "", childOfFamily: nil)
        out.surname = a.surname ?? b.surname
        out.birthDate = pick("BIRT DATE", a.birthDate, b.birthDate)
        out.deathDate = pick("DEAT DATE", a.deathDate, b.deathDate)
        out.birthPlace = pick("BIRT PLAC", a.birthPlace, b.birthPlace)
        out.deathPlace = pick("DEAT PLAC", a.deathPlace, b.deathPlace)
        out.familySearchID = a.familySearchID ?? b.familySearchID
        var names = a.alternateNames
        for n in [b.name] + b.alternateNames where n != out.name && !names.contains(n) && !n.isEmpty {
            names.append(n)
        }
        out.alternateNames = names
        var surnames = a.alternateSurnames
        for s in [b.surname].compactMap({ $0 }) + b.alternateSurnames
        where s != out.surname && !surnames.contains(s) {
            surnames.append(s)
        }
        out.alternateSurnames = surnames
        var famc = a.childOfFamilies.isEmpty ? [a.childOfFamily].compactMap { $0 } : a.childOfFamilies
        for f in (b.childOfFamilies.isEmpty ? [b.childOfFamily].compactMap { $0 } : b.childOfFamilies)
        where !famc.contains(f) { famc.append(f) }
        out.childOfFamilies = famc
        out.childOfFamily = famc.first
        var fams = a.spouseOfFamilies
        for f in b.spouseOfFamilies where !fams.contains(f) { fams.append(f) }
        out.spouseOfFamilies = fams
        return (out, conflicts)
    }
}
