// CatalogTrashShortcutTests.swift
// ⌘⌫ in the Catalog table moves the highlighted rows to the Trash through
// the ONE existing Trash routine (Rick, 2026-09-13). Three dimensions:
//
//   (a) PLAN    — pure: a Master Archive row, a pair member, an offline
//                 row, an already-removed row are refused (with why); the
//                 normal row is the only one handed on. Order is kept.
//   (b) LEDGER  — the real routine on tiny temp files: one `copyTrashed`
//                 line per row that left the disk, by: rick; refused rows
//                 stay on disk and get no line. (Files land in the Trash,
//                 the JunkDeletionTests precedent.)
//   (c) SENSOR  — the source: the shortcut handler calls
//                 `trashSelectedRecords`, which ends in the same
//                 `deleteConfirmedJunk(mode: .toTrash)` the row menu uses,
//                 and the new file has no FileManager code of its own.
//                 The Master Archive refusal sentence is shared.

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog ⌘⌫ — Trash through the existing routine", .serialized)
@MainActor
struct CatalogTrashShortcutTests {

    private func record(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.ext = (path as NSString).pathExtension
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    // MARK: (a) The pure plan

    @Test("plan: archive, pair member, offline and removed rows are refused; the normal row goes on; order kept")
    func planSortsTheSelection() {
        let archived = record("/Volumes/FamilyArchive/BreenFamilyArchive/1990s/test_a.mov")
        let pairHalf = record("/Volumes/X9/avid/test_pair_v.mxf")
        pairHalf.pairGroupID = UUID()
        let combined = record("/Volumes/X9/avid/test_combined.mov")
        combined.combinedFromPairID = UUID()
        let offline = record("/Volumes/Unplugged/test_off.mov")
        let removed = record("/Volumes/X9/test_removed.mov")
        removed.purgedAt = Date()
        let setAside = record("/Volumes/X9/test_aside.mp3")
        setAside.setAsideReason = CatalogScopePolicy.SetAsideReason.musicFormat.rawValue
        let normal = record("/Volumes/X9/test_normal.mov")
        let normal2 = record("/Users/rick/Movies/test_normal2.mov")

        let plan = VideoScanModel.catalogTrashPlan(
            for: [normal, archived, pairHalf, combined, offline, removed, setAside, normal2],
            isMasterArchive: { $0.fullPath.hasPrefix("/Volumes/FamilyArchive/") },
            isOffline: { $0.fullPath.hasPrefix("/Volumes/Unplugged/") })

        #expect(plan.toTrash == [normal.id, normal2.id], "only the ordinary rows, in selection order")
        #expect(plan.refused.map(\.id) == [archived.id, pairHalf.id, combined.id, offline.id, removed.id, setAside.id])
        #expect(plan.refused.map(\.reason) == [.masterArchive, .pairMember, .pairMember, .offlineVolume, .notActive, .notActive])
        #expect(plan.refusedCount(.pairMember) == 2)
        #expect(plan.refusedCount(.masterArchive) == 1)
        #expect(plan.refusedCount(.offlineVolume) == 1)
        #expect(plan.refusedCount(.notActive) == 2)
    }

    @Test("plan: the archive gate wins over the pair gate, and a removed row is never re-trashed")
    func planPrecedence() {
        let both = record("/Volumes/FamilyArchive/BreenFamilyArchive/test_pair.mxf")
        both.pairGroupID = UUID()
        let removedPair = record("/Volumes/X9/test_gone.mxf")
        removedPair.pairGroupID = UUID()
        removedPair.purgedAt = Date()
        let plan = VideoScanModel.catalogTrashPlan(
            for: [both, removedPair],
            isMasterArchive: { $0.fullPath.hasPrefix("/Volumes/FamilyArchive/") },
            isOffline: { _ in false })
        #expect(plan.toTrash.isEmpty)
        #expect(plan.refused.map(\.reason) == [.masterArchive, .notActive])
        #expect(VideoScanModel.catalogTrashPlan(for: [], isMasterArchive: { _ in true }, isOffline: { _ in true }) == .init())
    }

    // MARK: (b) The ledger, through the real routine

    @Test("ledger: one copyTrashed line per trashed row, by rick; refused rows stay on disk with no line")
    func trashWritesOneCopyTrashedLinePerRow() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("cmddel")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)

        let a = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_cmddel_a.mov"), bytes: 1024, seed: 1)
        let b = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_cmddel_b.mov"), bytes: 1024, seed: 2)
        let pairFile = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_cmddel_pair.mxf"), bytes: 1024, seed: 3)
        let archiveDir = sb.archiveRoot.appendingPathComponent("30_Video", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let archiveFile = try MasterArchiveTestSupport.writeBlob(at: archiveDir.appendingPathComponent("test_cmddel_archived.mov"), bytes: 1024, seed: 4)

        let recA = MasterArchiveTestSupport.makeRecord(path: a.path)
        let recB = MasterArchiveTestSupport.makeRecord(path: b.path)
        let recPair = MasterArchiveTestSupport.makeRecord(path: pairFile.path, streamType: .videoOnly)
        recPair.pairGroupID = UUID()
        let recArchived = MasterArchiveTestSupport.makeRecord(path: archiveFile.path)
        // The ignore list is content-keyed (partial MD5 + size).
        for (r, md5) in [(recA, "md5a"), (recB, "md5b"), (recPair, "md5p"), (recArchived, "md5x")] { r.partialMD5 = md5 }
        model.records = [recA, recB, recPair, recArchived]
        #expect(model.isInsideMasterArchive(path: archiveFile.path), "sandbox archive root is the model's Master Archive")

        let result = await model.trashSelectedRecords([recA, recPair, recB, recArchived])
        // One outcome per selected row (design R6): 2 moved, 2 held with why.
        #expect(result.attempted == 4 && result.succeeded == 2 && result.failed.isEmpty, "\(result)")
        #expect(result.refused.map(\.record.id) == [recPair.id, recArchived.id], "\(result.refused.map(\.reason))")

        // Disk: the two ordinary files left; the refused ones did not.
        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(FileManager.default.fileExists(atPath: pairFile.path), "a pair member is never trashed")
        #expect(FileManager.default.fileExists(atPath: archiveFile.path), "a Master Archive file is never trashed")
        // Catalog: the existing trashed state on the trashed rows only.
        #expect(recA.isPurged && recA.lifecycleStage == .trashed)
        #expect(recB.isPurged && recB.lifecycleStage == .trashed)
        #expect(!recPair.isPurged && recPair.lifecycleStage == .cataloged)
        #expect(!recArchived.isPurged && recArchived.lifecycleStage == .cataloged)

        // Ledger: exactly one copyTrashed per trashed row, by rick.
        await model.mediaLedger.waitForPendingWrites()
        let events = model.mediaLedger.allEvents()
        let trashed = events.filter { $0.event == .copyTrashed }
        #expect(trashed.count == 2, "\(events.map(\.event))")
        #expect(Set(trashed.map(\.recordID)) == [recA.id, recB.id])
        #expect(trashed.allSatisfy { $0.by == .rick && $0.by.rawValue == "rick" })
        #expect(trashed.allSatisfy { $0.detail[MediaLedgerEvent.Detail.mode] == "trash" })
        #expect(events.filter { $0.recordID == recPair.id || $0.recordID == recArchived.id }.isEmpty,
                "a refused row is not 'what happened to the file'")

        // "I don't wanna see it again" (Rick 2026-09-20): the trashed rows'
        // content is on the ignore list; the refused rows' is not.
        let store = model.ignoredContentStore
        #expect(store.contains(partialMD5: recA.partialMD5, sizeBytes: recA.sizeBytes, filename: recA.filename))
        #expect(store.contains(partialMD5: recB.partialMD5, sizeBytes: recB.sizeBytes, filename: recB.filename))
        #expect(!store.contains(partialMD5: recPair.partialMD5, sizeBytes: recPair.sizeBytes, filename: recPair.filename))
        #expect(!store.contains(partialMD5: recArchived.partialMD5, sizeBytes: recArchived.sizeBytes, filename: recArchived.filename))
        #expect(store.entry(id: store.entries.first { $0.filename == recA.filename }?.id ?? UUID())?.reason == "trashed-by-user")
    }

    @Test("no selection, a fully refused selection, and read-only mode never reach the disk")
    func noOpsNeverTouchTheDisk() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("cmddelnoop")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        let file = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_cmddel_keep.mov"), bytes: 512, seed: 9)
        let rec = MasterArchiveTestSupport.makeRecord(path: file.path)
        rec.pairGroupID = UUID()
        model.records = [rec]

        let empty = await model.trashSelectedRecords([])
        #expect(empty.attempted == 0)
        let refused = await model.trashSelectedRecords([rec])
        #expect(refused.attempted == 1 && refused.succeeded == 0 && refused.refused.count == 1, "the refusal is reported, not dropped")
        rec.pairGroupID = nil
        model.isReadOnly = true
        let readOnly = await model.trashSelectedRecords([rec])
        #expect(readOnly.attempted == 1 && readOnly.refused.first?.reason.contains("read-only viewer") == true)
        #expect(FileManager.default.fileExists(atPath: file.path))
        await model.mediaLedger.waitForPendingWrites()
        #expect(model.mediaLedger.allEvents().isEmpty)
    }

    // MARK: (c) Source sensor — one Trash routine, one refusal sentence

    private func productionSource(_ filename: String) throws -> String {
        // By NAME anywhere under VideoScan/VideoScan (feature folders, 2026-09-29).
        try SourceTree.appSource(named: filename)
    }

    @Test("sensor: the shortcut and the row menu end in the same deleteConfirmedJunk(mode: .toTrash); the new file owns no file deletion")
    func shortcutSharesTheTrashRoutine() throws {
        let table = try productionSource("CatalogContent+Table.swift")
        let handlerRange = try #require(table.range(of: "private func trashSelectedRows()"))
        // 1,800, not 900: the handler gained begin/reason logging on
        // 2026-09-16 and the two calls this pins moved past the old window.
        // A slice too small to reach what it asserts is a sensor that goes
        // quiet rather than a sensor that passes.
        let handler = String(table[handlerRange.lowerBound...].prefix(1_800))
        #expect(handler.contains("model.trashSelectedRecords(targets)"))
        #expect(handler.contains("reportDeleteResult(result)"))
        // The guard was `press.modifiers == .command` until 2026-09-16.
        // Exact equality made any stray flag macOS reported alongside
        // Command an `.ignored` with NO trace, which is indistinguishable
        // from the shortcut being gone — which is exactly what Rick
        // reported. What must stay true is the INTENT: ⌘⌫ is handled on
        // the table (so it is focus-scoped), and the other modifiers are
        // still refused.
        // 2026-10-05: the table's own .onKeyPress(⌘⌫) is GONE — it broke ↑/↓
        // row navigation (Rick: "still can't arrow up and down in cat view")
        // and was never reached (the menu claims ⌘⌫ first, 2026-09-20). The
        // INTENT — ⌘⌫ only while the table has focus — is kept by the
        // focus-scoped menu route pinned below. Nothing may put a key
        // handler back on the Table.
        #expect(!table.contains(".onKeyPress("), "no key handler on the Catalog table — it breaks arrow-key navigation")
        // The row menu moved to CatalogRowContextMenu.swift (R1, GH #281).
        let rowMenu = try productionSource("CatalogRowContextMenu.swift")
        #expect(rowMenu.contains("await model.deleteConfirmedJunk(targets, mode: .toTrash)"), "the row menu's Move to Trash still exists")
        #expect(!rowMenu.contains(".onKeyPress("), "no key handler in the row menu either")

        // 2026-09-20 (Rick's second "why can't I hit cmd-delete"): a Command
        // key is a KEY EQUIVALENT the menu bar sees first, so the table's
        // onKeyPress was never reached. The gesture must ALSO be a real
        // menu item (Catalog ▸ Move to Trash ⌘⌫) whose target is the
        // FOCUSED table's selection — never a scene-wide value, or a
        // search field's ⌘⌫ would trash rows.
        #expect(table.contains("focusedValue(\\.catalogTrashSelection"), "the table publishes its selection to the menu while focused")
        #expect(!table.contains("focusedSceneValue(\\.catalogTrashSelection"), "focus-scoped, never scene-scoped")
        #expect(table.contains("perform: trashSelectedRows"), "the menu ends in the same handler")
        let command = try productionSource("CatalogTrashCommand.swift")
        #expect(command.contains(".keyboardShortcut(.delete, modifiers: .command)"), "⌘⌫ as the key equivalent")
        #expect(command.contains("@FocusedValue(\\.catalogTrashSelection)"))
        #expect(!command.contains("FileManager"), "no file deletion of its own")
        let app = try productionSource("VideoScanApp.swift")
        #expect(app.contains("CatalogTrashMenuItem()"), "the item is in the Catalog menu")

        let plan = try productionSource("VideoScanModel+TrashSelection.swift")
        #expect(plan.contains("await deleteConfirmedJunk(targets, mode: .toTrash, guard: fileGuard)"), "the ONE existing Trash routine")
        #expect(!plan.contains("trashItem("), "no file deletion of its own")
        #expect(!plan.contains("removeItem("), "no file deletion of its own")
        #expect(!plan.contains("FileManager"), "no file deletion of its own")
        #expect(plan.contains("CatalogScopePolicy.isPairProtected("), "the pair gate Tidy uses")
        #expect(plan.contains("masterArchiveRefusalLine(verb: \"Move to Trash\""))

        let archive = try productionSource("VideoScanModel+MasterArchive.swift")
        #expect(archive.contains("log(Self.masterArchiveRefusalLine(verb: verb, count: tree))"),
                "excludingMasterArchiveFiles and ⌘⌫ share one sentence")
        // 2026-09-22: the rest of the Master Archive's VOLUME has its own
        // sentence, also shared by the choke point and ⌘⌫.
        #expect(archive.contains("log(Self.masterArchiveVolumeRefusalLine(verb: verb, count: onVolume, volume: label))"))
        #expect(plan.contains("masterArchiveVolumeRefusalLine(verb: \"Move to Trash\""))
        #expect(VideoScanModel.masterArchiveRefusalLine(verb: "Remove", count: 2)
                == "Remove: left 2 file(s) alone — they live in the Master Archive, which only archive actions may change.")
    }
}
