// HallieSuperlativeScopeTests.swift
// Live 2026-09-26 20:46–20:49 ET (session E1832598): "find the person in
// the family tree with the earliest birth date who is a direct ancestor to
// rick" and "find the earliest birth year for richard's tree" both ranked
// the WHOLE tree and answered Gruffudd ap Einion b. 780 — Donna's line.
// Rick's corrections — "that person b. 780 is donna's ancestor, not mine. I
// want mine" and "that is donna's line" — became biographies of Rick and of
// Donna. Pinned here: a scoped superlative ranks that person's ancestors
// (or descendants), states the scope and its size, a scope correction right
// after re-runs the same ranking over the corrected scope, and an unscoped
// superlative still ranks the whole tree word for word as before.
//
// Fixture: the merged two-root shape of the live tree in miniature —
// Rick's side stops at Patrick Breen 1860, Donna's side reaches a
// Gruffudd ap Einion b. 780, so the whole tree and Rick's ancestors have
// different winners.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let tree = """
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
1 DEAT
2 DATE 2008
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
1 FAMC @F6@
1 FAMS @F2@
0 @I8@ INDI
1 NAME Muriel /Lamb/
1 SEX F
1 BIRT
2 DATE 1899
1 FAMS @F2@
0 @I13@ INDI
1 NAME Patrick /Breen/
1 SEX M
1 BIRT
2 DATE 1860
2 PLAC Cork, Ireland
1 FAMS @F6@
0 @I14@ INDI
1 NAME Hannah /Ryan/
1 SEX F
1 BIRT
2 DATE 1862
1 FAMS @F6@
0 @I9@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 4 AUG 1959
1 FAMC @F7@
1 FAMS @F5@
0 @I20@ INDI
1 NAME Richard C /Hudson/
1 SEX M
1 BIRT
2 DATE 1930
1 FAMC @F8@
1 FAMS @F7@
0 @I21@ INDI
1 NAME Elaine /Bowser/
1 SEX F
1 BIRT
2 DATE 1932
1 FAMS @F7@
0 @I22@ INDI
1 NAME William S /Hudson/
1 SEX M
1 BIRT
2 DATE 1900
1 FAMC @F9@
1 FAMS @F8@
0 @I23@ INDI
1 NAME Bessie /Macgregor/
1 SEX F
1 BIRT
2 DATE 1902
1 FAMS @F8@
0 @I24@ INDI
1 NAME Gruffudd ap /Einion/
1 SEX M
1 BIRT
2 DATE ABT 0780
2 PLAC Wales
1 FAMS @F9@
0 @I10@ INDI
1 NAME Tim /Breen/
1 SEX M
1 BIRT
2 DATE 1985
1 FAMC @F5@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I7@
1 WIFE @I8@
1 CHIL @I2@
0 @F6@ FAM
1 HUSB @I13@
1 WIFE @I14@
1 CHIL @I7@
0 @F5@ FAM
1 HUSB @I1@
1 WIFE @I9@
1 CHIL @I10@
0 @F7@ FAM
1 HUSB @I20@
1 WIFE @I21@
1 CHIL @I9@
0 @F8@ FAM
1 HUSB @I22@
1 WIFE @I23@
1 CHIL @I20@
0 @F9@ FAM
1 HUSB @I24@
1 CHIL @I22@
0 TRLR
"""

@Suite("Superlative scope — X's tree / ancestors / side, and the scope correction after (live 2026-09-26)")
struct HallieSuperlativeScopeTests {
    typealias Q = HallieLineageQuestion
    typealias Exec = HallieTurnExecutor
    let graph = GedcomFamilyGraph(gedcomText: tree)
    var context: Exec.Context {
        .init(profiles: [], graph: graph, assetConfiguration: { .emptyForTests },
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil,
                              ownerFamilySearchID: "GVQV-NW3"))
    }
    private func pre(_ q: String, memory: Exec.ConversationMemory = .init()) -> Exec.PreTranslation {
        Exec.preTranslation(
            question: q, playAfterAnswer: false, memory: memory, isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    }
    /// One turn: the local answer, recorded into memory the way the app's
    /// commit path records it. Nil when the question went to the translator.
    private func turn(_ q: String, memory: inout Exec.ConversationMemory) -> Exec.Result? {
        guard case .answer(let r) = pre(q, memory: memory) else { return nil }
        memory.record(intent: nil, result: r, question: q)
        return r
    }
    private func answer(_ kind: Q.SuperlativeKind, _ scope: Q.SuperlativeScope) throws -> Exec.Result {
        try #require(HallieLineageAnswer.answer(.superlative(kind: kind, scope: scope), context: context))
    }

    // MARK: A. Detection — the live utterances carry a scope

    @Test func theLiveUtterancesAreScopedToRicksAncestors() {
        #expect(Q.detect("find the earliest birth year for richard's tree")
                == .superlative(kind: .earliestBorn, scope: .ancestorsOf("Richard")))
        #expect(Q.detect("find the person in the family tree with the earliest birth date who is a direct ancestor to rick")
                == .superlative(kind: .earliestBorn, scope: .ancestorsOf("Rick")))
        // Rick's own words for the one that "worked well" + his fix.
        #expect(Q.detect("find the earliest birth year in the family tree for rick")
                == .superlative(kind: .earliestBorn, scope: .ancestorsOf("Rick")))
    }

    @Test func everyScopePhraseDetects() {
        #expect(Q.detect("who is the oldest person on donna's side") == .superlative(kind: .earliestBorn, scope: .ancestorsOf("Donna")))
        #expect(Q.detect("who is the oldest person in rick's line") == .superlative(kind: .earliestBorn, scope: .ancestorsOf("Rick")))
        #expect(Q.detect("who is the oldest person in rick's family tree") == .superlative(kind: .earliestBorn, scope: .ancestorsOf("Rick")))
        #expect(Q.detect("who lived the longest among donna's ancestors") == .superlative(kind: .longestLived, scope: .ancestorsOf("Donna")))
        #expect(Q.detect("who had the most children among rick's ancestors") == .superlative(kind: .mostChildren, scope: .ancestorsOf("Rick")))
        #expect(Q.detect("who is the oldest person among my ancestors") == .superlative(kind: .earliestBorn, scope: .ancestorsOf(nil)))
        #expect(Q.detect("who is the oldest ancestor of me") == .superlative(kind: .earliestBorn, scope: .ancestorsOf(nil)))
        #expect(Q.detect("find the earliest birth year for me") == .superlative(kind: .earliestBorn, scope: .ancestorsOf(nil)))
        #expect(Q.detect("who was the first person born in ireland among rick's ancestors")
                == .superlative(kind: .firstBornIn(place: "Ireland"), scope: .ancestorsOf("Rick")))
        #expect(Q.detect("who was the first person born in ireland for rick")
                == .superlative(kind: .firstBornIn(place: "Ireland"), scope: .ancestorsOf("Rick")))
        // Descendants.
        #expect(Q.detect("who is the youngest of rick's descendants") == .superlative(kind: .latestBorn, scope: .descendantsOf("Rick")))
        #expect(Q.detect("who is the youngest among my descendants") == .superlative(kind: .latestBorn, scope: .descendantsOf(nil)))
        #expect(Q.detect("who is the youngest descendant of patrick breen") == .superlative(kind: .latestBorn, scope: .descendantsOf("Patrick Breen")))
    }

    @Test func unscopedAndSurnameShapesAreUntouched() {
        // Sensor C, the detector half: the plain shapes read as they did.
        #expect(Q.detect("find the person in the family tree with the earliest birth date") == .superlative(kind: .earliestBorn, scope: .wholeTree))
        #expect(Q.detect("who is the oldest person in the family tree") == .superlative(kind: .earliestBorn, scope: .wholeTree))
        #expect(Q.detect("can you find the person in our family tree with the oldest birth year") == .superlative(kind: .earliestBorn, scope: .wholeTree))
        #expect(Q.detect("who is the oldest person in the breen family") == .superlative(kind: .earliestBorn, scope: .surname("breen")))
        #expect(Q.detect("who is the oldest breen") == .superlative(kind: .earliestBorn, scope: .surname("breen")))
        #expect(Q.detect("who was the first person born in ireland") == .superlative(kind: .firstBornIn(place: "Ireland"), scope: .wholeTree))
        // "for example" / "for real" are not people.
        #expect(Q.detect("who is the oldest person in the tree for example") == .superlative(kind: .earliestBorn, scope: .wholeTree))
        // Not ours at all.
        #expect(Q.detect("who was rick's oldest son") == nil)
        #expect(Q.detect("that is donna's line") == nil)
        #expect(Q.detect("i meant rick") == nil)
    }

    // MARK: A. Answers — the scope is walked, named and counted

    @Test func ricksAncestorsRankOnlyRicksAncestors() throws {
        let r = try answer(.earliestBorn, .ancestorsOf("Rick"))
        #expect(r.route == .graph)
        #expect(r.outcome == .answered)
        #expect(r.prose.hasPrefix("The earliest birth year among Richard Harding Breen Jr’s 6 recorded ancestors is born 1860: Patrick Breen"),
                Comment(rawValue: r.prose))
        #expect(!r.prose.contains("Gruffudd"))
        #expect(r.basisLine.contains("Ranked 6 of Richard Harding Breen Jr’s 6 recorded ancestors across 3 generations that record the fact."),
                Comment(rawValue: r.basisLine))
        #expect(r.catalogPersonName == "Patrick Breen")
        #expect(r.offeredActions == [.openFamilyTreePerson(personID: "@I13@", personName: "Patrick Breen")])
        #expect(r.superlative == .init(kind: .earliestBorn, scope: .ancestorsOf("Rick")))
    }

    @Test func richardResolvesToTheOwnerThroughTheFamilySearchPin() throws {
        // Live: "richard" is Rick (Jr), his father (Sr) and Donna's father
        // (Richard C Hudson). The owner's FamilySearch pin settles it.
        let r = try answer(.earliestBorn, .ancestorsOf("Richard"))
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.contains("Patrick Breen"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("Gruffudd"))
    }

    @Test func donnasAncestorsAndDescendantsAndTheOtherSide() throws {
        let donna = try answer(.earliestBorn, .ancestorsOf("Donna"))
        #expect(donna.prose.hasPrefix("The earliest birth year among Donna Hudson’s 5 recorded ancestors is born 780: Gruffudd ap Einion"),
                Comment(rawValue: donna.prose))
        let kids = try answer(.latestBorn, .descendantsOf("Rick"))
        #expect(kids.prose.hasPrefix("The latest birth year among Richard Harding Breen Jr’s 1 recorded descendant is born 1985: Tim Breen"),
                Comment(rawValue: kids.prose))
        #expect(kids.basisLine.contains("Ranked 1 of Richard Harding Breen Jr’s 1 recorded descendant across 1 generation"),
                Comment(rawValue: kids.basisLine))
        // The other side of Donna is the owner; the other side of the owner
        // is the spouse.
        let notDonna = try answer(.earliestBorn, .otherSideOf("Donna"))
        #expect(notDonna.prose.contains("Patrick Breen"), Comment(rawValue: notDonna.prose))
        #expect(notDonna.superlative?.scope == .ancestorsOf("Richard Harding Breen Jr"))
        let notRick = try answer(.earliestBorn, .otherSideOf(nil))
        #expect(notRick.prose.contains("Gruffudd ap Einion"), Comment(rawValue: notRick.prose))
        #expect(notRick.superlative?.scope == .ancestorsOf("Donna Hudson"))
        // Nobody to rank: honest, and still a superlative to correct.
        let none = try answer(.latestBorn, .descendantsOf("Tim Breen"))
        #expect(none.outcome == .declined)
        #expect(none.prose.contains("no children for Tim Breen"), Comment(rawValue: none.prose))
        #expect(none.superlative != nil)
    }

    // MARK: C. Sensor — the unscoped ask is byte-identical to before

    @Test func theUnscopedSuperlativeStillRanksTheWholeTreeWordForWord() throws {
        guard case .answer(let r) = pre("find the person in the family tree with the earliest birth date") else {
            Issue.record("the superlative went to the translator"); return
        }
        #expect(r.prose == "The earliest birth year in the family tree is born 780: Gruffudd ap Einion — born ABT 0780 in Wales; parent of William S Hudson.",
                Comment(rawValue: r.prose))
        #expect(r.basisLine == "Basis: imported family tree (GEDCOM). Ranked 14 of 14 people in the family tree that record the fact.",
                Comment(rawValue: r.basisLine))
        #expect(r.queryDescription == "superlative: earliestBorn scope=wholeTree → Gruffudd ap Einion")
        #expect(r.offeredActions == [.openFamilyTreePerson(personID: "@I24@", personName: "Gruffudd ap Einion")])
    }

    // MARK: B. The scope correction right after

    @Test func thatIsDonnasLineRerunsTheRankingOverRicksAncestors() throws {
        var memory = Exec.ConversationMemory()
        let first = try #require(turn("find the person in the family tree with the earliest birth date", memory: &memory))
        #expect(first.prose.contains("Gruffudd"))
        #expect(memory.lastSuperlative == .init(kind: .earliestBorn, scope: .wholeTree))

        let corrected = try #require(turn("that is donna's line", memory: &memory))
        #expect(corrected.route == .graph)
        #expect(corrected.outcome == .answered)
        #expect(corrected.prose.hasPrefix("The earliest birth year among Richard Harding Breen Jr’s 6 recorded ancestors is born 1860: Patrick Breen"),
                Comment(rawValue: corrected.prose))
        #expect(!corrected.prose.contains("Donna Hudson was born"))
        #expect(corrected.queryDescription?.hasPrefix("superlative: earliestBorn scope=ancestorsOf") == true,
                Comment(rawValue: corrected.queryDescription ?? "nil"))
        // The corrected answer is itself a superlative, so a second
        // correction works.
        #expect(memory.lastSuperlative?.kind == .earliestBorn)
        let back = try #require(turn("that is rick's line", memory: &memory))
        #expect(back.prose.contains("Gruffudd ap Einion"), Comment(rawValue: back.prose))
    }

    @Test func everyCorrectionPhraseRerunsTheSameKind() throws {
        let phrases: [(String, String)] = [
            ("that person b. 780 is donna's ancestor, not mine. I want mine", "Patrick Breen"),
            ("that's not my side", "Patrick Breen"),
            ("i meant rick", "Patrick Breen"),
            ("no, i meant for rick", "Patrick Breen"),
            ("for rick", "Patrick Breen"),
            ("i want mine", "Patrick Breen"),
            ("those are donna's ancestors", "Patrick Breen"),
            ("that's donna's side", "Patrick Breen"),
            ("i meant donna", "Gruffudd ap Einion"),
            ("what about donna's side", "Gruffudd ap Einion"),
            ("that is rick's line", "Gruffudd ap Einion"),
        ]
        for (phrase, expected) in phrases {
            var memory = Exec.ConversationMemory()
            _ = try #require(turn("who lived the longest in the family tree", memory: &memory))
            // The KIND is kept: longest-lived, not earliest-born.
            guard let r = turn(phrase, memory: &memory) else {
                Issue.record("\"\(phrase)\" went to the translator"); continue
            }
            #expect(r.route == .graph, Comment(rawValue: phrase))
            #expect(r.queryDescription?.hasPrefix("superlative: longestLived") == true,
                    Comment(rawValue: "\(phrase) → \(r.queryDescription ?? "nil")"))
            // Nobody in this fixture has a death year but Richard Sr (Rick's
            // side), so the longest-lived among Rick's ancestors is him, and
            // Donna's side declines honestly — either way the scope is what
            // the correction asked for.
            let scopeSays = r.prose.contains("Richard Harding Breen Jr’s") || r.basisLine.contains("Richard Harding Breen Jr’s")
            let donnaSays = r.prose.contains("Donna Hudson’s") || r.basisLine.contains("Donna Hudson’s")
            if expected == "Patrick Breen" {
                #expect(scopeSays, Comment(rawValue: "\(phrase) → \(r.prose) | \(r.basisLine)"))
            } else {
                #expect(donnaSays, Comment(rawValue: "\(phrase) → \(r.prose) | \(r.basisLine)"))
            }
        }
    }

    @Test func aCorrectionWithNoSuperlativeToCorrectIsNotClaimed() {
        // Fresh conversation: nothing to correct, the words route as before.
        if case .answer(let r) = pre("that is donna's line") {
            Issue.record("claimed with nothing remembered: \(r.queryDescription ?? r.prose)")
        }
        // After a non-superlative tree answer the memory is empty too.
        var memory = Exec.ConversationMemory()
        _ = turn("who is the oldest person in the family tree", memory: &memory)
        #expect(memory.lastSuperlative != nil)
        let bio = Exec.Result(route: .graph, outcome: .answered, prose: "Donna Hudson was born 1959.",
                              basisLine: "Basis: fixture.", queryDescription: "shape=graph operation=familyTree person=donna",
                              citations: [], catalogPersonName: "Donna Hudson")
        memory.record(intent: nil, result: bio, question: "tell me about donna")
        #expect(memory.lastSuperlative == nil)
        if case .answer(let r) = pre("that is donna's line", memory: memory) {
            Issue.record("claimed after the memory was cleared: \(r.queryDescription ?? r.prose)")
        }
    }

    @Test func aFreshScopedQuestionIsNeverReadAsACorrection() throws {
        // With a superlative remembered, a new superlative question that
        // happens to name a side is the new question, not a correction of
        // the old one's kind.
        var memory = Exec.ConversationMemory()
        _ = try #require(turn("who lived the longest in the family tree", memory: &memory))
        let r = try #require(turn("who is the oldest person on donna's side", memory: &memory))
        #expect(r.queryDescription?.hasPrefix("superlative: earliestBorn scope=ancestorsOf") == true,
                Comment(rawValue: r.queryDescription ?? "nil"))
    }
}
