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
}
