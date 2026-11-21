// ContainedLogWrite.swift (VideoScanCore)
//
// The one way a file-backed log sink puts bytes on disk (codex r1,
// 2026-11-21). `FileHandle.write(_:)` — the non-throwing spelling — RAISES
// an Objective-C NSFileHandleOperationException when write(2) fails (disk
// full, I/O error, the volume gone). Swift's `catch` cannot contain that, so
// a log line on a full disk took the app down — and the lines written on a
// full disk are the "…could not be written" diagnostics.
//
// This writes with the throwing API and contains every failure: a line that
// cannot be written is dropped and COUNTED, and the first write that works
// again is preceded, in the same write, by one line saying how many were
// lost and why. It never throws, never traps, and adds nothing to the bytes
// of a write that succeeds.
//
// Not thread-safe by itself: each sink calls it under the lock it already
// holds for its handle. State is two integers and one short string — it
// does not grow however long an outage lasts.
//
// For Rick (C++): a small value-type helper owned by the sink, like a
// member struct that wraps `::write()` and remembers a drop counter.

import Foundation

public struct ContainedLogWrite: Sendable {

    /// Lines dropped since the last write that landed.
    public private(set) var droppedLines = 0
    /// Lines dropped over the life of the sink (never reset; tests, forensics).
    public private(set) var totalDroppedLines = 0
    /// Why the most recent failed write failed.
    public private(set) var lastFailure = ""

    public init() {}

    /// Write `data` (which holds `lines` log lines) to `handle`. True when it
    /// landed. `stampPrefix` is the sink's own line prefix ("[HH:mm:ss] "),
    /// used only for the "could not be written" line after an outage.
    @discardableResult
    public mutating func write(_ data: Data, lines: Int, to handle: FileHandle,
                               stampPrefix: @autoclosure () -> String) -> Bool {
        var payload = data
        if droppedLines > 0 {
            let notice = "\(stampPrefix())\(droppedLines) log line\(droppedLines == 1 ? "" : "s") could not be written: \(lastFailure)\n"
            payload = Data(notice.utf8) + data
        }
        do {
            try handle.write(contentsOf: payload)
            droppedLines = 0
            return true
        } catch {
            // Saturating: an outage of any length cannot overflow the count.
            droppedLines = droppedLines.addingReportingOverflow(max(0, lines)).overflow ? .max : droppedLines + max(0, lines)
            totalDroppedLines = totalDroppedLines.addingReportingOverflow(max(0, lines)).overflow ? .max : totalDroppedLines + max(0, lines)
            lastFailure = Self.words(error)
            return false
        }
    }

    /// The errno's own words when there is one ("No space left on device
    /// (errno 28)"), else Foundation's.
    static func words(_ error: Error) -> String {
        var ns: NSError? = error as NSError
        while let e = ns {
            if e.domain == NSPOSIXErrorDomain {
                return "\(String(cString: strerror(Int32(e.code)))) (errno \(e.code))"
            }
            ns = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return error.localizedDescription
    }
}
