// LogExpectationsTesting.swift — the test-side half of LogExpectations
// (Core source, LogExpectations.swift): run a body under a capture and turn
// the ONE failure message into ONE Issue at the caller's line. The app's
// VideoScanTests has the same few lines in LogSinks+Test.swift (Core cannot
// import Testing).
//
// (C++: the bridge from the mock's verdict to ADD_FAILURE_AT(file, line).)

import Testing
@_spi(Testing) @testable import VideoScanCore

/// Run `body` with a capture bound for its task tree, then verify
/// `expectations`: every unmet or violated one is named in a single issue
/// at the caller's line, with the captured lines that show it.
///
/// `waitingUpTo`: how long to wait, after `body` returns, for expectations
/// that a later line could still meet (an OUTCOME written one actor turn
/// after the job's task ended). A met or already-final verdict never waits;
/// pass `.zero` when everything is logged before `body` returns.
/// `settling` (default none): a fixed beat after that, then judged again —
/// for a `.never` / `.once` / `.noOtherLines` that a LATE line would break.
///
/// Returns the body's value and the capture, for ad hoc assertions.
@discardableResult
func expectingLog<R>(
    _ expectations: LogExpectation...,
    waitingUpTo timeout: Duration = .seconds(5),
    settling: Duration = .zero,
    capture: LogCapture = LogCapture(name: "expecting"),
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> R
) async rethrows -> (value: R, log: LogCapture) {
    let value = try await LogExpectations.run(expectations, capture: capture, waitingUpTo: timeout, settling: settling, isolation: isolation,
                                              report: { Issue.record(Comment(rawValue: $0), sourceLocation: sourceLocation) },
                                              body)
    return (value, capture)
}

extension LogCapture {
    /// Checked after: verify expectations on a capture the test already
    /// holds, now. One issue names everything unmet. True when all are met.
    /// (C++: Mock::VerifyAndClearExpectations.)
    @discardableResult
    func verify(_ expectations: LogExpectation..., sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let report = check(expectations)
        if let message = report.message { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
        return report.isMet
    }

    /// The same, first waiting (bounded) for lines still to come.
    @discardableResult
    func verify(
        _ expectations: LogExpectation...,
        waitingUpTo timeout: Duration,
        settling: Duration = .zero,
        isolation: isolated (any Actor)? = #isolation,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let report = await check(expectations, waitingUpTo: timeout, settling: settling, isolation: isolation)
        if let message = report.message { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
        return report.isMet
    }
}
