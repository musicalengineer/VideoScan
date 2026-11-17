// FrameSearchProductionDoorTests.swift — the Frames mode's door as the app
// builds it (`FrameSearchLoader.make`, Observations/FrameSearch/
// FrameSearchStore.swift), on a real session: a model with catalog.sqlite
// open. Only the three parts a test must not share with Rick's data are
// named — a stub model in place of SigLIP 2, a temp index folder in place of
// Application Support, the test's own MFO center.
//
//   TRUTH      a hit names the file, path and record of THIS session's
//              catalog row for the indexed content, read through the door;
//              a content the catalog does not hold is never a hit; the read
//              commits nothing.
//   JOB        Index Frames through the door runs in the given center, over
//              the session's own files, writing under the SAME folder the
//              window reads.
//   ISOLATION  a session with no catalog open: the search says so in the
//              refusal's words, the job refuses and writes nothing; no MFO
//              center: said, nothing started.
// Fixture catalog and synthetic vectors; every folder is a temp folder.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Frames mode — the production door on a real session", .serialized) @MainActor
struct FrameSearchProductionDoorTests {

    private static let notOpen = "catalog.sqlite is not open in this session — there is nothing to read"

    /// A cutover scene with catalog.sqlite open in its model.
    private static func session(_ label: String) async throws -> (scene: CutoverScene, repository: any CatalogRepository) {
        let scene = try CutoverScene.make(label)
        try await scene.importCatalog()
        try scene.writeLatch()
        scene.model.records = scene.model.loadCatalogAtLaunch()
        return (scene, try #require(scene.model.catalogCutover.committer?.repository))
    }

    @Test func aHitIsThisSessionsCatalogRowForTheIndexedContentAndTheReadCommitsNothing() async throws {
        let (scene, repository) = try await Self.session("frames_door")
        defer { scene.cleanup() }
        let root = try ObsFixture.tempDir("frames-door")
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = await repository.generation
        let rows = try await repository.read { try $0.frameIndexFiles(.everything) }
        let target = try #require(rows.first, "the fixture catalog holds at least one content")
        var builder = FrameIndexBuilder(model: "test/stub-siglip", dims: 8)
        builder.add(digest: target.digest, frames: [(12.5, ObsStubEmbedder.axis(5))])
        builder.add(digest: ObsFixture.digest(999), frames: [(1, ObsStubEmbedder.axis(5))])   // a content this catalog does not hold
        try FrameIndexStore.save(builder.snapshot(), root: root)

        let loader = FrameSearchLoader.make(model: scene.model, embedder: ObsStubEmbedder(), root: root, center: { nil })
        #expect(loader.modelID == "test/stub-siglip")
        #expect(try await loader.files(.everything) == rows, "the door reads the session's own catalog")
        let store = FrameSearchStore(scope: .everything, loader: loader)
        await store.loadIndex()
        #expect(store.indexState == .ready(frames: 2, contents: 2), "the index folder the door was given")
        await store.search("axis 5")
        #expect(store.failure == nil && store.hits.count == 1, "a content the catalog does not hold is never a hit: \(store.failure ?? "")")
        let hit = try #require(store.hits.first)
        #expect(hit.digest == target.digest && hit.seconds == 12.5 && hit.filename == target.filename && hit.path == target.path)
        #expect(hit.recordID != nil && hit.recordID == UUID(uuidString: target.fileID), "the link is the catalog's own record")
        #expect(store.timing?.hasSuffix("over 1 frames in scope") == true)

        let stranger = FrameHit(model: "test/stub-siglip", digest: "d", seconds: 0, score: 0, recordID: UUID(), filename: "Gone.dv", path: "/V/Gone.dv", removed: false)
        #expect(store.reveal(stranger) == false && store.revealProblem == "Gone.dv is not in this session's catalog — nothing to show")
        store.buildIndex()
        #expect(store.job == nil && store.jobLine == "The Media File Operations center is not available in this window.")
        #expect(await repository.generation == generation, "READ ONLY: no commit")
    }

    @Test func indexFramesThroughTheDoorRunsInTheGivenCenterOverTheSessionsFilesAndTheWindowsFolder() async throws {
        let (scene, repository) = try await Self.session("frames_door_job")
        defer { scene.cleanup() }
        let root = try ObsFixture.tempDir("frames-door")
        defer { try? FileManager.default.removeItem(at: root) }
        let center = MediaFileOperationsCenter()
        let rows = try await repository.read { try $0.frameIndexFiles(.everything) }
        let withPicture = rows.filter { $0.hasVideo && !$0.removed }.count
        let store = FrameSearchStore(scope: .everything, loader: FrameSearchLoader.make(model: scene.model, embedder: ObsStubEmbedder(), root: root, center: { center }))
        await store.loadIndex()
        store.buildIndex()
        let job = try #require(store.job, "\(store.jobLine ?? "")")
        #expect(center.jobs.contains { $0.id == job.id } && job.root == root, "the job writes where the window reads")
        await job.task?.value
        // The fixture's files are paths that do not exist on this Mac: each is left for the next run, none is recorded.
        #expect(job.outcome == .finished && job.planned == withPicture && job.indexed == 0 && job.unreadable == 0, "\(job.state)")
        #expect(job.missing + job.offline == withPicture)
        #expect(ObsFixture.onDisk(root) == .notBuilt, "nothing was indexed, so no index was written")
        try await FrameIndexJobTests.until("the finished job leaves the window") { store.job == nil }
    }

    @Test func aSessionWithNoCatalogOpenSaysSoAndItsJobRefusesAndWritesNothing() async throws {
        let sandbox = try ShowAgainSandbox.make("frames_closed")
        defer { sandbox.cleanup() }
        let root = try ObsFixture.tempDir("frames-door")
        defer { try? FileManager.default.removeItem(at: root) }
        try FrameIndexStore.save(ObsFixture.index([2]), root: root)
        let before = ObsFixture.onDisk(root)
        let center = MediaFileOperationsCenter()
        let store = FrameSearchStore(scope: .everything, loader: FrameSearchLoader.make(model: sandbox.model, embedder: ObsStubEmbedder(), root: root, center: { center }))
        await store.loadIndex()
        #expect(store.indexState == .ready(frames: 1, contents: 1), "the index is its own folder; it is there whether or not the catalog is open")
        await store.search("axis 2")
        #expect(store.failure == Self.notOpen && store.hits.isEmpty, "\(store.failure ?? "nil")")

        store.buildIndex()
        let job = try #require(store.job)
        await job.task?.value
        #expect(job.wasRefused && job.state == .failed(message: "Refused — the catalog could not be read: \(Self.notOpen)"))
        #expect(ObsFixture.onDisk(root) == before, "a refused job leaves the index as it was")
    }

    @Test func theAppBuildsOneLoaderPerModelAndItIsSigLIP() throws {
        let sandbox = try ShowAgainSandbox.make("frames_one_loader")
        defer { sandbox.cleanup() }
        let loader = FrameSearchLoader.production(model: sandbox.model)
        #expect(FrameSearchLoader.production(model: sandbox.model).id == loader.id, "never rebuilt per window")
        #expect(loader.modelID == "google/siglip2-base-patch16-224")
    }
}
