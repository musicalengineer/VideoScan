import Foundation
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
