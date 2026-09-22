// HallieRegnalNumeralTests.swift
// Rick, live 2026-09-07: "she pronounces III not as third but as I-I-I even
// though I kept telling her Third." Every synthesizer reads a bare Roman
// numeral as letters, and a twenty-generation tree is full of them.

import Foundation
import Testing
@testable import VideoScan

@Suite("Regnal numerals are spoken, not spelled")
struct HallieRegnalNumeralTests {
    private let expand = HalliePronunciationLexicon.expandingRegnalNumerals

    @Test func theNameRickAskedAbout() {
        #expect(expand("Edward III of Windsor King of England")
                == "Edward the Third of Windsor King of England")
        #expect(expand("tell me about Edward III") == "tell me about Edward the Third")
    }

    @Test func theRangeThatOccursInNames() {
        #expect(expand("Henry II") == "Henry the Second")
        #expect(expand("Henry IV") == "Henry the Fourth")
        #expect(expand("Henry V") == "Henry the Fifth")
        #expect(expand("Henry VIII") == "Henry the Eighth")
        #expect(expand("Louis IX") == "Louis the Ninth")
        #expect(expand("Charles X") == "Charles the Tenth")
    }

    /// THE TRAP. Bare "I" is the pronoun and by far the commonest word this
    /// could damage. It must never be touched.
    @Test func thePronounIsNeverTouched() {
        #expect(expand("I think I know") == "I think I know")
        #expect(expand("Rick I know") == "Rick I know")
        #expect(expand("Donna and I") == "Donna and I")
    }

    /// A numeral with no name in front of it is not a regnal number.
    @Test func aStrayNumeralIsLeftAlone() {
        #expect(expand("III") == "III")
        #expect(expand("see III below") == "see III below")
        #expect(expand("the III") == "the III", "lowercase 'the' is not a name")
    }

    /// Ordinary text with no numerals is returned untouched, and the
    /// early-out means it is not even scanned.
    @Test func ordinaryTextIsUnchanged() {
        let plain = "Mary Catherine O'Connor was born in Ireland."
        #expect(expand(plain) == plain)
    }

    /// Longer numerals must win over their own prefixes — VIII must not
    /// become "the Fifth" + III.
    @Test func longerNumeralsWinOverTheirPrefixes() {
        #expect(expand("Henry VIII and Edward VI")
                == "Henry the Eighth and Edward the Sixth")
    }

    /// Names with apostrophes and hyphens still count as the preceding name.
    @Test func namesWithPunctuationStillAnchorIt() {
        #expect(expand("O'Connor III") == "O'Connor the Third")
        #expect(expand("Breen-Parker II") == "Breen-Parker the Second")
    }

    /// Sept 21: the number rule worked, but a Sept 7 teach had stored
    /// Edward → III. The lexicon then replaced the NAME with the numeral.
    @Test func poisonedLearnedNameCannotUndoTheRegnalSpeechRule() throws {
        let data = Data(#"{"Edward":{"respelling":"III","source":"told"}}"#.utf8)
        let lexicon = try HalliePronunciationLexicon(jsonData: data)
        let displayed = "Edward III was king."
        for phonemes in [false, true] {
            let said = HallieSpeaker.spokenText(displayed, lexicon: lexicon, phonemeLinks: phonemes)
            #expect(said == "Edward the Third was king.")
            #expect(HallieSpeaker.sentences(said, lexicon: lexicon, phonemeLinks: phonemes) == [said])
        }
        #expect(displayed == "Edward III was king.")
        #expect(lexicon.apply(to: displayed).fired.isEmpty)
    }

    @Test func firstAlternativeAndUnicodeNumeralCannotPoisonSpeech() {
        for bad in ["III | ED-werd", "Ⅲ", "VIII"] {
            let lexicon = HalliePronunciationLexicon(entries: [.init(written: "Edward", spoken: bad)])
            #expect(HallieSpeaker.spokenText("Edward III", lexicon: lexicon) == "Edward the Third")
        }
    }

    /// A numeral entry is ignored WHOLE, phonemes included (2026-09-21
    /// review of codex's WIP, which kept the phonemes): a teach derives the
    /// phonemes FROM the typed respelling, so beside "III" they are the
    /// numeral's, not the name's. Both voices say the plain name.
    @Test func aNumeralEntryIsIgnoredWholePhonemesIncluded() {
        let lexicon = HalliePronunciationLexicon(entries: [
            .init(written: "Edward", spoken: "III", phonemes: "ˈɛdwɚd")
        ])
        let neural = HallieSpeaker.spokenText("Edward III", lexicon: lexicon, phonemeLinks: true)
        #expect(neural == "Edward the Third")
        #expect(lexicon.strippingPhonemeLinks(neural) == "Edward the Third")
        #expect(HallieSpeaker.spokenText("Edward III", lexicon: lexicon) == "Edward the Third")
        #expect(lexicon.apply(to: "Edward III", style: .kokoro).fired.isEmpty)
    }

    @Test func ordinaryStressedSyllablesAndSingleLetterSoundsRemainValid() {
        for said in ["LAT", "LIV", "MIX", "liv", "I", "V", "X", "ED-werd"] {
            #expect(HallieTellingMode.looksLikeRespelling(said))
            let lexicon = HalliePronunciationLexicon(entries: [.init(written: "Edward", spoken: said)])
            #expect(lexicon.apply(to: "Edward").spoken == said)
        }
    }

    @Test func numeralOnlyTeachingIsDeclined() {
        for text in ["say Edward as III", "Edward is pronounced III", "pronounce Edward like Ⅲ"] {
            #expect(HallieTellingMode.detectPronunciation(text) == nil)
        }
    }

    @Test func historicalQuotedFullNameCorrectionNeverTeachesEdwardAsIII() throws {
        let text = #""Edward III" is pronounced Edward the third."#
        #expect(HallieTellingMode.detectPronunciation(text) == nil)
        let free = try #require(HalliePronunciationFreeform.detect(text, isKnownName: { $0 == "Edward" }))
        #expect(free.kind == .hintOnly)
        #expect(free.alternatives.isEmpty)
        #expect(HalliePronunciationFreeform.hintOnlyReply(free).contains("I haven't changed"))
        #expect(HalliePronunciationFreeform.hintOnlyReply(free).contains("spoken words"))
    }

    @Test func rejectedNumeralWriteHasNoDiskSideEffects() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HallieRomanGuard-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("pronunciations.json")
        #expect(throws: HalliePronunciationGuard.Refusal.numeral(word: "Edward", spoken: "III")) {
            try HalliePronunciationLexicon.setFileEntry(written: "Edward", spoken: "III", url: url, log: nil)
        }
        // Phonemes beside the numeral do not buy it a pass.
        #expect(throws: HalliePronunciationGuard.Refusal.numeral(word: "Edward", spoken: "III")) {
            try HalliePronunciationLexicon.setFileEntry(written: "Edward", spoken: "III", phonemes: "ˈɪ", url: url, log: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(HalliePronunciationGuard.Refusal.numeral(word: "Edward", spoken: "III")
            .localizedDescription.contains("Roman numeral"))
    }
}
