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
}
