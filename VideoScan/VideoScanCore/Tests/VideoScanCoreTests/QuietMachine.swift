// QuietMachine.swift — the ONE declaration of "this test needs a quiet
// machine" for VideoScanCoreTests (2026-11-20, the parallel Core lane).
//
// The Core lane (scripts/core_lane.py) runs in two phases:
//   phase A — every test NOT marked here, in parallel, timing not strict;
//   phase B — only the marked tests, one at a time (`--no-parallel`), with
//             VIDEOSCAN_TIMING_STRICT as the lane set it (the nightly: 1).
//             Since 2026-11-21 as K serial strands side by side (each a
//             process running its share one test at a time; `--quiet-jobs`).
//             A marked test that fails beside the other strands is run again
//             ALONE before it is judged: red only if it fails alone too, and
//             named on an AMBER line when it passed alone. So the mark still
//             means "judge me on a quiet machine" — do not loosen a budget
//             because a strand was noisy; read the AMBER list instead.
// The split is read from the BUILT test bundle (Swift Testing's test listing
// carries each test's tags; the XCTest base class below names its subclasses),
// so it is declared here, at the test, and nowhere else: there is no list in a
// script to forget.
//
// What qualifies (mark the test, or the suite when every test in it does):
//   1. it judges a wall-time budget — through the TimingBudget helpers
//      (expectWithinTimingBudget, expectWithinReferenceTimingBudget,
//      recordTimingJudgement, expectRatio, assertTimingJudgements) or with a
//      bare assertion that orders a clock reading (`#expect(elapsed < …)`,
//      `XCTAssertLessThan(elapsed, …)`, two `clock.measure` windows compared);
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
// How it is pinned, and how far (review 2026-11-21):
//   - scripts/core_lane.py `check` (in the sensor lane, a SOURCE scan): a test
//     that reaches a judging or resident-size helper, or orders a clock
//     reading in an assertion, must carry the mark. The helper rule is by
//     name; the bare-assertion rule is a heuristic that errs toward flagging
//     (a clock read in the assertion, or a local initialized from a clock or
//     from a helper that returns one). A reviewed comparison that is not a
//     budget is let through on its own line with
//         // quiet-machine: not a budget — <why>
//     Category 3 (a real-time window) has no rule: it is marked by hand when
//     it fails under load.
//   - at run time the lane tells each test process its phase
//     (VIDEOSCAN_CORE_PHASE): the judging helpers record an issue whenever
//     they run in the parallel phase, and so does every test of a
//     QuietMachineXCTestCase subclass. recordTimingJudgement / expectRatio
//     also record one when the running test is unmarked.
//   - the lane refuses to start when the built bundle's listing disagrees
//     with the source about how many tests are marked.
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
///
/// Keep subclasses internal and top-level: the lane matches the name written
/// here (`NSStringFromClass`) against the XCTest listing's `Module.Class`,
/// and refuses the run when a private or nested class's mangled name is not
/// in it (it never drops the class into the parallel phase).
class QuietMachineXCTestCase: XCTestCase {
    static let listEnvironmentKey = "VIDEOSCAN_QUIET_XCTEST_LIST"

    override class var defaultTestSuite: XCTestSuite {
        let suite = super.defaultTestSuite
        if self != QuietMachineXCTestCase.self, suite.testCaseCount > 0,
           let path = ProcessInfo.processInfo.environment[listEnvironmentKey], !path.isEmpty {
            let line = Array((NSStringFromClass(self) + "\n").utf8)
            // O_APPEND: one short write per class, whole or not at all. A list
            // that cannot be written is a listing that FAILED (review F3): the
            // listing process stops here, the lane reads its exit as "could not
            // list" and runs nothing — a class missing from the list would run
            // in the parallel phase without a word. Only ever in the listing
            // process (the key is set by scripts/core_lane.py list_bundle).
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0, write(fd, line, line.count) == line.count else {
                fatalError("\(Self.listEnvironmentKey)=\(path): cannot record \(NSStringFromClass(self)) (errno \(errno))")
            }
            close(fd)
        }
        return suite
    }

    /// A subclass's test never runs in the lane's parallel phase.
    override func setUp() {
        super.setUp()
        if let problem = QuietMachinePhase.problem() { XCTFail(problem) }
    }
}

/// Which phase of the Core lane this test PROCESS is in. scripts/core_lane.py
/// sets VIDEOSCAN_CORE_PHASE to "parallel" (phase A) or "serial" (phase B);
/// any other runner (`swift test`, Xcode, CI) sets nothing. The mark says
/// where a test must run; this says where it is running, so the helpers that
/// judge time can refuse the parallel phase themselves (review F2): a mark
/// the build lost, or a lane that did not honour it, is a failed test, not a
/// budget quietly judged beside 2,400 neighbours with strictness off.
enum QuietMachinePhase {
    static let environmentKey = "VIDEOSCAN_CORE_PHASE"
    static let parallel = "parallel"

    /// Nil unless this process is the lane's parallel phase; then the sentence to record.
    static func problem(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard environment[environmentKey] == parallel else { return nil }
        return "a quiet-machine test is running in the Core lane's PARALLEL phase (\(environmentKey)=\(parallel)): "
            + "its time includes its neighbours' and strict timing is off. Its mark was lost or not honoured "
            + "(.tags(.quietMachine) / QuietMachineXCTestCase, QuietMachine.swift)."
    }
}
