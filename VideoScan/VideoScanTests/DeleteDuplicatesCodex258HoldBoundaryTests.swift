// DeleteDuplicatesCodex258HoldBoundaryTests.swift
// Codex review of the delete-safety bundle (GH #258 + Read-only volumes +
// the two-drives rule), cycle #34, 2026-10-03: BLOCK, 11 findings
// (docs/reviews/codex/codex-review-delete-safety-bundle-258-2026-10-03.md).
// One pinning test (or a few) per finding, each red before its fix.
//
//   F1  a copy the run LEAVES ALONE (in use by the Angel, on a Read-only
//       folder of the cleaned drive) was counted as a survivor for another
//       copy — which main never did while it was a pending row
//   F2  a Read-only mark made through an alias / a custom mount point
//       protected only the spelling
//   F3  an import replaced an existing mark's drive identity
//   F4  a FOLDER mark was not found by UUID at removal after a remount
//   F5  Junk Delete / Move to Trash judged every file by the snapshot taken
//       before the first one
//   F6  a hold acquired during phase two's re-read was not asked at the
//       removal boundary
//   F7  a finished Prepare released its hold before the prepared set said
//       so; a batch saved by another route was not seen at a copy's turn;
//       an older disk read could overwrite a newer one
//   F8  one volume keyed two ways (UUID / device) counted as two drives
//   F9  a disk image counted as a drive
//   F10 the forecast took the drive from the path's spelling
//   F11 a sibling on a second drive was not read once three were counted
//
// Dimensions: Logic (below) · Scale N/A (every change is O(family) per row
// or O(1) per file; the 100k selection budgets are pinned in
// DeleteDuplicatesAngelHoldTests / ReadOnlyVolumeTests and re-run) · Media
// matrix N/A (synthetic bytes; no media opened beyond the planner's whole-
// file reads) · Isolation (temp catalog, ledger, plan root and Angel buffer
// per test; volume identity, mount identity and drive identity are injected
// — nothing reads the machine's drives) · Sensor (source pins at the end).
//
// Suites: DeleteDuplicatesCodex258HoldBoundaryTests
//
// This file: F6–F7 (the holds at the removal boundary and across a Prepare's end).

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_codex258_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
private func makeModel(_ dir: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
    model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
    return model
}

@MainActor
private func scanTarget(_ path: String) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.role = .workspace
    t.isReachable = true
    return t
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

@MainActor
private func setAngel(_ model: VideoScanModel, prepared: Set<UUID> = [], promoted: Set<UUID> = []) {
    var summary = model.archiveAngel.recommendations
    summary.preparedIDs = prepared
    summary.promotedIDs = promoted
    summary.revision += 1
    model.archiveAngel.publishRecommendations(summary)
}

private let fileSize = FileHasher.segmentSize * 2
private let fileBytes: [UInt8] = (0..<fileSize).map { UInt8($0 % 199) }
private let fileDigest = SHA256.hash(data: Data(fileBytes)).map { String(format: "%02x", $0) }.joined()

/// A lock-protected value a hook on a disk thread and the test can share.
private final class Shared<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline, !condition() { await Task.yield() }
    #expect(condition(), "timed out waiting for: \(what)")
}

/// Two drives cannot be had in one temp folder: R "is on" drive B.
private let secondDrive: @Sendable (String, FileIdentityStamp) -> DeletionTierFacts.Drive = { path, _ in
    path.hasSuffix("/r.mov") ? .init(key: "B", label: "X9") : .init(key: "A", label: "LaCie")
}

// MARK: - F6, F7 — the holds at the removal boundary and across a Prepare's end

@Suite("Codex #258 F6–F7 — a hold is asked at the removal itself, and never lapses in a gap", .serialized)
@MainActor
struct DeleteDuplicatesCodex258HoldBoundaryTests {

    struct Rig {
        let dir: URL
        let root: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let copies: [VideoRecord]
        let environment: AngelEnvironment
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// keeper (NO stored fixity) + two identical copies + the verified
    /// archive family; the Angel reads and writes a buffer of its own.
    private func makeRig(_ label: String) -> Rig {
        let dir = tempDir(label)
        let group = UUID()
        func record(_ name: String, _ disposition: DuplicateDisposition) -> VideoRecord {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data(fileBytes))
            return dupRecord(path: url.path, size: Int64(fileSize), group: group, disposition: disposition)
        }
        let model = makeModel(dir)
        var env = AngelEnvironment.app
        env.bufferRoot = dir.appendingPathComponent("Buffer", isDirectory: true)
        env.evidenceDirectory = dir.appendingPathComponent("evidence", isDirectory: true)
        env.policyOverrideURL = dir.appendingPathComponent("no-policy.json")
        env.isTestHost = true
        model.archiveAngel = ArchiveAngel(model: model, environment: env)
        let keeper = record("keeper.mov", .keep)
        let copies = ["copy1.mov", "copy2.mov"].map { record($0, .extraCopy) }
        model.records = [keeper] + copies
        addVerifiedArchiveFamily(to: model, keeper: keeper)
        return Rig(dir: dir, root: dir.appendingPathComponent("plans", isDirectory: true), model: model,
                   keeper: keeper, copies: copies, environment: env)
    }

    private func readyBatch(for record: VideoRecord, in env: AngelEnvironment, name: String) throws -> ArchiveAngelPlan {
        let folder = env.bufferRoot.appendingPathComponent("batch-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var plan = ArchiveAngelPlan(batchDir: folder.path, requestedCount: 1, makeLossless: false)
        plan.status = .ready
        var entry = ArchiveAngelPlan.Entry(id: record.id, sourcePath: record.fullPath, filename: record.filename, sizeBytes: 1,
                                           durationSeconds: 61, score: 0, evidence: [], proposedName: record.filename)
        entry.status = .ready
        plan.entries = [entry]
        return plan
    }

    /// F6: the keeper has no stored fixity, so phase two re-reads the
    /// quarantined duplicate (minutes, on a big file). A Prepare picks that
    /// very record DURING the re-read. The removal must not happen.
    @Test func aHoldAcquiredDuringPhaseTwosReReadStopsTheRemoval() async throws {
        let rig = makeRig("f6"); defer { rig.cleanup() }
        let chosen = rig.copies[0]
        let before = try Data(contentsOf: URL(fileURLWithPath: chosen.fullPath))
        let center = MediaFileOperationsCenter()
        rig.model.archiveAngel.attach(jobRunner: center)

        // armed: the row is in quarantine and saved (phase two is next).
        let armed = Shared(false), blocked = Shared(false)
        let release = DispatchSemaphore(value: 0)
        var hooks = SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir)
        hooks.didReadBlock = { label in
            guard label == "quarantine", armed.value, !blocked.update({ was in defer { was = true }; return was }) else { return }
            release.wait()
        }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: hooks, planRoot: rig.root)
        job.testHookAfterQuarantineSaved = { entry in if entry.id == chosen.id { armed.value = true } }
        job.start()
        await waitUntil("phase two's re-read of the quarantined duplicate") { blocked.value }

        // The Angel picks the record now: an explicit Prepare, registered and running.
        let prepare = ArchiveAngelJob(model: rig.model, center: center, count: 1, makeLossless: false,
                                      bufferRoot: rig.environment.bufferRoot, explicitRecordIDs: [chosen.id])
        #expect(center.add(prepare) && prepare.state.isActive)
        #expect(rig.model.duplicateDeletionHoldRule()(chosen) == .inUseByAngel, "fixture: the hold is live")
        release.signal()
        await job.task?.value

        #expect(FileManager.default.fileExists(atPath: chosen.fullPath), "removed although the Angel held it before the removal")
        #expect((try? Data(contentsOf: URL(fileURLWithPath: chosen.fullPath))) == before, "put back untouched")
        let row = try #require(job.plan?.entries.first { $0.id == chosen.id })
        #expect(row.status == .skipped && row.note == "left alone — in use by the Archive Angel", "\(row.status): \(row.note)")
        #expect(row.quarantineDirectory == nil, "nothing is left in quarantine")
        #expect(chosen.duplicateDisposition == .extraCopy && rig.model.records.contains { $0 === chosen })
        prepare.refuseToStart(reason: "test: over")
    }

    /// F7: a ready batch is saved AFTER the run planned, by a route that
    /// never refreshes the façade (the Archive tab is closed). At the copy's
    /// turn the run must see it on disk.
    @Test func aBatchSavedAfterPlanningIsSeenAtTheCopysTurn() async throws {
        let rig = makeRig("f7disk"); defer { rig.cleanup() }
        let late = rig.copies[1]
        let batch = try readyBatch(for: late, in: rig.environment, name: "late")
        let saved = Shared(false)
        var hooks = SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir)
        hooks.didReadBlock = { _ in
            // During the FIRST pair's read: the batch lands on disk.
            guard !saved.update({ was in defer { was = true }; return was }) else { return }
            try? ArchiveAngelPlanStore.save(batch)
        }
        let opened = Shared<[String]>([])
        hooks.didOpen = { path in opened.update { $0.append(path) } }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: hooks, planRoot: rig.root)
        job.start()
        await job.task?.value
        #expect(saved.value, "fixture: the batch was saved during the first pair")
        // Seen AT ITS TURN — before a byte of it was read or it was moved
        // aside — not only by the removal boundary's own look at the disk.
        // (The quarantine move keeps the file's name: no path of that name was opened.)
        #expect(!opened.value.contains { ($0 as NSString).lastPathComponent == late.filename },
                "the batch's source was moved aside and read before the batch was seen")
        let plan = try #require(job.plan)
        #expect(plan.entries.map(\.id) == rig.copies.map(\.id), "fixture: both copies were planned (the buffer was empty then)")
        let row = plan.entries[1]
        #expect(row.status == .skipped && row.note == "left alone — in use by the Archive Angel", "\(row.status): \(row.note)")
        #expect(FileManager.default.fileExists(atPath: late.fullPath), "the source of a ready batch on disk was removed")
        #expect(late.duplicateDisposition == .extraCopy)
    }

    /// F7: the hand-over. A Prepare that ends lets go of nothing until a
    /// reading of the buffer that began AFTER it ended has been published.
    @Test func aFinishedPrepareKeepsItsRecordsHeldUntilTheBufferHasBeenReRead() async {
        let rig = makeRig("f7handover"); defer { rig.cleanup() }
        let picked = rig.copies[0]
        let center = MediaFileOperationsCenter()
        rig.model.archiveAngel.attach(jobRunner: center)
        let prepare = ArchiveAngelJob(model: rig.model, center: center, count: 1, makeLossless: false,
                                      bufferRoot: rig.environment.bufferRoot, explicitRecordIDs: [picked.id])
        #expect(center.add(prepare) && prepare.state.isActive)
        #expect(rig.model.duplicateDeletionHoldRule()(picked) == .inUseByAngel)

        prepare.refuseToStart(reason: "test: the Prepare is over")
        #expect(!prepare.state.isActive)
        #expect(rig.model.duplicateDeletionHoldRule()(picked) == .inUseByAngel,
                "the hold lapsed the instant the Prepare ended — before any reading of the buffer said what became of its records")
        if case .authorized = rig.model.authorizeDuplicateDeletion(
            entry: .init(id: picked.id, path: picked.fullPath, filename: picked.filename, sizeBytes: picked.sizeBytes,
                         keeperID: rig.keeper.id, keeperPath: rig.keeper.fullPath, keeperFilename: rig.keeper.filename),
            volumePath: rig.dir.path, crossVolumeMode: false, stage: "before deletion") {
            Issue.record("authorized a record a Prepare had just let go of, before the buffer was re-read")
        }
        // The buffer is re-read (nothing in it: the Prepare prepared nothing):
        // only now is the record ordinary again.
        await rig.model.archiveAngel.refreshRecordIDsInBatchesOnDisk()
        #expect(rig.model.duplicateDeletionHoldRule()(picked) == nil)
    }

    /// F7: two readings of the buffer overlap; the OLDER one (it began
    /// first and saw nothing) finishes last. It must not overwrite the newer.
    @Test func anOlderReadingOfTheBufferNeverOverwritesANewerOne() async {
        let rig = makeRig("f7overlap"); defer { rig.cleanup() }
        let id = rig.copies[0].id
        let calls = Shared(0)
        let (gate, open) = AsyncStream<Void>.makeStream()
        rig.model.archiveAngel.diskBatchReaderForTests = { _ in
            let n = calls.update { $0 += 1; return $0 }
            guard n == 1 else { return [id] }          // the newer reading: the batch is there
            for await _ in gate { break }              // the older reading: held back…
            return []                                  // …and it saw an empty buffer
        }
        let older = Task { @MainActor in await rig.model.archiveAngel.refreshRecordIDsInBatchesOnDisk() }
        await waitUntil("the older reading to start") { calls.value == 1 }
        await rig.model.archiveAngel.refreshRecordIDsInBatchesOnDisk()
        #expect(rig.model.archiveAngel.recordIDsInBatchesOnDisk == [id])
        open.yield()
        open.finish()
        await older.value
        #expect(rig.model.archiveAngel.recordIDsInBatchesOnDisk == [id], "an older, empty reading overwrote the newer one")
        #expect(rig.model.duplicateDeletionHoldRule()(rig.copies[0]) == .inUseByAngel)
    }

    /// F7: a reading that BEGAN before the Prepare ended cannot say what
    /// became of its records — it does not complete the hand-over. Only a
    /// reading begun after the end does.
    @Test func onlyAReadingBegunAfterThePrepareEndedCompletesTheHandOver() async {
        let rig = makeRig("f7sequence"); defer { rig.cleanup() }
        let id = rig.copies[0].id
        let calls = Shared(0)
        let (gate1, open1) = AsyncStream<Void>.makeStream()
        let (gate2, open2) = AsyncStream<Void>.makeStream()
        rig.model.archiveAngel.diskBatchReaderForTests = { _ in
            switch calls.update({ $0 += 1; return $0 }) {
            case 1: for await _ in gate1 { break }
            case 2: for await _ in gate2 { break }
            default: break
            }
            return []
        }
        let early = Task { @MainActor in await rig.model.archiveAngel.refreshRecordIDsInBatchesOnDisk() }
        await waitUntil("the early reading to start") { calls.value == 1 }
        // The Prepare ends NOW, holding the record (this starts a reading of its own).
        rig.model.archiveAngel.notePrepareEnded(holding: [id])
        #expect(rig.model.archiveAngel.recordIDsHandedOver == [id])
        open1.yield(); open1.finish()
        await early.value
        #expect(rig.model.archiveAngel.recordIDsHandedOver == [id],
                "a reading that began BEFORE the Prepare ended released its records")
        #expect(rig.model.duplicateDeletionHoldRule()(rig.copies[0]) == .inUseByAngel)
        open2.yield(); open2.finish()
        await waitUntil("the reading begun after the end to publish") { rig.model.archiveAngel.recordIDsHandedOver.isEmpty }
        #expect(rig.model.duplicateDeletionHoldRule()(rig.copies[0]) == nil, "nothing on disk holds it: ordinary again")
        rig.model.archiveAngel.notePrepareEnded(holding: [])
        #expect(rig.model.archiveAngel.recordIDsHandedOver.isEmpty, "nothing held, nothing handed over")
    }

    /// The Master Archive is designated WHILE phase two re-reads the
    /// quarantined duplicate, and the copy now lies on the archive's folder.
    /// The removal boundary builds the archive protection from the model's
    /// CURRENT designation (nothing at the final verdict comes from a
    /// cache): refused as an ARCHIVE refusal — Review, as main classifies
    /// archive refusals — and put back.
    @Test func aMasterArchiveDesignatedDuringPhaseTwosReReadStopsTheRemoval() async throws {
        let rig = makeRig("f6archive"); defer { rig.cleanup() }
        #expect(rig.model.masterArchive == nil, "fixture: nothing designated at the copy's turn")
        let chosen = rig.copies[0]
        let armed = Shared(false), blocked = Shared(false)
        let release = DispatchSemaphore(value: 0)
        var hooks = SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir)
        hooks.didReadBlock = { label in
            guard label == "quarantine", armed.value, !blocked.update({ was in defer { was = true }; return was }) else { return }
            release.wait()
        }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: hooks, planRoot: rig.root)
        job.testHookAfterQuarantineSaved = { entry in if entry.id == chosen.id { armed.value = true } }
        job.start()
        await waitUntil("phase two's re-read of the quarantined duplicate") { blocked.value }
        rig.model.masterArchive = MasterArchiveDesignation(targetPath: rig.dir.path,
                                                           rootPath: rig.dir.appendingPathComponent("Test_Family_Archive").path, volumeUUID: nil)
        release.signal()
        await job.task?.value

        #expect(FileManager.default.fileExists(atPath: chosen.fullPath), "removed from what is now the Master Archive's folder")
        let row = try #require(job.plan?.entries.first { $0.id == chosen.id })
        #expect(row.status == .refused && row.note.contains("the Master Archive"), "\(row.status): \(row.note)")
        #expect(row.quarantineDirectory == nil, "put back at its path")
        #expect(chosen.duplicateDisposition == .review, "an archive refusal keeps main's classification (Review) — it is not a hold")
        #expect(job.result.deleted == 0)
    }

    /// F6, the Read-only half: the drive is marked Read only WHILE phase
    /// two re-reads the quarantined duplicate. It is put back, untouched.
    @Test func aReadOnlyMarkMadeDuringPhaseTwosReReadStopsTheRemoval() async throws {
        let rig = makeRig("f6readonly"); defer { rig.cleanup() }
        let target = scanTarget(rig.dir.path)
        rig.model.scanTargets = [target]
        let chosen = rig.copies[0]
        let armed = Shared(false), blocked = Shared(false)
        let release = DispatchSemaphore(value: 0)
        var hooks = SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir)
        hooks.didReadBlock = { label in
            guard label == "quarantine", armed.value, !blocked.update({ was in defer { was = true }; return was }) else { return }
            release.wait()
        }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: hooks, planRoot: rig.root)
        job.testHookAfterQuarantineSaved = { entry in if entry.id == chosen.id { armed.value = true } }
        job.start()
        await waitUntil("phase two's re-read of the quarantined duplicate") { blocked.value }
        rig.model.setVolumeReadOnly(true, for: target)
        release.signal()
        await job.task?.value

        #expect(FileManager.default.fileExists(atPath: chosen.fullPath), "removed from a drive marked Read only before the removal")
        let rows = try #require(job.plan?.entries)
        let note = "left alone — lives on \(rig.dir.lastPathComponent), which you marked Read only"
        #expect(rows.map(\.status) == [.skipped, .skipped] && rows.map(\.note) == [note, note], "\(rows.map(\.status)) \(rows.map(\.note))")
        #expect(chosen.duplicateDisposition == .extraCopy && rows[0].quarantineDirectory == nil)
        #expect(job.runTally.skipped == 2 && job.runTally.refused == 0 && job.result.deleted == 0)
    }

    /// The model's last word, and the hop that carries it to a disk thread.
    @Test func theBoundarysWordIsTheHoldRuleAndTheReadOnlyMarksLive() async throws {
        let rig = makeRig("f6word"); defer { rig.cleanup() }
        let target = scanTarget(rig.dir.path)
        rig.model.scanTargets = [target]
        let copy = rig.copies[0]
        // The question as the disk worker asks it (it hands over the path
        // the file is at then).
        let ask = DeleteDuplicatesJob.removalBoundaryHold(model: rig.model, recordID: copy.id, path: copy.fullPath)
        let here = copy.fullPath
        #expect(rig.model.duplicateRemovalBoundaryWord(recordID: copy.id).holdNote == nil)
        #expect(await Task.detached { ask(here) }.value == nil)
        setAngel(rig.model, prepared: [copy.id])
        #expect(rig.model.duplicateRemovalBoundaryWord(recordID: copy.id).holdNote == "left alone — in use by the Archive Angel")
        #expect(await Task.detached { ask(here) }.value == "left alone — in use by the Archive Angel")
        setAngel(rig.model)
        rig.model.setVolumeReadOnly(true, for: target)
        #expect(!rig.model.duplicateRemovalBoundaryWord(recordID: copy.id).readOnlyMarks.isEmpty, "today's marks travel to the disk thread")
        #expect(await Task.detached { ask(here) }.value
                == "left alone — lives on \(rig.dir.lastPathComponent), which you marked Read only")
        rig.model.setVolumeReadOnly(false, for: target)

        // The buffer on disk comes first…
        #expect(await Task.detached { ask(here) }.value == nil)
        try ArchiveAngelPlanStore.save(try readyBatch(for: copy, in: rig.environment, name: "boundary"))
        #expect(rig.model.archiveAngel.recordIDsInBatchesOnDisk.isEmpty, "fixture: the façade has not re-read the buffer")
        #expect(await Task.detached { ask(here) }.value == "left alone — in use by the Archive Angel",
                "a batch on disk the façade has not read yet is not seen at the removal boundary")
        // …and the hop itself runs its body on the main actor, from either side.
        #expect(DeleteDuplicatesJob.onMainActor { MainActor.assertIsolated(); return 7 } == 7)
        #expect(await Task.detached { DeleteDuplicatesJob.onMainActor { MainActor.assertIsolated(); return 8 } }.value == 8)
    }

    /// Sensors: the removal's own verdict asks the holds; the turn reads the
    /// buffer first; the Prepare hands over as its state changes.
    @Test func theBoundaryTheTurnAndTheHandOverAreWired() throws {
        let job = try SourceTree.appSource(named: "DeleteDuplicatesJob.swift")
        let verdict = try #require(job.range(of: "let result = SignatureVerification.deleteQuarantined(ticket, disposal: recorded, hooks: hooks) {"))
        let recheck = try #require(job.range(of: "let now = facts.recheck()", range: verdict.upperBound..<job.endIndex))
        #expect(String(job[verdict.upperBound..<recheck.lowerBound]).contains("if let boundaryHold, let note = boundaryHold(ticket.quarantinedPath) {"),
                "the final verdict no longer asks the holds before the removal")
        #expect(job.components(separatedBy: "SignatureVerification.deleteQuarantined(").count == 2,
                "a second path reaches the removal — it must ask the holds too")
        for (relative, url) in SourceTree.appSources where !relative.hasSuffix("DeleteDuplicatesJob.swift")
            && !relative.hasSuffix("SignatureVerification.swift") {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("SignatureVerification.deleteQuarantined("), "\(relative) removes a quarantined duplicate on its own")
        }
        #expect(job.contains("boundaryHold: Self.removalBoundaryHold(model: model, recordID: entry.id, path: entry.path),"))
        #expect(job.contains("archiveCheck: archiveCheck, boundaryHold: boundaryHold,"))
        #expect(job.contains("if inBatchOnDisk(recordID) { return DuplicateDeletionHold.inUseByAngel.note }")
                && job.contains("return model.duplicateRemovalBoundaryWord(recordID: recordID)")
                && job.contains("?? readOnly.verdictAtRemoval(path: currentPath, probe: uuidProbe, identity: identityProbe)"))
        let dispatch = try #require(job.range(of: "private func dispatchPairs("))
        let authorize = try #require(job.range(of: "switch model.authorizeDuplicateDeletion(entry: entry, volumePath: volumePath,",
                                               range: dispatch.upperBound..<job.endIndex))
        #expect(String(job[dispatch.upperBound..<authorize.lowerBound]).contains("await model.archiveAngel.refreshRecordIDsInBatchesOnDisk()"),
                "a copy's turn no longer reads the Angel's buffer from disk first")
        let model = try SourceTree.appSource(named: "VideoScanModel+Duplicates.swift")
        #expect(model.contains("|| onDisk.contains(r.id) || preparing.contains(r.id) || handedOver.contains(r.id) {"))
        let prepare = try SourceTree.appSource(named: "ArchiveAngelJob.swift")
        #expect(prepare.contains("model?.archiveAngel.notePrepareEnded(holding: Self.heldRecordIDs(explicit: explicitRecordIDs, plan: plan))"))
        let facade = try SourceTree.appSource(named: "ArchiveAngel.swift")
        #expect(facade.contains("guard reading > bufferReadingPublished else { return }"), "an older reading may overwrite a newer one again")
        #expect(facade.contains("handOverSequence = handOverSequence.filter { $0.value > handOversBefore }"))
    }
}
