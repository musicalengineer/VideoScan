// PerformanceLaneTests.swift
// 2026-09-23 — the Release perf gate never ran. `xcodebuild test` sets
// LLVM_PROFILE_FILE=/dev/null in the test runner even with
// `-enableCodeCoverage NO`, and PerformanceLane treated ANY value as
// "coverage on", so every strict Release budget (HallieQueryBench p95 <
// 100 ms, the GEDCOM sensors, the transcript render sensor …) was skipped
// on the very lane built to enforce it.
//
// Swift Testing: `#expect(x)` is EXPECT_TRUE (records and continues);
// `#require` is ASSERT_TRUE (stops the test).

import Foundation
import MachO
import Testing
@testable import VideoScan

@Suite("PerformanceLane — coverage detection")
struct PerformanceLaneTests {

    static let key = "VIDEOSCAN_TEST_PERF_OPTIN"

    private func authoritative(_ env: [String: String], debug: Bool = false) -> Bool {
        PerformanceLane.isAuthoritative(debugBuild: debug, optInKey: Self.key, environment: env)
    }

    @Test("LLVM_PROFILE_FILE=/dev/null (Xcode's coverage-off value) is coverage OFF")
    func devNullIsCoverageOff() {
        #expect(authoritative([Self.key: "1", "LLVM_PROFILE_FILE": "/dev/null"]))
    }

    @Test("empty LLVM_PROFILE_FILE is coverage OFF")
    func emptyIsCoverageOff() {
        #expect(authoritative([Self.key: "1", "LLVM_PROFILE_FILE": ""]))
    }

    @Test("a real profraw path is coverage ON — never authoritative")
    func realPathIsCoverageOn() {
        #expect(!authoritative([Self.key: "1", "LLVM_PROFILE_FILE": "/tmp/default.profraw"]))
        #expect(!authoritative([Self.key: "1",
            "LLVM_PROFILE_FILE": "/Users/x/Library/Developer/Xcode/DerivedData/VS/Build/ProfileData/ABC/%p.profraw"]))
    }

    @Test("coverageEnabled: unset / empty / /dev/null are off; any real path is on")
    func coverageEnabledPredicate() {
        #expect(!PerformanceLane.coverageEnabled(environment: [:]))
        #expect(!PerformanceLane.coverageEnabled(environment: ["LLVM_PROFILE_FILE": ""]))
        #expect(!PerformanceLane.coverageEnabled(environment: ["LLVM_PROFILE_FILE": "/dev/null"]))
        #expect(PerformanceLane.coverageEnabled(environment: ["LLVM_PROFILE_FILE": "/tmp/default.profraw"]))
        #expect(PerformanceLane.coverageEnabled(environment: ["LLVM_PROFILE_FILE": "default-%p.profraw"]))
    }

    @Test("Release + opt-in + coverage off are all still required")
    func otherConditionsStillRequired() {
        let off = ["LLVM_PROFILE_FILE": "/dev/null"]
        #expect(!authoritative(off.merging([Self.key: "1"]) { $1 }, debug: true), "Debug is never authoritative")
        #expect(!authoritative(off), "no opt-in")
        #expect(!authoritative(off.merging([Self.key: "0"]) { $1 }), "opt-in must be exactly 1")
        #expect(authoritative([Self.key: "1"]), "variable absent = coverage off")
    }

    /// True when any loaded Mach-O image carries LLVM profile counters.
    /// Not `dlsym("__llvm_profile_write_file")`: the profile runtime's
    /// symbols are hidden, so dlsym says "not instrumented" even on a
    /// coverage build (nightly 2026-09-24 went red on exactly that).
    private static func anyImageHasProfileCounters() -> Bool {
        (0..<_dyld_image_count()).contains { index in
            guard let header = _dyld_get_image_header(index) else { return false }
            var size: UInt = 0
            return header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
                getsectiondata($0, "__DATA", "__llvm_prf_cnts", &size) != nil && size > 0
            }
        }
    }

    /// Sensor: the environment rule must agree with what the binary actually
    /// is. A coverage build links the LLVM profile runtime; a non-coverage
    /// build does not. If Xcode ever changes what it puts in
    /// LLVM_PROFILE_FILE, this goes red instead of the perf gate silently
    /// switching itself off again.
    @Test("sensor: env rule agrees with the live binary's instrumentation")
    func envRuleMatchesBinaryInstrumentation() {
        let env = ProcessInfo.processInfo.environment
        let instrumented = Self.anyImageHasProfileCounters()
        let envSaysCoverageOn = PerformanceLane.coverageEnabled(environment: env)
        #expect(envSaysCoverageOn == !authoritative(env.merging([Self.key: "1"]) { $1 }),
                "isAuthoritative must use the same coverage rule")
        print("[PerformanceLane] LLVM_PROFILE_FILE=\(env["LLVM_PROFILE_FILE"].map { "'\($0)'" } ?? "<unset>") instrumented=\(instrumented)")
        // Red with env=on, instrumented=false is usually NOT a sensor bug:
        // it is `test-without-building -enableCodeCoverage YES` over a
        // build-for-testing made without coverage (CI run 36202513830) —
        // xcodebuild names a profraw path the binary can never write, and
        // "coverage" silently reports nothing.
        let hint = envSaysCoverageOn && !instrumented
            ? " — coverage requested at test time for a binary built without it (pass -enableCodeCoverage to the BUILD step too, or drop it from the test step)"
            : ""
        #expect(envSaysCoverageOn == instrumented,
                "LLVM_PROFILE_FILE=\(env["LLVM_PROFILE_FILE"] ?? "<unset>") but profile counters present=\(instrumented)\(hint)")
    }
}

/// 2026-09-24 (CI run 36068753075): the 100k scale budgets now all route
/// through `debugCeiling`. These pin that the widening happens ONLY on a
/// GitHub-hosted runner — every local / nightly / fleet run still asserts
/// the original number.
@Suite("PerformanceLane — hosted-runner Debug ceiling")
struct PerformanceLaneHostedRunnerTests {

    @Test("off GitHub the ceiling is exactly the budget; CI=1 alone does not widen it")
    func localCeilingIsTheBudget() {
        for budget in [Duration.milliseconds(200), .milliseconds(400), .seconds(1), .seconds(2), .seconds(4)] {
            #expect(PerformanceLane.debugCeiling(budget, environment: [:]) == budget)
            #expect(PerformanceLane.debugCeiling(budget, environment: ["CI": "1"]) == budget)
            #expect(PerformanceLane.debugCeiling(budget, environment: ["GITHUB_ACTIONS": "false"]) == budget)
        }
    }

    @Test("on a GitHub-hosted runner the ceiling is 3× the budget")
    func hostedCeilingIsTripled() {
        #expect(PerformanceLane.debugCeiling(.seconds(2), environment: ["GITHUB_ACTIONS": "true"]) == .seconds(6))
        #expect(PerformanceLane.debugCeiling(.milliseconds(400), environment: ["GITHUB_ACTIONS": "true"]) == .milliseconds(1_200))
    }

    /// Sensor on the LIVE process: a run on Rick's machines (no
    /// GITHUB_ACTIONS=true) must be held to the unscaled budget.
    @Test("sensor: this process's ceiling matches its environment")
    func liveCeilingMatchesEnvironment() {
        let onGitHub = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
        let ceiling = PerformanceLane.debugCeiling(.seconds(2))
        #expect(ceiling == (onGitHub ? .seconds(6) : .seconds(2)), "GITHUB_ACTIONS=\(onGitHub) ceiling \(ceiling)")
        // The Double forms use the same multiplier.
        #expect(PerformanceLane.debugCeiling(seconds: 2.0) == (onGitHub ? 6.0 : 2.0))
        #expect(PerformanceLane.debugCeiling(milliseconds: 1_500) == (onGitHub ? 4_500 : 1_500))
    }
}

@Suite("PerformanceLane — load-aware Debug ceiling")
struct PerformanceLaneLoadTests {

    @Test("busy Debug (load ≥ half the cores) gets the headroom; quiet Debug gets the plain budget")
    func debugHeadroomOnlyWhenBusy() {
        #expect(PerformanceLane.loadFactor(debugBuild: true, loadAverage: 8, activeProcessors: 16, loadedHeadroom: 1.5) == 1.5)
        #expect(PerformanceLane.loadFactor(debugBuild: true, loadAverage: 12.4, activeProcessors: 16, loadedHeadroom: 1.5) == 1.5)
        #expect(PerformanceLane.loadFactor(debugBuild: true, loadAverage: 7.9, activeProcessors: 16, loadedHeadroom: 1.5) == 1)
        #expect(PerformanceLane.loadFactor(debugBuild: true, loadAverage: 0.5, activeProcessors: 18, loadedHeadroom: 1.5) == 1)
    }

    @Test("Release never stretches, however busy")
    func releaseIsStrict() {
        #expect(PerformanceLane.loadFactor(debugBuild: false, loadAverage: 40, activeProcessors: 16, loadedHeadroom: 1.5) == 1)
    }

    @Test("unknown load or a nonsense headroom never loosens a budget below 1×")
    func degenerateInputs() {
        #expect(PerformanceLane.loadFactor(debugBuild: true, loadAverage: nil, activeProcessors: 16, loadedHeadroom: 1.5) == 1)
        #expect(PerformanceLane.loadFactor(debugBuild: true, loadAverage: 20, activeProcessors: 0, loadedHeadroom: 1.5) == 1)
        #expect(PerformanceLane.loadFactor(debugBuild: true, loadAverage: 20, activeProcessors: 16, loadedHeadroom: 0.5) == 1)
    }

    @Test("the live ceiling is the budget or the budget × headroom — never anything else")
    func liveCeilingIsOneOfTwo() {
        let budget = Duration.seconds(2)
        let ceiling = PerformanceLane.loadAwareDebugCeiling(budget, loadedHeadroom: 1.5)
        let plain = PerformanceLane.debugCeiling(budget)
        #expect(ceiling == plain || ceiling == plain * 1.5, "\(ceiling) (\(PerformanceLane.loadDescription()))")
        #expect(PerformanceLane.currentLoadAverage() != nil, "getloadavg answers on macOS")
    }
}
