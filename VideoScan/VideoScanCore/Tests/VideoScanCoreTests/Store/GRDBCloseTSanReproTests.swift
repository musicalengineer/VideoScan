// GRDBCloseTSanReproTests.swift
// The weekly Thread Sanitizer run (scripts/weekly_sanitizer.py) reported a data
// race at catalog close (GH #423): DatabasePool.close() writes `readerPool = nil`
// inside its barrier; the "previous read" is `guard let readerPool` at the top of
// DatabasePool.read(_:) async, on another thread.
//
// These tests hold NO VideoScan code: plain GRDB, a temp directory, awaited
// accesses, then close(). They show the three SEQUENTIAL shapes do not race
// (2026-11-08, GRDB 7.11.1): the race needs a read that STARTS while close runs.
//
// 2026-11-14: #423 is fixed in GRDBCatalogRepository (close stops admitting
// reads, drains, then closes — CatalogCloseDrainTests, which reproduces the
// report with the fix switched off). The CONTROL test that raced GRDB on
// purpose, and the suppression that counted its hit, are retired with it: the
// weekly run now has no thread suppression, so a race here reads red.

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
}
