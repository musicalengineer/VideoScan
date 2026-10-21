// CatalogCornerTestSupport.swift
// Shared by the catalog corner-case suites (Rick, 2026-10-21): a repository
// wrapper that injects failures AT OUR SEAM (CatalogRepository) — a write
// refused with given words, a sealed copy that dies part-way — and the small
// file helpers (SHA-256, damaged page headers, a newer schema stamp) the
// suites use to prove "nothing was written". Everything runs inside a
// CutoverScene sandbox; nothing touches Application Support.
//
// For Rick: `FaultyRepository` is a decorator — the real GRDB store inside,
// every call forwarded, and two switches that make chosen calls fail the way
// a full disk or an interrupted VACUUM INTO would. A C++ mock that wraps the
// real object instead of replacing it.

import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import VideoScan
import VideoScanCore

final class FaultyRepository: CatalogRepository, @unchecked Sendable {
    let inner: GRDBCatalogRepository
    private let lock = NSLock()
    private var _writeFault: String?
    private var _sealFault: (@Sendable (URL) -> String?)?
    private var _writesAttempted = 0
    private var _writesForwarded = 0

    init(_ inner: GRDBCatalogRepository) { self.inner = inner }

    /// Non-nil: every write is refused with these words (nothing forwarded).
    var writeFault: String? {
        get { lock.withLock { _writeFault } }
        set { lock.withLock { _writeFault = newValue } }
    }
    /// Non-nil: replaces the sealed copy; its answer is the door's answer.
    var sealFault: (@Sendable (URL) -> String?)? {
        get { lock.withLock { _sealFault } }
        set { lock.withLock { _sealFault = newValue } }
    }
    /// Writes the caller attempted (refused by the fault or forwarded).
    var writesAttempted: Int { lock.withLock { _writesAttempted } }
    var writesForwarded: Int { lock.withLock { _writesForwarded } }

    private func admit() -> String? {
        lock.withLock {
            _writesAttempted += 1
            if _writeFault == nil { _writesForwarded += 1 }
            return _writeFault
        }
    }

    func open(at url: URL) async -> CatalogOpenOutcome { await inner.open(at: url) }
    var generation: Int { get async { await inner.generation } }

    func write(as door: CatalogWriter, _ body: @Sendable (any CatalogTransaction) throws -> Void) async -> CatalogWriteOutcome {
        if let fault = admit() { return .refused(reason: "write rolled back: \(fault)") }
        return await inner.write(as: door, body)
    }

    func writeBlocking(as door: CatalogWriter, _ body: (any CatalogTransaction) throws -> Void) -> CatalogWriteOutcome {
        if let fault = admit() { return .refused(reason: "write rolled back: \(fault)") }
        return inner.writeBlocking(as: door, body)
    }

    func read<T: Sendable>(_ body: @Sendable (any CatalogReader) throws -> T) async throws -> T { try await inner.read(body) }
    func verify() async -> CatalogVerifyOutcome { await inner.verify() }
    func adopt(toHighWater highWater: Int) async -> CatalogAdoptOutcome { await inner.adopt(toHighWater: highWater) }
    func close() async { await inner.close() }

    func sealedCopyBlocking(to target: URL) -> String? {
        if let fault = sealFault { return fault(target) }
        return inner.sealedCopyBlocking(to: target)
    }
}

/// The words SQLite gives a full disk, as our store passes them on.
let diskFullWords = "SQLite error 13: database or disk is full - while executing `COMMIT TRANSACTION`"

enum CornerFiles {

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 or "-" when absent.
    static func sha256OrAbsent(_ url: URL) -> String {
        (try? sha256(url)) ?? "-"
    }

    /// catalog.sqlite and both high-water witnesses beside it.
    static func catalogFingerprint(_ database: URL) -> [String] {
        let folder = database.deletingLastPathComponent()
        return [database, folder.appendingPathComponent(CatalogHighWater.fileName),
                folder.appendingPathComponent(CatalogHighWaterLedger.fileName)].map(sha256OrAbsent)
    }

    /// Fold the WAL in and drop the sidecars (a cleanly closed catalog).
    static func checkpointAndDropSidecars(_ database: URL) throws {
        try exec(database, "PRAGMA wal_checkpoint(TRUNCATE)")
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: database.path + suffix)
        }
    }

    /// One statement on a private connection (the C API — the app target does
    /// not link the store's engine wrapper outside Core).
    static func exec(_ database: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw CutoverFailure(words: "open \(database.lastPathComponent): \(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "?")")
        }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CutoverFailure(words: "\(sql): \(String(cString: sqlite3_errmsg(handle)))")
        }
    }

    /// The injected damage: the first 8 bytes of every page after the first set to 0xFF.
    static func corruptPageHeaders(_ database: URL) throws {
        let handle = try FileHandle(forUpdating: database)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 100) ?? Data()
        guard header.count == 100 else { throw CutoverFailure(words: "short header") }
        var pageSize = Int(header[16]) << 8 | Int(header[17])
        if pageSize == 1 { pageSize = 65_536 }
        let pages = Int(try handle.seekToEnd()) / pageSize
        guard pages > 2 else { throw CutoverFailure(words: "only \(pages) pages") }
        for page in 1..<pages {
            try handle.seek(toOffset: UInt64(page * pageSize))
            try handle.write(contentsOf: Data(repeating: 0xFF, count: 8))
        }
        try handle.synchronize()
    }

    /// Files in `folder` whose names start with `prefix`.
    static func names(in folder: URL, prefix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
    }
}
