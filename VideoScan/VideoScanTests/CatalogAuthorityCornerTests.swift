// CatalogAuthorityCornerTests.swift
// Corner-case matrix (Rick, 2026-10-21), the LAUNCH and AUTHORITY half: how
// our launch rule (`CatalogAuthority.decide`), the model's launch seam and the
// committer react when the files that make catalog.sqlite the authority are
// missing, vanish mid-session, are damaged, or come from a newer build.
//
//   Case 5   no catalog.cutover beside a real catalog.sqlite — on a master and
//            on a viewer. Since slice 2 (GH #354, 2026-10-21): `.noLatch`;
//            the master refuses loudly, read-only, with words, and opens no
//            catalog.json; a viewer with no latch of its own nor in
//            viewer-catalog/ says nothing is synced yet. PENDING (slice 2b):
//            a viewer's synced folder with the snapshot but no latch is still
//            labelled as the frozen catalog.json (CatalogViewerSnapshot.source).
//   Fail-fast  the latch vanishes mid-session — TODAY commits go on; INTENDED
//            the next commit stops and says why (pending).
//   Case 10  (app) a damaged catalog.sqlite behind the latch — the launch is
//            refused with words, no catalog opens (catalog.json is never the
//            fallback, QA r1 F1, 2026-10-21), and neither
//            catalog.sqlite nor its witnesses change by one byte.
//   Case 11  (app) a newer schema behind the latch — the same: refused with
//            the store's "newer than this build" words, read-only, untouched.
//
// Five dimensions: LOGIC (above) · SCALE N/A (each case is one launch) ·
// MEDIA N/A · ISOLATION (CutoverScene sandboxes only; a damaged file is our
// own synthetic fixture) · SENSOR (SHA-256 before == after on every refusal).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Catalog authority corners — missing or vanished latch, damaged or newer catalog.sqlite", .serialized)
@MainActor
struct CatalogAuthorityCornerTests {

    // MARK: - Case 5

    @Test("case 5 (master): catalog.sqlite with no catalog.cutover — refused loudly, read-only, catalog.json not opened (GH #354)")
    func masterWithoutLatch() async throws {
        let scene = try CutoverScene.make("corner_nolatch_master"); defer { scene.cleanup() }
        try await scene.importCatalog()
        _ = try await scene.sqliteLoad()
        let jsonBefore = try CornerFiles.sha256(scene.catalogURL)
        let authority = await CatalogAuthority.decide(folder: scene.folder)
        scene.model.records = scene.model.loadCatalogAtLaunch()
        #expect(authority == .noLatch)
        #expect(scene.model.catalogCutover.committer == nil)
        #expect(scene.model.records.isEmpty, "no catalog was opened")
        #expect(scene.model.isReadOnly, "catalog.json must not open writable")
        #expect(scene.model.catalogStore.isReadOnly)
        #expect(scene.model.catalogStore.lastLoadOutcome == .missing, "catalog.json was never loaded")
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("OUTCOME No catalog — \(CatalogAuthority.latchFileName) is not beside the catalog"), Comment(rawValue: log))
        #expect(try CornerFiles.sha256(scene.catalogURL) == jsonBefore)
    }

    @Test("case 5 (viewer): own catalog.sqlite with no latch → .noLatch (GH #354); a synced snapshot with no latch → still labelled as the frozen catalog.json (pending, slice 2b)")
    func viewerWithoutLatch() async throws {
        let scene = try CutoverScene.make("corner_nolatch_viewer"); defer { scene.cleanup() }
        try await scene.importCatalog()
        _ = try await scene.sqliteLoad()
        let own = await CatalogAuthority.decide(folder: scene.folder, readOnly: true)
        #expect(own == .noLatch, "a viewer without the latch never takes catalog.json as its catalog")

        // The synced folder: the master's sealed snapshot arrived, its latch did not.
        let live = scene.sandbox.root.appendingPathComponent("viewer-live", isDirectory: true)
        let repository = GRDBCatalogRepository(host: "corner-test")
        _ = await repository.open(at: scene.databaseURL)
        try FileManager.default.createDirectory(at: CatalogViewerSnapshot.directory(in: live), withIntermediateDirectories: true)
        let sealed = repository.sealedCopyBlocking(to: CatalogViewerSnapshot.databaseURL(in: live))
        await repository.close()
        #expect(sealed == nil)
        try Data("{\"version\":4,\"records\":[]}".utf8).write(to: live.appendingPathComponent("catalog.json"))
        let source = CatalogViewerSnapshot.source(in: live)
        #expect(source == .legacyJSON, "pinned: the snapshot without its latch falls back to catalog.json")

        withKnownIssue("slice 2b: a synced snapshot that arrived without its latch is labelled as the frozen catalog.json, without a word") {
            #expect(source != .legacyJSON, "a snapshot that arrived without its latch is ignored without a word")
        }
    }

    // MARK: - Fail fast: the latch vanishes mid-session

    @Test("fail-fast: catalog.cutover removed mid-session — today the next commit still lands; intended it stops with words (pending)")
    func latchVanishesMidSession() async throws {
        let scene = try CutoverScene.make("corner_latch_gone"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow())
        try FileManager.default.removeItem(at: scene.latchURL)
        try scene.record(.healthy).userNotes = "after the latch went"
        let saved = scene.model.saveCatalogNow()
        let landed = try await scene.reloaded(.healthy).userNotes == "after the latch went"
        print("[corner-authority] latch gone: saveCatalogNow → \(saved), landed → \(landed)")
        withKnownIssue("GH #354 (mid-session note): the committer never re-checks catalog.cutover; a session whose latch vanished keeps writing") {
            #expect(!saved, "a commit ran after catalog.cutover vanished")
            #expect(scene.model.catalogCutover.blockedReason?.contains(CatalogAuthority.latchFileName) == true)
        }
    }

    // MARK: - Cases 10 and 11 at the launch

    enum Damage: String, CaseIterable, Sendable, CustomStringConvertible {
        case corruptPages
        case newerSchema
        var description: String { rawValue }
    }

    @Test("cases 10/11 (app): a damaged or newer catalog.sqlite behind the latch — refused with words, no catalog opened (catalog.json never the fallback), catalog.sqlite and its witnesses byte-identical",
          arguments: Damage.allCases)
    func damagedOrNewerCatalogIsRefusedAndUntouched(_ damage: Damage) async throws {
        let scene = try CutoverScene.make("corner_\(damage)"); defer { scene.cleanup() }
        try await scene.importCatalog()
        _ = try await scene.sqliteLoad()
        try CornerFiles.checkpointAndDropSidecars(scene.databaseURL)
        switch damage {
        case .corruptPages:
            try CornerFiles.corruptPageHeaders(scene.databaseURL)
        case .newerSchema:
            try CornerFiles.exec(scene.databaseURL, "UPDATE catalog_state SET schema_version = schema_version + 1 WHERE singleton = 1")
            try CornerFiles.checkpointAndDropSidecars(scene.databaseURL)
        }
        try scene.writeLatch()
        let before = CornerFiles.catalogFingerprint(scene.databaseURL)
        let jsonBefore = try CornerFiles.sha256(scene.catalogURL)

        scene.model.records = scene.model.loadCatalogAtLaunch()
        scene.model.applyReadOnlyMode(false)                    // the master's onAppear
        let log = scene.sandbox.catalogLogText()
        #expect(scene.model.catalogCutover.committer == nil, "\(damage): a committer was installed on a refused store")
        #expect(scene.model.isReadOnly, "\(damage)")
        #expect(scene.model.catalogStore.isReadOnly, "\(damage)")
        #expect(log.contains("SQLite catalog refused — catalog.sqlite would not open"), "\(damage): \(log)")
        if damage == .newerSchema {
            #expect(log.contains("newer than this build"), Comment(rawValue: log))
        }
        // Fail-fast: nothing may be written over it, by any door.
        #expect(scene.model.records.isEmpty, "\(damage): a refused launch opens no catalog (QA r1 F1)")
        #expect(scene.model.saveCatalogNow() == false, "\(damage)")
        #expect(CornerFiles.catalogFingerprint(scene.databaseURL) == before, "\(damage): catalog.sqlite or a witness changed")
        #expect(try CornerFiles.sha256(scene.catalogURL) == jsonBefore, "\(damage): catalog.json was written")
    }
}
