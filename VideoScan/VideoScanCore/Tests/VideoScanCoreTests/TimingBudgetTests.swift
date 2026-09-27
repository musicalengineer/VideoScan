// TimingBudgetTests.swift — pins that the shared test-budget rule only
// widens where it says it does. Every quiet local run must be held to the
// exact budget; the app-side PerformanceLaneTests pin the same numbers
// through PerformanceLane, which forwards here.
//
// Swift Testing: `#expect(x)` is EXPECT_TRUE (records and continues).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("TimingBudget — shared test-budget rule")
struct TimingBudgetTests {

    @Test("off GitHub the ceiling is exactly the budget; CI=1 alone does not widen it")
    func localCeilingIsTheBudget() {
        for budget in [Duration.milliseconds(50), .seconds(2), .seconds(20)] {
            #expect(TimingBudget.debugCeiling(budget, environment: [:]) == budget)
            #expect(TimingBudget.debugCeiling(budget, environment: ["CI": "1"]) == budget)
            #expect(TimingBudget.debugCeiling(budget, environment: ["GITHUB_ACTIONS": "false"]) == budget)
        }
    }

    @Test("GITHUB_ACTIONS=true triples it")
    func hostedIsTripled() {
        #expect(TimingBudget.debugCeiling(.seconds(3), environment: ["GITHUB_ACTIONS": "true"]) == .seconds(9))
    }

    @Test("load headroom: Debug and busy only; never below 1×")
    func loadRule() {
        #expect(TimingBudget.loadFactor(debugBuild: true, loadAverage: 8, activeProcessors: 16, loadedHeadroom: 1.5) == 1.5)
        #expect(TimingBudget.loadFactor(debugBuild: true, loadAverage: 7.9, activeProcessors: 16, loadedHeadroom: 1.5) == 1)
        #expect(TimingBudget.loadFactor(debugBuild: false, loadAverage: 40, activeProcessors: 16, loadedHeadroom: 1.5) == 1)
        #expect(TimingBudget.loadFactor(debugBuild: true, loadAverage: nil, activeProcessors: 16, loadedHeadroom: 1.5) == 1)
        #expect(TimingBudget.loadFactor(debugBuild: true, loadAverage: 20, activeProcessors: 16, loadedHeadroom: 0.5) == 1)
    }

    @Test("seconds(_:) converts a Duration exactly enough for budgets")
    func secondsConversion() {
        #expect(TimingBudget.seconds(.milliseconds(1_500)) == 1.5)
        #expect(TimingBudget.seconds(.zero) == 0)
    }

    // GH #208: thread CPU time counts work, not waiting. Both directions
    // are pinned — a clock that returned wall time would fail the sleep
    // case; one that returned zero (or another thread's time) would fail
    // the spin case.
    @Test("thread CPU time: a sleep costs ~nothing, a spin costs about its length")
    func threadCPUTimeCountsWorkNotWaiting() {
        let wall = ContinuousClock()
        var slept = Duration.zero
        let sleepCPU = TimingBudget.measureThreadCPUTime {
            slept = wall.measure { Thread.sleep(forTimeInterval: 0.3) }
        }
        #expect(slept >= .milliseconds(300))
        #expect(sleepCPU < .milliseconds(50), "sleeping 300 ms cost \(sleepCPU) of thread CPU")

        var sink: UInt64 = 0
        let spinCPU = TimingBudget.measureThreadCPUTime {
            let until = ContinuousClock.now + .milliseconds(200)
            while ContinuousClock.now < until { sink &+= 1 }
        }
        #expect(sink > 0)
        // On an idle core ~200 ms; allow for a busy host descheduling us.
        #expect(spinCPU >= .milliseconds(20), "spinning 200 ms wall cost only \(spinCPU) of thread CPU")
        #expect(spinCPU <= .milliseconds(260), "thread CPU \(spinCPU) exceeds the 200 ms spin — not per-thread?")
    }

    @Test("thread CPU time ignores other threads' work")
    func threadCPUTimeIsPerThread() {
        let done = DispatchSemaphore(value: 0)
        let cpu = TimingBudget.measureThreadCPUTime {
            DispatchQueue.global().async {
                var x: UInt64 = 0
                let until = ContinuousClock.now + .milliseconds(200)
                while ContinuousClock.now < until { x &+= 1 }
                if x == 0 { print("unreachable") }
                done.signal()
            }
            done.wait()
        }
        #expect(cpu < .milliseconds(50), "another thread's 200 ms spin was charged to this one: \(cpu)")
    }
}
