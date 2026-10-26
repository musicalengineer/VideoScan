// CatalogStoreDurabilityCodex141Tests.swift
// Codex cycle #141 (docs/reviews/codex/codex-review-catalog-store-consistency-
// 2026-10-25.md), the Core-only findings 1, 6 and 4 — each seen RED before
// its fix:
//
//   | finding | test                                              | red (before)                                  | green (after) |
//   |---------|---------------------------------------------------|-----------------------------------------------|---------------|
//   | 1  P1   | archivalWriterUsesFullSynchronization             | PRAGMA synchronous on the WRITER read 1       | reads 2       |
//   |         |                                                   | (GRDB's WAL setup runs `synchronous=NORMAL`   |               |
//   |         |                                                   | after prepareDatabase; readers stayed FULL)   |               |
//
// Lives under Tests/…/Store/ because it opens the same file with a plain
// GRDB queue (the sensor allows `import GRDB` only here and in
// Sources/…/Store/). One condition per #expect.
//
// Suite (filter by SUITE): CatalogStoreDurabilityCodex141Tests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogStoreDurabilityCodex141 — the writer's durability, refuse-before-WAL, the display pass marker")
struct CatalogStoreDurabilityCodex141Tests {

    /// A locked box the synchronous write body fills (for Rick: a mutex
    /// around one optional int; the body is `@Sendable`, so no captured var).
    private final class Reading: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int?
        func set(_ v: Int?) { lock.withLock { value = v } }
        func get() -> Int? { lock.withLock { value } }
    }

    // MARK: - Finding 1 (P1): the archival WRITER runs synchronous=FULL

    @Test func archivalWriterUsesFullSynchronization() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0, durability: .archival)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "writer-pragmas", durability: .archival)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)
        let reading = Reading()
        let outcome = await repository.write(as: .ui) { transaction in
            guard let tx = transaction as? GRDBTransaction else { throw FixtureFailure(words: "not a GRDB transaction") }
            reading.set(try Int.fetchOne(tx.db, sql: "PRAGMA synchronous"))
        }
        #expect(outcome == .committed(generation: 1))
        #expect(reading.get() == 2, "the writer connection must be FULL (2); GRDB's WAL setup leaves it NORMAL (1)")
        await repository.close()
    }
}
