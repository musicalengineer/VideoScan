// HallieDeepAncestorTests.swift
// ITEM 3 (live 2026-08-26): "great great great grandpa", "3rd great
// grandfather", "5x great grandmother" fell to the translator because
// ExtendedRelation is closed at great-great. Depth-N ancestors now walk
// the tree deterministically and list each qualifying ancestor with the
// path. Pure: synthetic GEDCOM, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Rick 1959 → Richard Sr 1929 → George 1898 → Patrick 1860 → Owen →
/// Seamus 1790 → Brendan 1750, all male, plus Rick's mother Eileen whose
/// line stops at her mother Mary.
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
0 @I8@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 FAMC @F7@
1 FAMS @F1@
0 @I9@ INDI
1 NAME Mary /McGill/
1 SEX F
1 FAMS @F7@
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
1 WIFE @I8@
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
0 @F7@ FAM
1 WIFE @I9@
1 CHIL @I8@
0 TRLR
"""

@Suite("Deep ancestors — great × 3 and beyond")
struct HallieDeepAncestorTests {
    typealias Q = HallieLineageQuestion
    let graph = GedcomFamilyGraph(gedcomText: chain)
    var context: HallieTurnExecutor.Context {
        .init(profiles: [], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }
    private func pre(_ q: String) -> HallieTurnExecutor.PreTranslation {
        HallieTurnExecutor.preTranslation(
            question: q, playAfterAnswer: false, memory: .init(), isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    }

    @Test func countingGreats() {
        #expect(Q.greatCount(in: "great great great grandpa")! == (3, "grandpa"))
        #expect(Q.greatCount(in: "3rd great grandfather")! == (3, "grandfather"))
        #expect(Q.greatCount(in: "third great grandfather")! == (3, "grandfather"))
        #expect(Q.greatCount(in: "5x great grandmother")! == (5, "grandmother"))
        #expect(Q.greatCount(in: "4 times great grandparents")! == (4, "grandparents"))
        #expect(Q.greatCount(in: "great-great-great-great-grandmother")! == (4, "grandmother"))
        #expect(Q.greatCount(in: "grandma")! == (0, "grandma"))
        #expect(Q.greatCount(in: "uncle") == nil)
        #expect(Q.grandparentSex("grandson") == nil)
    }

    @Test func depthThreeFourFiveAndOrdinalFormsDetect() {
        #expect(Q.detect("tell me about rick's great great great grandpa")
                == .deepAncestor(person: "Rick", depth: 5, sex: "M", side: nil))
        #expect(Q.detect("who was rick's 3rd great grandfather")
                == .deepAncestor(person: "Rick", depth: 5, sex: "M", side: nil))
        #expect(Q.detect("my third great grandfather on my father's side")
                == .deepAncestor(person: nil, depth: 5, sex: "M", side: .paternal))
        #expect(Q.detect("rick's 4th great grandfather")
                == .deepAncestor(person: "Rick", depth: 6, sex: "M", side: nil))
        #expect(Q.detect("rick's 5x great grandmother")
                == .deepAncestor(person: "Rick", depth: 7, sex: "F", side: nil))
        #expect(Q.detect("my great great great great grandparents")
                == .deepAncestor(person: nil, depth: 6, sex: "", side: nil))
        // ≤ great-great stays on the closed vocabulary (unchanged route).
        #expect(Q.detect("rick's great great grandpa")
                == .kinship(person: "Rick", relation: .greatGreatGrandfather, side: nil))
        #expect(Q.detect("rick's 2nd great grandfather")
                == .kinship(person: "Rick", relation: .greatGreatGrandfather, side: nil))
        #expect(Q.detect("who was Donna's maternal grandmother")
                == .kinship(person: "Donna", relation: .grandmother, side: .maternal))
        // A descendant word is still not ours.
        #expect(Q.detect("rick's 3rd great grandson") == nil)
        // The general parser must not read it as a biography of "rick's 3rd great grandfather".
        #expect(ArchivistQuestionParser.general("tell me about rick's 3rd great grandfather") == nil)
    }

    @Test func depthFiveListsSeamusWithThePath() throws {
        guard case .answer(let r) = pre("who was rick's 3rd great grandfather") else {
            Issue.record("expected a local answer"); return
        }
        #expect(r.route == .graph)
        #expect(r.outcome == .answered)
        #expect(r.prose.hasPrefix("Rick Breen’s 3rd-great-grandfather: Seamus Breen (b. 1790) (Rick Breen → father Richard Breen Sr → his father George Breen → his father Patrick Breen → his father Owen Breen → his father Seamus Breen)."), Comment(rawValue: r.prose))
        #expect(r.offeredActions == [.openFamilyTreePerson(personID: "@I6@", personName: "Seamus Breen")])
        #expect(r.basisLine.contains("ancestor walk 5 generations up"))
        // Depth 6, ordinal spelling, same walk.
        guard case .answer(let four) = pre("rick's fourth great grandfather") else { Issue.record("expected local"); return }
        #expect(four.prose.contains("4th-great-grandfather: Brendan Breen (b. 1750)"))
        // "my …" binds to the owner.
        guard case .answer(let mine) = pre("my great great great grandpa on my paternal side") else { Issue.record("expected local"); return }
        #expect(mine.prose.contains("paternal 3rd-great-grandfather: Seamus Breen"))
        #expect(mine.basisLine.contains("first hop through the paternal side"))
    }

    @Test func missingHopAndMissingSexAreSaidExactly() throws {
        // Depth 7: the tree stops at Brendan (6 up).
        guard case .answer(let seven) = pre("rick's 5x great grandmother") else { Issue.record("expected local"); return }
        #expect(seven.outcome == .declined)
        #expect(seven.prose.contains("but no parents for Brendan Breen"))
        #expect(seven.prose.contains("6 of 7 generations recorded"))
        // Depth 5 female: everyone there is male.
        guard case .answer(let her) = pre("rick's 3rd great grandmother") else { Issue.record("expected local"); return }
        #expect(her.outcome == .declined)
        #expect(her.prose.contains("records nobody female there"))
        // Maternal side dies at generation 2 (Mary has no parents).
        guard case .answer(let mat) = pre("rick's 3rd great grandfather on his mother's side") else { Issue.record("expected local"); return }
        #expect(mat.outcome == .declined)
        #expect(mat.prose.contains("mother (Eileen Latta) → her mother (Mary McGill), but no parents for Mary McGill"))
    }

    // MARK: deepAncestors — characterization (2026-10-29, before the split)
    //
    // The branches the tests above do not reach: a person with no parents
    // at all (with and without a side), the caller's basis note, and the
    // walk budget declining before the asked-for generation.

    @Test func noParentsAtAllIsSaidWithTheSideWord() throws {
        let brendan = try #require(graph.people["@I7@"])
        let none = HallieLineageAnswer.deepAncestors(of: brendan, depth: 3, sex: nil, side: nil, graph: graph)
        #expect(none.outcome == .declined)
        #expect(none.prose == "The family tree doesn’t record parents for Brendan Breen, so I can’t reach a great-grandparent.")
        #expect(none.basisLine == "Basis: imported family tree (GEDCOM); ancestor walk 3 generations up.")
        #expect(none.offeredActions == [.openFamilyTreePerson(personID: "@I7@", personName: "Brendan Breen")])
        let mary = try #require(graph.people["@I9@"])
        let maternal = HallieLineageAnswer.deepAncestors(of: mary, depth: 3, sex: "F", side: .maternal, graph: graph)
        #expect(maternal.outcome == .declined)
        #expect(maternal.prose == "The family tree doesn’t record a mother for Mary McGill, so I can’t reach a maternal great-grandmother.")
        #expect(maternal.basisLine == "Basis: imported family tree (GEDCOM); ancestor walk 3 generations up, first hop through the maternal side.")
    }

    @Test func basisNoteFollowsTheWalkDescription() throws {
        let rick = try #require(graph.people["@I1@"])
        let r = HallieLineageAnswer.deepAncestors(of: rick, depth: 5, sex: "M", side: .paternal, graph: graph,
                                                  basisNote: "Taking “my” as Rick Breen.")
        #expect(r.basisLine == "Basis: imported family tree (GEDCOM); ancestor walk 5 generations up, first hop through the paternal side. Taking “my” as Rick Breen.")
        #expect(r.queryDescription == "deep ancestor ×5 M: Rick Breen")
    }

    /// Both budget branches, reached by COUNT: an 8-generation pedigree
    /// (255 people) with a 100-expansion cap and an hour on the clock.
    /// Generations 1–6 take 63 expansions; the cap trips 37 people into
    /// generation 7. (codex 2026-10-29: the first version used the real
    /// 0.15 s clock on 131k people, which a loaded host could trip earlier.)
    @Test func walkBudgetIsSaidOnAPartialAnswerAndDeclinesShortOfTheGeneration() throws {
        let graph = GedcomFamilyGraph(gedcomText: Self.binaryPedigree(generations: 8))
        let root = try #require(graph.people["@I1@"])
        let budget = HallieLineageAnswer.DeepAncestorBudget(maxExpanded: 100, timeBudget: 3600)
        // Budget trips while filling the asked generation: a partial list, said so.
        let partial = HallieLineageAnswer.deepAncestors(of: root, depth: 7, sex: nil, side: nil,
                                                        graph: graph, budget: budget)
        #expect(partial.outcome == .answered)
        #expect(partial.prose.hasPrefix("Person N1’s 5th-great-grandparents: Person N128 ("), Comment(rawValue: String(partial.prose.prefix(120))))
        #expect(partial.prose.hasSuffix(" There are 49 more at that generation I haven’t listed (74 in all). I stopped the walk at its budget (100 people examined), so there may be others."),
                Comment(rawValue: partial.prose))
        #expect(partial.basisLine == "Basis: imported family tree (GEDCOM); ancestor walk 7 generations up. Walk stopped at its budget; there may be more.")
        #expect(partial.offeredActions.count == 3)
        // One generation further: the budget trips before generation 8 has anyone.
        let short = HallieLineageAnswer.deepAncestors(of: root, depth: 8, sex: nil, side: nil,
                                                      graph: graph, budget: budget)
        #expect(short.outcome == .declined)
        #expect(short.prose == "Person N1’s ancestry fans out too far for me to reach a 6th-great-grandparent in one go — I examined 100 people across 7 generations and stopped. Try one line (paternal or maternal) or a smaller count.")
        #expect(short.basisLine == "Basis: imported family tree (GEDCOM); ancestor walk 8 generations up. Walk stopped at its budget.")
        // The production budget is the two static caps, unchanged.
        #expect(HallieLineageAnswer.DeepAncestorBudget.production.maxExpanded == 50_000)
        #expect(HallieLineageAnswer.DeepAncestorBudget.production.timeBudget == 0.15)
    }

    /// Heap-indexed binary pedigree (person n's parents are 2n and 2n+1).
    private static func binaryPedigree(generations: Int) -> String {
        let count = (1 << generations) - 1
        var out = ["0 HEAD"]
        for n in 1...count {
            out.append("0 @I\(n)@ INDI")
            out.append("1 NAME Person /N\(n)/")
            out.append("1 SEX \(n == 1 || n % 2 == 0 ? "M" : "F")")
            if 2 * n + 1 <= count { out.append("1 FAMC @F\(n)@") }
            if n > 1 { out.append("1 FAMS @F\(n / 2)@") }
        }
        for n in 1...count where 2 * n + 1 <= count {
            out.append("0 @F\(n)@ FAM")
            out.append("1 HUSB @I\(2 * n)@")
            out.append("1 WIFE @I\(2 * n + 1)@")
            out.append("1 CHIL @I\(n)@")
        }
        out.append("0 TRLR")
        return out.joined(separator: "\n")
    }
}
