// CatalogBackupSQLiteTests.swift
// File ▸ Back Up Catalog… and Import Catalog… under catalog.sqlite
// (2026-10-19, "JSON gone by Friday"). The bundle carries a sealed
// catalog.sqlite (CatalogBackupSeal) instead of a catalog.json built from
// memory; Import never merges into catalog.sqlite.
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC      back up → the bundled catalog.sqlite opens sealed + read-only
//              (integrity_check at open), its table counts equal the live
//              store's INCLUDING a removed (tombstoned) row and quarantine,
//              an edit made inside the save debounce is in it, the manifest
//              records generation / counts / SHA-256, and there is no
//              catalog.json; the import decision table.
//   ISOLATION  nothing is written beside the live catalog (the folder lists
//              the same names before and after); a held catalog refuses and
//              writes no bundle; a Mac on catalog.json refuses; a JSON bundle
//              under catalog.sqlite is refused with the live database
//              byte-identical (SHA-256 of catalog.sqlite + its -wal).
//   SCALE      12,000 rows: the whole backup is timed against the 15 s line
//              past which CLAUDE.md "Long operations" asks for an MFO job.
//   SENSOR     the round trip pins "the backup is the database" at the store
//              level (counts and tombstones), not at the record level.
//   MEDIA      N/A — no media is opened.
// Every case runs in a CutoverScene sandbox; nothing touches
// ~/Library/Application Support/VideoScan, the real People store or the
// dossier-delta drive (BackupSideFiles points at the sandbox).
//
// Suites (filter by SUITE): CatalogBackupSQLiteTests · CatalogBackupImportTests ·
// CatalogBackupScaleTests

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Helpers

/// Writes a v1 (catalog.json) bundle exactly as builds before 2026-10-19
/// did — the shape Import Catalog must recognise, merge on a catalog.json
/// Mac, and refuse under catalog.sqlite. Overwrites an existing bundle.
@MainActor
enum LegacyJSONBundle {
    static func write(records: [VideoRecord], to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.createDirectory(at: url.appendingPathComponent("people", isDirectory: true), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let exportable = pfExportableRecords(records)
        let snapshot = CatalogSnapshot(version: CatalogSnapshot.currentVersion, savedAt: Date(),
                                       records: exportable, savedFromHost: "legacy-test")
        try CatalogSnapshotDTO(snapshot).encoded(using: encoder).write(to: url.appendingPathComponent("catalog.json"))
        try encoder.encode(VolumesSnapshot(savedAt: Date(), volumes: [])).write(to: url.appendingPathComponent("volumes.json"))
        try encoder.encode(SettingsSnapshot(from: PersonFinderSettings())).write(to: url.appendingPathComponent("settings.json"))
        let manifest = BundleManifest(bundleVersion: 1, exportedAt: Date(), exportedFromHost: "legacy-test",
                                      appVersion: "1.0", appBuild: "1",
                                      counts: .init(records: exportable.count, volumes: 0, people: 0, referencePhotos: 0),
                                      sizes: .init(totalBytes: 0, referencePhotoBytes: 0))
        try encoder.encode(manifest).write(to: url.appendingPathComponent("manifest.json"))
    }
}

@MainActor
extension CutoverScene {

    /// Side files that all live in the sandbox (no people, no deltas drive).
    var sandboxSideFiles: BackupSideFiles {
        BackupSideFiles(poiFolders: [],
                        dossierDeltaDir: sandbox.root.appendingPathComponent("no-deltas", isDirectory: true),
                        catalogManifest: sandbox.root.appendingPathComponent("no-manifest.sha256"))
    }

    var backupURL: URL { sandbox.root.appendingPathComponent("backups/test.videoscanbundle") }

    /// The live store's table counts and generation.
    func liveFacts() async throws -> (counts: CatalogRow.TableCounts, generation: Int) {
        let repository = try #require(model.catalogCutover.committer?.repository)
        let counts = try await repository.read { try $0.recordCounts() }
        return (counts, await repository.generation)
    }

    /// Names in the live catalog folder (the isolation listing).
    func folderNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// SHA-256 over catalog.sqlite and (when present) its -wal: a commit in
    /// WAL mode lands in the -wal first, so both must be unchanged.
    func databaseFingerprint() throws -> String {
        let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
        let walHash = FileManager.default.fileExists(atPath: wal.path) ? try sha256(wal) : "no-wal"
        return try sha256(databaseURL) + "/" + walHash
    }
}

private func backedUp(_ outcome: CatalogBackupOutcome) throws -> BundleExporter.Summary {
    switch outcome {
    case .backedUp(let summary): return summary
    case .refused(let words): throw CutoverFailure(words: "backup refused: \(words)")
    }
}

// MARK: - Back Up Catalog

@Suite("Catalog backup — the bundle is a sealed catalog.sqlite", .serialized)
@MainActor
struct CatalogBackupSQLiteTests {

    static let sentinel = "backup sentinel — typed a second before ⌘E"

    @Test("round trip: the bundled catalog.sqlite opens read-only, integrity ok, counts match the live store with a removed row and quarantine, and the pending edit is in it")
    func backupRoundTrip() async throws {
        let scene = try CutoverScene.make("bk_round", healthyRows: 10); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model

        // A removed row: out of memory, purged through the door (tombstoned).
        let goneID = try scene.bulk(3).id
        model.records.removeAll { $0.id == goneID }
        model.purgeCatalogRows(ids: [goneID], reason: "backup test door")
        #expect(model.saveCatalogNow())
        // A pending edit, inside the save debounce — not committed yet.
        let edited = try scene.bulk(5)
        edited.userNotes = Self.sentinel

        let summary = try backedUp(await model.backUpCatalog(to: scene.backupURL, sideFiles: scene.sandboxSideFiles))
        let live = try await scene.liveFacts()
        #expect(live.counts.files > 0 && live.counts.quarantine > 0, "the fixture has rows and quarantine: \(live.counts)")

        // Open the bundled copy the way a viewer does: sealed, read-only.
        let bundled = scene.backupURL.appendingPathComponent("catalog.sqlite")
        #expect(GRDBCatalogRepository.sealedSnapshotRefusal(bundled) == nil, "rollback journal, nothing beside it")
        let reader = GRDBCatalogRepository(host: "backup-test")
        #expect(await reader.openSealedSnapshot(at: bundled) == .readOnly(reason: GRDBCatalogRepository.sealedSnapshotWords),
                "integrity_check / foreign_key_check / schema passed at open")
        let counts = try await reader.read { try $0.recordCounts() }
        let tombstones = try await reader.read { try $0.tombstoneRevisions(fileID: goneID.uuidString) }
        let generation = await reader.generation
        await reader.close()
        #expect(counts == live.counts, "bundled \(counts) vs live \(live.counts)")
        #expect(!tombstones.isEmpty, "the removed row travels as its tombstone")
        #expect(generation == live.generation)

        // The pending edit is in the copy (commit-first).
        guard case .loaded(let loaded) = await CatalogViewerSnapshot.load(bundled) else {
            Issue.record("the bundled catalog.sqlite did not load read-only"); return
        }
        #expect(loaded.records.first { $0.id == edited.id }?.userNotes == Self.sentinel,
                "the edit typed inside the debounce must be in the backup")
        #expect(!loaded.records.contains { $0.id == goneID }, "a removed row is not a live record")

        // The manifest names the database; no catalog.json; latch + high-water ride along.
        let db = try #require(summary.manifest.catalogDatabase)
        #expect(summary.manifest.bundleVersion == 2)
        #expect(db.sha256 == (try scene.sha256(bundled)))
        #expect(db.generation == live.generation && db.files == live.counts.files && db.quarantine == live.counts.quarantine)
        #expect((db.highWater ?? -1) >= db.generation)
        #expect(summary.manifest.counts.records == live.counts.files)
        let onDisk = try JSONDecoder.iso8601.decode(BundleManifest.self,
                                                    from: Data(contentsOf: scene.backupURL.appendingPathComponent("manifest.json")))
        #expect(onDisk.catalogDatabase == db)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: scene.backupURL.path))
        #expect(!names.contains("catalog.json"), "new bundles carry no JSON catalog")
        #expect(names.isSuperset(of: ["catalog.sqlite", "catalog.cutover", "catalog.highwater", "manifest.json",
                                      "volumes.json", "settings.json", "people"]), "\(names.sorted())")
        #expect(!names.contains { AtomicFilePublish.isTemporaryPublishArtifact($0) }, "no seal temp left: \(names.sorted())")
        #expect(try Data(contentsOf: scene.backupURL.appendingPathComponent("catalog.cutover")) == Data(contentsOf: scene.latchURL))
        #expect(scene.sandbox.catalogLogText().contains("OUTCOME Back Up Catalog"))
        #expect(BundleImporter.catalogKind(of: scene.backupURL) == .sqlite(generation: live.generation))
    }

    @Test("ISOLATION: nothing is written beside the live catalog, and opening the backup leaves it byte-identical")
    func backupWritesNothingBesideTheLiveCatalog() async throws {
        let scene = try CutoverScene.make("bk_iso"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.saveCatalogNow())
        let before = try scene.folderNames()
        try scene.record(.healthy).starRating = 3          // pending, so commit-first has work to do
        _ = try backedUp(await scene.model.backUpCatalog(to: scene.backupURL, sideFiles: scene.sandboxSideFiles))
        let after = try scene.folderNames()
        #expect(after == before, "new names beside the live catalog: \(after.subtracting(before).sorted())")

        let bundled = scene.backupURL.appendingPathComponent("catalog.sqlite")
        let sha = try scene.sha256(bundled)
        _ = try await CatalogViewerSnapshot.inspect(bundled)
        #expect(try scene.sha256(bundled) == sha, "a read-only open changed the backup")
        let sidecars = try FileManager.default.contentsOfDirectory(atPath: scene.backupURL.path)
            .filter { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") || $0.hasSuffix("-journal") }
        #expect(sidecars.isEmpty, Comment(rawValue: "\(sidecars)"))
    }

    @Test("a held catalog refuses with words, and no bundle is written")
    func heldCatalogRefuses() async throws {
        let scene = try CutoverScene.make("bk_held"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        await scene.hold()
        defer { scene.release() }
        try scene.record(.healthy).userNotes = Self.sentinel
        guard case .refused(let words) = await scene.model.backUpCatalog(to: scene.backupURL, sideFiles: scene.sandboxSideFiles) else {
            Issue.record("a held catalog must refuse the backup"); return
        }
        #expect(words.contains("held"), Comment(rawValue: words))
        #expect(words.contains("could not be saved to catalog.sqlite first"), Comment(rawValue: words))
        #expect(!FileManager.default.fileExists(atPath: scene.backupURL.path), "no bundle on a refusal")
        #expect(scene.sandbox.catalogLogText().contains("REFUSED Back Up Catalog"))
    }

    @Test("a Mac whose catalog is still catalog.json refuses: backups hold catalog.sqlite only")
    func jsonAuthorityRefuses() async throws {
        let scene = try CutoverScene.make("bk_json"); defer { scene.cleanup() }
        scene.model.records = scene.model.loadCatalogAtLaunch()     // no latch → catalog.json
        #expect(!scene.model.catalogCutover.isSQLiteAuthority)
        guard case .refused(let words) = await scene.model.backUpCatalog(to: scene.backupURL, sideFiles: scene.sandboxSideFiles) else {
            Issue.record("catalog.json must refuse the backup"); return
        }
        #expect(words.contains("catalog.sqlite only"), Comment(rawValue: words))
        #expect(!FileManager.default.fileExists(atPath: scene.backupURL.path))
    }
}

// MARK: - Import Catalog

@Suite("Catalog backup — Import never merges into catalog.sqlite", .serialized)
@MainActor
struct CatalogBackupImportTests {

    @Test("a JSON bundle under catalog.sqlite is refused with the exact words; the database is byte-identical (SHA-256 before == after)")
    func jsonBundleRefusedDatabaseUnchanged() async throws {
        let scene = try CutoverScene.make("bk_imp_json"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        #expect(model.saveCatalogNow())
        // A bundle with a brand-new record and a duplicate of a live one.
        let fresh = VideoRecord()
        fresh.filename = "from_another_mac.mov"
        fresh.fullPath = "/Volumes/Elsewhere/from_another_mac.mov"
        fresh.partialMD5 = "feedface"
        fresh.sizeBytes = 9_999
        let url = scene.sandbox.root.appendingPathComponent("old.videoscanbundle")
        try LegacyJSONBundle.write(records: [fresh, try scene.record(.healthy)], to: url)

        let fingerprint = try scene.databaseFingerprint()
        let before = try await scene.liveFacts()
        let recordCount = model.records.count
        let targets = model.scanTargets.count

        #expect(BundleImporter.catalogKind(of: url) == .legacyJSON)
        #expect(model.bundleImportDecision(for: url) == .refuse(VideoScanModel.jsonBundleUnderSQLiteWords))
        #expect(VideoScanModel.jsonBundleUnderSQLiteWords
                == "this backup is from before the database switch; it can't be merged into catalog.sqlite")

        // The door's own guard, for any caller that skips the panel.
        var payload = try BundleImporter.read(from: url)
        payload.poiFoldersInBundle = []
        let result = await model.applyBundlePayload(payload, bundleURL: url)
        #expect(result.refusal == VideoScanModel.jsonBundleUnderSQLiteWords)
        #expect(result.recordsAdded == 0 && result.volumesAdded == 0)

        #expect(model.records.count == recordCount, "no JSON record joined memory")
        #expect(!model.records.contains { $0.id == fresh.id })
        #expect(model.scanTargets.count == targets)
        #expect(try scene.databaseFingerprint() == fingerprint, "catalog.sqlite (+ -wal) changed")
        let after = try await scene.liveFacts()
        #expect(after.counts == before.counts && after.generation == before.generation)
        #expect(scene.sandbox.catalogLogText().contains("REFUSED Import Catalog"))
    }

    @Test("a catalog.sqlite bundle is refused (no merge, no safe Restore yet) and the database is unchanged")
    func sqliteBundleRefused() async throws {
        let scene = try CutoverScene.make("bk_imp_sqlite"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try backedUp(await scene.model.backUpCatalog(to: scene.backupURL, sideFiles: scene.sandboxSideFiles))
        let fingerprint = try scene.databaseFingerprint()
        guard case .refuse(let words) = scene.model.bundleImportDecision(for: scene.backupURL) else {
            Issue.record("a catalog.sqlite bundle must be refused"); return
        }
        #expect(words.contains("never merged into catalog.sqlite"), Comment(rawValue: words))
        #expect(words.contains("no safe Restore"), Comment(rawValue: words))
        #expect(try scene.databaseFingerprint() == fingerprint)
    }

    @Test("decision table: only a JSON bundle on a catalog.json Mac merges; everything else refuses")
    func decisionTable() {
        typealias M = VideoScanModel
        #expect(M.bundleImportDecision(kind: .legacyJSON, isSQLiteAuthority: false) == .mergeLegacyJSON)
        #expect(M.bundleImportDecision(kind: .legacyJSON, isSQLiteAuthority: true) == .refuse(M.jsonBundleUnderSQLiteWords))
        for kind: BundleImporter.CatalogKind in [.sqlite(generation: 7), .sqlite(generation: nil), .none] {
            for authority in [true, false] {
                guard case .refuse = M.bundleImportDecision(kind: kind, isSQLiteAuthority: authority) else {
                    Issue.record("\(kind) on sqlite=\(authority) must refuse"); continue
                }
            }
        }
    }
}

// MARK: - Scale

@Suite("Catalog backup — 12,000 rows, timed", .serialized)
@MainActor
struct CatalogBackupScaleTests {

    /// Past this, CLAUDE.md "Long operations" wants an MFO job instead of
    /// console progress lines.
    static let mfoLine: Duration = .seconds(15)

    @Test("SCALE: a 12,000-row backup (commit-first + seal + check + hash) stays under the 15 s MFO line")
    func twelveThousandRows() async throws {
        let scene = try CutoverScene.make("bk_scale", healthyRows: 12_000); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.records.count >= 12_000)
        try scene.bulk(6_000).userNotes = "scale edit"
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let summary = try backedUp(await scene.model.backUpCatalog(to: scene.backupURL, sideFiles: scene.sandboxSideFiles))
        let elapsed = clock.now - start
        let db = try #require(summary.manifest.catalogDatabase)
        print("[backup-scale] \(db.files) file rows, \(ByteCountFormatter.string(fromByteCount: db.bytes, countStyle: .file)): \(elapsed) (\(TimingBudget.loadDescription()))")
        #expect(db.files >= 12_000)
        _ = expectWithinTimingBudget("12,000-row Back Up Catalog", measured: elapsed, budget: Self.mfoLine, loadBefore: load)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
