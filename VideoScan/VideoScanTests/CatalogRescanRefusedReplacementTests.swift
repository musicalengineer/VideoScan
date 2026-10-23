// CatalogRescanRefusedReplacementTests.swift
// P0 2026-10-22, end to end through the app: rescan merge → committer →
// catalog.sqlite → reload. At 18:05:37 a rescan of /Volumes/FamilyArchive
// replaced 641 records with fresh instances under new ids; the commit
// purged all 641 old rows and REFUSED 95 replacements — import-era archive
// copies (`promoted_by = 'import'`, source row never stored) whose fresh
// instance the live writer inserts as a NEW `archive_copies` row with
// `promoted_by = 'promote'` and no source, which `archive_copies_need_source`
// refuses. After the relaunch those 95 archived Masters had no live row.
// The store now purges a replaced row only together with its replacement
// (VideoScanCore CatalogCommitReplacementTests); this pins the whole chain
// on the incident's exact shape.
//
//   LOGIC  a rescan of an import-era archive copy: after a reload the
//          ORIGINAL row is still there, live, at its path, the refused
//          replacement is not stored, and catalog.log names the kept row.
//          Control: an ordinary rescan swap still purges the old id
//          (CatalogExplicitPurgeTests.rescanSwapsKeepValues, unchanged).
//
// Suites (filter by SUITE): CatalogRescanRefusedReplacementTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Rescan → commit → reload: a refused replacement never costs the file its catalog row (P0 2026-10-22)", .serialized)
@MainActor
struct CatalogRescanRefusedReplacementTests {

    @Test("a rescan of an import-era archive copy whose replacement is refused keeps the original row live after a reload")
    func refusedArchiveReplacementKeepsOriginalRow() async throws {
        let scene = try CutoverScene.make("p0_refused_replacement"); defer { scene.cleanup() }
        try await scene.importCatalog()
        // The incident shape: an archive copy the JSON import adopted, whose
        // source row catalog.sqlite never held (it was quarantined).
        let healthyID = PoisonedCatalogFixture.id(.healthy)
        try scene.execSQL("""
            INSERT INTO archive_copies (file_id, source_file_id, source_row_id, archived_at, fixity_verified_at, promoted_by)
            VALUES ('\(healthyID)', NULL, '\(UUID().uuidString)', 1792000000, 1792000000, 'import')
            """)
        try scene.writeLatch()
        scene.model.records = scene.model.loadCatalogAtLaunch()
        let original = try scene.record(.healthy)
        #expect(original.archiveFixity != nil, "precondition: the stored row loads with its archive fixity")
        let path = original.fullPath
        let root = (path as NSString).deletingLastPathComponent

        // The rescan re-sees the file: a fresh instance under a new id; the
        // merge carries the live provenance and fixity onto it.
        let probed = try scene.probe(of: original)
        await scene.model.commitScanResults(root: root, volName: "Fixture", targetRecords: [probed],
                                            scanWasComplete: false)
        _ = scene.model.saveCatalogNow()   // reports the refusal; must not cost the old row
        // The shape that lost the row in the first cut of the fix: later
        // commits re-sent the purge WITHOUT the (waiting) replacement.
        let committer = try scene.committer()
        for _ in 0..<3 {
            committer.scheduleCommit(after: .zero)
            try await scene.settle()
        }
        _ = scene.model.saveCatalogNow()

        let reloaded = try await scene.sqliteLoad()
        let atPath = reloaded.records.filter { $0.fullPath == path }
        #expect(atPath.map(\.id) == [original.id], "the file keeps its ORIGINAL catalog row")
        #expect(atPath.first?.removal == nil, "and that row is live")
        #expect(!reloaded.records.contains { $0.id == probed.id }, "the refused replacement was not stored")
        #expect(scene.sandbox.catalogLogText().contains("NOT REMOVED \(original.id.uuidString)"),
                "catalog.log names the row the store kept")
    }
}
