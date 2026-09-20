// DeleteDuplicatesTierAndSpeedTests.swift
// Rick's ruling, 2026-09-20 evening: "implement the single-read design,
// SSD parallelism and the copy-count tiering" — and, from his test drive
// the same night, a Pause that lets him quit cleanly and a Stop that
// keeps the rest for later.
//
//   1. SINGLE READ — the file that goes is moved first, hashed once in
//      quarantine; the keeper is never read; a rewrite between the hash
//      and the unlink is refused and put back; a keeper stamp change
//      between the hold and the hash is refused and put back.
//   2. SSD PARALLELISM — two SSD pairs overlap, HDD pairs never do, a
//      cancel with two in flight leaves both put back, never half.
//   3. COPY-COUNT TIER — ≥ 3 verified copies remain → permanent; exactly
//      2 (archive + keeper) → the Trash; no verified archive copy → left
//      alone before a byte is read; the toggle → the Trash for all; the
//      ledger line and the summary say which.
//   4. PAUSE / QUIT / STOP — paused at a boundary = quiet for quit;
//      pausing waits for the file in flight; "Finish this file, then
//      quit" lands the pair and the plan; Stop keeps the plan resumable.
//
// Everything lives under the process temp dir; the Trash step is routed
// into a scratch folder (DeleteDuplicatesTierFixtures).

import CryptoKit
import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_duptier_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
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

/// Read counter + per-file barriers (thread-safe).
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [String: Int] = [:]
    private var opens: [String: Int] = [:]
    private var quarantines: [String] = []
    private var activeQuarantineHolds = 0
    private(set) var peakQuarantineOverlap = 0
    /// Seconds to hold inside `didQuarantine` (the injected slow step).
    var quarantineHold: TimeInterval = 0
    /// Block the FIRST read block of each of these basenames until released.
    var barrierFor: Set<String> = []
    private var barriers: [String: DispatchSemaphore] = [:]
    private var blockedOnce: Set<String> = []
    private var lastLabelPath: [String: String] = [:]
    var onFirstBlock: ((String) -> Void)?

    func blocks(_ label: String) -> Int { lock.withLock { blocks[label] ?? 0 } }
    func opens(of path: String) -> Int { lock.withLock { opens[path] ?? 0 } }
    var quarantineCount: Int { lock.withLock { quarantines.count } }
    var quarantinedNames: [String] { lock.withLock { quarantines.map { ($0 as NSString).lastPathComponent } } }

    func release(_ name: String) { lock.withLock { barriers[name] }?.signal() }
    func hasBlocked(_ name: String) -> Bool { lock.withLock { blockedOnce.contains(name) } }

    var hooks: SignatureVerification.Hooks {
        SignatureVerification.Hooks(
            shouldCancel: { Task.isCancelled },
            didReadBlock: { [self] label in
                lock.withLock { blocks[label, default: 0] += 1 }
            },
            didOpen: { [self] path in
                let name = (path as NSString).lastPathComponent
                let barrier: DispatchSemaphore? = lock.withLock {
                    opens[path, default: 0] += 1
                    guard barrierFor.contains(name), !blockedOnce.contains(name) else { return nil }
                    blockedOnce.insert(name)
                    let s = DispatchSemaphore(value: 0)
                    barriers[name] = s
                    return s
                }
                if let barrier {
                    onFirstBlock?(name)
                    barrier.wait()
                }
            },
            didQuarantine: { [self] path in
                let hold = quarantineHold
                lock.withLock {
                    quarantines.append(path)
                    activeQuarantineHolds += 1
                    peakQuarantineOverlap = max(peakQuarantineOverlap, activeQuarantineHolds)
                }
                if hold > 0 { Thread.sleep(forTimeInterval: hold) }
                lock.withLock { activeQuarantineHolds -= 1 }
            })
    }
}

@MainActor
private func consoleText(_ model: VideoScanModel) async -> String {
    try? await Task.sleep(nanoseconds: 400_000_000)
    return model.dashboard.consoleLines.joined(separator: "\n")
}

private func quarantineFolders(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix(SignatureVerification.quarantineDirectoryPrefix) }
}

// MARK: - 3a. The tier rule (pure)

@Suite("Copy-count tier — the rule")
struct DeletionTierRuleTests {

    private func facts(_ remaining: Int, archive: Bool) -> DeletionTierFacts {
        DeletionTierFacts(remainingVerifiedCopies: remaining, hasVerifiedArchive: archive, unverifiedCopies: 0)
    }

    @Test(arguments: [
        (3, true, false, DeletionTier?.some(.permanent)),
        (4, true, false, DeletionTier?.some(.permanent)),
        (2, true, false, DeletionTier?.some(.trash)),
        (1, true, false, DeletionTier?.none),
        (3, false, false, DeletionTier?.none),
        (2, false, false, DeletionTier?.none),
        (3, true, true, DeletionTier?.some(.trash)),
        (2, true, true, DeletionTier?.some(.trash)),
        (1, true, true, DeletionTier?.none),
    ])
    func tierTable(remaining: Int, archive: Bool, preferTrash: Bool, expected: DeletionTier?) {
        let d = DeletionTierDecision.decide(facts: facts(remaining, archive: archive), preferTrash: preferTrash)
        #expect(d.tier == expected, "\(remaining) remaining, archive \(archive), preferTrash \(preferTrash) → \(d.reason)")
        #expect(d.remainingVerifiedCopies == remaining)
        if !archive { #expect(d.reason == DeletionTierText.noVerifiedArchive) }
        if archive, remaining == 2, !preferTrash { #expect(d.reason.contains("only the archive copy and the keeper remain")) }
        if archive, remaining < 2 { #expect(d.reason.contains("never below the archive copy")) }
    }

    /// The disk side: an archive copy counts only when it is there with
    /// the same size and the SAME digest; another copy only when its
    /// stored fixity reproduces and its digest is this one's; a keeper
    /// that IS the archive copy is counted once.
    @Test func gatherCountsOnlyCopiesThatHoldTheseBytes() throws {
        let dir = tempDir("gather"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<4_096).map { UInt8($0 % 7) }
        var other = bytes; other[100] ^= 0xFF
        let archiveOK = dir.appendingPathComponent("archive.mov"); write(archiveOK, bytes)
        let archiveOther = dir.appendingPathComponent("archive-other.mov"); write(archiveOther, other)
        let copyOK = dir.appendingPathComponent("copy.mov"); write(copyOK, bytes)
        let copyStale = dir.appendingPathComponent("stale.mov"); write(copyStale, bytes)
        let digest = plainSHA256(archiveOK)
        let staleFixity = try #require(ContentFixity.captured(path: copyStale.path, digest: digest, byteCount: 4_096))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: copyStale.path)

        var c = DeletionTierCandidates()
        c.archiveCopies = [.init(path: archiveOK.path, digest: digest.uppercased(), sizeBytes: 4_096),
                           .init(path: archiveOther.path, digest: plainSHA256(archiveOther), sizeBytes: 4_096),
                           .init(path: dir.appendingPathComponent("offline.mov").path, digest: digest, sizeBytes: 4_096)]
        c.otherCopies = [.init(path: copyOK.path, fixity: ContentFixity.captured(path: copyOK.path, digest: digest, byteCount: 4_096)),
                         .init(path: copyStale.path, fixity: staleFixity),
                         .init(path: dir.appendingPathComponent("nofixity.mov").path, fixity: nil)]
        let f = DeletionTierFacts.gather(c, digest: digest)
        #expect(f.hasVerifiedArchive)
        #expect(f.remainingVerifiedCopies == 3, "keeper + the one good archive copy + the one good copy")
        #expect(f.unverifiedCopies == 4)

        var keeperIsArchive = DeletionTierCandidates()
        keeperIsArchive.keeperIsVerifiedArchive = true
        let g = DeletionTierFacts.gather(keeperIsArchive, digest: digest)
        #expect(g.hasVerifiedArchive && g.remainingVerifiedCopies == 1, "the keeper is counted once")
        #expect(DeletionTierDecision.decide(facts: g, preferTrash: false).tier == nil, "only the archive copy would remain")
    }

    @Test func subtitleAndSummaryNameTheTrash() {
        var c = DeleteDuplicatesPlan.Counts()
        c.total = 10; c.deleted = 3; c.trashed = 2; c.freedBytes = 1_200_000_000; c.trashedBytes = 800_000_000
        let text = DeleteDuplicatesRate.subtitle(counts: c, rate: DeleteDuplicatesRate(), trashVolumes: ["SanDisk"])
        #expect(text == "verified 5 of 10 · 3 deleted · 2 to the Trash · 1.2 GB freed now · 800 MB waiting in the Trash of SanDisk", Comment(rawValue: text))
        #expect(DeleteDuplicatesRate.freedText(counts: c, trashVolumes: []) == "1.2 GB freed now · 800 MB waiting in the Trash")
        var permanentOnly = DeleteDuplicatesPlan.Counts(); permanentOnly.freedBytes = 1_000
        #expect(DeleteDuplicatesRate.freedText(counts: permanentOnly, trashVolumes: []) == "1 KB freed")
        #expect(DeleteDuplicatesRate.subtitle(counts: c, rate: DeleteDuplicatesRate(), paused: true, trashVolumes: ["SanDisk"])
                == "Paused at 5 of 10 · 1.2 GB freed now · 800 MB waiting in the Trash of SanDisk so far")
        #expect(DeleteDuplicatesRate.subtitle(counts: c, rate: DeleteDuplicatesRate(), pausing: true)
                == "Pausing — finishing the current file (6 of 10)")
    }

    @Test func rateDividesWallClockByPairsInFlight() {
        var r = DeleteDuplicatesRate()
        r.add(bytes: 100, seconds: 2, concurrency: 2)
        #expect(r.bytesPerSecond == 100, "two pairs sharing 2 s each count 1 s")
        r.add(bytes: 100, seconds: 1)
        #expect(r.bytesPerSecond == 100)
    }

    @Test func oldPlansDecodeWithNoTierAndTrashedRowsCountApart() throws {
        let json = """
        {"catalogLocation":"/c","createdAt":"2026-09-20T10:00:00Z","crossVolumeMode":false,"entries":[
         {"filename":"a.mov","id":"\(UUID().uuidString)","isWorkingCopy":false,"keeperFilename":"k","keeperID":"\(UUID().uuidString)",
          "keeperPath":"/k","note":"","path":"/Volumes/S/a.mov","sizeBytes":10,"status":"deleted"},
         {"filename":"b.mov","id":"\(UUID().uuidString)","isWorkingCopy":false,"keeperFilename":"k","keeperID":"\(UUID().uuidString)",
          "keeperPath":"/k","note":"","path":"/Volumes/S/b.mov","sizeBytes":20,"status":"pending"}],
         "id":"\(UUID().uuidString)","log":[],"resumeCount":0,"skippedBeforePlan":0,"summaryLine":"","volumeName":"S","volumePath":"/Volumes/S"}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var plan = try dec.decode(DeleteDuplicatesPlan.self, from: Data(json.utf8))
        #expect(plan.entries.allSatisfy { $0.tier == nil && $0.remainingVerifiedCopies == nil })
        #expect(plan.isResumable)
        plan.set(plan.entries[1].id, .trashed)
        plan.setTier(plan.entries[1].id, DeletionTierDecision(tier: .trash, remainingVerifiedCopies: 2, reason: "r"), trashVolume: "S")
        let c = plan.counts
        #expect(c.deleted == 1 && c.trashed == 1 && c.freedBytes == 10 && c.trashedBytes == 20 && c.removed == 2)
        #expect(plan.trashVolumes == ["S"])
        #expect(plan.entries[1].tierLabel == "Trash of S" && plan.entries[0].tierLabel == "—")
        #expect(DeleteDuplicatesPlan.EntryStatus.trashed.isSettled && DeleteDuplicatesPlan.EntryStatus.trashed.isRemoved)
    }

    @Test func preferTrashSettingRoundTripsThroughInjectedDefaults() throws {
        let suite = "test.duptier.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DuplicateKeeperSettings.restored(from: defaults).preferTrashForEveryDuplicate == false, "DEFAULT OFF")
        var s = DuplicateKeeperSettings()
        s.preferTrashForEveryDuplicate = true
        s.save(to: defaults)
        #expect(DuplicateKeeperSettings.restored(from: defaults).preferTrashForEveryDuplicate == true)
    }
}

// MARK: - 1. The single-read gate

@Suite("Single read — move first, hash once in quarantine")
struct SingleReadGateTests {

    private let size = FileHasher.segmentSize * 2 + 777

    @Test func holdMovesBeforeReadingAndTheKeeperIsNeverRead() throws {
        let dir = tempDir("hold"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 251) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper), byteCount: Int64(size)))
        let probe = Probe()

        guard case .held(let hold) = SignatureVerification.holdForSingleRead(
            keeperPath: keeper.path, keeperFixity: fixity, duplicatePath: copy.path, hooks: probe.hooks) else {
            Issue.record("expected a hold"); return
        }
        #expect(!FileManager.default.fileExists(atPath: copy.path), "moved before any read")
        #expect(FileManager.default.fileExists(atPath: hold.quarantinedPath))
        #expect(probe.blocks("quarantine") == 0 && probe.blocks("duplicate") == 0, "nothing read yet")
        #expect(hold.baseline.hasChangeTime)

        guard case .verified(let ticket) = SignatureVerification.verifyHeld(hold, hooks: probe.hooks) else {
            Issue.record("expected verified"); return
        }
        #expect(probe.blocks("quarantine") == 3, "ONE full read, in quarantine")
        #expect(probe.blocks("duplicate") == 0 && probe.blocks("keeper") == 0)
        #expect(probe.opens(of: keeper.path) == 0 && probe.opens(of: copy.path) == 0)
        #expect(ticket.hashedInQuarantine && !ticket.proof.keeperReadInFull)
        #expect(ticket.proof.fullHash == fixity.digest)

        #expect(SignatureVerification.deleteQuarantined(ticket, hooks: probe.hooks) == .deleted(bytes: Int64(size)))
        #expect(probe.blocks("quarantine") == 3, "the unlink step re-stats only — no second read")
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(quarantineFolders(in: dir).isEmpty)
    }

    /// A rewrite through an open descriptor between the hash (e) and the
    /// unlink (g), mtime put back: the ctime moved, the unlink is refused
    /// and the file put back with the NEW bytes.
    @Test func rewriteBetweenHashAndUnlinkIsRefusedAndRestored() throws {
        let dir = tempDir("rewrite"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 13) }
        var other = bytes; other[size / 2] ^= 0xFF
        let wholeSecond = Date(timeIntervalSince1970: 1_600_000_000)
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        try FileManager.default.setAttributes([.modificationDate: wholeSecond], ofItemAtPath: copy.path)
        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper), byteCount: Int64(size)))
        let fd = open(copy.path, O_WRONLY); #expect(fd >= 0); defer { close(fd) }

        guard case .held(let hold) = SignatureVerification.holdForSingleRead(
            keeperPath: keeper.path, keeperFixity: fixity, duplicatePath: copy.path),
              case .verified(let ticket) = SignatureVerification.verifyHeld(hold) else {
            Issue.record("expected a verified ticket"); return
        }
        let wrote = other.withUnsafeBytes { pwrite(fd, $0.baseAddress, other.count, 0) }
        #expect(wrote == other.count)
        try FileManager.default.setAttributes([.modificationDate: wholeSecond], ofItemAtPath: ticket.quarantinedPath)

        let result = SignatureVerification.deleteQuarantined(ticket)
        #expect(result == .refused(.changedSinceVerification(copy.path)), "\(result)")
        #expect((try? Data(contentsOf: copy)) == Data(other), "put back holding the new bytes")
        #expect(quarantineFolders(in: dir).isEmpty)
    }

    /// The keeper's stamp changes between the hold (a) and the compare
    /// (f): refused, the held file put back untouched.
    @Test func keeperStampChangeBetweenHoldAndCompareIsRefusedAndRestored() throws {
        let dir = tempDir("keeperstamp"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 17) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper), byteCount: Int64(size)))

        guard case .held(let hold) = SignatureVerification.holdForSingleRead(
            keeperPath: keeper.path, keeperFixity: fixity, duplicatePath: copy.path) else {
            Issue.record("expected a hold"); return
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
                                              ofItemAtPath: keeper.path)
        let result = SignatureVerification.verifyHeld(hold)
        #expect(result == .refused(.changedSinceVerification(keeper.path)), "\(result)")
        #expect((try? Data(contentsOf: copy)) == Data(bytes), "put back, untouched")
        #expect(quarantineFolders(in: dir).isEmpty)
    }

    @Test func contentThatDiffersIsRefusedAsNotADuplicateAndRestored() throws {
        let dir = tempDir("differs"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 19) }
        var other = bytes; other[size - 1] ^= 0x01
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, other)
        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper), byteCount: Int64(size)))
        let probe = Probe()
        guard case .held(let hold) = SignatureVerification.holdForSingleRead(
            keeperPath: keeper.path, keeperFixity: fixity, duplicatePath: copy.path, hooks: probe.hooks) else {
            Issue.record("expected a hold"); return
        }
        #expect(SignatureVerification.verifyHeld(hold, hooks: probe.hooks) == .refused(.contentDiffers))
        #expect((try? Data(contentsOf: copy)) == Data(other))
        #expect(probe.blocks("keeper") == 0 && probe.opens(of: keeper.path) == 0)
    }

    @Test func noUsableFixityMovesNothingAndSizeMismatchRefusesBeforeMoving() throws {
        let dir = tempDir("nofix"); defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<size).map { UInt8($0 % 23) }
        let keeper = dir.appendingPathComponent("keeper.mov"); write(keeper, bytes)
        let copy = dir.appendingPathComponent("copy.mov"); write(copy, bytes)
        #expect(SignatureVerification.holdForSingleRead(keeperPath: keeper.path, keeperFixity: nil, duplicatePath: copy.path)
                == .keeperFixityUnusable)
        let stale = ContentFixity(digest: plainSHA256(keeper), byteCount: Int64(size),
                                  stamp: FileIdentityStamp(device: 1, inode: 2, size: Int64(size), mtimeNs: 3, ctimeNs: 4))
        #expect(SignatureVerification.holdForSingleRead(keeperPath: keeper.path, keeperFixity: stale, duplicatePath: copy.path)
                == .keeperFixityUnusable)
        #expect(FileManager.default.fileExists(atPath: copy.path) && quarantineFolders(in: dir).isEmpty)
        let short = dir.appendingPathComponent("short.mov"); write(short, Array(bytes.prefix(100)))
        let fixity = try #require(ContentFixity.captured(path: keeper.path, digest: plainSHA256(keeper), byteCount: Int64(size)))
        #expect(SignatureVerification.holdForSingleRead(keeperPath: keeper.path, keeperFixity: fixity, duplicatePath: short.path)
                == .refused(.contentDiffers))
        #expect(FileManager.default.fileExists(atPath: short.path) && quarantineFolders(in: dir).isEmpty)
    }
}

// MARK: - 2, 3b, 4. The job

@Suite("Delete Duplicates — tier, parallelism, pause/quit/stop", .serialized)
@MainActor
struct DeleteDuplicatesTierAndSpeedTests {

    private struct Rig {
        let dir: URL
        let root: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let copies: [VideoRecord]
        let bytes: [UInt8]
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// keeper + `copies` identical extras; the keeper's stored fixity is
    /// optional (with it, every pair takes the single-read path).
    private func makeRig(_ label: String, copies n: Int, keeperFixity: Bool) -> Rig {
        let dir = tempDir(label)
        let root = dir.appendingPathComponent("plans", isDirectory: true)
        let bytes = (0..<fileSize).map { UInt8($0 % 199) }
        let keeperURL = dir.appendingPathComponent("keeper.mov"); write(keeperURL, bytes)
        let group = UUID()
        let model = makeModel(dir)
        let keeper = dupRecord(path: keeperURL.path, size: Int64(fileSize), group: group, disposition: .keep)
        if keeperFixity {
            keeper.contentFixity = ContentFixity.captured(path: keeperURL.path, digest: plainSHA256(keeperURL), byteCount: Int64(fileSize))
        }
        var copies: [VideoRecord] = []
        for i in 1...n {
            let c = dir.appendingPathComponent("copy\(i).mov"); write(c, bytes)
            copies.append(dupRecord(path: c.path, size: Int64(fileSize), group: group, disposition: .extraCopy))
        }
        model.records = [keeper] + copies
        return Rig(dir: dir, root: root, model: model, keeper: keeper, copies: copies, bytes: bytes)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: Double = 10) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline, !condition() { await Task.yield() }
    }

    // MARK: Tier

    @Test func threeVerifiedCopiesRemainingDeletesOutrightWithTierOnTheLedger() async throws {
        let rig = makeRig("tier3", copies: 1, keeperFixity: true); defer { rig.cleanup() }
        addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper)          // archive + sibling → 3 remain
        let probe = Probe()
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: probe.hooks.withScratchTrash(in: rig.dir), planRoot: rig.root)
        job.start(); await job.task?.value

        let freed = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        #expect(job.state == .finished(summary: "1 deleted · \(freed) freed"), "\(job.state)")
        #expect(job.result.deleted == 1 && job.result.bytesFreed == Int64(fileSize))
        let plan = try #require(job.plan)
        #expect(plan.entries[0].status == .deleted && plan.entries[0].tier == .permanent)
        #expect(plan.entries[0].remainingVerifiedCopies == 3)
        #expect(plan.entries[0].tierReason?.contains("space back now") == true)
        #expect(!FileManager.default.fileExists(atPath: rig.copies[0].fullPath))
        #expect(!FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("Trash").path), "nothing went to a Trash")
        #expect(probe.blocks("keeper") == 0 && probe.blocks("quarantine") == 3 && probe.blocks("duplicate") == 0,
                "single read: keeper 0, duplicate once in quarantine")
        await rig.model.mediaLedger.waitForPendingWrites()
        let events = rig.model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }
        #expect(events.count == 1)
        #expect(events.first?.detail[MediaLedgerEvent.Detail.tier] == "permanent")
        #expect(events.first?.detail[MediaLedgerEvent.Detail.remainingVerifiedCopies] == "3")
        #expect(events.first?.detail[MediaLedgerEvent.Detail.mode] == "permanent")
        let console = await consoleText(rig.model)
        #expect(console.contains("Deleted (verified identical to keeper.mov): copy1.mov [keeper matched by stored fixity, not re-read] — 3 verified copies remain"))
    }

    @Test func exactlyArchiveAndKeeperRemainingGoesToTheTrash() async throws {
        let rig = makeRig("tier2", copies: 1, keeperFixity: true); defer { rig.cleanup() }
        addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper, withSibling: false)   // archive + keeper → 2 remain
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir), planRoot: rig.root)
        job.start(); await job.task?.value

        let plan = try #require(job.plan)
        let volume = VolumeReachability.volumeName(forPath: rig.copies[0].fullPath)
        #expect(plan.entries[0].status == .trashed && plan.entries[0].tier == .trash, "\(plan.entries[0].status)")
        #expect(plan.entries[0].remainingVerifiedCopies == 2)
        #expect(plan.entries[0].trashedOnVolume == volume)
        #expect(plan.entries[0].note.contains("in the Trash of \(volume)"))
        #expect(plan.entries[0].tierLabel == "Trash of \(volume)")
        #expect(!FileManager.default.fileExists(atPath: rig.copies[0].fullPath))
        #expect(FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("Trash/copy1.mov").path), "moved into the (scratch) Trash")
        #expect(quarantineFolders(in: rig.dir).isEmpty)
        let waiting = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        #expect(job.state == .finished(summary: "0 deleted · 1 to the Trash · \(waiting) waiting in the Trash of \(volume)"), "\(job.state)")
        #expect(job.result.deleted == 1 && job.result.bytesFreed == 0, "trashed counts as removed, not as freed")
        #expect(rig.model.duplicateStatus == "1 deleted, \(waiting) waiting in the Trash of \(volume)")
        #expect(rig.copies[0].lifecycleStage == .trashed)
        await rig.model.mediaLedger.waitForPendingWrites()
        let events = rig.model.mediaLedger.allEvents().filter { $0.event == .copyTrashed }
        #expect(events.count == 1 && rig.model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }.isEmpty)
        #expect(events.first?.detail[MediaLedgerEvent.Detail.tier] == "trash")
        #expect(events.first?.detail[MediaLedgerEvent.Detail.remainingVerifiedCopies] == "2")
        #expect(events.first?.detail[MediaLedgerEvent.Detail.mode] == "trash")
        let console = await consoleText(rig.model)
        #expect(console.contains("Moved to the Trash of \(volume) (verified identical to keeper.mov): copy1.mov"))
    }

    @Test func noVerifiedArchiveCopyIsLeftAloneBeforeAByteIsRead() async throws {
        let rig = makeRig("noarchive", copies: 1, keeperFixity: true); defer { rig.cleanup() }
        let probe = Probe()
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: rig.root)
        job.start(); await job.task?.value

        let plan = try #require(job.plan)
        #expect(plan.entries[0].status == .skipped && plan.entries[0].note == DeletionTierText.noVerifiedArchive)
        #expect(plan.entries[0].tier == nil)
        #expect(FileManager.default.fileExists(atPath: rig.copies[0].fullPath))
        #expect(rig.copies[0].duplicateDisposition == .extraCopy, "not a refusal — the row is not re-marked Review")
        #expect(probe.blocks("quarantine") == 0 && probe.blocks("duplicate") == 0 && probe.quarantineCount == 0, "nothing read, nothing moved")
        #expect(job.result.deleted == 0 && job.result.skipped == 1)
        #expect(job.state == .finished(summary: "0 deleted · Zero KB freed · 1 not archived yet"), "\(job.state)")
        let console = await consoleText(rig.model)
        #expect(console.contains("Left alone copy1.mov: \(DeletionTierText.noVerifiedArchive)"))
        #expect(console.contains("promote the keeper first, then run again"))
    }

    @Test func archiveCopyHoldingDifferentBytesIsLeftAloneAfterTheHashAndPutBack() async throws {
        let rig = makeRig("archiveother", copies: 1, keeperFixity: true); defer { rig.cleanup() }
        let (archive, _) = addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper, withSibling: false)
        var other = rig.bytes; other[10] ^= 0x55
        write(URL(fileURLWithPath: archive.fullPath), other)
        archive.archiveFixity = ArchiveFixity(digest: plainSHA256(URL(fileURLWithPath: archive.fullPath)), verifiedAt: Date(),
                                              sizeBytes: Int64(other.count))
        let probe = Probe()
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: rig.root)
        job.start(); await job.task?.value

        let plan = try #require(job.plan)
        #expect(plan.entries[0].status == .skipped, "\(plan.entries[0].status): \(plan.entries[0].note)")
        #expect(plan.entries[0].note == DeletionTierText.noVerifiedArchive)
        #expect(plan.entries[0].tier == nil && plan.entries[0].remainingVerifiedCopies == 1)
        #expect(FileManager.default.fileExists(atPath: rig.copies[0].fullPath), "put back at its path")
        #expect((try? Data(contentsOf: URL(fileURLWithPath: rig.copies[0].fullPath))) == Data(rig.bytes))
        #expect(quarantineFolders(in: rig.dir).isEmpty)
        #expect(rig.copies[0].duplicateDisposition == .extraCopy)
        #expect(probe.blocks("quarantine") == 3, "the file was read once — the tier is decided with the digest in hand")
    }

    @Test func preferTrashToggleSendsEveryTierToTheTrash() async throws {
        let rig = makeRig("toggle", copies: 1, keeperFixity: true); defer { rig.cleanup() }
        addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper)          // 3 remain — would be permanent
        rig.model.duplicateKeeperSettings.preferTrashForEveryDuplicate = true
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir), planRoot: rig.root)
        job.start(); await job.task?.value
        let plan = try #require(job.plan)
        #expect(plan.entries[0].status == .trashed && plan.entries[0].tier == .trash)
        #expect(plan.entries[0].remainingVerifiedCopies == 3)
        #expect(plan.entries[0].tierReason?.contains("by your setting") == true)
        #expect(FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("Trash/copy1.mov").path))
    }

    /// The first pair of a keeper without a stored fixity still reads it
    /// once (path 1); every later pair is single-read.
    @Test func keeperWithoutFixityIsReadOnceThenEveryPairIsSingleRead() async throws {
        let rig = makeRig("firstpair", copies: 3, keeperFixity: false); defer { rig.cleanup() }
        addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper)
        let probe = Probe()
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: rig.root)
        job.mediaTechForPath = { _ in .ssd }
        job.start(); await job.task?.value
        #expect(job.result.deleted == 3)
        #expect(probe.blocks("keeper") == 3, "the keeper is read exactly once, even on an SSD")
        #expect(probe.blocks("duplicate") == 3, "only the first pair reads its duplicate at its path")
        #expect(probe.blocks("quarantine") == 9, "first pair re-read (3) + two single-read pairs (6)")
    }

    // MARK: Parallelism

    @Test func twoSSDPairsOverlapAndHDDPairsNeverDo() async throws {
        for (tech, expectedPeak) in [(VolumeMediaTech.ssd, 2), (VolumeMediaTech.hdd, 1), (VolumeMediaTech.unknown, 1)] {
            let rig = makeRig("overlap-\(tech.rawValue)", copies: 3, keeperFixity: true); defer { rig.cleanup() }
            addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper)
            let probe = Probe()
            probe.quarantineHold = 0.3          // the injected slow step: each pair sits 300 ms after its move
            let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: rig.root)
            job.mediaTechForPath = { _ in tech }
            job.start(); await job.task?.value
            #expect(job.result.deleted == 3, "\(tech)")
            #expect(job.peakInFlight == expectedPeak, "\(tech): peak in flight \(job.peakInFlight)")
            #expect(probe.peakQuarantineOverlap == expectedPeak, "\(tech): \(probe.peakQuarantineOverlap) quarantine holds overlapped")
            #expect(quarantineFolders(in: rig.dir).isEmpty)
            let plan = try #require(job.plan)
            #expect(plan.entries.allSatisfy { $0.status == .deleted })
        }
    }

    @Test func cancelWithTwoInFlightPutsBothBackNeverHalf() async throws {
        let rig = makeRig("cancel2", copies: 2, keeperFixity: true); defer { rig.cleanup() }
        addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper)
        let probe = Probe()
        probe.barrierFor = ["copy1.mov", "copy2.mov"]     // each blocks at its first open (the quarantine read)
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: rig.root)
        job.mediaTechForPath = { _ in .ssd }
        job.start()
        await waitUntil { probe.hasBlocked("copy1.mov") && probe.hasBlocked("copy2.mov") }
        #expect(job.inFlightCount == 2 && job.peakInFlight == 2)
        #expect(!FileManager.default.fileExists(atPath: rig.copies[0].fullPath) && !FileManager.default.fileExists(atPath: rig.copies[1].fullPath),
                "both moved into quarantine")

        job.cancel()
        probe.release("copy1.mov"); probe.release("copy2.mov")
        await job.task?.value

        #expect(job.state == .cancelled)
        for c in rig.copies {
            #expect(FileManager.default.fileExists(atPath: c.fullPath), "put back: \(c.filename)")
            #expect((try? Data(contentsOf: URL(fileURLWithPath: c.fullPath))) == Data(rig.bytes))
            #expect(c.duplicateDisposition == .extraCopy)
        }
        #expect(quarantineFolders(in: rig.dir).isEmpty, "no half-state left behind")
        let plan = try #require(job.plan)
        #expect(plan.entries.allSatisfy { $0.status == .pending }, "\(plan.entries.map(\.status))")
        #expect(plan.isResumable && job.result.deleted == 0)
    }

    // MARK: Pause / quit / stop

    @Test func pausedAtABoundaryIsQuietForQuitAndThePlanIsOnDisk() async throws {
        let rig = makeRig("pausedquiet", copies: 3, keeperFixity: true); defer { rig.cleanup() }
        addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper)
        let center = MediaFileOperationsCenter()
        let probe = Probe()
        probe.barrierFor = ["copy1.mov"]
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: rig.root)
        center.add(job)
        job.start()
        await waitUntil { probe.hasBlocked("copy1.mov") }

        // Pause mid-file: it is requested, not yet in effect.
        job.pause()
        #expect(job.isPaused && !job.isQuiescentForQuit && job.isMidPair)
        #expect(job.subtitle.hasPrefix("Pausing — finishing the current file (1 of 3)"), Comment(rawValue: job.subtitle))
        #expect(center.runningCount == 1, "mid-file it still counts")
        probe.release("copy1.mov")
        await waitUntil { job.isQuiescentForQuit }

        #expect(job.isQuiescentForQuit && job.state == .running && !job.isMidPair)
        #expect(job.subtitle.hasPrefix("Paused at 1 of 3 · "), Comment(rawValue: job.subtitle))
        #expect(center.runningCount == 0, "a paused, idle delete job is not a reason to warn on quit")
        #expect(center.activeCount == 1 && center.quiescentDeleteDuplicates.count == 1 && !center.hasDeleteDuplicatesMidPair)
        #expect(job.pausedForQuitLogLine == "delete duplicates paused at 1 of 3 — plan kept, resume at next launch")
        let plan = try #require(job.plan)
        let onDisk = try DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root))
        #expect(onDisk.isResumable && onDisk.entries.map(\.status) == [.deleted, .pending, .pending])
        #expect(!FileManager.default.fileExists(atPath: rig.copies[0].fullPath) && FileManager.default.fileExists(atPath: rig.copies[1].fullPath))

        job.resume()
        await job.task?.value
        #expect(job.result.deleted == 3)
    }

    @Test func finishThisFileThenQuitLandsThePairAndSuspendsThePlan() async throws {
        let rig = makeRig("finishquit", copies: 3, keeperFixity: true); defer { rig.cleanup() }
        addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper)
        let center = MediaFileOperationsCenter()
        let probe = Probe()
        probe.barrierFor = ["copy1.mov"]
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: rig.root)
        center.add(job)
        job.start()
        await waitUntil { probe.hasBlocked("copy1.mov") }
        #expect(center.hasDeleteDuplicatesMidPair && center.runningCount == 1)
        #expect(MediaFileOperationsCenter.quitInformativeText(running: 1, deleteDuplicatesActive: true, midPair: true)
                    .contains("Finish this file, then quit"))

        center.finishInFlightThenSuspendForQuit()
        #expect(job.quitRequested && job.finishInFlightForQuit && job.state == .cancelling)
        #expect(job.subtitle.hasPrefix("Finishing the current file, then quitting"), Comment(rawValue: job.subtitle))
        probe.release("copy1.mov")
        let settled = await center.waitForDeleteDuplicatesToSettle(deadline: 10)

        #expect(settled && job.state == .cancelled)
        #expect(job.subtitle.contains("Suspended for quit"), Comment(rawValue: job.subtitle))
        #expect(!FileManager.default.fileExists(atPath: rig.copies[0].fullPath), "the file in flight landed")
        #expect(FileManager.default.fileExists(atPath: rig.copies[1].fullPath) && FileManager.default.fileExists(atPath: rig.copies[2].fullPath))
        #expect(job.result.deleted == 1 && job.result.failed == 0)
        let plan = try #require(job.plan)
        let onDisk = try DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root))
        #expect(onDisk.finishedAt == nil && onDisk.outcome == nil && onDisk.entries.map(\.status) == [.deleted, .pending, .pending])
        #expect(rig.model.pendingDeleteDuplicatesResume?.id == plan.id, "offered to resume")
        #expect(quarantineFolders(in: rig.dir).isEmpty)
    }

    @Test func stopKeepsThePlanResumableByDefaultAndOffersItAtOnce() async throws {
        let rig = makeRig("stopkeep", copies: 3, keeperFixity: true); defer { rig.cleanup() }
        addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper)
        let probe = Probe()
        probe.barrierFor = ["copy2.mov"]
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: rig.root)
        job.start()
        await waitUntil { probe.hasBlocked("copy2.mov") }

        job.cancel()                                      // the row's Stop, "keep the rest for later"
        #expect(job.stopKeepingPlan && !job.discardRequested && job.state == .cancelling)
        probe.release("copy2.mov")
        await job.task?.value

        #expect(job.state == .cancelled)
        #expect(job.subtitle == "Stopped — 1 deleted; 2 remaining kept for later (Resume in Media File Operations)", Comment(rawValue: job.subtitle))
        #expect(job.result.deleted == 1 && job.result.failed == 0, "nothing is counted as not done")
        #expect(FileManager.default.fileExists(atPath: rig.copies[1].fullPath), "the file in flight was put back")
        #expect(rig.copies[1].duplicateDisposition == .extraCopy)
        let plan = try #require(job.plan)
        let onDisk = try DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root))
        #expect(onDisk.finishedAt == nil && onDisk.outcome == nil, "still resumable")
        #expect(onDisk.entries.map(\.status) == [.deleted, .pending, .pending], "\(onDisk.entries.map(\.status))")
        #expect(onDisk.entries[1].note.contains("interrupted by Stop"))
        #expect(onDisk.log.contains { $0.hasPrefix("Suspended by Stop with 2 remaining") })
        #expect(!FileManager.default.fileExists(atPath: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root).path), "never filed as done")
        #expect(rig.model.pendingDeleteDuplicatesResume?.id == plan.id, "offered at once, not only at the next launch")
        let console = await consoleText(rig.model)
        #expect(console.contains("Stopped while verifying copy2.mov — put back"))
        #expect(console.contains("suspended for Stop: 1 deleted, 2 remaining — kept"))

        // And the resume picks up exactly there.
        let center = MediaFileOperationsCenter()
        let resumed = center.resumeDeleteDuplicates(plan: onDisk, model: rig.model, planRoot: rig.root)
        await resumed.task?.value
        #expect(resumed.result.deleted == 2 && resumed.plan?.outcome == "completed")
    }
}
