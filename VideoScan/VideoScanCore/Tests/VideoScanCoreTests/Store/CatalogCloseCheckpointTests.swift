// CatalogCloseCheckpointTests.swift
// A closed catalog is ONE self-contained file (2026-10-17 night, found by the
// quit-path agent): GRDB closes the writer before its readers, so SQLite never
// checkpoints and the write-ahead log keeps the data. A backup or off-site copy
// of catalog.sqlite alone would then be missing every recent commit. close()
// folds the WAL in (wal_checkpoint(TRUNCATE)) before the pool goes.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("Catalog store — close leaves one self-contained file")
struct CatalogCloseCheckpointTests {

    private static func walBytes(beside url: URL) -> Int {
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let size = (try? FileManager.default.attributesOfItem(atPath: wal.path))?[.size] as? Int
        return size ?? 0
    }

    @Test("after close the -wal holds nothing: every commit is in catalog.sqlite itself")
    func closeCheckpointsTheLog() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 25)
        #expect(Self.walBytes(beside: fixture.url) == 0)
    }

    @Test("a copy of catalog.sqlite ALONE (no -wal, no -shm) carries every committed generation")
    func aLoneCopyIsComplete() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 25)
        let copy = fixture.directory.appendingPathComponent("copy-alone.sqlite")
        try FileManager.default.copyItem(at: fixture.url, to: copy)
        let queue = try DatabaseQueue(path: copy.path)
        let generation = try await queue.read { try Int.fetchOne($0, sql: "SELECT generation FROM generations WHERE id = 1") }
        #expect(generation == 25)
    }
}
