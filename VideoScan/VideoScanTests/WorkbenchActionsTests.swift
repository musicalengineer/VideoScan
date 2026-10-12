import Testing
import Foundation
@testable import VideoScan

// MARK: - WorkbenchActionsTests
//
// Locks down VideoScanModel's Workbench helpers:
//   - promoteWorkbenchToArchive  → lifecycleStage = .archived + archiveStage starts at .healthy
//   - dropWorkbenchToCatalog     → lifecycleStage = .cataloged (no archive metadata change)
//   - discardWorkbench           → purgedAt set, lifecycleStage = .trashed (only for a file
//                                  the Trash took, or one already gone — see
//                                  WorkbenchDiscardTrashFailureTests for failed / offline)
//
// All three must persist synchronously. The persistence half is critical
// — three workbench mutations across an overnight Combine batch that
// silently fail to save would lose every triage decision the user made.
// Same family of bug as the ArchiveView one we fixed in 41319e6.
//
// Step 2C of [[project_archive_combine_pipeline_order]].

@MainActor
struct WorkbenchActionsTests {

    private func scratchDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoscan_workbench_\(UUID().uuidString)",
                                    isDirectory: true)
    }

    private func makeModel(at dir: URL) throws -> VideoScanModel {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        return model
    }

    private func makeWorkbenchRecord(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/Workbench/\(name)"
        r.lifecycleStage = .workbench
        return r
    }

    /// A Workbench record whose file lives in `dir` (a connected drive);
    /// `create` = put a real file there.
    private func makeDiscardableRecord(_ name: String, in dir: URL, create: Bool = true) -> VideoRecord {
        let url = dir.appendingPathComponent(name)
        if create { FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3])) }
        let r = makeWorkbenchRecord(name)
        r.fullPath = url.path
        r.directory = dir.path
        return r
    }

    // MARK: - Promote

    //
    // Tab-charter audit T2 (2026-10-11): Promote used to stamp
    // `lifecycleStage = .archived` (+ archiveStage .healthy) and copy
    // nothing. It is now the Catalog's Promote — `requestPromote` → the
    // confirmation sheet → PromoteToArchiveJob. These pin the hand-off and
    // that nothing is stamped before a verified copy exists.

    @Test
    func promoteWithoutAMasterArchiveRaisesTheEnginesAlertAndStampsNothing() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModel(at: dir)
        let recs = ["a.mov", "b.mov", "c.mov"].map { makeWorkbenchRecord($0) }
        recs[2].archiveStage = .backedUp
        model.records = recs

        model.promoteWorkbenchToArchive(recs)
        #expect(model.pendingPromoteWithoutMaster?.recordIDs == recs.map(\.id),
                "the Promote engine's 'designate a master archive' alert, for every selected file")
        #expect(model.pendingPromoteRequest == nil)
        #expect(recs.allSatisfy { $0.lifecycleStage == .workbench }, "no label-only promote")
        #expect(recs.map(\.archiveStage) == [ArchiveStage.none, .none, .backedUp], "archive stage untouched")
    }

    @Test
    func promoteWithAMasterArchiveOffersTheEnginesPlanAndStampsNothingYet() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("workbench_promote")
        defer { sb.cleanup() }
        let model = VideoScanModel()
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("combined.mov"),
                                                         bytes: 1000, seed: 7)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)
        rec.lifecycleStage = .workbench
        model.records = [rec]
        try MasterArchiveTestSupport.initialize(model, in: sb)

        model.promoteWorkbenchToArchive([rec])
        let plan = try #require(model.pendingPromoteRequest?.plan, "the confirmation sheet's plan")
        #expect(plan.entries.map(\.recordID) == [rec.id])
        #expect(rec.lifecycleStage == .workbench, "the stage changes only on the verified archive copy")
        #expect(!model.isArchived(rec))
    }

    @Test
    func promoteOnAReadOnlyViewerDoesNothing() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModel(at: dir)
        model.isReadOnly = true
        // On a mounted volume and missing — the looks-moved check would
        // raise a relink notice; a viewer is refused BEFORE it (QA m6).
        let rec = makeDiscardableRecord("x.mov", in: dir, create: false)
        model.records = [rec]

        model.promoteWorkbenchToArchive([rec])
        #expect(model.pendingPromoteRequest == nil && model.pendingPromoteWithoutMaster == nil)
        #expect(model.looksMovedNotice == nil, "no relink offer on a viewer")
        #expect(rec.lifecycleStage == .workbench)
    }

    // MARK: - Drop

    @Test
    func dropSetsLifecycleToCatalogedAndPersists() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModel(at: dir)
        let rec = makeWorkbenchRecord("x.mov")
        model.records = [rec]

        model.dropWorkbenchToCatalog([rec])
        #expect(rec.lifecycleStage == .cataloged)
        #expect(rec.archiveStage == .none,
                "drop must not touch archiveStage — record is just ordinary media now")

        let reloaded = CatalogStore(directory: dir).load().first!
        #expect(reloaded.lifecycleStage == .cataloged)
    }

    // MARK: - Discard

    @Test
    func discardSetsPurgedAtAndTrashedLifecycle() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModel(at: dir)
        // A real file on a connected drive (the scratch dir). Before B1
        // (2026-10-11) this test used /Volumes/Workbench/… — an unmounted
        // path whose Trash call THREW — and passed only because a failed
        // Trash still stamped the record. The Trash itself is a seam here.
        let rec = makeDiscardableRecord("test_artifact.mov", in: dir)
        model.records = [rec]
        let trashed = TrashCallLog()

        let revisionBefore = model.volumeAggregatesRevision
        let n = await model.discardWorkbench([rec], trash: trashed.operation)
        #expect(n == 1)
        #expect(trashed.names == ["test_artifact.mov"])
        #expect(model.volumeAggregatesRevision > revisionBefore,
                "in-place purge must announce itself so cached table/aggregates recompute (#160)")
        #expect(rec.purgedAt != nil, "purgedAt must be stamped so soft-delete takes effect")
        #expect(rec.lifecycleStage == .trashed)

        let reloaded = CatalogStore(directory: dir).load().first!
        #expect(reloaded.purgedAt != nil)
        #expect(reloaded.lifecycleStage == .trashed)
    }

    @Test
    func discardEmptyArrayIsNoOp() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModel(at: dir)
        model.records = []
        let n = await model.discardWorkbench([])
        #expect(n == 0)
        // No catalog should have been written.
        let reloaded = CatalogStore(directory: dir).load()
        #expect(reloaded.isEmpty)
    }

    @Test
    func discardGracefullyHandlesMissingFile() async throws {
        // The file at fullPath doesn't exist in the test fixture, but
        // discardWorkbench must still purge the record — leaving an
        // un-purgeable row would let bad records accumulate forever.
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModel(at: dir)
        // Missing on a CONNECTED drive (the scratch dir). A file on an
        // unplugged /Volumes/… drive is "offline" and keeps its record.
        let rec = makeDiscardableRecord("ghost.mov", in: dir, create: false)
        model.records = [rec]
        let trashCalls = TrashCallLog()

        let n = await model.discardWorkbench([rec], trash: trashCalls.operation)
        #expect(n == 1)
        #expect(trashCalls.count == 0, "nothing to Trash — the file is already gone")
        #expect(rec.purgedAt != nil)
    }
}
