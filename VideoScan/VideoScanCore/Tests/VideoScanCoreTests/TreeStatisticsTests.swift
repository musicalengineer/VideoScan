// TreeStatisticsTests.swift
// Rick, 2026-09-07: "like asking an excel spreadsheet to compute averages,
// medians ... compute average ages for groups, how many people live in what
// location."
//
// The contract these tests exist to hold: EVERY figure carries its
// denominator. On Rick's real tree 11,920 of 16,383 people have a computable
// lifespan, so "57.5 years" without "over 11,920 people" is an invented
// coverage claim.

import Foundation
import Testing
@testable import VideoScanCore

private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Rick /Breen/
1 SEX M
1 BIRT
2 DATE 1959
2 PLAC Boston, Suffolk, Massachusetts, United States
1 FAMC @F1@
0 @I2@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 1930
2 PLAC Chelsea, Suffolk, Massachusetts, United States
1 DEAT
2 DATE 2023
1 FAMS @F1@
1 FAMC @F2@
0 @I3@ INDI
1 NAME Richard /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 1929
2 PLAC Boston, Suffolk, Massachusetts, United States
1 DEAT
2 DATE 2008
1 FAMS @F1@
0 @I4@ INDI
1 NAME Mary Catherine /O'Connor/
1 SEX F
1 BIRT
2 DATE 1900
2 PLAC Ireland
1 DEAT
2 DATE 1975
1 FAMS @F2@
0 @I5@ INDI
1 NAME Patrick /O'Connor/
1 SEX M
1 BIRT
2 DATE 1895
2 PLAC Cork, Ireland
1 DEAT
2 DATE 1960
1 FAMS @F2@
0 @I6@ INDI
1 NAME Unrecorded /Person/
1 SEX F
0 @I7@ INDI
1 NAME Colonial /Ancestor/
1 SEX M
1 BIRT
2 DATE 1700
2 PLAC Boston, Massachusetts Bay Colony, British Colonial America
0 @I8@ INDI
1 NAME Ambiguous /Place/
1 SEX M
1 BIRT
2 DATE 1750
2 PLAC New France
0 @F1@ FAM
1 HUSB @I3@
1 WIFE @I2@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I5@
1 WIFE @I4@
1 CHIL @I2@
0 TRLR
"""

@Suite("Tree statistics — spreadsheet questions, with denominators")
struct TreeStatisticsTests {
    let graph = GedcomFamilyGraph(gedcomText: tree)
    private typealias Stats = TreeStatistics

    /// "how many people were born in Ireland?"
    @Test func countByCountry() {
        let c = Stats.count(Stats.Query(place: .country("Ireland")), in: graph)
        #expect(c.matched == 2, "Ireland and Cork, Ireland")
        #expect(c.considered == 8, "the whole tree is the denominator")
        #expect(c.unrecorded == 1, "one person has no birthplace at all")
        #expect(c.unclassifiable == 1, "New France is recorded but spans today's borders")
    }

    /// codex #1181: the first version filtered undated people out BEFORE
    /// counting, so "born before 1800" over a pool of one dated and one undated
    /// person reported 1 of 1 and looked complete. The denominator is the
    /// population; the undated person is reported, not vanished.
    @Test func anUndatedPersonIsReportedNotDropped() {
        let two = """
        0 HEAD
        0 @I1@ INDI
        1 NAME Dated /Person/
        1 BIRT
        2 DATE 1700
        0 @I2@ INDI
        1 NAME Undated /Person/
        0 TRLR
        """
        let g = GedcomFamilyGraph(gedcomText: two)
        let c = Stats.count(Stats.Query(time: .init(bornTo: 1799)), in: g)
        #expect(c.matched == 1)
        #expect(c.considered == 2, "both people were asked about")
        #expect(c.unrecorded == 1, "the undated one is the gap an honest sentence names")
    }

    /// codex #1180: `recordedText("england")` as a SUBSTRING matched "New
    /// England", so a count of English births would have swallowed
    /// Massachusetts. A recorded-text filter matches a whole comma-separated
    /// component, never a substring.
    @Test func recordedTextMatchesAWholeComponentNeverASubstring() {
        let mixed = """
        0 HEAD
        0 @I1@ INDI
        1 NAME English /Birth/
        1 BIRT
        2 PLAC Kenilworth, Warwickshire, England
        0 @I2@ INDI
        1 NAME Yankee /Birth/
        1 BIRT
        2 PLAC Boston, New England
        0 @I3@ INDI
        1 NAME Irish /Birth/
        1 BIRT
        2 PLAC Cork, Ireland
        0 TRLR
        """
        let g = GedcomFamilyGraph(gedcomText: mixed)
        #expect(Stats.count(Stats.Query(place: .recordedText("england")), in: g).matched == 1)
        #expect(Stats.count(Stats.Query(place: .recordedText("new england")), in: g).matched == 1)
        #expect(Stats.count(Stats.Query(place: .recordedText("ireland")), in: g).matched == 1,
                "a component that IS the word still matches")
        #expect(Stats.count(Stats.Query(place: .recordedText("cork")), in: g).matched == 1)
    }

    /// "how many were born in Europe?" — the question that started all this.
    /// Ireland IS Europe.
    @Test func countByContinent() {
        let c = Stats.count(Stats.Query(place: .continent(.europe)), in: graph)
        #expect(c.matched == 2, Comment(rawValue: "matched \(c.matched)"))
    }

    /// "how many were born outside the US?"
    @Test func countOutsideACountry() {
        let c = Stats.count(Stats.Query(place: .outsideCountry("United States")), in: graph)
        #expect(c.matched == 2, "the two Irish births; colonial America is not 'outside'")
    }

    /// A raw recorded region the classifier does not model as a country.
    @Test func countByRecordedText() {
        let c = Stats.count(Stats.Query(place: .recordedText("Suffolk")), in: graph)
        #expect(c.matched == 3)
    }

    /// EVERY FIGURE CARRIES ITS DENOMINATOR. Four of eight people have both
    /// years; the summary must say so rather than quietly averaging four.
    @Test func lifespanReportsWhatItCouldNotMeasure() throws {
        let s = try #require(Stats.lifespan(Stats.Query(), in: graph))
        #expect(s.count == 4, "Eileen 93, Richard 79, Mary 75, Patrick 65")
        #expect(s.considered == 8)
        #expect(s.unrecorded == 4, "the denominator gap an answer must state")
        #expect(s.minimum == 65)
        #expect(s.maximum == 93)
        #expect(abs(s.mean - 78.0) < 0.001)
        #expect(abs(s.median - 77.0) < 0.001, "even count → mean of the middle two")
    }

    /// "average age for a group": the same statistic, narrowed.
    @Test func lifespanOfAGroup() throws {
        let irish = try #require(
            Stats.lifespan(Stats.Query(place: .country("Ireland")), in: graph))
        #expect(irish.count == 2)
        #expect(abs(irish.mean - 70.0) < 0.001, "75 and 65")
    }

    /// An implausible span is treated as unrecorded, never averaged in — a
    /// twenty-generation tree carries transcription errors and one 900-year
    /// life would move a mean people will quote.
    @Test func animpossibleLifespanIsNotAveragedIn() throws {
        let broken = tree.replacingOccurrences(of: "1 NAME Patrick /O'Connor/",
                                               with: "1 NAME Patrick /O'Connor/")
            .replacingOccurrences(of: "2 DATE 1895", with: "2 DATE 1095")
        let g = GedcomFamilyGraph(gedcomText: broken)
        let s = try #require(Stats.lifespan(Stats.Query(), in: g))
        #expect(s.count == 3, "the 865-year life is dropped, not averaged")
        #expect(s.unrecorded == 5)
    }

    /// "how many people live in what location" — grouped, commonest first,
    /// with ambiguous and unrecorded places kept OUT of the rows and
    /// reported on their own.
    @Test func countriesAreGroupedAndTheOddOnesReportedSeparately() {
        let result = Stats.birthCountries(Stats.Query(), in: graph)
        #expect(result.rows.first?.country == "United States")
        #expect(result.rows.first?.count == 4, "colonial America maps to the United States")
        #expect(result.rows.contains { $0.country == "Ireland" && $0.count == 2 })
        #expect(result.ambiguous == 1, "New France spanned today's borders")
        #expect(result.unrecorded == 1)
    }

    /// SCOPE IS NOT COSMETIC. Rick's ancestors are not the whole tree, and
    /// conflating them is the hazard codex flagged.
    @Test func ancestorScopeDiffersFromTheWholeTree() {
        let all = Stats.count(Stats.Query(place: .country("Ireland")), in: graph)
        let mine = Stats.count(
            Stats.Query(scope: .ancestors(of: "@I1@", maxGenerations: 10),
                        place: .country("Ireland")), in: graph)
        #expect(all.considered == 8)
        #expect(mine.considered == 4, "four ancestors, not eight people")
        #expect(mine.matched == 2)
        let none = Stats.count(
            Stats.Query(scope: .ancestors(of: "@I4@", maxGenerations: 10),
                        place: .country("Ireland")), in: graph)
        #expect(none.considered == 0, "Mary has no recorded parents")
    }

    @Test func descendantScopeWalksDown() {
        let c = Stats.count(Stats.Query(scope: .descendants(of: "@I4@", maxGenerations: 10)),
                            in: graph)
        #expect(c.considered == 2, "Eileen and Rick")
    }

    /// A time filter, and people with no birth year are excluded from it
    /// rather than assumed in range.
    @Test func timeFilterExcludesUndatedPeople() {
        let c = Stats.count(Stats.Query(time: .init(bornFrom: 1900, bornTo: 1999)), in: graph)
        #expect(c.matched == 4, "1959, 1930, 1929, 1900")
        #expect(c.considered == 8)
        #expect(c.unrecorded == 1, "the person with no birth year, reported rather than dropped")
    }

    /// An empty result is an ANSWER, not an error, and still reports its
    /// denominator so the prose can say "none of 8".
    @Test func zeroMatchesStillCarriesItsDenominator() {
        let c = Stats.count(Stats.Query(place: .country("Norway")), in: graph)
        #expect(c.matched == 0)
        #expect(c.considered == 8)
        #expect(Stats.lifespan(Stats.Query(place: .country("Norway")), in: graph) == nil,
                "no population → no statistic, rather than a zero that reads as a fact")
    }

    /// The listing is stable across runs so "show me more" pages the same way.
    @Test func theListingOrderIsStable() {
        let first = Stats.people(matching: Stats.Query(place: .country("Ireland")), in: graph)
        let again = Stats.people(matching: Stats.Query(place: .country("Ireland")), in: graph)
        #expect(first.map(\.id) == again.map(\.id))
        #expect(first.map(\.id) == first.map(\.id).sorted())
    }
}

/// The project's scale rule: anything that iterates records gets 100k and a
/// stated budget. Rick's real tree is 16,383 people; Donna's is 58,464.
@Suite("Tree statistics — 100k scale")
struct TreeStatisticsScaleTests {
    @Test func oneHundredThousandPeopleStayUnderBudget() throws {
        var text = "0 HEAD\n"
        let countries = ["Ireland", "England", "United States", "France"]
        for i in 0..<100_000 {
            text += "0 @I\(i)@ INDI\n1 NAME Person\(i) /Scale/\n1 SEX M\n1 BIRT\n"
            text += "2 DATE \(1600 + i % 400)\n2 PLAC Town, \(countries[i % 4])\n"
            text += "1 DEAT\n2 DATE \(1600 + i % 400 + 60)\n"
        }
        text += "0 TRLR\n"
        let graph = GedcomFamilyGraph(gedcomText: text)
        #expect(graph.people.count == 100_000)

        let started = Date()
        let count = TreeStatistics.count(
            TreeStatistics.Query(place: .country("Ireland")), in: graph)
        let span = try #require(TreeStatistics.lifespan(TreeStatistics.Query(), in: graph))
        let grouped = TreeStatistics.birthCountries(TreeStatistics.Query(), in: graph)
        let elapsed = Date().timeIntervalSince(started)

        #expect(count.matched == 25_000)
        #expect(span.count == 100_000)
        #expect(abs(span.mean - 60.0) < 0.001)
        #expect(grouped.rows.count == 4)
        // Generous on purpose: this runs beside builds and a model host, and
        // a budget that fails on a busy machine teaches people to ignore it.
        #expect(elapsed < 10.0, Comment(rawValue: "three full passes took \(elapsed)s"))
    }
}
