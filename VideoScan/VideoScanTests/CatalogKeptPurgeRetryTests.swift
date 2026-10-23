// CatalogKeptPurgeRetryTests.swift
// codex #123 F4 (P2): a purge the store KEPT because its replacement was
// refused must not be forgotten. Once the replacement can be stored, the
// pair goes again together: the replacement lands and the old row is
// purged — never a permanent live-path collision, never two rows.
//
// codex #124 F2 (P2): the kept purge's dependency follows the doors.
//   * a later rescan swaps the unstored B for a fresh C: A now waits on C
//     and goes with it (A→C), so C never collides with A's live path;
//   * B is removed outright (gone from disk — the merge's plain purge):
//     A's dependency is RELEASED. A is NOT purged on B's account (nothing
//     proved A's own file gone); it stays live, catalog.log names it, and
//     its own case is decided by its own evidence after a reload.
// Both were red at 3197ef431 (A stayed tied to B: C collided; the release
// was silent).
//
// Suites (filter by SUITE): CatalogKeptPurgeRetryTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Kept purge + corrected replacement: the pair goes again together (codex #123 F4)", .serialized)
@MainActor
struct CatalogKeptPurgeRetryTests {

    @Test("B refused → A kept; B corrected → B stored and A purged, one row at the path after a reload")
    func correctedReplacementCompletesThePair() async throws {
        let scene = try CutoverScene.make("codex123_f4"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let a = try scene.record(.healthy)
        #expect(a.contentFixity != nil, "precondition: A has a whole-file hash")
        #expect(scene.model.saveCatalogNow())
        let path = a.fullPath
        let root = (path as NSString).deletingLastPathComponent

        let b = try scene.probe(of: a)
        b.contentFixity = a.contentFixity   // the rescan hashed it: B is storable, not held
        let trigger = "test_refuse_f4"
        try scene.execSQL("""
            CREATE TRIGGER \(trigger) BEFORE INSERT ON files WHEN NEW.id = '\(b.id.uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected refusal'); END
            """)
        await scene.model.commitScanResults(root: root, volName: "Fixture", targetRecords: [b], scanWasComplete: false)
        _ = scene.model.saveCatalogNow()
        let kept = try await scene.sqliteLoad().records.filter { $0.fullPath == path }.map(\.id)
        #expect(kept == [a.id], "while B is refused, A keeps the file's row")

        // The refusal is corrected, and B changes (so it is sent again).
        try scene.execSQL("DROP TRIGGER \(trigger)")
        b.userNotes = "corrected"
        #expect(scene.model.saveCatalogNow())

        let reloaded = try await scene.sqliteLoad()
        let atPath = reloaded.records.filter { $0.fullPath == path }
        #expect(atPath.map(\.id) == [b.id], "the replacement lands and the old row is purged — one row")
        #expect(atPath.first?.userNotes == "corrected")
    }

    /// A at its path, a rescan's B refused by a trigger, A kept. Returns A, B, path, root.
    private func keptPair(_ scene: CutoverScene) async throws -> (a: VideoRecord, b: VideoRecord, path: String, root: String) {
        try await scene.launchOnSQLite()
        let a = try scene.record(.healthy)
        #expect(scene.model.saveCatalogNow())
        let path = a.fullPath
        let root = (path as NSString).deletingLastPathComponent
        let b = try scene.probe(of: a)
        b.contentFixity = a.contentFixity
        try scene.execSQL("""
            CREATE TRIGGER test_refuse_b BEFORE INSERT ON files WHEN NEW.id = '\(b.id.uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected refusal'); END
            """)
        await scene.model.commitScanResults(root: root, volName: "Fixture", targetRecords: [b], scanWasComplete: false)
        _ = scene.model.saveCatalogNow()
        let kept = try await scene.sqliteLoad().records.filter { $0.fullPath == path }.map(\.id)
        #expect(kept == [a.id], "precondition: while B is refused, A keeps the file's row")
        return (a, b, path, root)
    }

    @Test("#124 F2: A kept for unstored B; a later rescan swaps B for a fresh C → C stored, A purged, one row")
    func keptPurgeFollowsTheNextReplacement() async throws {
        let scene = try CutoverScene.make("codex124_f2_c"); defer { scene.cleanup() }
        let (a, b, path, root) = try await keptPair(scene)
        let c = try scene.probe(of: b)                  // a fresh UUID, never refused
        c.contentFixity = a.contentFixity
        await scene.model.commitScanResults(root: root, volName: "Fixture", targetRecords: [c], scanWasComplete: false)
        _ = scene.model.saveCatalogNow()

        let reloaded = try await scene.sqliteLoad()
        let atPath = reloaded.records.filter { $0.fullPath == path }
        #expect(atPath.map(\.id) == [c.id], "C holds the path; A went with it — one row, no collision")
        #expect(!reloaded.records.contains { $0.id == b.id }, "the refused B was never stored")
    }

    @Test("#124 F2: A kept for unstored B; B removed (gone from disk) → A's dependency released: A stays live, named, not purged")
    func removedReplacementReleasesTheKeptRow() async throws {
        let scene = try CutoverScene.make("codex124_f2_gone"); defer { scene.cleanup() }
        let (a, b, path, root) = try await keptPair(scene)
        // What a COMPLETE rescan does when B's file is gone: B leaves memory
        // and the merge purges its id with no replacement (a plain removal).
        scene.model.records.removeAll { $0.id == b.id }
        scene.model.purgeCatalogRows(ids: [b.id], reason: "rescan of \(root): replaced by a fresh record or gone from disk")
        _ = scene.model.saveCatalogNow()

        let reloaded = try await scene.sqliteLoad()
        let atPath = reloaded.records.filter { $0.fullPath == path }
        #expect(atPath.map(\.id) == [a.id], "A is not purged on B's account")
        #expect(atPath.first?.removal == nil, "and stays live")
        #expect(scene.sandbox.catalogLogText().contains("KEPT \(a.id.uuidString)"),
                "catalog.log names the released row and why it stays")
    }

    /// Source pin (joins the sensor lane): every door that SWAPS a record
    /// names the replacement, so the store never purges the old row alone.
    @Test func swapDoorsNameTheirReplacement() throws {
        // CatalogPurge: the parameter + two swap doors.
        for (file, expected) in [("VideoScanModel+ScanMerge.swift", 2), ("VideoScanModel+CatalogPurge.swift", 3)] {
            let url = try #require(SourceTree.appSourceURL(named: file))
            let code = SourceTree.scan(try String(contentsOf: url, encoding: .utf8)).code
            let calls = code.components(separatedBy: "replacedBy: ").count - 1
            #expect(calls >= expected, "\(file): \(calls) purge call(s) name a replacement, want ≥ \(expected)")
        }
    }
}
