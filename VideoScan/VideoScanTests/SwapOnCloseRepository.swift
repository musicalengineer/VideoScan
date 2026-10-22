// SwapOnCloseRepository.swift — test support for codex #117 F4 (GH #359).
// A store whose close() swaps catalog.sqlite for a replacement FIRST (the swap
// "while close is pending"), then closes the real repository. Everything else
// forwards to it; opens are counted so a test can prove Reopen opened nothing.

import Foundation
@testable import VideoScan
import VideoScanCore

final class SwapOnCloseRepository: CatalogRepository, @unchecked Sendable {
    let inner: GRDBCatalogRepository
    let database: URL
    let replacement: URL
    private(set) var openCalls = 0
    /// SHA-256 of the replacement right after the swap (before any close work).
    private(set) var replacementSHA = ""

    init(inner: GRDBCatalogRepository, database: URL, replacement: URL) {
        self.inner = inner
        self.database = database
        self.replacement = replacement
    }

    func open(at url: URL) async -> CatalogOpenOutcome {
        openCalls += 1
        return await inner.open(at: url)
    }

    func open(at url: URL, requiringLatch: Bool) async -> CatalogOpenOutcome {
        openCalls += 1
        return await inner.open(at: url, requiringLatch: requiringLatch)
    }

    var generation: Int { get async { await inner.generation } }

    func write(as door: CatalogWriter, _ body: @Sendable (any CatalogTransaction) throws -> Void) async -> CatalogWriteOutcome {
        await inner.write(as: door, body)
    }

    func writeBlocking(as door: CatalogWriter, _ body: (any CatalogTransaction) throws -> Void) -> CatalogWriteOutcome {
        inner.writeBlocking(as: door, body)
    }

    func read<T: Sendable>(_ body: @Sendable (any CatalogReader) throws -> T) async throws -> T {
        try await inner.read(body)
    }

    func verify() async -> CatalogVerifyOutcome { await inner.verify() }

    func adopt(toHighWater highWater: Int) async -> CatalogAdoptOutcome { await inner.adopt(toHighWater: highWater) }

    func close() async {
        let folder = database.deletingLastPathComponent()
        try? FileManager.default.moveItem(at: database, to: folder.appendingPathComponent("moved-aside.sqlite"))
        try? FileManager.default.moveItem(at: replacement, to: database)
        replacementSHA = (try? CornerFiles.sha256(database)) ?? "?"
        await inner.close()
    }

    func sealedCopyBlocking(to target: URL) -> String? { inner.sealedCopyBlocking(to: target) }

    var fileStopWords: String? { inner.fileStopWords }

    var lastCloseNotes: [String] { inner.lastCloseNotes }
}
