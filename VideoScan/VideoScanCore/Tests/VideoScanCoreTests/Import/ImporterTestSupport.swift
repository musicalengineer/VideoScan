// ImporterTestSupport.swift
// The scene every CatalogImporter test starts from: the poisoned fixture
// (and its sidecars) written to a scratch folder, an importer on a fresh
// GRDB store beside it, a sink that keeps the lines, and a way to read the
// rows back through the seam afterwards (Tests/Import may not name the SQLite
// engine's module — CatalogStoreSensorTests — so every assertion goes through
// CatalogReader). The poisons (codex D′ pins): rewrite the frozen catalog
// (and the integrity report that certifies it), the audit marker, the events
// file or the ledger, then run.

import CryptoKit
import Foundation
import Testing
@testable import VideoScanCore

/// The sink's lines, kept for assertions. (For Rick: a mutex around a vector.)
final class SinkLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}

struct ImporterScene {
    let fixture: PoisonedCatalogFixture
    let directory: URL
    let databaseFolder: URL
    var inputs: CatalogImporter.Inputs
    let sink = SinkLines()

    var databaseURL: URL { inputs.databaseURL }

    /// The fixture's files in `directory`; the database in `database/` beside them.
    static func make(healthyRows: Int = 0, sidecars: Bool = true) throws -> ImporterScene {
        let fixture = PoisonedCatalogFixture(healthyRows: healthyRows)
        let directory = try StoreFixture.temporaryDirectory()
        try fixture.write(to: directory)
        let databaseFolder = directory.appendingPathComponent("database", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseFolder, withIntermediateDirectories: true)
        func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
        let inputs = CatalogImporter.Inputs(
            catalogURL: file(PoisonedCatalogFixture.catalogFileName),
            integrityURL: file(PoisonedCatalogFixture.integrityFileName),
            auditURL: file(PoisonedCatalogFixture.auditFileName),
            eventsURL: sidecars ? file(PoisonedCatalogFixture.eventsFileName) : nil,
            ignoredURL: sidecars ? file(PoisonedCatalogFixture.ignoredFileName) : nil,
            ledgerURL: sidecars ? file(PoisonedCatalogFixture.ledgerFileName) : nil,
            backfillURL: sidecars ? file(PoisonedCatalogFixture.backfillFileName) : nil,
            databaseURL: databaseFolder.appendingPathComponent("catalog.sqlite"))
        return ImporterScene(fixture: fixture, directory: directory, databaseFolder: databaseFolder, inputs: inputs)
    }

    /// A write through the SAME repository the importer holds, in the window
    /// between its outer empty-target check and its transaction (codex D′ #7).
    typealias PreTransaction = @Sendable (any CatalogRepository) async -> Void

    /// Run once; the importer closes its store before returning.
    func run(seam: CatalogImporter.ComparatorSeam? = nil,
             decodeSeam: CatalogImporter.DecodeSeam? = nil,
             preTransaction: PreTransaction? = nil) async -> (outcome: CatalogImporter.Outcome, runID: String) {
        let repository = GRDBCatalogRepository(host: "import-test", durability: .volatileForTests)
        let sink = sink
        let importer = CatalogImporter(repository: repository) { sink.append($0) }
        await importer.injectComparatorSeam(seam)
        await importer.injectDecodeSeam(decodeSeam)
        if let preTransaction {
            await importer.injectPreTransactionSeam { await preTransaction(repository) }
        }
        let outcome = await importer.run(inputs)
        let runID = await importer.lastRunID ?? ""
        return (outcome, runID)
    }

    /// Read the committed rows back through the seam.
    func read<T: Sendable>(_ body: @Sendable (any CatalogReader) throws -> T) async throws -> T {
        let repository = GRDBCatalogRepository(host: "import-test-reader", durability: .volatileForTests)
        let opened = await repository.open(at: databaseURL)
        guard opened == .readWrite else { throw FixtureFailure(words: "reader could not open: \(opened)") }
        let value: T
        do {
            value = try await repository.read(body)
        } catch {
            await repository.close()
            throw error
        }
        await repository.close()
        return value
    }

    // MARK: - Poisons

    /// Rewrite one of the fixture's files (an isolation test's poison).
    func overwrite(_ name: String, with data: Data) throws {
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Replace the frozen catalog's BYTES and re-certify them in the
    /// integrity report (its hash and byte count), so only the poison under
    /// test differs from a clean gate.
    func replaceCatalog(bytes: Data) throws {
        try overwrite(PoisonedCatalogFixture.catalogFileName, with: bytes)
        var report = try IntegrityReportJSON.decode(fixture.integrityData)
        report.catalogSHA256 = Self.sha256(bytes)
        report.catalogByteCount = Int64(bytes.count)
        try overwrite(PoisonedCatalogFixture.integrityFileName, with: try CatalogJSONValue.makeEncoder().encode(report))
    }

    /// Edit the frozen catalog as a JSON tree (the fixture's encoder keeps
    /// the bytes canonical), then re-certify it.
    func replaceCatalog(_ edit: (inout [String: CatalogJSONValue]) -> Void) throws {
        var catalog = try #require(try JSONDecoder().decode(CatalogJSONValue.self, from: fixture.catalogData).objectValue)
        edit(&catalog)
        try replaceCatalog(bytes: try CatalogJSONValue.makeEncoder().encode(CatalogJSONValue.object(catalog)))
    }

    /// Edit one row of the frozen catalog by its shape.
    func replaceRow(_ shape: PoisonedCatalogFixture.Shape, _ edit: (inout [String: CatalogJSONValue]) -> Void) throws {
        let ordinal = try #require(fixture.ordinals(of: shape).first)
        try replaceCatalog { catalog in
            guard var records = catalog["records"]?.arrayValue, var row = records[ordinal].objectValue else { return }
            edit(&row)
            records[ordinal] = .object(row)
            catalog["records"] = .array(records)
        }
    }

    func replaceAudit(_ edit: (inout AuditMarkerJSON) -> Void) throws {
        var marker = try AuditMarkerJSON.decode(fixture.auditData)
        edit(&marker)
        try overwrite(PoisonedCatalogFixture.auditFileName, with: try CatalogJSONValue.makeEncoder().encode(marker))
    }

    func replaceEvents(_ edit: (inout [String: CatalogJSONValue]) -> Void) throws {
        let data = try #require(fixture.sidecarData[PoisonedCatalogFixture.eventsFileName])
        var events = try #require(try JSONDecoder().decode(CatalogJSONValue.self, from: data).objectValue)
        edit(&events)
        try overwrite(PoisonedCatalogFixture.eventsFileName, with: try CatalogJSONValue.makeEncoder().encode(CatalogJSONValue.object(events)))
    }

    func replaceLedger(_ text: String) throws {
        try overwrite(PoisonedCatalogFixture.ledgerFileName, with: Data(text.utf8))
    }

    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: databaseFolder.path)
        try? FileManager.default.removeItem(at: directory)
    }
}

extension CatalogImporter.Outcome {
    var reconciliation: ImportReconciliation? {
        if case .imported(let r) = self { return r }
        return nil
    }
    var refusals: [ImportGate.RunRefusal] {
        if case .refused(let r) = self { return r }
        return []
    }
    var refusalKinds: [ImportGate.RunRefusal.Kind] { refusals.map(\.kind) }
    var misses: [ImportComparator.Miss]? {
        if case .rolledBack(let m) = self { return m }
        return nil
    }
    var failureWords: String? {
        if case .failed(let w) = self { return w }
        return nil
    }
}
