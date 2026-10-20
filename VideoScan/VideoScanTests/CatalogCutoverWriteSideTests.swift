// CatalogCutoverWriteSideTests.swift
// Cutover B2 — the WRITE SIDE in the app (docs/design/
// catalog_cutover_f_prime_2026_10_17.md §3, §7, §10): the three save funnels
// commit into catalog.sqlite once it is the authority. (The "Switch Catalog to
// SQLite…" suite, CatalogSwitchTests, was retired with that menu item 2026-10-20.)
//   LOGIC     an edit + saveCatalogNow is in catalog.sqlite after a reload;
//             the debounced funnel commits on its own; the other copy of the
//             same content shows the new star at once;
//   SENSOR    under SQLite the funnels never reach the JSON store (catalog
//             .json byte-identical, nothing pending in the store); the source
//             routes every funnel through the committer first;
//   ISOLATION a read-only catalog.sqlite keeps the records changed and says
//             so; a MOPS-16 hold makes a commit wait, and its release lets it
//             through; the switch with an import that does not finish (or a
//             catalog.json that changed after it) writes NO latch, moves
//             (never deletes) the rehearsal, and un-freezes catalog.json;
//   TRUTH     covered in Core (CatalogCommitRoundTripTests.p0FactsSurvive);
//   SCALE     covered in Core (CatalogCommitScaleTests: 14k and 100k);
//   MEDIA     N/A — no media is opened.
// Every case runs in a sandbox folder (CutoverScene), never Application Support.
//
// Suites (filter by SUITE): CatalogCommitterTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
extension CutoverScene {

    /// Import, latch, launch on SQLite: the model holds the SQLite records
    /// and its committer.
    func launchOnSQLite() async throws {
        try await importCatalog()
        try writeLatch()
        model.records = model.loadCatalogAtLaunch()
    }

    func record(_ shape: PoisonedCatalogFixture.Shape) throws -> VideoRecord {
        try #require(model.records.first { $0.id.uuidString == PoisonedCatalogFixture.id(shape) })
    }

    func reloaded(_ shape: PoisonedCatalogFixture.Shape) async throws -> VideoRecord {
        let result = try await sqliteLoad()
        return try #require(result.records.first { $0.id.uuidString == PoisonedCatalogFixture.id(shape) })
    }
}

// MARK: - The committer behind the funnels

@Suite("Catalog committer — under catalog.sqlite the save funnels commit there, never to catalog.json", .serialized)
@MainActor
struct CatalogCommitterTests {

    @Test("an edit + saveCatalogNow is in catalog.sqlite after a reload")
    func saveNowCommits() async throws {
        let scene = try CutoverScene.make("b2_now"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.catalogCutover.isSQLiteAuthority)
        #expect(scene.model.isReadOnly == false)
        try scene.record(.healthy).starRating = 3
        #expect(scene.model.saveCatalogNow())
        #expect(try await scene.reloaded(.healthy).starRating == 3)
        #expect(scene.sandbox.catalogLogText().contains("OUTCOME commit generation"))
    }

    @Test("the debounced funnel commits on its own, ~2 s later")
    func debouncedCommits() async throws {
        let scene = try CutoverScene.make("b2_debounced"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try #require(scene.model.catalogCutover.committer)
        try scene.record(.healthy).userNotes = "the lake house"
        scene.model.saveCatalogDebounced()
        let deadline = Date().addingTimeInterval(10)
        while committer.changedRecordCount() > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(committer.changedRecordCount() == 0)
        #expect(try await scene.reloaded(.healthy).userNotes == "the lake house")
    }

    @Test("a star on one copy shows on the other copy of the same content at once")
    func copiesFollow() async throws {
        let scene = try CutoverScene.make("b2_copies"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try scene.record(.curatedConflictA).starRating = 2
        #expect(scene.model.saveCatalogNow())
        #expect(try scene.record(.curatedConflictB).starRating == 2)
        #expect(scene.model.catalogCutover.committer?.changedRecordCount() == 0)
    }

    @Test("SENSOR: under catalog.sqlite no funnel reaches the JSON store — catalog.json is byte-identical")
    func funnelsNeverTouchJSON() async throws {
        let scene = try CutoverScene.make("b2_sensor"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let before = try scene.sha256(scene.catalogURL)
        try scene.record(.healthy).starRating = 1
        scene.model.saveCatalogDebounced()
        _ = scene.model.saveCatalogNow()
        _ = await scene.model.saveCatalogAcknowledged()
        #expect(try scene.sha256(scene.catalogURL) == before)
        #expect(scene.model.catalogStore.hasUnsavedChanges == false)
        #expect(scene.model.catalogStore.isReadOnly)
        // Not even ASKED: a frozen store asked to save records `.readOnlyViewer`.
        #expect(scene.model.catalogStore.lastWriteError == nil)
    }

    @Test("SENSOR (source): each funnel asks the committer before the JSON store")
    func funnelSourceOrder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let model = try String(contentsOf: root.appendingPathComponent("VideoScan/Model/VideoScanModel.swift"), encoding: .utf8)
        let phases = try String(contentsOf: root.appendingPathComponent("VideoScan/MediaOps/ImportToSQLitePhases.swift"), encoding: .utf8)
        #expect(model.contains("if let committer = catalogCutover.committer { return committer.scheduleCommit() }\n        catalogStore.scheduleSave(records: records)"))
        #expect(model.contains("if let committer = catalogCutover.committer { return committer.commitNow() }\n        return catalogStore.saveNow(records: records)"))
        #expect(phases.contains("if let committer = catalogCutover.committer { return await committer.commitAcknowledged(owner: owner) }\n        return await catalogStore.saveAcknowledged(records: records, as: owner)"))
    }

    @Test("ISOLATION: a read-only catalog.sqlite keeps the record changed and says so")
    func readOnlyKeepsChanges() async throws {
        let scene = try CutoverScene.make("b2_readonly"); defer { scene.cleanup() }
        try await scene.importCatalog()
        _ = try await scene.sqliteLoad()                          // the display pass, once
        try Data("99\n".utf8).write(to: CatalogHighWater.url(besideDatabaseAt: scene.databaseURL))
        try scene.writeLatch()
        scene.model.records = scene.model.loadCatalogAtLaunch()
        #expect(scene.model.isReadOnly)
        try scene.record(.healthy).starRating = 3
        #expect(scene.model.saveCatalogNow() == false)
        #expect(scene.model.catalogCutover.blockedReason?.contains("restoredBelowHighWater") == true)
        #expect(scene.model.catalogCutover.committer?.changedRecordCount() == 1)
        #expect(scene.sandbox.catalogLogText().contains("NOT SAVED"))
    }

    @Test("ISOLATION: a MOPS-16 hold makes the commit wait; its release lets it through")
    func holdWaits() async throws {
        let scene = try CutoverScene.make("b2_hold"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let owner = CatalogWriteHoldOwner()
        await scene.model.catalogStore.holdWrites(reason: "a test job is reading the catalog", owner: owner)
        try scene.record(.healthy).starRating = 2
        #expect(scene.model.saveCatalogNow() == false)
        #expect(scene.sandbox.catalogLogText().contains("HELD — a test job is reading the catalog"))
        #expect(try await scene.reloaded(.healthy).starRating == 0)
        #expect(await scene.model.saveCatalogAcknowledged(asHoldOwner: owner), "the holder's own writer passes")
        scene.model.catalogStore.releaseWriteHold()
        try scene.record(.healthy).starRating = 3
        #expect(scene.model.saveCatalogNow())
        #expect(try await scene.reloaded(.healthy).starRating == 3)
    }
}
