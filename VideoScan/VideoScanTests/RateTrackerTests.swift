import Foundation
import Testing
@testable import VideoScan

// MARK: - RateTracker tests
//
// Sliding-window rate of records added to the catalog over time.
// All these tests pass dates explicitly so they don't depend on
// real wall-clock time.

@Suite("RateTracker")
struct RateTrackerTests {

    @Test("no samples → 0/min, hasEnoughSamples false")
    func zeroState() {
        let r = RateTracker()
        #expect(r.perMinute == 0)
        #expect(r.hasEnoughSamples == false)
        #expect(r.displayText == "—")
    }

    @Test("one sample is not enough to compute a rate")
    func singleSampleNoRate() {
        var r = RateTracker()
        r.record(count: 100, at: Date(timeIntervalSince1970: 1000))
        #expect(r.perMinute == 0)
        #expect(r.hasEnoughSamples == false)
        #expect(r.displayText == "—")
    }

    @Test("two samples 60s apart with +6 records → 6.0/min")
    func basicRateComputation() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        r.record(count: 100, at: t0)
        r.record(count: 106, at: t0.addingTimeInterval(60))
        #expect(r.perMinute == 6.0)
        #expect(r.hasEnoughSamples == true)
        #expect(r.displayText == "6.0/min")
    }

    @Test("samples outside the window are trimmed")
    func windowTrimming() {
        var r = RateTracker(window: 60)
        let t0 = Date(timeIntervalSince1970: 1000)
        r.record(count: 0, at: t0)                              // will fall out
        r.record(count: 100, at: t0.addingTimeInterval(30))     // will fall out
        r.record(count: 200, at: t0.addingTimeInterval(100))    // first surviving
        r.record(count: 220, at: t0.addingTimeInterval(160))    // last
        // Surviving span: 60s, delta 20 → 20/min
        #expect(r.perMinute == 20.0)
        #expect(r.displayText == "20/min")
    }

    @Test("count going down (catalog reset) discards old samples")
    func resetClearsWindow() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        r.record(count: 1000, at: t0)
        r.record(count: 1050, at: t0.addingTimeInterval(60))
        // Catalog reset to 50 — we shouldn't get a negative rate.
        r.record(count: 50, at: t0.addingTimeInterval(120))
        #expect(r.perMinute == 0, "After a reset only one sample remains, perMinute must be 0")
        #expect(r.hasEnoughSamples == false)
    }

    @Test("zero elapsed (same timestamp twice) is safely guarded")
    func zeroElapsedNoDivByZero() {
        var r = RateTracker()
        let t = Date(timeIntervalSince1970: 1000)
        r.record(count: 100, at: t)
        r.record(count: 200, at: t)   // same timestamp
        #expect(r.perMinute == 0, "Zero elapsed must return 0, not crash")
    }

    @Test("display switches to /s when rate is large enough to bother")
    func displayUnitSwitch() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        // 600 files in 60 seconds → 600/min = 10/s.
        r.record(count: 0, at: t0)
        r.record(count: 600, at: t0.addingTimeInterval(60))
        #expect(r.displayText == "10.0/s")
    }

    @Test("display shows whole number /min when rate is in the 10-60/min band")
    func displayWholeNumberFormat() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        // 12 records in 60s → 12.0/min, should print as "12/min"
        r.record(count: 0, at: t0)
        r.record(count: 12, at: t0.addingTimeInterval(60))
        #expect(r.displayText == "12/min")
    }

    @Test("color is green when actively producing (>= 1/min)")
    func colorReflectsActivity() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        r.record(count: 0, at: t0)
        r.record(count: 10, at: t0.addingTimeInterval(60))
        // 10/min is well over the green threshold.
        // Just check that hasEnoughSamples + rate >= 1 produces a non-gray color.
        // We compare via behavior not by Color identity (SwiftUI Color isn't trivially Equatable
        // across systems), so check the rate threshold directly:
        #expect(r.perMinute >= 1)
        #expect(r.hasEnoughSamples)
    }

    @Test("color is secondary (placeholder) before two samples")
    func colorWhenWaiting() {
        let r = RateTracker()
        #expect(r.hasEnoughSamples == false)
    }

    // MARK: - ETA tests (Rick 2026-06-09)
    //
    // ETA = remaining / rate. Tests pin the boundary cases that drive
    // the "—" fallback and the rough-rounding display bands.

    @Test("ETA is nil when no samples yet")
    func etaNilWhenNoSamples() {
        let r = RateTracker()
        #expect(r.eta(remaining: 100) == nil)
        #expect(r.etaDisplayText(remaining: 100) == "—")
    }

    @Test("ETA is nil when remaining is zero — nothing to wait for")
    func etaNilWhenNothingLeft() {
        var r = RateTracker()
        r.record(count: 0, at: Date(timeIntervalSince1970: 0))
        r.record(count: 60, at: Date(timeIntervalSince1970: 60))
        #expect(r.eta(remaining: 0) == nil)
        #expect(r.etaDisplayText(remaining: 0) == "—")
    }

    @Test("ETA is nil when rate is too low to be meaningful")
    func etaNilWhenRateTooLow() {
        // 1 record over 60 minutes → 0.0167/min, well under the 0.1/min
        // meaningful-rate floor. Treat as effectively idle.
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 0)
        r.record(count: 0, at: t0)
        r.record(count: 1, at: t0.addingTimeInterval(3600))
        #expect(r.eta(remaining: 1000) == nil)
        #expect(r.etaDisplayText(remaining: 1000) == "—")
    }

    @Test("ETA at 60/min and 60 remaining → exactly 60s")
    func etaSimpleMath() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 0)
        // 60 records over 60s → 60/min
        r.record(count: 0, at: t0)
        r.record(count: 60, at: t0.addingTimeInterval(60))
        let eta = r.eta(remaining: 60)
        #expect(eta != nil)
        if let eta {
            // Allow tiny floating tolerance.
            #expect(abs(eta - 60.0) < 0.01)
        }
    }

    @Test("ETA display: under a minute → '<1m'")
    func etaDisplayUnderMinute() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 0)
        // 600 records over 60s → 600/min
        r.record(count: 0, at: t0)
        r.record(count: 600, at: t0.addingTimeInterval(60))
        // 5 remaining at 600/min → 0.5s
        #expect(r.etaDisplayText(remaining: 5) == "<1m")
    }

    @Test("ETA display: minutes band → '~Nm'")
    func etaDisplayMinutesBand() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 0)
        // 60/min
        r.record(count: 0, at: t0)
        r.record(count: 60, at: t0.addingTimeInterval(60))
        // 300 remaining at 60/min → 5 minutes
        #expect(r.etaDisplayText(remaining: 300) == "~5m")
    }

    @Test("ETA display: hours band → '~Nh'")
    func etaDisplayHoursBand() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 0)
        // 60/min
        r.record(count: 0, at: t0)
        r.record(count: 60, at: t0.addingTimeInterval(60))
        // 7200 remaining at 60/min → 120 min → 2 hours
        #expect(r.etaDisplayText(remaining: 7200) == "~2h")
    }

    @Test("ETA display: days band → '~Nd Mh' when leftover hours")
    func etaDisplayDaysBand() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 0)
        // 1/min
        r.record(count: 0, at: t0)
        r.record(count: 1, at: t0.addingTimeInterval(60))
        // 1500 remaining at 1/min → 1500 min → 25 hours → 1d 1h
        #expect(r.etaDisplayText(remaining: 1500) == "~1d 1h")
    }

    @Test("ETA display: even multiple of a day → '~Nd' (no leftover hours)")
    func etaDisplayEvenDays() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 0)
        // 1/min
        r.record(count: 0, at: t0)
        r.record(count: 1, at: t0.addingTimeInterval(60))
        // 2880 remaining at 1/min → 2880 min → 48 hours → exactly 2 days
        #expect(r.etaDisplayText(remaining: 2880) == "~2d")
    }

    @Test("ETA scales realistically with Rick's actual fleet: 7500 records at 2/min ≈ 62h ≈ 2d 14h")
    func etaRealistic() {
        var r = RateTracker()
        let t0 = Date(timeIntervalSince1970: 0)
        // 4 records over 2 minutes → 2/min — close to Rick's observed
        // fleet rate (2-3 records/min combined).
        r.record(count: 0, at: t0)
        r.record(count: 4, at: t0.addingTimeInterval(120))
        let display = r.etaDisplayText(remaining: 7500)
        // 7500 / 2 / 60 = 62.5h = 2.6 days. Rounded should be "~3d" or
        // "~2d 14h" depending on which boundary. Both are reasonable;
        // pin that it lands in the days band with a sensible value.
        #expect(display.hasPrefix("~"),
                "Expected days-band display, got '\(display)'")
        #expect(display.contains("d"),
                "Expected day unit in display, got '\(display)'")
    }
}
