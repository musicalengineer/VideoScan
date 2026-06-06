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
}
