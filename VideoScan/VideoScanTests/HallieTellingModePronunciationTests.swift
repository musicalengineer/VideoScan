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
                == "OK, noted — Nathaniel. I'll say Nathaniel as nuh-THAN-yul from now on. I've kept that with Nathaniel McGill.")
        #expect(HallieTellingMode.pronunciationReply(told, scope: .person(name: "nathaniel"))
                == "OK, noted — Nathaniel. I'll say Nathaniel as nuh-THAN-yul from now on. I've kept that on Nathaniel's record.")
        #expect(HallieTellingMode.pronunciationReply(told, scope: .file)
            == "OK, noted — Nathaniel. I'll say Nathaniel as nuh-THAN-yul from now on. I've kept that in the pronunciation list for that name.")
        #expect(HallieTellingMode.pronunciationFailureReply(told, error: "disk full").contains("disk full"))
        #expect(HallieTellingMode.pronunciationFailureReply(told, error: "could not save: disk full")
            == "I couldn't save that — disk full. Saying Nathaniel as nuh-THAN-yul won't stick past this answer, sorry.")
        // Spoken through the lexicon, the confirmation is the proof: the
        // name is respelled, the respelling is left alone.
        let lexicon = HalliePronunciationLexicon(entries: [.init(written: "Nathaniel", spoken: "nuh-THAN-yul")])
        #expect(lexicon.apply(to: HallieTellingMode.pronunciationReply(told, scope: .file)).spoken
                    .hasPrefix("OK, noted — nuh-THAN-yul. I'll say nuh-THAN-yul as nuh-THAN-yul from now on."))
    }
}

extension HallieTellingModeTests {

    /// QA 2026-08-26: "Donna is said to cook" used to detect word=Donna,
    /// saidAs="to cook" and PERSIST it. A respelling has to look like one:
    /// one token, or hyphenated, or carrying an all-caps stressed syllable
    /// — and never opening with a function word ("to", "a", "of", ...).
    @Test func twoTokenPredicatesAreNotRespellings() throws {
        for text in [
            "Donna is said to cook",
            "Rick is read a story",
            "Tim is said to sing",
            "Edith is spoken of fondly",
            "Nathaniel is pronounced in Boston",
            "McGill is said as the Scots do",
        ] {
            #expect(HallieTellingMode.detectPronunciation(text) == nil, Comment(rawValue: text))
        }
        let a = try #require(HallieTellingMode.detectPronunciation("Nathaniel is pronounced nuh-THAN-yul"))
        #expect(a == .init(word: "Nathaniel", saidAs: "nuh-THAN-yul"))
        let b = try #require(HallieTellingMode.detectPronunciation("say Edith as EE-dith"))
        #expect(b == .init(word: "Edith", saidAs: "EE-dith"))
        let c = try #require(HallieTellingMode.detectPronunciation("McGill is pronounced muh-GILL"))
        #expect(c == .init(word: "McGill", saidAs: "muh-GILL"))
        // Two tokens are still fine when one carries the stress marking.
        let d = try #require(HallieTellingMode.detectPronunciation("Latta is pronounced LAT uh"))
        #expect(d == .init(word: "Latta", saidAs: "LAT uh"))
    }
}
