// TaskTreeScope.swift (VideoScanCore)
// The second task-local test seam, and the ONE helper that carries both
// seams across a task-tree escape.
//
//   seam 1  ProcessRunner.executor   which child-process executor runs   (CommandExecutor.swift)
//   seam 2  LogScope.current         where the app's `appLog` lines go    (this file)
//
// WHY. Until 2026-11-20 tests captured log output by ASSIGNING the
// process-global `appLog`. One global ⇒ every suite that swapped it had to
// be `.serialized`, and even then another suite's test, running in parallel,
// could write into this test's sink or restore its own sink over it (a
// suite's `.serialized` orders only that suite's tests). The fix is the same
// as for the executor: a `@TaskLocal` a test binds for its own task tree.
//
//     let log = LogCapture()
//     await log.scoped { try await job.run() }      // app tests: `withAppLog(log) { … }`
//     #expect(log.contains("verify video done:"))
//
// The app's `appLog` (VideoScanApp.swift) is a get-only computed global:
// the sink bound for the current task tree, else the production sink.
// INSTEAD, not a tee: while a sink is bound, the lines go to it and
// nowhere else. A tee would add
// nothing (under a test host the production sink is a NullLogSink) and
// would let a test run outside a test host write to the real videoscan.log;
// "instead" also keeps exactly the semantics the old swap had, so no
// assertion changes meaning. In production nothing ever binds a capture, so
// the cost is one task-local read per log line (measured in
// LogCaptureSeamTests: tens of nanoseconds, against a write + fsync of
// tens of microseconds) and no lock is added to the hot path.
//
// For Rick (C++): `@TaskLocal` is a `thread_local` that follows the
// coroutine — and every child task it starts — instead of the OS thread.
// There is deliberately NO global setter.
//
// ESCAPES. A task-local reaches child tasks (`async let`, task groups,
// `Task {}`) but NOT `Task.detached`, GCD blocks, Combine sinks delivered on
// a queue, timers, NotificationCenter or Process handlers. A line logged
// there from inside a scoped test goes to the default sink (a NullLogSink
// under a test host) and the test's assertion on it fails — loud, not
// silent. To carry the scope across an escape, snapshot it and re-enter:
//
//     let scope = TaskTreeScope.current            // on the tree
//     queue.async { scope.run { appLog.write(…) } } // off the tree
//
// or use `TaskTreeScope.detached { … }` in place of `Task.detached { … }`,
// or `scope.carrying(callback)` for a callback another thread will call
// (ProcessRunner does this for its stdout/stderr callbacks, so the
// `Task { @MainActor in … }` hop every job makes from a progress line
// stays on the tree).
// `ProcessRunner.detachedKeepingExecutor` is that same function (it carries
// BOTH seams); there is one mechanism, not two.

import Foundation
import os

/// What a task tree's log lines can be scoped to. The app's `LogSink`
/// refines this, so a test may bind any of its doubles (a counting sink, a
/// thread-recording sink), not only `LogCapture`.
/// (C++: the minimal pure-virtual base the thread_local pointer is typed as.)
public protocol TaskScopedLogSink: AnyObject, Sendable {
    func write(_ line: String)
}

/// The task-local itself and the only way to bind it.
public enum LogScope {
    /// Internal setter on purpose: the only way to bind is `with`, which
    /// cannot outlive its closure. Nil in production, always.
    @TaskLocal static var bound: (any TaskScopedLogSink)? = nil

    /// The sink the current task tree logs into, if a test bound one.
    /// One task-local read; no lock.
    public static var current: (any TaskScopedLogSink)? { bound }

    /// Bind `sink` for `body` and every child task it starts. TEST USE
    /// ONLY (a sensor forbids it in production sources).
    public static func with<R>(_ sink: any TaskScopedLogSink, _ body: () throws -> R) rethrows -> R {
        try $bound.withValue(sink, operation: body)
    }

    /// Async form. `isolation` keeps `body` on the caller's actor (a
    /// `@MainActor` test stays on the main actor; nothing has to be
    /// Sendable to cross).
    public static func with<R>(
        _ sink: any TaskScopedLogSink,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> R
    ) async rethrows -> R {
        try await $bound.withValue(sink, operation: body, isolation: isolation)
    }
}

/// Records log lines for one test, thread-safely. Bind it for a task tree
/// with `scoped { … }`; read it with `lines` / `contains` / `waitForLine`.
///
/// Memory: one `String` per recorded line, bounded by `maxLines` (default
/// 200 000; at ~200 bytes a line that is ~40 MB worst case). Lines past the
/// bound are counted in `droppedCount`, never stored — a runaway loop cannot
/// take the test host down.
///
/// (C++: a `std::vector<std::string>` behind a `std::mutex`, plus a
/// `thread_local` pointer to "the vector for this test".)
public final class LogCapture: TaskScopedLogSink {
    public let name: String
    public let maxLines: Int

    private struct State {
        var lines: [String] = []
        var closed = false
        var dropped = 0
    }

    /// (`OSAllocatedUnfairLock` ≈ a `std::mutex` that owns the data it
    /// guards: the state is reachable only inside `withLock`.)
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(name: String = "capture", maxLines: Int = 200_000) {
        self.name = name
        self.maxLines = max(1, maxLines)
    }

    // MARK: Scoping

    /// Bind this capture for `body` and every child task it starts.
    public func scoped<R>(_ body: () throws -> R) rethrows -> R {
        try LogScope.with(self, body)
    }

    /// Async form; see `LogScope.with`.
    public func scoped<R>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> R
    ) async rethrows -> R {
        try await LogScope.with(self, isolation: isolation, body)
    }

    // MARK: Writing (the shape of the app's LogSink)

    /// Record one line. Ignored after `close()` until `start` reopens.
    public func write(_ line: String) {
        state.withLock { s in
            guard !s.closed else { return }
            if s.lines.count < maxLines { s.lines.append(line) } else { s.dropped += 1 }
        }
    }

    /// Reopen; `append: false` also empties the buffer.
    public func start(append: Bool) {
        state.withLock { s in
            if !append { s.lines.removeAll(keepingCapacity: true); s.dropped = 0 }
            s.closed = false
        }
    }

    public func flush() {}

    /// Stop recording (later writes are discarded).
    public func close() { state.withLock { $0.closed = true } }

    /// Empty the buffer (between phases of a multi-step test).
    public func clear() {
        state.withLock { s in s.lines.removeAll(keepingCapacity: true); s.dropped = 0 }
    }

    // MARK: Reading

    /// A snapshot copy of every line recorded so far, in order.
    public var lines: [String] { state.withLock { $0.lines } }
    public var joined: String { lines.joined(separator: "\n") }
    public var count: Int { state.withLock { $0.lines.count } }
    /// Lines refused because the buffer was at `maxLines`.
    public var droppedCount: Int { state.withLock { $0.dropped } }

    /// True when any recorded line contains `text`.
    public func contains(_ text: String) -> Bool {
        state.withLock { s in s.lines.contains { $0.contains(text) } }
    }

    public func lines(containing text: String) -> [String] {
        lines.filter { $0.contains(text) }
    }

    public func lines(matching predicate: (String) -> Bool) -> [String] {
        lines.filter(predicate)
    }

    /// The first line satisfying `predicate`, waiting up to `timeout` for
    /// it to be logged; nil on timeout. Polls every 5 ms: each poll
    /// suspends, so a `@MainActor` caller lets main-actor work (the MFO
    /// Center's OUTCOME hop) run in between.
    public func waitForLine(
        timeout: Duration = .seconds(5),
        isolation: isolated (any Actor)? = #isolation,
        where predicate: (String) -> Bool
    ) async -> String? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let hit = lines.first(where: predicate) { return hit }
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(5))
            if Task.isCancelled { return lines.first(where: predicate) }
        }
    }

    public func waitForLine(
        containing text: String,
        timeout: Duration = .seconds(5),
        isolation: isolated (any Actor)? = #isolation
    ) async -> String? {
        await waitForLine(timeout: timeout, isolation: isolation) { $0.contains(text) }
    }
}

/// A snapshot of BOTH task-local seams, to carry across a task-tree escape.
/// In production it holds the real executor and no log sink, and re-entering
/// it changes nothing.
/// (C++: capturing the two thread_locals by value into the lambda you hand
/// to std::thread, and re-installing them at the top of the lambda.)
public struct TaskTreeScope: Sendable {
    let executor: any CommandExecutor
    let logSink: (any TaskScopedLogSink)?

    /// The scope of the task this is called from.
    public static var current: TaskTreeScope {
        TaskTreeScope(executor: ProcessRunner.executor, logSink: LogScope.bound)
    }

    /// True for the scope every production task has: no log sink bound,
    /// the real executor. Re-entering it changes nothing, so carriers skip
    /// the work.
    public var isProductionDefault: Bool { logSink == nil && executor is RealCommandExecutor }

    /// Run `body` under this scope — for a GCD block, a timer, a Combine
    /// sink or a callback that runs outside the task that made the scope.
    public func run<R>(_ body: () throws -> R) rethrows -> R {
        try ProcessRunner.$executor.withValue(executor) {
            try LogScope.$bound.withValue(logSink, operation: body)
        }
    }

    /// Async form of `run`.
    public func run<R>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> R
    ) async rethrows -> R {
        try await ProcessRunner.$executor.withValue(executor, operation: {
            try await LogScope.$bound.withValue(logSink, operation: body, isolation: isolation)
        }, isolation: isolation)
    }

    /// `callback`, re-entering this scope each time it is called — for a
    /// callback some other thread will invoke (ProcessRunner's pipe
    /// readers). For production's scope it returns `callback` ITSELF: no
    /// wrapper, nothing added to the reader path.
    /// (C++: std::bind-ing the thread_local snapshot into the callback.)
    public func carrying<A>(_ callback: (@Sendable (A) -> Void)?) -> (@Sendable (A) -> Void)? {
        guard let callback, !isProductionDefault else { return callback }
        return { value in self.run { callback(value) } }
    }

    /// `Task.detached` that keeps the caller's scope (a detached task
    /// inherits no task-locals). Same priority, isolation (none) and
    /// cancellation as `Task.detached`.
    public static func detached<Success: Sendable>(
        priority: TaskPriority? = nil,
        operation: sending @escaping () async -> Success
    ) -> Task<Success, Never> {
        let scope = current
        return Task.detached(priority: priority) {
            await ProcessRunner.$executor.withValue(scope.executor) {
                await LogScope.$bound.withValue(scope.logSink) { await operation() }
            }
        }
    }
}
