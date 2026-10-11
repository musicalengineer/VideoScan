// OneRemovalShapeTests.swift
// GH #143 — the tab-charter audit's T4 (docs/reviews/tab_charter_audit_2026_10_11.md
// §4), now green: every Trash door keeps the row, marked with the one
// removal marker, so Show Removed → Restore can bring the file back.
// Before GH #143, Delete Duplicates' settle deleted the row
// (VideoScanModel+Duplicates.swift `records.remove(at:)`).
//
// Plus the engine's catalog half: Restore clears the marker (and an old
// "deleted" label), and "Trash emptied" is recorded from a stat.
//
// Dimensions: logic; isolation (sandbox catalog + ledger; temp files only).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("One removal shape — T4 and Restore (GH #143)", .serialized)
@MainActor
struct OneRemovalShapeTests {

    private func scratch(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_charter_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func model(in dir: URL) -> VideoScanModel {
        let m = VideoScanModel(logDirectory: dir.appendingPathComponent("logs"))
        m.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog"))
        m.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        return m
    }

    private func record(_ path: String, size: Int64 = 100) -> VideoRecord {
        let r = VideoRecord(); r.fullPath = path; r.filename = (path as NSString).lastPathComponent
        r.sizeBytes = size; r.partialMD5 = "h-\(UUID().uuidString)"; return r
    }

    // T4 — verbatim from the audit, plus the marker's Trash path.
    @Test func aTrashedDuplicateStaysInTheCatalogAsRemovedLikeEveryOtherTrashPath() throws {
        let root = try scratch("dup_row"); defer { try? FileManager.default.removeItem(at: root) }
        let m = model(in: root)
        let keeper = record(root.appendingPathComponent("keeper.mov").path)
        let extra = record(root.appendingPathComponent("extra.mov").path)
        m.records = [keeper, extra]
        m.settleDeletedDuplicate(expectedID: extra.id, expectedPath: extra.fullPath, preAwait: extra,
                                 keeperID: keeper.id, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                                 isWorkingCopy: false, batchID: "test", keeperMatchedByStoredFixity: true,
                                 tier: .trash, trashVolume: "Test")
        #expect(m.records.contains { $0.id == extra.id && $0.isPurged && $0.lifecycleStage == .trashed },
                "the trashed duplicate left the catalog — Restore cannot bring it back")
        #expect(extra.removal?.state == .inTrash && extra.removal?.reason == .duplicate)
    }

    @Test func aDupTrashedRowCanBeRestored() throws {
        let root = try scratch("dup_restore"); defer { try? FileManager.default.removeItem(at: root) }
        let m = model(in: root)
        let keeper = record(root.appendingPathComponent("keeper.mov").path)
        let extraURL = root.appendingPathComponent("extra.mov")
        let extra = record(extraURL.path)
        m.records = [keeper, extra]
        m.settleDeletedDuplicate(expectedID: extra.id, expectedPath: extra.fullPath, preAwait: extra,
                                 keeperID: keeper.id, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                                 isWorkingCopy: false, batchID: "test", keeperMatchedByStoredFixity: true,
                                 tier: .trash, trashVolume: "Test", trashPath: "/nowhere/.Trash/extra.mov")
        #expect(extra.removal?.trashPath == "/nowhere/.Trash/extra.mov")
        // Rick puts it back in Finder, then Restores.
        try Data(repeating: 1, count: 100).write(to: extraURL)
        #expect(m.restoreRecord(id: extra.id))
        #expect(extra.removal == nil && !extra.isPurged && extra.lifecycleStage == .cataloged)
    }

    @Test func restoringAnOldDeletedLabelRowClearsTheLabel() throws {
        let root = try scratch("label_restore"); defer { try? FileManager.default.removeItem(at: root) }
        let m = model(in: root)
        let r = record(root.appendingPathComponent("camcorder.mts").path)
        r.archiveStage = .manuallyDeleted
        r.removal = RemovalMarker.migrated(stored: nil, purgedAt: nil, lifecycleStage: .cataloged,
                                           archiveStage: .manuallyDeleted, loadedAt: Date())
        m.records = [r]
        #expect(r.isPurged)
        #expect(m.restoreRecord(id: r.id))
        #expect(!r.isPurged && r.archiveStage == .none, "a restored row is live — the old label no longer hides it")
    }

    @Test func trashEmptiedIsRecordedFromAStat() throws {
        let root = try scratch("emptied"); defer { try? FileManager.default.removeItem(at: root) }
        let m = model(in: root)
        let inTrashFile = root.appendingPathComponent("Trash-a.mov")
        try Data(repeating: 2, count: 10).write(to: inTrashFile)
        let still = record(root.appendingPathComponent("a.mov").path)
        still.removal = .inTrash(movedAt: Date(), trashPath: inTrashFile.path, reason: .junk)
        let emptied = record(root.appendingPathComponent("b.mov").path)
        emptied.removal = .inTrash(movedAt: Date(), trashPath: root.appendingPathComponent("Trash-b.mov").path, reason: .junk)
        let removed = record(root.appendingPathComponent("c.mov").path)
        removed.removal = .removedFromCatalog(at: Date(), reason: .userRemoved)
        m.records = [still, emptied, removed]

        #expect(m.noteEmptiedTrash(in: m.records) == 1)
        #expect(still.removal?.isTrashEmptied == false)
        #expect(emptied.removal?.isTrashEmptied == true && emptied.removal?.state == .inTrash)
        #expect(removed.removal?.state == .removedFromCatalog)
        #expect(m.noteEmptiedTrash(in: m.records) == 0, "recorded once")
    }
}
