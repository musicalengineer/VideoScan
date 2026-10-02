// TimingBudgetXCTestSupport.swift — the XCTest form of
// TimingBudgetExpectations.swift (GH #208). XCTest has no "known issue",
// so a busy-machine miss within 3× becomes an XCTSkip whose message names
// the load; a strict miss or a miss beyond 3× is an XCTFail.
//
// Judge every measurement first, then call this once: every fail is
// reported, and only then (no fails) does a known issue skip the test —
// a skip thrown early would hide a later hard failure.

import XCTest
import VideoScanCore

func assertTimingJudgements(_ judgements: [TimingBudget.Judgement],
                            file: StaticString = #filePath, line: UInt = #line) throws {
    var anyFail = false
    for j in judgements where j.verdict == .fail {
        anyFail = true
        XCTFail(j.logLine, file: file, line: line)
    }
    guard !anyFail else { return }
    let known = judgements.filter { $0.verdict == .knownIssue }
    if !known.isEmpty {
        throw XCTSkip("GH #208 busy machine, timing miss within \(Int(TimingBudget.busyMissLimit))× budget: "
                      + known.map(\.logLine).joined(separator: "; "))
    }
}
