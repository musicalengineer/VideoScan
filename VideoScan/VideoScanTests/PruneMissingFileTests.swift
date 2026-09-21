// PruneMissingFileTests.swift
// "Archived — what next?" with a MISSING FILE on a connected volume
// (2026-09-21 — Rick: "'M4drive' was said 'not connected' in some cases
// which is weird. So I could only delete some videos."). The boot volume
// is M4drive; the rows had been moved or deleted outside the app. The
// model half: the snapshot's `isOnline` is the VOLUME, the plan stats the
// working copies off-main, the row reads "not on … any more (moved or
// deleted?)", Apply never trashes it nor counts it as remaining, and
// "Remove from catalog" tombstones it through the existing purge path
// with a `setAside` "removed-from-catalog" ledger line — nothing on disk.
//
// ISOLATION: sandbox model + sandbox ledger + sandbox archive root under
// the temp dir (an internal path — the boot volume, exactly Rick's case);
// `.permanent` so nothing reaches the real Trash.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archived — what next? — a missing file is not an offline drive", .serialized)
@MainActor
struct PruneMissingFileTests {

    struct Fixture {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let ids: [UUID]
        let source: VideoRecord
        let dup: VideoRecord
        /// Same content key, a path in the sandbox that has no file.
        let gone: VideoRecord
        let archive: VideoRecord
    }

    /// A promoted source, a byte-identical copy on disk, and a record
    /// for a copy that is NOT on disk (moved or deleted outside the app).
    private func fixture(_ label: String) async throws -> Fixture {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_missing_a.mov"),
                                                       bytes: 40 * 1024, seed: 11)
        let source = MasterArchiveTestSupport.makeRecord(path: a.path, userDate: "1992")
        model.records = [source]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [source.id]))
        await job.completionTask?.value
        let archive = try #require(model.archivedCopy(of: source), "fixture: promote made an archive copy")

        let dupDir = sb.sources.appendingPathComponent("copies", isDirectory: true)
        try FileManager.default.createDirectory(at: dupDir, withIntermediateDirectories: true)
        let a2 = dupDir.appendingPathComponent("test_missing_a.mov")
        try FileManager.default.copyItem(at: a, to: a2)
        let dup = MasterArchiveTestSupport.makeRecord(path: a2.path, userDate: "1992")
        // The missing one: a record whose file never existed here.
        let gonePath = sb.sources.appendingPathComponent("moved-away/test_missing_a.mov").path
        let gone = VideoRecord()
        gone.filename = "test_missing_a.mov"; gone.fullPath = gonePath
        gone.directory = (gonePath as NSString).deletingLastPathComponent; gone.ext = "mov"
        gone.sizeBytes = source.sizeBytes; gone.userDate = "1992"
        for r in [source, dup, gone, archive] { r.contentHash = "v1:test-missing-a" }
        model.records.append(contentsOf: [dup, gone])
        await model.recordAttestation(kind: .cloud, answer: .yes, label: "iCloud", for: [source.id, dup.id, gone.id]).flush?.value
        return Fixture(sb: sb, model: model, ids: [source.id, dup.id, gone.id], source: source, dup: dup, gone: gone, archive: archive)
    }

    @Test("the snapshot says the VOLUME is online for an internal path with no file; the plan lists the row disabled as 'not on … any more (moved or deleted?)', never 'drive not connected', and never as a copy")
    func theRowIsMissingNotOffline() async throws {
        let f = try await fixture("missing_row"); defer { f.sb.cleanup() }
        // Default `isOnline` (the volume) and default `fileExists` (a stat).
        let snaps = f.model.archiveCopySnapshots()
        let gone = try #require(snaps.first { $0.id == f.gone.id })
        #expect(gone.isOnline, "the temp dir is on the boot volume — online")
        #expect(gone.fileExists, "the main-actor snapshot never stats — unknown reads true until the off-main pass")
        let plan = await f.model.prunePlan(for: f.ids, options: .init())
        try #require(plan.families.count == 1, "\(plan)")
        let family = plan.families[0]
        let row = try #require(family.rows.first { $0.id == f.gone.id })
        #expect(row.role == .kept(.fileMissing))
        #expect(!row.checkable)
        #expect(row.reasonText?.hasPrefix("not on ") == true && row.reasonText?.hasSuffix(" any more (moved or deleted?)") == true, "\(row.reasonText ?? "nil")")
        #expect(row.reasonText != "drive not connected")
        #expect(family.missingIDs == [f.gone.id] && plan.missingCount == 1)
        #expect(family.extraCount == 2, "source + dup — the missing row is not a copy")
        #expect(family.checkableIDs.sorted { $0.uuidString < $1.uuidString } == [f.source.id, f.dup.id].sorted { $0.uuidString < $1.uuidString })
        #expect(family.archiveVerified && family.covered)
        // The protection line counts two working copies, both online.
        let protection = await f.model.batchProtection(for: f.ids)
        #expect(protection.workingCopyCount == 2 && protection.workingVolumesOffline.isEmpty, "\(protection.displayLine)")
        // ISOLATION: an injected stat answer flips it back — the plan's
        // missing verdict comes from `fileExists`, not from the volume.
        let asIfThere = await f.model.prunePlan(for: f.ids, options: .init(), fileExists: { _ in true })
        #expect(asIfThere.families[0].rows.first { $0.id == f.gone.id }?.checkable == true)
        #expect(asIfThere.missingCount == 0)
    }

    @Test("Apply never trashes a missing row (held as never offered) and never counts it as a remaining copy; the real copies are judged on their own")
    func applyNeverTouchesTheMissingRow() async throws {
        let f = try await fixture("missing_apply"); defer { f.sb.cleanup() }
        let shown = await f.model.prunePlan(for: f.ids, options: .init(keepOne: false))
        // Check everything the sheet could hold, plus the missing id as if
        // a stale selection carried it.
        let outcome = await f.model.applyPrune(shown: shown, selected: [f.source.id, f.dup.id, f.gone.id],
                                               recordIDs: f.ids, options: .init(keepOne: false),
                                               batchID: "t-missing", mode: .permanent)
        #expect(outcome.trashed == 2, "\(outcome.summary)")
        #expect(outcome.alreadyMissing == 0 && outcome.skippedOffline == 0, "the missing row never reaches the Trash routine")
        #expect(outcome.held.count == 1 && outcome.held[0].hasPrefix("test_missing_a.mov — was never offered: not on "), "\(outcome.held)")
        #expect(f.gone.purgedAt == nil, "held, untouched")
        #expect(f.source.purgedAt != nil && f.dup.purgedAt != nil)
        // The approval verdict: nothing remains but the archive — the
        // missing row did not pass for a remaining copy.
        await f.model.mediaLedger.waitForPendingWrites()
        let approvals = f.model.mediaLedger.allEvents().filter { $0.event == .approval }
        #expect(approvals.count == 1)
        let judged = shown.families[0].selection([f.source.id, f.dup.id])
        #expect(judged.archiveOnlyFamilies.count == 1, "only the archive copy remains — the missing row is not a copy")
        // No copyDeleted line for the missing row.
        let deleted = f.model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }
        #expect(Set(deleted.map(\.recordID)) == [f.source.id, f.dup.id])
    }

    @Test("Remove from catalog: the missing row is tombstoned through the purge path with a setAside 'removed-from-catalog' line, nothing on disk; a row whose file exists is kept; idempotent; the re-plan has no missing row")
    func removeFromCatalogTombstonesOnlyTheMissingRow() async throws {
        let f = try await fixture("missing_remove"); defer { f.sb.cleanup() }
        let before = await f.model.prunePlan(for: f.ids, options: .init())
        #expect(before.missingIDs == [f.gone.id])
        // Ask for the missing row AND a real one: only the missing goes.
        let n = await f.model.removeMissingCopiesFromCatalog(recordIDs: [f.gone.id, f.dup.id])
        #expect(n == 1)
        #expect(f.gone.purgedAt != nil && f.dup.purgedAt == nil && f.source.purgedAt == nil && f.archive.purgedAt == nil)
        #expect(FileManager.default.fileExists(atPath: f.dup.fullPath) && FileManager.default.fileExists(atPath: f.archive.fullPath),
                "nothing on disk is touched")
        await f.model.mediaLedger.waitForPendingWrites()
        let setAside = f.model.mediaLedger.allEvents().filter { $0.event == .setAside }
        #expect(setAside.count == 1)
        #expect(setAside.first?.recordID == f.gone.id && setAside.first?.by == .rick)
        #expect(setAside.first?.detail[MediaLedgerEvent.Detail.reason] == "removed-from-catalog")
        // Idempotent, and never the archive side.
        #expect(await f.model.removeMissingCopiesFromCatalog(recordIDs: [f.gone.id, f.archive.id]) == 0)
        #expect(f.archive.purgedAt == nil)
        // The re-plan: no missing row, the two real copies unchanged.
        let after = await f.model.prunePlan(for: f.ids, options: .init())
        #expect(after.missingCount == 0)
        #expect(!after.families[0].rows.contains { $0.id == f.gone.id })
        #expect(after.families[0].extraCount == 2)
        // Undo (the purge banner) brings the row back — it is a tombstone.
        #expect(f.model.lastPurgedBatch?.ids == [f.gone.id])
    }

    @Test("a truly offline drive still says 'drive not connected' and Remove from catalog refuses it — the file may well be there")
    func offlineIsStillOffline() async throws {
        let f = try await fixture("missing_offline"); defer { f.sb.cleanup() }
        let off = VideoRecord()
        off.filename = "test_missing_a.mov"
        off.fullPath = "/Volumes/__VideoScanTest_NotMounted_\(UUID().uuidString.prefix(8))/test_missing_a.mov"
        off.directory = (off.fullPath as NSString).deletingLastPathComponent
        off.scanContext.volumeName = "OffDrive"
        off.contentHash = "v1:test-missing-a"; off.sizeBytes = f.source.sizeBytes
        f.model.records.append(off)
        let plan = await f.model.prunePlan(for: f.ids + [off.id], options: .init())
        let row = try #require(plan.families[0].rows.first { $0.id == off.id })
        #expect(row.role == .kept(.offline) && row.reasonText == "drive not connected")
        #expect(plan.missingIDs == [f.gone.id], "offline is not missing")
        #expect(await f.model.removeMissingCopiesFromCatalog(recordIDs: [off.id]) == 0)
        #expect(off.purgedAt == nil)
    }
}
