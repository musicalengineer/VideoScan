// DeleteDuplicatesJobTests.swift
// Delete Duplicates as a job, against a live (sandboxed) catalog: only
// verified pairs are deleted, the keeper is read once and its fixity
// stored, a ledger line per file, the keeper named in the log, pause holds
// between pairs, cancel leaves the rest, the plan is saved after every
// pair, a resume re-validates every remaining row, a stale safety snapshot
// is retaken, and a finished plan lands in done/.
//
// Everything lives under the process temp dir: the catalog store, the
// ledger and the plan root are all isolated — never App Support.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dupjob_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ url: URL, _ bytes: [UInt8]) {
    FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
}

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

/// Counts reads by label; optionally blocks the first duplicate block
/// until released (the existing DeleteDuplicatesSafetyTests pattern).
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var quarantines = 0
    var onQuarantine: ((Int) -> Void)?
    var onFirstDuplicateBlock: (() -> Void)?
    private var firstDuplicateBlockSeen = false

    func blocks(_ label: String) -> Int { lock.withLock { counts[label] ?? 0 } }
    var quarantineCount: Int { lock.withLock { quarantines } }

    var hooks: SignatureVerification.Hooks {
        SignatureVerification.Hooks(
            shouldCancel: { Task.isCancelled },
            didReadBlock: { [self] label in
                let first: Bool = lock.withLock {
                    counts[label, default: 0] += 1
                    guard label == "duplicate", !firstDuplicateBlockSeen else { return false }
                    firstDuplicateBlockSeen = true
                    return true
                }
                if first { onFirstDuplicateBlock?() }
            },
            didQuarantine: { [self] _ in
                let n: Int = lock.withLock { quarantines += 1; return quarantines }
                onQuarantine?(n)
            })
    }
}

private let blockSize = FileHasher.segmentSize
private let fileSize = blockSize * 3     // three read blocks per file

@MainActor
private func consoleText(_ model: VideoScanModel) async -> String {
    try? await Task.sleep(nanoseconds: 400_000_000)   // console flush debounce (150 ms)
    return model.dashboard.consoleLines.joined(separator: "\n")
}

@Suite(.serialized)
@MainActor
struct DeleteDuplicatesJobTests {

    /// keeper + two identical copies + one that differs in the middle.
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

    @Test func deletesOnlyVerifiedPairsReadsKeeperOnceLedgersAndNamesKeeper() async throws {
        let rig = makeRig("verified"); defer { rig.cleanup() }
        let probe = Probe()
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: rig.root)
        job.start()
        await job.task?.value

        let freed = ByteCountFormatter.string(fromByteCount: Int64(fileSize * 2), countStyle: .file)
        #expect(job.state == .finished(summary: "2 deleted · \(freed) freed · 1 refused"), "\(job.state)")
        #expect(job.result.deleted == 2 && job.result.failed == 0 && job.result.skipped == 0)
        #expect(job.result.bytesFreed == Int64(fileSize * 2))
        #expect(!FileManager.default.fileExists(atPath: rig.copies[0].fullPath))
        #expect(!FileManager.default.fileExists(atPath: rig.copies[1].fullPath))
        #expect(FileManager.default.fileExists(atPath: rig.different.fullPath), "a look-alike must survive")
        #expect(FileManager.default.fileExists(atPath: rig.keeper.fullPath))
        #expect(rig.different.duplicateDisposition == .review)

        // The keeper was read ONCE (three blocks) across three pairs; every
        // duplicate was read in full.
        #expect(probe.blocks("keeper") == 3, "keeper read \(probe.blocks("keeper")) blocks — expected exactly one full read")
        #expect(probe.blocks("duplicate") == 9)
        let fixity = try #require(rig.keeper.contentFixity, "the keeper's fixity is stored after its one read")
        #expect(fixity.stampMatches(path: rig.keeper.fullPath))
        #expect(fixity.digest == (try CatalogStore.sha256HexStreaming(fileURL: URL(fileURLWithPath: rig.keeper.fullPath))))

        // Plan: statuses + how each keeper match was made; filed under done/.
        let plan = try #require(job.plan)
        #expect(plan.entries.map(\.status) == [.deleted, .deleted, .refused])
        #expect(plan.entries[0].keeperMatchedByStoredFixity == false, "first pair paid the keeper read")
        #expect(plan.entries[1].keeperMatchedByStoredFixity == true, "second pair used the stored fixity")
        #expect(plan.entries[2].note.contains("content differs from keeper keeper.mov"))
        #expect(plan.outcome == "completed" && plan.finishedAt != nil)
        let done = DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root).appendingPathComponent("plan.json")
        #expect(FileManager.default.fileExists(atPath: done.path))
        #expect(!FileManager.default.fileExists(atPath: DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root).path))

        // Ledger: one copyDeleted line per file that left the disk, batch-keyed.
        await rig.model.mediaLedger.waitForPendingWrites()
        let events = rig.model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }
        #expect(events.map(\.filename).sorted() == ["copy1.mov", "copy2.mov"])
        #expect(Set(events.compactMap(\.batchID)).count == 1)

        // Log names the keeper and how it was matched.
        let console = await consoleText(rig.model)
        #expect(console.contains("Deleted (verified identical to keeper.mov): copy1.mov [keeper read in full, fixity stored]"))
        #expect(console.contains("Deleted (verified identical to keeper.mov): copy2.mov [keeper matched by stored fixity, not re-read]"))
        #expect(console.contains("REFUSED lookalike.mov: content differs from keeper keeper.mov — NOT a duplicate"))
        #expect(rig.model.records.count == 2 && !rig.model.isDeletingDuplicates)
    }

    @Test func pauseHoldsBetweenPairsAndResumeContinues() async throws {
        let rig = makeRig("pause"); defer { rig.cleanup() }
        let probe = Probe()
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: rig.root)
        // Pause the moment the first duplicate is being read: the pair in
        // flight must finish, then the loop must hold.
        probe.onFirstDuplicateBlock = { Task { @MainActor in job.pause() } }
        job.start()

        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, (job.plan?.counts.deleted ?? 0) < 1 { await Task.yield() }
        #expect(job.plan?.counts.deleted == 1)
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(job.isPaused && job.state == .running)
        #expect(job.plan?.counts.deleted == 1, "nothing moves while paused")
        #expect(FileManager.default.fileExists(atPath: rig.copies[1].fullPath))
        #expect(job.subtitle.contains("paused"), Comment(rawValue: job.subtitle))

        job.resume()
        await job.task?.value
        #expect(job.result.deleted == 2 && job.result.failed == 0)
        #expect(!job.isPaused)
        #expect(!FileManager.default.fileExists(atPath: rig.copies[1].fullPath))
    }

    @Test func cancelLeavesTheRestAndFilesTheCancelledPlan() async throws {
        let rig = makeRig("cancel"); defer { rig.cleanup() }
        let probe = Probe()
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var started = false
        probe.onFirstDuplicateBlock = {
            lock.withLock { started = true }
            release.wait()
        }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: rig.root)
        job.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !lock.withLock({ started }) { await Task.yield() }
        #expect(lock.withLock { started })

        job.cancel()
        #expect(job.state == .cancelling)
        release.signal()
        await job.task?.value

        #expect(job.state == .cancelled)
        #expect(job.result.deleted == 0)
        #expect(job.result.failed == 3, "the rest is counted, not done")
        for r in rig.copies + [rig.different] {
            #expect(FileManager.default.fileExists(atPath: r.fullPath))
            #expect(r.duplicateDisposition == .extraCopy, "a cancel never re-marks a row")
        }
        #expect(rig.model.records.count == 4)
        let plan = try #require(job.plan)
        #expect(plan.entries.allSatisfy { $0.status == .skipped })
        #expect(plan.outcome == "cancelled")
        #expect(FileManager.default.fileExists(
            atPath: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: rig.root).appendingPathComponent("plan.json").path))
    }

    @Test func planIsSavedAfterEveryPair() async throws {
        let rig = makeRig("saved"); defer { rig.cleanup() }
        let probe = Probe()
        let root = rig.root
        let lock = NSLock()
        var snapshotAtSecondQuarantine: DeleteDuplicatesPlan?
        var planID: UUID?
        probe.onQuarantine = { n in
            // The second quarantine happens while pair 2 is being removed:
            // the plan on disk must already say pair 1 was deleted.
            guard n == 2, let id = lock.withLock({ planID }) else { return }
            let loaded = try? DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.planURL(for: id, root: root))
            lock.withLock { snapshotAtSecondQuarantine = loaded }
        }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: probe.hooks, planRoot: root)
        job.start()
        // The plan is published before the first pair is read; grab its id
        // on our first main-actor turn after that.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, job.plan == nil { await Task.yield() }
        let id = try #require(job.plan?.id)
        lock.withLock { planID = id }
        await job.task?.value

        let mid = try #require(lock.withLock { snapshotAtSecondQuarantine })
        #expect(mid.entries[0].status == .deleted)
        #expect(mid.entries[1].status == .verifying || mid.entries[1].status == .pending)
        #expect(mid.entries[2].status == .pending)
        #expect(mid.finishedAt == nil, "mid-run the plan is still resumable")
    }

    @Test func resumeRevalidatesEveryRemainingRow() async throws {
        let dir = tempDir("resume"); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("plans", isDirectory: true)
        let bytes = (0..<fileSize).map { UInt8($0 % 101) }
        let model = makeModel(dir)
        let group = UUID(), otherGroup = UUID()
        func file(_ name: String, _ b: [UInt8] = bytes) -> URL { let u = dir.appendingPathComponent(name); write(u, b); return u }
        let keeperA = dupRecord(path: file("keeperA.mov").path, size: Int64(fileSize), group: group, disposition: .keep)
        let good = dupRecord(path: file("good copy.mov").path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        let keeperB = dupRecord(path: file("keeperB.mov").path, size: Int64(fileSize), group: otherGroup, disposition: .keep)
        let underB = dupRecord(path: file("B copy.mov").path, size: Int64(fileSize), group: otherGroup, disposition: .extraCopy)
        let purged = dupRecord(path: file("purged copy.mov").path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        let regrouped = dupRecord(path: file("regrouped copy.mov").path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        let alreadyDone = dupRecord(path: dir.appendingPathComponent("done copy.mov").path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        model.records = [keeperA, good, keeperB, underB, purged, regrouped]

        func entry(_ rec: VideoRecord, keeper: VideoRecord, status: DeleteDuplicatesPlan.EntryStatus = .pending) -> DeleteDuplicatesPlan.Entry {
            var e = DeleteDuplicatesPlan.Entry(id: rec.id, path: rec.fullPath, filename: rec.filename, sizeBytes: rec.sizeBytes,
                                               keeperID: keeper.id, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                                               keeperStamp: FileIdentityStamp.capture(path: keeper.fullPath))
            e.status = status
            return e
        }
        var plan = DeleteDuplicatesPlan(volumePath: dir.path, catalogLocation: model.catalogStore.fileLocation,
                                        crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "5 same-drive extras",
                                        entries: [entry(alreadyDone, keeper: keeperA, status: .deleted),
                                                  entry(good, keeper: keeperA),
                                                  entry(underB, keeper: keeperB),
                                                  entry(purged, keeper: keeperA),
                                                  entry(regrouped, keeper: keeperA)])
        plan.startedAt = Date().addingTimeInterval(-3600)
        try DeleteDuplicatesPlanStore.save(plan, root: root)
        // A plan from ANOTHER catalog must never be offered here.
        var foreign = DeleteDuplicatesPlan(volumePath: dir.path, catalogLocation: "/elsewhere/catalog.json",
                                           crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "",
                                           entries: [entry(good, keeper: keeperA)])
        foreign.createdAt = Date().addingTimeInterval(60)
        try DeleteDuplicatesPlanStore.save(foreign, root: root)

        // Between sessions: keeperB was rewritten (same bytes, new mtime),
        // one record was purged, one moved to another group.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_200_000_000)],
                                              ofItemAtPath: keeperB.fullPath)
        purged.purgedAt = Date()
        regrouped.duplicateGroupID = UUID()

        model.checkForUnfinishedDeleteDuplicatesPlans(root: root)
        let pending = try #require(model.pendingDeleteDuplicatesResume)
        #expect(pending.id == plan.id, "the foreign catalog's plan is ignored")
        #expect(pending.resumeOffer == "Resume deleting duplicates on \(dir.lastPathComponent) — 4 of 5 remaining?")

        let center = MediaFileOperationsCenter()
        let job = center.resumeDeleteDuplicates(plan: pending, model: model, planRoot: root)
        #expect(model.pendingDeleteDuplicatesResume == nil, "the offer is consumed by Resume")
        await job.task?.value

        let after = try #require(job.plan)
        #expect(after.resumeCount == 1)
        #expect(after.entries[0].status == .deleted, "done stays done")
        #expect(after.entries[1].status == .deleted)
        #expect(!FileManager.default.fileExists(atPath: good.fullPath))
        #expect(after.entries[2].status == .refused)
        #expect(after.entries[2].note == "keeper keeperB.mov changed since the plan was made — refused at resume")
        #expect(FileManager.default.fileExists(atPath: underB.fullPath))
        #expect(underB.duplicateDisposition == .review)
        #expect(after.entries[3].status == .skipped && after.entries[3].note.contains("no longer in the catalog"))
        #expect(FileManager.default.fileExists(atPath: purged.fullPath))
        #expect(after.entries[4].status == .refused && after.entries[4].note.contains("no longer this file's keeper"))
        #expect(FileManager.default.fileExists(atPath: regrouped.fullPath))
        #expect(job.result.deleted == 1)
        #expect(FileManager.default.fileExists(
            atPath: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: root).appendingPathComponent("plan.json").path))
        #expect(DeleteDuplicatesPlanStore.unfinishedPlans(root: root, log: { _ in }).map(\.id) == [foreign.id],
                "only the foreign plan is left unfinished")
        let console = await consoleText(model)
        #expect(console.contains("Resuming Delete Duplicates on \(dir.lastPathComponent): 4 of 5 remaining"))
        #expect(console.contains("REFUSED B copy.mov: keeper keeperB.mov changed since the plan was made"))
    }

    @Test func discardFilesThePlanUnderDoneWithoutTouchingFiles() async throws {
        let dir = tempDir("discard"); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("plans", isDirectory: true)
        let model = makeModel(dir)
        let group = UUID()
        let keeper = dupRecord(path: dir.appendingPathComponent("k.mov").path, size: 10, group: group, disposition: .keep)
        let copy = dupRecord(path: dir.appendingPathComponent("c.mov").path, size: 10, group: group, disposition: .extraCopy)
        write(URL(fileURLWithPath: copy.fullPath), [UInt8](repeating: 1, count: 10))
        model.records = [keeper, copy]
        let plan = DeleteDuplicatesPlan(volumePath: dir.path, catalogLocation: model.catalogStore.fileLocation,
                                        crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "",
                                        entries: [DeleteDuplicatesPlan.Entry(id: copy.id, path: copy.fullPath, filename: "c.mov",
                                                                             sizeBytes: 10, keeperID: keeper.id, keeperPath: keeper.fullPath,
                                                                             keeperFilename: "k.mov", keeperStamp: nil)])
        try DeleteDuplicatesPlanStore.save(plan, root: root)
        model.checkForUnfinishedDeleteDuplicatesPlans(root: root)
        #expect(model.pendingDeleteDuplicatesResume != nil)

        model.discardPendingDeleteDuplicatesPlan(root: root)

        #expect(model.pendingDeleteDuplicatesResume == nil)
        #expect(FileManager.default.fileExists(atPath: copy.fullPath), "discard touches no media")
        let done = try DeleteDuplicatesPlanStore.load(
            url: DeleteDuplicatesPlanStore.doneURL(for: plan.id, root: root).appendingPathComponent("plan.json"))
        #expect(done.outcome == "discarded" && done.entries[0].status == .skipped)
        #expect(DeleteDuplicatesPlanStore.unfinishedPlans(root: root, log: { _ in }).isEmpty)
    }

    @Test func staleSafetySnapshotIsRetakenAtResume() async throws {
        let dir = tempDir("snapshot"); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("plans", isDirectory: true)
        let bytes = (0..<fileSize).map { UInt8($0 % 103) }
        let model = makeModel(dir)
        let group = UUID()
        let k = dir.appendingPathComponent("k.mov"); write(k, bytes)
        let c = dir.appendingPathComponent("c.mov"); write(c, bytes)
        let keeper = dupRecord(path: k.path, size: Int64(fileSize), group: group, disposition: .keep)
        let copy = dupRecord(path: c.path, size: Int64(fileSize), group: group, disposition: .extraCopy)
        model.records = [keeper, copy]
        #expect(model.saveCatalogNow(), "a catalog file must exist for the staleness rule")
        let catalogDir = (model.catalogStore.fileLocation as NSString).deletingLastPathComponent
        let stale = (catalogDir as NSString).appendingPathComponent("catalog.pre-dup-crossvolume.old.json")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: stale))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: stale)

        var plan = DeleteDuplicatesPlan(volumePath: dir.path, catalogLocation: model.catalogStore.fileLocation,
                                        crossVolumeMode: true, skippedBeforePlan: 0, summaryLine: "1 same-drive extra",
                                        snapshotPath: stale,
                                        entries: [DeleteDuplicatesPlan.Entry(id: copy.id, path: copy.fullPath, filename: "c.mov",
                                                                             sizeBytes: Int64(fileSize), keeperID: keeper.id,
                                                                             keeperPath: keeper.fullPath, keeperFilename: "k.mov",
                                                                             keeperStamp: FileIdentityStamp.capture(path: k.path))])
        plan.snapshotTakenAt = Date(timeIntervalSince1970: 1_000_000)
        try DeleteDuplicatesPlanStore.save(plan, root: root)

        let job = DeleteDuplicatesJob(model: model, resuming: plan, planRoot: root)
        job.start()
        await job.task?.value

        let after = try #require(job.plan)
        let fresh = try #require(after.snapshotPath)
        #expect(fresh != stale, "the snapshot must be retaken when the catalog was saved after it")
        #expect(FileManager.default.fileExists(atPath: fresh))
        #expect(after.log.contains { $0.hasPrefix("Safety snapshot retaken at resume") })
        #expect(after.entries[0].status == .deleted && job.result.deleted == 1)
    }

    @Test func centerRefusesASecondConcurrentRun() async throws {
        let dir = tempDir("second"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        model.isDeletingDuplicates = true
        let center = MediaFileOperationsCenter()
        let job = center.startDeleteDuplicates(onVolume: dir.path, model: model)
        #expect(job.wasRefused)
        if case .failed(let message) = job.state {
            #expect(message.contains("already going"))
        } else {
            Issue.record("expected a refused (failed) row, got \(job.state)")
        }
        #expect(center.jobs.count == 1 && center.jobs[0].kind == .deleteDuplicates)
        #expect(MediaFileOperationKind.deleteDuplicates.badgeText == "DELETE")
        #expect(MediaFileOperationKind.deleteDuplicates.hasDetailView)
    }

    /// The model verb keeps its contract: same tuple, reentry guard intact.
    @Test func modelVerbStillReturnsTheTuple() async throws {
        let rig = makeRig("verb"); defer { rig.cleanup() }
        let result = await rig.model.deleteDuplicates(onVolume: rig.dir.path)
        #expect(result.deleted == 2 && result.failed == 0 && result.skipped == 0 && result.bytesFreed == Int64(fileSize * 2))
        #expect(!rig.model.isDeletingDuplicates)
        let freed = ByteCountFormatter.string(fromByteCount: Int64(fileSize * 2), countStyle: .file)
        #expect(rig.model.duplicateStatus == "2 deleted, \(freed) freed")
    }
}
