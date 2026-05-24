import Foundation

// MARK: - LogSink — the DI seam for app-level logging
//
// A protocol abstraction over the destination of `appLog` writes. The
// production implementation (`PersistentLog`) writes to a flat file under
// ~/Library/Logs/VideoScan/; test doubles in `LogSinks+Test.swift` route
// writes to /dev/null or an in-memory buffer.
//
// This is the FIRST of several DI seams Rick is introducing. The shape
// below is the reference: a small protocol that matches the existing
// production type's external surface, conformed-to by the existing type
// (no rename, no wrapper), with the global symbol typed as the protocol
// so test code can swap the instance.
//
// Why a protocol (not an `actor` and not a closure):
//   - The 32 call sites already use synchronous `.write("…")` and no one
//     awaits — wrapping in an actor would force `await` everywhere and
//     drag MainActor isolation problems into the catalog/scan code.
//   - A closure (`var logLine: (String) -> Void`) couldn't carry the
//     fileURL the crash guard needs, and would lose the start/close
//     lifecycle that PersistentLog already implements.
//
// Swift's `protocol` here is roughly a C++ pure-virtual abstract base
// class — the concrete types implement the methods, and `appLog` holds
// an existential (`LogSink`) that dispatches dynamically.
protocol LogSink: AnyObject, Sendable {
    /// Human-readable name (used in headers and diagnostics).
    var name: String { get }

    /// File-backed sinks return their on-disk URL; in-memory and null
    /// sinks return nil. Only the crash-guard installer needs this —
    /// no general-purpose code should branch on it.
    var fileURL: URL? { get }

    /// Open / prepare the sink. For file sinks this opens the FileHandle
    /// and writes a header. For in-memory sinks this clears the buffer.
    /// `append` is honoured by file sinks; non-file sinks ignore it.
    func start(append: Bool)

    /// Append a single line. Implementations decide whether to add a
    /// timestamp and trailing newline (PersistentLog does both).
    func write(_ line: String)

    /// Force any buffered output to its backing store. PersistentLog
    /// already flushes on every write — flush is a no-op for it — but
    /// custom sinks (or a future buffered impl) may use it.
    func flush()

    /// Tear down. After close(), writes should be discarded or queued
    /// per the implementation's contract.
    func close()
}

// MARK: - NullLogSink (production-side)
//
// Discards every write. Used as the safe default for the global `appLog`
// when the binary is being hosted by XCTest / Swift Testing — that way
// even if a test forgets to inject an explicit sink, nothing leaks to
// ~/Library/Logs/VideoScan/videoscan.log. Lives in production code (not
// the test target) because the global `appLog` initializer below has to
// reference it.
//
// `final class … : @unchecked Sendable` matches the existing
// PersistentLog convention — no mutable state to guard.
final class NullLogSink: LogSink, @unchecked Sendable {
    let name: String
    var fileURL: URL? { nil }

    init(name: String = "null") {
        self.name = name
    }

    func start(append: Bool) {}
    func write(_ line: String) {}
    func flush() {}
    func close() {}
}

