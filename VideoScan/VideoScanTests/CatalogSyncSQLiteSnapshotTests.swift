// CatalogSyncSQLiteSnapshotTests.swift
// CatalogSync phase 2 (2026-10-19, cutover audit gap 3): the master
// publishes a sealed catalog.sqlite for the viewer Macs; a viewer opens it
// read-only through the master's own read path.
//
//   LOGIC      master publish: the snapshot opens sealed, has the source's
//              row count and generation, the latch rides beside it, the
//              manifest verifies and no longer names catalog.json;
//              the publisher commits first, publishes on a generation
//              change only, and skips (with words) when it cannot commit.
//   ISOLATION  a viewer open never modifies the snapshot (SHA-256 before ==
//              after), leaves no -wal / -shm / -journal anywhere in the
//              synced folder, and refuses every write; a WAL database (the
//              master's live catalog.sqlite) is refused by the sealed open.
//   TRUTH      a manifest mismatch keeps the old snapshot on disk and on
//              screen; a JSON-only folder shows the legacy label; a master
//              on an older build is refused in words.
//
// The fixture is the P0 suite's poisoned catalog through a real import
// (CutoverScene). Everything lives under the scene's sandbox; nothing
// touches ~/Library/Application Support/VideoScan.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Stubs

private struct SnapshotHost: HostnameSource {
    let value: String
    func currentHostname() -> String { value }
}

/// Mirrors the master tree into the staging dir (cp, not rsync) and lets a
/// test tamper with the staged copy before verify.
private final class SnapshotStubRsync: RsyncRunner, @unchecked Sendable {
    let source: URL
    var postCopy: ((URL) -> Void)?
    init(source: URL) { self.source = source }

    func run(args: [String], destDir: URL) async -> RsyncOutcome {
        let fm = FileManager.default
        try? fm.removeItem(at: destDir)
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        for kid in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.copyItem(at: kid, to: destDir.appendingPathComponent(kid.lastPathComponent))
        }
        postCopy?(destDir)
        return RsyncOutcome(succeeded: true, exitCode: 0, stderr: "")
    }
}

/// What a test loader adopted (a mutable box the closure can write to).
@MainActor
private final class Adopted {
    var records: Int?
    var loads = 0
}

// MARK: - The world: one master store, one master tree, one viewer

@MainActor
private struct SnapshotWorld {
    let scene: CutoverScene
    let repository: GRDBCatalogRepository
    /// What a load of the master's catalog.sqlite gives (the record count a viewer must see).
    let masterRecords: Int

    var masterLive: URL { scene.sandbox.root.appendingPathComponent("master-live", isDirectory: true) }
    var viewerRoot: URL { scene.sandbox.root.appendingPathComponent("viewer", isDirectory: true) }
    var viewerPaths: CatalogSyncPaths {
        CatalogSyncPaths(liveDir: viewerRoot.appendingPathComponent("live", isDirectory: true),
                         stagingDir: viewerRoot.appendingPathComponent("staging", isDirectory: true),
                         previousDir: viewerRoot.appendingPathComponent("previous", isDirectory: true),
                         lastSyncFile: viewerRoot.appendingPathComponent("last_sync.txt"))
    }
    var viewerSnapshot: URL { CatalogViewerSnapshot.databaseURL(in: viewerPaths.liveDir) }

    static func make(_ label: String) async throws -> SnapshotWorld {
        let scene = try CutoverScene.make("sync2_\(label)")
        try await scene.importCatalog()
        // The master's first SQLite launch fills the display tables; a
        // snapshot is only ever taken of a catalog that has had one.
        let masterRecords = try await scene.sqliteLoad().records.count
        try scene.writeLatch()
        let repository = GRDBCatalogRepository(host: "sync2-test")
        guard case .readWrite = await repository.open(at: scene.databaseURL) else {
            throw CutoverFailure(words: "the master's catalog.sqlite did not open read-write")
        }
        let world = SnapshotWorld(scene: scene, repository: repository, masterRecords: masterRecords)
        try FileManager.default.createDirectory(at: world.masterLive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: world.viewerPaths.liveDir, withIntermediateDirectories: true)
        // The frozen catalog.json is still on the master: it must NOT be published.
        try Data("{\"version\":4,\"records\":[]}".utf8).write(to: world.masterLive.appendingPathComponent("catalog.json"))
        return world
    }

    /// Make the world, run `body`, and close the store + remove the sandbox
    /// on every path (≈ RAII by hand: Swift has no async defer).
    static func with(_ label: String, _ body: (SnapshotWorld) async throws -> Void) async throws {
        let world = try await make(label)
        do {
            try await body(world)
        } catch {
            await world.cleanup()
            throw error
        }
        await world.cleanup()
    }

    func cleanup() async {
        await repository.close()
        scene.cleanup()
    }

    /// The master's publish: seal + latch, then the manifest over the phase-2 scope.
    @discardableResult
    func publish() async throws -> CatalogViewerSnapshot.Published {
        let published = try await CatalogViewerSnapshot.publish(from: repository, latch: scene.latchURL, into: masterLive)
        _ = try CatalogSync.computeAndWriteManifest(liveDir: masterLive, scope: .sqliteCatalog)
        return published
    }

    func master() -> CatalogSync {
        CatalogSync(paths: CatalogSyncPaths(liveDir: masterLive,
                                            stagingDir: masterLive.appendingPathComponent(".s"),
                                            previousDir: masterLive.appendingPathComponent(".p"),
                                            lastSyncFile: masterLive.appendingPathComponent(".t")),
                    hostnameSource: SnapshotHost(value: "RicksM4.local"),
                    rsyncRunner: SnapshotStubRsync(source: masterLive),
                    masterHostname: "RicksM4.local", remoteUser: "rickb", scope: .sqliteCatalog, log: { _ in })
    }

    func viewer(_ runner: SnapshotStubRsync, adopted: Adopted) -> CatalogSync {
        let sync = CatalogSync(paths: viewerPaths, hostnameSource: SnapshotHost(value: "RicksMBP"),
                               rsyncRunner: runner, masterHostname: "RicksM4.local", remoteUser: "rickb",
                               scope: .sqliteCatalog, log: { _ in })
        // The same mapping VideoScanModel.showViewerCatalog uses; the model
        // only adds the records swap (and the viewer-role guard).
        sync.viewerCatalogLoader = { source in
            await CatalogViewerSnapshot.show(source, note: { _ in }, adopt: { result in
                adopted.records = result.records.count
                adopted.loads += 1
            })
        }
        return sync
    }

    func masterCounts() async throws -> CatalogRow.TableCounts {
        try await repository.read { try $0.recordCounts() }
    }
}

private func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

/// Every file under `root` (relative paths, sorted), hidden files included.
private func listing(_ root: URL) -> [String] {
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var out: [String] = []
    for case let url as URL in walker { out.append(CatalogSync.relativePath(of: url, under: root)) }
    return out.sorted()
}

private func sidecars(_ root: URL) -> [String] {
    listing(root).filter { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") || $0.hasSuffix("-journal") }
}

// MARK: - Master publish

@MainActor
@Suite("CatalogSyncSQLiteSnapshot master publish", .serialized)
struct CatalogSyncSQLiteSnapshotPublishTests {

    @Test("master publish: the sealed snapshot opens, has the source's rows and generation, and the manifest verifies without catalog.json")
    func publishSealsAVerifiableSnapshot() async throws {
        try await SnapshotWorld.with("publish") { world in
            let source = try await world.masterCounts()
            #expect(source.files > 0, "the fixture has rows")

            let published = try await world.publish()
            let snapshot = CatalogViewerSnapshot.databaseURL(in: world.masterLive)
            #expect(GRDBCatalogRepository.sealedSnapshotRefusal(snapshot) == nil, "rollback journal, nothing beside it")
            #expect(published.files == source.files)
            #expect(published.generation == (await world.repository.generation))
            let checked = try await CatalogViewerSnapshot.validate(snapshot)
            #expect(checked == CatalogViewerSnapshot.Checked(generation: published.generation, files: source.files))
            #expect(try Data(contentsOf: CatalogViewerSnapshot.latchURL(in: world.masterLive)) == Data(contentsOf: world.scene.latchURL))

            try world.master().verifyManifest(in: world.masterLive)
            let manifest = try String(contentsOf: world.masterLive.appendingPathComponent("manifest.sha256"), encoding: .utf8)
            #expect(manifest.contains("  viewer-catalog/catalog.sqlite\n"))
            #expect(manifest.contains("  viewer-catalog/catalog.cutover\n"))
            #expect(!manifest.contains("  catalog.json"), "catalog.json is no longer published")
            #expect(CatalogViewerSnapshot.snapshotHash(inManifest: manifest) == (try sha256(snapshot)))
            #expect(listing(CatalogViewerSnapshot.directory(in: world.masterLive)) == ["catalog.cutover", "catalog.sqlite"],
                    "no publish temp left behind")
        }
    }

    @Test("master publish refuses without the latch and leaves the last published pair as it was")
    func publishWithoutLatchRefuses() async throws {
        try await SnapshotWorld.with("nolatch") { world in
            try await world.publish()
            let before = try sha256(CatalogViewerSnapshot.databaseURL(in: world.masterLive))
            let missing = world.scene.sandbox.root.appendingPathComponent("no-such.cutover")
            await #expect(throws: CatalogViewerSnapshot.PublishError.self) {
                _ = try await CatalogViewerSnapshot.publish(from: world.repository, latch: missing, into: world.masterLive)
            }
            #expect(try sha256(CatalogViewerSnapshot.databaseURL(in: world.masterLive)) == before)
        }
    }

    @Test("publisher: commits first on every tick, publishes only when the generation moved, skips with words when it cannot commit")
    func publisherCommitsFirstAndThrottlesOnGeneration() async throws {
        try await SnapshotWorld.with("publisher") { world in
            var commits = 0
            var refusal: String?
            var published = 0
            var store: CatalogSnapshotPublisher.Store? = CatalogSnapshotPublisher.Store(
                repository: world.repository, commitFirst: { commits += 1; return refusal })
            let publisher = CatalogSnapshotPublisher(
                liveDir: world.masterLive,
                source: .init(store: { store }, latchURL: world.scene.latchURL),
                log: { _ in }, onPublished: { published += 1 })

            guard case .published(let first) = await publisher.publishIfChanged() else {
                Issue.record("first tick must publish: \(String(describing: publisher.lastOutcome))"); return
            }
            #expect(commits == 1 && published == 1)
            #expect(await publisher.publishIfChanged() == .unchanged(generation: first.generation))
            #expect(commits == 2 && published == 1, "commit-first runs every tick; nothing republished")

            // A new commit on the master moves the generation → republished.
            guard case .committed = await world.repository.write(as: .ui, { _ in }) else {
                Issue.record("the test commit did not land"); return
            }
            guard case .published(let second) = await publisher.publishIfChanged() else {
                Issue.record("a moved generation must publish: \(String(describing: publisher.lastOutcome))"); return
            }
            #expect(second.generation == first.generation + 1)
            let republished = try await CatalogViewerSnapshot.validate(CatalogViewerSnapshot.databaseURL(in: world.masterLive))
            #expect(republished.generation == second.generation)

            refusal = "held — a Promote job holds catalog writes"
            guard case .skipped(let words) = await publisher.publishIfChanged() else {
                Issue.record("a refused commit must skip"); return
            }
            #expect(words.contains("could not be committed first"))
            #expect(published == 2)

            store = nil
            guard case .skipped(let jsonWords) = await publisher.publishIfChanged() else {
                Issue.record("no store must skip"); return
            }
            #expect(jsonWords.contains("catalog.json is this Mac's catalog"))
        }
    }

    @Test("publisher (GH #350): while a job writes, a tick seals nothing and commits nothing (said once); the first tick after it ends publishes once")
    func publisherWaitsForARunningJobThenPublishesOnce() async throws {
        try await SnapshotWorld.with("busy") { world in
            var commits = 0
            var published = 0
            var lines: [String] = []
            var writer: String? = "Fill In Full Hashes is running"
            let store = CatalogSnapshotPublisher.Store(repository: world.repository, commitFirst: { commits += 1; return nil })
            let publisher = CatalogSnapshotPublisher(
                liveDir: world.masterLive,
                source: .init(store: { store }, latchURL: world.scene.latchURL, busy: { writer }),
                log: { lines.append($0) }, onPublished: { published += 1 })

            // The job commits between ticks: the generation moves every time.
            for tick in 0..<3 {
                guard case .committed = await world.repository.write(as: .ui, { _ in }) else {
                    Issue.record("the test commit did not land"); return
                }
                guard case .skipped(let words) = await publisher.publishIfChanged() else {
                    Issue.record("tick \(tick): a running job must hold the publish: \(String(describing: publisher.lastOutcome))"); return
                }
                #expect(words.contains("Fill In Full Hashes is running"), Comment(rawValue: words))
                #expect(publisher.isHeldForWriter)
            }
            #expect(commits == 0, "commit-first never runs on the main actor while the job writes")
            #expect(published == 0, "nothing sealed, nothing integrity-checked")
            #expect(!FileManager.default.fileExists(atPath: CatalogViewerSnapshot.databaseURL(in: world.masterLive).path))
            #expect(lines.filter { $0.contains("published once it ends") }.count == 1, "the reason is said once: \(lines)")

            writer = nil
            guard case .published(let after) = await publisher.publishIfChanged() else {
                Issue.record("the first tick after the job must publish: \(String(describing: publisher.lastOutcome))"); return
            }
            #expect(commits == 1 && published == 1)
            #expect(!publisher.isHeldForWriter)
            let sealed = try await CatalogViewerSnapshot.validate(CatalogViewerSnapshot.databaseURL(in: world.masterLive))
            #expect(sealed.generation == after.generation, "the copy holds what the job wrote")
            #expect(await publisher.publishIfChanged() == .unchanged(generation: after.generation), "published once, not again")

            writer = "Fill In Full Hashes is running"
            _ = await publisher.publishIfChanged()
            #expect(lines.filter { $0.contains("published once it ends") }.count == 2, "a new hold says why again")
        }
    }

    @Test("scope: production syncs the sealed snapshot + latch, never catalog.json")
    func productionScopeCarriesTheSnapshotNotTheJSON() {
        let scope = CatalogSyncScope.sqliteCatalog
        #expect(scope.carriesSQLiteSnapshot)
        #expect(!CatalogSyncScope.phase1.carriesSQLiteSnapshot)
        let rules = scope.rsyncIncludeRules
        #expect(rules.contains("--include=viewer-catalog/"))
        #expect(rules.contains("--include=viewer-catalog/catalog.sqlite"))
        #expect(rules.contains("--include=viewer-catalog/catalog.cutover"))
        #expect(!rules.contains { $0.contains("catalog.json") })
        #expect(!rules.contains("--include=viewer-catalog/**"), "a publish temp is never mirrored")
        #expect(CatalogSync.production().scope == .sqliteCatalog)
    }
}

// MARK: - Viewer open

@MainActor
@Suite("CatalogSyncSQLiteSnapshot viewer open", .serialized)
struct CatalogSyncSQLiteSnapshotViewerTests {

    @Test("ISOLATION: a viewer open is read-only — the snapshot's SHA-256 is unchanged and no -wal/-shm/-journal appears in the synced folder")
    func viewerOpenNeverModifiesTheSnapshot() async throws {
        try await SnapshotWorld.with("isolation") { world in
            let published = try await world.publish()
            let adopted = Adopted()
            let viewer = world.viewer(SnapshotStubRsync(source: world.masterLive), adopted: adopted)

            await viewer.syncFromMaster()
            #expect(viewer.state.isSynced, "\(viewer.state.phase)")
            #expect(!FileManager.default.fileExists(atPath: world.viewerPaths.liveDir.appendingPathComponent("catalog.json").path),
                    "the viewer does not take catalog.json")
            // syncFromMaster already opened and loaded it once; prove the folder after that.
            #expect(viewer.state.viewerCatalog == .snapshot(generation: published.generation, records: world.masterRecords))
            #expect(adopted.records == world.masterRecords && adopted.loads == 1)
            let shaAfterFirstOpen = try sha256(world.viewerSnapshot)
            #expect(shaAfterFirstOpen == (try sha256(CatalogViewerSnapshot.databaseURL(in: world.masterLive))),
                    "the open did not change one byte of what the master published")
            let before = listing(world.viewerPaths.liveDir)
            #expect(sidecars(world.viewerPaths.liveDir).isEmpty, "no sidecar after the open: \(before)")

            // Open again directly, read everything, try to write — then compare.
            let repository = GRDBCatalogRepository(host: "viewer-test")
            #expect(await repository.openSealedSnapshot(at: world.viewerSnapshot) == .readOnly(reason: GRDBCatalogRepository.sealedSnapshotWords))
            let loaded = try await SQLiteCatalogLoader.load(repository: repository)
            #expect(loaded.records.count == world.masterRecords)
            guard case .refused = await repository.write(as: .ui, { _ in }) else {
                Issue.record("a write on the sealed snapshot must be refused"); return
            }
            guard case .refused = repository.writeBlocking(as: .save, { _ in }) else {
                Issue.record("a blocking write on the sealed snapshot must be refused"); return
            }
            #expect(sidecars(world.viewerPaths.liveDir).isEmpty, "no sidecar while open: \(listing(world.viewerPaths.liveDir))")
            await repository.close()

            #expect(try sha256(world.viewerSnapshot) == shaAfterFirstOpen)
            #expect(listing(world.viewerPaths.liveDir) == before, "the synced folder is file-for-file what it was")
            #expect(sidecars(world.viewerPaths.liveDir).isEmpty)
        }
    }

    @Test("ISOLATION: the sealed open refuses a WAL database (the master's live catalog.sqlite) without touching it")
    func sealedOpenRefusesAWALDatabase() async throws {
        try await SnapshotWorld.with("wal") { world in
            let refusal = GRDBCatalogRepository.sealedSnapshotRefusal(world.scene.databaseURL)
            #expect(refusal != nil, "the live store is WAL / has sidecars")
            let repository = GRDBCatalogRepository(host: "viewer-test")
            guard case .refused = await repository.openSealedSnapshot(at: world.scene.databaseURL) else {
                Issue.record("a WAL database must be refused by the sealed open"); return
            }
            await repository.close()
        }
    }

    @Test("an unchanged snapshot is not reloaded on the next sync")
    func unchangedSnapshotIsNotReloaded() async throws {
        try await SnapshotWorld.with("unchanged") { world in
            try await world.publish()
            let adopted = Adopted()
            let viewer = world.viewer(SnapshotStubRsync(source: world.masterLive), adopted: adopted)
            await viewer.syncFromMaster()
            await viewer.syncFromMaster()
            #expect(viewer.state.isSynced)
            #expect(adopted.loads == 1, "same manifest hash → no second load")
        }
    }

    @Test("TRUTH: a manifest mismatch keeps the old snapshot on disk and on screen, and says the sync was refused")
    func manifestMismatchKeepsTheOldSnapshot() async throws {
        try await SnapshotWorld.with("mismatch") { world in
            let published = try await world.publish()
            let adopted = Adopted()
            let runner = SnapshotStubRsync(source: world.masterLive)
            let viewer = world.viewer(runner, adopted: adopted)
            await viewer.syncFromMaster()
            #expect(viewer.state.isSynced)
            let good = try sha256(world.viewerSnapshot)

            runner.postCopy = { staging in
                let staged = CatalogViewerSnapshot.databaseURL(in: staging)
                if let handle = try? FileHandle(forWritingTo: staged) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data("torn in transit".utf8))
                    try? handle.close()
                }
            }
            await viewer.syncFromMaster()
            guard case .failed(let reason) = viewer.state.phase else {
                Issue.record("expected a refused sync, got \(viewer.state.phase)"); return
            }
            #expect(reason.contains("manifest verify failed"))
            #expect(reason.contains("sha256 mismatch: viewer-catalog/catalog.sqlite"))
            #expect(viewer.state.refusal == reason)
            #expect(try sha256(world.viewerSnapshot) == good, "the last good snapshot is kept")
            #expect(viewer.state.viewerCatalog == .snapshot(generation: published.generation, records: world.masterRecords))
            #expect(adopted.loads == 1, "the kept snapshot is not reloaded")
        }
    }
}

// MARK: - The legacy (JSON-only) folder

@MainActor
@Suite("CatalogSyncSQLiteSnapshot legacy JSON", .serialized)
struct CatalogSyncSQLiteSnapshotLegacyTests {

    @Test("a viewer whose folder has only the old catalog.json shows it, labelled 'older catalog'")
    func jsonOnlyFolderShowsTheLegacyLabel() async throws {
        try await SnapshotWorld.with("legacy") { world in
            let json = world.viewerPaths.liveDir.appendingPathComponent("catalog.json")
            try Data("{\"version\":4,\"records\":[]}".utf8).write(to: json)
            let before = try sha256(json)
            let adopted = Adopted()
            let viewer = world.viewer(SnapshotStubRsync(source: world.masterLive), adopted: adopted)

            await viewer.refreshViewerCatalog()
            #expect(viewer.state.viewerCatalog == .legacyJSON)
            #expect(viewer.state.viewerCatalog.words == "older catalog — the master has moved to the new database; update the master")
            #expect(adopted.loads == 0)
            #expect(try sha256(json) == before)
        }
    }

    @Test("a master on an older build (catalog.json only) is refused in words; the viewer keeps its catalog.json, labelled")
    func olderMasterIsRefusedWithWords() async throws {
        try await SnapshotWorld.with("oldmaster") { world in
            // The old master: catalog.json + its phase-1 manifest, no snapshot.
            _ = try CatalogSync.computeAndWriteManifest(liveDir: world.masterLive, scope: .phase1)
            let json = world.viewerPaths.liveDir.appendingPathComponent("catalog.json")
            try Data("{\"version\":4,\"records\":[],\"frozen\":\"10/18\"}".utf8).write(to: json)
            let before = try sha256(json)
            let adopted = Adopted()
            let viewer = world.viewer(SnapshotStubRsync(source: world.masterLive), adopted: adopted)

            await viewer.syncFromMaster()
            guard case .failed(let reason) = viewer.state.phase else {
                Issue.record("expected a refused sync, got \(viewer.state.phase)"); return
            }
            #expect(reason.contains("publishes no catalog.sqlite"))
            #expect(viewer.state.refusal != nil)
            #expect(viewer.state.viewerCatalog == .legacyJSON)
            #expect(try sha256(json) == before, "the frozen catalog.json is left exactly as it was")
        }
    }
}
