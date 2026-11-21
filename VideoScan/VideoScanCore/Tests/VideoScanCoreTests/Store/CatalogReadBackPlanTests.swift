// CatalogReadBackPlanTests.swift
// Cutover B2.2 SENSOR: a commit reads every changed row back the way a load
// does (`storedRow(id:)`), and since B2.2 that commit runs on the main
// actor — so the read-back must cost O(1) per row, never a table scan.
// Measured 2026-10-18 (M4, Debug, 14k rows): the `import_items` join
// without an index made 1,000 read-backs cost 3.09 s; the bound-derived
// UNION scanned every derived table per row (an outer WHERE is not pushed
// into a compound that holds a window function). This pins both plans.
// Under Tests/…/Store/ because it asks the engine with GRDB.
//
// Suite (filter by SUITE): CatalogReadBackPlanTests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("Catalog read-back plan — a commit's one-row read is indexed, never a table scan (B2.2)", .serialized)
struct CatalogReadBackPlanTests {

    /// The plan's table SCAN steps (a SEARCH uses an index; a SCAN reads
    /// the whole table). "SCAN (subquery-N)" reads a subquery's already
    /// filtered rows, not a table, and is not counted.
    private static func scans(_ s: CommitScene, _ sql: String, _ argument: String) throws -> [String] {
        try s.queue().read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: [argument]).compactMap { row -> String? in
                let detail: String = row["detail"]
                return detail.hasPrefix("SCAN ") && !detail.hasPrefix("SCAN (subquery") ? detail : nil
            }
        }
    }

    @Test("the one-row SELECT (files ⋈ its single-valued tables ⋈ import_items) searches every table by key")
    func oneRowIsIndexed() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let scans = try Self.scans(s, LoadSQL.oneRow, PoisonedCatalogFixture.id(.healthy))
        #expect(scans.isEmpty, Comment(rawValue: scans.joined(separator: "; ")))
    }

    @Test("the bound derived values of ONE digest search each derived table by digest")
    func boundDerivedForOneDigestIsIndexed() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let scans = try Self.scans(s, LoadBoundSQL.unionForOne, String(repeating: "a", count: 64))
        #expect(scans.isEmpty, Comment(rawValue: scans.joined(separator: "; ")))
    }
}
