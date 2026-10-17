// ImportTestSupport.swift
// Shared helpers for the importer's pure pieces: the repo files the tests pin
// against (the DDL and the contract, read at test time — never copied), the
// golden decode, and the PoisonedCatalogFixture's writer (the only file I/O,
// kept in the test target so the source stays pure).

import Foundation
import Testing
@testable import VideoScanCore

enum ImportTestSupport {

    /// …/VideoScan (the repository root): Import → VideoScanCoreTests → Tests →
    /// VideoScanCore → VideoScan → repo.
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Import
        .deletingLastPathComponent()   // VideoScanCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // VideoScanCore
        .deletingLastPathComponent()   // VideoScan (Xcode project folder)
        .deletingLastPathComponent()   // repository root

    static let ddlURL = repoRoot.appendingPathComponent("docs/design/catalog_sqlite_schema_v1.sql")
    static let contractURL = repoRoot.appendingPathComponent("docs/design/catalog_contract_freeze_2026_10_17.md")

    static func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: DDL

    /// The quoted words of the first `<column> IN (` list after
    /// `CREATE TABLE <table> (`, with `--` comments stripped first. nil when
    /// the table or the list is not there.
    static func ddlCheckList(_ ddl: String, table: String, column: String) -> [String]? {
        guard let start = ddl.range(of: "CREATE TABLE \(table) (") else { return nil }
        let rest = ddl[start.upperBound...]
        let end = rest.range(of: "CREATE ")?.lowerBound ?? rest.endIndex
        let segment = rest[..<end].split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if let dash = line.range(of: "--") { return String(line[..<dash.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
        guard let col = segment.range(of: "\(column) IN") else { return nil }
        guard let open = segment[col.upperBound...].firstIndex(of: "(") else { return nil }
        var depth = 0
        var body = ""
        for ch in segment[open...] {
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            body.append(ch)
        }
        var words: [String] = []
        var current: String?
        for ch in body {
            if ch == "'" {
                if let w = current {
                    words.append(w)
                    current = nil
                } else {
                    current = ""
                }
            } else if current != nil {
                current?.append(ch)
            }
        }
        return words
    }

    // MARK: Contract §a

    struct InventoryRow: Equatable {
        let number: Int
        let key: String
        let fate: String
    }

    /// The 129 rows of contract §a (`| N | key … | … | Fate |`), in order.
    static func inventory(_ contract: String) -> [InventoryRow] {
        var out: [InventoryRow] = []
        for line in contract.split(separator: "\n") {
            guard out.count < 129, line.hasPrefix("| ") else { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // ["", "N", "field", type, enc, role, writers, fate, ""]
            guard cells.count >= 9, let n = Int(cells[1]), n == out.count + 1 else { continue }
            let key = cells[2].split(separator: " ").first.map { String($0).replacingOccurrences(of: "`", with: "") } ?? ""
            out.append(InventoryRow(number: n, key: key, fate: cells[cells.count - 2]))
        }
        return out
    }

    /// The contract's fate class: drop / X / col / anything else.
    static func fateClass(_ fate: String) -> CatalogRecordDTO.Fate {
        if fate.hasPrefix("drop") { return .drop }
        if fate.hasPrefix("X") { return .probeExtra }
        if fate.hasPrefix("col") { return .column }
        return .table
    }

    // MARK: Decode

    static func catalog(_ json: String) throws -> CatalogFileJSON {
        try CatalogFileJSON.decode(Data(json.utf8))
    }

    /// The object keys of an Encodable value, re-encoded and read back.
    static func encodedKeys<T: Encodable>(_ value: T) throws -> Set<String> {
        Set(try CatalogJSONValue.of(value).objectValue?.keys.map { $0 } ?? [])
    }

    // MARK: Poisoned fixture → gate inputs (what the importer will do, in miniature)

    struct FixtureRun {
        let fixture: PoisonedCatalogFixture
        let catalog: CatalogFileJSON
        let audit: AuditMarkerJSON
        let report: IntegrityReportJSON
        let dtos: [CatalogRecordDTO]
        let inputs: [ImportGate.Input]
    }

    static func fixtureRun() throws -> FixtureRun {
        let fixture = PoisonedCatalogFixture()
        let catalog = try CatalogFileJSON.decode(fixture.catalogData)
        let audit = try AuditMarkerJSON.decode(fixture.auditData)
        let report = try IntegrityReportJSON.decode(fixture.integrityData)
        let dtos = catalog.records.map { CatalogRecordDTO(record: $0, migrationLoadedAt: PoisonedCatalogFixture.auditStartedAt) }
        var counts: [String: Int] = [:]
        for d in dtos { counts[d.file.id, default: 0] += 1 }
        let evidence = audit.evidenceByID()
        let findings = report.findingsByRecord()
        let inputs = dtos.map { d in
            ImportGate.Input(record: d, occurrences: counts[d.file.id] ?? 1, audit: evidence[d.file.id],
                             auditWindow: audit.window, findings: findings[d.file.id] ?? [])
        }
        return FixtureRun(fixture: fixture, catalog: catalog, audit: audit, report: report, dtos: dtos, inputs: inputs)
    }
}

extension PoisonedCatalogFixture {
    /// Writes catalog.json, catalog-audit.json and integrity-latest.json into
    /// `directory` (a scratch folder the caller owns). Test-only file I/O.
    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in files {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }
}
