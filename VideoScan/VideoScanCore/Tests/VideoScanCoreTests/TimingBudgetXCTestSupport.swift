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
    // XCTest has no tag to read: the phase is the run-time check (QuietMachine.swift).
    if let problem = QuietMachinePhase.problem() { XCTFail(problem, file: file, line: line) }
    var anyFail = false
    for j in judgements where j.verdict == .fail {
        anyFail = true
        XCTFail("\(quietBudgetMarker) \(j.logLine)", file: file, line: line)
    }
    guard !anyFail else { return }
    let known = judgements.filter { $0.verdict == .knownIssue }
    if !known.isEmpty {
        throw XCTSkip("GH #208 busy machine, timing miss within \(Int(TimingBudget.busyMissLimit))× budget: "
                      + known.map(\.logLine).joined(separator: "; "))
    }
}

/// The XCTest form of `expectBudget`: `measured` under `limit`, reported with
/// `quietBudgetMarker` so the lane knows the failure is a budget and nothing
/// else. Use it instead of XCTAssertLessThan on a time or a resident size.
func XCTAssertBudget<T: Comparable>(_ measured: T, under limit: T, _ what: @autoclosure () -> String = "",
                                    file: StaticString = #filePath, line: UInt = #line) {
    if let problem = QuietMachinePhase.problem() { XCTFail(problem, file: file, line: line) }
    if !(measured < limit) {
        let about = what()
        XCTFail("\(quietBudgetMarker) measured \(measured), budget: under \(limit)" + (about.isEmpty ? "" : " — \(about)"),
                file: file, line: line)
    }
}

/// The same with `<=`.
func XCTAssertBudget<T: Comparable>(_ measured: T, atMost limit: T, _ what: @autoclosure () -> String = "",
                                    file: StaticString = #filePath, line: UInt = #line) {
    if let problem = QuietMachinePhase.problem() { XCTFail(problem, file: file, line: line) }
    if !(measured <= limit) {
        let about = what()
        XCTFail("\(quietBudgetMarker) measured \(measured), budget: at most \(limit)" + (about.isEmpty ? "" : " — \(about)"),
                file: file, line: line)
    }
}
