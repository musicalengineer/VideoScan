// HallieLineageYearBoundTests.swift
// ITEM 2 (live 2026-08-26): "the family tree from rick breen all the way
// back to 1600" walked until the tree ended. "back to <year>" / "before
// <year>" / "until the 1600s" is now a stop on the ancestor walk. Pure.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// A single paternal chain with one undated link:
/// Rick 1959 → Richard Sr 1929 → George 1898 → Patrick 1860 → Owen (undated)
/// → Seamus 1790 → Brendan 1750.
private let chain = """
0 HEAD
0 @I1@ INDI
1 NAME Rick /Breen/
1 SEX M
1 BIRT
2 DATE 1959
1 FAMC @F1@
0 @I2@ INDI
1 NAME Richard /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 1929
1 FAMC @F2@
1 FAMS @F1@
0 @I3@ INDI
1 NAME George /Breen/
1 SEX M
1 BIRT
2 DATE 1898
1 FAMC @F3@
1 FAMS @F2@
0 @I4@ INDI
1 NAME Patrick /Breen/
1 SEX M
1 BIRT
2 DATE 1860
1 FAMC @F4@
1 FAMS @F3@
0 @I5@ INDI
1 NAME Owen /Breen/
1 SEX M
1 FAMC @F5@
1 FAMS @F4@
0 @I6@ INDI
1 NAME Seamus /Breen/
1 SEX M
1 BIRT
2 DATE 1790
1 FAMC @F6@
1 FAMS @F5@
0 @I7@ INDI
1 NAME Brendan /Breen/
1 SEX M
1 BIRT
2 DATE 1750
1 FAMS @F6@
0 @F1@ FAM
1 HUSB @I2@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I3@
1 CHIL @I2@
0 @F3@ FAM
1 HUSB @I4@
1 CHIL @I3@
0 @F4@ FAM
1 HUSB @I5@
1 CHIL @I4@
0 @F5@ FAM
1 HUSB @I6@
1 CHIL @I5@
0 @F6@ FAM
1 HUSB @I7@
1 CHIL @I6@
0 TRLR
"""

@Suite("Lineage — year bound")
struct HallieLineageYearBoundTests {
    typealias Q = HallieLineageQuestion
    let graph = GedcomFamilyGraph(gedcomText: chain)
    var rick: GedcomFamilyGraph.Person { graph.people["@I1@"]! }
    var context: HallieTurnExecutor.Context {
        .init(profiles: [], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }

    @Test func walkStopsAtTheYearAndKeepsUndatedLinksUnderADatedChild() {
        // 1850: Patrick (1860) in; Owen undated but reached through Patrick
        // (1860 ≥ 1850) in; Seamus (1790) out — and nothing walked past him.
        let to1850 = graph.ancestorLine(of: rick, line: .paternal, generations: 40, untilYear: 1850)
        #expect(to1850.map { $0.people.map(\.name) } == [["Richard Breen Sr"], ["George Breen"], ["Patrick Breen"], ["Owen Breen"]])
        // 1900: George (1898) is past the bound; the walk ends at Sr.
        let to1900 = graph.ancestorLine(of: rick, line: .paternal, generations: 40, untilYear: 1900)
        #expect(to1900.map { $0.people.map(\.name) } == [["Richard Breen Sr"]])
        // 1700: nobody is past the bound — the whole chain, same as unbounded.
        let to1700 = graph.ancestorLine(of: rick, line: .paternal, generations: 40, untilYear: 1700)
        #expect(to1700.count == 6)
        #expect(to1700.count == graph.ancestorLine(of: rick, line: .paternal, generations: 40).count)
        // An undated parent of an undated child is NOT kept (the rule as
        // specified: unknown year rides on a dated child only).
        let owen = graph.people["@I5@"]!
        #expect(GedcomFamilyGraph.withinBound(owen, child: owen, year: 1850) == false)
    }

    @Test func theLiveUtteranceParsesAsAYearBoundedAncestorWalk() {
        #expect(Q.detect("show me the family tree from rick breen all the way back to 1600")
                == .ancestorLine(person: "Rick Breen", line: .both, generations: Q.yearBoundGenerations, untilYear: 1600))
        #expect(Q.detect("trace my paternal line back to 1700")
                == .ancestorLine(person: nil, line: .paternal, generations: Q.yearBoundGenerations, untilYear: 1700))
        #expect(Q.detect("rick's ancestors before 1800")
                == .ancestorLine(person: "Rick", line: .both, generations: Q.yearBoundGenerations, untilYear: 1800))
        #expect(Q.detect("show my maternal line until the 1600s")
                == .ancestorLine(person: nil, line: .maternal, generations: Q.yearBoundGenerations, untilYear: 1600))
        // An explicit generation count still wins as the cap.
        #expect(Q.detect("rick's ancestors back 3 generations to 1800")
                == .ancestorLine(person: "Rick", line: .both, generations: 3, untilYear: 1800))
        // Unchanged shapes: a country is not a year; no bound → no bound.
        #expect(Q.detect("trace the family back to Ireland") == .originTrail(person: nil, country: "Ireland", line: .both))
        #expect(Q.detect("rick's maternal line back 5 generations") == .ancestorLine(person: "Rick", line: .maternal, generations: 5))
        // A media question with years is not ours.
        #expect(Q.detect("show me donna from 1990 to 1995") == nil)
        #expect(Q.yearBound(in: "back to 1600") == 1600)
        #expect(Q.yearBound(in: "until the 1600s") == 1600)
        #expect(Q.yearBound(in: "back 5 generations") == nil)
        #expect(Q.yearBound(in: "back to 0600") == nil)
    }

    @Test func theAnswerSaysItStoppedAtTheYear() throws {
        let r = try #require(HallieLineageAnswer.answer(
            .ancestorLine(person: "Rick", line: .paternal, generations: Q.yearBoundGenerations, untilYear: 1850),
            context: context))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("back to 1850"))
        #expect(r.prose.contains("Owen Breen"))
        #expect(!r.prose.contains("Seamus Breen"))
        #expect(r.prose.contains("I stopped at 1850 as you asked; the tree goes further back."))
        #expect(r.queryDescription?.contains("until 1850") == true)
        guard case .lineage(let card)? = r.attachments.first else { Issue.record("no lineage card"); return }
        #expect(card.generations.count == 4)
        // A bound the tree never reaches is said as the tree's own limit.
        let deep = try #require(HallieLineageAnswer.answer(
            .ancestorLine(person: "Rick", line: .paternal, generations: Q.yearBoundGenerations, untilYear: 1600),
            context: context))
        #expect(deep.prose.contains("Brendan Breen"))
        #expect(deep.prose.contains("as far as the tree reaches on that line before 1600"))
        // A bound that excludes even the parents declines honestly.
        let none = try #require(HallieLineageAnswer.answer(
            .ancestorLine(person: "Rick", line: .paternal, generations: Q.yearBoundGenerations, untilYear: 1950),
            context: context))
        #expect(none.outcome == .declined)
        #expect(none.prose.contains("born in or after 1950"))
    }
}
