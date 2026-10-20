// CatalogTableDateTests.swift
// Pins the Catalog table's one date spelling (Rick 2026-10-20) and the
// volumes-pane divider rule. Stub written by feature-dev; the testing
// agent owns it from here.

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog table — one date format, 25-Dec-1995")
struct CatalogTableDateTests {

    @Test func partialDatesKeepTheirPrecision() {
        #expect(CatalogTableDate.cell(forResolved: "1995-12-25").text == "25-Dec-1995")
        #expect(CatalogTableDate.cell(forResolved: "1996-01-01").text == "01-Jan-1996", "two-digit day, like dd")
        #expect(CatalogTableDate.cell(forResolved: "1995-12").text == "Dec-1995", "never an invented day")
        #expect(CatalogTableDate.cell(forResolved: "1995").text == "1995")
        #expect(CatalogTableDate.cell(forResolved: "2003\u{2013}2004").text == "2003\u{2013}2004", "a year span is left alone")
    }

    @Test func aBestGuessKeepsItsSuffix() {
        #expect(CatalogTableDate.cell(forResolved: "1992-06 (est.)").text == "Jun-1992 (est.)")
        #expect(CatalogTableDate.cell(forResolved: "1992 (est.)").text == "1992 (est.)")
    }

    @Test func aTimeOfDayMovesToTheTooltip() {
        let cell = CatalogTableDate.cell(forResolved: "2023-11-14 10:22:33")
        #expect(cell.text == "14-Nov-2023")
        #expect(cell.dateAndTime == "14-Nov-2023 10:22:33")
        #expect(CatalogTableDate.cell(forResolved: "2023-11-14").dateAndTime == nil)
    }

    @Test func unknownAndUnrecognisedAreShownAsGiven() {
        #expect(CatalogTableDate.cell(forResolved: "").text.isEmpty, "the cell shows its dash")
        #expect(CatalogTableDate.cell(forResolved: "sometime in the 80s").text == "sometime in the 80s")
        #expect(CatalogTableDate.cell(forResolved: "1995-13-01").text == "1995-13-01", "not a calendar date: untouched")
    }

    @Test func folderRangesUseTheSameSpelling() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let a = cal.date(from: DateComponents(year: 1995, month: 12, day: 25)) ?? .distantPast
        let b = cal.date(from: DateComponents(year: 1996, month: 1, day: 1)) ?? .distantPast
        #expect(CatalogTableDate.range(b, a) == "25-Dec-1995 \u{2013} 01-Jan-1996")
        #expect(CatalogTableDate.range(a, a) == "25-Dec-1995")
    }

    @Test func aHandEnteredDayIsNotPrintedAsTheDayBefore() {
        // UTC midnight (UserDateEntry.date) must read as its own day in any zone.
        let d = UserDateEntry.date(from: "1984-04-07") ?? .distantPast
        #expect(CatalogTableDate.day(d) == "07-Apr-1984")
    }
}

@Suite("Catalog volumes pane — divider rule")
struct CatalogVolumePaneHeightTests {

    @Test func firstLaunchFitsTheContentUpToFortyPercent() {
        #expect(CatalogVolumePaneHeight.target(remembered: nil, contentFit: 200, splitHeight: 1000) == 200)
        #expect(CatalogVolumePaneHeight.target(remembered: nil, contentFit: 700, splitHeight: 1000) == 400)
    }

    @Test func aRememberedHeightWinsButBothPanesKeepTheirFloors() {
        #expect(CatalogVolumePaneHeight.target(remembered: 550, contentFit: 200, splitHeight: 1000) == 550)
        #expect(CatalogVolumePaneHeight.target(remembered: 980, contentFit: 200, splitHeight: 1000) == 900)
        #expect(CatalogVolumePaneHeight.target(remembered: 10, contentFit: 200, splitHeight: 1000) == 60)
    }
}
