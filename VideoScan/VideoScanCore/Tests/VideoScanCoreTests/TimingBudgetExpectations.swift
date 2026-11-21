// TimingBudgetExpectations.swift — maps a TimingBudget.Judgement onto
// Swift Testing (GH #208, 2026-10-02). The rule lives in VideoScanCore's
// TimingBudget.judge; this file only says what each verdict does to a test:
//   pass        → nothing
//   knownIssue  → withKnownIssue: the run stays green, the miss is listed
//   fail        → Issue.record: a real failure
// The app test target has the same mapping in its own
// TimingBudgetExpectations.swift (a test target cannot import another).
//
// C++ analogy: withKnownIssue is roughly an "expected failure" wrapper —
// the body is expected to record an issue; one that does is reported as
// known instead of failing the test.

import Foundation
import Testing
import VideoScanCore

/// Judges `measured` against `budget` (load sampled at `loadBefore` and
/// now), logs the one-line verdict, and records it on the current test.
@discardableResult
func expectWithinTimingBudget(
    _ label: String,
    measured: Duration,
    budget: Duration,
    loadBefore: TimingBudget.LoadSample,
    sourceLocation: SourceLocation = #_sourceLocation
) -> TimingBudget.Judgement {
    let judgement = TimingBudget.judgeNow(label, budget: budget, measured: measured,
                                          loadBefore: loadBefore)
    recordTimingJudgement(judgement, sourceLocation: sourceLocation)
    return judgement
}

/// Nil when `test` may judge a timing budget: it carries `.quietMachine`
/// (its own tag or a suite's), so the Core lane runs it in the serial phase
/// (QuietMachine.swift). Otherwise the sentence the helpers below record.
/// `test` nil (a detached task, an XCTest method) cannot be judged here; the
/// source check `scripts/core_lane.py check` covers those.
func quietMachineTagProblem(for test: Test?) -> String? {
    guard let test, !test.tags.contains(.quietMachine) else { return nil }
    return "\(test.name) judges a timing budget but is not tagged .quietMachine: in the Core lane's "
        + "parallel phase its time includes its neighbours'. Add .tags(.quietMachine) (QuietMachine.swift)."
}

private func requireQuietMachineTag(_ sourceLocation: SourceLocation) {
    if let problem = quietMachineTagProblem(for: Test.current) {
        Issue.record(Comment(rawValue: problem), sourceLocation: sourceLocation)
    }
    // Whatever the tag says: a budget judged in the lane's parallel phase is an issue.
    if let problem = QuietMachinePhase.problem() {
        Issue.record(Comment(rawValue: problem), sourceLocation: sourceLocation)
    }
}

/// GH #385: an absolute budget for a test whose machine-independent check
/// is a growth ratio. Judged and recorded on the reference run
/// (`TimingBudget.isReferenceRun`, the nightly); everywhere else the
/// verdict line is logged and nothing is recorded.
@discardableResult
func expectWithinReferenceTimingBudget(
    _ label: String,
    measured: Duration,
    budget: Duration,
    loadBefore: TimingBudget.LoadSample,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    sourceLocation: SourceLocation = #_sourceLocation
) -> TimingBudget.Judgement {
    let judgement = TimingBudget.judgeNow(label, budget: budget, measured: measured,
                                          loadBefore: loadBefore, environment: environment)
    if TimingBudget.isReferenceRun(environment: environment) {
        recordTimingJudgement(judgement, sourceLocation: sourceLocation)
    } else if judgement.verdict == .fail {
        // Off the reference run the number is logged, not asserted (GH #385) — except a
        // HANG: beyond 3× the budget `judge` fails in every mode, and a hang must never be
        // swallowed by a wrapper (Codex P2, 2026-10-31).
        recordTimingJudgement(judgement, sourceLocation: sourceLocation)
    } else {
        requireQuietMachineTag(sourceLocation)
        print("[timing-budget] (not the reference run: logged, not asserted — GH #385)")
    }
    return judgement
}

/// Logs a growth / relative verdict and records a failure when it did not pass.
func expectRatio(_ judgement: TimingBudget.RatioJudgement,
                 sourceLocation: SourceLocation = #_sourceLocation) {
    requireQuietMachineTag(sourceLocation)
    print(judgement.logLine)
    if !judgement.passed {
        Issue.record(Comment(rawValue: judgement.logLine), sourceLocation: sourceLocation)
    }
}

func recordTimingJudgement(_ judgement: TimingBudget.Judgement,
                           sourceLocation: SourceLocation = #_sourceLocation) {
    requireQuietMachineTag(sourceLocation)
    switch judgement.verdict {
    case .pass:
        return
    case .knownIssue:
        withKnownIssue("GH #208: timing miss on a busy machine (within \(Int(TimingBudget.busyMissLimit))× budget)",
                       sourceLocation: sourceLocation) {
            Issue.record(Comment(rawValue: judgement.logLine), sourceLocation: sourceLocation)
        }
    case .fail:
        Issue.record(Comment(rawValue: judgement.logLine), sourceLocation: sourceLocation)
    }
}
