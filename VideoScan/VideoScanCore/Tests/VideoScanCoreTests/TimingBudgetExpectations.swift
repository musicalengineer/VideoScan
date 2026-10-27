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
    sourceLocation: SourceLocation = #_sourceLocation
) -> TimingBudget.Judgement {
    let judgement = TimingBudget.judgeNow(label, budget: budget, measured: measured,
                                          loadBefore: loadBefore)
    if TimingBudget.isReferenceRun() {
        recordTimingJudgement(judgement, sourceLocation: sourceLocation)
    } else {
        print("[timing-budget] (not the reference run: logged, not asserted — GH #385)")
    }
    return judgement
}

/// Logs a growth / relative verdict and records a failure when it did not pass.
func expectRatio(_ judgement: TimingBudget.RatioJudgement,
                 sourceLocation: SourceLocation = #_sourceLocation) {
    print(judgement.logLine)
    if !judgement.passed {
        Issue.record(Comment(rawValue: judgement.logLine), sourceLocation: sourceLocation)
    }
}

func recordTimingJudgement(_ judgement: TimingBudget.Judgement,
                           sourceLocation: SourceLocation = #_sourceLocation) {
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
