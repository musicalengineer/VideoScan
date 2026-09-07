import Foundation
import Testing
@testable import VideoScan

/// Three live misses from Rick's 2026-09-06 evening spin, all in one shape:
/// the composer talking ABOUT its scaffolding instead of using it. Every
/// fact underneath was correct and every basis line was correct.
///
/// The brain at the time was qwen3:30b-a3b, chosen from the model picker and
/// persisted — not the evaluated qwen3.8:27b-mlx. These tests are
/// deliberately model-independent: the next model Rick tries will have its
/// own habits, and the contract must not depend on which one is loaded.
@Suite("The composer never narrates its own scaffolding")
struct HallieScaffoldNarrationTests {

    /// Verbatim, tags stripped the way `verify` strips them before asking.
    @Test func theThreeLiveMissesAreCaught() {
        let said = [
            "Looking at claims  to , they all confirm Donna in specific files.",
            "There are 14 videos total, as per claim .",
            "I need to end the sentence with  in square brackets.",
            "Looking at the approved claims, there's only one claim: Richard Harding Breen Sr was born 21 February 1929.",
        ]
        for sentence in said {
            #expect(HallieCompositionVerifier.narratesScaffolding(sentence),
                    Comment(rawValue: sentence))
        }
    }

    /// Why the existing guard missed them, pinned so the reasoning survives:
    /// `namesScaffoldLabel` needs digits that tag-stripping has removed.
    @Test func theOlderGuardGenuinelyCannotSeeThem() {
        #expect(!HallieCompositionVerifier.namesScaffoldLabel(
            "Looking at claims  to , they all confirm Donna in specific files."),
            "if this ever starts matching, the new guard is redundant and should go")
        // It still catches what it was built for — a model spelling it out.
        #expect(HallieCompositionVerifier.namesScaffoldLabel("Two examples are Item 1 and Item 2."))
        #expect(HallieCompositionVerifier.namesScaffoldLabel("as per claim 1"))
    }

    // MARK: what must survive

    /// Real answers Hallie gave today, which must not be touched. If any of
    /// these starts being dropped the guard has eaten the product.
    @Test func honestAnswersAreUnaffected() {
        let good = [
            "Richard Harding Breen Sr was born 21 February 1929.",
            "Eileen Latta was born 31 August 1930.",
            "I don't have any videos tagged with Richard yet.",
            "There are 14 videos: 4 with the phrase in the directory and 10 in the filename.",
            "Rick is the brother of Beth, Ellen, and Tim.",
            "You have 44 videos of Donna.",
            "Among them are Christmas-1990-something.mov and VTS_01_1.mp4.",
            "Timmy started his own machining firm named Lee Machine in 1999.",
            "She was recruited by the CIA in 1952 but declined and married Richard Breen Sr.",
            "I couldn't match Timmy to a record in the family tree I have.",
        ]
        for sentence in good {
            #expect(!HallieCompositionVerifier.narratesScaffolding(sentence),
                    Comment(rawValue: sentence))
        }
    }

    /// The first-person rule is scoped to the composer's OWN instructions.
    /// Hallie says "I" constantly and legitimately.
    @Test func hallieMaySpeakInTheFirstPerson() {
        let good = [
            "I don't have any videos tagged with Donna yet.",
            "I couldn't work out who you meant.",
            "I need to know which Eileen you mean before I can look her up.",
            "I have three videos from that summer.",
            "I should have those on the LaCie, but I can't reach it.",
        ]
        for sentence in good {
            #expect(!HallieCompositionVerifier.narratesScaffolding(sentence),
                    Comment(rawValue: sentence))
        }
    }

    /// And it fires when the first person is about the FORMAT.
    @Test func firstPersonAboutTheFormatIsCaught() {
        #expect(HallieCompositionVerifier.narratesScaffolding(
            "I need to end the sentence with a citation."))
        #expect(HallieCompositionVerifier.narratesScaffolding(
            "I should cite the tag at the end of each sentence."))
        #expect(HallieCompositionVerifier.narratesScaffolding(
            "I have to put the answer in square brackets."))
    }

    /// The whole point: it does not matter which model said it.
    @Test func theGuardIsAboutTheWordsNotTheModel() {
        #expect(HallieCompositionVerifier.narratesScaffolding(
            "The claims list every file I found."))
        #expect(HallieCompositionVerifier.narratesScaffolding(
            "Based on the approved claim, she was born in 1930."))
    }
}
