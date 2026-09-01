import Testing
import Foundation
@testable import VideoScan

// MARK: - Splitting a conjunction into questions Hallie can actually answer
//
// Rick, 2026-09-01. The measured failure this exists for:
//
//   "who was Martha Lamson and do we have any videos of her"
//     -> query: media ask: pronoun her (no subject)
//
// One shape survived, the other clause was dropped, and the pronoun lost an
// antecedent that was six words away in the same sentence.
//
// The risk of the fix is OVER-splitting: "who was X and where was she born"
// already answers well as one biography, and replacing that with two thinner
// answers would be a regression. So most of these tests are about NOT
// splitting.

struct HallieQuestionSplitterTests {

    // MARK: The case that broke

    @Test func aCrossShapeConjunctionSplitsAndBindsThePronoun() throws {
        let parts = try #require(
            HallieQuestionSplitter.split("who was Martha Lamson and do we have any videos of her"))
        #expect(parts.count == 2)
        #expect(parts[0] == "who was Martha Lamson")
        #expect(parts[1].contains("Martha Lamson"),
                "the pronoun must be bound to the name in the same sentence: \(parts[1])")
        #expect(!parts[1].lowercased().contains(" her"),
                "'her' must be gone, not merely accompanied: \(parts[1])")
    }

    @Test func theBoundClauseStillReadsAsItsOwnQuestion() throws {
        let parts = try #require(
            HallieQuestionSplitter.split("who was Martha Lamson and do we have any videos of her"))
        #expect(parts[1].hasPrefix("do we have"))
    }

    // MARK: Rick's second example (2026-09-01): place and date

    @Test func aPlaceAndADateQuestionSplitAndBothCarryTheName() throws {
        let parts = try #require(
            HallieQuestionSplitter.split("where was Martha Lamson born and when was she born"))
        #expect(parts.count == 2)
        #expect(parts[0].hasPrefix("where was"))
        #expect(parts[1].hasPrefix("when was"))
        #expect(parts[0].contains("Martha Lamson"))
        #expect(parts[1].contains("Martha Lamson"),
                "'she' must be bound to the name from the first clause: \(parts[1])")
    }

    @Test func withNoNameInTheLineThePronounSurvivesTheSplit() throws {
        // "did she have kids" is `.other` (no kind word), "where did she
        // live" is `.place`; both open like questions, so the line splits.
        // There is no capitalised name to bind, so `she` is left in BOTH
        // clauses on purpose — the caller runs clause 2 against the memory
        // clause 1 wrote, and if nobody was named the normal "who do you
        // mean?" decline still applies. The splitter must never invent one.
        let parts = try #require(
            HallieQuestionSplitter.split("did she have kids and where did she live"))
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { $0.lowercased().contains("she") })
        #expect(parts[0] == "did she have kids")
        #expect(parts[1] == "where did she live")
    }

    // MARK: Not splitting — the larger half of the job

    @Test func sameShapeConjunctionsAreLeftAlone() {
        // Both halves are about the person; `biography` already carries the
        // birthplace, so one rich answer beats two thin ones.
        #expect(HallieQuestionSplitter.split("who was Martha Lamson and who were her parents") == nil)
    }

    @Test func aCompoundNounPhraseIsNotTwoQuestions() {
        #expect(HallieQuestionSplitter.split("show me Rick and Donna") == nil)
        #expect(HallieQuestionSplitter.split("who are Rick and Donna") == nil)
        // "Mark together" is not a question, so "Dan and Mark" stays one
        // noun phrase — the media query must see both names.
        #expect(HallieQuestionSplitter.split("find the videos with Dan and Mark together") == nil)
    }

    @Test func aPlaceNameContainingAndIsNotASplit() {
        #expect(HallieQuestionSplitter.split("where is Stratford and Avon") == nil)
    }

    @Test func aBareFragmentAfterAndIsNotAQuestion() {
        #expect(HallieQuestionSplitter.split("who was Martha Lamson and tall") == nil)
        #expect(HallieQuestionSplitter.split("show me Donna and the dog") == nil)
    }

    @Test func aPlainQuestionIsUntouched() {
        #expect(HallieQuestionSplitter.split("who was Martha Lamson") == nil)
        #expect(HallieQuestionSplitter.split("do we have any videos of Donna") == nil)
    }

    @Test func anAbsurdlyLongLineIsLeftToTheNormalPath() {
        #expect(HallieQuestionSplitter.split(String(repeating: "who was x and ", count: 40)) == nil)
    }

    // MARK: The switch

    @Test func theSwitchIsOnUnlessTheKillSwitchIsSet() {
        // Never mutate the process environment from a test: it is shared
        // with every other test in this host. Assert the contract against
        // whatever the environment IS — unset means on, "0" means off,
        // anything else means on — so the test is honest under a harness
        // that set the variable and is not skipped for it.
        let value = ProcessInfo.processInfo.environment["VIDEOSCAN_HALLIE_SPLIT"]
        #expect(HallieQuestionSplitter.isEnabled == (value != "0"))
        if value == nil {
            #expect(HallieQuestionSplitter.isEnabled, "the default is ON everywhere")
        }
    }

    // MARK: Bounds

    @Test func atMostThreeClausesAreAccepted() {
        let four = "who was Martha Lamson and where was she born and when did she die "
                 + "and do we have any videos of her"
        // Four clauses is a dictated list; the single-query path handles it
        // no worse and without a wall of answers.
        #expect(HallieQuestionSplitter.split(four) == nil)
    }

    @Test func threeClausesOfDifferentKindsSplit() throws {
        let parts = try #require(HallieQuestionSplitter.split(
            "who was Martha Lamson and where was she born and do we have any videos of her"))
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { !$0.isEmpty })
    }

    // MARK: The pieces, tested directly

    @Test func nameDetectionNeedsTwoCapitalisedWords() {
        #expect(HallieQuestionSplitter.firstPersonName(in: ["who was Martha Lamson"])
                == "Martha Lamson")
        // One capital is too weak — "Who" and "Rick" alike would qualify.
        #expect(HallieQuestionSplitter.firstPersonName(in: ["who was Martha"]) == nil)
        #expect(HallieQuestionSplitter.firstPersonName(in: ["who was she"]) == nil)
    }

    @Test func onlyTheFirstPronounInAClauseIsBound() {
        // "her mother and her father" must not become "Martha Lamson mother
        // and Martha Lamson father".
        let bound = HallieQuestionSplitter.bindPronouns(
            in: ["who was Martha Lamson", "who were her mother and her father"])
        #expect(bound[1].contains("Martha Lamson"))
        #expect(bound[1].lowercased().contains("her father"),
                "the second pronoun stays: \(bound[1])")
    }

    @Test func withNoNameThePronounIsLeftForTheNormalDecline() {
        let bound = HallieQuestionSplitter.bindPronouns(
            in: ["who was she", "do we have videos of her"])
        #expect(bound[1].lowercased().contains("her"),
                "no antecedent means Hallie's existing 'who do you mean?' still applies")
    }

    @Test func kindsAreCoarseAndSafe() {
        #expect(HallieQuestionSplitter.kind("do we have any videos of her") == .media)
        #expect(HallieQuestionSplitter.kind("where was she born") == .place)
        #expect(HallieQuestionSplitter.kind("when did she die") == .date)
        #expect(HallieQuestionSplitter.kind("who was Martha Lamson") == .person)
    }
}
