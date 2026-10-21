// CatalogCodexSlice2Tests.swift
// Codex review of JSON-gone slice 2 (cycle #116, 2026-10-21,
// docs/reviews/codex/codex-review-json-gone-slice2-2026-10-21.md): one RED
// test per finding, landed red, then the fixes.
//
//   F1 (P1)  a writable SQLite master with an edit inside the save debounce
//            becomes read-only (applyReadOnlyMode(true)) and quits: the edit
//            must be committed at the role switch, or — when that commit
//            fails — the quit must still write the rescue copy. A session
//            that BEGAN read-only still writes none (CatalogQuitRecoveryTests).
//   F2 (P1)  the launch restore backfills records from the local metadata
//            cache for any target with none — also after a launch that
//            opened no catalog (a viewer with nothing synced, no latch,
//            refused). Driven through restoreCatalogAtLaunch(), the code
//            init runs.
//   F3 (P2)  a side-table commit (the ignore list here) must move the
//            committer's knownGeneration, which the quit copy's header stamps.
//
// Dimensions: LOGIC (above) · ISOLATION (CutoverScene sandboxes; the
// per-process test metadata cache, under a unique sandbox prefix) · SCALE /
// MEDIA N/A (one launch, no media opened).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Codex slice 2 — role switch with pending edits, the launch backfill, side-table generations", .serialized)
@MainActor
struct CatalogCodexSlice2Tests {

    // MARK: - F1

    @Test("F1: writable master, an edit inside the debounce, then the viewer role → the edit is committed at the switch; the quit has nothing at risk")
    func roleSwitchCommitsPendingEdits() async throws {
        let scene = try CutoverScene.make("codex_f1_commit"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow(), "the launch commit lands first")
        try scene.record(.healthy).userNotes = "typed before the role switch"
        scene.model.saveCatalogDebounced()                      // inside the 2 s debounce
        scene.model.applyReadOnlyMode(true)                     // the role turns read-only
        let outcome = CatalogQuitRecovery.saveAtTermination(model: scene.model, writerDeadline: 5)
        #expect(try await scene.reloaded(.healthy).userNotes == "typed before the role switch",
                "the edit accepted while writable is in catalog.sqlite (outcome \(outcome))")
        let copies = ((try? FileManager.default.contentsOfDirectory(atPath: scene.folder.path)) ?? [])
            .filter { $0.hasPrefix(CatalogQuitRecovery.filePrefix) }
        #expect(copies.isEmpty, "nothing was at risk, so no copy: \(copies)")
    }

    @Test("F1: the same, but the commit at the switch FAILS → the quit still writes the rescue copy with the edit (the session did not begin read-only)")
    func roleSwitchWithFailedCommitKeepsTheRescue() async throws {
        let scene = try CutoverScene.make("codex_f1_rescue"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow())
        // Another writer's mark: the session's next commit is refused (fail-fast).
        try Data("99\n".utf8).write(to: CatalogHighWater.url(besideDatabaseAt: scene.databaseURL))
        try scene.record(.healthy).userNotes = "must be rescued"
        scene.model.saveCatalogDebounced()
        scene.model.applyReadOnlyMode(true)
        let outcome = CatalogQuitRecovery.saveAtTermination(model: scene.model, writerDeadline: 5)
        guard case .recoveryCopy(let copy) = outcome else {
            Issue.record("edits accepted while writable were dropped at quit: \(outcome)"); return
        }
        #expect(try String(contentsOf: copy, encoding: .utf8).contains("must be rescued"))
    }

    // MARK: - F2

    /// A `.cataloged` target under a fresh sandbox prefix, and one cached
    /// probe beneath it in the model's (per-process, test) metadata cache.
    private static func seedTargetAndCache(_ model: VideoScanModel, root: URL) throws -> String {
        let dir = root.appendingPathComponent("vol-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = CatalogScanTarget(searchPath: dir.path)
        target.phase = .cataloged
        model.scanTargets = [target]
        var o = ProbeOutcome()
        o.fullPath = dir.appendingPathComponent("old.mov").path
        o.filename = "old.mov"
        o.ext = "mov"
        o.probe.streamTypeRaw = "Video + Audio"
        o.probe.durationSeconds = 1
        model.metadataCache.store(outcome: o, fileSize: 4, modDate: Date(timeIntervalSince1970: 1_000_000_000))
        #expect(!model.metadataCache.allRecordsWithPrefix(dir.path).isEmpty, "the cache holds the stale record")
        return dir.path
    }

    @Test("F2: a viewer with nothing synced shows NO records from the local metadata cache (the code init runs)")
    func viewerLaunchDoesNotBackfillFromTheCache() async throws {
        let scene = try CutoverScene.make("codex_f2_viewer"); defer { scene.cleanup() }
        _ = try Self.seedTargetAndCache(scene.model, root: scene.sandbox.root)
        scene.model.applyReadOnlyMode(true)
        scene.model.restoreCatalogAtLaunch()
        #expect(scene.model.records.isEmpty, "stale cached records became the viewer's catalog: \(scene.model.records.map(\.filename))")
    }

    @Test("F2: a master with no latch (GH #354) shows NO records from the local metadata cache")
    func noLatchLaunchDoesNotBackfillFromTheCache() async throws {
        let scene = try CutoverScene.make("codex_f2_nolatch"); defer { scene.cleanup() }
        _ = try Self.seedTargetAndCache(scene.model, root: scene.sandbox.root)
        scene.model.restoreCatalogAtLaunch()
        #expect(scene.model.records.isEmpty, "stale cached records became the catalog of a refused launch")
    }

    @Test("F2: a writable SQLite master still backfills an empty target from the cache (unchanged)")
    func sqliteMasterStillBackfills() async throws {
        let scene = try CutoverScene.make("codex_f2_master"); defer { scene.cleanup() }
        try await scene.importCatalog()
        try scene.writeLatch()
        let prefix = try Self.seedTargetAndCache(scene.model, root: scene.sandbox.root)
        scene.model.restoreCatalogAtLaunch()
        #expect(scene.model.catalogCutover.isSQLiteAuthority)
        #expect(scene.model.records.contains { $0.fullPath.hasPrefix(prefix) })
    }

    // MARK: - F3

    @Test("F3: a side-table commit (the ignore list) moves knownGeneration — the quit copy's header stamps catalog.sqlite's generation")
    func sideTableCommitMovesKnownGeneration() async throws {
        let scene = try CutoverScene.make("codex_f3"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow())
        let committer = try #require(scene.model.catalogCutover.committer)
        let store = scene.model.ignoredContentStore
        _ = await store.load()
        #expect(store.add(partialMD5: "abc123", sizeBytes: 42, filename: "x.mov", reason: "test", samplePath: "/x.mov"))
        #expect(await store.save())
        let now = try await committer.repository.read { $0.generation }
        #expect(committer.knownGeneration == now, "knownGeneration \(committer.knownGeneration), catalog.sqlite at \(now)")
        #expect(scene.model.catalogGenerationForStamp == now)
    }
}
