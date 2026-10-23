// CatalogKeptPurgeRetryTests.swift
// codex #123 F4 (P2): a purge the store KEPT because its replacement was
// refused must not be forgotten. Once the replacement can be stored, the
// pair goes again together: the replacement lands and the old row is
// purged — never a permanent live-path collision, never two rows.
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
