// OneEngineDoorCharacterizationTests.swift
// GH #143 step 2 (docs/design/one_removal_marker_and_trash_engine.md §5):
// pins the door behaviour that must SURVIVE the move onto one removal
// marker and one Trash engine. These are written against the base, and
// must pass there, before any door moves.
//
// Pinned per door:
//   - Trash only: a moved file is in the (sandbox) Trash, never unlinked;
//   - the row stays in `records`, hidden (isPurged), stage Trashed;
//   - held on failure: a Trash call that throws leaves file AND row alone;
//   - the archive gate: a file on the Master Archive volume is held,
//     named, untouched — by every bulk door, including Remove from Catalog;
//   - Remove from Catalog never touches the disk, and Restore undoes it.
//
// Dimensions: logic (one outcome per door), isolation (sandbox catalog,
// ledger and Trash — nothing reaches App Support or the real Trash).
// Delete Duplicates' proof is pinned by the DeleteDuplicates* suites
// (keeper read in full, quarantine re-read); its ROW behaviour changes in
// this theme (T4), so it is not characterized here.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("One engine — door characterization (GH #143)", .serialized)
@MainActor
struct OneEngineDoorCharacterizationTests {

    struct Boom: Error {}

    // MARK: ⌘⌫ / Catalog Move to Trash

    @Test func catalogTrashMovesToTheTrashAndKeepsTheRowAsRemoved() async throws {
        let sb = try JunkTrashSandbox("char_cat"); defer { sb.cleanup() }
        let model = sb.model()
        let url = try sb.write("test_clip.mov")
        let rec = sb.junk(url)
        rec.mediaDisposition = .unreviewed
        model.records = [rec]

        let result = await model.trashSelectedRecords([rec], confirmed: model.catalogTrashPlan(for: [rec]), fileOperation: sb.trash.operation)

        #expect(result.items.map(\.outcome.kind) == [.moved])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(sb.trash.attempts == [url.path], "handed to the Trash, nothing else")
        let inTrash = try FileManager.default.contentsOfDirectory(atPath: sb.trash.dir.path)
        #expect(inTrash.count == 1 && inTrash[0].hasSuffix("test_clip.mov"), "the bytes are in the Trash: \(inTrash)")
        #expect(model.records.contains { $0 === rec }, "the row stays in the catalog")
        #expect(rec.isPurged && rec.lifecycleStage == .trashed)
    }

    @Test func catalogTrashHeldOnFailureLeavesFileAndRow() async throws {
        let sb = try JunkTrashSandbox("char_cat_fail"); defer { sb.cleanup() }
        let model = sb.model()
        let url = try sb.write("test_clip.mov")
        let rec = sb.junk(url)
        model.records = [rec]
        sb.trash.failEverything(with: Boom())

        let result = await model.trashSelectedRecords([rec], confirmed: model.catalogTrashPlan(for: [rec]), fileOperation: sb.trash.operation)

        // The lane reports a thrown Trash call as failed or held (it names
        // the drive); either way nothing moved.
        #expect(!result.items.contains { $0.outcome.isMoved }, "\(result.items.map(\.outcome))")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!rec.isPurged && rec.lifecycleStage == .cataloged, "a failed Trash never stamps the row")
    }

    // MARK: Triage Delete Junk

    @Test func deleteJunkMovesToTheTrashAndKeepsTheRow() async throws {
        let sb = try JunkTrashSandbox("char_junk"); defer { sb.cleanup() }
        let model = sb.model()
        let url = try sb.write("test_junk.mov")
        let rec = sb.junk(url)
        model.records = [rec]
        let snapshot = await model.freezeJunkSnapshot([rec], isOffline: { _ in false })

        let result = await model.trashFrozenJunk(snapshot, fileOperation: sb.trash.operation)

        #expect(result.items.map(\.outcome.kind) == [.moved])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(model.records.contains { $0 === rec })
        #expect(rec.isPurged && rec.lifecycleStage == .trashed)
    }

    @Test func deleteJunkHeldOnFailureLeavesFileAndRow() async throws {
        let sb = try JunkTrashSandbox("char_junk_fail"); defer { sb.cleanup() }
        let model = sb.model()
        let url = try sb.write("test_junk.mov")
        let rec = sb.junk(url)
        model.records = [rec]
        let snapshot = await model.freezeJunkSnapshot([rec], isOffline: { _ in false })
        sb.trash.failEverything(with: Boom())

        let result = await model.trashFrozenJunk(snapshot, fileOperation: sb.trash.operation)

        #expect(result.items.map(\.outcome.kind) != [.moved])
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!rec.isPurged)
    }

    // MARK: Workbench discard

    @Test func workbenchDiscardMovesToTheTrashAndKeepsTheRow() async throws {
        let sb = try JunkTrashSandbox("char_wb"); defer { sb.cleanup() }
        let model = sb.model()
        let url = try sb.write("test_out.mov")
        let rec = sb.junk(url)
        rec.lifecycleStage = .workbench
        model.records = [rec]

        let n = await model.discardWorkbench([rec], trash: sb.trash.operation)

        #expect(n == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(sb.trash.attempts == [url.path])
        #expect(model.records.contains { $0 === rec })
        #expect(rec.isPurged && rec.lifecycleStage == .trashed)
    }

    @Test func workbenchDiscardHeldOnFailureLeavesFileAndRow() async throws {
        let sb = try JunkTrashSandbox("char_wb_fail"); defer { sb.cleanup() }
        let model = sb.model()
        let url = try sb.write("test_out.mov")
        let rec = sb.junk(url)
        rec.lifecycleStage = .workbench
        model.records = [rec]
        sb.trash.failEverything(with: Boom())

        let n = await model.discardWorkbench([rec], trash: sb.trash.operation)

        #expect(n == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!rec.isPurged && rec.lifecycleStage == .workbench)
    }

    // MARK: Remove from Catalog (+ Restore)

    @Test func removeFromCatalogNeverTouchesTheDiskAndRestoreUndoesIt() throws {
        let sb = try JunkTrashSandbox("char_remove"); defer { sb.cleanup() }
        let model = sb.model()
        let url = try sb.write("test_keep.mov")
        let rec = sb.junk(url)
        model.records = [rec]

        #expect(model.purgeRecords(ids: [rec.id]) == 1)
        #expect(FileManager.default.fileExists(atPath: url.path), "Remove from Catalog is catalog-only")
        #expect(rec.isPurged && rec.lifecycleStage == .cataloged)
        #expect(sb.trash.attempts.isEmpty)

        #expect(model.restoreRecord(id: rec.id))
        #expect(!rec.isPurged && rec.lifecycleStage == .cataloged)
    }

    // MARK: The archive gate, every bulk door

    @Test func everyBulkDoorHoldsAFileOnTheArchiveVolume() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("char_arch")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        _ = try MasterArchiveTestSupport.initialize(model, in: sb)
        let onArchive = try MasterArchiveTestSupport.writeBlob(
            at: sb.archiveVolume.appendingPathComponent("test_family.mov"), bytes: 2_048, seed: 7)
        let rec = MasterArchiveTestSupport.makeRecord(path: onArchive.path)
        rec.lifecycleStage = .workbench
        rec.mediaDisposition = .confirmedJunk
        model.records.append(rec)
        let trashDir = sb.root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let trash = SandboxTrash(dir: trashDir)

        let cat = await model.trashSelectedRecords([rec], confirmed: model.catalogTrashPlan(for: [rec]), fileOperation: trash.operation)
        #expect(cat.items.map(\.outcome.kind) == [.held], "⌘⌫: \(cat.items.map(\.outcome))")

        let snapshot = await model.freezeJunkSnapshot([rec], isOffline: { _ in false })
        let junk = await model.trashFrozenJunk(snapshot, fileOperation: trash.operation)
        #expect(!junk.items.contains { $0.outcome.isMoved }, "Delete Junk: \(junk.items.map(\.outcome))")

        #expect(await model.discardWorkbench([rec], trash: trash.operation) == 0, "Discard")
        #expect(model.purgeRecords(ids: [rec.id]) == 0, "Remove from Catalog on FamilyArchive")

        #expect(trash.attempts.isEmpty, "nothing was handed to the Trash")
        #expect(FileManager.default.fileExists(atPath: onArchive.path))
        #expect(!rec.isPurged && rec.lifecycleStage == .workbench)
    }
}
