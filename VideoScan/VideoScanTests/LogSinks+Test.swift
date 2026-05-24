import Foundation
@testable import VideoScan

// MARK: - Test-only LogSink doubles
//
// `NullLogSink` lives in production (LogSink.swift) because the global
// `appLog` initializer falls back to it under test hosts. This file
// provides the *inspectable* test double — `InMemoryLogSink` — plus
// helpers tests use to swap `appLog` for the duration of a single test.
//
// Worst-case memory footprint: O(number of writes × line length).
// Tests should be short-lived enough that this stays trivial; if you
// write a stress test that loops millions of times, prefer NullLogSink
// or call `clear()` periodically.

/// Captures every `write(_:)` call into an in-memory array so tests can
/// assert on logged content without touching disk. Thread-safe — wraps
/// the buffer in an NSLock the same way PersistentLog does.
final class InMemoryLogSink: LogSink, @unchecked Sendable {
    let name: String

    /// In-memory buffers — read via `lines` / `joined` accessors which
    /// take the lock. Mutated only behind `lock`.
    private var buffer: [String] = []
    private var closed: Bool = false
    private let lock = NSLock()

    var fileURL: URL? { nil }

    init(name: String = "in-memory") {
        self.name = name
    }

    /// Returns a snapshot copy of all lines written so far. Safe to call
    /// from test code without worrying about concurrent writes mutating
    /// the array under iteration.
    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    /// Convenience for `#expect(sink.joined.contains("…"))`.
    var joined: String {
        lines.joined(separator: "\n")
    }

    /// Number of lines currently buffered.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    /// Empty the buffer (useful between phases of a multi-step test).
    func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
    }

    // MARK: LogSink

    func start(append: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !append {
            buffer.removeAll(keepingCapacity: true)
        }
        closed = false
    }

    func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        buffer.append(line)
    }

    func flush() { /* no-op — already in memory */ }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
    }
}

// MARK: - appLog swap helpers
//
// Tests that want to assert on what was logged should use
// `withAppLog(_:body:)` to swap in their own sink for the duration of
// the test, then restore the previous sink in `defer`. This pattern is
// the test-side equivalent of RAII / scope guards in C++.

/// Replace the global `appLog` with `sink` for the duration of `body`,
/// then restore whatever was there before. Use this in Swift Testing
/// `@Test` functions:
///
///     @Test func myThing() throws {
///         let sink = InMemoryLogSink()
///         try withAppLog(sink) {
///             SomeProductionCode().doThing()
///             #expect(sink.joined.contains("did thing"))
///         }
///     }
///
/// The swap is not thread-safe across concurrent tests — Swift Testing
/// parallelizes by default, so any test that uses this MUST either run
/// in a `@Suite(.serialized)` suite or hold an external mutex. Single
/// tests within a serialized suite are fine.
func withAppLog<R>(_ sink: LogSink, _ body: () throws -> R) rethrows -> R {
    let previous = appLog
    appLog = sink
    defer { appLog = previous }
    return try body()
}
