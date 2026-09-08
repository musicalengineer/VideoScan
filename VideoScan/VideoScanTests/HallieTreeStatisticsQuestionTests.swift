// HallieTreeStatisticsQuestionTests.swift
// Rick, live 2026-09-07:
//   "how many people in the tree were born in england in total?"
//   → "The family tree has 49 people named England — which one?"
// The engine existed; nothing could reach it.
//
// This is the first recognizer written to codex's rule: recognized only when
// the FULL shape is accounted for, otherwise ABSTAIN. Most of these tests are
// about the abstaining, because that is the part that decides whether the
// design is better than the cue-spotting guards it replaces.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Tree statistics — recognized, or abstained")
struct HallieTreeStatisticsQuestionTests {
    private typealias Q = HallieTreeStatisticsQuestion

    private func place(_ question: String) -> TreeStatistics.PlaceFilter? {
        Q.detect(question)?.query.place
    }

    /// RICK'S OWN SENTENCES, both phrasings.
    /// RICK'S OWN SENTENCES, both phrasings — and "England" must mean
    /// England. The classifier maps it to "United Kingdom", which is right for
    /// continent membership and wrong for counting: it would answer with the
    /// whole UK (13,622) where Rick asked about England (11,280).
    @Test func theQuestionsRickAsked() throws {
        let a = try #require(Q.detect("how many people in the tree were born in england in total?"))
        #expect(a.query.place == .recordedText("england"), Comment(rawValue: "\(a.query.place)"))
        let b = try #require(Q.detect("how many people in the tree have a birthplace in the coubtry of england ?"))
        #expect(b.query.place == .recordedText("england"), Comment(rawValue: "\(b.query.place)"))
        #expect(Q.detect("how many people were born in scotland")?.query.place == .recordedText("scotland"))
        // Rick's typo is load-bearing here: "coubtry" defeats the "country
        // of" pattern, so the captured phrase carries noise and only a
        // last-word check catches England inside it.
        #expect(Q.detect("how many people were born in the country of england")?.query.place
                == .recordedText("england"))
        #expect(Q.detect("how many people were born in wales")?.query.place == .recordedText("wales"))
        // AND the trap my own first fix walked into: "New England" ends with
        // "england" but is Massachusetts, not England. It must never become
        // the England filter.
        #expect(Q.detect("how many people were born in new england")?.query.place
                == .recordedText("new england"))
    }

    @Test func theOtherShapesRickNamed() throws {
        // "how many people were born before 1800"
        let before = try #require(Q.detect("how many people were born before 1800"))
        #expect(before.query.time.bornTo == 1799)
        // "average age of people"
        let avg = try #require(Q.detect("what is the average lifespan of people in the tree"))
        if case .lifespan = avg {} else { Issue.record("expected a lifespan summary") }
        // grouped
        let grouped = try #require(Q.detect("which countries were people in the tree born in"))
        if case .birthCountries = grouped {} else { Issue.record("expected grouped countries") }
    }

    @Test func placesAreClassifiedOrKeptAsRecordedText() {
        #expect(place("how many people were born in ireland") == .country("Ireland"))
        #expect(place("how many people in the tree were born in europe") == .continent(.europe))
        #expect(place("how many people were born outside the united states")
                == .outsideCountry(BirthplaceClassifier.unitedStates))
        #expect(place("how many people were born abroad")
                == .outsideCountry(BirthplaceClassifier.unitedStates))
        // "New England" classifies as the United States, and using THAT
        // filter would count every American birth (codex #1180). A region
        // matches the recorded components as written; only a country named
        // as itself gets the country filter.
        #expect(place("how many people were born in new england") == .recordedText("new england"))
        #expect(place("how many people were born in massachusetts") == .recordedText("massachusetts"))
        #expect(place("how many people were born in the usa") == .country(BirthplaceClassifier.unitedStates))
        #expect(place("how many people were born in france") == .country("France"))
        // No place named at all is a fine whole-tree question.
        #expect(place("how many people are in the family tree") == .anywhere)
    }

    @Test func timeFiltersAreRead() throws {
        #expect(try #require(Q.detect("how many people were born after 1900")).query.time.bornFrom == 1901)
        let between = try #require(Q.detect("how many people were born between 1700 and 1800"))
        #expect(between.query.time.bornFrom == 1700)
        #expect(between.query.time.bornTo == 1800)
        let decade = try #require(Q.detect("how many people in the tree were born in the 1840s"))
        #expect(decade.query.time.bornFrom == 1840)
        #expect(decade.query.time.bornTo == 1849)
    }

    /// SCOPE. Whole tree and ancestors-only are different answers.
    @Test func ancestorScopeIsDistinguished() throws {
        let mine = try #require(Q.detect("how many of my ancestors were born in ireland"))
        if case .ancestors = mine.query.scope {} else {
            Issue.record("expected ancestor scope, got \(mine.query.scope)")
        }
        let all = try #require(Q.detect("how many people in the tree were born in ireland"))
        #expect(all.query.scope == .wholeTree)
    }

    // MARK: - Abstention: the point of the design

    /// A constraint we cannot represent must ABSTAIN, never be dropped. "born
    /// in Ireland who married a Breen" is not a place count with the marriage
    /// quietly ignored.
    @Test func anUnsupportedConstraintAbstains() {
        #expect(Q.detect("how many people born in ireland married a breen") == nil)
        #expect(Q.detect("how many people in the tree have photos") == nil)
        #expect(Q.detect("how many people in the tree appear in videos") == nil)
        #expect(Q.detect("how many people were born in ireland per generation") == nil)
        #expect(Q.detect("how many people named smythe are in the tree") == nil)
        #expect(Q.detect("how many children did people in the tree have on average") == nil)
    }

    /// codex #1180: three constraints the first version silently DROPPED,
    /// answering a whole-tree count that read as complete.
    @Test func theConstraintsCodexFoundLeaking() throws {
        #expect(Q.detect("how many people in the tree are alive") == nil, "alive is not a filter we hold")
        #expect(Q.detect("how many people are still living") == nil)
        #expect(Q.detect("how many of my maternal ancestors were born in ireland") == nil,
                "a SIDE is a constraint Scope.ancestors cannot hold")
        let year = try #require(Q.detect("how many people were born in 1800"))
        #expect(year.query.time.bornFrom == 1800)
        #expect(year.query.time.bornTo == 1800)
        #expect(Q.detect("how many people were born in ireland per generation") == nil)
        #expect(Q.detect("how many generations back were people born in ireland") == nil)
    }

    /// A period we cannot parse abstains rather than answering as though no
    /// date had been mentioned — the failure that would look like a correct
    /// whole-tree count.
    @Test func anUnparsedPeriodAbstains() {
        #expect(Q.detect("how many people in the tree were born in the nineteenth century") == nil)
        #expect(Q.detect("how many people in the tree were born in medieval times") == nil)
    }

    /// A place we cannot classify at all abstains: "0 people were born in
    /// Ruritania" would be a confident lie about the tree when we simply
    /// failed to read the word.
    @Test func anUnreadablePlaceAbstains() {
        #expect(Q.detect("how many people were born in a place i cannot spell properly at all") == nil)
    }

    /// Questions about ONE PERSON that happen to start with "how many".
    @Test func singlePersonQuestionsAreNotStatistics() {
        #expect(Q.detect("how many children did Edward III have") == nil)
        #expect(Q.detect("how many brothers did he have") == nil)
        #expect(Q.detect("how many generations back to Ireland") == nil)
    }

    /// And ordinary questions are untouched.
    @Test func ordinaryQuestionsAreNotClaimed() {
        #expect(Q.detect("tell me about Edward III") == nil)
        #expect(Q.detect("where was John Hastings born") == nil)
        #expect(Q.detect("how are we related to king henry the 8th") == nil)
        #expect(Q.detect("show me videos from 2005") == nil)
        #expect(Q.detect("what is the average of these numbers") == nil)
    }
}
