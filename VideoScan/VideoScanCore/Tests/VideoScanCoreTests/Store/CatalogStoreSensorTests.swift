// CatalogStoreSensorTests.swift
// SENSOR: the three rules Rick set for the SQLite port (2026-10-17), pinned
// as source scans so a later change cannot drift them quietly:
//   1. GRDB is a plugin — `import GRDB` appears only under a `Store/`
//      folder (Sources/VideoScanCore/Store and its tests).
//   2. Every statement that touches `generations`, `generation_history` or
//      `catalog_state` is raw SQL: no query-builder calls in Store/.
//   3. `DatabasePool` is created in exactly one place.
// Plus the durability rule: `.volatileForTests` never leaves the tests.
// Part 2a adds the DDL-file sensors: every table and every trigger the
// design document declares is in the Swift schema, and the migration
// creates no table the document does not name.

import Foundation
import GRDB
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

    /// Both migrations' statements as one text, for "is it declared" scans.
    private static var swiftSchema: String {
        (CatalogBookkeepingSchema.statements + CatalogDataSchema.statements + CatalogLiveWritesSchema.statements).joined(separator: "\n")
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
            // Both test trees count as tests: the package's `Tests/` and the
            // app target's `VideoScanTests/` (2026-10-17: the quit-path suite
            // builds its sandbox stores with .volatileForTests).
            .filter { !$0.path.contains("/Tests/") && !$0.path.contains("/VideoScanTests/") }
            .filter { $0.lastPathComponent != "GRDBCatalogRepository.swift" }
            .filter { Self.read($0).contains("volatileForTests") }
        #expect(users.isEmpty, "production code chose .volatileForTests: \(users.map(\.lastPathComponent))")
    }

    @Test func theDDLMatchesTheDesignDocumentsTriggers() {
        // The bookkeeping triggers by name, as docs/design/catalog_sqlite_schema_v1.sql r3 lists them.
        let names = [
            "catalog_state_no_replace", "catalog_state_no_delete",
            "generations_step_by_one", "generations_no_step_over_pending_adopt",
            "generations_adoption_fields_only_by_adoption", "generations_no_delete", "generations_no_replace",
            "generation_history_names_this_commit", "generation_history_adopt_precedes_jump",
            "generation_history_no_update", "generation_history_no_replace", "generation_history_no_delete",
        ]
        let ddl = CatalogBookkeepingSchema.statements.joined(separator: "\n")
        for name in names {
            #expect(ddl.contains("CREATE TRIGGER \(name)"), Comment(rawValue: name))
        }
        #expect(CatalogBookkeepingSchema.statements.filter { $0.contains("CREATE TABLE") }.count == 3)
    }

    // MARK: - Part 2a: the DDL file against the Swift schema

    @Test func everyTableOfTheDDLIsInTheSwiftSchema() throws {
        let documented = try SchemaDocument.ddl().tableNames
        #expect(documented.count == 52)                        // 3 bookkeeping + 47 data + content_text_fts + 1 live (v1.7)
        let swift = Self.swiftSchema
        for name in documented {
            let declared = swift.contains("CREATE TABLE \(name) ") || swift.contains("CREATE VIRTUAL TABLE \(name) ")
            #expect(declared, Comment(rawValue: "table \(name) is in the DDL file but not in the Swift schema"))
        }
    }

    @Test func everyTriggerOfTheDDLIsInTheSwiftSchema() throws {
        let documented = try SchemaDocument.ddl().triggerNames
        #expect(documented.count == 73)                        // 12 bookkeeping + 58 data + 3 live (v1.7)
        let swift = Self.swiftSchema
        for name in documented {
            let declared = swift.contains("CREATE TRIGGER \(name) ") || swift.contains("CREATE TRIGGER \(name)\n")
            #expect(declared, Comment(rawValue: "trigger \(name) is in the DDL file but not in the Swift schema"))
        }
    }

    @Test func theMigrationCreatesNoTableOutsideTheDDL() async throws {
        let documented = Set(try SchemaDocument.ddl().tableNames)
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let inventory = try DatabaseQueue(path: fixture.url.path).inDatabase { db in try SchemaInventory(db) }
        let strangers = (inventory.tables + inventory.virtualTables).filter { !documented.contains($0) }
        #expect(strangers.isEmpty, Comment(rawValue: "tables outside the DDL: \(strangers)"))
        #expect(inventory.shadowTables.allSatisfy { $0.hasPrefix(SchemaInventory.shadowPrefix) })
    }

    // MARK: - Codex C′ #1 (c): no REPLACE / IGNORE conflict resolution in the store

    /// Spelled out: the store writes plain INSERT / UPDATE only. A REPLACE
    /// deletes the row in the way (the delete triggers catch it now, but
    /// the spelling should never appear), and an IGNORE hides a refusal.
    @Test func noReplaceOrIgnoreConflictResolutionInTheStore() {
        let spellings = ["OR REPLACE", "REPLACE INTO", "OR IGNORE", "or replace", "replace into", "or ignore"]
        let sources = Self.storeSources
        #expect(sources.count >= 9)
        for file in sources {
            let text = Self.read(file)
            let found = spellings.filter { text.contains($0) }
            #expect(found.isEmpty, "\(file.lastPathComponent) spells conflict resolution: \(found)")
        }
    }

    // MARK: - Codex C′ #8: the drift test's normalisation keeps literals whole

    /// `'Backed Up'` and `'Backed  Up'` are two different CHECK constants;
    /// collapsing whitespace inside a string literal would hide the drift.
    @Test func normalisationKeepsWhitespaceInsideStringLiterals() {
        let statement = CatalogDataSchema.files[0]
        #expect(statement.contains("'Backed Up'"))
        let mutated = statement.replacingOccurrences(of: "'Backed Up'", with: "'Backed  Up'")
        #expect(SQLScript.normalized(mutated) != SQLScript.normalized(statement))
        #expect(SQLScript.normalized("CREATE  TABLE t\n  (s TEXT)") == "CREATE TABLE t (s TEXT)")
        #expect(SQLScript.normalized("CHECK (s IN ('a  b',  'c'));") == "CHECK (s IN ('a  b', 'c'))")
    }
}
