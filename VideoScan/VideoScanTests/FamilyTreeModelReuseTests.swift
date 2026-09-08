import Testing
import Foundation
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
        let shared = FamilyTreeDemoView(sharedModel: model, preferences: suite)
        let injected = FamilyTreeDemoView(model: model, preferences: suite)
        #expect(!shared.usesInjectedModelForTesting)
        #expect(injected.usesInjectedModelForTesting)
    }
}
