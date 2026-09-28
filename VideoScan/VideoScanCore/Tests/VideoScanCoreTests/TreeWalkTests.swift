// TreeWalkTests.swift
// The Family Tree Walk (2026-09-27), core half. Five dimensions:
//   Logic     — line attribution incl. pedigree collapse = both; generation
//               = shortest path; distinct path counts; Tarjan cycles (self,
//               3-loop, two disjoint loops); every check positive AND
//               negative; region table; depth limit; determinism; dates.
//   Scale     — TreeWalkScaleTests: 100k synthetic, off-main, budgeted.
//   Isolation — no start people → honest error; missing dates → coverage,
//               no crash; hidden records excluded; absent / poisoned /
//               stale decorations.json → rebuild.
//   Sensor    — TreeWalkRealTreeReport (opt-in, prints, pins nothing) and
//               the log-cadence sensor below.

import Foundation
import Testing
@testable import VideoScanCore

// MARK: - Fixture builder

/// Tiny GEDCOM writer so each test states its family in a few lines.
private struct Fam {
    var people: [(id: String, name: String, sex: String, birth: String?, death: String?, place: String?)] = []
    var families: [(id: String, husband: String?, wife: String?, children: [String])] = []
    var roots: [String] = []

    mutating func person(_ id: String, _ name: String, _ sex: String = "M",
                         born: String? = nil, died: String? = nil, place: String? = nil) {
        people.append((id, name, sex, born, died, place))
    }
    mutating func family(_ id: String, husband: String?, wife: String?, children: [String]) {
        families.append((id, husband, wife, children))
    }
    var graph: GedcomFamilyGraph {
        var out = ["0 HEAD"]
        if roots.count > 1 { out.append("1 _VS_MERGED Y") }
        for r in roots { out.append("1 _VS_ROOT \(r)") }
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
        return GedcomFamilyGraph(gedcomText: out.joined(separator: "\n"))
    }
}

/// Rick (@R) and Donna (@D) married. Rick's parents @RF/@RM, Donna's
/// @DF/@DM. @S (Shared) is the father of both @RM and @DF — pedigree
/// collapse ACROSS the marriage, so @S and his wife @SW are on both lines.
/// @X is Rick's mother's ancestor reached two ways (a diamond).
private func marriedWithCollapse() -> GedcomFamilyGraph {
    var f = Fam()
    f.roots = ["@R@", "@D@"]
    f.person("@R@", "Richard Harding /Breen/ Jr", born: "4 MAR 1959", place: "Boston, Suffolk, Massachusetts, United States")
    f.person("@D@", "Donna /Hudson/", "F", born: "1959")
    f.person("@RF@", "Richard /Breen/ Sr", born: "21 FEB 1929", died: "25 JUN 2008")
    f.person("@RM@", "Eileen /Latta/", "F", born: "31 AUG 1930", died: "3 MAR 2023")
    f.person("@DF@", "Richard C /Hudson/", born: "1930")
    f.person("@DM@", "Elaine /Bowser/", "F", born: "1932")
    f.person("@S@", "Shared /Ancestor/", born: "1900", died: "1970", place: "Chelsea, Mass.")
    f.person("@SW@", "Shared /Wife/", "F", born: "1902")
    f.person("@X@", "Diamond /Top/", born: "1850", place: "Cork, Ireland")
    f.family("@F0@", husband: "@R@", wife: "@D@", children: [])
    f.family("@F1@", husband: "@RF@", wife: "@RM@", children: ["@R@"])
    f.family("@F2@", husband: "@DF@", wife: "@DM@", children: ["@D@"])
    f.family("@F3@", husband: "@S@", wife: "@SW@", children: ["@RM@", "@DF@"])
    // Diamond: @X is father of @RF and of @SW → reaches Rick via RF and via RM→SW.
    f.family("@F4@", husband: "@X@", wife: nil, children: ["@RF@", "@SW@"])
    return f.graph
}

private func walk(_ g: GedcomFamilyGraph, _ starts: [String], depth: Int? = nil) throws -> TreeWalk.Result {
    try TreeWalk.walk(g, options: .init(starts: starts, maxGenerations: depth), now: Date(timeIntervalSince1970: 0))
}

// MARK: - Logic

@Suite("TreeWalkLogic")
struct TreeWalkLogicTests {

    @Test func lineAttributionIncludingCollapseAcrossTheMarriage() throws {
        let r = try walk(marriedWithCollapse(), ["@R@", "@D@"])
        func line(_ id: String) -> TreeWalk.Line? { r.decoration(for: id)?.line }
        #expect(line("@R@") == .first)
        #expect(line("@D@") == .second)
        #expect(line("@RF@") == .first)
        #expect(line("@DM@") == .second)
        #expect(line("@S@") == .both, "Rick's grandfather AND Donna's grandfather")
        #expect(line("@SW@") == .both)
        #expect(line("@X@") == .both, "via Shared Wife, whose line reaches Donna too")
        #expect(r.summary.byLine[.both] == 3)
    }

    @Test func generationIsTheShortestPathAndPathsCountTheDiamond() throws {
        let r = try walk(marriedWithCollapse(), ["@R@", "@D@"])
        let x = try #require(r.decoration(for: "@X@"))
        // Rick ← RF ← X (2) and Rick ← RM ← SW ← X (3): shortest is 2.
        #expect(x.generationFromFirst == 2)
        #expect(x.pathsFromFirst == 2, "two distinct lines from Rick up to X")
        // Donna ← DF ← S … X is SW's father: Donna ← DF ← SW? No — DF's
        // parents are S and SW, so Donna ← DF ← SW ← X = 3.
        #expect(x.generationFromSecond == 3)
        #expect(x.pathsFromSecond == 1)
        #expect(r.decoration(for: "@S@")?.generationFromFirst == 2)
        #expect(r.decoration(for: "@S@")?.relationLabel(generations: 2) == "grandfather")
        #expect(x.relationLabel(generations: x.generationFromFirst) == "grandfather")
        #expect(r.decoration(for: "@R@")?.generationFromFirst == 0)
        #expect(r.decoration(for: "@R@")?.generationFromSecond == nil, "a spouse is not an ancestor")
    }

    @Test func distinctCountsDoNotDoubleCountTheDiamond() throws {
        let r = try walk(marriedWithCollapse(), ["@R@", "@D@"])
        // Rick's ancestors: RF, RM, S, SW, X = 5 (X reached twice, counted once).
        #expect(r.decoration(for: "@R@")?.ancestorCount == TreeWalk.Count(value: 5, isEstimate: false))
        // X's descendants: RF, SW, RM, DF, R, D = 6 distinct.
        #expect(r.decoration(for: "@X@")?.descendantCount == TreeWalk.Count(value: 6, isEstimate: false))
        // All of Rick's 5 ancestors have a birth year.
        #expect(r.decoration(for: "@R@")?.documentedAncestorFraction == 1.0)
        // A non-start person's small set is exact through the sketch too.
        #expect(r.decoration(for: "@RM@")?.ancestorCount == TreeWalk.Count(value: 3, isEstimate: false))
        #expect(r.decoration(for: "@X@")?.documentedAncestorFraction == nil, "no ancestors")
    }

    @Test func localFactsAndAgeAtDeathPrecision() throws {
        let r = try walk(marriedWithCollapse(), ["@R@", "@D@"])
        let dad = try #require(r.decoration(for: "@RF@"))
        #expect(dad.ageAtDeath == AgeAtDeath(minYears: 79, maxYears: 79), "21 Feb 1929 – 25 Jun 2008, day-precise")
        #expect(dad.birthPrecision == .day)
        let shared = try #require(r.decoration(for: "@S@"))
        #expect(shared.ageAtDeath == AgeAtDeath(minYears: 69, maxYears: 70), "years only: 69 or 70")
        #expect(shared.birthRegion == .newEngland)
        #expect(shared.childCount == 2)
        #expect(r.decoration(for: "@X@")?.birthRegion == .ireland)
        #expect(r.decoration(for: "@R@")?.birthRegion == .newEngland)
        #expect(r.decoration(for: "@D@")?.birthRegion == .unknown)
    }

    @Test func depthLimitStopsTheWalkAndTheLines() throws {
        let r = try walk(marriedWithCollapse(), ["@R@", "@D@"], depth: 1)
        #expect(r.layers.count == 2)
        #expect(Set(r.layers[1].map { r.ids[Int($0.ordinal)] }) == ["@RF@", "@RM@", "@DF@", "@DM@"])
        #expect(r.decoration(for: "@S@")?.line == TreeWalk.Line.none)
        #expect(r.decoration(for: "@S@")?.generationFromFirst == nil)
        #expect(r.summary.peopleWalked == 6)
    }

    @Test func determinism() throws {
        let g = marriedWithCollapse()
        let a = try walk(g, ["@R@", "@D@"]), b = try walk(g, ["@R@", "@D@"])
        #expect(a.decorations == b.decorations)
        #expect(a.checks == b.checks)
        #expect(a.layers == b.layers)
        #expect(a.sourceKey == b.sourceKey)
        // The stored people and checks are byte-identical (only the
        // timings and generatedAt differ run to run).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(TreeWalkStored(a).people) == encoder.encode(TreeWalkStored(b).people))
        #expect(try encoder.encode(a.checks) == encoder.encode(b.checks))
    }

    @Test func layersAreGenerationOrderedAndCarryTheFanSlots() throws {
        let r = try walk(marriedWithCollapse(), ["@R@", "@D@"])
        for (g, layer) in r.layers.enumerated() { #expect(layer.allSatisfy { Int($0.generation) == g }) }
        #expect(r.layers[0].map(\.slots) == [2, 2])
        let rf = try #require(r.layers[1].first { r.ids[Int($0.ordinal)] == "@RF@" })
        #expect(r.ids[Int(rf.from)] == "@R@")
        #expect(rf.slot == 0 && rf.slots == 2, "father first")
        #expect(r.visitedCount == 9)
    }
}

// MARK: - Cycles

@Suite("TreeWalkCycles")
struct TreeWalkCycleTests {

    private func loops() -> GedcomFamilyGraph {
        var f = Fam()
        f.person("@R@", "Root /Person/")
        // Self-parent: @P is his own father.
        f.person("@P@", "Self /Parent/")
        // Three-node loop A → B → C → A (each the parent of the next).
        f.person("@A@", "Loop /A/"); f.person("@B@", "Loop /B/"); f.person("@C@", "Loop /C/")
        // A second, disjoint two-node loop hanging off the root's mother.
        f.person("@M@", "Mother /Person/", "F")
        f.person("@Y@", "Loop /Y/"); f.person("@Z@", "Loop /Z/")
        f.person("@TOP@", "Above /Loop/", "F")
        f.family("@F1@", husband: "@P@", wife: "@M@", children: ["@R@"])
        f.family("@F2@", husband: "@P@", wife: nil, children: ["@P@"])          // self-parent
        f.family("@F3@", husband: "@A@", wife: nil, children: ["@B@"])
        f.family("@F4@", husband: "@B@", wife: nil, children: ["@C@"])
        f.family("@F5@", husband: "@C@", wife: nil, children: ["@A@"])
        f.family("@F6@", husband: "@Y@", wife: nil, children: ["@M@", "@Z@"])
        // Y's parents: Z (the loop) and TOP, who sits ABOVE the loop.
        f.family("@F7@", husband: "@Z@", wife: "@TOP@", children: ["@Y@"])
        return f.graph
    }

    @Test func tarjanReportsEveryCycleAndTheWalkTerminates() throws {
        let r = try walk(loops(), ["@R@"])
        let cycles = r.checks.filter { $0.kind == .ancestorCycle }
        #expect(cycles.count == 3)
        let sets = Set(cycles.map { Set($0.personIDs) })
        #expect(sets == [["@P@"], ["@A@", "@B@", "@C@"], ["@Y@", "@Z@"]])
        #expect(cycles.allSatisfy { $0.severity == .warn })
        // The summary counts the loops ON the walk (P, Y/Z); A/B/C is a loop
        // nobody walks into — still a check, counted in the tree total.
        #expect(r.summary.cycleCount == 2)
        #expect(r.summary.treeCycleCount == 3)
        for id in ["@P@", "@A@", "@B@", "@C@", "@Y@", "@Z@"] {
            #expect(r.decoration(for: id)?.inCycle == true, "\(id)")
        }
        #expect(r.decoration(for: "@R@")?.inCycle == false)
    }

    @Test func aCyclePoisonsPathCountsAboveItButNotLineOrGeneration() throws {
        let r = try walk(loops(), ["@R@"])
        let p = try #require(r.decoration(for: "@P@"))
        #expect(p.line == .first)
        #expect(p.generationFromFirst == 1)
        #expect(p.pathsFromFirst?.isNaN == true, "a self-loop has infinitely many paths")
        #expect(r.decoration(for: "@TOP@")?.pathsFromFirst?.isNaN == true, "poison flows up")
        #expect(r.decoration(for: "@TOP@")?.generationFromFirst == 3)   // R ← M ← Y ← TOP
        #expect(r.decoration(for: "@M@")?.pathsFromFirst == 1)
        // A loop nobody walks into is still reported, and not walked.
        #expect(r.decoration(for: "@A@")?.line == TreeWalk.Line.none)
        // The stored form writes no NaN (JSON cannot).
        let data = try TreeWalkStore.encode(TreeWalkStored(r))
        #expect(!String(decoding: data, as: UTF8.self).contains("nan"))
    }

    @Test func cyclesAreDeterministic() throws {
        let a = try walk(loops(), ["@R@"]), b = try walk(loops(), ["@R@"])
        #expect(a.checks == b.checks)
        #expect(a.layers == b.layers)
    }

    @Test func aTenThousandGenerationChainDoesNotOverflowTheStack() throws {
        // Recursive Tarjan would need 10k frames; the iterative one needs none.
        var text = "0 HEAD\n"
        let n = 10_000
        for i in 1...n {
            text += "0 @I\(i)@ INDI\n1 NAME P\(i) /Line/\n1 SEX M\n"
            if i < n { text += "1 FAMC @F\(i)@\n" }
            if i > 1 { text += "1 FAMS @F\(i - 1)@\n" }
        }
        for i in 1..<n { text += "0 @F\(i)@ FAM\n1 HUSB @I\(i + 1)@\n1 CHIL @I\(i)@\n" }
        text += "0 TRLR\n"
        let r = try walk(GedcomFamilyGraph(gedcomText: text), ["@I1@"])
        #expect(r.summary.generationsFromFirst == n - 1)
        #expect(r.summary.cycleCount == 0)
        #expect(r.decoration(for: "@I1@")?.ancestorCount.value == n - 1)
    }
}

// MARK: - Checks (each positive + negative)

@Suite("TreeWalkChecks")
struct TreeWalkCheckTests {

    /// A child with a father and a mother and chosen dates.
    private func family(child: String?, childDied: String? = nil, father: String?, fatherDied: String? = nil,
                        mother: String?, motherDied: String? = nil) throws -> [TreeWalk.Check] {
        var f = Fam()
        f.person("@C@", "Child /Test/", born: child, died: childDied)
        f.person("@F@", "Father /Test/", born: father, died: fatherDied)
        f.person("@M@", "Mother /Test/", "F", born: mother, died: motherDied)
        f.family("@F1@", husband: "@F@", wife: "@M@", children: ["@C@"])
        return try walk(f.graph, ["@C@"]).checks
    }
    private func kinds(_ c: [TreeWalk.Check]) -> Set<TreeWalk.CheckKind> { Set(c.map(\.kind)) }

    @Test func childBornBeforeParentWasTwelve() throws {
        #expect(kinds(try family(child: "1710", father: "1700", mother: "1680")).contains(.childBornBeforeParentAge12))
        #expect(kinds(try family(child: "1700", father: "1710", mother: "1680")).contains(.childBornBeforeParentAge12), "born before the parent")
        #expect(!kinds(try family(child: "1713", father: "1700", mother: "1680")).contains(.childBornBeforeParentAge12))
        // ABT 1700 could be 1698: a child in 1711 might have a 13-year-old father — not proven.
        #expect(!kinds(try family(child: "1711", father: "ABT 1700", mother: "1680")).contains(.childBornBeforeParentAge12))
    }

    @Test func oldParents() throws {
        #expect(kinds(try family(child: "1760", father: "1720", mother: "1700")).contains(.childBornAfterMother55))
        #expect(!kinds(try family(child: "1754", father: "1720", mother: "1700")).contains(.childBornAfterMother55))
        #expect(kinds(try family(child: "1790", father: "1705", mother: "1760")).contains(.childBornAfterFather80))
        #expect(!kinds(try family(child: "1780", father: "1705", mother: "1750")).contains(.childBornAfterFather80))
    }

    @Test func deathBeforeBirthAndAgeOver110() throws {
        #expect(kinds(try family(child: "1800", childDied: "1790", father: nil, mother: nil)).contains(.deathBeforeBirth))
        #expect(!kinds(try family(child: "1800", childDied: "1800", father: nil, mother: nil)).contains(.deathBeforeBirth))
        #expect(kinds(try family(child: "1700", childDied: "1815", father: nil, mother: nil)).contains(.ageOver110))
        #expect(!kinds(try family(child: "1700", childDied: "1809", father: nil, mother: nil)).contains(.ageOver110))
        #expect(!kinds(try family(child: "ABT 1700", childDied: "1811", father: nil, mother: nil)).contains(.ageOver110), "could be 109")
    }

    @Test func bornAfterAParentsDeath() throws {
        #expect(kinds(try family(child: "1692", father: "1650", mother: "1660", motherDied: "1690")).contains(.bornAfterMotherDeath))
        #expect(!kinds(try family(child: "1690", father: "1650", mother: "1660", motherDied: "1690")).contains(.bornAfterMotherDeath))
        #expect(kinds(try family(child: "NOV 1691", father: "1650", fatherDied: "JAN 1691", mother: "1660")).contains(.bornAfterFatherDeath))
        #expect(!kinds(try family(child: "AUG 1691", father: "1650", fatherDied: "JAN 1691", mother: "1660")).contains(.bornAfterFatherDeath), "7 months: posthumous, fine")
        let c = try family(child: "1692", father: "1650", mother: "1660", motherDied: "1690")
        let why = try #require(c.first { $0.kind == .bornAfterMotherDeath })
        #expect(why.personIDs == ["@C@", "@M@"])
        #expect(why.reason.contains("died 1690"))
    }

    @Test func spouseAgeGap() throws {
        func couple(_ a: String, _ b: String) throws -> Set<TreeWalk.CheckKind> {
            var f = Fam()
            f.person("@H@", "Husband /Test/", born: a); f.person("@W@", "Wife /Test/", "F", born: b)
            f.family("@F1@", husband: "@H@", wife: "@W@", children: [])
            return kinds(try walk(f.graph, ["@H@"]).checks)
        }
        #expect(try couple("1700", "1745").contains(.spouseAgeGap))
        #expect(!(try couple("1700", "1738").contains(.spouseAgeGap)))
        #expect(TreeWalk.CheckKind.spouseAgeGap.severity == .info)
    }

    @Test func likelyDuplicateNeedsSameNameSameParentsAndCloseYears() throws {
        func kids(_ a: (String, String), _ b: (String, String)) throws -> Set<TreeWalk.CheckKind> {
            var f = Fam()
            f.person("@F@", "Father /Test/"); f.person("@M@", "Mother /Test/", "F")
            f.person("@A@", a.0, born: a.1); f.person("@B@", b.0, born: b.1)
            f.family("@F1@", husband: "@F@", wife: "@M@", children: ["@A@", "@B@"])
            return kinds(try walk(f.graph, ["@A@"]).checks)
        }
        #expect(try kids(("Mary /O'Connor/", "1904"), ("Mary /O'Connor/", "1905")).contains(.likelyDuplicate))
        #expect(!(try kids(("Mary /O'Connor/", "1904"), ("Mary /O'Connor/", "1912")).contains(.likelyDuplicate)), "a later child given the name")
        #expect(!(try kids(("Mary /O'Connor/", "1904"), ("Ellen /O'Connor/", "1905")).contains(.likelyDuplicate)))
    }

    @Test func aCleanFamilyHasNoChecks() throws {
        #expect(try family(child: "1730", father: "1700", mother: "1705").isEmpty)
    }
}

// MARK: - Regions

@Suite("TreeWalkRegions")
struct TreeWalkRegionTests {
    @Test(arguments: [
        ("Boston, Suffolk, Massachusetts, United States", BirthplaceClassifier.BirthRegion.newEngland),
        ("Chelsea, Mass.", .newEngland),
        ("Lowell, Mass. U.S.A.", .newEngland),
        ("Plymouth, Plymouth Colony", .newEngland),
        ("Plymouth Colony, British Colonial America", .newEngland),
        ("Hartford, CT", .newEngland),
        ("Portland, ME", .newEngland),
        ("Portland, Me.", .newEngland),
        ("Exeter, New Hampshire, USA", .newEngland),
        ("Newport, Rhode Island", .newEngland),
        ("Bennington, Vermont", .newEngland),
        ("Salem, Massachusetts Bay Colony", .newEngland),
        ("New England", .newEngland),
        ("Old England", .england),
        ("Norfolk, England, United Kingdom", .england),
        ("Leicestershire, Eng.", .england),
        ("London, England>", .england),
        ("London, Inglaterra", .england),
        ("Cork, Ireland", .ireland),
        ("Belfast, Northern Ireland", .ireland),
        ("Edinburgh, Scotland", .scotland),
        ("Cardiff, Wales", .wales),
        ("Toronto, Ontario, Canada", .canada),
        ("Halifax, Nova Scotia", .canada),
        ("Columbus, Ohio, USA", .restOfUS),
        ("New York, New York, United States", .restOfUS),
        ("Jamestown, Virginia Colony", .restOfUS),
        ("USA", .unitedStatesUnspecified),
        ("British Colonial America", .unitedStatesUnspecified),
        ("Berlin, Germany", .other),
        ("Paris, France", .other),
        ("London, United Kingdom", .other),
        ("Quebec, New France", .unknown),
        ("Xyzzy", .unknown),
        ("", .unknown),
    ])
    func region(_ place: String, _ expected: BirthplaceClassifier.BirthRegion) {
        #expect(BirthplaceClassifier.region(place) == expected, "\(place)")
    }

    @Test func englandIsNeverASubstringOfNewEngland() {
        #expect(BirthplaceClassifier.region("Dedham, New England") == .newEngland)
        #expect(BirthplaceClassifier.region("Portland, me") == .unknown, "a lower-case word is not Maine")
        #expect(BirthplaceClassifier.region(nil) == .unknown)
    }
}

// MARK: - Dates

@Suite("TreeWalkDates")
struct TreeWalkDateTests {
    @Test func precisionsAndMonthIntervals() throws {
        let d = try #require(TreeWalkDate.parse("4 MAR 1959"))
        #expect(d.precision == .day && d.lowerMonth == 1959 * 12 + 2 && d.day == 4)
        #expect(TreeWalkDate.parse("MAR 1959")?.precision == .month)
        let y = try #require(TreeWalkDate.parse("1959"))
        #expect(y.precision == .year && y.lowerMonth == 1959 * 12 && y.upperMonth == 1959 * 12 + 11)
        #expect(TreeWalkDate.parse("ABT 1700")?.precision == .approximate)
        #expect(TreeWalkDate.parse("ABT 1700")?.lowerMonth == 1698 * 12)
        let before = try #require(TreeWalkDate.parse("BEF 1700"))
        #expect(before.precision == .bounded && before.lowerMonth == nil)
        #expect(TreeWalkDate.parse(nil) == nil)
        #expect(TreeWalkDate.parse("unknown") == nil)
    }

    @Test func ageAtDeath() throws {
        let a = AgeAtDeath.between(birth: TreeWalkDate.parse("31 AUG 1930"), death: TreeWalkDate.parse("3 MAR 2023"))
        #expect(a == AgeAtDeath(minYears: 92, maxYears: 92), "Ma: 92")
        #expect(AgeAtDeath.between(birth: TreeWalkDate.parse("1700"), death: TreeWalkDate.parse("1771"))?.spoken == "70–71")
        #expect(AgeAtDeath.between(birth: TreeWalkDate.parse("BEF 1700"), death: TreeWalkDate.parse("1771")) == nil)
    }
}

// MARK: - Isolation

@Suite("TreeWalkIsolation")
struct TreeWalkIsolationTests {

    @Test func noStartPeopleIsAnHonestError() {
        let empty = GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR")
        #expect(throws: TreeWalk.WalkError.noStartPeople) { try TreeWalk.walk(empty, options: .init(starts: [])) }
        #expect(throws: TreeWalk.WalkError.unknownStart("@NOPE@")) {
            try TreeWalk.walk(marriedWithCollapse(), options: .init(starts: ["@NOPE@"]))
        }
        #expect(TreeWalk.WalkError.noStartPeople.description.contains("pick someone"))
    }

    @Test func missingDatesAreCoverageNotACrash() throws {
        var f = Fam()
        f.person("@A@", "No /Dates/"); f.person("@B@", "Also /None/", "F"); f.person("@C@", "Dad /Only/")
        f.family("@F1@", husband: "@C@", wife: "@B@", children: ["@A@"])
        let r = try walk(f.graph, ["@A@"])
        #expect(r.checks.isEmpty)
        let birth = try #require(r.summary.coverageWalked.first { $0.field == "a birth year" })
        #expect(birth.have == 0 && birth.of == 3)
        #expect(birth.line == "0 of 3 have a birth year")
        #expect(r.decoration(for: "@A@")?.ageAtDeath == nil)
        #expect(r.decoration(for: "@A@")?.documentedAncestorFraction == 0)
    }

    @Test func aHiddenRecordIsNotWalkedOrCounted() throws {
        let text = """
        0 HEAD
        0 @A@ INDI
        1 NAME Child /X/
        1 FAMC @F1@
        0 @P@ INDI
        1 NAME Parent /X/
        1 _FSFTID AAAA-111
        1 FAMS @F1@
        0 @F1@ FAM
        1 HUSB @P@
        1 CHIL @A@
        0 TRLR
        """
        let g = GedcomFamilyGraph(gedcomText: text)
            .applyingIdentityRulings(FamilyIdentityDecisions(decisions: [
                FamilyIdentityDecision(key: .familySearch("AAAA-111"), hidden: true)]))
        let r = try walk(g, ["@A@"])
        #expect(r.decoration(for: "@P@") == nil)
        #expect(r.summary.peopleInTree == 1)
        #expect(r.visitedCount == 1)
    }
}

// MARK: - Store

@Suite("TreeWalkStore")
struct TreeWalkStoreTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("treewalk-\(UUID().uuidString)")
            .appendingPathComponent(TreeWalkStore.fileName)
    }

    @Test func roundTripCurrentAndStale() throws {
        let g = marriedWithCollapse()
        let r = try walk(g, ["@R@", "@D@"])
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(TreeWalkStore.load(from: url, expectedSourceKey: r.sourceKey) == .absent)
        try TreeWalkStore.save(r, to: url)
        guard case .current(let stored) = TreeWalkStore.load(from: url, expectedSourceKey: TreeWalkStore.sourceKey(of: g)) else {
            Issue.record("expected current"); return
        }
        #expect(stored.people["@X@"] == r.decoration(for: "@X@"))
        #expect(stored.people.count == 9)
        #expect(stored.checks == r.checks)
        #expect(stored.summary == r.summary)
        // A changed tree is stale.
        guard case .stale = TreeWalkStore.load(from: url, expectedSourceKey: "different") else {
            Issue.record("expected stale"); return
        }
    }

    @Test func aPoisonedFileIsUnreadableNotACrash() throws {
        let url = scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"walkerVersion\": 1, \"people\": [".utf8).write(to: url)
        guard case .unreadable = TreeWalkStore.load(from: url, expectedSourceKey: nil) else {
            Issue.record("expected unreadable"); return
        }
        // An older walker version is stale.
        let r = try walk(marriedWithCollapse(), ["@R@"])
        var json = String(decoding: try TreeWalkStore.encode(TreeWalkStored(r)), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"walkerVersion\":\(TreeWalk.walkerVersion)", with: "\"walkerVersion\":0")
        try Data(json.utf8).write(to: url)
        guard case .stale(let why) = TreeWalkStore.load(from: url, expectedSourceKey: r.sourceKey) else {
            Issue.record("expected stale"); return
        }
        #expect(why.contains("v0"))
    }

    @Test func theSourceKeyFollowsTheFacts() {
        let a = TreeWalkStore.sourceKey(of: marriedWithCollapse())
        var f = Fam()
        f.person("@R@", "Richard /Breen/", born: "1959")
        let b = TreeWalkStore.sourceKey(of: f.graph)
        f.people[0].birth = "1960"
        #expect(a != b)
        #expect(b != TreeWalkStore.sourceKey(of: f.graph))
        #expect(a == TreeWalkStore.sourceKey(of: marriedWithCollapse()))
    }
}

// MARK: - Log (sensor)

@Suite("TreeWalkLogCadence")
struct TreeWalkLogCadenceTests {

    @Test func oneStartOneOutcomeAndOneProgressPairPerThousand() throws {
        let g = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 20_000))
        let root = try #require(g.rootPersonID)
        var sink = TreeWalkLog.Sink(TreeWalkLog(mode: .foreground, displayNames: ["Rick"]))
        var lines: [String] = []
        let result = try TreeWalk.walk(g, options: .init(starts: [root], progressEvery: 1_000)) { lines += sink.lines(for: $0) }
        lines += sink.lines(for: .finished(result), savedNote: "decorations saved")
        let p = TreeWalkLog.prefix
        #expect(lines.filter { $0.hasPrefix(p + "starting from") }.count == 1)
        #expect(lines.filter { $0.hasPrefix(p + "analysis complete") }.count == 1)
        let progress = lines.filter { $0.range(of: #"^Walk Tree: [0-9,]+ visited"#, options: .regularExpression) != nil }
        #expect(progress.count == result.visitedCount / 1_000)
        #expect(lines.filter { $0.hasPrefix(p + "decorated ") }.count == progress.count)
        #expect(lines.first?.contains("walker v\(TreeWalk.walkerVersion), foreground") == true)
        let outcome = try #require(lines.last)
        #expect(outcome.contains("visited \(result.visitedCount.formatted()) people"))
        #expect(outcome.hasSuffix("decorations saved"))
    }

    @Test func cancelledAndFailedOutcomes() {
        let log = TreeWalkLog(mode: .background)
        #expect(log.lines(for: .cancelled, starts: []).first?.hasPrefix("Walk Tree: CANCELLED") == true)
        #expect(log.lines(for: .failed("no tree"), starts: []) == ["Walk Tree: FAILED — no tree"])
    }

    @Test func aSmallOrShallowWalkLogsEveryHundred() throws {
        let g = marriedWithCollapse()
        var progress = 0
        _ = try TreeWalk.walk(g, options: .init(starts: ["@R@"], maxGenerations: 5)) { if case .progress = $0 { progress += 1 } }
        #expect(progress == 0, "6 people: fewer than one cadence step")
        let big = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 3_000))
        var events = 0
        let r = try TreeWalk.walk(big, options: .init(starts: [big.rootPersonID!])) { if case .progress = $0 { events += 1 } }
        #expect(events == r.visitedCount / 100, "under 5,000 reachable → every 100")
    }
}

// MARK: - Scope (Rick 2026-09-27 spot test: a 3-generation walk showed the
// WHOLE tree's 1,119 warnings in its summary)

/// Rick (@R) and Donna (@D), each with a straight father line five deep.
/// A depth-3 walk visits R, R1, R2, R3 and D, D1, D2, D3.
///   IN scope:  R2 age at death over 110 (walked alone);
///              R3 born before his father R4 was 12 — R3 is walked, R4 is
///              not; the check involves a walked person (the fan marks R3),
///              so it counts. This is the boundary rule, pinned here.
///   OUT of scope: R4 born before R5 was 12 (neither walked);
///              cousin @C (a child of R2, not an ancestor) death before
///              birth; D4 age over 110; a two-person loop @L1/@L2
///              nobody walks into.
private func scopedPedigree() -> GedcomFamilyGraph {
    var f = Fam()
    f.roots = ["@R@", "@D@"]
    f.person("@R@", "Richard /Breen/", born: "1959")
    f.person("@R1@", "Rone /Breen/", born: "1929")
    f.person("@R2@", "Rtwo /Breen/", born: "1900", died: "2015")         // in: age over 110
    f.person("@R3@", "Rthree /Breen/", born: "1850")
    f.person("@R4@", "Rfour /Breen/", born: "1845")                       // R3 born when R4 was 5
    f.person("@R5@", "Rfive /Breen/", born: "1840")                       // R4 born when R5 was 5
    f.person("@C@", "Cousin /Breen/", born: "1935", died: "1930")          // out: not an ancestor
    f.person("@D@", "Donna /Hudson/", "F", born: "1959")
    f.person("@D1@", "Done /Hudson/", born: "1930")
    f.person("@D2@", "Dtwo /Hudson/", born: "1900")
    f.person("@D3@", "Dthree /Hudson/", born: "1870")
    f.person("@D4@", "Dfour /Hudson/", born: "1840", died: "1960")          // out: generation 4, age over 110
    f.person("@L1@", "Loop /One/"); f.person("@L2@", "Loop /Two/")
    f.family("@F0@", husband: "@R@", wife: "@D@", children: [])
    f.family("@FR1@", husband: "@R1@", wife: nil, children: ["@R@"])
    f.family("@FR2@", husband: "@R2@", wife: nil, children: ["@R1@", "@C@"])
    f.family("@FR3@", husband: "@R3@", wife: nil, children: ["@R2@"])
    f.family("@FR4@", husband: "@R4@", wife: nil, children: ["@R3@"])
    f.family("@FR5@", husband: "@R5@", wife: nil, children: ["@R4@"])
    f.family("@FD1@", husband: "@D1@", wife: nil, children: ["@D@"])
    f.family("@FD2@", husband: "@D2@", wife: nil, children: ["@D1@"])
    f.family("@FD3@", husband: "@D3@", wife: nil, children: ["@D2@"])
    f.family("@FD4@", husband: "@D4@", wife: nil, children: ["@D3@"])
    f.family("@FL1@", husband: "@L1@", wife: nil, children: ["@L2@"])
    f.family("@FL2@", husband: "@L2@", wife: nil, children: ["@L1@"])
    return f.graph
}

@Suite("TreeWalkScope")
struct TreeWalkScopeTests {

    @Test func aThreeGenerationSummaryCountsOnlyTheWalkedPeoplesChecks() throws {
        let r = try walk(scopedPedigree(), ["@R@", "@D@"], depth: 3)
        #expect(r.summary.peopleWalked == 8)
        // The tree still HAS every check (decorations.json, the inspector)…
        #expect(r.checks.filter { $0.kind == .ageOver110 }.count == 2)
        #expect(r.checks.filter { $0.kind == .deathBeforeBirth }.count == 1)
        #expect(r.checks.filter { $0.kind == .childBornBeforeParentAge12 }.count == 2)
        #expect(r.checks.filter { $0.kind == .ancestorCycle }.count == 1)
        // …but the walk's summary counts only the checks on people it walked.
        #expect(r.summary.checksByKind[.ageOver110] == 1, "R2 only; not D4 (generation 4)")
        #expect(r.summary.checksByKind[.deathBeforeBirth] == nil, "the cousin is not an ancestor")
        #expect(r.summary.checksByKind[.childBornBeforeParentAge12] == 1, "R3↔R4 (R3 walked); not R4↔R5")
        #expect(r.summary.checksByKind[.ancestorCycle] == nil, "nobody walks into the loop")
        #expect(r.summary.warnCount == 2)
        #expect(r.summary.infoCount == 0)
        #expect(r.summary.cycleCount == 0)
        // Whole-tree totals are kept, apart and labelled by name.
        #expect(r.summary.treeChecksByKind[.ageOver110] == 2)
        #expect(r.summary.treeChecksByKind[.deathBeforeBirth] == 1)
        #expect(r.summary.treeChecksByKind[.childBornBeforeParentAge12] == 2)
        #expect(r.summary.treeCycleCount == 1)
        #expect(r.summary.treeWarnCount == 6)
        #expect(r.summary.treeCheckCount == r.checks.count)
        // Coverage is over the walked 8, not the tree's 14.
        #expect(r.summary.coverageWalked.first?.of == 8)
        #expect(r.summary.peopleInTree == 14)
    }

    @Test func theOutcomeLineCountsTheWalksChecks() throws {
        let r = try walk(scopedPedigree(), ["@R@", "@D@"], depth: 3)
        let line = TreeWalkLog(mode: .foreground, displayNames: ["Rick", "Donna"]).outcome(r, savedNote: nil)
        #expect(line.contains("visited 8 people"))
        #expect(line.contains(", 2 checks (2 warn),"), "\(line)")
    }

    @Test func theSummarySaysWhatItWalkedInPlainWords() throws {
        let g = scopedPedigree()
        let three = try walk(g, ["@R@", "@D@"], depth: 3).summary
        #expect(three.walkedSentence(names: ["Rick", "Donna"])
                == "Walked 3 generations from Rick and Donna — 8 people (Rick's line 4, Donna's line 4)")
        #expect(three.walkedSentence() == "Walked 3 generations from Richard and Donna — 8 people (Richard's line 4, Donna's line 4)")
        let all = try walk(g, ["@R@", "@D@"]).summary
        #expect(all.walkedSentence(names: ["Rick", "Donna"])
                == "Walked every generation from Rick and Donna (5 generations above Rick, 4 above Donna) — 11 people (Rick's line 6, Donna's line 5)")
        let one = try walk(g, ["@R@"], depth: 1).summary
        #expect(one.walkedSentence(names: ["Rick"]) == "Walked 1 generation from Rick — 2 people")
        let collapse = try walk(marriedWithCollapse(), ["@R@", "@D@"]).summary
        #expect(collapse.walkedSentence(names: ["Rick", "Donna"]).hasSuffix("(Rick's line 3, Donna's line 3, on both lines 3)"))
    }

    @Test func aVersionOneFileIsStaleNotUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("twscope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(TreeWalkStore.fileName)
        // The v1 shape: a summary without the v2 fields.
        try Data(#"{"walkerVersion":1,"sourceKey":"k","generatedAt":"2026-09-27T00:00:00Z","starts":[],"people":{},"checks":[],"summary":{"peopleInTree":1}}"#.utf8).write(to: url)
        #expect(TreeWalkStore.load(from: url, expectedSourceKey: "k") == .stale(reason: "made by walker v1; this build is v\(TreeWalk.walkerVersion)"))
    }

    @Test func theWalkLogsOnlyTheWalkedPeoplesChecks() throws {
        var warn: [TreeWalk.Check] = [], cycles: [TreeWalk.Check] = []
        _ = try TreeWalk.walk(scopedPedigree(), options: .init(starts: ["@R@", "@D@"], maxGenerations: 3)) { event in
            if case .warnCheck(let c) = event { warn.append(c) }
            if case .cycle(let c) = event { cycles.append(c) }
        }
        #expect(Set(warn.map(\.personIDs)) == [["@R2@"], ["@R3@", "@R4@"]])
        #expect(cycles.isEmpty)
    }
}

/// A 41-person father line, everyone born 1900 (so each child is "born
/// before the father was 12": 40 warnings), and the first 30 of them with a
/// mother who is her own parent (30 cycles, all walked).
private func manyWarningsAndCycles() -> GedcomFamilyGraph {
    var f = Fam()
    for i in 1...41 { f.person("@I\(i)@", "P\(i) /Line/", born: "1900") }
    for i in 1...30 { f.person("@Q\(i)@", "Q\(i) /Loop/", "F") }
    for i in 1...40 {
        f.family("@F\(i)@", husband: "@I\(i + 1)@", wife: i <= 30 ? "@Q\(i)@" : nil, children: ["@I\(i)@"])
    }
    for i in 1...30 { f.family("@G\(i)@", husband: nil, wife: "@Q\(i)@", children: ["@Q\(i)@"]) }
    return f.graph
}

@Suite("TreeWalkLogCap")
struct TreeWalkLogCapTests {

    /// Rick 2026-09-27: 1,119 check lines in one burst. The first 25
    /// warnings individually, then ONE remainder line; cycles always listed.
    @Test func first25WarningsThenOneRemainderLineCyclesAllListed() throws {
        var sink = TreeWalkLog.Sink(TreeWalkLog(mode: .foreground, displayNames: ["Rick"]))
        var lines: [String] = []
        let r = try TreeWalk.walk(manyWarningsAndCycles(), options: .init(starts: ["@I1@"])) { lines += sink.lines(for: $0) }
        lines += sink.lines(for: .finished(r), savedNote: "decorations saved")
        let p = TreeWalkLog.prefix
        let warnings = r.checks.filter { $0.severity == .warn && $0.kind != .ancestorCycle }.count
        #expect(warnings == 40)
        #expect(lines.filter { $0.hasPrefix(p + "check — ") }.count == 25)
        #expect(lines.filter { $0.hasPrefix(p + "cycle — ") }.count == 30, "cycles are never capped")
        let more = lines.filter { $0.hasPrefix(p + "… and ") }
        #expect(more == [p + "… and 15 more warnings — see the Walk Tree report / decorations.json"])
        let moreLine = try #require(more.first)
        let moreAt = try #require(lines.firstIndex(of: moreLine))
        let outcomeAt = try #require(lines.firstIndex { $0.hasPrefix(p + "analysis complete") })
        #expect(moreAt == outcomeAt - 1, "the remainder line comes right before the OUTCOME")
    }

    @Test func noRemainderLineAtOrUnderTheCap() throws {
        var sink = TreeWalkLog.Sink(TreeWalkLog(mode: .foreground))
        var lines: [String] = []
        let r = try TreeWalk.walk(scopedPedigree(), options: .init(starts: ["@R@", "@D@"])) { lines += sink.lines(for: $0) }
        lines += sink.lines(for: .finished(r))
        #expect(!lines.contains { $0.hasPrefix(TreeWalkLog.prefix + "… and ") })
    }
}
