// BackgroundCountCatalogURLTests.swift — regression (Rick 2026-11-03,
// Settings ▸ Background: "Content analysis: could not count — catalog read
// failed: file is not a database"). The store's count was handed
// `catalogStore.fileLocation`, which is catalog.json — the frozen pre-SQLite
// file — so the era planner opened JSON as SQLite, every recount failed, and
// the app never queued the era job itself (since 2026-11-02).
//
// One rule for "the catalog database" (CatalogAuthority.databaseURL): the
// database the cutover opened, else catalog.sqlite beside catalog.json —
// the rule CatalogDatabaseInfo already used. TRUTH: the count against a real
// catalog.json-beside-catalog.sqlite folder succeeds; SENSOR: the launch
// wiring no longer hands the store the JSON path.

import Foundation
import Testing
@testable import VideoScan

@Suite("Background count reads catalog.sqlite, never catalog.json")
@MainActor
struct BackgroundCountCatalogURLTests {

    @Test("the one rule: the opened database, else catalog.sqlite beside catalog.json")
    func rule() {
        let json = URL(fileURLWithPath: "/tmp/VS/catalog.json")
        #expect(CatalogAuthority.databaseURL(opened: nil, catalogFile: json).path == "/tmp/VS/catalog.sqlite")
        let opened = URL(fileURLWithPath: "/tmp/elsewhere/catalog.sqlite")
        #expect(CatalogAuthority.databaseURL(opened: opened, catalogFile: json) == opened)
    }

    @Test("TRUTH: handed the JSON path the count fails 'not a database'; handed the rule's URL it opens SQLite")
    func countOpensSQLite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bg-count-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent("catalog.json")
        try Data(#"{"version": 9, "records": []}"#.utf8).write(to: json)
        let root = dir.appendingPathComponent("background", isDirectory: true)

        guard case .failure(let r) = BackgroundServiceStore.count(catalogURL: json, stateRoot: root, knownJobs: [], now: Date()) else {
            Issue.record("JSON must not count as a catalog"); return
        }
        #expect(r.words.contains("not a database"), "\(r.words)")

        let db = CatalogAuthority.databaseURL(opened: nil, catalogFile: json)
        #expect(db.lastPathComponent == "catalog.sqlite")
        if case .failure(let r2) = BackgroundServiceStore.count(catalogURL: db, stateRoot: root, knownJobs: [], now: Date()) {
            #expect(!r2.words.contains("not a database"), "the rule's URL is never the JSON file: \(r2.words)")
        }
    }

    @Test("SENSOR: the launch hands the Background store the database URL, not catalogStore.fileLocation")
    func wiring() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/App/VideoScanApp.swift")
        let text = try String(contentsOf: app, encoding: .utf8)
        let start = try #require(text.range(of: "private func wireBackgroundService()")).upperBound
        let body = String(text[start...].prefix(1_200))
        #expect(body.contains("CatalogAuthority.databaseURL("), "the store counts against catalog.sqlite")
        #expect(!body.contains("catalogModel.map { URL(fileURLWithPath: $0.catalogStore.fileLocation) }"), "catalog.json is not a database")
    }
}
