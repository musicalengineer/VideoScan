// CatalogDatabaseInfoSensorTests.swift — the architecture sensor for the
// database facts (built 11/01 as Catalog ▸ Catalog Database Info…; the same
// day's regrouping moved the rows into the Catalog Status window) and for
// that window (rule 8, sensor dimension): its code
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

    static let appFiles = ["VideoScan/Catalog/CatalogDatabaseInfo.swift", "VideoScan/Catalog/CatalogDatabaseInfoView.swift",
                           "VideoScan/Catalog/CatalogStatusWindow.swift", "VideoScan/Analyze/CatalogStatusLines.swift"]
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

    @Test func theRowsLiveInTheStatusWindowAndCommandIStaysTheVolumes() throws {
        let window = try Self.code("VideoScan/Catalog/CatalogStatusWindow.swift")
        #expect(window.contains("CatalogDatabaseInfoRows(model: info)"), "the 11/01 rows, reused")
        #expect(window.contains("CatalogDatabaseInfoModel(sources: sources,"), "the 11/01 read, reused")
        #expect(!window.contains("keyboardShortcut"), "no shortcut here (⌘I is the volume's)")
        let app = try Self.code("VideoScan/App/VideoScanApp.swift")
        #expect(!app.contains("CatalogDatabaseInfoMenuItem"), "the item left the Catalog menu")
        #expect(!app.contains("catalog-database-info") && !app.contains("CatalogDatabaseInfoView("), "its window is gone")
        #expect(app.contains("Window(CatalogStatusWindow.windowTitle, id: CatalogStatusWindow.sceneID)"))
        #expect(app.contains("WindowGroup(\"Catalog Info\", for: CatalogInfoItem.self)"), "the per-volume window stays")
    }
}
