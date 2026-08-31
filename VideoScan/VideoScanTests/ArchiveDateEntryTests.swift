import Testing
import Foundation
@testable import VideoScan
import VideoScanCore

// MARK: - ArchiveDateEntryTests
//
// Rick, 2026-08-31: "the archive helper should ask for estimated date if it
// is suspicious and I can type in an estimate rather than going in without
// a date."
//
// The stakes are why this is forgiving: the archive bakes the date into the
// filename AND the folder, the manifest is append-only, and there is
// neither a refile nor an un-promote. A promotion's date is permanent. A
// parser that rejects "March 1947" on syntax teaches the reader to skip the
// field, and the file lands in Undated/ forever.

struct ArchiveDateEntryTests {

    private let today = Date(timeIntervalSince1970: 1_788_000_000)   // 2026

    private func parse(_ s: String) -> ArchiveDateEntry.Parsed? {
        ArchiveDateEntry.parse(s, today: today)
    }

    // MARK: What a person actually types

    @Test func aBareYearStaysAYear() {
        #expect(parse("1947")?.hint == .year(1947))
        #expect(parse("1947")?.preview == "1947-xx-xx")
    }

    /// The important negative: a year must NOT become 1 January. The
    /// filename shape is how the archive distinguishes "we know the year"
    /// from "we know the day", so inventing precision corrupts that.
    @Test func aYearIsNeverPromotedToADay() {
        #expect(parse("1947")?.hint != .day(year: 1947, month: 1, day: 1))
    }

    @Test func writtenMonthsAreUnderstood() {
        #expect(parse("March 1947")?.hint == .month(year: 1947, month: 3))
        #expect(parse("mar 1947")?.hint == .month(year: 1947, month: 3))
        #expect(parse("12 March 1947")?.hint == .day(year: 1947, month: 3, day: 12))
        #expect(parse("Sept 1963")?.hint == .month(year: 1963, month: 9))
    }

    @Test func isoAndTheSeparatorsPeopleActuallyUse() {
        for text in ["1947-03-12", "1947/03/12", "1947.03.12"] {
            #expect(parse(text)?.hint == .day(year: 1947, month: 3, day: 12),
                    Comment(rawValue: "failed on \(text)"))
        }
        #expect(parse("1947-3")?.hint == .month(year: 1947, month: 3))
    }

    @Test func aDecadeFilesAtTheDecadeRoot() {
        #expect(parse("1940s")?.hint == .decade(startYear: 1940))
        #expect(parse("1940's")?.hint == .decade(startYear: 1940))
        #expect(parse("1943s") == nil, "only whole decades")
    }

    @Test func whitespaceAndCaseDoNotMatter() {
        #expect(parse("  MARCH 1947  ")?.hint == .month(year: 1947, month: 3))
    }

    // MARK: Refusals — silence beats a wrong permanent date

    @Test func nonsenseIsRefusedRatherThanGuessed() {
        for text in ["", "   ", "sometime in the war", "19", "47", "abcd", "1947-13", "1947-00"] {
            #expect(parse(text) == nil, Comment(rawValue: "should refuse: \(text)"))
        }
    }

    @Test func impossibleDaysAreRefused() {
        #expect(parse("1947-02-30") == nil, "February has no 30th")
        #expect(parse("1947-04-31") == nil, "April has 30 days")
        #expect(parse("1900-02-29") == nil, "1900 was not a leap year")
        #expect(parse("1948-02-29")?.hint == .day(year: 1948, month: 2, day: 29),
                "1948 WAS a leap year")
    }

    /// A four-digit number is not automatically a year. 1650 is plausible
    /// for a tree person but not for a home movie, and a typo like 1047
    /// must not silently create a folder in the eleventh century.
    @Test func implausibleYearsAreRefused() {
        #expect(parse("1047") == nil, "before film existed")
        #expect(parse("2099") == nil, "the future")
        #expect(parse("1850")?.hint == .year(1850), "the documented floor is accepted")
    }

    // MARK: The guidance line

    /// The sheet used to promise "you can refile later once the date is
    /// known", and no refile exists. The replacement must not reassure.
    @Test func theGuidanceNeverPromisesAFixLater() {
        let blank = ArchiveDateEntry.guidance(for: nil, typed: "")
        #expect(blank.contains("cannot be changed later"))
        #expect(!blank.lowercased().contains("refile later"))

        let good = ArchiveDateEntry.guidance(for: parse("1947"), typed: "1947")
        #expect(good.contains("1947-xx-xx"), "show what it will actually be called")
        #expect(good.contains("permanent"))

        let bad = ArchiveDateEntry.guidance(for: nil, typed: "sometime in the war")
        #expect(bad.contains("Not understood"))
        #expect(bad.contains("1947"), "say what a good answer looks like")
    }
}
