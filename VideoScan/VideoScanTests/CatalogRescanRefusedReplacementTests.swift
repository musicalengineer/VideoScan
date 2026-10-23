// CatalogRescanRefusedReplacementTests.swift
// P0 2026-10-22, end to end through the app: rescan merge → committer →
// catalog.sqlite → reload. At 18:05:37 a rescan of /Volumes/FamilyArchive
// replaced 641 records with fresh instances under new ids; the commit
// purged all 641 old rows and REFUSED 95 replacements — import-era archive
// copies (`promoted_by = 'import'`, source row never stored) whose fresh
// instance the live writer inserted as a NEW `archive_copies` row with a
// hard-coded `promoted_by = 'promote'` and no source, which
// `archive_copies_need_source` refuses. After the relaunch those 95
// archived Masters had no live row.
//
// Two fixes, two tests:
//   * f59f6d841 / 868c8d2ae — a replaced row is purged only together with
//     its replacement (VideoScanCore CatalogCommitReplacementTests). Pinned
//     here with an INJECTED refusal: the original row survives.
//   * root cause — the replacement's archive copy takes the provenance of
//     the row it replaces (VideoScanCore CatalogCommitArchiveProvenanceTests,
//     100-row scale there). Pinned here on the incident's exact shape: the
//     rescan's replacement LANDS as 'import', the old row is purged, and
//     catalog.log has no NOT REMOVED.
//
// Suites (filter by SUITE): CatalogRescanRefusedReplacementTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Rescan → commit → reload: an import-era archived Master's replacement lands; a refused one never costs the file its row (P0 2026-10-22)", .serialized)
@MainActor
struct CatalogRescanRefusedReplacementTests {

    /// Import the fixture, make the healthy row the incident's import-era
    /// archive copy (its source row quarantined, never stored), launch on
    /// SQLite. Returns the loaded original.
    private func importEraArchiveCopy(_ scene: CutoverScene) async throws -> VideoRecord {
        try await scene.importCatalog()
        let healthyID = PoisonedCatalogFixture.id(.healthy)
        try scene.execSQL("""
            INSERT INTO archive_copies (file_id, source_file_id, source_row_id, archived_at, fixity_verified_at, promoted_by)
            VALUES ('\(healthyID)', NULL, '\(UUID().uuidString)', 1792000000, 1792000000, 'import')
            """)
        try scene.writeLatch()
        scene.model.records = scene.model.loadCatalogAtLaunch()
        let original = try scene.record(.healthy)
        #expect(original.archiveFixity != nil, "precondition: the stored row loads with its archive fixity")
        return original
    }

    @Test("the incident: a rescan of an import-era archive copy lands its replacement as 'import' and purges the old row — no NOT REMOVED")
    func importEraReplacementLands() async throws {
        let scene = try CutoverScene.make("p0_import_era_lands"); defer { scene.cleanup() }
        let original = try await importEraArchiveCopy(scene)
        let path = original.fullPath
        let root = (path as NSString).deletingLastPathComponent

        let probed = try scene.probe(of: original)
        await scene.model.commitScanResults(root: root, volName: "Fixture", targetRecords: [probed],
                                            scanWasComplete: false)
        _ = scene.model.saveCatalogNow()
        let committer = try scene.committer()
        committer.scheduleCommit(after: .zero)
        try await scene.settle()

        let reloaded = try await scene.sqliteLoad()
        let atPath = reloaded.records.filter { $0.fullPath == path }
        #expect(atPath.map(\.id) == [probed.id], "the rescan's replacement is the file's one live row")
        #expect(atPath.first?.archiveFixity != nil, "and it is still an archive copy")
        #expect(!reloaded.records.contains { $0.id == original.id }, "the old row is purged")
        #expect(try scene.sqliteRows("SELECT promoted_by || '|' || ifnull(source_file_id, 'NULL') FROM archive_copies WHERE file_id = '\(probed.id.uuidString)'")
                == ["import|NULL"], "the replacement keeps the import-era provenance")
        let log = scene.sandbox.catalogLogText()
        #expect(!log.contains("NOT REMOVED"), "no purge was kept back")
        #expect(!log.contains("an archive copy names its source"), "the trigger did not refuse the replacement")
    }

    @Test("a rescan whose replacement is refused (injected) keeps the original row live after a reload")
    func refusedReplacementKeepsOriginalRow() async throws {
        let scene = try CutoverScene.make("p0_refused_replacement"); defer { scene.cleanup() }
        let original = try await importEraArchiveCopy(scene)
        let path = original.fullPath
        let root = (path as NSString).deletingLastPathComponent

        // The rescan re-sees the file: a fresh instance under a new id; the
        // merge carries the live provenance and fixity onto it. The store
        // refuses it (any refusal — the archive-copy one is fixed).
        let probed = try scene.probe(of: original)
        try scene.execSQL("""
            CREATE TRIGGER test_refuse_replacement BEFORE INSERT ON files WHEN NEW.id = '\(probed.id.uuidString)'
            BEGIN SELECT RAISE(ABORT, 'injected refusal of the replacement'); END
            """)
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
