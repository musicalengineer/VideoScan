// CatalogStoreSensorTests.swift
// SENSOR: the three rules Rick set for the SQLite port (2026-10-17), pinned
// as source scans so a later change cannot drift them quietly:
//   1. GRDB is a plugin — `import GRDB` appears only under a `Store/`
//      folder (Sources/VideoScanCore/Store and its tests).
//   2. Every statement that touches `generations`, `generation_history` or
//      `catalog_state` is raw SQL: no query-builder calls in Store/.
//   3. `DatabasePool` is created in exactly one place.
// Plus the durability rule: `.volatileForTests` never leaves the tests.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogStoreSensor")
struct CatalogStoreSensorTests {

    /// …/VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Store/<this file>
    /// → six levels up is the repository root.
    private static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    private static let sourceTrees = [
        "VideoScan/VideoScan",
        "VideoScan/VideoScanTests",
        "VideoScan/VideoScanCore/Sources",
        "VideoScan/VideoScanCore/Tests",
        "swift_cli",
    ]

    private static func swiftFiles() -> [URL] {
        var files: [URL] = []
        for tree in sourceTrees {
            let base = repositoryRoot.appendingPathComponent(tree)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            while let url = walker.nextObject() as? URL {
                if url.lastPathComponent == ".build" { walker.skipDescendants(); continue }
                if url.pathExtension == "swift" { files.append(url) }
            }
        }
        return files
    }

    private static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static var storeSources: [URL] {
        swiftFiles().filter { $0.path.contains("/VideoScanCore/Sources/VideoScanCore/Store/") }
    }

    @Test func onlyStoreFoldersImportGRDB() {
        let files = Self.swiftFiles()
        #expect(files.count > 100, "the scan found the source trees")
        let importers = files.filter { Self.read($0).contains("import GRDB") }
        let outsideStore = importers.filter { !$0.path.contains("/Store/") }
        #expect(outsideStore.isEmpty, "GRDB imported outside Store/: \(outsideStore.map(\.lastPathComponent))")
        #expect(importers.contains { $0.lastPathComponent == "GRDBCatalogRepository.swift" })
    }

    @Test func bookkeepingStatementsAreRawSQL() {
        // Query-builder spellings. `fetchOne(db)` / `fetchAll(db)` WITHOUT a
        // `sql:` argument is a request built by the query interface.
        let builder: [String] = [
            "Table(", "TableRecord", "FetchableRecord", "PersistableRecord", "Column(",
            "QueryInterfaceRequest", ".filter(", ".updateAll(", ".deleteAll(", ".insert(db", ".update(db",
            ".fetchOne(db)", ".fetchAll(db)", ".fetchSet(db)", ".fetchCursor(db)",
        ]
        for file in Self.storeSources {
            let text = Self.read(file)
            let found = builder.filter { text.contains($0) }
            #expect(found.isEmpty, "\(file.lastPathComponent) uses the query builder: \(found)")
        }
        let repository = Self.storeSources.first { $0.lastPathComponent == "GRDBCatalogRepository.swift" }.map(Self.read) ?? ""
        #expect(repository.contains("UPDATE generations SET generation = generation + 1"))
        #expect(repository.contains("INSERT INTO generation_history"))
    }

    @Test func databasePoolIsCreatedInOnePlace() {
        let creators = Self.swiftFiles().filter { !$0.path.contains("/Tests/") }
            .flatMap { file -> [(String, Int)] in
                let count = Self.read(file).components(separatedBy: "DatabasePool(").count - 1
                return count > 0 ? [(file.lastPathComponent, count)] : []
            }
        #expect(creators.count == 1, "DatabasePool created in: \(creators)")
        #expect(creators.first?.0 == "GRDBCatalogRepository.swift")
        #expect(creators.first?.1 == 1)
    }

    @Test func volatileDurabilityNeverLeavesTheTests() {
        let users = Self.swiftFiles()
            .filter { !$0.path.contains("/Tests/") && $0.lastPathComponent != "GRDBCatalogRepository.swift" }
            .filter { Self.read($0).contains("volatileForTests") }
        #expect(users.isEmpty, "production code chose .volatileForTests: \(users.map(\.lastPathComponent))")
    }

    @Test func theDDLMatchesTheDesignDocumentsTriggers() {
        // The bookkeeping triggers by name, as docs/design/catalog_sqlite_schema_v1.sql r3 lists them.
        let names = [
            "generations_step_by_one", "generations_no_step_over_pending_adopt",
            "generations_adoption_fields_only_by_adoption", "generations_no_delete",
            "generation_history_names_this_commit", "generation_history_adopt_precedes_jump",
            "generation_history_no_update",
        ]
        let ddl = CatalogBookkeepingSchema.statements.joined(separator: "\n")
        for name in names {
            #expect(ddl.contains("CREATE TRIGGER \(name)"), Comment(rawValue: name))
        }
        #expect(CatalogBookkeepingSchema.statements.filter { $0.contains("CREATE TABLE") }.count == 3)
    }
}
