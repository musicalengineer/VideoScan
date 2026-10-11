// QAReviewRedTests_2026_10_11.swift — QA red tests for branch worktree-agent-afadff82e20fa9d5a
// (tab-charter audit T1/T3 fixes). Each test FAILS on the code under review
// and names the file:line it pins. Uncommitted; the fix agent lands them.
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("QA red — T1/T3 review 2026-10-11", .serialized)
@MainActor
struct QAReviewRedTests20261011 {

    private func rec(_ path: String, md5: String = "m1", size: Int64 = 1_000) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path; r.filename = (path as NSString).lastPathComponent
        r.partialMD5 = md5; r.sizeBytes = size
        return r
    }

    // MARK: T1

    // Pins Volumes/VideoScanModel+RetireVolume.swift:424 — `stat != .missing`
    // treats ENOENT as "gone" even when the file's FOLDER is gone from a
    // connected drive (renamed/reorganised on the drive). The bytes are still
    // on the drive, under a path the catalog doesn't know; Retire goes through.
    @Test func retireRefusesWhenALabelledFilesFolderIsGoneFromAConnectedDrive() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_qa_retire_folder_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let drive = root.appendingPathComponent("Old")
        let renamed = drive.appendingPathComponent("Tapes-1994")
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
        // The only copy, now under the renamed folder.
        try Data(repeating: 7, count: 100).write(to: renamed.appendingPathComponent("only.mov"))
        let m = VideoScanModel(logDirectory: root.appendingPathComponent("logs"))
        m.catalogStore = CatalogStore(directory: root.appendingPathComponent("catalog"))
        let labelled = rec(drive.appendingPathComponent("Tapes/only.mov").path, size: 100)
        labelled.archiveStage = .manuallyDeleted        // a false label (audit T1)
        m.records = [labelled]
        m.scanTargets = [CatalogScanTarget(searchPath: drive.path)]
        #expect(!m.retireVolume(at: drive.path, reason: "qa", witnesses: []),
                "ENOENT under a folder that no longer exists is not proof the bytes left the drive")
    }

    // Pins Volumes/VideoScanModel+RetireVolume.swift:420-421 — "is the drive
    // connected" is asked ONCE, before the stats. A drive that goes away
    // during the loop makes every later stat ENOENT = "gone".
    @Test func retireRechecksTheDriveIsConnectedAfterTheStats() {
        final class Calls: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let calls = Calls()
        let disk = ShowAgainDisk(
            volumeOnline: { _ in
                calls.lock.lock(); defer { calls.lock.unlock() }
                calls.n += 1
                return calls.n == 1           // connected at the first ask, gone after
            },
            stat: { _ in .missing })
        let m = VideoScanModel()
        let a = rec("/Volumes/QAOld/a.mov"); a.archiveStage = .manuallyDeleted
        let b = rec("/Volumes/QAOld/b.mov", md5: "m2"); b.archiveStage = .manuallyDeleted
        m.records = [a, b]
        m.scanTargets = [CatalogScanTarget(searchPath: "/Volumes/QAOld")]
        m.relocateWitnessIndependence = { w, s, _ in w != s }
        #expect(m.retireRefusal(at: "/Volumes/QAOld", disk: disk) != nil,
                "absence was read while the drive may already have been gone")
    }

    // MARK: T3

    private func plan(_ all: [VideoRecord], _ sel: [VideoRecord],
                      targets: [CatalogScanTarget] = []) -> VideoScanModel.CatalogTrashPlan {
        let m = VideoScanModel()
        m.records = all
        if !targets.isEmpty { m.scanTargets = targets }
        return m.catalogTrashPlan(for: sel, isOffline: { _ in false })
    }

    // Pins MediaOps/CatalogKnownCopies.swift:292 — a copy labelled deleted
    // (`.manuallyDeleted`) is counted as a survivor. The label exists because
    // the file was missing; trusting it hides the only-copy warning.
    @Test func aCopyLabelledDeletedIsNotASurvivingCopy() {
        let target = rec("/Volumes/A/clip.mov")
        let labelled = rec("/Volumes/B/clip.mov"); labelled.archiveStage = .manuallyDeleted
        #expect(plan([target, labelled], [target]).onlyCopy == [target.id])
    }

    // Pins MediaOps/CatalogKnownCopies.swift:292 — a copy on a RETIRED drive
    // (physically disconnected for good) is counted as a survivor.
    @Test func aCopyOnARetiredDriveIsNotASurvivingCopy() {
        let target = rec("/Volumes/A/clip.mov")
        let onRetired = rec("/Volumes/Maxtor500FW/clip.mov")
        let retired = CatalogScanTarget(searchPath: "/Volumes/Maxtor500FW"); retired.retiredAt = Date()
        #expect(plan([target, onRetired], [target], targets: [retired]).onlyCopy == [target.id])
    }

    // Pins MediaOps/CatalogKnownCopies.swift:282,292 — "same path catalogued
    // twice" is an exact string compare. The same file under a case variant
    // (case-insensitive APFS/HFS+) is the SAME bytes on disk, not a copy:
    // trashing one trashes "both".
    @Test func theSameFileUnderACaseVariantPathIsNotACopy() {
        let target = rec("/Volumes/A/Tapes/Clip.mov")
        let alias = rec("/Volumes/A/tapes/clip.mov")
        #expect(plan([target, alias], [target]).onlyCopy == [target.id])
    }
}
