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

    /// Sensor: the environment rule must agree with what the binary actually
    /// is. A coverage build links the LLVM profile runtime; a non-coverage
    /// build does not. If Xcode ever changes what it puts in
    /// LLVM_PROFILE_FILE, this goes red instead of the perf gate silently
    /// switching itself off again.
    @Test("sensor: env rule agrees with the live binary's instrumentation")
    func envRuleMatchesBinaryInstrumentation() {
        let env = ProcessInfo.processInfo.environment
        let instrumented = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__llvm_profile_write_file") != nil
        let envSaysCoverageOn = PerformanceLane.coverageEnabled(environment: env)
        #expect(envSaysCoverageOn == !authoritative(env.merging([Self.key: "1"]) { $1 }),
                "isAuthoritative must use the same coverage rule")
        print("[PerformanceLane] LLVM_PROFILE_FILE=\(env["LLVM_PROFILE_FILE"].map { "'\($0)'" } ?? "<unset>") instrumented=\(instrumented)")
        #expect(envSaysCoverageOn == instrumented,
                "LLVM_PROFILE_FILE=\(env["LLVM_PROFILE_FILE"] ?? "<unset>") but profile runtime present=\(instrumented)")
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
