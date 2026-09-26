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
}
