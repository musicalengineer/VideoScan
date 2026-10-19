// AdvSQLiteSafetyCopyTests.swift
//
// Adversarial review 2026-10-18, item 3 (P2, invariant VOL-3): under
// catalog.sqlite the pre-change safety copy was the LAST COMMIT, not what is
// in memory.
//
// Mechanism (pre-fix): `snapshotCatalog` / `snapshotCatalogAsync` under the
// SQLite authority call `sqliteSnapshot`, which seals `VACUUM INTO` of
// catalog.sqlite as it stands. An edit typed inside the 2 s save debounce is
// not in catalog.sqlite yet, so it is not in the copy. The door then drops
// the record from memory and purges its id; the purge commit snapshots
// `records`, which no longer holds the doomed row, so its unsaved edit is
// never written. Result: the edit is in neither catalog.sqlite nor the
// recovery copy. (Under catalog.json the snapshot was written FROM MEMORY —
// QA #7, 2026-07-02 — for exactly this reason.)
//
// The contract pinned here: the copy holds what the person sees. The fix
// commits the in-memory edits (the same synchronous commit saveCatalogNow
// runs) before sealing; when no commit can be written now (held, blocked)
// the copy is REFUSED, so the door refuses too (fail safe).
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC     an edit inside the debounce is in the copy (sync + async doors)
//   ISOLATION every case in a CutoverScene sandbox, never Application Support
//   SENSOR    the counterexample end to end — edit, copy, remove + purge:
//             catalog.sqlite no longer holds the row, the copy holds it WITH
//             the edit; and a held catalog refuses the copy (no file written)
//   SCALE     the added work is the synchronous commit saveCatalogNow already
//             runs — pinned by CatalogCommitScaleTests (unchanged pipeline)
//   MEDIA     N/A — no media is opened.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Adv — the SQLite safety copy holds what the person sees", .serialized)
@MainActor
struct AdvSQLiteSafetyCopyTests {

    static let sentinel = "adv sentinel — typed a second before the door"

    @Test("an edit inside the save debounce is in the sealed copy (snapshotCatalog)")
    func safetyCopyCarriesAnEditNotYetCommitted() async throws {
        let scene = try CutoverScene.make("adv_copy_lag"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        healthy.userNotes = Self.sentinel                                   // inside the debounce
        let path = try #require(scene.model.snapshotCatalog(prefix: "pre-target-removal"))
        let copy = try await CutoverScene.load(URL(fileURLWithPath: path))
        let inCopy = try #require(copy.records.first { $0.id == healthy.id })
        #expect(inCopy.userNotes == Self.sentinel,
                "the safety copy lags memory: the edit the door is about to purge is not in it")
    }

    @Test("the off-main door (snapshotCatalogAsync) seals the edit too")
    func asyncSafetyCopyCarriesTheEdit() async throws {
        let scene = try CutoverScene.make("adv_copy_lag_async"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        healthy.starRating = 2
        let path = try #require(await scene.model.snapshotCatalogAsync(prefix: "pre-show-again"))
        let copy = try await CutoverScene.load(URL(fileURLWithPath: path))
        #expect(copy.records.first { $0.id == healthy.id }?.starRating == 2)
    }

    @Test("SENSOR: edit → copy → remove + purge: the row is gone from catalog.sqlite and its edit is in the copy")
    func removedRowsLatestEditIsRecoverable() async throws {
        let scene = try CutoverScene.make("adv_copy_door"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        let id = healthy.id
        healthy.userNotes = Self.sentinel
        let path = try #require(scene.model.snapshotCatalog(prefix: "pre-target-removal"))
        // The door: drop it from memory and purge it explicitly (B2.3).
        scene.model.records.removeAll { $0.id == id }
        scene.model.purgeCatalogRows(ids: [id], reason: "adv test door")
        #expect(scene.model.saveCatalogNow())
        #expect(try await scene.sqliteLoad().records.contains { $0.id == id } == false, "the door removed the row")
        let copy = try await CutoverScene.load(URL(fileURLWithPath: path))
        #expect(copy.records.first { $0.id == id }?.userNotes == Self.sentinel,
                "the removed row's latest edit must be recoverable from the safety copy")
    }

    @Test("a held catalog refuses the copy (nothing written) — the door fails safe instead of sealing a copy that lags memory")
    func heldCatalogRefusesTheCopy() async throws {
        let scene = try CutoverScene.make("adv_copy_held"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        await scene.hold()
        defer { scene.release() }
        healthy.userNotes = Self.sentinel
        #expect(scene.model.snapshotCatalog(prefix: "pre-held") == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scene.folder.path)
            .filter { $0.hasPrefix("catalog.pre-held.") }
        #expect(leftovers.isEmpty, Comment(rawValue: "\(leftovers)"))
        #expect(scene.sandbox.catalogLogText().contains("REFUSED safety copy pre-held"))
    }
}
