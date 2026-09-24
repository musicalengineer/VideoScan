// GedcomFamilyGraph+IdentityRulings.swift (VideoScanCore)
// ONE ruled query view of the tree (codex #1710/#1711/#1712, 2026-09-23).
//
// Rick's identity rulings (FamilyIdentityDecisions — "the other Mary should
// be ignored by the app") used to reach exactly one query: name lookup.
// The surname roster, the superlatives, relationship answers, lineage walks
// and the People-tab picker all still read the raw records, so a record he
// had hidden came back as a grandmother, an earliest-born Breen or a
// second mother. And two app paths applied the rulings by hand, differently,
// so the Family Tree tab and Hallie disagreed about the same file.
//
// Now there is one function, `applyingIdentityRulings(_:)`, and one
// semantics that every query surface of the returned graph honours:
//
//   • A HIDDEN record (a FamilySearch id Rick ruled `hidden` or
//     `duplicateOf`) is not returned by any lookup, roster or iteration
//     (`visiblePeople`), and is nobody's relative.
//   • A RESOLVED duplicate (`duplicateOf` naming a record in this tree)
//     hands its traffic to the record he verified: a name that finds the
//     duplicate answers with the verified record; a child or spouse
//     recorded against the duplicate is the verified person's child or
//     spouse. Symmetric on purpose — the child's mother and the mother's
//     children must agree, or a walk up and a walk down disagree.
//   • What a person-ruling does NOT do: merge the duplicate's OWN parent
//     families into the verified person's, or pick between different
//     parent families. "Same human" is Rick's ruling; "same family" is a
//     separate one (adoption, remarriage) and Eileen Latta's three FAMC
//     links are still his open question. A hidden record's child-of edge
//     is simply dropped.
//
// RAW RECORDS STAY. `people`, `families`, `allRecordedParents`, the GEDCOM,
// the compiled store and provenance are never edited: audits
// (FamilyTreeVerification) and ingestion read the evidence as recorded.
//
// KEYED DURABLY. Rulings name FamilySearch ids, never GEDCOM xrefs, which
// every re-pull renumbers; the xrefs here are derived per graph.
//
// COST. With no ruling in force every function below is the old code path
// (one `isEmpty` check). With rulings: the compiled CSR topology is PATCHED
// for the people whose edges touch a ruled record (O(people) array copy +
// O(affected) relative lookups), never rebuilt from scratch — a 40k-person
// launch does not pay for a full index build because Rick hid one record.
//
// (For Rick: `GedcomFamilyGraph` is a value type — a C++ struct copied on
// assignment. `applyingIdentityRulings` returns a NEW value; the caller's
// raw graph is unchanged, and the index box — a shared_ptr-like holder —
// is replaced, never mutated, so the raw copy keeps its raw index.)

import Foundation

extension GedcomFamilyGraph {

    // MARK: Building the ruled view

    /// This graph with Rick's identity rulings applied as the query view.
    /// Idempotent: applying the same rulings again returns an equal value
    /// sharing the same index (no work). Applying different rulings to an
    /// already-ruled graph replaces the old ones — un-hiding works.
    public func applyingIdentityRulings(_ rulings: FamilyIdentityDecisions) -> GedcomFamilyGraph {
        let suppressedFSIDs = rulings.suppressedFamilySearchIDs
        var hidden: Set<String> = []
        var redirect: [String: String] = [:]
        if !suppressedFSIDs.isEmpty {
            // Every record carrying a ruled id: a malformed export can repeat
            // one, and each copy is the same wrong record.
            for person in people.values {
                if let fsid = person.familySearchID, suppressedFSIDs.contains(fsid) {
                    hidden.insert(person.id)
                }
            }
            for id in hidden {
                guard let fsid = people[id]?.familySearchID else { continue }
                let target = rulings.preferred(.familySearch(fsid))
                guard let targetFSID = target.familySearchID, targetFSID != fsid,
                      let targetPerson = person(familySearchID: targetFSID),
                      !hidden.contains(targetPerson.id) else { continue }
                redirect[id] = targetPerson.id
            }
        }
        if hidden == suppressedPersonIDs && redirect == preferredPersonID { return self }

        let previouslyTouched = suppressedPersonIDs.union(preferredPersonID.values)
        var out = self
        out.suppressedPersonIDs = hidden
        out.preferredPersonID = redirect
        var sources: [String: [String]] = [:]
        for (from, to) in redirect { sources[to, default: []].append(from) }
        out.redirectSources = sources.mapValues { $0.sorted() }
        // A FRESH box, always: the old one is shared with `self` (and every
        // other copy of the raw graph), and a ruled index installed there
        // would change the raw graph's answers. With a built index, patch
        // its topology; without one, the lazy build reads the ruled
        // `relatives` and is ruled by construction.
        let touched = previouslyTouched.union(hidden).union(redirect.values)
        out.indexBox = TreeIndexBox(indexBox.current.map { out.ruledTopology(patching: $0, touching: touched) })
        return out
    }

    // MARK: Query helpers (the ruled view's vocabulary)

    /// True when Rick ruled this record out of sight in this view.
    public func isHidden(_ personID: String) -> Bool {
        suppressedPersonIDs.contains(personID)
    }

    /// The record that answers for `personID` in the query view: itself;
    /// the verified record for a resolved duplicate; nil for a hidden one.
    public func visiblePersonID(_ personID: String) -> String? {
        guard suppressedPersonIDs.contains(personID) else { return personID }
        guard let target = preferredPersonID[personID], !suppressedPersonIDs.contains(target) else { return nil }
        return target
    }

    /// Every record the query view offers — the raw table minus the hidden
    /// ones. Order is the dictionary's (unspecified), like `people.values`;
    /// callers that rank or list sort it themselves.
    public var visiblePeople: [Person] {
        suppressedPersonIDs.isEmpty
            ? Array(people.values)
            : people.values.filter { !suppressedPersonIDs.contains($0.id) }
    }

    /// A relationship pointer read through the rulings (parents, spouses).
    func queryPerson(_ id: String?) -> Person? {
        guard let id else { return nil }
        guard !suppressedPersonIDs.isEmpty else { return people[id] }
        return visiblePersonID(id).flatMap { people[$0] }
    }

    /// A lookup's hits with hidden records handed to their verified record,
    /// or dropped, and repeats removed (first occurrence keeps its place).
    func ruledLookupResult(_ found: [Person]) -> [Person] {
        guard !suppressedPersonIDs.isEmpty else { return found }
        var out: [Person] = []
        var seen = Set<String>()
        for person in found {
            guard let id = visiblePersonID(person.id),
                  let resolved = people[id], seen.insert(id).inserted else { continue }
            out.append(resolved)
        }
        return out
    }

    // MARK: Ruled relationships

    /// `person` and the hidden duplicates that hand their traffic to them —
    /// the records whose marriages and children are this person's.
    private func ruledSelves(of person: Person) -> [Person] {
        [person] + (redirectSources[person.id] ?? []).compactMap { people[$0] }
    }

    /// `relatives(_:of:)` under the rulings. Parent edges and spouse edges
    /// are REDIRECTED (a duplicate spouse or parent is the verified
    /// person); child-of edges of a hidden record are DROPPED (its own
    /// parent families are not merged into anyone's). See the header.
    func ruledRelatives(_ relation: Relation, of person: Person) -> [Person] {
        let selves = ruledSelves(of: person)
        let selfIDs = Set(selves.map(\.id))
        switch relation {
        case .father:
            return [primaryParentFamily(of: person).flatMap { queryPerson($0.husband) }]
                .compactMap { $0 }.filter { !selfIDs.contains($0.id) }
        case .mother:
            return [primaryParentFamily(of: person).flatMap { queryPerson($0.wife) }]
                .compactMap { $0 }.filter { !selfIDs.contains($0.id) }
        case .parents:
            guard let family = primaryParentFamily(of: person) else { return [] }
            return [queryPerson(family.husband), queryPerson(family.wife)]
                .compactMap { $0 }.filter { !selfIDs.contains($0.id) }
        case .brother, .sister, .siblings:
            let sibs = uniquePeople(parentFamilyIDs(of: person)
                .compactMap { families[$0] }
                .flatMap(\.children)
                .filter { !selfIDs.contains($0) && !suppressedPersonIDs.contains($0) }
                .compactMap { people[$0] })
            switch relation {
            case .brother: return sibs.filter { $0.sex == "M" }
            case .sister:  return sibs.filter { $0.sex == "F" }
            default:       return sibs
            }
        case .son, .daughter, .children:
            let kids = uniquePeople(selves
                .flatMap(\.spouseOfFamilies)
                .compactMap { families[$0] }
                .flatMap(\.children)
                .filter { !selfIDs.contains($0) && !suppressedPersonIDs.contains($0) }
                .compactMap { people[$0] })
            switch relation {
            case .son:      return kids.filter { $0.sex == "M" }
            case .daughter: return kids.filter { $0.sex == "F" }
            default:        return kids
            }
        case .husband, .wife, .spouse:
            let spouses = uniquePeople(selves
                .flatMap { own in
                    own.spouseOfFamilies
                        .compactMap { families[$0] }
                        .flatMap { [$0.husband, $0.wife].compactMap { $0 } }
                        .filter { $0 != own.id }
                }
                .compactMap { queryPerson($0) }
                .filter { !selfIDs.contains($0.id) })
            switch relation {
            case .husband: return spouses.filter { $0.sex == "M" }
            case .wife:    return spouses.filter { $0.sex == "F" }
            default:       return spouses
            }
        }
    }

    /// `familyUnits(of:)` under the rulings: the units of the person and
    /// of their resolved duplicates, spouse read through the rulings,
    /// hidden children dropped. The unit id stays the raw FAM pointer.
    func ruledFamilyUnits(of person: Person) -> [FamilyUnit] {
        let selves = ruledSelves(of: person)
        let selfIDs = Set(selves.map(\.id))
        var seenFamilies = Set<String>()
        var out: [FamilyUnit] = []
        for own in selves {
            for familyID in own.spouseOfFamilies where seenFamilies.insert(familyID).inserted {
                guard let family = families[familyID] else { continue }
                let isHusband = family.husband == own.id
                let isWife = family.wife == own.id
                guard isHusband != isWife else { continue }
                let spouse = queryPerson(isHusband ? family.wife : family.husband)
                out.append(FamilyUnit(
                    id: familyID,
                    spouse: spouse.flatMap { selfIDs.contains($0.id) ? nil : $0 },
                    children: family.children.compactMap { id in
                        selfIDs.contains(id) || suppressedPersonIDs.contains(id) ? nil : people[id]
                    },
                    marriageDate: family.marriageDate))
            }
        }
        return out
    }

    /// `marriages(of:)` under the rulings (same selves, same spouse rule).
    func ruledMarriages(of person: Person) -> [Marriage] {
        let selves = ruledSelves(of: person)
        let selfIDs = Set(selves.map(\.id))
        var seenFamilies = Set<String>()
        var out: [Marriage] = []
        for own in selves {
            for familyID in own.spouseOfFamilies where seenFamilies.insert(familyID).inserted {
                guard let family = families[familyID] else { continue }
                let spouseID = [family.husband, family.wife].compactMap { $0 }.first { $0 != own.id }
                let spouse = queryPerson(spouseID).flatMap { selfIDs.contains($0.id) ? nil : $0 }
                out.append(Marriage(spouse: spouse, date: family.marriageDate))
            }
        }
        return out
    }

    // MARK: Ruled topology (the compiled CSR the walks read)

    /// `index` with the parent / child / spouse lists of every person whose
    /// edges touch a ruled record recomputed from the ruled `relatives` —
    /// exactly what `TreeIndex(graph:)` would build for this graph (pinned
    /// by GedcomIdentityRulingsTests), without re-tokenizing 40k names.
    /// `touching` = hidden records, their verified records, and those of
    /// the rulings being replaced.
    func ruledTopology(patching index: TreeIndex, touching touched: Set<String>) -> TreeIndex {
        var affected = Set<Int32>()
        func add(_ id: String?) {
            if let id, let o = index.ordinal(of: id) { affected.insert(o) }
        }
        for id in touched {
            guard let person = people[id] else { continue }
            add(id)
            // Its marriages: the spouses' spouse lists, the children's parent lists.
            for familyID in person.spouseOfFamilies {
                guard let family = families[familyID] else { continue }
                add(family.husband); add(family.wife)
                family.children.forEach { add($0) }
            }
            // Its parent families: the parents' child lists.
            for familyID in parentFamilyIDs(of: person) {
                guard let family = families[familyID] else { continue }
                add(family.husband); add(family.wife)
            }
        }
        guard !affected.isEmpty else { return index }

        var parentStart: [Int32] = [0], parents: [Int32] = [], motherOffset: [Int32] = []
        var childStart: [Int32] = [0], children: [Int32] = []
        var spouseStart: [Int32] = [0], spouses: [Int32] = []
        parentStart.reserveCapacity(index.count + 1)
        motherOffset.reserveCapacity(index.count)
        childStart.reserveCapacity(index.count + 1)
        spouseStart.reserveCapacity(index.count + 1)
        parents.reserveCapacity(index.parents.count)
        children.reserveCapacity(index.children.count)
        spouses.reserveCapacity(index.spouses.count)

        // Same rules as the builder: unique within each half / list, in
        // `relatives` order.
        func appendUnique(_ list: inout [Int32], _ from: Int, _ people: [Person]) {
            for p in people {
                if let o = index.ordinal(of: p.id), !list[from...].contains(o) { list.append(o) }
            }
        }
        for i in 0..<index.count {
            let o = Int32(i)
            if affected.contains(o), let person = people[index.ids[i]] {
                let pFrom = parents.count
                appendUnique(&parents, pFrom, relatives(.father, of: person))
                motherOffset.append(Int32(parents.count))
                appendUnique(&parents, parents.count, relatives(.mother, of: person))
                parentStart.append(Int32(parents.count))
                appendUnique(&children, children.count, relatives(.children, of: person))
                childStart.append(Int32(children.count))
                appendUnique(&spouses, spouses.count, relatives(.spouse, of: person))
                spouseStart.append(Int32(spouses.count))
            } else {
                let fathers = index.fathers(of: o)
                parents.append(contentsOf: fathers)
                motherOffset.append(Int32(parents.count))
                parents.append(contentsOf: index.mothers(of: o))
                parentStart.append(Int32(parents.count))
                children.append(contentsOf: index.children(of: o))
                childStart.append(Int32(children.count))
                spouses.append(contentsOf: index.spouses(of: o))
                spouseStart.append(Int32(spouses.count))
            }
        }
        return index.replacingTopology(parentStart: parentStart, parents: parents, motherOffset: motherOffset,
                                       childStart: childStart, children: children,
                                       spouseStart: spouseStart, spouses: spouses)
    }
}

extension GedcomFamilyGraph.TreeIndex {
    /// A copy with new CSR topology; every name / sidebar / launch table is
    /// shared (copy-on-write arrays). The identity-rulings view only.
    func replacingTopology(parentStart: [Int32], parents: [Int32], motherOffset: [Int32],
                           childStart: [Int32], children: [Int32],
                           spouseStart: [Int32], spouses: [Int32]) -> GedcomFamilyGraph.TreeIndex {
        GedcomFamilyGraph.TreeIndex(
            ids: ids, nameRank: nameRank,
            parentStart: parentStart, parents: parents, motherOffset: motherOffset,
            childStart: childStart, children: children,
            spouseStart: spouseStart, spouses: spouses,
            tokens: tokens, likeTokens: likeTokens, surnames: surnames,
            givenNames: givenNames, familySearchIDs: familySearchIDs,
            recordStart: recordStart, recordTokenStart: recordTokenStart,
            recordTokenIDs: recordTokenIDs, recordLikeIDs: recordLikeIDs,
            marriedStart: marriedStart, marriedIDs: marriedIDs,
            surnameStart: surnameStart, surnameIDs: surnameIDs,
            sidebarOrder: sidebarOrder, sidebarHaystack: sidebarHaystack, sidebarStart: sidebarStart,
            identityKeys: identityKeys, givenStart: givenStart, givenIDs: givenIDs,
            surnameTokenStart: surnameTokenStart, surnameTokenIDs: surnameTokenIDs, suffixIDs: suffixIDs,
            lifeYears: lifeYears)
    }
}
