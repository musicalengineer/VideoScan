// QuietMachineTagTests.swift — the run-time half of the quiet-machine pin
// (QuietMachine.swift; the source half is `scripts/core_lane.py check`).
// The timing helpers record an issue when the running test does not carry
// `.quietMachine`; these tests pin the rule that decides it, including that
// a suite's tag reaches its tests.

import Testing
import XCTest
@testable import VideoScanCore

@Suite("Quiet machine — who may judge a timing budget")
struct QuietMachineTagTests {
    @Test func anUntaggedTestIsToldToTagItself() throws {
        let problem = try #require(quietMachineTagProblem(for: Test.current))
        #expect(problem.contains(".tags(.quietMachine)") && problem.contains("anUntaggedTestIsToldToTagItself"))
    }

    @Test(.tags(.quietMachine)) func aTaggedTestMayJudge() {
        #expect(quietMachineTagProblem(for: Test.current) == nil)
    }

    @Test func outsideATestNothingIsClaimed() {
        #expect(quietMachineTagProblem(for: nil) == nil)
    }

    @Test func onlyTheLanesParallelPhaseIsAProblem() throws {
        #expect(QuietMachinePhase.problem(environment: [:]) == nil, "swift test, Xcode, CI: no phase, no claim")
        #expect(QuietMachinePhase.problem(environment: ["VIDEOSCAN_CORE_PHASE": "serial"]) == nil)
        let problem = try #require(QuietMachinePhase.problem(environment: ["VIDEOSCAN_CORE_PHASE": "parallel"]))
        #expect(problem.contains("PARALLEL phase") && problem.contains("VIDEOSCAN_CORE_PHASE=parallel"))
    }

    @Test func theKeyIsTheOneTheLaneSets() throws {
        // scripts/core_lane.py PHASE_KEY / PHASE_VALUE: one spelling on both sides.
        let lane = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/core_lane.py"), encoding: .utf8)
        #expect(lane.contains("PHASE_KEY = \"\(QuietMachinePhase.environmentKey)\""))
        #expect(lane.contains("\"A\": \"\(QuietMachinePhase.parallel)\""))
    }

    @Suite("a suite's tag reaches its tests", .tags(.quietMachine))
    struct TaggedSuite {
        @Test func aTestInATaggedSuiteMayJudge() {
            #expect(quietMachineTagProblem(for: Test.current) == nil)
        }
    }
}

/// The XCTest form: a subclass is an ordinary test case in a run, and names
/// itself to the lane only when the lane asks (the listing's environment key).
final class QuietMachineXCTestCaseTests: QuietMachineXCTestCase {
    func testASubclassRunsAsAnOrdinaryTestCase() {
        XCTAssertGreaterThan(Self.defaultTestSuite.testCaseCount, 0)
    }
}
