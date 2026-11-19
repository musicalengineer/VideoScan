// WaitUntilStarvationTests.swift — BackgroundFixtures.waitUntil charges only the time its
// poller was scheduled (2026-11-18). RED before: under the M4's instrumented Debug run
// (`swift test --enable-code-coverage`) the scale suites held all 16 cooperative-pool
// threads for ~50 s, and 16 Background tests failed on a 5 s wall-clock wait for work that
// needed 15 ms. A fake clock plays the starvation; nothing here sleeps for real.

import Foundation
import Testing

/// Fake time: each sleep advances it by the next planned step (a stall is a long step).
final class FakeTime: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private var steps: [Duration]
    private let rest: Duration
    private(set) var polls = 0

    init(steps: [Duration], then rest: Duration) {
        self.steps = steps
        self.rest = rest
    }

    var now: Duration { lock.lock(); defer { lock.unlock() }; return elapsed }

    func sleep() {
        lock.lock(); defer { lock.unlock() }
        polls += 1
        elapsed += steps.isEmpty ? rest : steps.removeFirst()
    }
}

@Suite("waitUntil — the machine's wait is not the code's (2026-11-18)")
struct WaitUntilStarvationTests {

    @Test("a poller starved for 15 s still sees work that finished meanwhile")
    func starvedPollerStillSucceeds() async {
        let time = FakeTime(steps: Array(repeating: .seconds(3), count: 5), then: .milliseconds(10))
        let ok = await BackgroundFixtures.waitUntil(.seconds(5), now: { time.now }, sleep: { _ in time.sleep() }) {
            time.polls >= 8                                   // the job finished while the pool was busy elsewhere
        }
        #expect(ok)
    }

    @Test("a job that never finishes still fails after 5 s of polling on a prompt scheduler")
    func stuckJobFailsOnTime() async {
        let time = FakeTime(steps: [], then: .milliseconds(10))
        let ok = await BackgroundFixtures.waitUntil(.seconds(5), now: { time.now }, sleep: { _ in time.sleep() }) { false }
        #expect(!ok)
        #expect(time.now >= .seconds(5) && time.now <= .milliseconds(5_100), "\(time.now)")
    }

    @Test("a wait that is starved forever ends at its wall-clock ceiling")
    func permanentStarvationHitsTheCeiling() async {
        let time = FakeTime(steps: [], then: .seconds(3))
        let ok = await BackgroundFixtures.waitUntil(.seconds(5), now: { time.now }, sleep: { _ in time.sleep() }) { false }
        #expect(!ok)
        #expect(time.now >= .seconds(50) && time.now <= .seconds(103), "\(time.now)")
    }

    @Test("the real clock: a condition already true returns at once")
    func realClockSmoke() async {
        #expect(await BackgroundFixtures.waitUntil { true })
    }
}
