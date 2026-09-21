// DeleteDuplicatesCodex1606Tests.swift
// Regressions for codex review 1606 (snapshot ddcdc2e0) — the Delete
// Duplicates job:
//
//   1. P1 — an archive copy counts toward the tier only with CURRENT,
//      identity-bound evidence: its stamp-bound fixity must reproduce on
//      a fresh stat (ctime included) and its digest must be this
//      duplicate's. A same-size in-place rewrite of the archive (mtime
//      put back) used to still count — keeper + valid sibling + corrupt
//      archive authorised a PERMANENT removal with only two intact
//      copies left. Now it drops to the Trash and the archive is named
//      "not verified now".
//   2. P1 — "Finish this file, then quit" is a permission a later forced
//      stop REVOKES: `stopForQuit` / `cancel` clear the latch before any
//      await returns, so a stop that lands during the ticket-save await
//      (no worker to cancel) puts the file back — never phase 2.
//   3. P1 — a file a put-back could not return (original path occupied)
//      leaves a STRANDED row: the plan stays discoverable whatever its
//      `finishedAt`, the offer says "N files waiting to be put back",
//      and Put Back retries only the move home; Discard cannot hide it.
//   4. "Stop now" waits (bounded) for the put-back before the process
//      goes away, and the log says what was OBSERVED.
//
// Everything lives under the process temp dir; the Trash step is routed
// into a scratch folder.

import CryptoKit
import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dup1606_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
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
/// size) and put the mtime back — the codex 1606 harness's corruption.
/// Device / inode / size / mtime all reproduce afterwards; only the
/// kernel ctime (and the bytes) differ.
private func rewriteInPlace(_ url: URL, bytes: [UInt8]) throws {
    var before = stat()
    try #require(stat(url.path, &before) == 0)
    let fd = open(url.path, O_WRONLY)
    try #require(fd >= 0)
    defer { close(fd) }
    let wrote = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, bytes.count, 0) }
    try #require(wrote == bytes.count)
    // Put the mtime back to the NANOSECOND (`touch -r` / `rsync -t`
    // precision) — a Date round-trip would lose it and the ordinary
    // stamp would catch the rewrite by accident.
    var times = [before.st_atimespec, before.st_mtimespec]
    try #require(futimens(fd, &times) == 0)
    var after = stat()
    try #require(stat(url.path, &after) == 0)
    try #require(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
                 && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
                 && after.st_ino == before.st_ino && after.st_size == before.st_size)
}

@MainActor
private func makeModel(_ dir: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
    model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
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

/// Block counter + a per-basename barrier on the first open (thread-safe).
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [String: Int] = [:]
    var barrierFor: Set<String> = []
    private var barriers: [String: DispatchSemaphore] = [:]
    private var blockedOnce: Set<String> = []

    func blocks(_ label: String) -> Int { lock.withLock { blocks[label] ?? 0 } }
    func release(_ name: String) { lock.withLock { barriers[name] }?.signal() }
    func hasBlocked(_ name: String) -> Bool { lock.withLock { blockedOnce.contains(name) } }

    var hooks: SignatureVerification.Hooks {
        SignatureVerification.Hooks(
            shouldCancel: { Task.isCancelled },
            didReadBlock: { [self] label in lock.withLock { blocks[label, default: 0] += 1 } },
            didOpen: { [self] path in
                let name = (path as NSString).lastPathComponent
                let barrier: DispatchSemaphore? = lock.withLock {
                    guard barrierFor.contains(name), !blockedOnce.contains(name) else { return nil }
                    blockedOnce.insert(name)
                    let s = DispatchSemaphore(value: 0)
                    barriers[name] = s
                    return s
                }
                barrier?.wait()
            })
    }
}

@MainActor
private func consoleText(_ model: VideoScanModel) async -> String {
    try? await Task.sleep(nanoseconds: 300_000_000)
    return model.dashboard.consoleLines.joined(separator: "\n")
}

private func quarantineFolders(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix(SignatureVerification.quarantineDirectoryPrefix) }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool, seconds: Double = 10) async {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline, !condition() {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// keeper (stored fixity) + `copies` identical extras; optionally the
/// verified archive family (archive + sibling → 3 remain → permanent).
@MainActor
private struct Rig {
    let dir: URL
    let root: URL
    let model: VideoScanModel
    let keeper: VideoRecord
    let copies: [VideoRecord]
    let archive: VideoRecord?
    let sibling: VideoRecord?
    let bytes: [UInt8]

    init(_ label: String, copies n: Int, archiveFamily: Bool, withSibling: Bool = true) {
        dir = tempDir(label)
        root = dir.appendingPathComponent("plans", isDirectory: true)
        bytes = (0..<fileSize).map { UInt8($0 % 193) }
        let keeperURL = dir.appendingPathComponent("keeper.mov"); write(keeperURL, bytes)
        let group = UUID()
        model = makeModel(dir)
        keeper = dupRecord(path: keeperURL.path, size: Int64(fileSize), group: group, disposition: .keep)
        keeper.contentFixity = ContentFixity.captured(path: keeperURL.path, digest: plainSHA256(keeperURL), byteCount: Int64(fileSize))
        var made: [VideoRecord] = []
        for i in 0..<n {
            let c = dir.appendingPathComponent("copy\(i + 1).mov"); write(c, bytes)
            made.append(dupRecord(path: c.path, size: Int64(fileSize), group: group, disposition: .extraCopy))
        }
        copies = made
        model.records = [keeper] + made
        if archiveFamily {
            let family = addVerifiedArchiveFamily(to: model, keeper: keeper, withSibling: withSibling)
            archive = family.archive
            sibling = family.sibling
        } else {
            archive = nil
            sibling = nil
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

// MARK: - 1. The archive copy needs current, identity-bound evidence

@Suite("Codex 1606 #1 — an archive copy counts only with current evidence")
struct DeletionTierArchiveEvidenceCodex1606Tests {

    /// The pure gather: an archive copy with a stamp-bound fixity counts;
    /// after a same-size in-place rewrite (mtime put back, records
    /// untouched) it does not, and is named "not verified now"; one that
    /// only ever had the promote-time digest never counts.
    @Test func sameSizeRewriteOfTheArchiveStopsItCounting() throws {
        let dir = tempDir("gather"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<4_096).map { UInt8($0 % 11) }
        let archive = dir.appendingPathComponent("archive.mov"); write(archive, bytes)
        let sibling = dir.appendingPathComponent("sibling.mov"); write(sibling, bytes)
        let digest = plainSHA256(archive)
        let archiveFixity = try #require(ContentFixity.captured(path: archive.path, digest: digest, byteCount: 4_096))

        var c = DeletionTierCandidates()
        c.keeperLabel = "keeper on LaCieWorkspace"
        c.archiveCopies = [.init(path: archive.path, digest: digest, sizeBytes: 4_096, fixity: archiveFixity,
                                 label: "archive copy on FamilyArchive")]
        c.otherCopies = [.init(path: sibling.path, fixity: ContentFixity.captured(path: sibling.path, digest: digest, byteCount: 4_096),
                               label: "sibling sibling.mov on SanDisk")]
        let before = DeletionTierFacts.gather(c, digest: digest)
        #expect(before.remainingVerifiedCopies == 3 && before.counted.contains("archive copy on FamilyArchive"))
        #expect(DeletionTierDecision.decide(facts: before, preferTrash: false).tier == .permanent)

        // The corruption: same inode, same size, mtime put back; only the
        // bytes and the kernel ctime differ. Nothing on record changes.
        var corrupt = bytes; corrupt[2_000] ^= 0x5A
        try rewriteInPlace(archive, bytes: corrupt)
        #expect(archiveFixity.stampMatches(path: archive.path), "the user-visible stamp still reproduces — only ctime tells")

        let after = DeletionTierFacts.gather(c, digest: digest)
        #expect(after.remainingVerifiedCopies == 2, "keeper + sibling; the archive is out: \(after.summary)")
        #expect(after.counted == ["keeper on LaCieWorkspace", "sibling sibling.mov on SanDisk"])
        #expect(after.notCounted == ["archive copy on FamilyArchive not verified now (changed since it was verified)"])
        #expect(after.hasVerifiedArchive, "on record the family is archived — informational only")
        let d = DeletionTierDecision.decide(facts: after, preferTrash: false)
        #expect(d.tier == .trash && d.reason.contains("archive copy on FamilyArchive not verified now"), Comment(rawValue: d.reason))

        // Promote-time digest only (no stamp-bound fixity): named, never counted.
        var unaudited = DeletionTierCandidates()
        unaudited.archiveCopies = [.init(path: sibling.path, digest: digest, sizeBytes: 4_096, label: "archive copy on Pegasus")]
        let u = DeletionTierFacts.gather(unaudited, digest: digest)
        #expect(u.remainingVerifiedCopies == 1 && u.hasVerifiedArchive)
        #expect(u.notCounted == ["archive copy on Pegasus not verified now (no stamp-bound fixity — run Verify Archive Copies)"])
        #expect(DeletionTierDecision.decide(facts: u, preferTrash: false).tier == nil)
    }

    /// The job: keeper + valid sibling + an archive rewritten in place the
    /// same size → the Trash (two verified remain), never permanent; the
    /// row's reason names the archive as not verified now.
    @Test @MainActor func corruptArchiveDropsTheTierToTheTrash() async throws {
        let rig = Rig("corrupt-archive", copies: 1, archiveFamily: true); defer { rig.cleanup() }
        let archive = try #require(rig.archive)
        var corrupt = rig.bytes; corrupt[blockSize + 77] ^= 0x33
        try rewriteInPlace(URL(fileURLWithPath: archive.fullPath), bytes: corrupt)
        #expect(archive.archiveFixity?.sizeBytes == Int64(fileSize), "size on record unchanged")
        #expect(archive.contentFixity?.stampMatches(path: archive.fullPath) == true, "user-visible stamp unchanged")

        let probe = Probe()
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: probe.hooks.withScratchTrash(in: rig.dir), planRoot: rig.root)
        job.start(); await job.task?.value

        let plan = try #require(job.plan)
        let row = plan.entries[0]
        #expect(row.status == .trashed && row.tier == .trash, "\(row.status): \(row.tierReason ?? "")")
        #expect(row.remainingVerifiedCopies == 2)
        let reason = try #require(row.tierReason)
        #expect(reason.hasPrefix("only two verified copies would remain — to the Trash"), Comment(rawValue: reason))
        #expect(reason.contains("archive copy on ") && reason.contains("not verified now (changed since it was verified)"), Comment(rawValue: reason))
        #expect(reason.contains("sibling verified-sibling-of-keeper.mov on "))
        #expect(!FileManager.default.fileExists(atPath: rig.copies[0].fullPath))
        #expect(FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("Trash/copy1.mov").path),
                "to the Trash, not gone: only two intact copies remain")
        #expect(job.result.bytesFreed == 0 && job.result.deleted == 1)
        #expect(FileManager.default.fileExists(atPath: archive.fullPath), "the archive itself is never touched")
        await rig.model.mediaLedger.waitForPendingWrites()
        let events = rig.model.mediaLedger.allEvents().filter { $0.event == .copyTrashed }
        #expect(events.count == 1 && events.first?.detail[MediaLedgerEvent.Detail.remainingVerifiedCopies] == "2")
    }

    /// An archive copy straight from promotion (digest on record, no
    /// stamp-bound fixity yet) does not count: keeper + it → 1 remain →
    /// left alone, by stat, before a byte is read; the row says why.
    @Test @MainActor func promotedButUnauditedArchiveDoesNotCount() async throws {
        let rig = Rig("unaudited", copies: 1, archiveFamily: true, withSibling: false); defer { rig.cleanup() }
        let archive = try #require(rig.archive)
        archive.contentFixity = nil        // the promote-time state
        let probe = Probe()
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: rig.root)
        job.start(); await job.task?.value

        let plan = try #require(job.plan)
        let row = plan.entries[0]
        #expect(row.status == .skipped && row.tier == nil && row.remainingVerifiedCopies == 1, "\(row.status): \(row.note)")
        #expect(row.note.contains("archive copy on ") && row.note.contains("not verified now (no stamp-bound fixity — run Verify Archive Copies)"),
                Comment(rawValue: row.note))
        #expect(row.hasVerifiedArchive == true, "archived on record — the label must not say 'not yet archived'")
        #expect(!row.tierLabel.contains(DeletionTierText.notYetArchived))
        #expect(FileManager.default.fileExists(atPath: rig.copies[0].fullPath))
        #expect(probe.blocks("quarantine") == 0, "settled by stat, nothing read")
    }
}

// MARK: - 2. A forced stop revokes "finish this file"

@Suite("Codex 1606 #2 — a forced stop after 'finish this file' puts the file back", .serialized)
@MainActor
struct DeleteDuplicatesQuitLatchCodex1606Tests {

    /// The escalation lands EXACTLY during the ticket-save await: finish
    /// was granted, then the deadline / "Stop now" revokes it. No worker
    /// is running to cancel; the cleared latch is what stops phase 2.
    @Test func forcedStopDuringTheTicketSaveRevokesFinishAndRestores() async throws {
        for how in ["stopForQuit", "cancel"] {
            let rig = Rig("latch-\(how)", copies: 1, archiveFamily: true); defer { rig.cleanup() }
            let probe = Probe()
            let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                          hooks: probe.hooks.withScratchTrash(in: rig.dir), planRoot: rig.root)
            job.testHookAfterQuarantineSaved = { [weak job] _ in
                job?.finishCurrentFileThenSuspendForQuit()
                #expect(job?.finishInFlightForQuit == true)
                if how == "stopForQuit" { job?.stopForQuit() } else { job?.cancel() }
                #expect(job?.finishInFlightForQuit == false, "\(how) revokes the permission at once")
            }
            job.start(); await job.task?.value

            let path = rig.copies[0].fullPath
            #expect(job.state == .cancelled, "\(how): \(job.state)")
            #expect(job.finishInFlightForQuit == false)
            #expect(FileManager.default.fileExists(atPath: path), "\(how): put back, never unlinked")
            #expect((try? Data(contentsOf: URL(fileURLWithPath: path))) == Data(rig.bytes))
            #expect(!FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("Trash/copy1.mov").path))
            #expect(quarantineFolders(in: rig.dir).isEmpty)
            #expect(probe.blocks("quarantine") == 3, "the one read happened; phase 2 did not")
            #expect(job.result.deleted == 0)
            let plan = try #require(job.plan)
            #expect(plan.entries[0].status == .pending && plan.entries[0].quarantineDirectory == nil,
                    "\(how): \(plan.entries[0].status) — \(plan.entries[0].note)")
            #expect(plan.isResumable && plan.finishedAt == nil)
            let onDisk = try DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root))
            #expect(onDisk.entries[0].status == .pending && onDisk.outcome == nil, "\(how): resumable on disk")
            #expect(job.interruptedFileOutcomes == ["put back copy1.mov at \(path)"], "\(job.interruptedFileOutcomes)")
            #expect(job.quitOutcomeLine.contains("settled") && job.quitOutcomeLine.contains("put back copy1.mov at \(path)"),
                    Comment(rawValue: job.quitOutcomeLine))
        }
    }

    /// The quit deadline path: finish granted, the file still being read
    /// when the deadline fires → `stopForQuit` revokes finish and cancels
    /// the read; the file is put back and the observed outcome is on the
    /// center, not a promise.
    @Test func theQuitDeadlineRevokesFinishWhileTheFileIsStillBeingRead() async throws {
        let rig = Rig("deadline", copies: 2, archiveFamily: true); defer { rig.cleanup() }
        let center = MediaFileOperationsCenter()
        let probe = Probe()
        probe.barrierFor = ["copy1.mov"]
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: probe.hooks.withScratchTrash(in: rig.dir), planRoot: rig.root)
        _ = center.add(job)
        job.start()
        await waitUntil { probe.hasBlocked("copy1.mov") }
        #expect(center.hasDeleteDuplicatesMidPair)

        center.finishInFlightThenSuspendForQuit()
        #expect(job.finishInFlightForQuit && job.quitRequested)
        async let settled = center.waitForDeleteDuplicatesToSettle(deadline: 0.4, grace: 10)
        await waitUntil { !job.finishInFlightForQuit }
        #expect(job.quitRequested && job.state == .cancelling, "the deadline revoked finish")
        probe.release("copy1.mov")
        let inTime = await settled

        #expect(!inTime && job.state == .cancelled, "\(job.state)")
        #expect(FileManager.default.fileExists(atPath: rig.copies[0].fullPath), "put back")
        #expect(FileManager.default.fileExists(atPath: rig.copies[1].fullPath), "never started")
        #expect(quarantineFolders(in: rig.dir).isEmpty)
        #expect(job.result.deleted == 0)
        let plan = try #require(job.plan)
        #expect(plan.entries.map(\.status) == [.pending, .pending] && plan.isResumable)
        let lines = center.deleteDuplicatesQuitOutcomeLines
        #expect(lines.count == 1 && lines[0].contains("settled") && lines[0].contains("put back copy1.mov at \(rig.copies[0].fullPath)"),
                Comment(rawValue: lines.joined(separator: " | ")))
    }
}

// MARK: - 3. A stranded file is offered a put-back

@Suite("Codex 1606 #3 — a stranded quarantine stays discoverable and is put back", .serialized)
@MainActor
struct DeleteDuplicatesStrandedRecoveryCodex1606Tests {

    /// A plan with one row in quarantine (the crash), the file in the
    /// folder the plan names with the recorded stamp.
    private func crashedPlan(_ rig: Rig, target: VideoRecord) throws -> (plan: DeleteDuplicatesPlan, qdir: URL) {
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
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)
        return (plan, qdir)
    }

    /// obstruction → resume refuses the restore (stranded) → obstruction
    /// removed → relaunch → OFFERED as "1 file waiting to be put back"
    /// → Put Back → the file is at its original path, the plan is filed.
    @Test func obstructedRestoreIsOfferedAgainAfterRelaunchAndPutBack() async throws {
        let rig = Rig("obstructed", copies: 1, archiveFamily: true); defer { rig.cleanup() }
        let target = rig.copies[0]
        let (plan, qdir) = try crashedPlan(rig, target: target)
        let original = URL(fileURLWithPath: target.fullPath)
        // The obstruction: something else now sits at the original path.
        write(original, [UInt8](repeating: 0xEE, count: 100))

        let job = DeleteDuplicatesJob(model: rig.model, resuming: plan, planRoot: rig.root)
        job.start(); await job.task?.value

        let after = try #require(job.plan)
        #expect(after.entries[0].status == .refused && after.entries[0].note.contains("the original path is occupied"),
                "\(after.entries[0].status): \(after.entries[0].note)")
        #expect(after.entries[0].needsRecovery && after.needsRecovery && after.strandedCount == 1)
        #expect(after.finishedAt != nil, "the run is over — and that must not hide the file")
        #expect(after.isOfferable && !after.isResumable)
        #expect(FileManager.default.fileExists(atPath: qdir.appendingPathComponent("copy1.mov").path), "still in quarantine")
        let planURL = DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root)
        #expect(FileManager.default.fileExists(atPath: planURL.path) && !FileManager.default.fileExists(atPath: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root).path))

        // While the obstruction stands: the offer is there, Put Back refuses, Discard cannot hide it.
        let relaunch1 = makeModel(rig.dir)
        relaunch1.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        let offered1 = try #require(relaunch1.pendingDeleteDuplicatesResume, "discoverable although finished")
        #expect(offered1.id == plan.id && offered1.resumeOffer == "1 file is on \(rig.dir.lastPathComponent) waiting to be put back from quarantine",
                Comment(rawValue: offered1.resumeOffer))
        #expect(relaunch1.putBackStrandedDuplicates(root: rig.root) == 0)
        #expect(FileManager.default.fileExists(atPath: qdir.appendingPathComponent("copy1.mov").path), "the obstruction still stands: nothing moved")
        #expect(relaunch1.pendingDeleteDuplicatesResume?.id == plan.id, "still offered")
        relaunch1.discardPendingDeleteDuplicatesPlan(root: rig.root)
        #expect(FileManager.default.fileExists(atPath: planURL.path), "Discard does not file a plan with a stranded file")
        #expect(relaunch1.pendingDeleteDuplicatesResume?.id == plan.id)
        let console1 = await consoleText(relaunch1)
        #expect(console1.contains("waiting to be put back") && console1.contains("not discarded"), Comment(rawValue: console1))

        // The obstruction goes; relaunch; Put Back.
        try FileManager.default.removeItem(at: original)
        let relaunch2 = makeModel(rig.dir)
        relaunch2.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        let offered2 = try #require(relaunch2.pendingDeleteDuplicatesResume)
        #expect(offered2.id == plan.id && offered2.needsRecovery && !offered2.isResumable)
        #expect(DeleteDuplicatesPlanStore.unfinishedPlans(root: rig.root, log: { _ in }).map(\.id) == [plan.id])

        #expect(relaunch2.putBackStrandedDuplicates(root: rig.root) == 1)
        #expect(FileManager.default.fileExists(atPath: original.path), "back at its original path")
        #expect((try? Data(contentsOf: original)) == Data(rig.bytes), "the file this run put there, byte for byte")
        #expect(!FileManager.default.fileExists(atPath: qdir.path), "the quarantine folder is gone")
        #expect(relaunch2.pendingDeleteDuplicatesResume == nil, "nothing left to offer")
        #expect(DeleteDuplicatesPlanStore.unfinishedPlans(root: rig.root, log: { _ in }).isEmpty)
        let done = try DeleteDuplicatesPlanStore.load(
            url: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root).appendingPathComponent("plan.json"))
        #expect(done.entries[0].status == .refused, "recovery is not a verdict — the row stays what the run decided")
        #expect(done.entries[0].quarantineDirectory == nil && done.entries[0].note.contains("put back at \(original.path)"),
                Comment(rawValue: done.entries[0].note))
        #expect(done.log.contains { $0.contains("put back at") })
        let console2 = await consoleText(relaunch2)
        #expect(console2.contains("Put back copy1.mov at \(original.path)") && console2.contains("the plan is filed"), Comment(rawValue: console2))
    }

    /// A resume retries the stranded rows first — the move home only; a
    /// settled row never re-enters the run.
    @Test func resumePutsStrandedRowsBackBeforeTheRest() async throws {
        let rig = Rig("resume-stranded", copies: 2, archiveFamily: true); defer { rig.cleanup() }
        let stranded = rig.copies[0]
        let pending = rig.copies[1]
        func entry(_ r: VideoRecord) -> DeleteDuplicatesPlan.Entry {
            DeleteDuplicatesPlan.Entry(id: r.id, path: r.fullPath, filename: r.filename, sizeBytes: r.sizeBytes,
                                       keeperID: rig.keeper.id, keeperPath: rig.keeper.fullPath, keeperFilename: rig.keeper.filename,
                                       keeperStamp: FileIdentityStamp.capture(path: rig.keeper.fullPath))
        }
        var plan = DeleteDuplicatesPlan(volumePath: rig.dir.path, catalogLocation: rig.model.catalogStore.fileLocation,
                                        crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "",
                                        entries: [entry(stranded), entry(pending)])
        let qdir = rig.dir.appendingPathComponent(
            DeleteDuplicatesJob.quarantineDirectoryName(planID: plan.id, entryID: stranded.id), isDirectory: true)
        try FileManager.default.createDirectory(at: qdir, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: stranded.fullPath), to: qdir.appendingPathComponent(stranded.filename))
        let stamp = try #require(FileIdentityStamp.capture(path: qdir.appendingPathComponent(stranded.filename).path))
        plan.setQuarantined(stranded.id, directory: qdir.path, stamp: stamp)
        // The earlier run settled the row as refused with the file still there.
        plan.set(stranded.id, .refused, note: "left in quarantine at \(qdir.path) — not put back: the original path is occupied")
        #expect(plan.entries[0].needsRecovery && plan.isResumable && plan.isOfferable)
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)

        let job = DeleteDuplicatesJob(model: rig.model, resuming: plan, hooks: SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir),
                                      planRoot: rig.root)
        job.start(); await job.task?.value

        let after = try #require(job.plan)
        #expect(after.entries[0].status == .refused && after.entries[0].quarantineDirectory == nil, "\(after.entries[0].note)")
        #expect(after.entries[0].note.hasSuffix("— put back at \(stranded.fullPath)"), Comment(rawValue: after.entries[0].note))
        #expect(FileManager.default.fileExists(atPath: stranded.fullPath) && !FileManager.default.fileExists(atPath: qdir.path))
        #expect(after.entries[1].status == .deleted, "\(after.entries[1].status): \(after.entries[1].note)")
        #expect(!after.needsRecovery && after.finishedAt != nil)
        #expect(FileManager.default.fileExists(
            atPath: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root).appendingPathComponent("plan.json").path),
            "nothing stranded — filed as done")
        #expect(job.result.deleted == 1)
    }

    /// The plan-level rule, in isolation: settled + folder named =
    /// recovery needed; offerable whatever `finishedAt` says; `.verified`
    /// (in flight) is not recovery.
    @Test func recoveryStateIsDerivedFromASettledRowThatStillNamesItsFolder() {
        var plan = DeleteDuplicatesPlan(volumePath: "/Volumes/SanDisk", catalogLocation: "/c", crossVolumeMode: false,
                                        skippedBeforePlan: 0, summaryLine: "", entries: [
            DeleteDuplicatesPlan.Entry(id: UUID(), path: "/Volumes/SanDisk/a.mov", filename: "a.mov", sizeBytes: 1,
                                       keeperID: UUID(), keeperPath: "/k", keeperFilename: "k", keeperStamp: nil),
            DeleteDuplicatesPlan.Entry(id: UUID(), path: "/Volumes/SanDisk/b.mov", filename: "b.mov", sizeBytes: 1,
                                       keeperID: UUID(), keeperPath: "/k", keeperFilename: "k", keeperStamp: nil)])
        let a = plan.entries[0].id, b = plan.entries[1].id
        let stamp = FileIdentityStamp(device: 1, inode: 2, size: 1, mtimeNs: 3, ctimeNs: 4)
        plan.setQuarantined(a, directory: "/Volumes/SanDisk/.videoscan-quarantine-x", stamp: stamp)
        #expect(!plan.entries[0].needsRecovery, "in flight is the resume's business")
        #expect(plan.entries[0].quarantinedFileURL?.path == "/Volumes/SanDisk/.videoscan-quarantine-x/a.mov")
        plan.set(a, .refused, note: "occupied")
        plan.set(b, .deleted)
        #expect(plan.entries[0].needsRecovery && plan.strandedCount == 1 && plan.needsRecovery)
        #expect(!plan.isResumable && plan.isOfferable)
        #expect(plan.resumeOffer == "1 file is on SanDisk waiting to be put back from quarantine", Comment(rawValue: plan.resumeOffer))
        plan.finishedAt = Date(); plan.outcome = "completed"
        #expect(plan.isOfferable, "finished does not hide it")
        plan.markRecovered(a, note: "put back at /Volumes/SanDisk/a.mov")
        #expect(!plan.entries[0].needsRecovery && !plan.isOfferable && plan.entries[0].status == .refused)
        #expect(plan.entries[0].note == "occupied — put back at /Volumes/SanDisk/a.mov")
        // Both: resumable AND stranded.
        var both = plan
        both.finishedAt = nil
        both.set(b, .pending)
        both.setQuarantined(a, directory: "/q", stamp: stamp); both.set(a, .failed, note: "retained")
        #expect(both.isResumable && both.needsRecovery)
        #expect(both.resumeOffer == "Resume deleting duplicates on SanDisk — 1 of 2 remaining? 1 file is on SanDisk waiting to be put back from quarantine.",
                Comment(rawValue: both.resumeOffer))
    }
}

// MARK: - 4. "Stop now" waits for the put-back and logs what it saw

@Suite("Codex 1606 — 'Stop now' waits for the put-back and reports the observed outcome", .serialized)
@MainActor
struct DeleteDuplicatesStopNowCodex1606Tests {

    @Test func stopNowWaitsForThePutBackAndReportsWhatItSaw() async throws {
        let rig = Rig("stopnow", copies: 2, archiveFamily: true); defer { rig.cleanup() }
        let center = MediaFileOperationsCenter()
        let idle = await center.waitForDeleteDuplicatesToStop(deadline: 1)
        #expect(idle, "nothing active: at once")
        let probe = Probe()
        probe.barrierFor = ["copy1.mov"]
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: probe.hooks.withScratchTrash(in: rig.dir), planRoot: rig.root)
        _ = center.add(job)
        job.start()
        await waitUntil { probe.hasBlocked("copy1.mov") }

        center.stopAllForQuit()                       // the quit guard's "Stop now"
        #expect(job.state == .cancelling && job.quitRequested)
        // Bounded: the read is still held, so the wait times out honestly
        // and the line says the file has not settled.
        let tooSoon = await center.waitForDeleteDuplicatesToStop(deadline: 0.3)
        #expect(tooSoon == false)
        let early = center.deleteDuplicatesQuitOutcomeLines
        #expect(early.count == 1 && early[0].contains("still settling") && early[0].contains("no file has settled yet"),
                Comment(rawValue: early.joined()))

        async let stopped = center.waitForDeleteDuplicatesToStop(deadline: 10)
        probe.release("copy1.mov")
        let inTime = await stopped
        #expect(inTime, "the put-back and the plan save were awaited")
        #expect(job.state == .cancelled)
        #expect(FileManager.default.fileExists(atPath: rig.copies[0].fullPath), "put back before the process could go away")
        #expect(quarantineFolders(in: rig.dir).isEmpty)
        let plan = try #require(job.plan)
        let onDisk = try DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root))
        #expect(onDisk.entries.map(\.status) == [.pending, .pending] && onDisk.outcome == nil, "the plan is on disk, resumable")
        let lines = center.deleteDuplicatesQuitOutcomeLines
        #expect(lines.count == 1 && lines[0].contains("settled at 0 of 2") && lines[0].contains("put back copy1.mov at \(rig.copies[0].fullPath)"),
                Comment(rawValue: lines.joined()))
        #expect(job.quitOutcomeLine.hasSuffix("plan kept for resume"))
    }
}
