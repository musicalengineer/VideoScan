// DeleteDuplicatesCodex1619Tests.swift
// Regressions for codex review 1615 / handoff 1619 (snapshot 9818ff51) —
// the Delete Duplicates job:
//
//   1. P1 — the uncached-keeper FALLBACK path (keeper without a usable
//      stored fixity: verify both files in place, then quarantine, ticket
//      `hashedInQuarantine == false`) re-checked the copy-count evidence
//      BEFORE phase two's full re-read of the quarantined file. A counted
//      sibling rewritten or removed during that read (minutes on a
//      spinning disk) left the permanent tier standing. Now the re-check
//      is the gate's FINAL verdict — after all hashing and the identity
//      checks, nothing between it and the unlink — on both paths.
//   2. P1 — Put Back treated "the quarantine path does not exist" as
//      "recovered" even with the drive disconnected, cleared the
//      obligation and filed the plan; the file was stranded on remount.
//      Now absence counts only on a mounted, reachable drive; otherwise
//      the row stays owed, the plan stays offered, Discard refuses, and
//      the console says "not connected — reconnect it".
//   3. P1 — a crash after the quarantine rename but BEFORE the ticket
//      save leaves a folder the plan never named. The resume found it
//      (derived name) but a failed restore (original path occupied)
//      settled the row refused WITHOUT adopting the folder — no
//      `needsRecovery`, plan filed as done, file lost to the offer. Now
//      the discovered folder + observed stamp go on the row before the
//      restore is tried.
//
// Everything lives under the process temp dir; the Trash step is routed
// into a scratch folder. The plan root and the catalog live OUTSIDE the
// fixture "volume" so the volume can go away by rename.

import CryptoKit
import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dup1619_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ url: URL, _ bytes: [UInt8]) {
    FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
}

private func plainSHA256(_ url: URL) -> String {
    let data = (try? Data(contentsOf: url)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private let blockSize = FileHasher.segmentSize
private let fileSize = blockSize * 3

/// Rewrite the file IN PLACE through a descriptor (same inode, same
/// size) and put the mtime back to the nanosecond — only the kernel
/// ctime (and the bytes) differ afterwards. The codex harness's corruption.
private func rewriteInPlace(_ url: URL, bytes: [UInt8]) throws {
    var before = stat()
    try #require(stat(url.path, &before) == 0)
    let fd = open(url.path, O_WRONLY)
    try #require(fd >= 0)
    defer { close(fd) }
    let wrote = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, bytes.count, 0) }
    try #require(wrote == bytes.count)
    var times = [before.st_atimespec, before.st_mtimespec]
    try #require(futimens(fd, &times) == 0)
    var after = stat()
    try #require(stat(url.path, &after) == 0)
    try #require(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
                 && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
                 && after.st_ino == before.st_ino && after.st_size == before.st_size)
}

@MainActor
private func makeModel(_ home: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: home.appendingPathComponent("catalog", isDirectory: true))
    model.mediaLedger = MediaLedger(directory: home.appendingPathComponent("ledger", isDirectory: true))
    return model
}

@MainActor
private func dupRecord(path: String, size: Int64, group: UUID, disposition: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = size
    r.partialMD5 = "same"
    r.durationSeconds = 61
    r.duplicateGroupID = group
    r.duplicateDisposition = disposition
    r.duplicateConfidence = .high
    return r
}

/// Block + open counters per label / basename, and a one-shot action run
/// on the FIRST block of a given label — from the disk thread, mid-read.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [String: Int] = [:]
    private var opens: [String: Int] = [:]
    private var fired: Set<String> = []
    private var onFirstBlock: [String: @Sendable () -> Void] = [:]

    func blocks(_ label: String) -> Int { lock.withLock { blocks[label] ?? 0 } }
    func opens(_ basename: String) -> Int { lock.withLock { opens[basename] ?? 0 } }
    func didFire(_ label: String) -> Bool { lock.withLock { fired.contains(label) } }
    func onFirstBlock(of label: String, _ action: @escaping @Sendable () -> Void) {
        lock.withLock { onFirstBlock[label] = action }
    }

    var hooks: SignatureVerification.Hooks {
        SignatureVerification.Hooks(
            shouldCancel: { Task.isCancelled },
            didReadBlock: { [self] label in
                let action: (@Sendable () -> Void)? = lock.withLock {
                    blocks[label, default: 0] += 1
                    guard let a = onFirstBlock[label], !fired.contains(label) else { return nil }
                    fired.insert(label)
                    return a
                }
                action?()
            },
            didOpen: { [self] path in
                let name = (path as NSString).lastPathComponent
                lock.withLock { opens[name, default: 0] += 1 }
            })
    }
}

/// The console flushes on the main actor a beat after the log call.
@MainActor
private func consoleText(_ model: VideoScanModel) async -> String {
    try? await Task.sleep(nanoseconds: 300_000_000)
    return model.dashboard.consoleLines.joined(separator: "\n")
}

private func quarantineFolders(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix(SignatureVerification.quarantineDirectoryPrefix) }
}

/// keeper + `copies` identical extras + (optionally) the verified archive
/// family (archive + sibling, stamp-bound fixity) → three verified copies
/// remain after one extra goes → PERMANENT. `keeperFixity: false` clears
/// the keeper's stored fixity so the first pair takes the fallback path
/// (verify both in place, quarantine, re-read in quarantine at phase two).
/// `home` (plans, catalog, ledger, scratch Trash) is a sibling of the
/// "volume" `dir`, never inside it.
@MainActor
private struct Rig {
    let home: URL
    let dir: URL
    let root: URL
    let model: VideoScanModel
    let keeper: VideoRecord
    let copies: [VideoRecord]
    let archive: VideoRecord?
    let sibling: VideoRecord?
    let bytes: [UInt8]

    init(_ label: String, copies n: Int = 1, archiveFamily: Bool = true, keeperFixity: Bool = true) {
        home = tempDir(label + "-home")
        dir = tempDir(label + "-volume")
        root = home.appendingPathComponent("plans", isDirectory: true)
        bytes = (0..<fileSize).map { UInt8($0 % 191) }
        let keeperURL = dir.appendingPathComponent("keeper.mov"); write(keeperURL, bytes)
        let group = UUID()
        model = makeModel(home)
        keeper = dupRecord(path: keeperURL.path, size: Int64(fileSize), group: group, disposition: .keep)
        if keeperFixity {
            keeper.contentFixity = ContentFixity.captured(path: keeperURL.path, digest: plainSHA256(keeperURL), byteCount: Int64(fileSize))
        }
        var made: [VideoRecord] = []
        for i in 0..<n {
            let c = dir.appendingPathComponent("copy\(i + 1).mov"); write(c, bytes)
            made.append(dupRecord(path: c.path, size: Int64(fileSize), group: group, disposition: .extraCopy))
        }
        copies = made
        model.records = [keeper] + made
        if archiveFamily {
            let family = addVerifiedArchiveFamily(to: model, keeper: keeper)
            archive = family.archive
            sibling = family.sibling
        } else {
            archive = nil
            sibling = nil
        }
    }

    var copy: VideoRecord { copies[0] }
    var copyURL: URL { URL(fileURLWithPath: copy.fullPath) }
    var trashedCopyURL: URL { home.appendingPathComponent("Trash/copy1.mov") }

    func job(_ probe: Probe) -> DeleteDuplicatesJob {
        DeleteDuplicatesJob(model: model, volumePath: dir.path,
                            hooks: probe.hooks.withScratchTrash(in: home), planRoot: root)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir.path + "-offline"))
        try? FileManager.default.removeItem(at: home)
    }
}

// MARK: - 1. The fallback path re-checks the evidence AFTER its full re-read

@Suite("Codex 1619 #1 — the uncached-keeper fallback re-checks counted copies after its final read", .serialized)
@MainActor
struct DeleteDuplicatesFallbackBoundaryCodex1619Tests {

    /// keeper without fixity → phase one verifies both in place and
    /// quarantines (`hashedInQuarantine == false`); phase two re-reads
    /// the file in quarantine. A counted SIBLING rewritten in place
    /// (mtime put back) on the FIRST block of that re-read: three → two,
    /// the tier falls to the Trash, the row and the ledger name the copy.
    /// Before the fix the re-check ran before the read and the file was
    /// unlinked with only two intact copies left.
    @Test func siblingRewrittenDuringTheQuarantineRereadDowngradesToTrash() async throws {
        let rig = Rig("fallback-rewrite", keeperFixity: false); defer { rig.cleanup() }
        let sibling = try #require(rig.sibling)
        let probe = Probe()
        let corrupt: [UInt8] = { var c = rig.bytes; c[blockSize + 7] ^= 0x5A; return c }()
        let siblingURL = URL(fileURLWithPath: sibling.fullPath)
        probe.onFirstBlock(of: "quarantine") { try? rewriteInPlace(siblingURL, bytes: corrupt) }
        let job = rig.job(probe)
        var tierWhenSaved: DeletionTier?
        var readsWhenSaved = 0
        job.testHookAfterQuarantineSaved = { [weak job] entry in
            tierWhenSaved = job?.plan?.entries.first { $0.id == entry.id }?.tier
            readsWhenSaved = probe.blocks("quarantine")
        }
        job.start(); await job.task?.value

        #expect(tierWhenSaved == .permanent, "three verified copies at the save")
        #expect(readsWhenSaved == 0 && probe.blocks("quarantine") == 3, "the fallback's re-read happened in phase two")
        #expect(probe.blocks("keeper") == 3 && probe.blocks("duplicate") == 3, "the fallback: both read once in place")
        #expect(probe.didFire("quarantine"), "the sibling was rewritten mid-read")
        #expect(sibling.contentFixity?.stampMatches(path: sibling.fullPath) == true, "only the kernel ctime tells")
        let plan = try #require(job.plan)
        let row = plan.entries[0]
        #expect(row.status == .trashed && row.tier == .trash && row.remainingVerifiedCopies == 2,
                "\(row.status): \(row.tierReason ?? "")")
        let reason = try #require(row.tierReason)
        #expect(reason.contains("sibling verified-sibling-of-keeper.mov on ") && reason.contains("changed since it was counted"),
                Comment(rawValue: reason))
        #expect(!FileManager.default.fileExists(atPath: rig.copy.fullPath))
        #expect(FileManager.default.fileExists(atPath: rig.trashedCopyURL.path), "to the Trash, not gone")
        #expect(quarantineFolders(in: rig.dir).isEmpty)
        #expect(job.result.deleted == 1 && job.result.bytesFreed == 0)
        await rig.model.mediaLedger.waitForPendingWrites()
        let events = rig.model.mediaLedger.allEvents().filter { $0.event == .copyTrashed || $0.event == .copyDeleted }
        #expect(events.count == 1 && events.first?.event == .copyTrashed)
        #expect(events.first?.detail[MediaLedgerEvent.Detail.tier] == "trash")
        #expect(events.first?.detail[MediaLedgerEvent.Detail.reason]?.contains("changed since it was counted") == true)
        let onDisk = try DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root)
            .appendingPathComponent(DeleteDuplicatesPlan.planFilename))
        #expect(onDisk.entries[0].tier == .trash && onDisk.entries[0].tierReason == reason)
        let console = await consoleText(rig.model)
        #expect(console.contains("re-checked before removal") && console.contains("Trash"), Comment(rawValue: console))
    }

    /// Same fallback; the sibling AND the archive copy are removed on the
    /// first block of the re-read: only the keeper would remain → the
    /// file is put back at its original path untouched, the row is left
    /// alone (disposition kept) and names both copies; nothing left the
    /// disk.
    @Test func siblingAndArchiveRemovedDuringTheQuarantineRereadPutsTheFileBack() async throws {
        let rig = Rig("fallback-remove", keeperFixity: false); defer { rig.cleanup() }
        let sibling = try #require(rig.sibling)
        let archive = try #require(rig.archive)
        let probe = Probe()
        let siblingPath = sibling.fullPath, archivePath = archive.fullPath
        probe.onFirstBlock(of: "quarantine") {
            try? FileManager.default.removeItem(atPath: siblingPath)
            try? FileManager.default.removeItem(atPath: archivePath)
        }
        let job = rig.job(probe)
        job.start(); await job.task?.value

        #expect(probe.blocks("quarantine") == 3 && probe.didFire("quarantine"))
        let plan = try #require(job.plan)
        let row = plan.entries[0]
        #expect(row.status == .skipped && row.tier == nil && row.remainingVerifiedCopies == 1, "\(row.status): \(row.note)")
        #expect(row.note.contains("sibling verified-sibling-of-keeper.mov on ") && row.note.contains("archive copy on ")
                && row.note.contains("gone since it was counted") && row.note.contains("left alone"), Comment(rawValue: row.note))
        #expect(FileManager.default.fileExists(atPath: rig.copy.fullPath), "put back at its original path")
        #expect((try? Data(contentsOf: rig.copyURL)) == Data(rig.bytes), "untouched")
        #expect(!FileManager.default.fileExists(atPath: rig.trashedCopyURL.path))
        #expect(quarantineFolders(in: rig.dir).isEmpty)
        #expect(job.result.deleted == 0 && job.result.bytesFreed == 0)
        #expect(rig.copy.duplicateDisposition == .extraCopy, "left alone keeps the disposition")
        await rig.model.mediaLedger.waitForPendingWrites()
        let removals = rig.model.mediaLedger.allEvents().filter { $0.event == .copyTrashed || $0.event == .copyDeleted }
        #expect(removals.isEmpty, "nothing left the disk")
        let console = await consoleText(rig.model)
        #expect(console.contains("put back") && console.contains("gone since it was counted"), Comment(rawValue: console))
    }

    /// The gate itself: `finalVerdict` runs after the re-read (the block
    /// counter has reached the file's length when it is consulted) and a
    /// `.putBack` verdict restores the file, reported as cancelled — the
    /// same shape `releaseQuarantine` reports.
    @Test func finalVerdictRunsAfterTheRereadAndCanPutBack() throws {
        let dir = tempDir("gate"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<fileSize).map { UInt8($0 % 89) }
        let keeper = dir.appendingPathComponent("k.mov"); write(keeper, bytes)
        let dup = dir.appendingPathComponent("d.mov"); write(dup, bytes)
        let probe = Probe()
        let proof: VerifiedDuplicate
        switch SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: dup.path, hooks: probe.hooks) {
        case .success(let p): proof = p
        case .failure(let f): Issue.record("verify failed: \(f)"); return
        }
        guard case .quarantined(let ticket) = SignatureVerification.quarantine(proof, hooks: probe.hooks) else {
            Issue.record("quarantine failed"); return
        }
        #expect(!ticket.hashedInQuarantine)
        var blocksAtVerdict = -1
        let result = SignatureVerification.deleteQuarantined(ticket, disposal: .permanent, hooks: probe.hooks) {
            blocksAtVerdict = probe.blocks("quarantine")
            return .putBack(reason: "evidence changed before removal")
        }
        #expect(blocksAtVerdict == 3, "the verdict was asked after every block of the re-read, not before")
        #expect(result == .refused(.cancelled))
        #expect(FileManager.default.fileExists(atPath: dup.path) && (try? Data(contentsOf: dup)) == Data(bytes))
        #expect(quarantineFolders(in: dir).isEmpty)

        // And `.proceed` may lower the disposal: permanent → Trash. (A
        // fresh proof: the put-back rename changed the file's ctime, and
        // `quarantine` revalidates the proof's pre-move stamp.)
        guard case .success(let proof2) = SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: dup.path, hooks: probe.hooks),
              case .quarantined(let ticket2) = SignatureVerification.quarantine(proof2, hooks: probe.hooks) else {
            Issue.record("second verify + quarantine failed"); return
        }
        let trash = dir.appendingPathComponent("scratch-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var hooks = probe.hooks
        hooks.trashItem = { url in
            let to = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: to)
            return to
        }
        let lowered = SignatureVerification.deleteQuarantined(ticket2, disposal: .permanent, hooks: hooks) { .proceed(.trash) }
        #expect(lowered == .trashed(bytes: Int64(fileSize), location: trash.appendingPathComponent("d.mov").path))
        #expect(!FileManager.default.fileExists(atPath: dup.path))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("d.mov").path))
    }
}

// MARK: - 2. Put Back with the drive away keeps the obligation

@Suite("Codex 1619 #2 — a stranded file on a disconnected drive is never forgotten", .serialized)
@MainActor
struct DeleteDuplicatesOfflineRecoveryCodex1619Tests {

    /// A finished plan with one stranded row: the file sits in the folder
    /// the plan names, with the recorded stamp; the row is refused.
    private func strandedPlan(_ rig: Rig, target: VideoRecord) throws -> (plan: DeleteDuplicatesPlan, qdir: URL) {
        let entry = DeleteDuplicatesPlan.Entry(id: target.id, path: target.fullPath, filename: target.filename, sizeBytes: target.sizeBytes,
                                               keeperID: rig.keeper.id, keeperPath: rig.keeper.fullPath, keeperFilename: rig.keeper.filename,
                                               keeperStamp: FileIdentityStamp.capture(path: rig.keeper.fullPath))
        var plan = DeleteDuplicatesPlan(volumePath: rig.dir.path, catalogLocation: rig.model.catalogStore.fileLocation,
                                        crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "", entries: [entry])
        let qdir = rig.dir.appendingPathComponent(
            DeleteDuplicatesJob.quarantineDirectoryName(planID: plan.id, entryID: target.id), isDirectory: true)
        try FileManager.default.createDirectory(at: qdir, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: target.fullPath), to: qdir.appendingPathComponent(target.filename))
        let stamp = try #require(FileIdentityStamp.capture(path: qdir.appendingPathComponent(target.filename).path))
        plan.setQuarantined(target.id, directory: qdir.path, stamp: stamp)
        plan.set(target.id, .refused, note: "left in quarantine — not put back: the original path is occupied")
        plan.finishedAt = Date()
        plan.outcome = "completed"
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)
        return (plan, qdir)
    }

    /// The pure question: present / absent / unavailable.
    @Test func presenceDistinguishesAbsentFromUnavailable() throws {
        let volume = tempDir("presence"); defer { try? FileManager.default.removeItem(at: volume) }
        let file = volume.appendingPathComponent(".videoscan-quarantine-x/f.mov")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        write(file, [1, 2, 3])
        #expect(DeleteDuplicatesJob.strandedPresence(of: file, volumePath: volume.path, volumeName: "V") == .present)
        try FileManager.default.removeItem(at: file)
        #expect(DeleteDuplicatesJob.strandedPresence(of: file, volumePath: volume.path, volumeName: "V") == .absent,
                "the drive is here and the file is not: absent")
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        #expect(DeleteDuplicatesJob.strandedPresence(of: file, volumePath: volume.path, volumeName: "V") == .absent,
                "the folder went too — still absent on a reachable drive")
        // The drive is gone: the same stat failure is UNAVAILABLE.
        let away = URL(fileURLWithPath: volume.path + "-away")
        let sameFileOnAway = away.appendingPathComponent(".videoscan-quarantine-x/f.mov")
        let verdict = DeleteDuplicatesJob.strandedPresence(of: sameFileOnAway, volumePath: away.path, volumeName: "SanDisk")
        guard case .unavailable(let why) = verdict else { Issue.record("expected unavailable, got \(verdict)"); return }
        #expect(why.contains("SanDisk is not connected") && why.contains("reconnect it"), Comment(rawValue: why))
        // A mount point that lingers as an empty folder but is not in the
        // kernel's mount table is not "connected" either: `volume` exists,
        // its parent stands in for /Volumes/, and the table has only "/".
        let volumesRoot = volume.deletingLastPathComponent().path + "/"
        let ghost = DeleteDuplicatesJob.strandedPresence(of: file, volumePath: volume.path, volumeName: "SanDisk",
                                                         mountedRoots: ["/"], volumesRoot: volumesRoot)
        guard case .unavailable(let ghostWhy) = ghost else { Issue.record("a mount point absent from the mount table must be unavailable, got \(ghost)"); return }
        #expect(ghostWhy.contains("SanDisk is not connected"), Comment(rawValue: ghostWhy))
        #expect(DeleteDuplicatesJob.strandedPresence(of: file, volumePath: volume.path, volumeName: "SanDisk",
                                                     mountedRoots: ["/", volume.path], volumesRoot: volumesRoot) == .absent,
                "in the table and a directory: absent")
    }

    /// drive away → Put Back refused with "not connected", the row still
    /// owed, the plan not filed, Discard refused → drive back → Put Back
    /// restores the file → plan filed under done/.
    @Test func putBackWhileTheDriveIsAwayKeepsTheObligationUntilItReturns() async throws {
        let rig = Rig("offline", archiveFamily: false); defer { rig.cleanup() }
        let target = rig.copy
        let (plan, qdir) = try strandedPlan(rig, target: target)
        let planURL = DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root)
        let doneURL = DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root)
        let volumeName = rig.dir.lastPathComponent

        // The drive is disconnected: the whole volume path is gone.
        let away = URL(fileURLWithPath: rig.dir.path + "-offline")
        try FileManager.default.moveItem(at: rig.dir, to: away)
        #expect(!FileManager.default.fileExists(atPath: qdir.path))

        let launch1 = makeModel(rig.home)
        launch1.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        let offered = try #require(launch1.pendingDeleteDuplicatesResume, "offered although finished")
        #expect(offered.id == plan.id && offered.needsRecovery && !offered.isResumable)

        #expect(launch1.putBackStrandedDuplicates(root: rig.root) == 0)
        let afterPutBack = try DeleteDuplicatesPlanStore.load(url: planURL)
        #expect(afterPutBack.entries[0].needsRecovery && afterPutBack.entries[0].quarantineDirectory == qdir.path,
                "the obligation is kept: the folder is still named")
        #expect(FileManager.default.fileExists(atPath: planURL.path) && !FileManager.default.fileExists(atPath: doneURL.path),
                "the plan is not filed")
        #expect(launch1.pendingDeleteDuplicatesResume?.id == plan.id, "still offered")
        let console1 = await consoleText(launch1)
        #expect(console1.contains("\(volumeName) is not connected") && console1.contains("reconnect it"), Comment(rawValue: console1))

        launch1.discardPendingDeleteDuplicatesPlan(root: rig.root)
        #expect(FileManager.default.fileExists(atPath: planURL.path) && !FileManager.default.fileExists(atPath: doneURL.path),
                "Discard refuses while the drive cannot answer")
        #expect(launch1.pendingDeleteDuplicatesResume?.id == plan.id)
        let console2 = await consoleText(launch1)
        #expect(console2.contains("not discarded") && console2.contains("is not connected"), Comment(rawValue: console2))
        #expect(FileManager.default.fileExists(atPath: away.appendingPathComponent(qdir.lastPathComponent + "/copy1.mov").path),
                "the file is still on the drive, untouched")

        // Reconnect.
        try FileManager.default.moveItem(at: away, to: rig.dir)
        let launch2 = makeModel(rig.home)
        launch2.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        #expect(launch2.pendingDeleteDuplicatesResume?.id == plan.id)
        #expect(launch2.putBackStrandedDuplicates(root: rig.root) == 1)
        #expect(FileManager.default.fileExists(atPath: target.fullPath), "back at its original path")
        #expect((try? Data(contentsOf: URL(fileURLWithPath: target.fullPath))) == Data(rig.bytes), "byte for byte")
        #expect(!FileManager.default.fileExists(atPath: qdir.path), "the quarantine folder is gone")
        #expect(launch2.pendingDeleteDuplicatesResume == nil, "nothing left to offer")
        #expect(!FileManager.default.fileExists(atPath: planURL.path) && FileManager.default.fileExists(atPath: doneURL.path), "filed")
        let done = try DeleteDuplicatesPlanStore.load(url: doneURL.appendingPathComponent(DeleteDuplicatesPlan.planFilename))
        #expect(done.entries[0].status == .refused && done.entries[0].quarantineDirectory == nil
                && done.entries[0].note.contains("put back at \(target.fullPath)"), Comment(rawValue: done.entries[0].note))
    }

    /// With the drive HERE, a file truly gone from its folder (moved by
    /// hand) is still closed as before — the fix does not turn every
    /// absence into an obligation.
    @Test func absentFileOnAReachableDriveIsStillClosed() async throws {
        let rig = Rig("absent", archiveFamily: false); defer { rig.cleanup() }
        let (plan, qdir) = try strandedPlan(rig, target: rig.copy)
        try FileManager.default.removeItem(at: qdir)
        let launch = makeModel(rig.home)
        launch.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        #expect(launch.pendingDeleteDuplicatesResume?.id == plan.id)
        #expect(launch.putBackStrandedDuplicates(root: rig.root) == 0)
        #expect(launch.pendingDeleteDuplicatesResume == nil, "closed: nothing to put back")
        let done = try DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root)
            .appendingPathComponent(DeleteDuplicatesPlan.planFilename))
        #expect(done.entries[0].quarantineDirectory == nil && done.entries[0].note.contains("nothing to put back"))
    }
}

// MARK: - 3. An unjournaled quarantine whose restore fails is still owed

@Suite("Codex 1619 #3 — a quarantine the crash kept the plan from naming is adopted before the restore", .serialized)
@MainActor
struct DeleteDuplicatesUnjournaledQuarantineCodex1619Tests {

    /// The crash landed after the rename, before the ticket save: the
    /// plan on disk says `.pending` and names no folder; the file sits in
    /// the folder this plan + row derive.
    private func unjournaledPlan(_ rig: Rig, target: VideoRecord) throws -> (plan: DeleteDuplicatesPlan, qdir: URL) {
        let entry = DeleteDuplicatesPlan.Entry(id: target.id, path: target.fullPath, filename: target.filename, sizeBytes: target.sizeBytes,
                                               keeperID: rig.keeper.id, keeperPath: rig.keeper.fullPath, keeperFilename: rig.keeper.filename,
                                               keeperStamp: FileIdentityStamp.capture(path: rig.keeper.fullPath))
        let plan = DeleteDuplicatesPlan(volumePath: rig.dir.path, catalogLocation: rig.model.catalogStore.fileLocation,
                                        crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "", entries: [entry])
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)
        let qdir = rig.dir.appendingPathComponent(
            DeleteDuplicatesJob.quarantineDirectoryName(planID: plan.id, entryID: target.id), isDirectory: true)
        try FileManager.default.createDirectory(at: qdir, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: target.fullPath), to: qdir.appendingPathComponent(target.filename))
        return (plan, qdir)
    }

    /// unsaved ticket + occupied original → resume refuses the restore
    /// but the row NAMES the derived folder and carries the observed
    /// stamp; the plan is not filed and is offered with Put Back →
    /// obstruction removed → Put Back restores → plan filed.
    @Test func obstructedRestoreOfAnUnjournaledQuarantineStaysOffered() async throws {
        let rig = Rig("unjournaled", archiveFamily: true); defer { rig.cleanup() }
        let target = rig.copy
        let (plan, qdir) = try unjournaledPlan(rig, target: target)
        let original = URL(fileURLWithPath: target.fullPath)
        write(original, [UInt8](repeating: 0xEE, count: 100))   // the obstruction
        let quarantined = qdir.appendingPathComponent(target.filename)
        let stampInFolder = try #require(FileIdentityStamp.capture(path: quarantined.path))

        let job = DeleteDuplicatesJob(model: rig.model, resuming: plan, planRoot: rig.root)
        job.start(); await job.task?.value

        let after = try #require(job.plan)
        let row = after.entries[0]
        #expect(row.status == .refused && row.note.contains("the original path is occupied"), "\(row.status): \(row.note)")
        #expect(row.quarantineDirectory == qdir.path, "the discovered folder is on the row: \(row.quarantineDirectory ?? "nil")")
        let adopted = try #require(row.quarantinedStamp, "the observed stamp is on the row")
        #expect(DeleteDuplicatesJob.quarantineIdentityMatches(recorded: adopted, current: stampInFolder))
        #expect(row.needsRecovery && after.needsRecovery && after.strandedCount == 1)
        #expect(after.finishedAt != nil && after.isOfferable && !after.isResumable)
        #expect(FileManager.default.fileExists(atPath: quarantined.path), "still in quarantine, untouched")
        let planURL = DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root)
        let doneURL = DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root)
        #expect(FileManager.default.fileExists(atPath: planURL.path) && !FileManager.default.fileExists(atPath: doneURL.path),
                "never filed as done with the file in quarantine")
        let onDisk = try DeleteDuplicatesPlanStore.load(url: planURL)
        #expect(onDisk.entries[0].quarantineDirectory == qdir.path && onDisk.entries[0].quarantinedStamp != nil,
                "the obligation is on disk")
        #expect(job.result.deleted == 0)

        // Relaunch while the obstruction stands: offered, Put Back refuses, Discard cannot hide it.
        let launch1 = makeModel(rig.home)
        launch1.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        let offered = try #require(launch1.pendingDeleteDuplicatesResume, "discoverable")
        #expect(offered.id == plan.id && offered.resumeOffer == "1 file is on \(rig.dir.lastPathComponent) waiting to be put back from quarantine",
                Comment(rawValue: offered.resumeOffer))
        #expect(launch1.putBackStrandedDuplicates(root: rig.root) == 0)
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
        launch1.discardPendingDeleteDuplicatesPlan(root: rig.root)
        #expect(FileManager.default.fileExists(atPath: planURL.path) && launch1.pendingDeleteDuplicatesResume?.id == plan.id)

        // The obstruction goes; Put Back.
        try FileManager.default.removeItem(at: original)
        let launch2 = makeModel(rig.home)
        launch2.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        #expect(launch2.pendingDeleteDuplicatesResume?.id == plan.id)
        #expect(launch2.putBackStrandedDuplicates(root: rig.root) == 1)
        #expect(FileManager.default.fileExists(atPath: original.path), "back at its original path")
        #expect((try? Data(contentsOf: original)) == Data(rig.bytes), "the file this run put there, byte for byte")
        #expect(!FileManager.default.fileExists(atPath: qdir.path), "the quarantine folder is gone")
        #expect(launch2.pendingDeleteDuplicatesResume == nil)
        let done = try DeleteDuplicatesPlanStore.load(url: doneURL.appendingPathComponent(DeleteDuplicatesPlan.planFilename))
        #expect(done.entries[0].status == .refused, "recovery is not a verdict")
        #expect(done.entries[0].quarantineDirectory == nil && done.entries[0].note.contains("put back at \(original.path)"))
    }

    /// The other half of the same seam: an unjournaled folder whose file
    /// has the WRONG size is not adopted as ours (no stamp), the restore
    /// refuses on size, and the row still names the folder for a human.
    @Test func unjournaledFolderWithAForeignFileIsNamedButNotRestored() async throws {
        let rig = Rig("foreign", archiveFamily: true); defer { rig.cleanup() }
        let target = rig.copy
        let (plan, qdir) = try unjournaledPlan(rig, target: target)
        let quarantined = qdir.appendingPathComponent(target.filename)
        try FileManager.default.removeItem(at: quarantined)
        write(quarantined, [UInt8](repeating: 0x11, count: 10))   // not the planned size

        let job = DeleteDuplicatesJob(model: rig.model, resuming: plan, planRoot: rig.root)
        job.start(); await job.task?.value

        let row = try #require(job.plan).entries[0]
        #expect(row.status == .refused && row.note.contains("size 10 ≠ planned \(fileSize)"), "\(row.status): \(row.note)")
        #expect(row.quarantineDirectory == qdir.path && row.quarantinedStamp == nil, "named, not vouched for")
        #expect(row.needsRecovery)
        #expect(FileManager.default.fileExists(atPath: quarantined.path) && !FileManager.default.fileExists(atPath: target.fullPath),
                "nothing moved")
        let launch = makeModel(rig.home)
        launch.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        #expect(launch.pendingDeleteDuplicatesResume?.id == plan.id, "offered for a human to look at")
        #expect(launch.putBackStrandedDuplicates(root: rig.root) == 0, "Put Back refuses the foreign file")
        #expect(FileManager.default.fileExists(atPath: quarantined.path))
    }
}
