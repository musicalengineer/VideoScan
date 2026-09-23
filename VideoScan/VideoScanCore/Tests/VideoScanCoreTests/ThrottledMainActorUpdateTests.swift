// ThrottledMainActorUpdateTests.swift
// 2026-09-23 — root cause of the StressTests/LivePreviewPublishBenchmarkTests
// flake (nightly: 29,988 of 30,000 notifications = 4 whole updates lost).
// The throttle measured time with CFAbsoluteTimeGetCurrent(), which is the
// WALL clock: timed/NTP may step it backwards. `now - lastUpdate` then goes
// negative, so even interval 0 ("never throttle") dropped updates until
// the wall clock caught up. In production (0.25–0.3 s intervals) a large
// backwards step — a manual clock change, a time-zone/NTP correction after
// wake — would have frozen live previews / progress for that long.
//
// The clock is injected here so a backwards step is reproducible instead
// of waiting for timed to do it under load.
//
// C++ analogy: std::chrono::system_clock vs steady_clock — the fix is the
// same one you would make there.

import Foundation
import Testing
@testable import VideoScanCore

/// A hand-cranked clock. Sendable box with a lock so the actor's
/// `@Sendable () -> TimeInterval` can read it.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    init(_ start: TimeInterval) { t = start }
    func read() -> TimeInterval { lock.withLock { t } }
    func set(_ v: TimeInterval) { lock.withLock { t = v } }
}

@MainActor
private final class Counter { var n = 0 }

@Suite("ThrottledMainActorUpdate — clock semantics")
struct ThrottledMainActorUpdateTests {

    @Test("interval 0 never drops an update, even when the clock steps backwards")
    @MainActor
    func zeroIntervalSurvivesBackwardsClockStep() async {
        let clock = FakeClock(1_000_000)
        let throttle = ThrottledMainActorUpdate(intervalSecs: 0, now: { clock.read() })
        let counter = Counter()

        await throttle.update { counter.n += 1 }
        clock.set(1_000_000 - 0.000_040)          // 40 µs step back (timed-sized)
        await throttle.update { counter.n += 1 }
        await throttle.update { counter.n += 1 }
        clock.set(1_000_000 + 1)
        await throttle.update { counter.n += 1 }

        #expect(counter.n == 4, "interval 0 must pass every update; got \(counter.n) of 4")
    }

    @Test("a large backwards clock step does not freeze a real throttle")
    @MainActor
    func backwardsStepDoesNotFreezeNonZeroInterval() async {
        let clock = FakeClock(1_000_000)
        let throttle = ThrottledMainActorUpdate(intervalSecs: 0.25, now: { clock.read() })
        let counter = Counter()

        await throttle.update { counter.n += 1 }   // fires
        clock.set(1_000_000 - 3_600)               // clock set back an hour
        await throttle.update { counter.n += 1 }   // must fire, not wait an hour
        clock.set(1_000_000 - 3_600 + 0.1)
        await throttle.update { counter.n += 1 }   // inside the window → dropped
        clock.set(1_000_000 - 3_600 + 0.3)
        await throttle.update { counter.n += 1 }   // window elapsed → fires

        #expect(counter.n == 3, "expected fire, fire, drop, fire → 3; got \(counter.n)")
    }

    @Test("throttling still works: updates inside the interval are dropped")
    @MainActor
    func updatesInsideIntervalAreDropped() async {
        let clock = FakeClock(500)
        let throttle = ThrottledMainActorUpdate(intervalSecs: 0.25, now: { clock.read() })
        let counter = Counter()

        await throttle.update { counter.n += 1 }   // fires (first ever)
        clock.set(500.1)
        await throttle.update { counter.n += 1 }   // dropped
        clock.set(500.2)
        await throttle.update { counter.n += 1 }   // dropped (0.2 < 0.25)
        clock.set(500.25)
        await throttle.update { counter.n += 1 }   // fires (exactly the interval)
        #expect(counter.n == 2)
    }

    @Test("the production clock is monotonic, not the wall clock")
    func defaultClockIsMonotonic() {
        // Pins the source: systemUptime is mach-absolute-time based and can
        // never step backwards; CFAbsoluteTimeGetCurrent can.
        let a = ThrottledMainActorUpdate.monotonicSeconds()
        let b = ThrottledMainActorUpdate.monotonicSeconds()
        #expect(b >= a)
        let uptime = ProcessInfo.processInfo.systemUptime
        #expect(abs(b - uptime) < 5, "default clock should be system uptime, got \(b) vs uptime \(uptime)")
    }
}
