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

    // GH #208 follow-up (2026-10-27): the threshold is tier-aware. Injected
    // core counts: M5 Ultra 30 logical / 10 fast ("Super"), M4 Max 16 / 12,
    // M1 Max 10 / 8, a single-tier host (fastCores nil).

    @Test("tier-aware: the Ultra (30 cores, 10 fast) is busy at 7 — the gauntlet's 8.0 and swift test's 11–14 are busy")
    func ultraIsJudgedByItsFastTier() {
        let ultra = { (load: Double) in TimingBudget.LoadSample(load: load, logicalCores: 30, fastCores: 10) }
        #expect(ultra(8.0).isBusy, "gauntlet 2026-10-27: load 8.0 on the Ultra was called quiet")
        #expect(ultra(11).isBusy)
        #expect(ultra(14).isBusy)
        #expect(ultra(7.0).isBusy, "threshold = 10 × 0.7 = 7, inclusive")
        #expect(!ultra(6.99).isBusy)
        #expect(!ultra(2).isBusy)
        #expect(ultra(1).busyThreshold == 7)
    }

    @Test("tier-aware: the M4 Max (16 cores, 12 fast) keeps its old threshold of 8")
    func m4ThresholdUnchanged() {
        let m4 = { (load: Double) in TimingBudget.LoadSample(load: load, logicalCores: 16, fastCores: 12) }
        #expect(m4(1).busyThreshold == 8)
        #expect(m4(8.0).isBusy)
        #expect(!m4(7.9).isBusy)
        #expect(m4(1).busyThreshold == TimingBudget.LoadSample(load: 1, logicalCores: 16).busyThreshold)
    }

    @Test("tier-aware: a single-tier host, or a nonsense tier count, falls back to half the logical cores")
    func singleTierFallsBack() {
        #expect(TimingBudget.busyLoadThreshold(logicalCores: 16, fastCores: nil) == 8)
        #expect(TimingBudget.busyLoadThreshold(logicalCores: 16, fastCores: 0) == 8)
        #expect(TimingBudget.busyLoadThreshold(logicalCores: 16, fastCores: 16) == 8, "all cores fast = one tier")
        #expect(TimingBudget.busyLoadThreshold(logicalCores: 16, fastCores: 40) == 8)
        #expect(TimingBudget.busyLoadThreshold(logicalCores: 10, fastCores: 8) == 5, "M1 Max: min(5, 5.6)")
        #expect(TimingBudget.busyLoadThreshold(logicalCores: 3, fastCores: nil) == 1.5, "GitHub runner VM")
    }

    @Test("tier-aware: judge on the Ultra at the gauntlet's load is a known issue, not a strict fail")
    func ultraGauntletMissIsKnownIssue() {
        let s = TimingBudget.LoadSample(load: 8.0, logicalCores: 30, fastCores: 10)
        let j = TimingBudget.judge("100k settled keystroke '1990s' (median of 5)", budget: .milliseconds(50),
                                   measured: .milliseconds(53), before: s, after: s, environment: [:])
        #expect(j.verdict == .knownIssue)
        #expect(j.modeReason == "busy")
        #expect(j.logLine.contains("on 30 cores (10 fast)"))
        // The nightly's strict pin still wins.
        let pinned = TimingBudget.judge("t", budget: .milliseconds(50), measured: .milliseconds(53), before: s, after: s,
                                        environment: [TimingBudget.strictEnvironmentKey: "1"])
        #expect(pinned.verdict == .fail)
    }

    @Test("tier-aware: the legacy load factor uses the same threshold")
    func legacyLoadFactorIsTierAware() {
        #expect(TimingBudget.loadFactor(debugBuild: true, loadAverage: 8, activeProcessors: 30, fastCores: 10, loadedHeadroom: 1.5) == 1.5)
        #expect(TimingBudget.loadFactor(debugBuild: true, loadAverage: 6, activeProcessors: 30, fastCores: 10, loadedHeadroom: 1.5) == 1)
        #expect(TimingBudget.loadFactor(debugBuild: true, loadAverage: 7.9, activeProcessors: 16, fastCores: 12, loadedHeadroom: 1.5) == 1)
        #expect(TimingBudget.loadFactor(debugBuild: true, loadAverage: 8, activeProcessors: 16, fastCores: 12, loadedHeadroom: 1.5) == 1.5)
    }

    @Test("this host's tier probe is consistent with its core count")
    func fastTierProbeIsSane() {
        let logical = ProcessInfo.processInfo.activeProcessorCount
        if let fast = TimingBudget.fastTierCores() {
            #expect(fast > 0 && fast < logical, "perflevel0 is a strict subset of the active cores")
        }
        #expect(TimingBudget.sampleLoad().fastCores == TimingBudget.fastTierCores())
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

// MARK: - Sanitizer runs (2026-10-04)

@Suite("TimingBudget — sanitizer runs")
struct TimingBudgetSanitizerTests {
    private let quiet = TimingBudget.LoadSample(load: 0.5, logicalCores: 16)

    @Test func factorsFollowTheSanitizer() {
        #expect(TimingBudget.sanitizerFactor(environment: [:]) == 1)
        // ×8 for ASan since 2026-10-14: the weekly runs measured up to 5.7×
        // on allocation-heavy tests (evidence in TimingBudget.sanitizerFactor).
        #expect(TimingBudget.sanitizerFactor(environment: ["VIDEOSCAN_SANITIZER": "address"]) == 8)
        #expect(TimingBudget.sanitizerFactor(environment: ["VIDEOSCAN_SANITIZER": "thread"]) == 15)
        #expect(TimingBudget.sanitizerFactor(environment: ["VIDEOSCAN_SANITIZER": "bogus"]) == 1)
    }

    @Test func debugCeilingWidensOnlyUnderASanitizer() {
        #expect(TimingBudget.debugCeiling(.milliseconds(100), environment: [:]) == .milliseconds(100))
        #expect(TimingBudget.debugCeiling(.milliseconds(100), environment: ["VIDEOSCAN_SANITIZER": "address"])
                == .milliseconds(800))
        #expect(TimingBudget.debugCeiling(.milliseconds(100), environment: ["VIDEOSCAN_SANITIZER": "thread"])
                == .milliseconds(1_500))
    }

    @Test func aSanitizerRunPassesInstrumentedSlownessButStillFailsAHang() {
        let env = ["VIDEOSCAN_SANITIZER": "thread"]
        func verdict(_ ms: Int) -> TimingBudget.Verdict {
            TimingBudget.judge("x", budget: .milliseconds(100), measured: .milliseconds(ms),
                               before: quiet, after: quiet, environment: env).verdict
        }
        #expect(verdict(1_000) == .pass, "10× under TSan is normal")
        #expect(verdict(3_000) == .knownIssue, "beyond 15× but within the busy band")
        #expect(verdict(5_000) == .fail, "beyond 45× is a hang")
    }

    @Test func withoutASanitizerAQuietMissStillFails() {
        let j = TimingBudget.judge("x", budget: .milliseconds(100), measured: .milliseconds(150),
                                   before: quiet, after: quiet, environment: [:])
        #expect(j.verdict == .fail)
    }
}

// MARK: - Relative budgets (GH #385, 2026-10-26)

@Suite("TimingBudget — relative budgets: the algorithm, not the host")
struct TimingBudgetRatioTests {

    @Test func growthPassesUpToTheLimitAndFailsBeyondIt() {
        let linear = TimingBudget.judgeGrowth("g", small: .milliseconds(10), large: .milliseconds(40),
                                              sizeRatio: 4, limit: 8)
        #expect(linear.passed && linear.ratio == 4)
        #expect(TimingBudget.judgeGrowth("g", small: .milliseconds(10), large: .milliseconds(80),
                                         sizeRatio: 4, limit: 8).passed, "at the limit passes")
        let quadratic = TimingBudget.judgeGrowth("g", small: .milliseconds(10), large: .milliseconds(160),
                                                 sizeRatio: 4, limit: 8)
        #expect(!quadratic.passed)
        #expect(quadratic.logLine.contains("1/4-size input") && quadratic.logLine.hasSuffix("fail"))
    }

    @Test func relativePassesUnderTheLimitAndAZeroReferenceNeverPasses() {
        #expect(TimingBudget.judgeRelative("r", measured: .milliseconds(20), reference: .milliseconds(100),
                                           referenceName: "a full pass", limit: 0.5).passed)
        #expect(!TimingBudget.judgeRelative("r", measured: .milliseconds(60), reference: .milliseconds(100),
                                            referenceName: "a full pass", limit: 0.5).passed)
        #expect(!TimingBudget.judgeRelative("r", measured: .milliseconds(1), reference: .zero,
                                            referenceName: "nothing", limit: 100).passed,
                "a reference that took no time cannot vouch for anything")
    }

    @Test func onlyTheNightlysStrictPinIsTheReferenceRun() {
        #expect(TimingBudget.isReferenceRun(environment: ["VIDEOSCAN_TIMING_STRICT": "1"]))
        #expect(!TimingBudget.isReferenceRun(environment: [:]))
        #expect(!TimingBudget.isReferenceRun(environment: ["VIDEOSCAN_TIMING_STRICT": "0"]))
        #expect(!TimingBudget.isReferenceRun(environment: ["VIDEOSCAN_SANITIZER": "address"]))
    }

    /// The detector on real work, on this host whatever its speed: a linear
    /// loop grows ≈ 4× for a 4× input and passes ×8; a quadratic one grows
    /// ≈ 16× and fails it.
    @Test func aQuadraticLoopFailsTheGrowthLimitALinearOnePasses() {
        // A dependent LCG chain per step: no optimizer can fold it into a
        // closed form, so Release measures the loop as written.
        var sink: UInt64 = 1
        func step() { sink = sink &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        func linear(_ n: Int) { for _ in 0..<n { step() } }
        func quadratic(_ n: Int) { for _ in 0..<n { for _ in 0..<n { step() } } }
        let lin = TimingBudget.interleavedMinimumCPUTime(rounds: 3, reference: { _ in linear(500_000) },
                                                         measured: { _ in linear(2_000_000) })
        let quad = TimingBudget.interleavedMinimumCPUTime(rounds: 3, reference: { _ in quadratic(500) },
                                                          measured: { _ in quadratic(2_000) })
        let l = TimingBudget.judgeGrowth("linear", small: lin.reference, large: lin.measured, sizeRatio: 4, limit: 8)
        let q = TimingBudget.judgeGrowth("quadratic", small: quad.reference, large: quad.measured,
                                         sizeRatio: 4, limit: 8)
        #expect(l.passed, Comment(rawValue: l.logLine))
        #expect(!q.passed, Comment(rawValue: q.logLine))
        #expect(sink != 42)   // keep the loops observable
    }
}
