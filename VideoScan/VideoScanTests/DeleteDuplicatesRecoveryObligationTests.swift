// DeleteDuplicatesRecoveryObligationTests.swift — born as the QA RED suite
// QARedDupRecoveryObligationTests (2026-09-21, review of 2a964623); green on
// fix/qa-dup-recovery-obligations. The first five tests FAILED on main
// 2a964623/0ca81f06. None of them shows an
// unlink with too few copies; each shows a family file left inside a hidden
// `.videoscan-quarantine-*` folder while NO plan owes it a put-back (the plan
// is filed under done/ or never offered again) — the file silently vanishes
// from its folder.

import CryptoKit
import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func qaTempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_qared_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
private func qaWrite(_ url: URL, _ bytes: [UInt8]) { FileManager.default.createFile(atPath: url.path, contents: Data(bytes)) }
private func qaSHA(_ url: URL) -> String {
    SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
}
private let qaBlock = FileHasher.segmentSize
private let qaSize = qaBlock * 3

@MainActor private func qaModel(_ home: URL) -> VideoScanModel {
    let m = VideoScanModel()
    m.catalogStore = CatalogStore(directory: home.appendingPathComponent("catalog", isDirectory: true))
    m.mediaLedger = MediaLedger(directory: home.appendingPathComponent("ledger", isDirectory: true))
    return m
}
@MainActor private func qaRecord(_ path: String, group: UUID, _ d: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path; r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = Int64(qaSize); r.partialMD5 = "same"; r.durationSeconds = 61
    r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
    return r
}
private final class QAProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var action: (@Sendable () -> Void)?
    func onFirstQuarantineBlock(_ a: @escaping @Sendable () -> Void) { lock.withLock { action = a } }
    var hooks: SignatureVerification.Hooks {
        SignatureVerification.Hooks(shouldCancel: { Task.isCancelled }, didReadBlock: { [self] label in
            guard label == "quarantine" else { return }
            let a: (@Sendable () -> Void)? = lock.withLock { guard !fired else { return nil }; fired = true; return action }
            a?()
        })
    }
}
private func qaQuarantineFolders(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix(SignatureVerification.quarantineDirectoryPrefix) }
}

/// keeper (stored fixity → single-read path) + one extra + verified archive
/// family (3 copies remain → permanent tier). Plans/catalog live OUTSIDE
/// the "volume" so the volume can go away by rename.
@MainActor private struct QARig {
    let home: URL, dir: URL, root: URL
    let model: VideoScanModel
    let keeper: VideoRecord, copy: VideoRecord
    let bytes: [UInt8]
    init(_ label: String, copyBytes: [UInt8]? = nil) {
        home = qaTempDir(label + "-home"); dir = qaTempDir(label + "-volume")
        root = home.appendingPathComponent("plans", isDirectory: true)
        bytes = (0..<qaSize).map { UInt8($0 % 191) }
        let k = dir.appendingPathComponent("keeper.mov"); qaWrite(k, bytes)
        let c = dir.appendingPathComponent("copy1.mov"); qaWrite(c, copyBytes ?? bytes)
        let g = UUID()
        model = qaModel(home)
        keeper = qaRecord(k.path, group: g, .keep)
        keeper.contentFixity = ContentFixity.captured(path: k.path, digest: qaSHA(k), byteCount: Int64(qaSize))
        copy = qaRecord(c.path, group: g, .extraCopy)
        model.records = [keeper, copy]
        _ = addVerifiedArchiveFamily(to: model, keeper: keeper)
    }
    var offline: URL { URL(fileURLWithPath: dir.path + "-offline") }
    func cleanup() {
        try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: offline)
        try? FileManager.default.removeItem(at: home)
    }
    /// A plan whose row is still `.pending` on disk while its file already
    /// sits in the derived quarantine folder: the crash landed after the
    /// single-read path's move and during its hash, before the ticket save.
    func unjournaledCrash() throws -> (plan: DeleteDuplicatesPlan, qfile: URL) {
        let e = DeleteDuplicatesPlan.Entry(id: copy.id, path: copy.fullPath, filename: copy.filename, sizeBytes: copy.sizeBytes,
                                           keeperID: keeper.id, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                                           keeperStamp: FileIdentityStamp.capture(path: keeper.fullPath))
        let plan = DeleteDuplicatesPlan(volumePath: dir.path, catalogLocation: model.catalogStore.fileLocation,
                                        crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "", entries: [e])
        try DeleteDuplicatesPlanStore.save(plan, root: root)
        let q = dir.appendingPathComponent(DeleteDuplicatesJob.quarantineDirectoryName(planID: plan.id, entryID: copy.id),
                                           isDirectory: true)
        try FileManager.default.createDirectory(at: q, withIntermediateDirectories: false)
        let qfile = q.appendingPathComponent(copy.filename)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: copy.fullPath), to: qfile)
        return (plan, qfile)
    }
}

@Suite("Delete Duplicates — a file left in quarantine is always owed a put-back", .serialized)
@MainActor
struct DeleteDuplicatesRecoveryObligationTests {

    /// F1 — pins DeleteDuplicatesJob.swift:903/978 + 1049–1052 (phase-1
    /// `.retained` never records the folder) and :844 (stranded test keys on
    /// `quarantineDirectory`). The drive drops mid-hash on the single-read
    /// path: verifyHeld cannot put the file back (parent gone), phase one
    /// returns `.retained`, the row is settled `.failed` with the folder only
    /// in a note, and the plan is filed under done/. Reconnect: the file is in
    /// a hidden folder and nothing offers to put it back.
    @Test func driveDropDuringTheSingleReadHashLeavesAnOwedPutBack() async throws {
        let rig = QARig("p1drop"); defer { rig.cleanup() }
        let probe = QAProbe()
        let dir = rig.dir, away = rig.offline
        probe.onFirstQuarantineBlock { try? FileManager.default.moveItem(at: dir, to: away) }   // drive drops
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: probe.hooks.withScratchTrash(in: rig.home), planRoot: rig.root)
        job.start(); await job.task?.value
        try FileManager.default.moveItem(at: away, to: dir)                                      // drive returns

        let folders = qaQuarantineFolders(rig.dir)
        #expect(folders.count == 1 && !FileManager.default.fileExists(atPath: rig.copy.fullPath),
                "precondition: the file is in a hidden quarantine folder, not at its path")
        let plan = try #require(job.plan)
        #expect(plan.entries[0].needsRecovery, "row \(plan.entries[0].status): \(plan.entries[0].note) — folder not named on the row")
        let offered = DeleteDuplicatesPlanStore.unfinishedPlans(root: rig.root, log: { _ in }).map(\.id)
        #expect(offered.contains(plan.id), "the plan was filed under done/ with the file still in quarantine")
    }

    /// F1b — same hole, no hardware: a look-alike (same size, differs in the
    /// middle) whose original path is re-occupied while it is hashed in
    /// quarantine. verifyHeld's put-back is refused (occupied) → `.retained`
    /// in phase one → row `.failed`, no folder on the row, plan filed done.
    @Test func obstructedPutBackOfALookAlikeLeavesAnOwedPutBack() async throws {
        var other = (0..<qaSize).map { UInt8($0 % 191) }; other[qaBlock + 11] ^= 0x33
        let rig = QARig("p1obstruct", copyBytes: other); defer { rig.cleanup() }
        let probe = QAProbe()
        let original = rig.copy.fullPath
        probe.onFirstQuarantineBlock { FileManager.default.createFile(atPath: original, contents: Data([1, 2, 3])) }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: probe.hooks.withScratchTrash(in: rig.home), planRoot: rig.root)
        job.start(); await job.task?.value

        #expect(qaQuarantineFolders(rig.dir).count == 1, "precondition: the look-alike is retained in quarantine")
        let plan = try #require(job.plan)
        #expect(plan.entries[0].needsRecovery, "row \(plan.entries[0].status): \(plan.entries[0].note)")
        let offered = DeleteDuplicatesPlanStore.unfinishedPlans(root: rig.root, log: { _ in }).map(\.id)
        #expect(offered.contains(plan.id), "plan filed as done with a unique look-alike still in quarantine")
    }

    /// F2 — pins VideoScanModel+Duplicates.swift:744–770. Crash mid-hash
    /// (unjournaled quarantine), relaunch, Rick chooses Discard on the offer.
    /// Discard only consults `needsRecovery` (recorded folders); it never looks
    /// for the derived folder, skips the row and files the plan under done/.
    @Test func discardAfterACrashMidHashPutsTheFileBackOrKeepsTheOffer() async throws {
        let rig = QARig("discard"); defer { rig.cleanup() }
        let (plan, qfile) = try rig.unjournaledCrash()
        let launch = qaModel(rig.home)
        launch.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        #expect(launch.pendingDeleteDuplicatesResume?.id == plan.id, "precondition: offered")
        launch.discardPendingDeleteDuplicatesPlan(root: rig.root)

        let restored = FileManager.default.fileExists(atPath: rig.copy.fullPath)
        let stillOffered = DeleteDuplicatesPlanStore.unfinishedPlans(root: rig.root, log: { _ in }).contains { $0.id == plan.id }
        #expect(restored || stillOffered,
                "Discard filed the plan while \(qfile.path) still holds the file — nothing will ever offer it again")
    }

    /// F2b — pins VideoScanModel+Duplicates.swift:751 vs 763. Crash in the
    /// phase-two window AFTER the ticket save (row `.verified`, folder and
    /// stamp recorded — the journaled case). Discard tests `needsRecovery`
    /// BEFORE `skipRemaining`; a `.verified` row is unsettled so it is false;
    /// skipRemaining then settles the row with the folder still named and the
    /// plan goes to done/ anyway.
    @Test func discardAfterACrashAfterTheTicketSavePutsTheFileBackOrKeepsTheOffer() async throws {
        let rig = QARig("discardj"); defer { rig.cleanup() }
        var (plan, qfile) = try rig.unjournaledCrash()
        let stamp = try #require(FileIdentityStamp.capture(path: qfile.path))
        plan.setQuarantined(rig.copy.id, directory: qfile.deletingLastPathComponent().path, stamp: stamp)
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)
        let launch = qaModel(rig.home)
        launch.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        #expect(launch.pendingDeleteDuplicatesResume?.id == plan.id, "precondition: offered")
        launch.discardPendingDeleteDuplicatesPlan(root: rig.root)

        let restored = FileManager.default.fileExists(atPath: rig.copy.fullPath)
        let stillOffered = DeleteDuplicatesPlanStore.unfinishedPlans(root: rig.root, log: { _ in }).contains { $0.id == plan.id }
        #expect(restored || stillOffered,
                "Discard filed the plan under done/ while \(qfile.path) still holds the file")
    }

    /// F3 — the known follow-up, pinned at DeleteDuplicatesJob.swift:1224 +
    /// 1272–1278 + 1386–1387. Crash mid-hash, relaunch with the drive NOT
    /// mounted, Resume: the derived folder cannot be seen, the target "is
    /// missing", the row is skipped as "gone before the crash" with no folder
    /// on it, and the plan is filed under done/. Remount: file hidden, no offer.
    /// NOT cosmetic for an unjournaled quarantine.
    @Test func resumeWithTheDriveAwayNeverForgetsAnUnjournaledQuarantine() async throws {
        let rig = QARig("resumeaway"); defer { rig.cleanup() }
        let (plan, qfile) = try rig.unjournaledCrash()
        try FileManager.default.moveItem(at: rig.dir, to: rig.offline)                           // not mounted
        let job = DeleteDuplicatesJob(model: rig.model, resuming: plan, planRoot: rig.root)
        job.start(); await job.task?.value
        try FileManager.default.moveItem(at: rig.offline, to: rig.dir)                           // remounted

        #expect(FileManager.default.fileExists(atPath: qfile.path), "precondition: still in quarantine")
        let row = try #require(job.plan).entries[0]
        let stillOffered = DeleteDuplicatesPlanStore.unfinishedPlans(root: rig.root, log: { _ in }).contains { $0.id == plan.id }
        #expect(stillOffered, "row \(row.status): \(row.note) — plan filed as done; the quarantined file is orphaned")
    }

    // MARK: - Added with the fix (2026-09-21)

    /// F5 — a keeper stamp that differs ONLY in the device number (an
    /// external drive replugged between sessions) is still the keeper:
    /// the resume proceeds and the copy is removed, never flipped to
    /// Review. The pure check: device ignored, inode/size/mtime/ctime not.
    @Test func resumeAfterAReplugTreatsADeviceOnlyChangeAsTheSameKeeper() async throws {
        let rig = QARig("replug"); defer { rig.cleanup() }
        let real = try #require(FileIdentityStamp.capture(path: rig.keeper.fullPath))
        let replugged = FileIdentityStamp(device: real.device &+ 7, inode: real.inode, size: real.size,
                                          mtimeNs: real.mtimeNs, ctimeNs: real.ctimeNs)
        #expect(DeleteDuplicatesJob.keeperUnchangedAcrossRemount(planned: replugged, current: real))
        let e = DeleteDuplicatesPlan.Entry(id: rig.copy.id, path: rig.copy.fullPath, filename: rig.copy.filename,
                                           sizeBytes: rig.copy.sizeBytes, keeperID: rig.keeper.id,
                                           keeperPath: rig.keeper.fullPath, keeperFilename: rig.keeper.filename,
                                           keeperStamp: replugged)
        let plan = DeleteDuplicatesPlan(volumePath: rig.dir.path, catalogLocation: rig.model.catalogStore.fileLocation,
                                        crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "", entries: [e])
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)
        let job = DeleteDuplicatesJob(model: rig.model, resuming: plan,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: rig.home), planRoot: rig.root)
        job.start(); await job.task?.value

        let row = try #require(job.plan).entries[0]
        #expect(row.status.isRemoved, "row \(row.status): \(row.note)")
        #expect(!row.note.contains("changed since the plan was made"), Comment(rawValue: row.note))
        #expect(!FileManager.default.fileExists(atPath: rig.copy.fullPath))
        #expect(FileManager.default.fileExists(atPath: rig.keeper.fullPath), "the keeper is never touched")
    }

    /// F5, the negative: a keeper whose kernel ctime moved (rewritten with
    /// the mtime put back) is refused at resume, device-insensitive or not.
    @Test func resumeStillRefusesAKeeperWhoseChangeTimeMoved() async throws {
        let rig = QARig("ctime"); defer { rig.cleanup() }
        let real = try #require(FileIdentityStamp.capture(path: rig.keeper.fullPath))
        let rewritten = FileIdentityStamp(device: real.device, inode: real.inode, size: real.size,
                                          mtimeNs: real.mtimeNs, ctimeNs: real.ctimeNs &- 1)
        #expect(!DeleteDuplicatesJob.keeperUnchangedAcrossRemount(planned: rewritten, current: real))
        let otherInode = FileIdentityStamp(device: real.device &+ 7, inode: real.inode &+ 1, size: real.size,
                                           mtimeNs: real.mtimeNs, ctimeNs: real.ctimeNs)
        #expect(!DeleteDuplicatesJob.keeperUnchangedAcrossRemount(planned: otherInode, current: real))
        let e = DeleteDuplicatesPlan.Entry(id: rig.copy.id, path: rig.copy.fullPath, filename: rig.copy.filename,
                                           sizeBytes: rig.copy.sizeBytes, keeperID: rig.keeper.id,
                                           keeperPath: rig.keeper.fullPath, keeperFilename: rig.keeper.filename,
                                           keeperStamp: rewritten)
        let plan = DeleteDuplicatesPlan(volumePath: rig.dir.path, catalogLocation: rig.model.catalogStore.fileLocation,
                                        crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "", entries: [e])
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)
        let job = DeleteDuplicatesJob(model: rig.model, resuming: plan,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: rig.home), planRoot: rig.root)
        job.start(); await job.task?.value

        let row = try #require(job.plan).entries[0]
        #expect(row.status == .refused && row.note.contains("changed since the plan was made"), "row \(row.status): \(row.note)")
        #expect(FileManager.default.fileExists(atPath: rig.copy.fullPath), "nothing removed")
    }

    /// F4 for Discard (the same hole through the other button): with the
    /// drive away an unsettled row may be a file a crash left in an
    /// unjournaled quarantine folder — Discard is refused, the plan on disk
    /// is untouched and still offered; remounted, Discard puts the file
    /// back and files the plan.
    @Test func discardWithTheDriveAwayKeepsTheOfferUntilItReturns() async throws {
        let rig = QARig("discardaway"); defer { rig.cleanup() }
        let (plan, qfile) = try rig.unjournaledCrash()
        let planURL = DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root)
        let before = try Data(contentsOf: planURL)
        try FileManager.default.moveItem(at: rig.dir, to: rig.offline)                           // not mounted
        let launch = qaModel(rig.home)
        launch.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        #expect(launch.pendingDeleteDuplicatesResume?.id == plan.id, "precondition: offered")
        launch.discardPendingDeleteDuplicatesPlan(root: rig.root)
        #expect(try Data(contentsOf: planURL) == before, "nothing settled, nothing saved while the drive is away")
        #expect(launch.pendingDeleteDuplicatesResume?.id == plan.id, "still offered")

        try FileManager.default.moveItem(at: rig.offline, to: rig.dir)                           // remounted
        launch.discardPendingDeleteDuplicatesPlan(root: rig.root)
        #expect(FileManager.default.fileExists(atPath: rig.copy.fullPath), "put back at its path")
        #expect(!FileManager.default.fileExists(atPath: qfile.path))
        #expect(qaQuarantineFolders(rig.dir).isEmpty, "the empty quarantine folder is removed")
        #expect(!DeleteDuplicatesPlanStore.unfinishedPlans(root: rig.root, log: { _ in }).contains { $0.id == plan.id },
                "nothing owed: the plan is filed")
    }

    /// F4, the resume's own words: refused with the reconnect line, the
    /// plan file byte-identical, the job reported as refused.
    @Test func resumeWithTheDriveAwaySaysReconnectAndChangesNothing() async throws {
        let rig = QARig("resumeawaywords"); defer { rig.cleanup() }
        let (plan, _) = try rig.unjournaledCrash()
        let planURL = DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root)
        let before = try Data(contentsOf: planURL)
        try FileManager.default.moveItem(at: rig.dir, to: rig.offline)
        let job = DeleteDuplicatesJob(model: rig.model, resuming: plan, planRoot: rig.root)
        job.start(); await job.task?.value
        try FileManager.default.moveItem(at: rig.offline, to: rig.dir)
        #expect(job.wasRefused)
        #expect(try Data(contentsOf: planURL) == before, "the plan on disk is exactly as it was")
        let expected = DeletionTierText.notConnected(plan.volumeName, path: plan.volumePath, action: "Resume")
        #expect(expected.contains("reconnect it and choose Resume again"), Comment(rawValue: expected))
        #expect(job.plan?.entries[0].status == .pending, "no row settled")
    }
}
