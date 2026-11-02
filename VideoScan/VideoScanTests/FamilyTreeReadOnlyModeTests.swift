// FamilyTreeReadOnlyModeTests.swift
// DECISIONS 2026-11-01 — "The Family Tree opens read-only when the Master
// Archive is absent". The tab shows the compiled graph with every writer
// disabled when the archive is offline / has the wrong UUID, or this Mac is
// a CatalogSync viewer; nothing is written anywhere in that state.
//
// Dimensions (CLAUDE.md rule 8 + truth):
//   Logic     — access × role → mode (pure), and access × role × compiled
//               graph (present / missing / corrupt) → shown read-only /
//               full / refused, on the real model.
//   Isolation — archive absent (unplugged), archive with the wrong UUID, and
//               a viewer: a fixture folder (archive + App Support) is
//               byte-identical after the load and every action a test can
//               drive; each attempted write refuses in words and logs ONE
//               line; the asset store is never asked for.
//   Truth     — the banner text, the disabled writers and the "no photo"
//               cards are asserted from MODEL state, not the view.
//   Transition— the archive coming back re-enables every writer without a
//               relaunch (configure → load), and a bookmark then saves.
//   Scale     — FamilyTreeReadOnlyScaleTests (39,250 people, prewarm budget).
//   Sensor    — FamilyTreeReadOnlyWriteSiteSensorTests (every write site).
//
// Every fixture lives under one temp root; nothing here reads production
// files. Viewer mode is played with an INJECTED ViewerModeCenter, never the
// process-wide one.

import Testing
import Foundation
import CryptoKit
import VideoScanCore
@testable import VideoScan

/// Thread-safe line capture.
final class ReadOnlyLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var all: [String] { lock.withLock { stored } }
}

/// The world a read-only test runs in: a Master Archive folder with the
/// GEDCOM, and an App Support folder with the compiled tree, the CyberBrain,
/// the overlay, decorations and Person of the Day — every place a write
/// could land. `snapshot()` is the byte-identity witness.
struct ReadOnlyFixture {
    let root: URL
    let archive: URL            // <root>/Volumes/MasterArchive
    let unplugged: URL          // where the archive goes when "unmounted"
    let support: URL            // <root>/AppSupport/VideoScan
    var familyTree: URL { support.appendingPathComponent("family-tree", isDirectory: true) }
    var compiled: URL { familyTree.appendingPathComponent("compiled", isDirectory: true) }
    var brain: URL { support.appendingPathComponent("cyberbrain", isDirectory: true) }
    var overlayDirectory: URL { familyTree.appendingPathComponent("person-refresh", isDirectory: true) }
    var decorations: URL { familyTree.appendingPathComponent(TreeWalkStore.fileName) }
    var personOfTheDay: URL { familyTree.appendingPathComponent("person-of-the-day.json") }
    var portraitDirectory: URL { support.appendingPathComponent("portrait", isDirectory: true) }
    var assetsRoot: URL { archive.appendingPathComponent("40_Family_Tree", isDirectory: true) }
    var gedcomDirectory: URL { assetsRoot.appendingPathComponent("GEDCOM", isDirectory: true) }
    let rootPersonID = "@I0_0@"
    let people: Int
    let storeLog = ReadOnlyLines()

    static func gedcom(people: Int, generations: Int) -> String {
        GedcomSyntheticPedigree.gedcom(people: people, generations: generations)
            .replacingOccurrences(of: "1 SOUR VideoScanSynthetic",
                                  with: "1 SOUR VideoScanSynthetic\n1 _VS_ROOT @I0_0@")
    }

    init(people: Int = 120, generations: Int = 6) throws {
        self.people = people
        root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("FT-ReadOnly-\(UUID().uuidString)", isDirectory: true)
        archive = root.appendingPathComponent("Volumes/MasterArchive", isDirectory: true)
        unplugged = root.appendingPathComponent("Unplugged/MasterArchive", isDirectory: true)
        support = root.appendingPathComponent("AppSupport/VideoScan", isDirectory: true)
        let fm = FileManager.default
        for dir in [gedcomDirectory, compiled, brain, overlayDirectory, portraitDirectory,
                    unplugged.deletingLastPathComponent()] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Self.gedcom(people: people, generations: generations)
            .write(to: gedcomDirectory.appendingPathComponent("family.ged"), atomically: true, encoding: .utf8)
        // Compile once, on the "master", exactly as the app would.
        var loader = FamilyGraphFileLoader(originalsDirectory: gedcomDirectory)
        loader.compiledStore = store()
        loader.readOnly = false
        let outcome = loader.loadNewestOutcome()
        guard outcome.compiled, outcome.graph?.people.count == people else {
            throw FixtureError("the fixture tree did not compile")
        }
        // Things a writer could overwrite, present before the test starts.
        var marks = FamilyTreeBookmarks()
        _ = marks.toggle(rootPersonID)
        try marks.save(to: gedcomDirectory)
        try Data("{\"history\":\"seeded\"}".utf8).write(to: personOfTheDay)
    }

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    func store() -> FamilyGraphCompiledStore {
        var store = FamilyGraphCompiledStore(root: compiled)
        let log = storeLog
        store.log = { log.append($0) }
        return store
    }

    var overlayStore: PersonFactOverlayStore { PersonFactOverlayStore(directory: overlayDirectory) }

    /// What the catalog model would publish: the archive's roots, with the
    /// given authority. `assets` defaults to the archive's 40_Family_Tree.
    func configuration(access: FamilyAssetStore.Access, assets: URL? = nil) -> FamilyAssetConfiguration {
        FamilyAssetConfiguration(
            roots: FamilyAssetStore.Roots(assets: assets ?? assetsRoot,
                                          thumbnailCache: familyTree.appendingPathComponent("thumbs")),
            access: access, legacyGEDCOMDirectory: nil)
    }

    /// The viewer's roots (VideoScanModel+FamilyAssets: no archive root, so
    /// assets fall back to App Support/family-tree/assets), read-only.
    var viewerConfiguration: FamilyAssetConfiguration {
        configuration(access: .readOnly, assets: familyTree.appendingPathComponent("assets"))
    }

    /// Unmount: the archive's folder is moved out of its mount point.
    func unplug() throws { try FileManager.default.moveItem(at: archive, to: unplugged) }
    func plugBackIn() throws { try FileManager.default.moveItem(at: unplugged, to: archive) }

    /// One note about the root person, written on the "master" before the
    /// test starts, so the correction verbs have a row to act on.
    @MainActor func seedNote() throws {
        let graph = try #require(store().loadCurrent()?.graph)
        let seed = FamilyTreeLiveModel(originalsDirectory: gedcomDirectory, cyberBrainRootURL: brain,
                                       noteAuthor: "Rick", pronunciationFallback: { .shipped })
        seed.install(graph: graph)
        seed.loadCyberBrainNow()
        try seed.addNote("Farmed in Huntingdon County.", about: rootPersonID)
    }

    /// Every regular file under `root` (relative path → size, mtime,
    /// SHA-256) and every directory. Equal snapshots = byte-identical tree.
    func snapshot() throws -> [String: String] {
        var out: [String: String] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw FixtureError("cannot walk the fixture")
        }
        let base = root.path.count
        for case let url as URL in walker {
            let v = try url.resourceValues(forKeys: Set(keys))
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(base))
            if v.isDirectory == true {
                out[rel + "/"] = "dir"
            } else {
                let data = try Data(contentsOf: url)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let mtime = v.contentModificationDate?.timeIntervalSince1970 ?? 0
                out[rel] = "\(v.fileSize ?? -1)|\(mtime)|\(digest)"
            }
        }
        return out
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }
}

private let settings = FamilyTreeLaunchBundle.Settings(speakers: .none, ownerFamilySearchID: nil)

/// A model wired to the fixture: injected compiled store, CyberBrain,
/// overlay and a document store provider that COUNTS (the truth test says
/// the asset store is never asked for in the read-only state).
@MainActor
final class ReadOnlyHarness {
    let model: FamilyTreeLiveModel
    let refusals = ReadOnlyLines()
    let viewer: ViewerModeCenter
    private(set) var storeRequests = 0

    init(_ fx: ReadOnlyFixture, configuration: FamilyAssetConfiguration, asViewer: Bool) {
        viewer = ViewerModeCenter()
        let refusals = self.refusals
        viewer.reset(sink: { refusals.append($0) })
        if asViewer { viewer.install(.viewer(masterHostname: "RicksM4.local")) }
        var counter: (() -> Void)?
        model = FamilyTreeLiveModel(
            originalsDirectory: configuration.gedcomDirectory(), compiledStore: fx.store(),
            cyberBrainRootURL: fx.brain, noteAuthor: "Rick",
            pronunciationFallback: { .shipped },
            bookmarksFollowSource: true,
            documentStoreProvider: { counter?(); return configuration.makeStore() })
        model.viewerCenter = viewer
        model.personRefreshOverlayStore = fx.overlayStore
        model.writeRefusalLog = { refusals.append($0) }
        counter = { [weak self] in self?.storeRequests += 1 }
    }

    func appear(_ configuration: FamilyAssetConfiguration, revision: String = "ro") async {
        await model.prepareForAppearance(revision: revision, source: configuration, settings: settings)
    }
}

// MARK: - Logic: the matrix

@Suite("Family Tree read-only — logic (access × role)")
struct FamilyTreeReadOnlyMatrixTests {

    @Test func accessTimesRoleResolvesToTheRuledMode() {
        let cases: [(FamilyAssetStore.Access, Bool, FamilyTreeAccessMode)] = [
            (.readWrite, false, .full),
            (.readOnly, false, .full),        // session read-only: as before (the store refuses its own writes)
            (.unavailable, false, .readOnly(.archiveUnavailable)),
            (.readWrite, true, .readOnly(.viewer)),
            (.readOnly, true, .readOnly(.viewer)),
            (.unavailable, true, .readOnly(.viewer)),
        ]
        for (access, viewer, expected) in cases {
            #expect(FamilyTreeAccessMode.resolve(access: access, isViewer: viewer) == expected,
                    "\(access) × \(viewer ? "viewer" : "master")")
        }
        #expect(FamilyTreeAccessMode.full.allowsWrites)
        #expect(!FamilyTreeAccessMode.readOnly(.viewer).allowsWrites)
        #expect(!FamilyTreeAccessMode.readOnly(.archiveUnavailable).allowsWrites)
    }

    /// The viewer role is read where CatalogSync installs it: the center.
    @Test func theProcessWideModeReadsTheViewerCenterAndThePublishedAccess() {
        let center = ViewerModeCenter()
        #expect(FamilyTreeAccessMode.current(viewer: center) == .full,
                "test host default: no archive designated, not a viewer")
        center.install(.viewer(masterHostname: "RicksM4.local"))
        #expect(FamilyTreeAccessMode.current(viewer: center) == .readOnly(.viewer))
    }

    enum Graph: CaseIterable { case present, missing, corrupt }
    enum Expect: Equatable { case full, readOnly, refused }

    /// access × role × compiled graph → what the tab shows. The only
    /// refusal left is a read-only state with no readable compiled graph.
    @Test(arguments: [FamilyAssetStore.Access.readWrite, .readOnly, .unavailable], [false, true])
    @MainActor func modelShowsReadOnlyFullOrRefused(access: FamilyAssetStore.Access, viewer: Bool) async throws {
        for graph in Graph.allCases {
            let fx = try ReadOnlyFixture(people: 40, generations: 4); defer { fx.tearDown() }
            switch graph {
            case .present: break
            case .missing:
                try FileManager.default.moveItem(at: fx.compiled,
                                                 to: fx.root.appendingPathComponent("compiled-gone"))
            case .corrupt:
                let pointer = try #require(fx.store().readPointer())
                try Data("not a tree".utf8).write(to: fx.store().artifactURL(pointer.current))
            }
            let configuration = viewer ? fx.viewerConfiguration : fx.configuration(access: access)
            let h = ReadOnlyHarness(fx, configuration: configuration, asViewer: viewer)
            await h.appear(configuration)
            let mode = FamilyTreeAccessMode.resolve(access: configuration.access, isViewer: viewer)
            #expect(h.model.accessMode == mode)
            // A read-only state never parses a .ged: no readable compiled
            // tree → refused. Full mode parses as it always has.
            let expected: Expect = mode == .full ? .full : (graph == .present ? .readOnly : .refused)
            let label = "\(access) × \(viewer ? "viewer" : "master") × \(graph)"
            switch expected {
            case .full:
                // Full mode parses the archive's .ged when the compiled tree
                // is missing or corrupt: exactly today's behaviour.
                #expect(h.model.loadState == .loaded(live: true), "\(label)")
                #expect(h.model.readOnlyBanner == nil, "\(label)")
                #expect(h.model.disabledWriters.isEmpty, "\(label)")
            case .readOnly:
                #expect(h.model.loadState == .loaded(live: true), "\(label)")
                #expect(h.model.peopleCount == 40, "\(label)")
                #expect(h.model.readOnlyBanner == FamilyTreeWriteGate.bannerText, "\(label)")
            case .refused:
                if mode == .readOnly(.archiveUnavailable) {
                    #expect(h.model.loadState == .unavailable, "\(label)")
                    #expect(h.model.unavailableReason?.contains("Connect the Master Archive") == true, "\(label)")
                    #expect(h.model.readOnlyBanner == nil, "the refusal banner speaks instead — \(label)")
                } else {
                    // Viewer with no compiled tree: no live tree (today's
                    // viewer behaviour — the demo / sync-again banners).
                    #expect(!h.model.isLive, "\(label)")
                }
            }
        }
    }
}

// MARK: - Truth: model state says what the view shows

@Suite("Family Tree read-only — truth (banner, writers, no photos)")
@MainActor
struct FamilyTreeReadOnlyTruthTests {

    @Test func theBannerTheDisabledWritersAndTheCardsComeFromTheModel() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        try fx.unplug()
        let configuration = fx.configuration(access: .unavailable)
        let h = ReadOnlyHarness(fx, configuration: configuration, asViewer: false)
        await h.appear(configuration)

        #expect(h.model.accessMode == .readOnly(.archiveUnavailable))
        #expect(h.model.readOnlyBanner == "Photos and documents are unavailable until the Master Archive is connected")
        #expect(h.model.disabledWriters == Set(FamilyTreeWriter.allCases))
        for writer in FamilyTreeWriter.allCases { #expect(!h.model.isEnabled(writer), "\(writer)") }
        #expect(h.model.peopleCount == fx.people)
        #expect(!h.model.filteredPeople.isEmpty, "the sidebar lists the read-only tree")
        #expect(!h.model.scene.cards.isEmpty)
        #expect(h.model.scene.cards.allSatisfy { $0.photo == nil && $0.assetPerson == nil },
                "every card is a 'no photo' placeholder that never reaches the asset store")
        #expect(h.model.selectedDocuments.isEmpty)
        #expect(h.storeRequests == 0, "the asset store was asked for \(h.storeRequests) time(s)")
        #expect(h.model.needsRecompile.isEmpty, "no Recompile offer in read-only")
        #expect(h.model.bookmarks.ids.isEmpty, "bookmarks live on the archive; none are read from it")
    }

    @Test func aViewerShowsTheSameBannerAndDisablesTheSameWriters() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let h = ReadOnlyHarness(fx, configuration: fx.viewerConfiguration, asViewer: true)
        await h.appear(fx.viewerConfiguration)
        #expect(h.model.accessMode == .readOnly(.viewer))
        #expect(h.model.readOnlyBanner == FamilyTreeWriteGate.bannerText)
        #expect(h.model.disabledWriters == Set(FamilyTreeWriter.allCases))
        #expect(h.model.isLive)
        #expect(h.model.scene.cards.allSatisfy { $0.photo == nil && $0.assetPerson == nil })
        #expect(h.storeRequests == 0)
    }

    @Test func refusalWordsNameTheWriterAndTheReason() {
        let archive = FamilyTreeWriteGate.refusalText(.bookmark, mode: .readOnly(.archiveUnavailable))
        #expect(archive == "Bookmarking is unavailable until the Master Archive is connected.")
        let center = ViewerModeCenter()
        center.install(.viewer(masterHostname: "RicksM4.local"))
        #expect(FamilyTreeWriteGate.refusalText(.note, mode: .readOnly(.viewer), viewerCenter: center)
                == "Writing notes happens on the master (RicksM4).")
        #expect(FamilyTreeWriteGate.refusalText(.note, mode: .full) == nil)
    }
}

// MARK: - Transition: the archive comes back

@Suite("Family Tree read-only — archive-back transition")
@MainActor
struct FamilyTreeReadOnlyTransitionTests {

    @Test func connectingTheArchiveReEnablesEveryWriterWithoutARelaunch() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        try fx.unplug()
        let offline = fx.configuration(access: .unavailable)
        let h = ReadOnlyHarness(fx, configuration: offline, asViewer: false)
        await h.appear(offline, revision: "offline")
        #expect(h.model.accessMode.isReadOnly)
        #expect(!h.model.toggleBookmark(fx.rootPersonID), "refused while offline")

        // The archive is mounted again with the right UUID: the catalog
        // model republishes, the tab's revision changes, it re-appears.
        try fx.plugBackIn()
        let online = fx.configuration(access: .readWrite)
        await h.appear(online, revision: "online")
        #expect(h.model.accessMode == .full)
        #expect(h.model.readOnlyBanner == nil)
        #expect(h.model.disabledWriters.isEmpty)
        #expect(h.model.isLive)
        #expect(h.model.bookmarks.contains(fx.rootPersonID), "the archive's bookmarks are read again")
        #expect(h.model.scene.cards.contains { $0.assetPerson != nil }, "cards reach the asset store again")
        // A writer works again, on the archive.
        let other = try #require(h.model.filteredPeople.first { $0.id != fx.rootPersonID }?.id)
        #expect(h.model.toggleBookmark(other))
        #expect(FamilyTreeBookmarks.load(from: fx.gedcomDirectory).contains(other))

        // And back offline: read-only again, on the next appearance.
        try fx.unplug()
        await h.appear(offline, revision: "offline-2")
        #expect(h.model.accessMode == .readOnly(.archiveUnavailable))
        #expect(h.model.isLive)
        #expect(!h.model.isEnabled(.bookmark))
    }
}
