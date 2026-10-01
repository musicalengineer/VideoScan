// TreeLineStatisticsTests.swift
// GH #214 / #200 / #218 (Rick approved 2026-10-01): statistics over one or
// two ancestor lines with their coverage, and relationship NAMES from the
// lowest common ancestor — on SYNTHETIC trees only (public repo; every name
// here is invented).
//
// The stats tree: Alan (side 0) married Beth (side 1). Their lines meet at
// Old Shared, who fathered Alan's grandfather Ed by Sal and Beth's father
// Hank by Joy — so Old Shared is on BOTH sides (counted once in the union)
// and Alan and Beth are half-first cousins once removed.
//
//   side 0 (Alan): Carl (Cork, Ireland 1930–1999), Dora (Leeds, England
//     1932–2020), Ed (Paris, France 1900–ABT 1960: too vague), Fay (no
//     place, 1902–1999), Gil (Boston, Massachusetts 1890–2015: implausible
//     124), Hope (nothing recorded), Old Shared (Concord, Massachusetts
//     1870–1940), Sal (Dublin, Ireland 1860)
//   side 1 (Beth): Hank (Portland, Maine 1931–2001), Ida (Glasgow,
//     Scotland 1933), Old Shared, Joy (Toronto, Ontario, Canada 1880–1940)

import Foundation
import Testing
@testable import VideoScanCore

/// Tiny GEDCOM writer for the fixtures. Shared with the scale suite.
enum SyntheticGedcom {
    struct Person {
        let id: String, name: String, sex: String
        var birth: String? = nil, place: String? = nil, death: String? = nil
    }
    struct Family {
        let id: String
        var husband: String? = nil, wife: String? = nil
        var children: [String] = []
    }
    static func text(_ people: [Person], _ families: [Family]) -> String {
        var out = ["0 HEAD"]
        for p in people {
            out.append("0 \(p.id) INDI")
            out.append("1 NAME \(p.name)")
            out.append("1 SEX \(p.sex)")
            if p.birth != nil || p.place != nil {
                out.append("1 BIRT")
                if let b = p.birth { out.append("2 DATE \(b)") }
                if let pl = p.place { out.append("2 PLAC \(pl)") }
            }
            if let d = p.death { out.append("1 DEAT"); out.append("2 DATE \(d)") }
            for f in families where f.children.contains(p.id) { out.append("1 FAMC \(f.id)") }
            for f in families where f.husband == p.id || f.wife == p.id { out.append("1 FAMS \(f.id)") }
        }
        for f in families {
            out.append("0 \(f.id) FAM")
            if let h = f.husband { out.append("1 HUSB \(h)") }
            if let w = f.wife { out.append("1 WIFE \(w)") }
            for c in f.children { out.append("1 CHIL \(c)") }
        }
        out.append("0 TRLR")
        return out.joined(separator: "\n")
    }
}

enum StatsTree {
    typealias P = SyntheticGedcom.Person
    typealias F = SyntheticGedcom.Family
    static let gedcom = SyntheticGedcom.text([
        P(id: "@A0@", name: "Alan /Test/", sex: "M", birth: "1959", place: "Boston, Suffolk, Massachusetts, United States"),
        P(id: "@B0@", name: "Beth /Sample/", sex: "F", birth: "1961", place: "Hartford, Connecticut, United States"),
        P(id: "@A1@", name: "Carl /Test/", sex: "M", birth: "1930", place: "Cork, Ireland", death: "1999"),
        P(id: "@A2@", name: "Dora /Hill/", sex: "F", birth: "1932", place: "Leeds, Yorkshire, England", death: "2020"),
        P(id: "@A3@", name: "Ed /Test/", sex: "M", birth: "1900", place: "Paris, France", death: "ABT 1960"),
        P(id: "@A4@", name: "Fay /Moss/", sex: "F", birth: "1902", death: "1999"),
        P(id: "@A5@", name: "Gil /Hill/", sex: "M", birth: "1890", place: "Boston, Massachusetts", death: "2015"),
        P(id: "@A6@", name: "Hope /Vale/", sex: "F"),
        P(id: "@S1@", name: "Old /Shared/", sex: "M", birth: "1870", place: "Concord, Middlesex, Massachusetts, United States", death: "1940"),
        P(id: "@S2@", name: "Sal /Quill/", sex: "F", birth: "1860", place: "Dublin, Ireland"),
        P(id: "@B1@", name: "Hank /Sample/", sex: "M", birth: "1931", place: "Portland, Maine", death: "2001"),
        P(id: "@B2@", name: "Ida /Reed/", sex: "F", birth: "1933", place: "Glasgow, Scotland"),
        P(id: "@S3@", name: "Joy /Lark/", sex: "F", birth: "1880", place: "Toronto, Ontario, Canada", death: "1940"),
    ], [
        F(id: "@FAB@", husband: "@A0@", wife: "@B0@"),
        F(id: "@FA1@", husband: "@A1@", wife: "@A2@", children: ["@A0@"]),
        F(id: "@FA2@", husband: "@A3@", wife: "@A4@", children: ["@A1@"]),
        F(id: "@FA3@", husband: "@A5@", wife: "@A6@", children: ["@A2@"]),
        F(id: "@FA4@", husband: "@S1@", wife: "@S2@", children: ["@A3@"]),
        F(id: "@FB1@", husband: "@B1@", wife: "@B2@", children: ["@B0@"]),
        F(id: "@FB2@", husband: "@S1@", wife: "@S3@", children: ["@B1@"]),
    ])
    static var graph: GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: gedcom) }
}

@Suite("TreeLineStatistics")
struct TreeLineStatisticsTests {
    typealias T = TreeLineStatistics
    let graph = StatsTree.graph

    private func both() throws -> T.Population {
        try #require(T.ancestors(of: ["@A0@", "@B0@"], in: graph))
    }

    @Test func populationCountsEachPersonOnceAndReportsTheOverlap() throws {
        let pop = try both()
        #expect(pop.members.count == 11)
        #expect(pop.count(onSide: 0) == 8)
        #expect(pop.count(onSide: 1) == 4)
        #expect(pop.sharedCount == 1)
        let shared = try #require(pop.members.first { $0.id == "@S1@" })
        #expect(shared.generations == [3, 2])
        #expect(!pop.members.contains { $0.id == "@A0@" || $0.id == "@B0@" }, "a start is not their own ancestor")
    }

    @Test func birthplacesByRegionAndCountryWithCoverage() throws {
        let pop = try both()
        let r = T.birthplaces(pop, places: [.regions([.newEngland]), .regions([.england]),
                                            .regions([.ireland]), .country("France")])
        #expect(r.considered == 11)
        #expect(r.placed == 9, "Fay and Hope have no birthplace")
        #expect(r.unplaced == 2)
        #expect(r.consideredPerSide == [8, 4])
        #expect(r.placedPerSide == [6, 4])
        #expect(r.shared == 1)
        #expect(r.rows.map(\.total) == [3, 1, 2, 1])
        #expect(r.rows[0].perSide == [2, 2], "Old Shared counts on both sides, once in the total")
        #expect(r.rows[1].perSide == [1, 0])
        #expect(r.rows[2].perSide == [2, 0])
        #expect(r.rows[3].perSide == [1, 0])
        #expect(r.elsewhere == 2, "Scotland and Canada are placed but not asked about")
    }

    @Test func newEnglandIsNeverOldEngland() throws {
        let pop = try both()
        let r = T.birthplaces(pop, places: [.regions([.england])])
        #expect(r.rows[0].total == 1, "only Leeds; the Massachusetts births are not England")
    }

    @Test func ageAtDeathStatesWhatWasLeftOutAndWhy() throws {
        let r = try #require(T.ageAtDeath(try both()))
        #expect(r.considered == 11)
        #expect(r.usable == 6)
        #expect(r.tooVague == 1, "Ed's ABT death brackets his age more widely than two years")
        #expect(r.implausible == 1, "Gil's 124 years is set aside, not averaged in")
        #expect(r.missingDates == 3)
        #expect(abs(r.mean - 451.0 / 6) < 0.001)
        #expect(r.median == 69.5)
        #expect(r.oldest.map(\.id) == ["@A4@"])
        #expect(r.perSide[0].usable == 4 && abs(r.perSide[0].mean - 80.5) < 0.001)
        #expect(r.perSide[1].usable == 3 && abs(r.perSide[1].mean - 198.5 / 3) < 0.001)
    }

    @Test func deepestLinePerSideWithTheLineShown() throws {
        let lines = T.deepestLines(try both())
        let alan = try #require(lines[0]), beth = try #require(lines[1])
        #expect(alan.generations == 3)
        #expect(alan.atDepth == 2)
        #expect(alan.ancestor.id == "@S2@", "earliest-born at the deepest generation")
        #expect(alan.line == ["@S2@", "@A3@", "@A1@", "@A0@"])
        #expect(beth.generations == 2)
        #expect(beth.ancestor.id == "@S1@")
        #expect(beth.line == ["@S1@", "@B1@", "@B0@"])
    }

    @Test func earliestAncestorOverTheUnionAndEachSide() throws {
        let pop = try both()
        let all = T.earliest(pop)
        #expect(all.year == 1860 && all.people.map(\.id) == ["@S2@"])
        #expect(all.dated == 10 && all.considered == 11)
        #expect(T.earliest(pop, side: 1).people.map(\.id) == ["@S1@"])
    }

    @Test func oneSideOnly() throws {
        let pop = try #require(T.ancestors(of: ["@B0@"], in: graph))
        #expect(pop.members.count == 4)
        #expect(pop.sharedCount == 0)
        let r = T.birthplaces(pop, places: [.regions([.newEngland])])
        #expect(r.rows[0].total == 2)
    }

    @Test func unknownOrHiddenStartIsNil() {
        #expect(T.ancestors(of: ["@NOPE@"], in: graph) == nil)
        #expect(T.ancestors(of: [], in: graph) == nil)
    }

    @Test func nobodyWithDatesIsAnHonestZeroNotNil() throws {
        let g = GedcomFamilyGraph(gedcomText: SyntheticGedcom.text([
            .init(id: "@K@", name: "Kid /X/", sex: "M"), .init(id: "@M@", name: "Mum /X/", sex: "F"),
        ], [.init(id: "@F@", wife: "@M@", children: ["@K@"])]))
        let pop = try #require(T.ancestors(of: ["@K@"], in: g))
        let r = try #require(T.ageAtDeath(pop))
        #expect(r.usable == 0 && r.considered == 1)
        #expect(T.earliest(pop).year == nil)
    }

    /// The SAME numbers as the walk's decorations: passing decorations.json's
    /// per-person facts changes nothing.
    @Test func decorationsAndGraphGiveTheSameFigures() throws {
        let walk = try TreeWalk.walk(graph, options: .init(starts: ["@A0@", "@B0@"]))
        var decorations: [String: TreeWalk.Decoration] = [:]
        for (o, id) in walk.ids.enumerated() where walk.visible[o] { decorations[id] = walk.decorations[o] }
        let fromGraph = try both()
        let fromWalk = try #require(T.ancestors(of: ["@A0@", "@B0@"], in: graph, decorations: decorations))
        #expect(fromGraph.members == fromWalk.members)
        // …and the generations equal the walk's own.
        for m in fromWalk.members {
            #expect(m.generations[0] == decorations[m.id]?.generationFromFirst)
            #expect(m.generations[1] == decorations[m.id]?.generationFromSecond)
        }
    }
}

// MARK: - Relationship names (#218)

enum KinTree {
    typealias P = SyntheticGedcom.Person
    typealias F = SyntheticGedcom.Family
    static let gedcom = SyntheticGedcom.text([
        P(id: "@G1@", name: "Gramps /Root/", sex: "M"), P(id: "@G2@", name: "Gran /Root/", sex: "F"),
        P(id: "@P1@", name: "Paul /Root/", sex: "M"), P(id: "@P2@", name: "Pia /Root/", sex: "F"),
        P(id: "@S1X@", name: "Sue /Wed/", sex: "F"), P(id: "@S2X@", name: "Stan /Other/", sex: "M"),
        P(id: "@C1@", name: "Cal /Root/", sex: "M"), P(id: "@C2@", name: "Cora /Other/", sex: "F"),
        P(id: "@SPC2@", name: "Seth /Spouse/", sex: "M"), P(id: "@D2@", name: "Dan /Spouse/", sex: "M"),
        P(id: "@SP1@", name: "Sam /Wed/", sex: "M"), P(id: "@SP2@", name: "Sara /Wed/", sex: "F"),
        P(id: "@SIS@", name: "Sis /Wed/", sex: "F"), P(id: "@N@", name: "Nell /Niece/", sex: "F"),
        P(id: "@H@", name: "Hal /Half/", sex: "M"), P(id: "@W1@", name: "Wendy /One/", sex: "F"),
        P(id: "@W2@", name: "Willa /Two/", sex: "F"),
        P(id: "@X1@", name: "Xavier /Half/", sex: "M"), P(id: "@X2@", name: "Xena /Half/", sex: "F"),
        P(id: "@Y1@", name: "Yara /Half/", sex: "F"), P(id: "@Y2@", name: "Yuri /Half/", sex: "M"),
        P(id: "@U@", name: "Una /Solo/", sex: "F"), P(id: "@Z1@", name: "Zed /Solo/", sex: "M"),
        P(id: "@Z2@", name: "Zack /Solo/", sex: "M"), P(id: "@V1@", name: "Vic /Solo/", sex: "M"),
        P(id: "@V2@", name: "Val /Solo/", sex: "F"),
        P(id: "@DA@", name: "Dave /Dbl/", sex: "M"), P(id: "@DB@", name: "Deb /Dbl/", sex: "F"),
        P(id: "@DC@", name: "Doug /Twin/", sex: "M"), P(id: "@DD@", name: "Dot /Twin/", sex: "F"),
        P(id: "@E1@", name: "Eli /Dbl/", sex: "M"), P(id: "@E2@", name: "Evan /Dbl/", sex: "M"),
        P(id: "@F1@", name: "Faye /Twin/", sex: "F"), P(id: "@F2@", name: "Fern /Twin/", sex: "F"),
        P(id: "@Q1@", name: "Quinn /Dbl/", sex: "M"), P(id: "@Q2@", name: "Quill /Dbl/", sex: "F"),
        P(id: "@LONE@", name: "Lone /Stranger/", sex: "M"),
    ], [
        F(id: "@K1@", husband: "@G1@", wife: "@G2@", children: ["@P1@", "@P2@"]),
        F(id: "@K2@", husband: "@P1@", wife: "@S1X@", children: ["@C1@"]),
        F(id: "@K3@", husband: "@S2X@", wife: "@P2@", children: ["@C2@"]),
        F(id: "@K4@", husband: "@SPC2@", wife: "@C2@", children: ["@D2@"]),
        F(id: "@K5@", husband: "@SP1@", wife: "@SP2@", children: ["@S1X@", "@SIS@"]),
        F(id: "@K6@", wife: "@SIS@", children: ["@N@"]),
        F(id: "@K7@", husband: "@H@", wife: "@W1@", children: ["@X1@"]),
        F(id: "@K8@", husband: "@H@", wife: "@W2@", children: ["@X2@"]),
        F(id: "@K9@", husband: "@X1@", children: ["@Y1@"]),
        F(id: "@K10@", wife: "@X2@", children: ["@Y2@"]),
        F(id: "@K11@", wife: "@U@", children: ["@Z1@"]),
        F(id: "@K12@", wife: "@U@", children: ["@Z2@"]),
        F(id: "@K13@", husband: "@Z1@", children: ["@V1@"]),
        F(id: "@K14@", husband: "@Z2@", children: ["@V2@"]),
        F(id: "@K15@", husband: "@DA@", wife: "@DB@", children: ["@E1@", "@E2@"]),
        F(id: "@K16@", husband: "@DC@", wife: "@DD@", children: ["@F1@", "@F2@"]),
        F(id: "@K17@", husband: "@E1@", wife: "@F1@", children: ["@Q1@"]),
        F(id: "@K18@", husband: "@E2@", wife: "@F2@", children: ["@Q2@"]),
    ])
    static var graph: GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: gedcom) }
}

@Suite("GedcomRelationshipName")
struct GedcomRelationshipNameTests {
    typealias G = GedcomFamilyGraph
    let graph = KinTree.graph

    private func name(_ b: String, _ a: String) -> String? { graph.bloodRelation(of: b, to: a)?.name }

    @Test func theWordsForDepths() {
        #expect(G.relationshipName(depthA: 3, depthB: 2, sexOfB: "M") == "first cousin once removed")
        #expect(G.relationshipName(depthA: 4, depthB: 4, sexOfB: "F") == "third cousin")
        #expect(G.relationshipName(depthA: 5, depthB: 3, sexOfB: "") == "second cousin twice removed")
        #expect(G.relationshipName(depthA: 3, depthB: 7, sexOfB: "") == "second cousin four times removed")
        #expect(G.relationshipName(depthA: 14, depthB: 14, sexOfB: "") == "13th cousin")
        #expect(G.relationshipName(depthA: 2, depthB: 14, sexOfB: "") == "first cousin 12 times removed")
        #expect(G.relationshipName(depthA: 1, depthB: 1, sexOfB: "F", half: true) == "half-sister")
        #expect(G.relationshipName(depthA: 2, depthB: 1, sexOfB: "F") == "aunt")
        #expect(G.relationshipName(depthA: 4, depthB: 1, sexOfB: "M") == "great-great-uncle")
        #expect(G.relationshipName(depthA: 5, depthB: 1, sexOfB: "M") == "3rd-great-uncle")
        #expect(G.relationshipName(depthA: 1, depthB: 3, sexOfB: "") == "great-niece or nephew")
        #expect(G.relationshipName(depthA: 0, depthB: 3, sexOfB: "M") == nil, "a direct line is not collateral")
    }

    @Test func cousinsAuntsNiecesAndDirectLines() {
        #expect(name("@C2@", "@C1@") == "first cousin")
        #expect(name("@D2@", "@C1@") == "first cousin once removed")
        #expect(name("@P1@", "@C2@") == "uncle")
        #expect(name("@C2@", "@P1@") == "niece")
        #expect(name("@D2@", "@P1@") == "great-nephew")
        #expect(name("@G1@", "@D2@") == "great-grandfather")
        #expect(name("@C1@", "@P1@") == "son")
        #expect(name("@P2@", "@P1@") == "sister")
    }

    @Test func halfBloodOnlyWhenBothPartnersAreRecordedAndDiffer() throws {
        let r = try #require(graph.bloodRelation(of: "@Y2@", to: "@Y1@"))
        #expect(r.name == "half-first cousin")
        #expect(r.half?.ancestor.id == "@H@")
        #expect(r.half?.partnerOnA.id == "@W1@")
        #expect(r.half?.partnerOnB.id == "@W2@")
        #expect(name("@X2@", "@Y1@") == "half-aunt")
        #expect(name("@X2@", "@X1@") == "half-sister")
        // Una's two lines record no father at all: the tree doesn't say half.
        #expect(name("@V2@", "@V1@") == "first cousin")
        #expect(graph.bloodRelation(of: "@V2@", to: "@V1@")?.half == nil)
    }

    @Test func pedigreeCollapseNamesTheNearestAndCountsTheLines() throws {
        let r = try #require(graph.bloodRelation(of: "@Q2@", to: "@Q1@"))
        #expect(r.name == "first cousin")
        #expect(r.separateLines == 2, "double first cousins: two grandparent couples")
    }

    @Test func inLawOnlyWhenThereIsNoBlood() throws {
        #expect(graph.bloodRelation(of: "@N@", to: "@P1@") == nil)
        let viaWife = try #require(graph.relationThroughMarriage(of: "@N@", to: "@P1@"))
        #expect(viaWife.via == .spouseOfA)
        #expect(viaWife.spouse.id == "@S1X@")
        #expect(viaWife.relation.name == "niece")
        let married = try #require(graph.relationThroughMarriage(of: "@SPC2@", to: "@P1@"))
        #expect(married.via == .spouseOfB)
        #expect(married.spouse.id == "@C2@")
        #expect(married.relation.name == "niece")
    }

    @Test func strangersAndUnknownsAreNil() {
        #expect(graph.bloodRelation(of: "@LONE@", to: "@C1@") == nil)
        #expect(graph.relationThroughMarriage(of: "@LONE@", to: "@C1@") == nil)
        #expect(graph.bloodRelation(of: "@NOPE@", to: "@C1@") == nil)
        #expect(graph.bloodRelation(of: "@C1@", to: "@C1@") == nil)
    }

    @Test func spousesWhoAreAlsoCousinsAreNamedByBlood() throws {
        // Alan and Beth (the stats tree) are married AND descend from Old
        // Shared by different wives: blood wins over the marriage.
        let g = StatsTree.graph
        let r = try #require(g.bloodRelation(of: "@B0@", to: "@A0@"))
        #expect(r.name == "half-first cousin once removed")
        #expect(r.half?.ancestor.id == "@S1@")
    }
}

// MARK: - Scale (100k synthetic people)

@Suite("TreeLineStatisticsScale")
struct TreeLineStatisticsScaleTests {
    /// Measured 2026-10-01, M4 Max, Debug, load 25 on 16 cores: stats
    /// 0.43 s over 17,836 ancestors of two starts, kinship (two LCA
    /// searches) 0.21 s. Budget ≈ 4× the slower; load-aware like the other
    /// scale sensors.
    static let budget: Duration = .seconds(2)

    @Test func hundredThousandPeopleStatsAndKinshipWithinBudget() throws {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        _ = graph.index   // prebuilt in production
        let root = try #require(graph.rootPersonID)
        let other = try #require(graph.relatives(.siblings, of: graph.people[root]!).first?.id
                                 ?? graph.people.keys.sorted().dropFirst(7).first)
        let clock = ContinuousClock()
        let start = clock.now
        let pop = try #require(TreeLineStatistics.ancestors(of: [root, other], in: graph))
        let places = TreeLineStatistics.birthplaces(pop, places: [.regions([.newEngland]), .regions([.england]), .country("France")])
        let ages = TreeLineStatistics.ageAtDeath(pop)
        let deepest = TreeLineStatistics.deepestLines(pop)
        let earliest = TreeLineStatistics.earliest(pop)
        let statsElapsed = clock.now - start
        let kinStart = clock.now
        let relation = graph.bloodRelation(of: other, to: root)
        let deepPair = pop.members.filter { $0.generations[0] == 6 }.prefix(2).map(\.id)
        let deep = deepPair.count == 2 ? graph.bloodRelation(of: deepPair[1], to: deepPair[0]) : nil
        let kinElapsed = clock.now - kinStart
        print("[line-stats-scale] 100k: stats \(statsElapsed) over \(pop.members.count) ancestors; kinship \(kinElapsed) (\(relation?.name ?? "-"), \(deep?.name ?? "-")) (\(TimingBudget.loadDescription()))")
        let ceiling = TimingBudget.loadAwareDebugCeiling(Self.budget)
        #expect(statsElapsed < ceiling, "100k line stats took \(statsElapsed), ceiling \(ceiling)")
        #expect(kinElapsed < ceiling, "100k kinship took \(kinElapsed), ceiling \(ceiling)")
        #expect(pop.members.count > 10_000)
        #expect(places.considered == pop.members.count)
        #expect(ages != nil)
        #expect(deepest[0] != nil)
        #expect(earliest.year != nil)
        #expect(relation != nil)
    }
}
