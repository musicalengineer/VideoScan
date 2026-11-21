// QuietMachine.swift — the ONE declaration of "this test needs a quiet
// machine" for VideoScanCoreTests (2026-11-20, the parallel Core lane).
//
// The Core lane (scripts/core_lane.py) runs in two phases:
//   phase A — every test NOT marked here, in parallel, timing not strict;
//   phase B — only the marked tests, one at a time (`--no-parallel`), with
//             VIDEOSCAN_TIMING_STRICT as the lane set it (the nightly: 1).
// The split is read from the BUILT test bundle (Swift Testing's test listing
// carries each test's tags; the XCTest base class below names its subclasses),
// so it is declared here, at the test, and nowhere else: there is no list in a
// script to forget.
//
// What qualifies (mark the test, or the suite when every test in it does):
//   1. it judges a wall-time budget — through the TimingBudget helpers
//      (expectWithinTimingBudget, expectWithinReferenceTimingBudget,
//      recordTimingJudgement, expectRatio, assertTimingJudgements) or with a
//      bare `#expect(elapsed < …)`;
//   2. it asserts a bound on this PROCESS's resident size (in one process a
//      neighbour's allocations count as its growth: GH #208, 2.4 GB of
//      "growth" beside the 100k import);
//   3. its verdict depends on something happening within a fixed real-time
//      window (a 300 ms lock hold, a worker's idle cap, a poll that must see
//      a state before a deadline) and it has failed under load for that
//      reason;
//   4. it needs a resource only one test may hold at a time (say which, on
//      the line that marks it).
// What does NOT qualify: a test that is merely slow, or one that fails beside
// its neighbours because of shared state (a fixed temp path, a global, an
// environment variable). That is an isolation bug: fix the test.
//
// Pinned by scripts/core_lane.py `check` (in the sensor lane): every test
// that reaches a strict-timing or resident-size helper carries the mark; and
// at run time recordTimingJudgement / expectRatio record an issue when the
// running test does not (TimingBudgetExpectations.swift).
//
// C++ analogy: a Swift Testing tag is a label on a test case, like a ctest
// LABELS property; the lane runs `ctest -LE quietMachine -j N`, then
// `ctest -L quietMachine -j 1`.

import Foundation
import Testing
import XCTest

extension Tag {
    /// The test's verdict needs a quiet machine: it runs in the Core lane's
    /// serial phase (see the file header for what qualifies). Use
    /// `.tags(.quietMachine)` on the `@Test`, or on the `@Suite` when every
    /// test in it qualifies (a suite's tags apply to its tests).
    @Tag static var quietMachine: Self
}

/// The XCTest form of `.tags(.quietMachine)`: XCTest has no per-method
/// traits, so a class with at least one quiet-machine test inherits from this
/// instead of XCTestCase and the WHOLE class runs in the serial phase.
///
/// How the lane finds the subclasses: when it lists the bundle's XCTest cases
/// it sets VIDEOSCAN_QUIET_XCTEST_LIST to a file path, and each subclass
/// appends its `Module.Class` name there as XCTest builds its suite. Unset
/// (every real run) this is plain XCTestCase.
class QuietMachineXCTestCase: XCTestCase {
    static let listEnvironmentKey = "VIDEOSCAN_QUIET_XCTEST_LIST"

    override class var defaultTestSuite: XCTestSuite {
        let suite = super.defaultTestSuite
        if self != QuietMachineXCTestCase.self,
           let path = ProcessInfo.processInfo.environment[listEnvironmentKey], !path.isEmpty,
           let line = (NSStringFromClass(self) + "\n").data(using: .utf8) {
            // O_APPEND: one short write per class, whole or not at all.
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            if fd >= 0 {
                line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
                close(fd)
            }
        }
        return suite
    }
}
