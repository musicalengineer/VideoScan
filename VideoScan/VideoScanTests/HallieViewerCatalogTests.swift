// HallieViewerCatalogTests.swift
// 2026-11-04, the M4's Hallie nightly lane: 0/56 strict, 0/826 advisory —
// "hallie: catalog.sqlite would not open for reading: the database is
// read-only and its schema is not current". The M4 is a VIEWER. The app there
// shows viewer-catalog/catalog.sqlite (the master's synced copy); the Hallie
// shell opened the top-level catalog.sqlite left from the M4's master days
// (v14, never updated again). The headless readers now pick their file
// through the app's one rule (`CatalogAuthority.databaseURL(role:…)`, via
// `CatalogAuthority.headlessSource`).
//
// Fixtures: two tiny catalogs told apart by their Master Archive designation
// (catalog_state.master_archive) — the top-level "own" file and the master's
// sealed snapshot in viewer-catalog/. Nothing outside a temp folder is read.
//
// Suite (filter by SUITE): HallieViewerCatalogTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Hallie shell on a viewer reads the master's synced copy (the M4, 2026-11-04)", .serialized)
struct HallieViewerCatalogTests {

    private static let master = "RicksUltra.local"

    /// A temp `Application Support/VideoScan` with a top-level catalog.sqlite
    /// + latch (designated `own`), and — when `synced` — the master's sealed
    /// snapshot + latch in viewer-catalog/ (designated `/Volumes/MastersCurrent`).
    private struct Scene {
        let folder: URL
        var topLevel: URL { folder.appendingPathComponent(CatalogAuthority.databaseFileName) }
        var snapshot: URL { CatalogViewerSnapshot.databaseURL(in: folder) }
        func remove() { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    }

    private static func designation(_ target: String) -> String {
        "{\"targetPath\":\"\(target)\",\"rootPath\":\"\(target)/Breen_Family_Archive\",\"volumeUUID\":\"fixture\","
            + "\"designatedAt\":\"2026-08-21T00:28:35Z\"}"
    }

    /// A catalog at `url` carrying `target` as its designation; when `sealTo`
    /// is given, its sealed `VACUUM INTO` copy is written there too.
    private static func catalog(at url: URL, target: String, sealTo: URL? = nil) async throws {
        let writer = GRDBCatalogRepository(host: "hallie-viewer-test", durability: .volatileForTests)
        #expect(await writer.open(at: url) == .readWrite)
        let wrote = await writer.write(as: .ui) { try $0.setMasterArchive(json: designation(target)) }
        guard case .committed = wrote else { throw CocoaError(.fileWriteUnknown) }
        if let sealTo { #expect(writer.sealedCopyBlocking(to: sealTo) == nil) }
        await writer.close()
    }

    private static func scene(topLevel: TopLevel = .current, synced: Bool = true) async throws -> Scene {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HallieViewerCatalog-\(UUID().uuidString)", isDirectory: true)
        let scene = Scene(folder: root.appendingPathComponent("VideoScan", isDirectory: true))
        let fm = FileManager.default
        try fm.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        switch topLevel {
        case .current: try await catalog(at: scene.topLevel, target: "/Volumes/OwnTopLevel")
        case .garbage: try Data("not a database — a stale file from the M4's master days".utf8).write(to: scene.topLevel)
        }
        try Data("{}".utf8).write(to: scene.folder.appendingPathComponent(CatalogAuthority.latchFileName))
        if synced {
            let masterDir = root.appendingPathComponent("master", isDirectory: true)
            try fm.createDirectory(at: masterDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: CatalogViewerSnapshot.directory(in: scene.folder), withIntermediateDirectories: true)
            try await catalog(at: masterDir.appendingPathComponent(CatalogAuthority.databaseFileName),
                              target: "/Volumes/MastersCurrent", sealTo: scene.snapshot)
            try Data("{}".utf8).write(to: CatalogViewerSnapshot.latchURL(in: scene.folder))
        }
        return scene
    }

    private enum TopLevel { case current, garbage }

    private static func target(_ loaded: SQLiteCatalogReader.Loaded) -> String? {
        CatalogCommitter.designation(fromJSON: loaded.masterArchiveJSON)?.targetPath
    }

    private static func fingerprint(_ folder: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            out[name] = try Data(contentsOf: url)
        }
        return out
    }

    // MARK: - The regression (red on main: the viewer read the top-level file)

    @Test("RED 11/04: a viewer with a top-level catalog.sqlite AND a synced copy reads the synced copy — never its own file")
    func viewerReadsTheSyncedCopyNotItsOwnTopLevelFile() async throws {
        let scene = try await Self.scene(); defer { scene.remove() }
        let source = CatalogAuthority.headlessSource(role: .viewer, master: Self.master, folder: scene.folder)
        #expect(source == .syncedCopy(scene.snapshot, master: Self.master))
        #expect(source.databaseURL == CatalogAuthority.databaseURL(role: .viewer, opened: nil,
                                                                   catalogFile: scene.folder.appendingPathComponent("catalog.json")),
                "the headless reader and the app's display share ONE rule")
        let synced = try Self.fingerprint(CatalogViewerSnapshot.directory(in: scene.folder))

        let loaded = try #require(await HallieShellCLI.loadCatalogReadOnly(source))

        #expect(Self.target(loaded) == "/Volumes/MastersCurrent", "the shell read the wrong catalog")
        #expect(try Self.fingerprint(CatalogViewerSnapshot.directory(in: scene.folder)) == synced,
                "the read changed or added a file in the synced folder")
    }

    @Test("isolation: a viewer whose top-level catalog.sqlite is garbage (the stale v14 file) still reads the synced copy")
    func viewerIgnoresAPoisonedTopLevelFile() async throws {
        let scene = try await Self.scene(topLevel: .garbage); defer { scene.remove() }
        let before = try Data(contentsOf: scene.topLevel)
        let source = CatalogAuthority.headlessSource(role: .viewer, master: Self.master, folder: scene.folder)
        let loaded = try #require(await HallieShellCLI.loadCatalogReadOnly(source))
        #expect(Self.target(loaded) == "/Volumes/MastersCurrent")
        #expect(try Data(contentsOf: scene.topLevel) == before, "the viewer touched its own top-level file")
    }

    @Test("the master reads its own catalog.sqlite (live), as before")
    func masterReadsItsOwnFile() async throws {
        let scene = try await Self.scene(); defer { scene.remove() }
        let source = CatalogAuthority.headlessSource(role: .master, master: Self.master, folder: scene.folder)
        #expect(source == .live(scene.topLevel))
        let loaded = try #require(await HallieShellCLI.loadCatalogReadOnly(source))
        #expect(Self.target(loaded) == "/Volumes/OwnTopLevel")
    }

    @Test("a viewer with nothing synced refuses — the words name the path and 'synced copy from <master>'; the top-level file is not the fallback")
    func viewerWithNothingSyncedRefusesInWords() async throws {
        let scene = try await Self.scene(synced: false); defer { scene.remove() }
        let source = CatalogAuthority.headlessSource(role: .viewer, master: Self.master, folder: scene.folder)
        #expect(await HallieShellCLI.loadCatalogReadOnly(source) == nil, "a viewer fell back to its own top-level file")
        guard case .failure(let failure) = await SQLiteCatalogReader.load(source) else {
            Issue.record("nothing synced, yet a catalog was read")
            return
        }
        #expect(failure.words.contains("synced copy from \(Self.master)"), Comment(rawValue: failure.words))
        #expect(failure.words.contains(CatalogViewerSnapshot.directory(in: scene.folder).path), Comment(rawValue: failure.words))
    }

    @Test("--catalog: a path in a synced viewer-catalog/ folder opens sealed; any other path is read as given")
    func explicitCatalogPaths() throws {
        let synced = URL(fileURLWithPath: "/x/VideoScan/viewer-catalog/catalog.sqlite")
        guard case .syncedCopy(let url, _) = CatalogAuthority.explicitSource(synced) else {
            Issue.record("a viewer-catalog path would be opened live (an empty -wal could appear in the synced folder)")
            return
        }
        #expect(url == synced)
        let other = URL(fileURLWithPath: "/tmp/backup/catalog.sqlite")
        #expect(CatalogAuthority.explicitSource(other) == .live(other))
        let options = try HallieShellCLI.parse(arguments: ["--hallie", "--catalog", other.path])
        #expect(options.catalog == .live(other))
        #expect(try FindTagCLI.parse(["--find-tag", "--catalog", synced.path]).catalogURL == synced)
        #expect(HallieShellCLI.catalogWords(.syncedCopy(synced, master: "RicksUltra.local"))
                == "\(synced.path) — this Mac is a viewer; the synced copy from RicksUltra.local")
        #expect(HallieShellCLI.catalogWords(.live(other)) == other.path)
    }
}
