// StoreTestSupport.swift — fixtures shared by the Store suites.
// Each fixture is one fresh temp directory holding either a GRDB catalog
// (catalog.sqlite + catalog.highwater) or a JSON catalog (catalog.json),
// built to a chosen generation, then CLOSED so the test opens it itself.

import Foundation
import Testing
@testable import VideoScanCore

enum StoreKind: String, CaseIterable, Sendable {
    case grdb
    case json

    var fileName: String { self == .grdb ? "catalog.sqlite" : "catalog.json" }

    /// What `open` says for a healthy store of this kind.
    var expectedOpen: CatalogOpenOutcome {
        self == .grdb ? .readWrite : .readOnly(reason: JSONCatalogRepository.readOnlyReason)
    }
}

struct StoreFixture: Sendable {
    let kind: StoreKind
    let directory: URL
    var url: URL { directory.appendingPathComponent(kind.fileName) }
    var highWaterURL: URL { CatalogHighWater.url(besideDatabaseAt: url) }

    static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoscan-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A closed store at `generation`.
    static func make(_ kind: StoreKind, generation: Int,
                     durability: GRDBCatalogRepository.Durability = .volatileForTests) async throws -> StoreFixture {
        let fixture = StoreFixture(kind: kind, directory: try temporaryDirectory())
        switch kind {
        case .grdb:
            let repository = GRDBCatalogRepository(host: "test-host", durability: durability)
            let opened = await repository.open(at: fixture.url)
            try #require(opened == .readWrite)
            for _ in 0..<generation {
                let outcome = await repository.write(as: .ui) { _ in }
                guard case .committed = outcome else {
                    throw FixtureFailure(words: "fixture write failed: \(outcome)")
                }
            }
            await repository.close()
        case .json:
            let text = "{\"version\":6,\"generation\":\(generation),\"savedFromHost\":\"test-host\",\"records\":[]}"
            try Data(text.utf8).write(to: fixture.url)
        }
        return fixture
    }

    func makeRepository(durability: GRDBCatalogRepository.Durability = .volatileForTests) -> any CatalogRepository {
        switch kind {
        case .grdb: return GRDBCatalogRepository(host: "test-host", durability: durability)
        case .json: return JSONCatalogRepository()
        }
    }

    func highWaterText() -> String? {
        try? String(contentsOf: highWaterURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func writeHighWater(_ text: String) throws {
        try Data(text.utf8).write(to: highWaterURL)
    }

    var highWaterLogURL: URL { CatalogHighWaterLedger.url(besideDatabaseAt: url) }

    func highWaterLogText() -> String? {
        try? String(contentsOf: highWaterLogURL, encoding: .utf8)
    }

    func writeHighWaterLog(_ text: String) throws {
        try Data(text.utf8).write(to: highWaterLogURL)
    }

    /// Puts `backup` (a completed VACUUM INTO, §9.6) in the database's
    /// place and drops the newer file's WAL and SHM — a restore as a person
    /// would do it.
    func restoreDatabase(from backup: URL) throws {
        let manager = FileManager.default
        try manager.removeItem(at: url)
        try? manager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? manager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        try manager.copyItem(at: backup, to: url)
    }

    /// Scratch only — the fixture's own temp directory.
    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

struct FixtureFailure: Error, CustomStringConvertible {
    let words: String
    var description: String { words }
}
