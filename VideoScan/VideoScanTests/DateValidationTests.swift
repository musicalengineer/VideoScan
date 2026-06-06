import Foundation
import Testing
@testable import VideoScan

// MARK: - Date validation predicate tests
//
// Locks the impossible / 2040-sentinel detection so a future refactor
// can't silently let the bug back in. Pinned cases:
//
//   - now + a few seconds                            → impossible
//   - exact 2040-02-06T06:28:16Z sentinel             → impossible
//   - 1899-12-31                                     → impossible (pre-1900)
//   - 1900-01-01                                     → plausible (floor inclusive)
//   - 2009-11-25T23:59:18Z (the file Rick spotted)   → plausible
//   - nil                                            → plausible (no signal)

@Suite("DateValidation")
struct DateValidationTests {

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int,
                      _ hh: Int = 0, _ mm: Int = 0, _ ss: Int = 0) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d
        dc.hour = hh; dc.minute = mm; dc.second = ss
        dc.timeZone = TimeZone(identifier: "UTC")
        return Self.utc.date(from: dc)!
    }

    // MARK: - pfIsImpossibleDate

    @Test("nil is plausible (no signal)")
    func nilIsPlausible() {
        #expect(pfIsImpossibleDate(nil) == false)
    }

    @Test("future date is impossible")
    func futureDateImpossible() {
        let now = date(2026, 6, 6, 12, 0, 0)
        let future = date(2030, 1, 1)
        #expect(pfIsImpossibleDate(future, now: now) == true)
    }

    @Test("date exactly at now is plausible (≤, not <)")
    func nowItselfIsPlausible() {
        let now = Date()
        #expect(pfIsImpossibleDate(now, now: now) == false)
    }

    @Test("1899 is impossible (before 1900 floor)")
    func pre1900Impossible() {
        let old = date(1899, 12, 31)
        #expect(pfIsImpossibleDate(old) == true)
    }

    @Test("1900-01-01 is plausible (floor is inclusive)")
    func nineteenHundredFloorPlausible() {
        let floor = date(1900, 1, 1)
        #expect(pfIsImpossibleDate(floor) == false)
    }

    @Test("Rick's real Thanksgiving 2009 timestamp is plausible")
    func realTimestampPlausible() {
        let thanksgiving = date(2009, 11, 25, 23, 59, 18)
        #expect(pfIsImpossibleDate(thanksgiving) == false)
    }

    // MARK: - pfIs2040Sentinel

    @Test("exact 2040-02-06 06:28:16 UTC matches the sentinel")
    func exactSentinelDetected() {
        let bogus = date(2040, 2, 6, 6, 28, 16)
        #expect(pfIs2040Sentinel(bogus) == true)
    }

    @Test("2040 in general does NOT match the sentinel")
    func unrelated2040IsNotSentinel() {
        let other2040 = date(2040, 6, 15, 12, 0, 0)
        #expect(pfIs2040Sentinel(other2040) == false,
                "Future-2040 legit dates must not be silently dropped")
    }

    @Test("nearby seconds do not match the sentinel")
    func nearbySecondsDoNotMatch() {
        let bogus = date(2040, 2, 6, 6, 28, 16)
        #expect(pfIs2040Sentinel(bogus.addingTimeInterval(2)) == false)
        #expect(pfIs2040Sentinel(bogus.addingTimeInterval(-2)) == false)
    }

    // MARK: - pfDateOrNilIfImpossible

    @Test("plausible date passes through unchanged")
    func plausiblePassThrough() {
        let thanksgiving = date(2009, 11, 25, 23, 59, 18)
        #expect(pfDateOrNilIfImpossible(thanksgiving) == thanksgiving)
    }

    @Test("future date becomes nil")
    func futureBecomesNil() {
        let future = date(2099, 1, 1)
        #expect(pfDateOrNilIfImpossible(future) == nil)
    }

    @Test("the 2040 sentinel specifically becomes nil")
    func sentinelBecomesNil() {
        let bogus = date(2040, 2, 6, 6, 28, 16)
        #expect(pfDateOrNilIfImpossible(bogus) == nil)
    }

    @Test("nil passes through as nil")
    func nilPassThrough() {
        #expect(pfDateOrNilIfImpossible(nil) == nil)
    }
}
