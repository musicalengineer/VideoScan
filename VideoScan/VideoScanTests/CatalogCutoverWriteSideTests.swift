// CatalogCutoverWriteSideTests.swift
// Cutover B2 — the WRITE SIDE in the app (docs/design/
// catalog_cutover_f_prime_2026_10_17.md §3, §7, §10): the three save funnels
// commit into catalog.sqlite once it is the authority, and "Switch Catalog to
// SQLite…" writes the latch only after a finished import.
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
// Suites (filter by SUITE): CatalogCommitterTests · CatalogSwitchTests

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
        #expect(phases.contains("if let committer = catalogCutover.committer { return await committer.commitAcknowledged(holder: owner != nil) }\n        return await catalogStore.saveAcknowledged(records: records, as: owner)"))
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
        scene.model.catalogStore.holdWrites(reason: "a test job is reading the catalog", owner: owner)
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

// MARK: - Switch Catalog to SQLite…

@Suite("Switch Catalog to SQLite — the latch only after .imported; the rehearsal moved, never deleted", .serialized)
@MainActor
struct CatalogSwitchTests {

    private final class Freezes {
        var calls: [Bool] = []
    }

    private static func environment(_ scene: CutoverScene, freezes: Freezes, designation: String? = nil,
                                     runImport: @escaping @MainActor () async -> CatalogSwitchImportResult) -> CatalogSwitchEnvironment {
        CatalogSwitchEnvironment(folder: scene.folder, catalogURL: scene.catalogURL, runImport: runImport,
                                 freezeJSON: { freezes.calls.append($0) }, designationJSON: designation,
                                 sink: { scene.model.catalogAuthorityNote($0) })
    }

    private static func rehearsalFolders(_ scene: CutoverScene) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: scene.folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(CatalogSwitch.rehearsalPrefix) }
    }

    @Test("an import that does not finish: no latch; the rehearsal is MOVED into a dated folder, not deleted")
    func noLatchWithoutImport() async throws {
        let scene = try CutoverScene.make("switch_fail"); defer { scene.cleanup() }
        try await scene.importCatalog()
        let rehearsalBytes = try Data(contentsOf: scene.databaseURL).count
        let freezes = Freezes()
        let phase = await CatalogSwitchRun.run(Self.environment(scene, freezes: freezes) { .notImported("stopped in a test") })
        #expect(phase == .failed("the import did not finish: stopped in a test. The rehearsal is in \(try Self.rehearsalFolders(scene).first?.path ?? "?"); nothing was switched"))
        #expect(FileManager.default.fileExists(atPath: scene.latchURL.path) == false)
        let aside = try #require(try Self.rehearsalFolders(scene).first)
        let moved = aside.appendingPathComponent(CatalogAuthority.databaseFileName)
        #expect(try Data(contentsOf: moved).count == rehearsalBytes)
        #expect(FileManager.default.fileExists(atPath: aside.appendingPathComponent(CatalogHighWater.fileName).path))
        #expect(freezes.calls.isEmpty)
    }

    @Test("an import that finishes: the latch is written, catalog.json frozen, the designation moved into catalog_state")
    func latchAfterImport() async throws {
        let scene = try CutoverScene.make("switch_ok"); defer { scene.cleanup() }
        try await scene.importCatalog()
        let freezes = Freezes()
        let json = #"{"rootPath":"/Volumes/Archive/Breen_Family_Archive","targetPath":"/Volumes/Archive"}"#
        let phase = await CatalogSwitchRun.run(Self.environment(scene, freezes: freezes, designation: json) {
            do { try await scene.importCatalog(); return .imported } catch { return .notImported("\(error)") }
        })
        guard case .done = phase else { Issue.record("expected .done, got \(phase)"); return }
        #expect(FileManager.default.fileExists(atPath: scene.latchURL.path))
        #expect(freezes.calls == [true])
        let launch = try #require(try? await SQLiteLaunchRead.read(scene.databaseURL).get())
        await launch.repository.close()
        #expect(launch.designationJSON == json)
        #expect(try Self.rehearsalFolders(scene).count == 1)
    }

    @Test("catalog.json changed after the import: no latch, and the freeze is undone")
    func jsonChangedMeanwhile() async throws {
        let scene = try CutoverScene.make("switch_changed"); defer { scene.cleanup() }
        try await scene.importCatalog()
        let freezes = Freezes()
        let phase = await CatalogSwitchRun.run(Self.environment(scene, freezes: freezes) {
            do {
                try await scene.importCatalog()
                let handle = try FileHandle(forWritingTo: scene.catalogURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(" ".utf8))
                try handle.close()
                return .imported
            } catch { return .notImported("\(error)") }
        })
        #expect(phase == .failed("catalog.json changed after the import (an edit was saved meanwhile) — run Switch again; nothing was switched"))
        #expect(FileManager.default.fileExists(atPath: scene.latchURL.path) == false)
        #expect(freezes.calls == [true, false])
    }

    @Test("a job running (or a read-only session): refused in words BEFORE anything moves")
    func busyRefusesFirst() async throws {
        let scene = try CutoverScene.make("switch_busy"); defer { scene.cleanup() }
        try await scene.importCatalog()
        var env = Self.environment(scene, freezes: Freezes()) { .imported }
        env.busyWords = { "Verify Catalog is running" }
        let phase = await CatalogSwitchRun.run(env)
        #expect(phase == .failed("Verify Catalog is running"))
        #expect(FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(try Self.rehearsalFolders(scene).isEmpty)
    }

    @Test("not ready (no catalog.sqlite): refused in words, nothing moved")
    func notReady() async throws {
        let scene = try CutoverScene.make("switch_notready"); defer { scene.cleanup() }
        let freezes = Freezes()
        let phase = await CatalogSwitchRun.run(Self.environment(scene, freezes: freezes) { .imported })
        #expect(phase == .failed("there is no \(CatalogAuthority.databaseFileName) beside the catalog — run Import to SQLite… first"))
        #expect(try Self.rehearsalFolders(scene).isEmpty)
        #expect(FileManager.default.fileExists(atPath: scene.latchURL.path) == false)
    }
}
