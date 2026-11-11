// GRDBCloseTSanReproTests.swift
// The weekly Thread Sanitizer run (scripts/weekly_sanitizer.py) reports a data
// race at catalog close: DatabasePool.close() writes `readerPool = nil` inside
// its barrier; the "previous read" is `guard let readerPool` at the top of
// DatabasePool.read(_:) async, on another thread, with no happens-before TSan
// can see. Our close path awaits every read and write to completion first.
//
// These tests hold NO VideoScan code: plain GRDB, a temp directory, awaited
// accesses, then close() — the order GRDBCatalogRepository uses. Under
// `swift test --sanitize=thread --filter GRDBCloseTSanRepro` they reproduce
// the same report (or not); in a normal run they are ordinary pass/fail tests
// that close a pool after awaited work. The verdict and the suppression live
// in scripts/sanitizer/tsan.supp and GH #423 (2026-11-08).

import Foundation
import GRDB
import Testing

@Suite("GRDB close TSan repro — no VideoScan code, awaited accesses, then close")
struct GRDBCloseTSanReproTests {

    private static func makePool() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grdb-close-tsan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        return (pool, dir)
    }

    @Test("one awaited async write, then close")
    func closeAfterAwaitedWrite() async throws {
        let (pool, dir) = try Self.makePool()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await pool.write { db in
            try db.execute(sql: "CREATE TABLE t (x INTEGER)")
            try db.execute(sql: "INSERT INTO t VALUES (1)")
        }
        try pool.close()
    }

    @Test("one awaited async write, one awaited async read, then close")
    func closeAfterAwaitedRead() async throws {
        let (pool, dir) = try Self.makePool()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await pool.write { db in try db.execute(sql: "CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (1)") }
        let count = try await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t") }
        #expect(count == 1)
        try pool.close()
    }

    /// The catalog's shape: an actor owns the pool, reads through it, then on
    /// close checkpoints on the writer (writeWithoutTransaction) and closes.
    private actor Owner {
        let pool: DatabasePool
        init(_ pool: DatabasePool) { self.pool = pool }
        func read() async throws -> Int? {
            try await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t") }
        }
        func close() async throws {
            try await pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            try pool.close()
        }
    }

    @Test("an actor reads, checkpoints on the writer and closes — the catalog's order")
    func actorReadCheckpointClose() async throws {
        let (pool, dir) = try Self.makePool()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await pool.write { db in try db.execute(sql: "CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (1)") }
        let owner = Owner(pool)
        for _ in 0..<20 { #expect(try await owner.read() == 1) }
        try await owner.close()
    }

    /// The CONTROL deliberately races GRDB's unsynchronised `readerPool` (GH #423),
    /// so it runs only inside a Thread Sanitizer run: weekly_sanitizer.py sets
    /// VIDEOSCAN_SANITIZER=thread and its suppression (scripts/sanitizer/tsan.supp)
    /// counts the hit, which also proves the pattern still matches. Result on
    /// 2026-11-08 (GRDB 7.11.1, no suppression): one report, write
    /// DatabasePool.swift:283 (close) vs read :357 (read async) — the weekly report's
    /// exact pair. The three sequential tests above: no report.
    @Test("CONTROL: reads still starting while close runs (GRDB allows it; it should throw, not race)",
          .enabled(if: ProcessInfo.processInfo.environment["VIDEOSCAN_SANITIZER"] == "thread",
                   "races GRDB on purpose (#423); runs only under the Thread Sanitizer runner"))
    func readsInFlightDuringClose() async throws {
        let (pool, dir) = try Self.makePool()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await pool.write { db in try db.execute(sql: "CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (1)") }
        let readers = (0..<8).map { _ in
            Task.detached { _ = try? await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM t") } }
        }
        try? pool.close()            // may throw SQLITE_BUSY while a reader holds a connection: GRDB's contract
        for r in readers { await r.value }
    }
}
