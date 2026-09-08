import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

// MARK: - FamilyTreeModelReuseTests
//
// Rick, 2026-09-08: switching People → Family Tree flashed the demo tree
// for 3-4 s on every switch, because the tab's `switch` rebuilt the view
// AND its model, and the fresh model reloaded from scratch. ContentView
// now owns one FamilyTreeLiveModel for the life of the window ("cache
// it — you have plenty of RAM"), and the tab asks `needsLoad(for:)`
// before touching disk. These pin that contract.
//
// Isolation: every case uses the compiled-store Sandbox (its own
// originals + store directories); nothing here reads production files.

struct FamilyTreeModelReuseTests {

    private typealias Sandbox = FamilyGraphCompiledStoreTests.Sandbox
    private static let tree = FamilyGraphCompiledStoreTests.tree
    private static let settings = FamilyTreeLaunchBundle.Settings(speakers: .none, ownerFamilySearchID: nil)

    @Test @MainActor func warmAppearanceRefreshesNotesWrittenElsewhere() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write("0 HEAD\n0 @I1@ INDI\n1 NAME Eileen /Latta/\n0 TRLR\n")
        let brain = box.root.appendingPathComponent("brain")
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals, cyberBrainRootURL: brain)
        await model.prepareForAppearance(revision: "a", settings: Self.settings)
        model.select("@I1@")
        #expect(model.selectedNotes.isEmpty)
        _ = try CyberBrainWriter.record(CyberBrainWriter.Testimony(
            subjectName: "Eileen Latta", subjectAliases: [], speakerName: "Rick",
            text: "She declined the CIA offer.", date: Date()), rootURL: brain)
        await model.prepareForAppearance(revision: "a", settings: Self.settings)
        #expect(model.diskLoadAttempts == 1)
        #expect(model.selectedNotes.map(\.text) == ["She declined the CIA offer."])
    }

    @Test @MainActor func productionAppearancePathKeepsWarmTreeAndSelection() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.tree)
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals, compiledStore: box.store())
        await model.prepareForAppearance(revision: "a", settings: Self.settings)
        let selected = try #require(model.selectedID)
        let attempts = model.diskLoadAttempts
        await model.prepareForAppearance(revision: "a", settings: Self.settings)
        #expect(model.diskLoadAttempts == attempts)
        #expect(model.selectedID == selected)
        #expect(model.peopleCount == 400)

        // Explicit reload installs a changed generation; returning to the tab
        // must retain that generation, not resurrect the original cached tree.
        let replacement = GedcomSyntheticPedigree.gedcom(people: 450, generations: 8)
        _ = try box.write(replacement, as: "family-2.ged", mtime: Date().addingTimeInterval(60))
        await model.loadFromDisk(settings: Self.settings)
        #expect(model.peopleCount == 450)
        let reloaded = model.diskLoadAttempts
        await model.prepareForAppearance(revision: "a", settings: Self.settings)
        #expect(model.diskLoadAttempts == reloaded)
        #expect(model.peopleCount == 450)
    }

    @Test @MainActor func ownerPinChangeRebuildsAnchorsOnAppearance() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.tree)
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals, compiledStore: box.store())
        await model.prepareForAppearance(revision: "a", settings: Self.settings)
        let changed = FamilyTreeLaunchBundle.Settings(speakers: .none, ownerFamilySearchID: "MISSING-PIN")
        await model.prepareForAppearance(revision: "a", settings: changed)
        #expect(model.diskLoadAttempts == 2)
        #expect(model.anchors.isEmpty)
        #expect(model.anchorsCaption != nil)
        await model.prepareForAppearance(revision: "a", settings: changed)
        #expect(model.diskLoadAttempts == 2)
    }

    @Test @MainActor func bookmarkStoresFollowArchiveButExplicitStoresStayIsolated() async throws {
        let a = try Sandbox(), b = try Sandbox()
        defer { a.tearDown(); b.tearDown() }
        _ = try a.write(Self.tree); _ = try b.write(Self.tree)
        var first = FamilyTreeBookmarks(), second = FamilyTreeBookmarks()
        first.toggle("a-only"); second.toggle("b-only")
        try first.save(to: a.originals); try second.save(to: b.originals)
        func source(_ box: Sandbox, access: FamilyAssetStore.Access = .readWrite) -> FamilyAssetConfiguration {
            FamilyAssetConfiguration(
                roots: FamilyAssetStore.Roots(assets: box.root.appendingPathComponent("assets"),
                                              thumbnailCache: box.root.appendingPathComponent("cache")),
                access: access, legacyGEDCOMDirectory: box.originals)
        }
        let model = FamilyTreeLiveModel(originalsDirectory: a.originals,
                                        bookmarksDirectory: a.originals, bookmarksFollowSource: true)
        await model.prepareForAppearance(revision: "a", source: source(a), settings: Self.settings)
        model.configure(source: source(b))
        model.toggleBookmark("old-tree-pointer")
        #expect(!FamilyTreeBookmarks.load(from: b.originals).contains("old-tree-pointer"))
        await model.prepareForAppearance(revision: "b", source: source(b), settings: Self.settings)
        #expect(model.bookmarks.ids == ["b-only"])
        model.toggleBookmark("new-b")
        #expect(FamilyTreeBookmarks.load(from: a.originals).ids == first.ids)
        #expect(FamilyTreeBookmarks.load(from: b.originals).contains("new-b"))
        model.configure(source: source(b, access: .readOnly))
        model.toggleBookmark("memory-only")
        #expect(!FamilyTreeBookmarks.load(from: b.originals).contains("memory-only"))

        let isolated = FamilyTreeLiveModel(originalsDirectory: a.originals, bookmarksDirectory: a.originals)
        isolated.configure(source: source(b))
        #expect(isolated.bookmarks.ids == first.ids)
        await model.prepareForAppearance(revision: "offline", source: source(b, access: .unavailable), settings: Self.settings)
        #expect(model.loadState == .unavailable)
        #expect(model.bookmarks.ids.isEmpty)
        await model.prepareForAppearance(revision: "b", source: source(b), settings: Self.settings)
        #expect(model.isLive)
        #expect(model.bookmarks.contains("new-b"))
    }

    @Test @MainActor func warmReturnAtArchiveScaleDoesNotEnterLoader() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(GedcomSyntheticPedigree.gedcom(people: 100_000, generations: 17))
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals, compiledStore: box.store())
        await model.prepareForAppearance(revision: "large", settings: Self.settings)
        #expect(model.peopleCount == 100_000)
        let attempts = model.diskLoadAttempts
        let clock = ContinuousClock(), start = clock.now
        for _ in 0..<10 {
            await model.prepareForAppearance(revision: "large", settings: Self.settings)
        }
        #expect(model.diskLoadAttempts == attempts)
        #expect(clock.now - start < .seconds(2))
    }

    /// A model that has never loaded must load, whatever the revision.
    @Test @MainActor func freshModelNeedsALoad() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals)
        #expect(model.needsLoad(for: "a|online|identity-ok|readwrite"))
        #expect(model.loadedRevision == nil)
    }

    /// The whole point: once loaded and marked for a revision, re-appearing
    /// with the SAME revision is a no-op, so the tab keeps its tree.
    @Test @MainActor func loadedModelWithSameRevisionSkipsTheReload() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.tree)
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals, compiledStore: box.store())
        let revision = "root|online|identity-ok|readwrite"

        await model.loadFromDisk()
        model.markLoaded(revision: revision)

        #expect(model.loadState == .loaded(live: true))
        #expect(model.isLive)
        #expect(!model.needsLoad(for: revision), "same revision, live graph: keep it")
        #expect(model.peopleCount == 400, "and the tree is still there to keep")
    }

    /// A changed source (archive went offline, root moved, read-only flip)
    /// must reload — that is what the revision string encodes.
    @Test @MainActor func changedRevisionForcesAReload() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.tree)
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals, compiledStore: box.store())
        await model.loadFromDisk()
        model.markLoaded(revision: "root|online|identity-ok|readwrite")

        #expect(model.needsLoad(for: "root|offline|identity-ok|readwrite"))
        #expect(model.needsLoad(for: "other|online|identity-ok|readwrite"))
        #expect(model.needsLoad(for: "root|online|identity-ok|readonly"))
    }

    /// Marked but never actually live (the load found no GEDCOM) must
    /// still try again next time the tab appears — a stale "loaded" mark
    /// must not hide an empty tree forever.
    @Test @MainActor func markWithoutALiveGraphStillNeedsALoad() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals)
        model.markLoaded(revision: "r")
        #expect(!model.isLive)
        #expect(model.needsLoad(for: "r"))
    }

    /// The production initialiser pair: `init(sharedModel:)` must NOT be
    /// the test seam. It still configures from the production source, so
    /// a shared model reloads when the revision changes. Pinned by the
    /// view's `usesInjectedModel` flag being false for the shared path.
    @Test @MainActor func sharedModelInitIsNotTheInjectedSeam() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals)
        let suite = UserDefaults(suiteName: "FamilyTreeModelReuseTests.\(UUID().uuidString)")!
        let shared = FamilyTreeView(sharedModel: model, preferences: suite)
        let injected = FamilyTreeView(model: model, preferences: suite)
        #expect(!shared.usesInjectedModelForTesting)
        #expect(injected.usesInjectedModelForTesting)
    }
}
