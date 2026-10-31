// BackgroundCatalogAccessTests.swift — the helper's catalog door opens one
// way (design §3.6: "opens the catalog with SQLITE_OPEN_READONLY only").
//
// Dimensions: LOGIC (open, read, refuse a write), ISOLATION (missing file,
// a non-catalog SQLite file). The runtime half of sensor §6(1); the source
// half is BackgroundServiceSensorTests in the app target.

import Foundation
import SQLite3
import Testing
@testable import VideoScanCore

@Suite("BackgroundCatalogAccess — read-only by construction")
struct BackgroundCatalogAccessTests {

    /// A small SQLite file with a catalog_state row, made with the C API.
    private func makeCatalog(schema: Int?) throws -> URL {
        let dir = try BackgroundFixtures.scratch("catalog")
        let url = dir.appendingPathComponent("catalog.sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        if let schema {
            try #require(sqlite3_exec(db, "CREATE TABLE catalog_state (singleton INTEGER PRIMARY KEY, schema_version INTEGER NOT NULL); INSERT INTO catalog_state VALUES (1, \(schema));", nil, nil, nil) == SQLITE_OK)
        }
        try #require(sqlite3_exec(db, "CREATE TABLE files (digest TEXT PRIMARY KEY, name TEXT); INSERT INTO files VALUES ('d1', 'a.mov'), ('d2', 'b.mov');", nil, nil, nil) == SQLITE_OK)
        return url
    }

    @Test("the only flags are SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, and SQLite agrees the handle is read-only")
    func flagsAndHandle() throws {
        #expect(BackgroundCatalogAccess.openFlags == SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        #expect(BackgroundCatalogAccess.openFlags & SQLITE_OPEN_READWRITE == 0)
        #expect(BackgroundCatalogAccess.openFlags & SQLITE_OPEN_CREATE == 0)
        let access = try BackgroundCatalogAccess.open(at: try makeCatalog(schema: 13))
        defer { access.close() }
        #expect(access.isReadOnly)
        #expect(try access.schemaVersion() == 13)
        #expect(try access.strings("SELECT name FROM files ORDER BY name") == ["a.mov", "b.mov"])
    }

    @Test("a write through the door is refused by the engine, in the door's words")
    func writeRefused() throws {
        let url = try makeCatalog(schema: 13)
        let access = try BackgroundCatalogAccess.open(at: url)
        defer { access.close() }
        for sql in ["INSERT INTO files VALUES ('d3', 'c.mov')", "UPDATE files SET name = 'x'", "DELETE FROM files",
                    "CREATE TABLE t (x)", "DROP TABLE files"] {
            let error = #expect(throws: Refusal.self, "\(sql) must be refused") { try access.strings(sql) }
            #expect(error?.words.contains(BackgroundCatalogAccess.readOnlyWords) == true, "\(sql): \(error?.words ?? "")")
        }
        #expect(try access.strings("SELECT count(*) FROM files") == ["2"], "nothing changed")
    }

    @Test("a missing file is a refusal in words, not a created database")
    func missingFile() throws {
        let dir = try BackgroundFixtures.scratch("missing")
        let url = dir.appendingPathComponent("catalog.sqlite")
        let error = #expect(throws: Refusal.self) { try BackgroundCatalogAccess.open(at: url) }
        #expect(error?.words.contains("no file at") == true)
        #expect(!FileManager.default.fileExists(atPath: url.path), "read-only never creates the file")
    }

    @Test("a SQLite file without catalog_state reports no schema version")
    func noSchemaRow() throws {
        let access = try BackgroundCatalogAccess.open(at: try makeCatalog(schema: nil))
        defer { access.close() }
        #expect(try access.schemaVersion() == nil)
    }
}
