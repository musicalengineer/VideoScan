// CatalogPreflightReader.swift (VideoScanCore/Store)
// The launch preflight's two questions for the catalog file (2026-10-21):
// its schema version, and `PRAGMA quick_check` within a time budget. Lives
// in Store/ because only Store/ may import GRDB (CatalogStoreSensorTests);
// the preflight itself (Preflight/) sees plain Swift values.
//
// Each question opens its own short-lived READ-ONLY `DatabaseQueue`
// (SQLITE_OPEN_READONLY: no migration, no write, no high-water) and closes
// it before returning. It never touches the app's writer pool, so it is
// safe beside the open catalog — a WAL reader sees the last commit and never
// blocks a writer (CatalogPreflightReaderQAR1Tests pins both).
//
// Stopping quick_check: two things may interrupt it — the budget watchdog
// (a timer thread) and a cancel (the app quitting, PreflightCancellation).
// Both go through one `InterruptGate`, whose lock-protected `closed` flag
// guarantees no interrupt reaches the connection once close has begun
// (QA r1 minor 3: a late watchdog firing during close was a use-after-close).
//
// Cost, measured 2026-10-21 on a `.backup` copy of the live catalog
// (275 MB, 67 202 pages, 16 156 files rows, M4 Max, SQLite 3.54), warm file
// cache, sqlite3 CLI / GRDB (CatalogPreflightMeasureTests, VIDEOSCAN_PREFLIGHT_DB):
//   schema_version     ≈ 2–6 ms
//   quick_check        ≈ 100 ms / 125–190 ms   — cold file cache: 2.67 s
//   integrity_check    ≈ 275 ms / 325–560 ms   (what `GRDBCatalogRepository.open` runs today)
//   foreign_key_check  ≈  66 ms /  75–120 ms   (likewise)
// quick_check skips the index-vs-table cross-check, which is most of
// integrity_check's extra cost; it still walks every page.
//
// Memory: SQLite's page cache for one connection (default ≈ 2 MB), freed at
// close. quick_check returns at most `maxProblemLines` text rows.
//
// (For Rick: `DatabaseQueue` ≈ one sqlite3* handle behind a serial queue;
// `interrupt()` is sqlite3_interrupt() from another thread — the running
// statement returns SQLITE_INTERRUPT at its next opcode check.)

import Foundation
import GRDB

public enum CatalogPreflightReader {

    /// The `catalog_state.schema_version` this build's store migrates to.
    public static var expectedSchemaVersion: Int { GRDBCatalogRepository.currentSchemaVersion }

    /// quick_check stops after this many problem rows: enough to log, never a flood.
    public static let maxProblemLines = 10

    /// `catalog_state.schema_version`, or nil when the file has no such row.
    public static func schemaVersion(at databaseURL: URL) throws -> Int? {
        let queue = try openReadOnly(databaseURL)
        defer { try? queue.close() }
        return try queue.read { db -> Int? in
            guard try db.tableExists("catalog_state") else { return nil }
            return try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state WHERE singleton = 1")
        }
    }

    /// `PRAGMA quick_check(maxProblemLines)` on a read-only connection,
    /// interrupted when `budget` runs out or `cancellation` is cancelled.
    public static func quickCheck(at databaseURL: URL, budget: Duration,
                                  cancellation: PreflightCancellation = PreflightCancellation()) throws -> PreflightQuickCheckOutcome {
        if cancellation.isCancelled { return .cancelled }
        let gate = InterruptGate(try openReadOnly(databaseURL))
        defer { gate.close() }
        let watchdog = DispatchWorkItem { gate.interrupt() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + dispatchInterval(budget), execute: watchdog)
        defer { watchdog.cancel() }
        let clock = ContinuousClock()
        let start = clock.now
        let lines: [String]
        do {
            lines = try cancellation.whileRegistered({ gate.interrupt() }) {
                try gate.queue.read { db in
                    // A cancel that landed while the read transaction opened
                    // found no statement to interrupt (SQLite drops it) — look
                    // once more right before stepping. The window left is the
                    // few instructions between here and the first step.
                    if cancellation.isCancelled { throw CancellationError() }
                    return try String.fetchAll(db, sql: "PRAGMA quick_check(\(maxProblemLines))")
                }
            }
        } catch is CancellationError {
            return .cancelled
        } catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
            return cancellation.isCancelled ? .cancelled : .ranOutOfTime(budget: budget)
        }
        let elapsed = clock.now - start
        return lines == ["ok"] ? .passed(elapsed: elapsed) : .problems(lines, elapsed: elapsed)
    }

    /// The one door to `interrupt()` and `close()` for a preflight connection.
    /// interrupt() takes the lock and checks `closed`; close() sets `closed`
    /// under the lock BEFORE closing, so an interrupt either finishes first
    /// or sees the flag and does nothing.
    private final class InterruptGate: @unchecked Sendable {
        let queue: DatabaseQueue
        private let lock = NSLock()
        private var closed = false

        init(_ queue: DatabaseQueue) { self.queue = queue }

        func interrupt() {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            queue.interrupt()
        }

        func close() {
            lock.lock()
            closed = true
            lock.unlock()
            try? queue.close()
        }
    }

    private static func openReadOnly(_ databaseURL: URL) throws -> DatabaseQueue {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: databaseURL.path])
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "preflight"
        return try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    }

    private static func dispatchInterval(_ budget: Duration) -> DispatchTimeInterval {
        let ms = max(0, Int(TimingBudget.seconds(budget) * 1_000))
        return .milliseconds(ms)
    }
}
