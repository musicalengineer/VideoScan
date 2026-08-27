import Foundation
import Testing
@testable import VideoScan

/// "Nathaniel is pronounced nah-thahn-yul" and friends: detection lives
/// beside the other told-me openers (HallieTellingMode).
extension HallieTellingModeTests {

    @Test func theThreeCanonicalPronunciationUtterancesAreDetected() throws {
        let a = try #require(HallieTellingMode.detectPronunciation("Nathaniel is pronounced nah-thahn-yul"))
        #expect(a == .init(word: "Nathaniel", saidAs: "nah-thahn-yul"))
        let b = try #require(HallieTellingMode.detectPronunciation("say Edith as EE-dith"))
        #expect(b == .init(word: "Edith", saidAs: "EE-dith"))
        let c = try #require(HallieTellingMode.detectPronunciation("you're mispronouncing McGill, it's muh-GILL"))
        #expect(c == .init(word: "McGill", saidAs: "muh-GILL"))
    }

    @Test func pronunciationPhrasingsKeepTheRespellingsCapitalsAndStripQuotes() throws {
        let cases: [(String, String, String)] = [
            ("Hallie, Latta should be said LAT-uh.", "Latta", "LAT-uh"),
            ("please pronounce “Bethiah” like beh-THY-uh", "Bethiah", "beh-THY-uh"),
            ("The name McLaughlin is pronounced as muh-GLOCK-lin!", "McLaughlin", "muh-GLOCK-lin"),
            ("you keep saying Latta wrong — it's LAT-uh", "Latta", "LAT-uh"),
            ("You are mispronouncing Ronan. It should be ROW-nin", "Ronan", "ROW-nin"),
            ("Edith is said EE-dith", "Edith", "EE-dith"),
        ]
        for (text, word, said) in cases {
            let told = HallieTellingMode.detectPronunciation(text)
            #expect(told?.word == word, Comment(rawValue: text))
            #expect(told?.saidAs == said, Comment(rawValue: text))
        }
    }

    @Test func questionsAndOrdinaryStatementsAreNotPronunciations() {
        for text in [
            "how is Nathaniel pronounced?",
            "is Edith pronounced EE-dith?",
            "let me tell you about Nathaniel",
            "Nathaniel is my uncle",
            "say hello to Donna",
            "Nathaniel was said to be a good man at the shop",
            "it is pronounced nuh-THAN-yul",
            "",
        ] {
            #expect(HallieTellingMode.detectPronunciation(text) == nil, Comment(rawValue: text))
        }
        // A telling-mode opener still opens telling, never a pronunciation.
        #expect(HallieTellingMode.detectOpening("let me tell you about Nathaniel") != nil)
    }

    @Test func pronunciationRepliesConfirmAndSayWhereItWasKept() {
        let told = HallieTellingMode.PronunciationTelling(word: "Nathaniel", saidAs: "nuh-THAN-yul")
        #expect(HallieTellingMode.pronunciationReply(told, scope: .person(name: "Nathaniel McGill"))
                == "Got it — I'll say Nathaniel as nuh-THAN-yul from now on. I've kept that with Nathaniel McGill.")
        #expect(HallieTellingMode.pronunciationReply(told, scope: .person(name: "nathaniel"))
                == "Got it — I'll say Nathaniel as nuh-THAN-yul from now on. I've kept that on Nathaniel's record.")
        #expect(HallieTellingMode.pronunciationReply(told, scope: .file).hasPrefix(
            "Got it — I'll say Nathaniel as nuh-THAN-yul from now on. I've kept that in the pronunciation list"))
        #expect(HallieTellingMode.pronunciationFailureReply(told, error: "disk full").contains("disk full"))
        // Spoken through the lexicon, the confirmation is the proof: the
        // name is respelled, the respelling is left alone.
        let lexicon = HalliePronunciationLexicon(entries: [.init(written: "Nathaniel", spoken: "nuh-THAN-yul")])
        #expect(lexicon.apply(to: HallieTellingMode.pronunciationReply(told, scope: .file)).spoken
                    .hasPrefix("Got it — I'll say nuh-THAN-yul as nuh-THAN-yul from now on."))
    }
}
