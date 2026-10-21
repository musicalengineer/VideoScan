// MasterArchiveDesignationReloadTests.swift
// GH #167 — the Master Archive designation silently vanished from
// catalog.json. One live path that loses it in the old code: every
// Person Finder job start called `CatalogStore.shared.load()` just to read
// records for its skip set. `load()` is the SESSION load — it overwrites the
// store's designation slot (what the next save serialises) and its OCC
// baseline with whatever is on disk, and rotates catalog.json → .prev. A
// designation set but not yet saved (Initialize inside the 2 s debounce) or
// rehomed to a new mount was reverted or nulled by the next save.
//
// 2026-10-21: the Person Finder prefilter no longer reads any catalog file —
// it snapshots the model's LIVE records (`VideoScanModel.personScanSkipFacts`
// through `pfLiveCatalogSkipResult`). These tests drive that real path on a
// model whose store is the scratch store and pin that the store's session is
// untouched; the last one pins that the skip set follows the live records,
// not the file.
//
// Isolation: every test pins its own CatalogStore(directory:) in a scratch
// directory. Nothing here touches App Support, the shared store or /Volumes
// (the designation paths are synthetic strings, never stat'ed).

import Foundation
import Testing
@testable import VideoScan

@Suite("GH #167 — a Person Finder read never resets the catalog session")
@MainActor
struct MasterArchiveDesignationReloadTests {

    private func scratchDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test_167_reload_\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    /// Whole seconds, so an ISO-8601 round trip compares equal.
    private func designation(_ volume: String) -> MasterArchiveDesignation {
        MasterArchiveDesignation(targetPath: "/Volumes/\(volume)",
                                 rootPath: "/Volumes/\(volume)/Breen_Family_Archive",
                                 volumeUUID: "TEST-UUID-167",
                                 designatedAt: Date(timeIntervalSince1970: 1_786_000_000))
    }

    private func audioOnlyRecord(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.streamTypeRaw = StreamType.audioOnly.rawValue
        return r
    }

    /// The Person Finder job-start prefilter, exactly as a job runs it, on a
    /// model whose catalog store is `store`.
    @discardableResult
    private func personFinderRead(store: CatalogStore, dir: URL,
                                  records: [VideoRecord] = [],
                                  target: String? = "Test Person") async -> CatalogSkipResult? {
        let model = VideoScanModel(logDirectory: dir.appendingPathComponent("logs", isDirectory: true))
        model.catalogStore = store
        model.records = records
        return await pfLiveCatalogSkipResult(targetPersonName: target,
                                             source: { model.personScanSkipFacts() })
    }

    @Test("a designation set but not yet saved survives a Person Finder job start and reaches disk")
    func unsavedDesignationSurvives() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))          // on disk: no designation
        _ = store.load()

        let d = designation("TestArchiveVol")
        store.masterArchive = d                      // what the model's didSet mirror does on Initialize
        await personFinderRead(store: store, dir: dir)
        #expect(store.masterArchive == d, "the skip-set read must not touch the designation slot")

        #expect(store.saveNow(records: []))
        let reread = CatalogStore(directory: dir)
        _ = reread.load()
        #expect(reread.masterArchive == d, "the designation was nulled by the reload before the save")
    }

    @Test("a rehomed designation is not reverted to the stale on-disk mount path")
    func rehomedDesignationNotReverted() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let old = designation("OldMountName")
        store.masterArchive = old
        #expect(store.saveNow(records: []))
        _ = store.load()

        let rehomed = old.rehomed(to: "/Volumes/NewMountName")
        store.masterArchive = rehomed                // reresolveMasterArchiveMount
        await personFinderRead(store: store, dir: dir)
        #expect(store.masterArchive == rehomed)
        #expect(store.saveNow(records: []))
        let reread = CatalogStore(directory: dir)
        _ = reread.load()
        #expect(reread.masterArchive?.targetPath == "/Volumes/NewMountName")
    }

    @Test("a Person Finder read does not adopt a foreign writer's generation (OCC stays armed)")
    func foreignGenerationNotAdopted() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = CatalogStore(directory: dir)
        #expect(app.saveNow(records: []))
        _ = app.load()

        // A cooperating external writer bumps the generation.
        let foreign = CatalogStore(directory: dir)
        _ = foreign.load()
        #expect(foreign.saveNow(records: [audioOnlyRecord("/Volumes/TestVol/foreign-work.wav")]))

        await personFinderRead(store: app, dir: dir, target: nil)
        // Our in-memory copy never merged the foreign write: saving it must
        // still be refused as stale, not silently clobber the foreign work.
        #expect(app.saveNow(records: []) == false)
        if case .staleGeneration = app.lastWriteError {} else {
            Issue.record("expected .staleGeneration, got \(String(describing: app.lastWriteError))")
        }
    }

    @Test("a Person Finder read does not rotate catalog.json over catalog.json.prev")
    func prevNotRotated() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: []))
        _ = store.load()                              // .prev = generation 1
        #expect(store.saveNow(records: []))           // primary = generation 2
        let prevURL = URL(fileURLWithPath: store.backupLocation)
        let before = CatalogSnapshot.headerProbe(at: prevURL)?.generation
        await personFinderRead(store: store, dir: dir)
        #expect(CatalogSnapshot.headerProbe(at: prevURL)?.generation == before,
                "the one-generation-back backup was overwritten by a read")
    }

    @Test("the skip set follows the LIVE records, not the records on disk")
    func skipSetFollowsLiveRecords() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.saveNow(records: [audioOnlyRecord("/Volumes/TestVol/on_disk_only.wav")]))
        let live = audioOnlyRecord("/Volumes/TestVol/live_only.wav")
        let result = try #require(await personFinderRead(store: store, dir: dir, records: [live], target: nil))
        #expect(result.unscannable == ["/Volumes/TestVol/live_only.wav"])
        #expect(pfCatalogSkipPaths(from: [live]) == ["/Volumes/TestVol/live_only.wav"])
    }
}
