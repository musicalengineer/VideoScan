// FamilyTreePersonMetadataTests.swift
// Rick, 2026-09-07, looking at John Hastings 3rd Earl of Pembroke in the
// Family Tree view: "I want all this text to be copyable via 'copy gedcom
// data for this individual' or just copy metadata."
//
// The fixture is his record, trimmed to what the parser actually keeps, plus
// the parts it drops (TITL, BURI, NOTE, SOUR) so the test proves they are
// absent from the copy rather than assuming it.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let hastingsTree = """
0 HEAD
0 @I1@ INDI
1 NAME John /Hastings/ 3rd Earl of Pembroke
1 NAME John /of Reading/
2 TYPE aka
1 SEX M
1 BIRT
2 DATE 11 October 1372
2 PLAC Kenilworth, Warwickshire, England
1 DEAT
2 DATE 30 December 1389
2 PLAC Woodstock, Oxfordshire, England
1 BURI
2 DATE 1389
2 PLAC Grey Friars London, London, Greater London, England
1 TITL 5th Baron of Abergavenny
1 TITL 3rd Earl of Pembroke
1 _FSFTID L2BD-JX1
1 FAMC @F1@
1 FAMS @F2@
0 @I2@ INDI
1 NAME Hastings /Hastings/ 2nd Earl
1 SEX M
1 BIRT
2 DATE 1347
1 FAMS @F1@
0 @I3@ INDI
1 NAME Anne /Manny/
1 SEX F
1 FAMS @F1@
0 @I4@ INDI
1 NAME Philippa de /Mortimer/
1 SEX F
1 BIRT
2 DATE 1375
1 DEAT
2 DATE 1401
1 FAMS @F2@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I1@
1 WIFE @I4@
1 MARR
2 DATE 1376
0 TRLR
"""

@Suite("Family Tree — copy a person's details")
struct FamilyTreePersonMetadataTests {
    let graph = GedcomFamilyGraph(gedcomText: hastingsTree)

    private func copy(_ id: String) throws -> String {
        let person = try #require(graph.people[id])
        return FamilyTreePersonMetadata.text(for: person, in: graph)
    }

    /// The birthplace is the whole reason this exists: Rick's FT view showed
    /// "Born 1372 (Kenilworth, Warwickshire, England)" while Hallie answered
    /// only the date, four times running.
    @Test func theBlockCarriesBothDatesAndBothPlaces() throws {
        let text = try copy("@I1@")
        #expect(text.hasPrefix("John Hastings 3rd Earl of Pembroke"))
        #expect(text.contains("Born 11 October 1372 (Kenilworth, Warwickshire, England)"))
        #expect(text.contains("Died 30 December 1389 (Woodstock, Oxfordshire, England)"))
    }

    @Test func itCarriesTheIdentifiersAndTheAlternateName() throws {
        let text = try copy("@I1@")
        #expect(text.contains("Also known as: John of Reading"))
        #expect(text.contains("FamilySearch ID: L2BD-JX1"))
        #expect(text.contains("Record ID: @I1@"))
        #expect(text.contains("Sex: Male"))
    }

    @Test func itCarriesParentsSpouseAndMarriageDate() throws {
        let text = try copy("@I1@")
        #expect(text.contains("Parents:"))
        #expect(text.contains("Anne Manny"))
        #expect(text.contains("Married to Philippa de Mortimer (b. 1375, d. 1401)"))
        #expect(text.contains("1376"), Comment(rawValue: text))
    }

    /// HONESTY. The parser drops TITL, BURI, NOTE and SOUR, so the copy
    /// cannot contain them — and must say so rather than look complete.
    /// If a future parser keeps titles, this test should FAIL and be
    /// rewritten to assert they are present.
    @Test func itSaysWhatItDoesNotHave() throws {
        let text = try copy("@I1@")
        #expect(!text.contains("Abergavenny"), "TITL is dropped at parse — see the correction in docs/hallie_titled_ancestors_design.md")
        #expect(!text.contains("Grey Friars"), "BURI is dropped at parse")
        #expect(text.contains("titles, burial, notes and sources in the source GEDCOM are not kept"))
    }

    /// A sparse record must not invent anything or crash.
    @Test func aRecordWithAlmostNothingStillCopies() throws {
        let text = try copy("@I3@")
        #expect(text.hasPrefix("Anne Manny"))
        #expect(!text.contains("Born"), Comment(rawValue: text))
        #expect(text.contains("Record ID: @I3@"))
    }

    /// A date with no place, and a place with no date, are both said plainly.
    @Test func aHalfRecordedEventSaysWhichHalfIsMissing() throws {
        let text = try copy("@I2@")
        #expect(text.contains("Born 1347 (place not recorded)"), Comment(rawValue: text))
    }
}
