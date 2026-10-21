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
// Stopping quick_check: two things may stop it — its time budget and a
// cancel (the app quitting, PreflightCancellation). Both are decided ON THE
// READING THREAD by an SQLite progress handler, which SQLite calls every
// `progressOpsInterval` steps — including inside quick_check's page walk
// (measured: ~4 000 calls in one 100k-row walk at N = 100, SQLite 3.54).
// It returns "stop" once the deadline has passed or a cancel has been
// requested, and the statement ends with SQLITE_INTERRUPT. A cancel also
// calls sqlite3_interrupt() at once, so a running step stops without
// waiting for the next progress call.
//
// Why not a timer thread (the first version, 2026-10-21 nightly-flake hunt):
//   - SQLite DROPS an interrupt that arrives while no statement is running
//     (QA r2), so a watchdog or cancel landing between open and the first
//     step was lost and quick_check ran to its natural end;
//   - in a saturated full test run a `.utility` GCD timer did not fire for
//     20 s — a budget that waits for another thread to be scheduled is no
//     budget on a busy Mac.
// The progress handler has neither problem: the stop is a remembered flag
// and the clock is read by the thread doing the work.
//
// Every stop goes through one `InterruptGate`, whose lock-protected `closed`
// flag guarantees no interrupt reaches the connection once close has begun
// (QA r1 minor 3: a late interrupt during close was a use-after-close).
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
import SQLite3

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
        try quickCheck(at: databaseURL, budget: budget, cancellation: cancellation,
                       statement: "PRAGMA quick_check(\(maxProblemLines))", beforeStep: { _ in })
    }

    /// The seam behind `quickCheck` (tests only): `statement` replaces the
    /// PRAGMA (e.g. one that never ends, so only a stop can end it), and
    /// `beforeStep` runs on the reading thread after the last cancel/budget
    /// look and before the first step — exactly the window where a one-shot
    /// interrupt used to be dropped.
    static func quickCheck(at databaseURL: URL, budget: Duration,
                           cancellation: PreflightCancellation,
                           statement: String,
                           beforeStep: (Database) throws -> Void) throws -> PreflightQuickCheckOutcome {
        if cancellation.isCancelled { return .cancelled }
        let clock = ContinuousClock()
        let start = clock.now
        let gate = InterruptGate(try openReadOnly(databaseURL), deadline: start + budget)
        defer { gate.close() }
        let lines: [String]
        do {
            lines = try cancellation.whileRegistered({ gate.interrupt() }) {
                try gate.queue.read { db in
                    sqlite3_progress_handler(db.sqliteConnection, progressOpsInterval, progressCallback,
                                             Unmanaged.passUnretained(gate).toOpaque())
                    defer { sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil) }
                    // A stop that landed while the read transaction opened
                    // found no statement to interrupt — look once before
                    // stepping. After this, the progress handler sees it.
                    if cancellation.isCancelled { throw CancellationError() }
                    if gate.shouldStop() { throw StopRequested() }
                    try beforeStep(db)
                    return try String.fetchAll(db, sql: statement)
                }
            }
        } catch is CancellationError {
            return .cancelled
        } catch is StopRequested {
            return cancellation.isCancelled ? .cancelled : .ranOutOfTime(budget: budget)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_INTERRUPT {
            return cancellation.isCancelled ? .cancelled : .ranOutOfTime(budget: budget)
        }
        let elapsed = clock.now - start
        return lines == ["ok"] ? .passed(elapsed: elapsed) : .problems(lines, elapsed: elapsed)
    }

    /// SQLite steps between progress-handler calls. Each call is a lock and
    /// a clock read (well under a microsecond); at 1 000 steps a stop lands
    /// within a fraction of a millisecond of work.
    static let progressOpsInterval: Int32 = 1_000

    /// The progress handler: non-zero tells SQLite to stop the statement
    /// (SQLITE_INTERRUPT). `context` is the gate, unretained — the gate
    /// outlives the connection (it closes it), and the handler is removed
    /// before the read returns.
    private static let progressCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
        guard let context else { return 0 }
        return Unmanaged<InterruptGate>.fromOpaque(context).takeUnretainedValue().shouldStop() ? 1 : 0
    }

    private struct StopRequested: Error {}

    /// The one door to `interrupt()` and `close()` for a preflight connection,
    /// and the remembered stop the progress handler reads. interrupt() takes
    /// the lock and checks `closed`; close() sets `closed` under the lock
    /// BEFORE closing, so an interrupt either finishes first or sees the flag
    /// and does nothing.
    private final class InterruptGate: @unchecked Sendable {
        let queue: DatabaseQueue
        private let deadline: ContinuousClock.Instant
        private let lock = NSLock()
        private var closed = false
        private var stopRequested = false

        init(_ queue: DatabaseQueue, deadline: ContinuousClock.Instant) {
            self.queue = queue
            self.deadline = deadline
        }

        /// True once a cancel was requested or the budget has run out.
        func shouldStop() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if stopRequested { return true }
            if ContinuousClock.now >= deadline { stopRequested = true }
            return stopRequested
        }

        /// A cancel: remember it (the progress handler will see it), and
        /// interrupt the step that is running now, if any.
        func interrupt() {
            lock.lock(); defer { lock.unlock() }
            stopRequested = true
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
}
