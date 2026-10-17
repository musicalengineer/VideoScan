// ImporterTestSupport.swift
// The scene every CatalogImporter test starts from: the poisoned fixture
// (and its sidecars) written to a scratch folder, an importer on a fresh
// GRDB store beside it, a sink that keeps the lines, and a way to read the
// rows back through the seam afterwards (Tests/Import may not name the SQLite
// engine's module — CatalogStoreSensorTests — so every assertion goes through
// CatalogReader).

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

    func makeImporter() -> CatalogImporter {
        let repository = GRDBCatalogRepository(host: "import-test", durability: .volatileForTests)
        let sink = sink
        return CatalogImporter(repository: repository) { sink.append($0) }
    }

    /// Run once; the importer closes its store before returning.
    func run(seam: CatalogImporter.ComparatorSeam? = nil,
             decodeSeam: CatalogImporter.DecodeSeam? = nil) async -> (outcome: CatalogImporter.Outcome, runID: String) {
        let importer = makeImporter()
        await importer.injectComparatorSeam(seam)
        await importer.injectDecodeSeam(decodeSeam)
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

    /// Rewrite one of the fixture's files (an isolation test's poison).
    func overwrite(_ name: String, with data: Data) throws {
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
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
    var refusalKinds: [ImportGate.RunRefusal.Kind] {
        if case .refused(let r) = self { return r.map(\.kind) }
        return []
    }
    var misses: [ImportComparator.Miss]? {
        if case .rolledBack(let m) = self { return m }
        return nil
    }
    var failureWords: String? {
        if case .failed(let w) = self { return w }
        return nil
    }
}
