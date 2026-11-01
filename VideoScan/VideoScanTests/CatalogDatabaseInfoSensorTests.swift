// CatalogDatabaseInfoSensorTests.swift — the architecture sensor for
// Catalog ▸ Catalog Database Info… (rule 8, sensor dimension): its code
// extends no model (rule 12, #337), reaches no write door (no committer, no
// repository write, no SQL that changes a row), runs no integrity_check
// (Rick 2026-11-01: seconds on 315 MB — Validate Catalog's job), does no
// read in the view body, and keeps ⌘I for the per-volume Catalog Info.
// Reads source text only (the sensor lane runs it).

import Foundation
import Testing

@Suite("CatalogDatabaseInfoSensor")
struct CatalogDatabaseInfoSensorTests {

    private static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Code lines only — comments may name what the code must not do.
    private static func code(_ relative: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    static let appFiles = ["VideoScan/Catalog/CatalogDatabaseInfo.swift", "VideoScan/Catalog/CatalogDatabaseInfoView.swift"]
    static let coreReader = "VideoScanCore/Sources/VideoScanCore/Store/CatalogDatabaseInfoReader.swift"

    @Test func theSheetExtendsNoModelAndReachesNoWriteDoor() throws {
        for file in Self.appFiles {
            let code = try Self.code(file)
            for forbidden in ["extension VideoScanModel", "committer", "Committer", "commit(", "commitSideTables", ".write(", "writeBlocking",
                              "repository", "saveCatalog", "INSERT ", "UPDATE ", "DELETE ", "import " + "GRDB", "IntegrityReportStore.write",
                              "recordBackupSuccess", "integrity_check", "quick_check"] {
                #expect(!code.contains(forbidden), "\(file) holds \(forbidden)")
            }
        }
    }

    @Test func theCoreReaderOpensReadOnlyAndOnlyReads() throws {
        let code = try Self.code(Self.coreReader)
        #expect(code.contains("CatalogPreflightReader.openReadOnly("), "the one read-only open")
        #expect(code.contains("queue.read {"), "reads in a read transaction")
        for forbidden in ["INSERT ", "UPDATE ", "DELETE ", "DROP ", "CREATE ", "ALTER ", "db.execute(", ".write {", "inDatabase",
                          "DatabasePool" + "(", "integrity_check", "quick_check", "GRDBCatalogRepository("] {
            #expect(!code.contains(forbidden), "the reader holds \(forbidden)")
        }
        let preflight = try Self.code("VideoScanCore/Sources/VideoScanCore/Store/CatalogPreflightReader.swift")
        #expect(preflight.contains("configuration.readonly = true"))
    }

    @Test func theViewBodyOnlyLaysOutRows() throws {
        let view = try Self.code("VideoScan/Catalog/CatalogDatabaseInfoView.swift")
        let body = try #require(view.range(of: "var body: some View")).lowerBound
        let text = String(view[body...])
        for forbidden in ["CatalogDatabaseInfoGather", "CatalogDatabaseInfoReader", "FileManager", "records", "UserDefaults"] {
            #expect(!text.contains(forbidden), "the view body does \(forbidden)")
        }
    }

    @Test func theMenuItemIsNamedApartAndLeavesCommandIAlone() throws {
        let view = try Self.code("VideoScan/Catalog/CatalogDatabaseInfoView.swift")
        #expect(view.contains("static let menuTitle = \"Catalog Database Info…\""))
        #expect(view.contains("static let windowTitle = \"Catalog Database\""))
        let item = try #require(view.range(of: "struct CatalogDatabaseInfoMenuItem")).lowerBound
        #expect(!String(view[item...]).contains("keyboardShortcut"), "no shortcut on the database item (⌘I is the volume's)")
        let app = try Self.code("VideoScan/App/VideoScanApp.swift")
        // Rick 2026-11-01: the item left the Catalog menu; its rows move to
        // the Catalog Status window.
        #expect(!app.contains("CatalogDatabaseInfoMenuItem()"))
        #expect(app.contains("WindowGroup(\"Catalog Info\", for: CatalogInfoItem.self)"), "the per-volume window stays")
    }
}
