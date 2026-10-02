// TimingBudgetExpectations.swift — the app test target's mapping of a
// VideoScanCore TimingBudget.Judgement onto Swift Testing (GH #208,
// Rick 2026-10-02). Same three cases as VideoScanCoreTests' file of the
// same name; the RULE (strict when quiet, known issue up to 3× when busy,
// VIDEOSCAN_TIMING_STRICT=1 pins strict) lives only in TimingBudget.judge.
//   pass        → nothing
//   knownIssue  → withKnownIssue: green run, the miss is listed
//   fail        → Issue.record
//
// Under xcodebuild the override reaches the test process as
// TEST_RUNNER_VIDEOSCAN_TIMING_STRICT=1 (xcodebuild strips the prefix);
// scripts/nightly_local_tests.sh exports both spellings.

import Testing
import VideoScanCore

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
