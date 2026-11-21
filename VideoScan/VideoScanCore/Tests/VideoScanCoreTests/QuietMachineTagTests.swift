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
