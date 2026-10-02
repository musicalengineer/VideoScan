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

    // MARK: GH #208 — strict when quiet, known issue (≤ 3×) when busy
    //
    // All injected: load, cores and environment are parameters, so these
    // never sleep and never depend on what the host is doing.

    static let quiet = TimingBudget.LoadSample(load: 7.9, logicalCores: 16)   // < 8 = 50%
    static let busy = TimingBudget.LoadSample(load: 8.0, logicalCores: 16)    // = 50%: busy
    static let noEnv: [String: String] = [:]

    static func judge(_ measuredMS: Int, budgetMS: Int = 100,
                      before: TimingBudget.LoadSample = quiet, after: TimingBudget.LoadSample = quiet,
                      env: [String: String] = noEnv) -> TimingBudget.Judgement {
        TimingBudget.judge("t", budget: .milliseconds(budgetMS), measured: .milliseconds(measuredMS),
                           before: before, after: after, environment: env)
    }

    @Test("quiet machine is strict: under budget passes, any miss fails")
    func quietIsStrict() {
        #expect(Self.judge(99).verdict == .pass)
        #expect(Self.judge(99).strict)
        #expect(Self.judge(100).verdict == .fail, "a measurement equal to the budget is a miss (strict <)")
        #expect(Self.judge(101).verdict == .fail)
        #expect(Self.judge(250).verdict == .fail, "quiet never gets the busy band")
        #expect(Self.judge(101).modeReason == "quiet")
    }

    @Test("the busy threshold is half the logical cores, inclusive")
    func busyThreshold() {
        #expect(!Self.quiet.isBusy)
        #expect(Self.busy.isBusy)
        #expect(TimingBudget.LoadSample(load: 2.0, logicalCores: 4).isBusy)
        #expect(!TimingBudget.LoadSample(load: 1.99, logicalCores: 4).isBusy)
        #expect(!TimingBudget.LoadSample(load: nil, logicalCores: 16).isBusy, "unknown load is not an excuse")
        #expect(!TimingBudget.LoadSample(load: 99, logicalCores: 0).isBusy)
    }

    @Test("busy: a miss up to 3× is a known issue, over 3× fails; a pass is still a pass")
    func busyBand() {
        #expect(Self.judge(99, before: Self.busy).verdict == .pass)
        #expect(Self.judge(101, before: Self.busy).verdict == .knownIssue)
        #expect(Self.judge(300, before: Self.busy).verdict == .knownIssue, "exactly 3× is inside the band")
        #expect(Self.judge(301, before: Self.busy).verdict == .fail, "over 3× is a hang or a real regression")
        #expect(Self.judge(5_000, before: Self.busy).verdict == .fail)
        #expect(!Self.judge(101, before: Self.busy).strict)
    }

    @Test("busy if EITHER sample is busy — before or after the measurement")
    func eitherSampleMakesItBusy() {
        #expect(Self.judge(150, before: Self.busy, after: Self.quiet).verdict == .knownIssue)
        #expect(Self.judge(150, before: Self.quiet, after: Self.busy).verdict == .knownIssue)
        #expect(Self.judge(150, before: Self.quiet, after: Self.quiet).verdict == .fail)
    }

    @Test("VIDEOSCAN_TIMING_STRICT=1 forces strict on a busy machine and on GitHub")
    func strictOverride() {
        let strict = [TimingBudget.strictEnvironmentKey: "1"]
        #expect(TimingBudget.strictEnvironmentKey == "VIDEOSCAN_TIMING_STRICT")
        let j = Self.judge(150, before: Self.busy, after: Self.busy, env: strict)
        #expect(j.verdict == .fail)
        #expect(j.strict)
        #expect(j.modeReason == "VIDEOSCAN_TIMING_STRICT=1")
        #expect(Self.judge(150, env: strict.merging(["GITHUB_ACTIONS": "true"]) { a, _ in a }).verdict == .fail)
        #expect(Self.judge(99, before: Self.busy, env: strict).verdict == .pass)
        // Only "1" forces it; anything else leaves the load rule in charge.
        #expect(Self.judge(150, before: Self.busy, env: [TimingBudget.strictEnvironmentKey: "0"]).verdict == .knownIssue)
        #expect(Self.judge(150, before: Self.busy, env: [TimingBudget.strictEnvironmentKey: ""]).verdict == .knownIssue)
    }

    @Test("a GitHub-hosted runner is treated as busy (shared VM), never as a wider pass")
    func hostedRunnerIsBusy() {
        let gh = ["GITHUB_ACTIONS": "true"]
        #expect(Self.judge(99, env: gh).verdict == .pass)
        #expect(Self.judge(250, env: gh).verdict == .knownIssue)
        #expect(Self.judge(301, env: gh).verdict == .fail)
        #expect(Self.judge(250, env: gh).modeReason == "GitHub-hosted runner")
        #expect(Self.judge(250, env: ["CI": "1"]).verdict == .fail, "CI=1 is set locally too; it is not busy")
    }

    @Test("the budget is compared as written — the verdict never moves the number")
    func budgetIsNotRaised() {
        let j = Self.judge(150, before: Self.busy)
        #expect(j.budget == .milliseconds(100))
        #expect(j.measured == .milliseconds(150))
        #expect(abs(j.ratio - 1.5) < 1e-9)
    }

    @Test("one log line carries budget, measured, load and verdict")
    func logLine() {
        let line = Self.judge(150, budgetMS: 100,
                              before: TimingBudget.LoadSample(load: 9.25, logicalCores: 16),
                              after: TimingBudget.LoadSample(load: 10.0, logicalCores: 16)).logLine
        #expect(!line.contains("\n"))
        #expect(line.hasPrefix("[timing-budget] t:"))
        #expect(line.contains("budget 100.0 ms"))
        #expect(line.contains("measured 150.0 ms"))
        #expect(line.contains("1.50×"))
        #expect(line.contains("load 9.2→10.0 on 16 cores") || line.contains("load 9.3→10.0 on 16 cores"))
        #expect(line.contains("busy (busy) → known-issue"))
        #expect(Self.judge(150).logLine.contains("strict (quiet) → fail"))
    }

    // The Swift Testing mapping (TimingBudgetExpectations.swift). Each case
    // is checked the way it would fail if the mapping were wrong:
    //   - knownIssue recorded as a hard issue → this test fails;
    //   - fail recorded as known (or not at all) → the outer withKnownIssue
    //     sees no issue and fails the test.
    @Test("mapping: pass records nothing, known issue stays green, fail records an issue")
    func swiftTestingMapping() {
        recordTimingJudgement(Self.judge(99))
        recordTimingJudgement(Self.judge(150, before: Self.busy))
        withKnownIssue("a strict miss must record a real issue") {
            recordTimingJudgement(Self.judge(150))
        }
        withKnownIssue("a busy miss over 3× must record a real issue") {
            recordTimingJudgement(Self.judge(400, before: Self.busy))
        }
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
