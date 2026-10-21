// QASlice2RedTests.swift — QA round 1 on JSON-gone slice 2 (2026-10-21).
// RED tests for the findings; not committed by QA. The fix agent lands them
// red -> green.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("QA slice 2 — latch present, catalog.json neither read nor written", .serialized)
@MainActor
struct QASlice2RedTests {

    /// Size, date and inode of the JSON side (catalog.json, .prev, sidecar).
    private static func jsonSide(_ folder: URL) -> [String] {
        ["catalog.json", "catalog.json.prev", CatalogGenerationSidecar.fileName].map { name in
            let path = folder.appendingPathComponent(name).path
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return "\(name) absent" }
            return "\(name) \(a[.size] ?? "?") \((a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1) \(a[.systemFileNumber] ?? "?")"
        }
    }

    // F1 — CatalogAuthorityFlip.swift:360-368 (loadJSONReadOnly): with the
    // latch present and the store refused, catalogStore.load() runs while the
    // JSON store is still WRITABLE (the freeze is set after the load), and
    // load() rotates catalog.json -> catalog.json.prev (remove + copy,
    // CatalogStore.swift:734/931) and may write the generation sidecar.
    @Test("F1: latch + refused store — catalog.json.prev and the sidecar are not rewritten")
    func refusedLaunchWritesNoJSONSideFile() async throws {
        let scene = try CutoverScene.make("qa_s2_refused_writes"); defer { scene.cleanup() }
        let repository = GRDBCatalogRepository(host: "cutover-test")
        _ = await repository.open(at: scene.databaseURL)      // a database with no finished import
        await repository.close()
        try scene.writeLatch()
        let before = Self.jsonSide(scene.folder)
        try await Task.sleep(for: .milliseconds(20))           // a rewrite carries a later date / new inode
        _ = scene.model.loadCatalogAtLaunch()
        #expect(scene.sandbox.catalogLogText().contains("SQLite catalog refused"))
        #expect(Self.jsonSide(scene.folder) == before,
                "with catalog.cutover present a launch rewrote the JSON side: \(Self.jsonSide(scene.folder)) was \(before)")
    }

    // F1b — the invariant itself, on a viewer: its own (stale) latch with no
    // usable catalog.sqlite, the master's snapshot + latch synced into
    // viewer-catalog/. Viewer rule: show the synced snapshot. Today the
    // launch goes .refused -> loadJSONReadOnly -> catalogStore.load(): the
    // frozen catalog.json becomes the viewer's on-screen catalog.
    @Test("F1b: a viewer with its own latch but no catalog.sqlite never opens catalog.json")
    func viewerWithOwnLatchAndNoDatabaseNeverReadsJSON() async throws {
        let scene = try CutoverScene.make("qa_s2_viewer_own_latch"); defer { scene.cleanup() }
        try await scene.importCatalog()
        _ = try await scene.sqliteLoad()
        let repository = GRDBCatalogRepository(host: "cutover-test")
        _ = await repository.open(at: scene.databaseURL)
        try FileManager.default.createDirectory(at: CatalogViewerSnapshot.directory(in: scene.folder), withIntermediateDirectories: true)
        #expect(repository.sealedCopyBlocking(to: CatalogViewerSnapshot.databaseURL(in: scene.folder)) == nil)
        await repository.close()
        try Data("switched\n".utf8).write(to: CatalogViewerSnapshot.latchURL(in: scene.folder))
        // The viewer's own top-level pair: the latch, but no catalog.sqlite.
        try FileManager.default.removeItem(at: scene.databaseURL)
        try scene.writeLatch()

        scene.model.applyReadOnlyMode(true)
        let records = scene.model.loadCatalogAtLaunch()
        #expect(scene.model.catalogStore.lastLoadOutcome == .missing,
                "catalog.json was loaded as the viewer's catalog with catalog.cutover present")
        #expect(records.isEmpty, "the launch showed \(records.count) records from catalog.json")
    }
    // F3 — CatalogAuditJob.swift:532 stamps the audit marker's
    // catalogGeneration from catalogStore.currentGeneration. Under
    // catalog.sqlite the JSON store is never loaded now (GH #353), so that is
    // 0 for every run — a durable false fact in catalog-audit.json.
    @Test("F3: under catalog.sqlite the generation an audit stamps is catalog.sqlite's, not 0")
    func auditGenerationUnderSQLiteIsTheDatabases() async throws {
        let scene = try CutoverScene.make("qa_s2_audit_generation"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try scene.record(.healthy).userNotes = "bump"
        #expect(scene.model.saveCatalogNow())
        let committer = try #require(scene.model.catalogCutover.committer)
        let dbGeneration = try await committer.repository.read { $0.generation }
        #expect(dbGeneration > 0)
        // Fix (2026-10-21): the stamp comes from the model's catalog
        // generation — catalog.sqlite's when a committer is installed — not
        // from the frozen JSON store, which never loads under SQLite.
        let stamped = await scene.model.catalogGenerationNow()
        #expect(stamped == dbGeneration, "CatalogAuditJob.conclude would stamp \(stamped); catalog.sqlite is at \(dbGeneration)")
        #expect(scene.model.catalogGenerationForStamp == dbGeneration, "the quit copy's header stamp")

        // The marker itself (CatalogAuditJob.conclude → catalog-audit.json).
        let marker = CatalogAuditRunMarker()
        _ = await runAudit(scene.model, marker: marker)
        let after = try await committer.repository.read { $0.generation }
        let file = scene.folder.appendingPathComponent(CatalogAuditRunMarker.fileName)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["catalogGeneration"] as? Int == after, "the marker stamps catalog.sqlite's generation \(after), got \(String(describing: json["catalogGeneration"]))")
        #expect((json["catalogGeneration"] as? Int ?? 0) > 0)
    }
}
