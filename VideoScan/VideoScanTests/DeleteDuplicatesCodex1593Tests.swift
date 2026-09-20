// DeleteDuplicatesCodex1593Tests.swift
// Regressions for codex review 1593 (snapshot 6cd71264) — the Delete
// Duplicates job. Two reproduced data-loss cases first, then one pinning
// test per remaining finding:
//
//   1. a same-length rewrite through an open descriptor after quarantine,
//      mtime put back, must be REFUSED — never deleted
//   2. orphan recovery restores only from the folder the plan recorded and
//      never removes a folder with anything else in it
//   3. every pair is re-authorised LIVE before dispatch (after a pause)
//   4. a retained live row whose path changed during the await is never
//      tombstoned; the ledger line carries the pre-await facts
//   5. Quit suspends the run and leaves the plan resumable
//   6. a failed final save leaves the last good plan in place, not in done/
//   7. Verify Archive's invalidation clears contentFixity too
//   8. the next unfinished plan is offered after Discard / after a resume
//      completes, in the same session
//
// Everything lives under the process temp dir; nothing touches App
// Support.

import CryptoKit
import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dup1593_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
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

/// Counts reads by label and opens by path (thread-safe).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [String: Int] = [:]
    private var opens: [String: Int] = [:]
    func blocks(_ label: String) -> Int { lock.withLock { blocks[label] ?? 0 } }
    func opens(of path: String) -> Int { lock.withLock { opens[path] ?? 0 } }
    func hooks(didQuarantine: ((String) -> Void)? = nil) -> SignatureVerification.Hooks {
        SignatureVerification.Hooks(
            shouldCancel: { false },
            didReadBlock: { [self] label in lock.withLock { blocks[label, default: 0] += 1 } },
            didOpen: { [self] path in lock.withLock { opens[path, default: 0] += 1 } },
            didQuarantine: didQuarantine)
    }
}

/// Rewrite `size` bytes through an ALREADY OPEN descriptor and put the
/// mtime back — the codex repro's writer. Device/inode/size/mtime all
/// still match afterwards; only the kernel ctime (and the bytes) differ.
private func rewriteThroughDescriptor(_ fd: Int32, path: String, bytes: [UInt8], restoreMtime: Date) {
    let wrote = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, bytes.count, 0) }
    precondition(wrote == bytes.count)
    try? FileManager.default.setAttributes([.modificationDate: restoreMtime], ofItemAtPath: path)
}

// MARK: - 1. The gate: post-quarantine rewrite through an open descriptor

@Suite("Codex 1593 — post-quarantine rewrite is refused")
struct SignatureVerificationCodex1593Tests {

    private let size = 8 * 1024
    private let wholeSecond = Date(timeIntervalSince1970: 1_600_000_000)

    /// CODEX REPRO #1 (exact shape): keeper A and target A, stored keeper
    /// fixity, an fd on the target opened BEFORE the run; `didQuarantine`
    /// writes B through it and restores the mtime. On 6cd71264 the four
    /// remaining fields matched and the (now unique) B bytes were deleted.
    @Test func rewriteThroughOpenDescriptorAfterQuarantineIsRefusedNotDeleted() throws {
        let dir = tempDir("repro1"); defer { try? FileManager.default.removeItem(at: dir) }
        let a = [UInt8](repeating: 0x41, count: size)
        let b = [UInt8](repeating: 0x42, count: size)
        let keeper = dir.appendingPathComponent("keeper.bin"); write(keeper, a)
        let target = dir.appendingPathComponent("target.bin"); write(target, a)
        try FileManager.default.setAttributes([.modificationDate: wholeSecond], ofItemAtPath: target.path)
        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper),
                                                          byteCount: Int64(size)))
        let fd = open(target.path, O_WRONLY)
        #expect(fd >= 0)
        defer { close(fd) }

        let counter = Counter()
        let proof = try SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: fixity, duplicatePath: target.path,
            hooks: counter.hooks()).get()
        #expect(proof.keeperReadInFull == false)

        let hooks = counter.hooks(didQuarantine: { quarantinedPath in
            rewriteThroughDescriptor(fd, path: quarantinedPath, bytes: b, restoreMtime: self.wholeSecond)
        })
        let result = SignatureVerification.quarantineAndDelete(proof, hooks: hooks)

        if case .deleted = result {
            Issue.record("the rewritten (unique) bytes were deleted — codex 1593 blocker 1")
        }
        #expect(result == .refused(.changedSinceVerification(target.path)), "\(result)")
        #expect(FileManager.default.fileExists(atPath: target.path), "the file is put back")
        #expect((try? Data(contentsOf: target)) == Data(b), "and it holds the NEW bytes — nothing was lost")
        #expect((try? Data(contentsOf: keeper)) == Data(a))
        #expect(counter.blocks("keeper") == 0, "the keeper is still never read")
        #expect(counter.opens(of: keeper.path) == 0)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(!leftovers.contains { $0.hasPrefix(SignatureVerification.quarantineDirectoryPrefix) },
                "the empty quarantine folder is gone: \(leftovers)")
    }

    /// The ticket's baseline is the FULL stamp (ctime included) taken after
    /// the rename, and the unlink step re-reads the file: a rewrite after
    /// the ticket was issued is refused by both.
    @Test func ticketBaselineIncludesCtimeAndTheUnlinkStepRehashes() throws {
        let dir = tempDir("ticket"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 251) }
        var other = bytes; other[size / 2] ^= 0xFF
        let keeper = dir.appendingPathComponent("keeper.bin"); write(keeper, bytes)
        let target = dir.appendingPathComponent("target.bin"); write(target, bytes)
        try FileManager.default.setAttributes([.modificationDate: wholeSecond], ofItemAtPath: target.path)
        let fd = open(target.path, O_WRONLY)
        #expect(fd >= 0)
        defer { close(fd) }

        let proof = try SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: target.path).get()
        guard case .quarantined(let ticket) = SignatureVerification.quarantine(proof) else {
            Issue.record("quarantine failed"); return
        }
        #expect(ticket.baseline.hasChangeTime)
        #expect(FileManager.default.fileExists(atPath: ticket.quarantinedPath))
        #expect(ticket.quarantineDirectory.hasPrefix(dir.path))

        // Writer strikes between the ticket and the unlink.
        rewriteThroughDescriptor(fd, path: ticket.quarantinedPath, bytes: other, restoreMtime: wholeSecond)
        let now = try #require(FileIdentityStamp.capture(path: ticket.quarantinedPath))
        #expect(now.matchesIgnoringChangeTime(ticket.baseline), "precondition: the four user-settable fields reproduce")
        #expect(now.ctimeNs != ticket.baseline.ctimeNs, "precondition: only the kernel ctime moved")

        let counter = Counter()
        let result = SignatureVerification.deleteQuarantined(ticket, hooks: counter.hooks())
        #expect(result == .refused(.changedSinceVerification(target.path)), "\(result)")
        #expect((try? Data(contentsOf: target)) == Data(other), "put back with the new bytes")
        #expect(!FileManager.default.fileExists(atPath: ticket.quarantineDirectory))

        // Happy path: the unlink step reads the file once more, in full.
        let target2 = dir.appendingPathComponent("target2.bin"); write(target2, bytes)
        let proof2 = try SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: target2.path).get()
        let counter2 = Counter()
        #expect(SignatureVerification.quarantineAndDelete(proof2, hooks: counter2.hooks()) == .deleted(bytes: Int64(size)))
        #expect(counter2.blocks("quarantine") == 1, "one 8 KiB block re-read in quarantine before the unlink")
        #expect(counter2.blocks("keeper") == 0 && counter2.opens(of: keeper.path) == 0)
        #expect(!FileManager.default.fileExists(atPath: target2.path))
    }

    /// A quarantine folder is removed with rmdir only: anything else in it
    /// survives both the delete and the restore paths.
    @Test func quarantineFolderIsNeverRemovedRecursively() throws {
        let dir = tempDir("rmdir"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 13) }
        let keeper = dir.appendingPathComponent("keeper.bin"); write(keeper, bytes)

        // Delete path.
        let t1 = dir.appendingPathComponent("t1.bin"); write(t1, bytes)
        let p1 = try SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: t1.path).get()
        guard case .quarantined(let ticket1) = SignatureVerification.quarantine(p1) else { Issue.record("no ticket"); return }
        let stranger1 = URL(fileURLWithPath: ticket1.quarantineDirectory).appendingPathComponent("unrelated-unique.bin")
        write(stranger1, [9, 9, 9])
        #expect(SignatureVerification.deleteQuarantined(ticket1) == .deleted(bytes: Int64(size)))
        #expect(!FileManager.default.fileExists(atPath: t1.path))
        #expect(FileManager.default.fileExists(atPath: stranger1.path), "the unrelated file survives the delete")
        #expect(FileManager.default.fileExists(atPath: ticket1.quarantineDirectory), "the non-empty folder is left in place")

        // Restore path.
        let t2 = dir.appendingPathComponent("t2.bin"); write(t2, bytes)
        let p2 = try SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: t2.path).get()
        guard case .quarantined(let ticket2) = SignatureVerification.quarantine(p2) else { Issue.record("no ticket"); return }
        let stranger2 = URL(fileURLWithPath: ticket2.quarantineDirectory).appendingPathComponent("unrelated-unique.bin")
        write(stranger2, [8, 8, 8])
        #expect(SignatureVerification.releaseQuarantine(ticket2, reason: "test") == .refused(.cancelled))
        #expect(FileManager.default.fileExists(atPath: t2.path), "put back")
        #expect(FileManager.default.fileExists(atPath: stranger2.path), "the unrelated file survives the restore")
        #expect(FileManager.default.fileExists(atPath: ticket2.quarantineDirectory))
    }

    /// The read-once metric now counts every OPEN of the keeper path — the
    /// head compare included — not just full-hash blocks.
    @Test func didOpenCountsTheHeadCompareAsAKeeperRead() throws {
        let dir = tempDir("opens"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 17) }
        let keeper = dir.appendingPathComponent("keeper.bin"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.bin"); write(copy, bytes)

        let two = Counter()
        _ = try SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: copy.path, hooks: two.hooks()).get()
        #expect(two.opens(of: keeper.path) == 2, "two-file path: head compare + full hash")
        #expect(two.opens(of: copy.path) == 2)

        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper), byteCount: Int64(size)))
        let one = Counter()
        _ = try SignatureVerification.verifyAgainstStoredKeeper(keeperPath: keeper.path, keeperFixity: fixity,
                                                                duplicatePath: copy.path, hooks: one.hooks()).get()
        #expect(one.opens(of: keeper.path) == 0, "stored-keeper path: the keeper is never opened")
        #expect(one.opens(of: copy.path) == 1)
    }
}

// MARK: - Job-level fixtures

@MainActor
private func makeModel(_ dir: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
    model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
    return model
}

@MainActor
private func dupRecord(id: UUID = UUID(), path: String, size: Int64, group: UUID,
                       disposition: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord(id: id)
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

private let blockSize = FileHasher.segmentSize
private let fileSize = blockSize * 3

@MainActor
private func consoleText(_ model: VideoScanModel) async -> String {
    try? await Task.sleep(nanoseconds: 400_000_000)
    return model.dashboard.consoleLines.joined(separator: "\n")
}

/// Blocks the first "duplicate" block until released; counts quarantines.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var firstSeen = false
    private(set) var started = false
    let release = DispatchSemaphore(value: 0)
    var onFirstDuplicateBlock: (() -> Void)?
    var hasStarted: Bool { lock.withLock { started } }
    var hooks: SignatureVerification.Hooks {
        SignatureVerification.Hooks(
            shouldCancel: { Task.isCancelled },
            didReadBlock: { [self] label in
                let first: Bool = lock.withLock {
                    guard label == "duplicate", !firstSeen else { return false }
                    firstSeen = true; started = true
                    return true
                }
                if first { onFirstDuplicateBlock?() }
            })
    }
}

@MainActor
private func entry(_ rec: VideoRecord, keeper: VideoRecord,
                   status: DeleteDuplicatesPlan.EntryStatus = .pending) -> DeleteDuplicatesPlan.Entry {
    var e = DeleteDuplicatesPlan.Entry(id: rec.id, path: rec.fullPath, filename: rec.filename, sizeBytes: rec.sizeBytes,
                                       keeperID: keeper.id, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                                       keeperStamp: FileIdentityStamp.capture(path: keeper.fullPath))
    e.status = status
    return e
}

@MainActor
private func planFor(_ model: VideoScanModel, dir: URL, entries: [DeleteDuplicatesPlan.Entry]) -> DeleteDuplicatesPlan {
    DeleteDuplicatesPlan(volumePath: dir.path, catalogLocation: model.catalogStore.fileLocation,
                         crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "", entries: entries)
}

// MARK: - 2. Orphan recovery

@Suite("Codex 1593 — quarantine recovery", .serialized)
@MainActor
struct DeleteDuplicatesRecoveryCodex1593Tests {

    /// CODEX REPRO #2 (exact shape): `duplicate.bin` and an unrelated
    /// unique sentinel share one quarantine folder. Restoring the duplicate
    /// must leave the sentinel — on 6cd71264 the folder was removed
    /// recursively and the sentinel with it.
    @Test func restoreLeavesUnrelatedQuarantineContentsAlone() throws {
        let dir = tempDir("repro2"); defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("duplicate.bin")
        let qdir = dir.appendingPathComponent(SignatureVerification.quarantineDirectoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: qdir, withIntermediateDirectories: false)
        let quarantined = qdir.appendingPathComponent("duplicate.bin"); write(quarantined, [1, 2, 3, 4])
        let sentinel = qdir.appendingPathComponent("unrelated-unique.bin"); write(sentinel, [5, 6, 7])
        let stamp = try #require(FileIdentityStamp.capture(path: quarantined.path))

        let result = DeleteDuplicatesJob.restoreQuarantined(quarantined, to: original.path, expectedStamp: stamp, expectedSize: 4)

        #expect(result == .success(false), "restored; the folder was NOT empty so it stays — got \(result)")
        #expect(FileManager.default.fileExists(atPath: original.path), "restored_exists")
        #expect(FileManager.default.fileExists(atPath: sentinel.path), "unrelated_unique_exists — codex 1593 blocker 2")
        #expect(FileManager.default.fileExists(atPath: qdir.path))
    }

    /// Recovery through the real job: only the folder the plan RECORDED is
    /// consulted; a same-named file in another quarantine is reported and
    /// left; wrong content in the recorded folder is refused and left;
    /// an occupied original path is refused.
    @Test func resumeRestoresOnlyFromTheRecordedFolder() async throws {
        let dir = tempDir("recorded"); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("plans", isDirectory: true)
        let bytes = (0..<fileSize).map { UInt8($0 % 109) }
        var other = bytes; other[blockSize + 7] ^= 0x33
        let model = makeModel(dir)
        let group = UUID()
        let k = dir.appendingPathComponent("k.mov"); write(k, bytes)
        let keeper = dupRecord(path: k.path, size: Int64(fileSize), group: group, disposition: .keep)

        // (a) recorded folder holds the right file + a stranger; a decoy
        //     sibling quarantine holds a same-named different file.
        let good = dupRecord(path: dir.appendingPathComponent("good copy.mov").path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        let goodDir = dir.appendingPathComponent(SignatureVerification.quarantineDirectoryPrefix + "recorded-good", isDirectory: true)
        try FileManager.default.createDirectory(at: goodDir, withIntermediateDirectories: false)
        let goodQ = goodDir.appendingPathComponent("good copy.mov"); write(goodQ, bytes)
        let stranger = goodDir.appendingPathComponent("unrelated-unique.bin"); write(stranger, [1])
        let goodStamp = try #require(FileIdentityStamp.capture(path: goodQ.path))
        let decoyDir = dir.appendingPathComponent(SignatureVerification.quarantineDirectoryPrefix + "decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: false)
        let decoy = decoyDir.appendingPathComponent("good copy.mov"); write(decoy, other)

        // (b) recorded folder, but the file there is not the one recorded.
        let wrong = dupRecord(path: dir.appendingPathComponent("wrong copy.mov").path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        let wrongDir = dir.appendingPathComponent(SignatureVerification.quarantineDirectoryPrefix + "recorded-wrong", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongDir, withIntermediateDirectories: false)
        let wrongQ = wrongDir.appendingPathComponent("wrong copy.mov"); write(wrongQ, other)
        let wrongStamp = FileIdentityStamp(device: 1, inode: 2, size: Int64(fileSize), mtimeNs: 3, ctimeNs: 4)

        // (c) recorded folder, right file, but the original path is occupied.
        let occupied = dupRecord(path: dir.appendingPathComponent("occupied copy.mov").path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        let occDir = dir.appendingPathComponent(SignatureVerification.quarantineDirectoryPrefix + "recorded-occ", isDirectory: true)
        try FileManager.default.createDirectory(at: occDir, withIntermediateDirectories: false)
        let occQ = occDir.appendingPathComponent("occupied copy.mov"); write(occQ, bytes)
        let occStamp = try #require(FileIdentityStamp.capture(path: occQ.path))
        write(URL(fileURLWithPath: occupied.fullPath), [7, 7, 7])   // a newcomer at the public name

        // (d) NO recorded folder; a same-named file sits in some sibling
        //     quarantine → reported, never moved.
        let orphan = dupRecord(path: dir.appendingPathComponent("orphan copy.mov").path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        let orphanDir = dir.appendingPathComponent(SignatureVerification.quarantineDirectoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: false)
        let orphanQ = orphanDir.appendingPathComponent("orphan copy.mov"); write(orphanQ, bytes)

        model.records = [keeper, good, wrong, occupied, orphan]
        var e1 = entry(good, keeper: keeper, status: .verified)
        e1.quarantineDirectory = goodDir.path; e1.quarantinedStamp = goodStamp
        var e2 = entry(wrong, keeper: keeper, status: .verified)
        e2.quarantineDirectory = wrongDir.path; e2.quarantinedStamp = wrongStamp
        var e3 = entry(occupied, keeper: keeper, status: .verified)
        e3.quarantineDirectory = occDir.path; e3.quarantinedStamp = occStamp
        let e4 = entry(orphan, keeper: keeper, status: .verifying)
        let plan = planFor(model, dir: dir, entries: [e1, e2, e3, e4])
        try DeleteDuplicatesPlanStore.save(plan, root: root)

        let job = DeleteDuplicatesJob(model: model, resuming: plan, planRoot: root)
        job.start()
        await job.task?.value

        let after = try #require(job.plan)
        // (a) restored from the recorded folder, re-verified, deleted;
        //     the stranger and the decoy untouched.
        #expect(after.entries[0].status == .deleted, "\(after.entries[0].note)")
        #expect(after.entries[0].quarantineDirectory == nil)
        #expect(FileManager.default.fileExists(atPath: stranger.path), "the stranger in the recorded folder survives")
        #expect(FileManager.default.fileExists(atPath: goodDir.path), "the recorded folder was not empty — left in place")
        #expect(FileManager.default.fileExists(atPath: decoy.path), "the decoy is not ours — untouched")
        #expect((try? Data(contentsOf: decoy)) == Data(other))
        // (b) identity mismatch → refused, left where it is.
        #expect(after.entries[1].status == .refused && after.entries[1].note.contains("not the one this run put there"), Comment(rawValue: after.entries[1].note))
        #expect(FileManager.default.fileExists(atPath: wrongQ.path))
        #expect(!FileManager.default.fileExists(atPath: wrong.fullPath))
        // (c) occupied → refused; newcomer intact; quarantined file intact.
        #expect(after.entries[2].status == .refused && after.entries[2].note.contains("original path is occupied"), Comment(rawValue: after.entries[2].note))
        #expect((try? Data(contentsOf: URL(fileURLWithPath: occupied.fullPath))) == Data([7, 7, 7]))
        #expect(FileManager.default.fileExists(atPath: occQ.path))
        // (d) no recorded folder → "gone before the crash"; the sibling
        //     orphan is reported and left alone; the row is not re-marked.
        #expect(after.entries[3].status == .skipped && after.entries[3].note.hasPrefix("gone before the crash"), Comment(rawValue: after.entries[3].note))
        #expect(FileManager.default.fileExists(atPath: orphanQ.path))
        #expect(orphan.duplicateDisposition == .extraCopy)
        #expect(job.result.deleted == 1)
        let console = await consoleText(model)
        #expect(console.contains("Restored good copy.mov from"))
        #expect(console.contains("the quarantine folder was not empty and was left in place"))
        #expect(console.contains("orphan copy.mov is gone from") && console.contains("not this run's quarantine, left alone"))
    }

    /// The crash beat the save that records the folder: the folder this
    /// plan + row would have used is still found (by construction), the
    /// size must match, and the file is restored and re-verified.
    @Test func resumeFindsTheDerivedFolderWhenTheCrashBeatTheSave() async throws {
        let dir = tempDir("derived"); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("plans", isDirectory: true)
        let bytes = (0..<fileSize).map { UInt8($0 % 113) }
        let model = makeModel(dir)
        let group = UUID()
        let k = dir.appendingPathComponent("k.mov"); write(k, bytes)
        let keeper = dupRecord(path: k.path, size: Int64(fileSize), group: group, disposition: .keep)
        let copy = dupRecord(path: dir.appendingPathComponent("copy.mov").path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        model.records = [keeper, copy]
        let plan = planFor(model, dir: dir, entries: [entry(copy, keeper: keeper, status: .verifying)])
        let derived = dir.appendingPathComponent(
            DeleteDuplicatesJob.quarantineDirectoryName(planID: plan.id, entryID: copy.id), isDirectory: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: false)
        write(derived.appendingPathComponent("copy.mov"), bytes)
        try DeleteDuplicatesPlanStore.save(plan, root: root)

        let job = DeleteDuplicatesJob(model: model, resuming: plan, planRoot: root)
        job.start()
        await job.task?.value

        let after = try #require(job.plan)
        #expect(after.entries[0].status == .deleted, Comment(rawValue: after.entries[0].note))
        #expect(!FileManager.default.fileExists(atPath: copy.fullPath))
        #expect(!FileManager.default.fileExists(atPath: derived.path), "the (empty) derived folder is gone")
        #expect(job.result.deleted == 1)
    }
}

// MARK: - 3–6, 8: the job

@Suite("Codex 1593 — job lifecycle", .serialized)
@MainActor
struct DeleteDuplicatesJobCodex1593Tests {

    private struct Rig {
        let dir: URL
        let root: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let copies: [VideoRecord]
        let different: VideoRecord
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeRig(_ label: String) -> Rig {
        let dir = tempDir(label)
        let root = dir.appendingPathComponent("plans", isDirectory: true)
        let bytes = (0..<fileSize).map { UInt8($0 % 199) }
        var other = bytes; other[blockSize + 500] ^= 0x5A
        let keeperURL = dir.appendingPathComponent("keeper.mov"); write(keeperURL, bytes)
        let c1 = dir.appendingPathComponent("copy1.mov"); write(c1, bytes)
        let c2 = dir.appendingPathComponent("copy2.mov"); write(c2, bytes)
        let d = dir.appendingPathComponent("lookalike.mov"); write(d, other)
        let group = UUID()
        let model = makeModel(dir)
        let keeper = dupRecord(path: keeperURL.path, size: Int64(fileSize), group: group, disposition: .keep)
        let copies = [c1, c2].map { dupRecord(path: $0.path, size: Int64(fileSize), group: group, disposition: .extraCopy) }
        let different = dupRecord(path: d.path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        model.records = [keeper] + copies + [different]
        return Rig(dir: dir, root: root, model: model, keeper: keeper, copies: copies, different: different)
    }

    /// #3: pause after the first pair; while paused, copy2 is re-elected
    /// KEEPER and the look-alike's group changes. On resume neither may be
    /// acted on from the plan's stale yes: copy2 is skipped untouched (its
    /// `.keep` survives), the look-alike is refused for its keeper, not
    /// for its bytes.
    @Test func everyPairIsReauthorizedLiveAfterAPause() async throws {
        let rig = makeRig("live"); defer { rig.cleanup() }
        let gate = Gate()
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: gate.hooks, planRoot: rig.root)
        gate.onFirstDuplicateBlock = { Task { @MainActor in job.pause() } }
        job.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, (job.plan?.counts.deleted ?? 0) < 1 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(job.isPaused && job.plan?.counts.deleted == 1)

        rig.copies[1].duplicateDisposition = .keep            // re-elected while paused
        rig.different.duplicateGroupID = UUID()               // regrouped while paused
        job.resume()
        await job.task?.value

        let plan = try #require(job.plan)
        #expect(job.result.deleted == 1)
        #expect(plan.entries[1].status == .skipped, "\(plan.entries[1].status)")
        #expect(plan.entries[1].note == "no longer marked as an extra copy — skipped before deletion")
        #expect(FileManager.default.fileExists(atPath: rig.copies[1].fullPath))
        #expect(rig.copies[1].duplicateDisposition == .keep, "a re-elected keeper is never re-marked")
        #expect(plan.entries[2].status == .refused)
        #expect(plan.entries[2].note == "keeper keeper.mov is no longer this file's keeper — refused before deletion")
        #expect(rig.different.duplicateDisposition == .review)
        #expect(FileManager.default.fileExists(atPath: rig.different.fullPath))
    }

    /// #4: the SAME row instance has its path changed during the disk
    /// await (a move, not a replacement). The file at the old path was
    /// verified and removed; the live row is retained untouched — not
    /// tombstoned — and the ledger line names the OLD path.
    @Test func retainedRowWhosePathMovedDuringTheAwaitIsNotTombstoned() async throws {
        let dir = tempDir("alias"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<fileSize).map { UInt8($0 % 131) }
        let model = makeModel(dir)
        let group = UUID()
        let k = dir.appendingPathComponent("keeper.mov"); write(k, bytes)
        let c = dir.appendingPathComponent("copy.mov"); write(c, bytes)
        let keeper = dupRecord(path: k.path, size: Int64(fileSize), group: group, disposition: .keep)
        let target = dupRecord(path: c.path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        model.records = [keeper, target]
        let gate = Gate()
        gate.onFirstDuplicateBlock = { gate.release.wait() }

        let deletion = Task { await model.deleteDuplicates(onVolume: dir.path, verificationHooks: gate.hooks) }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !gate.hasStarted { await Task.yield() }
        #expect(gate.hasStarted)
        let movedPath = dir.appendingPathComponent("moved.mov").path
        target.fullPath = movedPath                       // same instance, new path
        target.filename = "moved.mov"
        gate.release.signal()
        let result = await deletion.value

        #expect(result.deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: c.path), "the verified bytes at the old path are gone")
        #expect(model.records.count == 2, "the moved row is retained")
        #expect(model.records.contains { $0 === target })
        #expect(target.lifecycleStage == .cataloged, "never tombstoned — codex 1593 #4")
        #expect(target.purgedAt == nil)
        #expect(target.fullPath == movedPath)
        await model.mediaLedger.waitForPendingWrites()
        let events = model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }
        #expect(events.count == 1)
        #expect(events.first?.fullPath == c.path, "the ledger names the file that left the disk, not the row's new path")
        #expect(events.first?.filename == "copy.mov")
        let console = await consoleText(model)
        #expect(console.contains("current row retained"))
    }

    /// #5: Quit SUSPENDS. The pair in flight is put back and returns to
    /// pending, nothing is skipped, the plan stays unfinished in place
    /// (not under done/), and it is offered to resume — and the quit
    /// dialog says so.
    @Test func quitSuspendsTheRunAndKeepsThePlanResumable() async throws {
        let rig = makeRig("quit"); defer { rig.cleanup() }
        let gate = Gate()
        gate.onFirstDuplicateBlock = { gate.release.wait() }
        let center = MediaFileOperationsCenter()
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: gate.hooks, planRoot: rig.root)
        center.add(job)
        job.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !gate.hasStarted { await Task.yield() }
        #expect(gate.hasStarted)
        #expect(center.hasActiveDeleteDuplicates)

        center.stopAllForQuit()                           // the quit guard's call
        #expect(job.quitRequested && job.state == .cancelling)
        gate.release.signal()
        await job.task?.value

        #expect(job.state == .cancelled)
        #expect(job.subtitle.contains("Suspended for quit"), Comment(rawValue: job.subtitle))
        #expect(job.result.deleted == 0 && job.result.failed == 0, "nothing is counted as not done")
        for r in rig.copies + [rig.different] {
            #expect(FileManager.default.fileExists(atPath: r.fullPath))
            #expect(r.duplicateDisposition == .extraCopy)
        }
        let plan = try #require(job.plan)
        let onDisk = try DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root))
        #expect(onDisk.finishedAt == nil && onDisk.outcome == nil, "still resumable")
        #expect(onDisk.entries.allSatisfy { $0.status == .pending }, "\(onDisk.entries.map(\.status))")
        #expect(onDisk.entries[0].note.contains("interrupted by quit"))
        #expect(onDisk.entries[0].quarantineDirectory == nil)
        #expect(onDisk.log.contains { $0.hasPrefix("Suspended by quit with 3 remaining") })
        #expect(!FileManager.default.fileExists(atPath: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root).path),
                "never filed as done")
        #expect(rig.model.pendingDeleteDuplicatesResume?.id == plan.id, "offered to resume")
        #expect(MediaFileOperationsCenter.quitInformativeText(running: 1, deleteDuplicatesActive: true)
                    .contains("offered to resume at the next launch"))
        #expect(!MediaFileOperationsCenter.quitInformativeText(running: 1, deleteDuplicatesActive: false)
                    .contains("Delete Duplicates"))
        let console = await consoleText(rig.model)
        #expect(console.contains("Quit while verifying copy1.mov — left alone"))
        #expect(console.contains("suspended for quit: 0 deleted, 3 remaining"))
    }

    /// An explicit Stop still abandons (files the cancelled plan) — the
    /// two verbs must not be confused.
    @Test func explicitStopStillFilesTheCancelledPlan() async throws {
        let rig = makeRig("stop"); defer { rig.cleanup() }
        let gate = Gate()
        gate.onFirstDuplicateBlock = { gate.release.wait() }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: gate.hooks, planRoot: rig.root)
        job.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !gate.hasStarted { await Task.yield() }
        job.cancel()
        gate.release.signal()
        await job.task?.value
        let plan = try #require(job.plan)
        #expect(!job.quitRequested && job.state == .cancelled && plan.outcome == "cancelled")
        #expect(FileManager.default.fileExists(
            atPath: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root).appendingPathComponent("plan.json").path))
        #expect(rig.model.pendingDeleteDuplicatesResume == nil)
    }

    /// #6: the final save fails (the plan folder became unwritable). The
    /// last good plan.json stays where it is; nothing moves to done/; the
    /// deletions that happened are still reported.
    @Test func finalSaveFailureKeepsTheLastGoodPlanInPlace() async throws {
        let rig = makeRig("finalsave"); defer { rig.cleanup() }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, planRoot: rig.root)
        var planDir: URL?
        job.testHookBeforeFinalSave = { [weak job] in
            guard let id = job?.plan?.id else { return }
            let dir = DeleteDuplicatesPlanStore.directory(for: id, root: rig.root)
            planDir = dir
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        }
        defer {
            if let planDir { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: planDir.path) }
        }
        job.start()
        await job.task?.value

        let plan = try #require(job.plan)
        #expect(job.result.deleted == 2)
        #expect(job.state == .finished(summary: job.subtitle), "\(job.state)")
        let url = DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root)
        #expect(FileManager.default.fileExists(atPath: url.path), "the last good plan stays in place")
        let onDisk = try DeleteDuplicatesPlanStore.load(url: url)
        #expect(onDisk.finishedAt == nil && onDisk.outcome == nil, "…and it is the pre-final one")
        #expect(onDisk.entries.map(\.status) == [.deleted, .deleted, .refused])
        #expect(!FileManager.default.fileExists(atPath: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root).path),
                "a stale plan is never filed as done")
        let console = await consoleText(rig.model)
        #expect(console.contains("could not save the plan (finished)"))
        #expect(console.contains("is not filed as done"))
    }

    /// #8: with three unfinished plans, Discard offers the next one at
    /// once, and a resume that runs to completion offers the one after —
    /// no relaunch, no manual re-check.
    @Test func nextUnfinishedPlanIsOfferedAfterDiscardAndAfterACompletedResume() async throws {
        let dir = tempDir("next"); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("plans", isDirectory: true)
        let model = makeModel(dir)
        func plan(_ name: String, age: TimeInterval) -> DeleteDuplicatesPlan {
            var p = DeleteDuplicatesPlan(volumePath: "/Volumes/\(name)", catalogLocation: model.catalogStore.fileLocation,
                                         crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "",
                                         entries: [DeleteDuplicatesPlan.Entry(id: UUID(), path: "/Volumes/\(name)/x.mov", filename: "x.mov",
                                                                              sizeBytes: 1, keeperID: UUID(), keeperPath: "/k", keeperFilename: "k",
                                                                              keeperStamp: nil)])
            p.createdAt = Date().addingTimeInterval(-age)
            return p
        }
        let a = plan("A", age: 10_800), b = plan("B", age: 7_200), c = plan("C", age: 3_600)
        for p in [a, b, c] { try DeleteDuplicatesPlanStore.save(p, root: root) }

        model.checkForUnfinishedDeleteDuplicatesPlans(root: root)
        #expect(model.pendingDeleteDuplicatesResume?.id == a.id)

        model.discardPendingDeleteDuplicatesPlan(root: root)
        #expect(model.pendingDeleteDuplicatesResume?.id == b.id, "Discard offers the next plan at once")

        let center = MediaFileOperationsCenter()
        let jobB = center.resumeDeleteDuplicates(plan: b, model: model, planRoot: root)
        #expect(model.pendingDeleteDuplicatesResume == nil, "consumed by Resume")
        await jobB.task?.value
        #expect(jobB.plan?.outcome == "completed")
        #expect(model.pendingDeleteDuplicatesResume?.id == c.id, "a completed resume offers the next plan at once")

        let jobC = center.resumeDeleteDuplicates(plan: c, model: model, planRoot: root)
        await jobC.task?.value
        #expect(model.pendingDeleteDuplicatesResume == nil, "nothing left to offer")
        #expect(DeleteDuplicatesPlanStore.unfinishedPlans(root: root, log: { _ in }).isEmpty)
    }
}

// MARK: - 7. Fixity invalidation

@Suite("Codex 1593 — fixity invalidation clears deletion authority")
@MainActor
struct FixityInvalidationCodex1593Tests {

    @Test func invalidateArchiveFixityAlsoClearsContentFixityAndTheKeeperIsReReadNext() throws {
        let dir = tempDir("fixity"); defer { try? FileManager.default.removeItem(at: dir) }
        let size = FileHasher.segmentSize * 2 + 5
        let bytes = (0..<size).map { UInt8($0 % 23) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let model = VideoScanModel()
        let rec = VideoRecord()
        rec.filename = "keeper.mov"
        rec.fullPath = keeper.path
        let digest = plainSHA256(keeper)
        rec.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(), sizeBytes: Int64(size))
        rec.contentFixity = try #require(ContentFixity.captured(path: keeper.path, digest: digest, byteCount: Int64(size)))
        model.records = [rec]

        // Audit says the bytes are wrong: BOTH fixities go.
        #expect(model.invalidateArchiveFixity(path: rec.fullPath, observedDigest: digest) == .written)
        #expect(rec.archiveFixity == nil)
        #expect(rec.contentFixity == nil, "cached deletion authority revoked — codex 1593 #7")

        // A record with ONLY a content fixity (a keeper Delete Duplicates
        // hashed, never promoted) is cleared too.
        rec.contentFixity = try #require(ContentFixity.captured(path: keeper.path, digest: digest, byteCount: Int64(size)))
        #expect(model.invalidateArchiveFixity(path: rec.fullPath, observedDigest: nil) == .written)
        #expect(rec.contentFixity == nil)
        #expect(model.invalidateArchiveFixity(path: rec.fullPath, observedDigest: nil) == .nothingToClear)

        // With no fixity the next pair reads the keeper in full again.
        let counter = Counter()
        let proof = try SignatureVerification.verifyAgainstStoredKeeper(
            keeperPath: keeper.path, keeperFixity: rec.contentFixity, duplicatePath: copy.path, hooks: counter.hooks()).get()
        #expect(proof.keeperReadInFull == true)
        #expect(counter.blocks("keeper") == 3)
    }
}
