// CatalogSQLiteLaunchNoJSONTests.swift
// JSON gone, slice 2 (2026-10-21): a launch on catalog.sqlite reads no byte
// of catalog.json. Until today adoptSQLiteAuthority ran `catalogStore.load()`
// and discarded the records, but kept catalog.json's Master Archive
// designation whenever catalog_state held none — so a designation the
// person CLEARED (catalog_state = NULL) came back at the next launch and the
// first commit wrote it in again (GH #353). The load also rewrote
// catalog.json.prev and the generation sidecar beside the frozen file.
//
//   LOGIC     #353: designate, clear, relaunch on SQLite — it stays cleared
//             (in the store's slot the model adopts, and in catalog_state
//             after the relaunched session commits);
//   SENSOR    a SQLite launch leaves catalog.json, catalog.json.prev and the
//             sidecar exactly as they were (size, date, inode), and launches
//             the same with catalog.json moved away;
//   ISOLATION every case runs in a sandbox folder (CutoverScene);
//   SCALE / MEDIA: N/A — one launch, no media opened.
//
// Suites (filter by SUITE): CatalogSQLiteLaunchNoJSONTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("A SQLite launch never reads catalog.json (GH #353)", .serialized)
@MainActor
struct CatalogSQLiteLaunchNoJSONTests {

    /// A second launch on the same folder, as after quit + relaunch: a NEW
    /// model and a NEW store (no in-memory slot carried over), the launch
    /// rule, then what VideoScanModel.init adopts from the store's slot.
    private static func relaunchedModel(_ scene: CutoverScene) async throws -> VideoScanModel {
        if let committer = scene.model.catalogCutover.committer { await committer.repository.close() }
        let model = VideoScanModel(logDirectory: scene.sandbox.root.appendingPathComponent("logs2", isDirectory: true))
        model.catalogStore = CatalogStore(directory: scene.folder)
        model.records = model.loadCatalogAtLaunch()
        model.masterArchive = model.catalogStore.masterArchive   // VideoScanModel.init's adoption
        return model
    }

    private static func storedDesignationJSON(_ url: URL) async throws -> String? {
        let repository = GRDBCatalogRepository(host: "cutover-test")
        _ = await repository.open(at: url)
        do {
            let json = try await repository.read { try $0.masterArchiveJSON() }
            await repository.close()
            return json
        } catch {
            await repository.close()
            throw error
        }
    }

    @Test("GH #353: a cleared Master Archive designation stays cleared after a relaunch on catalog.sqlite")
    func aClearedDesignationStaysCleared() async throws {
        let scene = try CutoverScene.make("no_json_353"); defer { scene.cleanup() }
        // As on the M4: catalog.json (frozen) carries the designation, and so
        // does catalog_state.
        let designation = try scene.writeDesignation(rootPath: "/Volumes/Archive/Family_353")
        try await scene.launchOnSQLite()
        scene.model.masterArchive = designation
        #expect(scene.model.saveCatalogNow())
        #expect(CatalogCommitter.designation(fromJSON: try await Self.storedDesignationJSON(scene.databaseURL)) == designation)

        scene.model.clearMasterArchive()
        #expect(scene.model.saveCatalogNow())
        #expect(try await Self.storedDesignationJSON(scene.databaseURL) == nil, "the clear reached catalog_state")

        let relaunched = try await Self.relaunchedModel(scene)
        defer { if let c = relaunched.catalogCutover.committer { Task { await c.repository.close() } } }
        #expect(relaunched.catalogCutover.isSQLiteAuthority)
        #expect(relaunched.catalogStore.masterArchive == nil, "catalog.json's designation is not adopted")
        #expect(relaunched.masterArchive == nil)
        _ = relaunched.saveCatalogNow()
        #expect(try await Self.storedDesignationJSON(scene.databaseURL) == nil, "no commit writes it back")
    }

    /// Size, modification date and inode of each name in `folder` (nil = absent).
    private static func fingerprint(_ names: [String], in folder: URL) -> [String: String] {
        var out: [String: String] = [:]
        for name in names {
            let path = folder.appendingPathComponent(name).path
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { out[name] = "absent"; continue }
            let date = (a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
            out[name] = "\(a[.size] ?? "?")·\(date)·\(a[.systemFileNumber] ?? "?")"
        }
        return out
    }

    private static let jsonSide = ["catalog.json", "catalog.json.prev", CatalogGenerationSidecar.fileName]

    @Test("SENSOR: a SQLite launch leaves catalog.json, catalog.json.prev and the generation sidecar untouched")
    func theSQLiteLaunchTouchesNoJSONFile() async throws {
        let scene = try CutoverScene.make("no_json_touch"); defer { scene.cleanup() }
        try await scene.importCatalog()
        try scene.writeLatch()
        let before = Self.fingerprint(Self.jsonSide, in: scene.folder)
        try await Task.sleep(for: .milliseconds(20))   // a rewrite would carry a later date
        scene.model.records = scene.model.loadCatalogAtLaunch()
        #expect(scene.model.catalogCutover.isSQLiteAuthority)
        #expect(Self.fingerprint(Self.jsonSide, in: scene.folder) == before)
    }

    @Test("SENSOR: with catalog.json moved away the SQLite launch is the same — and creates no JSON-side file")
    func theSQLiteLaunchNeedsNoCatalogJSON() async throws {
        let scene = try CutoverScene.make("no_json_absent"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let expected = scene.model.records.count
        let designation = scene.model.masterArchive
        try #require(scene.model.catalogCutover.committer).block("test: hand over to the relaunch")

        let aside = scene.sandbox.root.appendingPathComponent("aside", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        for name in Self.jsonSide where FileManager.default.fileExists(atPath: scene.folder.appendingPathComponent(name).path) {
            try FileManager.default.moveItem(at: scene.folder.appendingPathComponent(name), to: aside.appendingPathComponent(name))
        }
        let relaunched = try await Self.relaunchedModel(scene)
        defer { if let c = relaunched.catalogCutover.committer { Task { await c.repository.close() } } }
        #expect(relaunched.catalogCutover.isSQLiteAuthority)
        #expect(relaunched.records.count == expected)
        #expect(relaunched.masterArchive == designation)
        #expect(Self.fingerprint(Self.jsonSide, in: scene.folder).values.allSatisfy { $0 == "absent" })
    }
}
