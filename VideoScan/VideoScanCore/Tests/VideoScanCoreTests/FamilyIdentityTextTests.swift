import XCTest
@testable import VideoScanCore

/// The ASCII fast path in FamilyIdentityText must equal the Unicode slow
/// path byte for byte, on ASCII and on everything that is not ASCII.
final class FamilyIdentityTextTests: XCTestCase {
    static let corpus: [String] = [
        "", " ", "  Richard Harding /Breen/ Jr ", "McGill", "O'Brien", "Zoë Élan", "José María", "Ævar", "ß Straße",
        "Ann-Marie", "GVQV-NW3", "@I12@", "Mary\tLamb\n", "\u{0301}e", "e\u{0301}", "ÅNGSTRÖM", "İstanbul", "K\u{212A}",
        "Ω omega", "日本語 名前", "  tabs\t and  spaces ", "Under_score", "A.B.C", "\u{00A0}nbsp", "Ó'Néill", "x\u{0B}y\u{0C}z",
        "MIXED case123 Digits", "trailing\r", "\u{FEFF}bom", "naïve café", "Fitz Gerald", "Ann Mc Gill",
    ]

    func testFastPathEqualsSlowPath() {
        for s in Self.corpus {
            XCTAssertEqual(FamilyIdentityText.normalized(s), FamilyIdentityText.slowNormalized(s), "normalized '\(s)'")
            XCTAssertEqual(FamilyIdentityText.tokens(s), FamilyIdentityText.slowTokens(s), "tokens '\(s)'")
        }
        // Every printable ASCII byte, alone and in context.
        for b in UInt8(0x20)...UInt8(0x7E) {
            let s = "ab" + String(UnicodeScalar(b)) + "Cd"
            XCTAssertEqual(FamilyIdentityText.normalized(s), FamilyIdentityText.slowNormalized(s), "normalized '\(s)'")
            XCTAssertEqual(FamilyIdentityText.tokens(s), FamilyIdentityText.slowTokens(s), "tokens '\(s)'")
        }
        for b in UInt8(0x00)...UInt8(0x1F) {
            let s = "ab" + String(UnicodeScalar(b)) + "Cd "
            XCTAssertEqual(FamilyIdentityText.normalized(s), FamilyIdentityText.slowNormalized(s), "normalized control \(b)")
            XCTAssertEqual(FamilyIdentityText.tokens(s), FamilyIdentityText.slowTokens(s), "tokens control \(b)")
        }
    }

    func testSyntheticNamesAgree() {
        let text = GedcomSyntheticPedigree.gedcom(people: 2_000, generations: 10)
        for line in text.split(separator: "\n") where line.hasPrefix("1 NAME ") {
            let s = String(line.dropFirst(7))
            XCTAssertEqual(FamilyIdentityText.tokens(s), FamilyIdentityText.slowTokens(s))
        }
    }
}
