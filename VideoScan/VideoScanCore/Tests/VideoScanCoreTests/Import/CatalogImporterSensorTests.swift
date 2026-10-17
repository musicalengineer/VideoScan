// CatalogImporterSensorTests.swift
// SENSOR: three rules of step D′ pinned as source scans, so a later edit
// cannot drift them quietly:
//   1. no `VideoRecord` (the app's class) symbol in Sources/VideoScanCore/Import/
//      — the importer reads the file through its own mirrors only;
//   2. every importer write is a transaction door: no SQL text and no GRDB
//      in Import/; the raw SQL lives in Store/ where Rick reviews it;
//   3. the comparator's JSON side is re-decoded from the file path
//      (`decodeCatalog()` reads `inputs.catalogURL`), never from the row
//      pass's DTOs — the comparator file never names the row pass.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogImporterSensor")
struct CatalogImporterSensorTests {

    private static var importSources: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }          // Import → VideoScanCoreTests → Tests → VideoScanCore
        return url.appendingPathComponent("Sources/VideoScanCore/Import", isDirectory: true)
    }

    private static func files() throws -> [(name: String, text: String)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: importSources.path).filter { $0.hasSuffix(".swift") }.sorted()
        return try names.map { ($0, try String(contentsOf: importSources.appendingPathComponent($0), encoding: .utf8)) }
    }

    /// The code without its `//` comments (the comments cite the app's types by name on purpose).
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let dash = line.range(of: "//") { return String(line[..<dash.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    @Test func noAppVideoRecordSymbolInImport() throws {
        let files = try Self.files()
        #expect(files.count >= 15)
        let symbol = try NSRegularExpression(pattern: "\\bVideoRecord\\b")
        for file in files {
            let text = Self.code(file.text)
            let hits = symbol.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            #expect(hits == 0, Comment(rawValue: "\(file.name) names the app's VideoRecord"))
        }
    }

    @Test func importerWritesOnlyThroughTheTransactionDoors() throws {
        // The engine's import line is spelled in two halves so the STORE sensor
        // (which greps every test file for that line) does not read this one.
        let spellings = ["import " + "GRDB", "INSERT INTO", "UPDATE ", "DELETE FROM", "execute(sql", "fetchOne(", "fetchCursor("]
        for file in try Self.files() {
            let text = Self.code(file.text)
            let found = spellings.filter { text.contains($0) }
            #expect(found.isEmpty, Comment(rawValue: "\(file.name) writes SQL itself: \(found)"))
        }
        let doors = try Self.files().first { $0.name == "CatalogImporter+Rows.swift" }.map { Self.code($0.text) } ?? ""
        #expect(doors.contains("tx.insertFile("))
        #expect(doors.contains("tx.insertQuarantine("))
        #expect(doors.contains("tx.insertKnowledgeSource("))
    }

    @Test func theComparatorReDecodesFromTheFilePath() throws {
        let files = try Self.files()
        let comparator = try #require(files.first { $0.name == "CatalogImporter+Comparator.swift" }).text
        let importer = try #require(files.first { $0.name == "CatalogImporter.swift" }).text
        let comparatorCode = Self.code(comparator)
        #expect(comparatorCode.contains("let catalog = try decodeCatalog()"))
        #expect(comparatorCode.contains("ImportComparator.JSONSide.occurrences(from: catalog)"))
        #expect(!comparatorCode.contains("ImportRowPass"))
        #expect(!comparatorCode.contains("CatalogRecordDTO(record:"))
        #expect(Self.code(importer).contains("data = try Data(contentsOf: inputs.catalogURL)"))
    }
}
