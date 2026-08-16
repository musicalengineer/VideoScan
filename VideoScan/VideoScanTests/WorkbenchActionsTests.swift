import Testing
import Foundation
@testable import VideoScan

// MARK: - WorkbenchActionsTests
//
// Locks down VideoScanModel's Workbench helpers:
//   - promoteWorkbenchToArchive  → lifecycleStage = .archived + archiveStage starts at .healthy
//   - dropWorkbenchToCatalog     → lifecycleStage = .cataloged (no archive metadata change)
//   - discardWorkbench           → purgedAt set, lifecycleStage = .trashed
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

    // MARK: - Promote

    @Test
    func promoteSetsArchivedLifecycleAndStartsArchiveStageAtHealthy() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModel(at: dir)
        let rec = makeWorkbenchRecord("donna_rock_combined.mov")
        #expect(rec.archiveStage == .none)
        model.records = [rec]

        model.promoteWorkbenchToArchive([rec])
        #expect(rec.lifecycleStage == .archived)
        #expect(rec.archiveStage == .healthy,
                "promote from .none must start the archive lifecycle at .healthy — not skip straight to fully-archived")

        // Persisted?
        let reloaded = CatalogStore(directory: dir).load().first!
        #expect(reloaded.lifecycleStage == .archived)
        #expect(reloaded.archiveStage == .healthy)
    }

    @Test
    func promoteDoesNotDowngradeAlreadyAdvancedArchiveStage() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModel(at: dir)
        let rec = makeWorkbenchRecord("x.mov")
        rec.archiveStage = .backedUp  // already past healthy
        model.records = [rec]

        model.promoteWorkbenchToArchive([rec])
        #expect(rec.archiveStage == .backedUp,
                "promote must not clobber an already-advanced archiveStage")
    }

    @Test
    func promoteAppliesToAllRecords() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModel(at: dir)
        let recs = ["a.mov", "b.mov", "c.mov"].map { makeWorkbenchRecord($0) }
        model.records = recs

        model.promoteWorkbenchToArchive(recs)
        #expect(recs.allSatisfy { $0.lifecycleStage == .archived })
        #expect(recs.allSatisfy { $0.archiveStage == .healthy })

        let reloaded = CatalogStore(directory: dir).load()
        #expect(reloaded.count == 3)
        #expect(reloaded.allSatisfy { $0.lifecycleStage == .archived })
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
    func discardSetsPurgedAtAndTrashedLifecycle() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModel(at: dir)
        let rec = makeWorkbenchRecord("test_artifact.mov")
        model.records = [rec]

        let revisionBefore = model.volumeAggregatesRevision
        let n = model.discardWorkbench([rec])
        #expect(n == 1)
        #expect(model.volumeAggregatesRevision > revisionBefore,
                "in-place purge must announce itself so cached table/aggregates recompute (#160)")
        #expect(rec.purgedAt != nil, "purgedAt must be stamped so soft-delete takes effect")
        #expect(rec.lifecycleStage == .trashed)

        let reloaded = CatalogStore(directory: dir).load().first!
        #expect(reloaded.purgedAt != nil)
        #expect(reloaded.lifecycleStage == .trashed)
    }

    @Test
    func discardEmptyArrayIsNoOp() throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModel(at: dir)
        model.records = []
        let n = model.discardWorkbench([])
        #expect(n == 0)
        // No catalog should have been written.
        let reloaded = CatalogStore(directory: dir).load()
        #expect(reloaded.isEmpty)
    }

    @Test
    func discardGracefullyHandlesMissingFile() throws {
        // The file at fullPath doesn't exist in the test fixture, but
        // discardWorkbench must still purge the record — leaving an
        // un-purgeable row would let bad records accumulate forever.
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = try makeModel(at: dir)
        let rec = makeWorkbenchRecord("ghost.mov")
        model.records = [rec]

        let n = model.discardWorkbench([rec])
        #expect(n == 1)
        #expect(rec.purgedAt != nil)
    }
}
