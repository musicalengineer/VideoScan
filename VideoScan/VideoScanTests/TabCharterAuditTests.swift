// TabCharterAuditTests.swift — QA red tests from docs/reviews/tab_charter_audit_2026_10_11.md
// (T1, T2, T3 — T4 and T5 wait on Rick's rulings and are not here).
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Tab charter audit 2026-10-11", .serialized)
@MainActor
struct TabCharterAuditTests {

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

    // T1 — pins VideoScanModel+RetireVolume.swift:124 and :349.
    // A row labelled .manuallyDeleted with no witness note, whose file is
    // STILL on the drive (the footer's "false label" case), lets the drive
    // be retired although it holds the only copy.
    @Test func retireRefusesADriveWhoseFalselyLabelledFileIsStillOnIt() throws {
        let root = try scratch("retire_false_label"); defer { try? FileManager.default.removeItem(at: root) }
        let drive = root.appendingPathComponent("A")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let file = drive.appendingPathComponent("only-copy.mov")
        try Data(repeating: 7, count: 100).write(to: file)
        let m = model(in: root)
        let labelled = record(file.path)
        labelled.archiveStage = .manuallyDeleted          // the old Migrate / keeper-fold label
        m.records = [labelled]
        m.scanTargets = [CatalogScanTarget(searchPath: drive.path)]
        #expect(!m.retireVolume(at: drive.path, reason: "test", witnesses: []),
                "retired a drive whose only copy of a file is still on it — the label is not a proof")
    }

    // T2 — pins Catalog/VideoScanModel+Workbench.swift:24 (and the same shape
    // at Catalog/TriageView.swift:1137, private to the View).
    // "Promote" must go through the Promote engine; a label alone puts a
    // file nobody copied into the Archived stage and freezes its dates.
    @Test func workbenchPromoteNeverStampsArchivedWithoutAnArchiveCopy() throws {
        let root = try scratch("promote_label"); defer { try? FileManager.default.removeItem(at: root) }
        let m = model(in: root)
        let produced = record(root.appendingPathComponent("combined.mov").path)
        produced.lifecycleStage = .workbench
        m.records = [produced]
        m.promoteWorkbenchToArchive([produced])
        #expect(!(produced.lifecycleStage == .archived && !m.isArchived(produced)),
                "stamped Archived with no copy in the Master Archive")
        #expect(!m.isDateReadOnly(produced) || m.isArchived(produced),
                "dates frozen on a file that is not in the archive")
    }

    // T3 — pins Catalog/CatalogTrashConfirmation.swift:35-63 and
    // MediaOps/VideoScanModel+TrashSelection.swift:60. Charter (Catalog):
    // "⌘⌫ Move to Trash (Finder-like; it warns when the file is the only copy)".
    @Test func catalogMoveToTrashWarnsWhenTheFileIsTheOnlyCopy() throws {
        let root = try scratch("only_copy"); defer { try? FileManager.default.removeItem(at: root) }
        let m = model(in: root)
        let only = record(root.appendingPathComponent("only.mov").path)
        m.records = [only]
        let plan = m.catalogTrashPlan(for: [only], isOffline: { _ in false })
        #expect(plan.toTrash == [only.id])
        let confirmation = CatalogTrashConfirmation(plan: plan, sizes: [only.id: only.sizeBytes])
        #expect(confirmation.detail.localizedCaseInsensitiveContains("only copy"),
                "the confirmation never says this is the only copy: \(confirmation.detail)")
    }
}
