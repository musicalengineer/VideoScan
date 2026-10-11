// GedcomTreeIndexBuildCharacterizationTests.swift
// The compiled index must be IDENTICAL, field for field, before and after
// the 2026-10-10 split of TreeIndex.init(graph:) (CCN 34, 179 lines) into
// its four builders. `legacyBuild(graph:)` is the pre-split init body,
// copied verbatim and frozen (do not "fix"), ending in the memberwise init;
// TreeIndex is Equatable, so one assertion per graph pins all 33 arrays.
// Graphs: the kinship fixture, the index-equivalence edge-case tree
// (alternate names, duplicate FSIDs, a surname-only name, diacritics), and
// two synthetic pedigrees (5k with the compiled-artifact round trip; 100k
// timed, Debug numbers printed, budgets asserted by GedcomScaleSensorTests).

import XCTest
@testable import VideoScanCore

final class GedcomTreeIndexBuildCharacterizationTests: XCTestCase {

    static let edgeTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 FAMC @F1@
    1 FAMS @F2@
    1 _FSFTID GVQV-NW3
    0 @I2@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 FAMS @F1@
    1 _FSFTID GVQV-NW3
    1 BIRT
    2 DATE 12 MAR 1929
    0 @I3@ INDI
    1 NAME Muriel /Lamb/
    1 NAME Muriel Burton /Lamb/
    1 SEX F
    1 FAMS @F1@
    1 BIRT
    2 DATE ABT 1930
    1 DEAT
    2 DATE 2001
    0 @I4@ INDI
    1 NAME Ann Mc Gill
    1 SEX F
    1 FAMS @F2@
    0 @I5@ INDI
    1 NAME Joanne /Jones/
    1 SEX F
    0 @I6@ INDI
    1 NAME Frederick Burton /Lamb/
    1 SEX M
    0 @I7@ INDI
    1 NAME William /Stone/
    1 NAME Bill /Stone/
    1 SEX M
    0 @I8@ INDI
    1 NAME /De Hendour/
    1 SEX M
    0 @I9@ INDI
    1 NAME Zoë /Élan/
    1 SEX F
    0 @F1@ FAM
    1 HUSB @I2@
    1 WIFE @I3@
    1 CHIL @I1@
    0 @F2@ FAM
    1 HUSB @I1@
    1 WIFE @I4@
    0 TRLR
    """

    // MARK: Frozen pre-split builder (verbatim copy of the old init body)

    static func legacyBuild(graph: GedcomFamilyGraph) -> GedcomFamilyGraph.TreeIndex {
        typealias PostingTable = GedcomFamilyGraph.PostingTable
        let ids = graph.people.keys.sorted()
        var ordinalByID: [String: Int32] = [:]
        ordinalByID.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() { ordinalByID[id] = Int32(i) }

        var parentStart: [Int32] = [0], parents: [Int32] = [], motherOffset: [Int32] = []
        var childStart: [Int32] = [0], children: [Int32] = []
        var spouseStart: [Int32] = [0], spouses: [Int32] = []
        var tokens: [String: [Int32]] = [:]
        var like: [String: [Int32]] = [:]
        var surnames: [String: [Int32]] = [:]
        var givens: [String: [Int32]] = [:]
        var fsids: [String: [Int32]] = [:]
        // Per-record token strings, resolved to key positions once the
        // sorted key arrays exist.
        var recordStart: [Int32] = [0]
        var recordTokenStart: [Int32] = [0]
        var recordTokens: [String] = []
        var marriedStart: [Int32] = [0]
        var marriedTokens: [String] = []
        var surnameStart: [Int32] = [0]
        var surnameTokens: [String] = []
        parentStart.reserveCapacity(ids.count + 1)
        motherOffset.reserveCapacity(ids.count)
        childStart.reserveCapacity(ids.count + 1)
        spouseStart.reserveCapacity(ids.count + 1)
        recordStart.reserveCapacity(ids.count + 1)

        func appendUnique(_ list: inout [Int32], _ from: Int, _ o: Int32) {
            if !list[from...].contains(o) { list.append(o) }
        }
        for (i, id) in ids.enumerated() {
            let o = Int32(i)
            let person = graph.people[id]!
            // Fathers (unique) then mothers (unique) — NOT deduplicated
            // across the two halves, exactly like relatives(.father) +
            // relatives(.mother); walks handle repeats with their seen set.
            let pFrom = parents.count
            for p in graph.relatives(.father, of: person) {
                if let po = ordinalByID[p.id] { appendUnique(&parents, pFrom, po) }
            }
            motherOffset.append(Int32(parents.count))
            let mFrom = parents.count
            for p in graph.relatives(.mother, of: person) {
                if let po = ordinalByID[p.id] { appendUnique(&parents, mFrom, po) }
            }
            parentStart.append(Int32(parents.count))
            let cFrom = children.count
            for c in graph.relatives(.children, of: person) {
                if let co = ordinalByID[c.id] { appendUnique(&children, cFrom, co) }
            }
            childStart.append(Int32(children.count))
            let sFrom = spouses.count
            for s in graph.relatives(.spouse, of: person) {
                if let so = ordinalByID[s.id] { appendUnique(&spouses, sFrom, so) }
            }
            spouseStart.append(Int32(spouses.count))

            for name in [person.name] + person.alternateNames {
                let raw = FamilyIdentityText.tokens(name)
                for (t, token) in raw.enumerated() {
                    tokens[token, default: []].append(o)
                    like[GedcomFamilyGraph.diminutives[token] ?? token, default: []].append(o)
                    if t == 0 { givens[token, default: []].append(o) }
                    recordTokens.append(token)
                }
                recordTokenStart.append(Int32(recordTokens.count))
            }
            recordStart.append(Int32(recordTokenStart.count - 1))
            for token in graph.marriedSurnames(of: person) {
                like[token, default: []].append(o)
                marriedTokens.append(token)
            }
            marriedStart.append(Int32(marriedTokens.count))
            for surname in [person.surname].compactMap({ $0 }) + person.alternateSurnames {
                let key = FamilyIdentityText.normalized(surname)
                surnames[key, default: []].append(o)
                surnameTokens.append(key)
            }
            surnameStart.append(Int32(surnameTokens.count))
            if let fsid = person.familySearchID { fsids[fsid, default: []].append(o) }
        }
        let tokenTable = PostingTable(tokens)
        let likeTable = PostingTable(like)
        let surnameTable = PostingTable(surnames)
        let built_tokens = tokenTable
        let likeTokens = likeTable
        let built_surnames = surnameTable
        let givenNames = PostingTable(givens)
        let familySearchIDs = PostingTable(fsids)
        let recordTokenIDs = recordTokens.map { Int32(tokenTable.position(of: $0)!) }
        let recordLikeIDs = recordTokens.map {
            Int32(likeTable.position(of: GedcomFamilyGraph.diminutives[$0] ?? $0)!)
        }
        let marriedIDs = marriedTokens.map { Int32(likeTable.position(of: $0)!) }
        let surnameIDs = surnameTokens.map { Int32(surnameTable.position(of: $0)!) }

        // Name order (name, then id) as a rank per ordinal. Names are
        // pulled once; the comparator touches only arrays.
        let names = ids.map { graph.people[$0]!.name }
        let byName = (0..<ids.count).sorted { a, b in
            names[a] == names[b] ? ids[a] < ids[b] : names[a] < names[b]
        }
        var rank = [Int32](repeating: 0, count: ids.count)
        for (r, o) in byName.enumerated() { rank[o] = Int32(r) }
        let nameRank = rank

        // Sidebar order: the Family Tree comparator (surname, name, id;
        // no surname last), keys computed ONCE per person instead of
        // per comparison.
        struct SortKey { let surname: String; let name: String; let ordinal: Int32 }
        var keys: [SortKey] = []
        keys.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() {
            let person = graph.people[id]!
            keys.append(SortKey(surname: person.surname?.lowercased() ?? "\u{FFFF}",
                                name: person.name.lowercased(), ordinal: Int32(i)))
        }
        keys.sort { lhs, rhs in
            if lhs.surname != rhs.surname { return lhs.surname < rhs.surname }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return ids[Int(lhs.ordinal)] < ids[Int(rhs.ordinal)]
        }
        let order = keys.map(\.ordinal)
        let sidebarOrder = order

        var haystack: [UInt8] = []
        var starts: [Int32] = [0]
        starts.reserveCapacity(order.count + 1)
        haystack.reserveCapacity(order.count * 64)
        for o in order {
            let person = graph.people[ids[Int(o)]]!
            for field in GedcomFamilyGraph.sidebarSearchFields(of: person) {
                haystack.append(contentsOf: field.lowercased().utf8)
                haystack.append(0x0A)
            }
            starts.append(Int32(haystack.count))
        }
        let sidebarHaystack = haystack
        let sidebarStart = starts

        // Launch tables (formatVersion 2): the tree pass of the
        // group-photo identity directory, per person, and the sidebar
        // life-years line. Spouses are exactly `familyUnits(of:)`'s —
        // a FAMS whose FAM names this person in one partner role.
        let suffixes = GedcomFamilyGraph.nameSuffixes
        var givenTokens: [[String]] = [], surnameTokens2: [[String]] = [], suffixTokens: [String?] = []
        givenTokens.reserveCapacity(ids.count); surnameTokens2.reserveCapacity(ids.count)
        suffixTokens.reserveCapacity(ids.count)
        var identityKeySet: Set<String> = []
        var lifeYears: [String] = []
        lifeYears.reserveCapacity(ids.count)
        for id in ids {
            let person = graph.people[id]!
            var surnameSet = Set(FamilyIdentityText.tokens(person.surname ?? ""))
            for familyID in person.spouseOfFamilies {
                guard let family = graph.families[familyID] else { continue }
                let isHusband = family.husband == person.id, isWife = family.wife == person.id
                guard isHusband != isWife else { continue }
                if let spouseID = isHusband ? family.wife : family.husband, let spouse = graph.people[spouseID] {
                    surnameSet.formUnion(FamilyIdentityText.tokens(spouse.surname ?? ""))
                }
            }
            let nameTokens = FamilyIdentityText.tokens(person.name)
            let suffix = nameTokens.last(where: { suffixes.contains($0) })
            let given = Set(nameTokens.filter { !suffixes.contains($0) && !surnameSet.contains($0) })
            identityKeySet.formUnion(given); identityKeySet.formUnion(surnameSet)
            if let suffix { identityKeySet.insert(suffix) }
            givenTokens.append(given.sorted()); surnameTokens2.append(surnameSet.sorted()); suffixTokens.append(suffix)
            lifeYears.append(GedcomFamilyGraph.lifeYearsLabel(birth: person.birthDate, death: person.deathDate) ?? "")
        }
        let identityKeys = identityKeySet.sorted()
        var keyPosition: [String: Int32] = [:]
        keyPosition.reserveCapacity(identityKeys.count)
        for (i, key) in identityKeys.enumerated() { keyPosition[key] = Int32(i) }
        var givenStart: [Int32] = [0], givenIDs: [Int32] = []
        var surnameTokenStart: [Int32] = [0], surnameTokenIDs: [Int32] = []
        var suffixIDs: [Int32] = []
        givenStart.reserveCapacity(ids.count + 1); surnameTokenStart.reserveCapacity(ids.count + 1)
        suffixIDs.reserveCapacity(ids.count)
        for i in 0..<ids.count {
            // Sorted by string above; positions in a sorted key table
            // are ascending in the same order.
            givenIDs.append(contentsOf: givenTokens[i].map { keyPosition[$0]! })
            givenStart.append(Int32(givenIDs.count))
            surnameTokenIDs.append(contentsOf: surnameTokens2[i].map { keyPosition[$0]! })
            surnameTokenStart.append(Int32(surnameTokenIDs.count))
            suffixIDs.append(suffixTokens[i].map { keyPosition[$0]! } ?? -1)
        }
            return GedcomFamilyGraph.TreeIndex(
                ids: ids,
                nameRank: nameRank,
                parentStart: parentStart,
                parents: parents,
                motherOffset: motherOffset,
                childStart: childStart,
                children: children,
                spouseStart: spouseStart,
                spouses: spouses,
                tokens: built_tokens,
                likeTokens: likeTokens,
                surnames: built_surnames,
                givenNames: givenNames,
                familySearchIDs: familySearchIDs,
                recordStart: recordStart,
                recordTokenStart: recordTokenStart,
                recordTokenIDs: recordTokenIDs,
                recordLikeIDs: recordLikeIDs,
                marriedStart: marriedStart,
                marriedIDs: marriedIDs,
                surnameStart: surnameStart,
                surnameIDs: surnameIDs,
                sidebarOrder: sidebarOrder,
                sidebarHaystack: sidebarHaystack,
                sidebarStart: sidebarStart,
                identityKeys: identityKeys,
                givenStart: givenStart,
                givenIDs: givenIDs,
                surnameTokenStart: surnameTokenStart,
                surnameTokenIDs: surnameTokenIDs,
                suffixIDs: suffixIDs,
                lifeYears: lifeYears)
    }

    // MARK: Pins

    private func assertIdentical(_ graph: GedcomFamilyGraph, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let legacy = Self.legacyBuild(graph: graph)
        let current = GedcomFamilyGraph.TreeIndex(graph: graph)
        XCTAssertEqual(current, legacy, "\(label): the rebuilt index differs from the frozen pre-split build", file: file, line: line)
        XCTAssertEqual(current.count, graph.people.count, file: file, line: line)
    }

    func testKinshipFixtureBuildsTheSameIndex() {
        assertIdentical(GedcomFamilyGraph(gedcomText: GedcomKinshipPathTests.tree), "kinship")
    }

    func testEdgeCaseTreeBuildsTheSameIndex() {
        let graph = GedcomFamilyGraph(gedcomText: Self.edgeTree)
        assertIdentical(graph, "edge")
        // Spot checks that the frozen builder is itself sane on this tree.
        let index = graph.index
        XCTAssertEqual(index.familySearchIDs.postings(for: "GVQV-NW3").count, 2, "duplicate FSIDs both posted")
        XCTAssertEqual(index.lifeYears[Int(index.ordinal(of: "@I3@")!)], GedcomFamilyGraph.lifeYearsLabel(birth: "ABT 1930", death: "2001") ?? "")
        XCTAssertEqual(index.lifeYears[Int(index.ordinal(of: "@I9@")!)], "")
    }

    func testFiveThousandPersonPedigreeBuildsTheSameIndexAndRoundTrips() throws {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 5_000))
        assertIdentical(graph, "5k")
        let decoded = try GedcomCompiledTree.decode(GedcomCompiledTree.encode(graph))
        XCTAssertEqual(decoded.index, graph.index, "the artifact carries the same index")
    }

    func testHundredThousandPersonPedigreeBuildsTheSameIndex() {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        var current: GedcomFamilyGraph.TreeIndex?
        let t0 = DispatchTime.now().uptimeNanoseconds
        current = GedcomFamilyGraph.TreeIndex(graph: graph)
        let build = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let t1 = DispatchTime.now().uptimeNanoseconds
        let legacy = Self.legacyBuild(graph: graph)
        let legacyBuild = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6
        print("TREEINDEX 100k build: current \(build) ms, frozen pre-split \(legacyBuild) ms")
        XCTAssertEqual(current, legacy, "100k: the rebuilt index differs from the frozen pre-split build")
    }
}
