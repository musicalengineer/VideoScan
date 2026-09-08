// HallieTreeStatisticsAnswerTests.swift
// The whole path — question → detect → answer → prose — for the spreadsheet
// questions, so the denominator contract is proven at the sentence, not just
// in the engine. Rick's live sentence from 2026-09-07 is the first case.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Rick /Breen/
1 SEX M
1 BIRT
2 DATE 1959
2 PLAC Boston, Massachusetts, United States
1 FAMC @F1@
0 @I2@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 1930
2 PLAC Chelsea, Massachusetts, United States
1 DEAT
2 DATE 2023
1 FAMS @F1@
1 FAMC @F2@
0 @I3@ INDI
1 NAME Mary /O'Connor/
1 SEX F
1 BIRT
2 DATE 1900
2 PLAC Cork, Ireland
1 DEAT
2 DATE 1975
1 FAMS @F2@
0 @I4@ INDI
1 NAME John /Hastings/
1 SEX M
1 BIRT
2 DATE 1372
2 PLAC Kenilworth, Warwickshire, England
1 DEAT
2 DATE 1389
0 @I5@ INDI
1 NAME Yankee /Birth/
1 SEX M
1 BIRT
2 DATE 1700
2 PLAC Boston, New England
0 @I6@ INDI
1 NAME Unrecorded /Person/
1 SEX F
0 @F1@ FAM
1 WIFE @I2@
1 CHIL @I1@
0 @F2@ FAM
1 WIFE @I3@
1 CHIL @I2@
0 TRLR
"""

@Suite("Tree statistics — the sentence carries the denominator")
struct HallieTreeStatisticsAnswerTests {
    private typealias Exec = HallieTurnExecutor
    let graph = GedcomFamilyGraph(gedcomText: tree)
    private var context: Exec.Context {
        Exec.Context(profiles: [], graph: graph,
                     speakers: .init(ownerName: "Rick", archivistName: nil, archivistPersonName: nil))
    }
    private func answer(_ question: String) -> Exec.Result? {
        guard case .answer(let r) = Exec.preTranslation(
            question: question, playAfterAnswer: false, memory: .init(), isKnownPerson: { _ in false },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) }) else { return nil }
        return r
    }

    /// RICK'S SENTENCE. England means England — the New England birth is not
    /// counted — and the person with no birthplace is named, not vanished.
    @Test func rickSentenceCountsEnglandOnly() throws {
        let r = try #require(answer("how many people in the tree were born in england in total?"))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("1 of the 6 people"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("recorded as England"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("1 have no record"), Comment(rawValue: r.prose))
    }

    @Test func aCountryCountNamesWhatCouldNotBePlaced() throws {
        let r = try #require(answer("how many people in the tree were born in ireland"))
        #expect(r.prose.hasPrefix("1 of the 6 people"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("in Ireland"), Comment(rawValue: r.prose))
        // The "New England" record has a birthplace the classifier can place
        // (United States), so nothing is unclassifiable here — only the one
        // with no birthplace at all is reported.
        #expect(r.prose.contains("1 have no record"), Comment(rawValue: r.prose))
    }

    @Test func zeroIsAnAnswerWithADenominator() throws {
        let r = try #require(answer("how many people in the tree were born in norway"))
        #expect(r.outcome == .answered)
        #expect(r.prose.hasPrefix("None of the 6 people"), Comment(rawValue: r.prose))
    }

    @Test func lifespanStatesItsPopulation() throws {
        let r = try #require(answer("what is the average lifespan of people in the tree"))
        // Eileen 93, Mary 75, John 17 → mean 61.7, median 75; three others lack a year.
        #expect(r.prose.contains("Across the 3 of the 6 people"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("61.7 years"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("median 75"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("3 more lack"), Comment(rawValue: r.prose))
    }

    @Test func ancestorScopeIsTheOwnersLineNotTheTree() throws {
        let r = try #require(answer("how many of my ancestors were born in ireland"))
        #expect(r.prose.hasPrefix("1 of your 2 recorded ancestors"), Comment(rawValue: r.prose))
    }

    @Test func groupedCountriesCommonestFirst() throws {
        let r = try #require(answer("which countries were people in the tree born in"))
        #expect(r.prose.contains("United States (3)"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("Ireland (1)"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("1 have no birthplace recorded"), Comment(rawValue: r.prose))
    }

    /// The recognizer's abstentions reach the route as NOT ours — the
    /// question goes on to the translator rather than being answered narrowly.
    @Test func anUnsupportedConstraintIsNotAnsweredHere() {
        #expect(HallieLineageQuestion.detect("how many people born in ireland married a breen") == nil
                || {
                    if case .treeStatistics = HallieLineageQuestion.detect("how many people born in ireland married a breen") { return false }
                    return true
                }())
    }
}
