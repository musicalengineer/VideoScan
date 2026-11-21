import Foundation
import Testing
@_spi(Testing) import VideoScanCore   // SPI: LogCapture.init and LogScope.with — the binders production cannot see
@testable import VideoScan

// MARK: - Capturing `appLog` in a test
//
// `appLog` is a get-only global: the sink bound for the CURRENT TASK TREE,
// else the production sink (a NullLogSink under a test host). A test that
// asserts on log lines binds its own sink for the duration of a closure:
//
//     @Test func myThing() async throws {
//         let sink = InMemoryLogSink()
//         try await withAppLog(sink) {
//             try await SomeJob().run()
//         }
//         #expect(sink.contains("did thing"))
//     }
//
// The binding is a task-local (VideoScanCore/TaskTreeScope.swift): it is
// visible to this test's task and every child task it starts, and to no
// other test. So a suite that captures the log does NOT need `.serialized`
// for that reason, and two tests running at once never see each other's
// lines. (Before 2026-11-20 this helper assigned a process-global, and its
// comment said `.serialized` made that safe. It did not: `.serialized`
// orders one suite's own tests; every other suite still ran beside it and
// could write into, or restore over, this test's sink.)
//
// What does NOT inherit the binding: `Task.detached`, GCD blocks, timers,
// NotificationCenter and Combine deliveries on a queue. Production code
// that logs from such a place carries the scope across with
// `TaskTreeScope.current` / `TaskTreeScope.detached`; a line that still
// escapes lands in the NullLogSink and the assertion on it fails loudly.
//
// (C++: this is gtest's "install the mock for this test" done with a
// thread_local that follows the coroutine, plus RAII for the uninstall.)
//
// Worst-case memory: LogCapture keeps at most 200 000 lines (~40 MB at
// 200 bytes a line) and counts, without storing, anything past that.

/// The inspectable test double. A thin shell over Core's `LogCapture`
/// (which owns the lock, the bound and the wait loop): the members are
/// re-declared HERE so the ~40 test files that use them need no
/// `import VideoScanCore` (the project builds with MemberImportVisibility).
final class InMemoryLogSink: LogSink {
    let capture: LogCapture
    var name: String { capture.name }
    var fileURL: URL? { nil }

    init(name: String = "in-memory") { capture = LogCapture(name: name) }

    /// Snapshot copy of every line written so far, in order.
    var lines: [String] { capture.lines }
    /// Convenience for `#expect(sink.joined.contains("…"))`.
    var joined: String { capture.joined }
    var count: Int { capture.count }
    /// Empty the buffer (between phases of a multi-step test).
    func clear() { capture.clear() }

    /// True when any line contains `text`.
    func contains(_ text: String) -> Bool { capture.contains(text) }
    func lines(containing text: String) -> [String] { capture.lines(containing: text) }
    func lines(matching predicate: (String) -> Bool) -> [String] { capture.lines(matching: predicate) }

    /// The first line containing `text`, waiting up to `timeout` for it;
    /// nil on timeout. Each poll suspends, so main-actor work (the MFO
    /// Center's OUTCOME hop) runs in between.
    func waitForLine(containing text: String, timeout: Duration = .seconds(5),
                     isolation: isolated (any Actor)? = #isolation) async -> String? {
        await capture.waitForLine(containing: text, timeout: timeout, isolation: isolation)
    }

    func waitForLine(timeout: Duration = .seconds(5),
                     isolation: isolated (any Actor)? = #isolation,
                     where predicate: (String) -> Bool) async -> String? {
        await capture.waitForLine(timeout: timeout, isolation: isolation, where: predicate)
    }

    // MARK: LogSink
    func start(append: Bool) { capture.start(append: append) }
    func write(_ line: String) { capture.write(line) }
    func flush() {}
    func close() { capture.close() }
}

/// Bind `sink` as `appLog` for `body` and every child task it starts.
/// Any `LogSink` works (a counting or thread-recording double too).
func withAppLog<R>(_ sink: any LogSink, _ body: () throws -> R) rethrows -> R {
    try LogScope.with(sink, body)
}

/// Async form. `isolation` keeps `body` on the caller's actor, so a
/// `@MainActor` test's closure can touch its non-Sendable locals.
func withAppLog<R>(
    _ sink: any LogSink,
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> R
) async rethrows -> R {
    try await LogScope.with(sink, isolation: isolation, body)
}

// MARK: - Expecting log lines (gmock-style)
//
// The EXPECT_CALL half of the mock log (Core: LogExpectations.swift, which
// has the full C++ mapping). Say up front which lines the code under test
// must write, how often and in what order; ONE issue at this call's line
// names everything unmet, with the captured lines that show why:
//
//     let (job, log) = await expectingLog(
//         .once(.hasPrefix("compare: ")),                       // START     EXPECT_CALL(...).Times(1)
//         .once(.hasPrefix("compare FAILED: ")),                // OUTCOME
//         .inOrder(.hasPrefix("compare: "), .hasPrefix("compare FAILED: ")),   // InSequence
//         .never(.hasPrefix("compare done: ")),                 //           .Times(0)
//         .noOtherLines(matching: .contains(stem))              // StrictMock, for this test's file
//     ) {
//         let job = center.startCompare(recordA: a, recordB: b)
//         await job.task?.value
//         return job
//     }
//
// A test file that writes expectations needs
// `@_spi(Testing) import VideoScanCore` (the project builds with
// MemberImportVisibility, and `.once(…)` is a Core member).

/// Run `body` with `sink` bound as `appLog`, then verify `expectations`.
/// After `body` returns it waits up to `waitingUpTo` for lines still to
/// come (the Center writes an OUTCOME one main-actor turn after the job's
/// task ends); a met or already-final verdict never waits. `settling`
/// (default none) is a fixed beat after that, then judged again — for a
/// `.never` / `.once` / `.noOtherLines` a LATE line would break. Returns
/// the body's value and the sink, for ad hoc assertions.
@discardableResult
func expectingLog<R>(
    _ expectations: LogExpectation...,
    waitingUpTo timeout: Duration = .seconds(5),
    settling: Duration = .zero,
    sink: InMemoryLogSink = InMemoryLogSink(name: "expecting"),
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> R
) async rethrows -> (value: R, log: InMemoryLogSink) {
    // Bound through the sink (a LogSink), judged on its capture: one buffer.
    let value = try await LogExpectations.run(expectations, capture: sink.capture, binding: sink, waitingUpTo: timeout,
                                              settling: settling, isolation: isolation,
                                              report: { Issue.record(Comment(rawValue: $0), sourceLocation: sourceLocation) },
                                              body)
    return (value, sink)
}

extension InMemoryLogSink {
    /// Checked after: verify expectations on a sink the test already
    /// bound, now. One issue names everything unmet. True when all are met.
    /// (C++: Mock::VerifyAndClearExpectations.)
    @discardableResult
    func verify(_ expectations: LogExpectation..., sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let report = capture.check(expectations)
        if let message = report.message { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
        return report.isMet
    }

    /// The same, first waiting (bounded) for lines still to come.
    @discardableResult
    func verify(_ expectations: LogExpectation..., waitingUpTo timeout: Duration, settling: Duration = .zero,
                isolation: isolated (any Actor)? = #isolation,
                sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await verify(expectations, waitingUpTo: timeout, settling: settling, isolation: isolation, sourceLocation: sourceLocation)
    }

    @discardableResult
    func verify(_ expectations: [LogExpectation], waitingUpTo timeout: Duration, settling: Duration = .zero,
                isolation: isolated (any Actor)? = #isolation,
                sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let report = await capture.check(expectations, waitingUpTo: timeout, settling: settling, isolation: isolation)
        if let message = report.message { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
        return report.isMet
    }
}
