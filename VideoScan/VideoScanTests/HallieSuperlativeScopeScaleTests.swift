// HallieSuperlativeScopeScaleTests.swift
// Night hardening 2026-09-26 — coverage audit of d7eaa08b (Hallie scoped
// superlatives: "earliest birth year for richard's tree", "youngest of
// rick's descendants"). HallieSuperlativeScopeTests pins the logic on a
// 14-person fixture. Two dimensions had nothing:
//
//   SCALE + SENSOR — the scope walks the tree (ancestorLine up, a
//     descendant DFS down) and the answer now STATES the count ("among
//     Rick's 6 recorded ancestors"). On a real merged tree with pedigree
//     collapse (the same ancestor reached through several lines — the
//     synthetic pedigree intermarries every row), that count is only
//     honest if every person is counted once. Pinned at 100k people:
//     the stated count equals an independent unique walk, the winner's
//     year is the true min/max of that set, within an explicit budget.
//
//   ISOLATION — Rick's identity rulings (codex #1710: "a record Rick hid
//     never wins"). The whole-tree ranking is pinned by
//     IdentityRulingsCoherenceTests; the new person scopes were not. A
//     hidden ancestor / descendant must neither win nor be counted.
//
// (C++ readers: `#require` is ASSERT_* — it stops the test; `#expect` is
// EXPECT_*. `GedcomFamilyGraph` is a value type; `applyingIdentityRulings`
// returns a new ruled view, the raw graph is untouched.)

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private typealias Exec = HallieTurnExecutor

private func context(_ graph: GedcomFamilyGraph, ownerName: String, ownerFSID: String?) -> Exec.Context {
    .init(profiles: [], graph: graph,
          speakers: .init(ownerName: ownerName, archivistName: nil, archivistPersonName: nil,
                          ownerFamilySearchID: ownerFSID))
}

/// The number in "… ’s 12,345 recorded ancestors across 21 generations".
private func statedCount(_ basis: String, noun: String) -> Int? {
    guard let r = basis.range(of: " recorded \(noun)") else { return nil }
    let before = basis[..<r.lowerBound]
    guard let space = before.lastIndex(of: " ") else { return nil }
    return Int(before[before.index(after: space)...].filter(\.isNumber))
}

/// Independent unique walk over the ruled `relatives` API — the oracle.
private func uniqueWalk(from start: GedcomFamilyGraph.Person, _ relation: GedcomFamilyGraph.Relation,
                        in graph: GedcomFamilyGraph) -> [GedcomFamilyGraph.Person] {
    var seen: Set<String> = [start.id]
    var frontier = [start]
    var out: [GedcomFamilyGraph.Person] = []
    while !frontier.isEmpty {
        var next: [GedcomFamilyGraph.Person] = []
        for p in frontier {
            for r in graph.relatives(relation, of: p) where seen.insert(r.id).inserted {
                out.append(r)
                next.append(r)
            }
        }
        frontier = next
    }
    return out
}

private func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

// MARK: - Scale + sensor

@Suite("Superlative scope — 100k people with pedigree collapse: counted once, ranked right, in budget", .serialized)
struct HallieSuperlativeScopeScaleTests {

    static let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))

    @Test("ancestors of the youngest person: the stated count is the unique ancestor set; the winner is its earliest year",
          .timeLimit(.minutes(2)))
    func ancestorsAtScale() throws {
        let graph = Self.graph
        let root = try #require(graph.people["@I0_0@"])
        let fsid = try #require(root.familySearchID, "the synthetic pedigree pins every 5th person")
        let ctx = context(graph, ownerName: root.name, ownerFSID: fsid)
        _ = graph.index   // built at install in production (launch bundle), never per question

        let clock = ContinuousClock()
        let start = clock.now
        let r = try #require(HallieLineageAnswer.answer(.superlative(kind: .earliestBorn, scope: .ancestorsOf(nil)), context: ctx))
        let elapsed = seconds(clock.now - start)

        let oracle = uniqueWalk(from: root, .parents, in: graph)
        #expect(oracle.count > 1_000, "precondition: a deep, collapsed pedigree (\(oracle.count) unique ancestors)")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        let stated = try #require(statedCount(r.basisLine, noun: "ancestors"), Comment(rawValue: r.basisLine))
        #expect(stated == oracle.count,
                "the answer says \(stated) recorded ancestors; the unique set has \(oracle.count) — pedigree collapse must count each person once")
        let minYear = try #require(oracle.compactMap(\.birthYear).min())
        #expect(r.prose.contains("born \(minYear)"), Comment(rawValue: String(r.prose.prefix(300))))

        // Measured 2026-09-26, M5 Pro Debug, index warm: ancestors 0.034 s,
        // descendants 0.243 s. ~8× the slower walk: catches a per-person
        // O(n) step (O(n²) at this size), not jitter.
        let budget = PerformanceLane.loadAwareDebugCeiling(PerformanceLane.isDebugBuild ? .seconds(2) : .milliseconds(500))
        print("SCALE[\(PerformanceLane.configurationName)] scoped superlative ancestors of 100k-tree root (\(oracle.count) ancestors): \(elapsed) s")
        #expect(elapsed < seconds(budget), "ancestor-scoped superlative took \(elapsed) s (\(PerformanceLane.loadDescription()))")
    }

    @Test("descendants of an oldest-row person: the stated count is the unique descendant set; the winner is its latest year",
          .timeLimit(.minutes(2)))
    func descendantsAtScale() throws {
        let graph = Self.graph
        let elder = try #require(graph.people["@I21_0@"])
        let fsid = try #require(elder.familySearchID)
        let ctx = context(graph, ownerName: elder.name, ownerFSID: fsid)
        _ = graph.index

        let clock = ContinuousClock()
        let start = clock.now
        let r = try #require(HallieLineageAnswer.answer(.superlative(kind: .latestBorn, scope: .descendantsOf(nil)), context: ctx))
        let elapsed = seconds(clock.now - start)

        let oracle = uniqueWalk(from: elder, .children, in: graph)
        #expect(oracle.count > 1_000, "precondition: a wide, intermarried descent (\(oracle.count) unique descendants)")
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        let stated = try #require(statedCount(r.basisLine, noun: "descendant"), Comment(rawValue: r.basisLine))
        #expect(stated == oracle.count,
                "the answer says \(stated) recorded descendants; the unique set has \(oracle.count)")
        let maxYear = try #require(oracle.compactMap(\.birthYear).max())
        #expect(r.prose.contains("born \(maxYear)"), Comment(rawValue: String(r.prose.prefix(300))))

        // Measured 2026-09-26, M5 Pro Debug, index warm: ancestors 0.034 s,
        // descendants 0.243 s. ~8× the slower walk: catches a per-person
        // O(n) step (O(n²) at this size), not jitter.
        let budget = PerformanceLane.loadAwareDebugCeiling(PerformanceLane.isDebugBuild ? .seconds(2) : .milliseconds(500))
        print("SCALE[\(PerformanceLane.configurationName)] scoped superlative descendants of 100k-tree elder (\(oracle.count) descendants): \(elapsed) s")
        #expect(elapsed < seconds(budget), "descendant-scoped superlative took \(elapsed) s (\(PerformanceLane.loadDescription()))")
    }
}

// MARK: - Isolation: identity rulings

private let ruledTree = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 _FSFTID GVQV-NW3
1 BIRT
2 DATE 4 MAR 1959
1 FAMC @F1@
1 FAMS @F5@
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 1929
1 FAMC @F2@
1 FAMS @F1@
0 @I3@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 1930
1 FAMS @F1@
0 @I7@ INDI
1 NAME George /Breen/
1 SEX M
1 BIRT
2 DATE 1898
1 FAMS @F2@
0 @I8@ INDI
1 NAME Muriel /Lamb/
1 SEX F
1 BIRT
2 DATE 1899
1 FAMC @F9@
1 FAMS @F2@
0 @I30@ INDI
1 NAME Wrong /Grandfather/
1 SEX M
1 _FSFTID HIDE-001
1 BIRT
2 DATE 1700
1 FAMS @F9@
0 @I9@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 4 AUG 1959
1 FAMS @F5@
0 @I10@ INDI
1 NAME Tim /Breen/
1 SEX M
1 BIRT
2 DATE 1985
1 FAMC @F5@
0 @I31@ INDI
1 NAME Wrong /Child/
1 SEX M
1 _FSFTID HIDE-002
1 BIRT
2 DATE 2020
1 FAMC @F5@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I7@
1 WIFE @I8@
1 CHIL @I2@
0 @F9@ FAM
1 HUSB @I30@
1 CHIL @I8@
0 @F5@ FAM
1 HUSB @I1@
1 WIFE @I9@
1 CHIL @I10@
1 CHIL @I31@
0 TRLR
"""

@Suite("Superlative scope — a record Rick hid neither wins nor is counted in a person scope")
struct HallieSuperlativeScopeRulingsTests {

    static var rulings: FamilyIdentityDecisions {
        var r = FamilyIdentityDecisions()
        r.record(.init(key: .familySearch("HIDE-001"), hidden: true))
        r.record(.init(key: .familySearch("HIDE-002"), hidden: true))
        return r
    }

    private func answer(_ graph: GedcomFamilyGraph, _ kind: HallieLineageQuestion.SuperlativeKind,
                        _ scope: HallieLineageQuestion.SuperlativeScope) throws -> Exec.Result {
        try #require(HallieLineageAnswer.answer(
            .superlative(kind: kind, scope: scope),
            context: context(graph, ownerName: "Rick Breen", ownerFSID: "GVQV-NW3")))
    }

    @Test func aHiddenAncestorNeitherWinsNorIsCounted() throws {
        let raw = GedcomFamilyGraph(gedcomText: ruledTree)
        // Precondition: the fixture discriminates — raw, the bogus 1700
        // grandfather wins and is counted (5 ancestors).
        let rawAnswer = try answer(raw, .earliestBorn, .ancestorsOf(nil))
        #expect(rawAnswer.prose.contains("Wrong Grandfather"), Comment(rawValue: rawAnswer.prose))
        #expect(statedCount(rawAnswer.basisLine, noun: "ancestors") == 5, Comment(rawValue: rawAnswer.basisLine))

        let ruled = raw.applyingIdentityRulings(Self.rulings)
        let r = try answer(ruled, .earliestBorn, .ancestorsOf(nil))
        #expect(r.outcome == .answered)
        #expect(!r.prose.contains("Wrong Grandfather"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("born 1898: George Breen"), Comment(rawValue: r.prose))
        #expect(statedCount(r.basisLine, noun: "ancestors") == 4, Comment(rawValue: r.basisLine))
        #expect(!r.offeredActions.contains(.openFamilyTreePerson(personID: "@I30@", personName: "Wrong Grandfather")))
    }

    @Test func aHiddenDescendantNeitherWinsNorIsCounted() throws {
        let raw = GedcomFamilyGraph(gedcomText: ruledTree)
        let rawAnswer = try answer(raw, .latestBorn, .descendantsOf(nil))
        #expect(rawAnswer.prose.contains("Wrong Child"), Comment(rawValue: rawAnswer.prose))
        #expect(statedCount(rawAnswer.basisLine, noun: "descendant") == 2, Comment(rawValue: rawAnswer.basisLine))

        let ruled = raw.applyingIdentityRulings(Self.rulings)
        let r = try answer(ruled, .latestBorn, .descendantsOf(nil))
        #expect(r.outcome == .answered)
        #expect(!r.prose.contains("Wrong Child"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("born 1985: Tim Breen"), Comment(rawValue: r.prose))
        #expect(statedCount(r.basisLine, noun: "descendant") == 1, Comment(rawValue: r.basisLine))
    }
}
