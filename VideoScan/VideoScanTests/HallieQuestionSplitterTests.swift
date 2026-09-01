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

    // MARK: Not splitting — the larger half of the job

    @Test func sameShapeConjunctionsAreLeftAlone() {
        // Both halves are about the person; `biography` already carries the
        // birthplace, so one rich answer beats two thin ones.
        #expect(HallieQuestionSplitter.split("who was Martha Lamson and who were her parents") == nil)
    }

    @Test func aCompoundNounPhraseIsNotTwoQuestions() {
        #expect(HallieQuestionSplitter.split("show me Rick and Donna") == nil)
        #expect(HallieQuestionSplitter.split("who are Rick and Donna") == nil)
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
