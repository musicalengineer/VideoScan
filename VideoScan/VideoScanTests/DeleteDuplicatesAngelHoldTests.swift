// DeleteDuplicatesAngelHoldTests.swift
// GH #258 (Rick 2026-10-03): "Delete duplicates on <drive>" leaves alone
// every copy the Archive Angel is USING and every promoted archive copy —
// at SELECTION time, again at the copy's TURN (delete time and resume) and
// once more between a pair's read and its removal, because the Angel's
// batches change while a run is in flight.
//
// The classes held (Rick's ruling 2026-10-03 — "a file in use", or an
// archive copy), one test each:
//   • in a prepared batch                   (recommendations.preparedIDs)
//   • in a batch being / just promoted      (recommendations.promotedIDs)
//   • in a batch ON DISK, whether or not the Archive tab was ever opened
//                                           (recordIDsInBatchesOnDisk)
//   • picked for a Prepare STILL RUNNING    (the running job's own list)
//   • a promoted archive copy while NO Master Archive is designated
// NOT held, and pinned as ordinary copies: one the Angel merely lists as a
// candidate, and one labelled Archived in Triage.
//
// The survival rule is NOT weakened (codex #258 F1): a copy the run leaves
// alone is NEVER counted as a copy that remains for another copy of the
// same run — on main it was a row of that run, "still to be decided", and
// leaving it alone must not turn it into a new survivor. The identical-input
// comparison (hold on vs hold off) is DeleteDuplicatesCodex258SurvivorTests.
//
// Dimensions: Logic (below) · Scale (100k records, 10k Angel ids, the
// selection's existing 2 s budget) · Media matrix N/A (no media is opened
// beyond the planner's existing whole-file reads of synthetic bytes) ·
// Isolation (every model has its own temp catalog, ledger and plan root; the
// Trash step is routed into a scratch folder) · Sensor (one predicate, called
// by the selection, the menu count and the delete-time authorization).
//
// Suite: DeleteDuplicatesAngelHoldTests

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_duphold_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
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
private func dupRecord(path: String, size: Int64 = 1, group: UUID,
                       disposition: DuplicateDisposition) -> VideoRecord {
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

/// Hand the Angel's ONE set of numbers a summary, as a sweep or a batch
/// refresh would (the façade's own writer).
@MainActor
private func setAngel(_ model: VideoScanModel, candidates: Set<UUID> = [], prepared: Set<UUID> = [],
                      promoted: Set<UUID> = []) {
    var summary = model.archiveAngel.recommendations
    summary.candidateIDs = candidates
    summary.preparedIDs = prepared
    summary.promotedIDs = promoted
    summary.revision += 1
    model.archiveAngel.publishRecommendations(summary)
}

private let volume = "/Volumes/SanDisk"
private let blockSize = FileHasher.segmentSize
private let fileSize = blockSize * 3

private func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}

@Suite("Delete Duplicates leaves the Archive Angel's copies alone (GH #258)", .serialized)
@MainActor
struct DeleteDuplicatesAngelHoldTests {

    // MARK: Selection

    /// One drive: keeper + free + in a prepared batch + merely listed by the
    /// Angel + labelled Archived → the batch copy alone is left alone.
    @Test func theRunLeavesAloneOnlyWhatTheAngelIsUsing() {
        let model = makeModel(tempDir("qa"))
        let g = UUID()
        let keeper = dupRecord(path: "\(volume)/keeper.mov", group: g, disposition: .keep)
        let free = dupRecord(path: "\(volume)/free.mov", group: g, disposition: .extraCopy)
        let inBatch = dupRecord(path: "\(volume)/batch.mov", group: g, disposition: .extraCopy)
        let listed = dupRecord(path: "\(volume)/listed.mov", group: g, disposition: .extraCopy)
        let filed = dupRecord(path: "\(volume)/filed.mov", group: g, disposition: .extraCopy)
        filed.lifecycleStage = .archived
        model.records = [keeper, free, inBatch, listed, filed]
        setAngel(model, candidates: [listed.id], prepared: [inBatch.id])

        let selection = model.duplicateDeletionSelection(onVolume: volume)
        #expect(Set(selection.targets.map(\.id)) == [free.id, listed.id, filed.id],
                "a merely-listed copy and an Archived-label copy are ordinary; the batch copy is not")
        #expect(selection.skippedCount == 1)
        #expect(model.volumesWithDeletableDuplicates().map(\.count) == [3], "the menu count agrees with the selection")

        // The copy left alone carries its reason…
        #expect(selection.held.map(\.record.id) == [inBatch.id])
        #expect(selection.held.map(\.hold.note) == ["left alone — in use by the Archive Angel"])
        // …the count is said in one line (the Start confirmation and the
        // finished row use it)…
        #expect(selection.leftAlone.line == "1 copy left alone — in use by the Archive Angel")
        // …and the existing "Skipping N file(s) — …" log line names it.
        #expect(selection.skippedReasons.map(\.reason) == ["left alone — in use by the Archive Angel"])
    }

    /// The two reasons, word for word, and the summary's wording.
    @Test func theReasonsAndTheSummaryLineSayItPlainly() {
        #expect(DuplicateDeletionHold.inUseByAngel.note == "left alone — in use by the Archive Angel")
        #expect(DuplicateDeletionHold.promotedArchiveCopy.note == "left alone — it is a promoted archive copy")
        #expect(DuplicateDeletionHold.allCases.count == 2, "a class was added or dropped — the ruling of 2026-10-03 names two")
        #expect(Set(DuplicateDeletionHold.allCases.map(\.note)).count == 2, "the plan tells the kinds apart by their words")
        var counts = DeleteDuplicatesPlan.LeftAloneCounts()
        #expect(counts.line == nil && counts.total == 0)
        counts.add(.inUseByAngel)
        #expect(counts.line == "1 copy left alone — in use by the Archive Angel")
        counts.add(.inUseByAngel)
        #expect(counts.line == "2 copies left alone — in use by the Archive Angel")
        counts.add(.promotedArchiveCopy)
        #expect(counts.line == "2 copies left alone — in use by the Archive Angel · 1 promoted archive copy left alone"
                && counts.total == 3)
    }

    /// The plan lists them with their reasons (the detail view's rows) —
    /// never as rows of the run — and an older plan.json still decodes.
    @Test func thePlanListsTheCopiesLeftAloneAndOlderPlansStillDecode() async throws {
        let dir = tempDir("plan")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let here = dir.path
        let g = UUID()
        let keeper = dupRecord(path: "\(here)/keeper.mov", size: 10, group: g, disposition: .keep)
        let free = dupRecord(path: "\(here)/free.mov", size: 10, group: g, disposition: .extraCopy)
        let angel = dupRecord(path: "\(here)/angel.mov", size: 30, group: g, disposition: .extraCopy)
        let promoted = dupRecord(path: "\(here)/promoted.mov", size: 40, group: g, disposition: .extraCopy)
        promoted.derivationKind = ArchivePromotion.derivationKind
        model.records = [keeper, free, angel, promoted]
        setAngel(model, prepared: [angel.id])

        let plan = try #require(await model.prepareDuplicateDeletion(onVolume: here))
        #expect(plan.entries.map(\.id) == [free.id], "only the free copy is a row of the run")
        let listed = try #require(plan.leftAloneCopies)
        #expect(listed.map(\.id) == [angel.id, promoted.id])
        #expect(listed.map(\.reason) == ["left alone — in use by the Archive Angel",
                                         "left alone — it is a promoted archive copy"])
        #expect(listed.map(\.sizeBytes) == [30, 40] && listed.map(\.filename) == ["angel.mov", "promoted.mov"])
        #expect(plan.leftAloneAtPlan == DeleteDuplicatesPlan.LeftAloneCounts(forAngel: 1, archived: 1))
        #expect(plan.skippedBeforePlan == 2)
        #expect(plan.leftAlone.line == "1 copy left alone — in use by the Archive Angel · 1 promoted archive copy left alone")
        // The detail view's words for them.
        #expect(DeleteDuplicatesLeftAloneList.rowText(listed[0]).hasSuffix("— left alone — in use by the Archive Angel"))
        #expect(DeleteDuplicatesLeftAloneList.headerText(summary: plan.leftAloneAtPlan?.line ?? "")
                == "Never part of this run: 1 copy left alone — in use by the Archive Angel · 1 promoted archive copy left alone")
        #expect(DeleteDuplicatesLeftAloneList.moreText(total: 250, shown: 200) == "… and 50 more")
        #expect(DeleteDuplicatesLeftAloneList.moreText(total: 2, shown: 2) == nil)

        // Round trip, and a plan written BEFORE these fields existed.
        let root = dir.appendingPathComponent("plans", isDirectory: true)
        try DeleteDuplicatesPlanStore.save(plan, root: root)
        let url = DeleteDuplicatesPlanStore.planURL(for: plan.id, root: root)
        // (Field by field: the store writes dates to the second.)
        let reloaded = try DeleteDuplicatesPlanStore.load(url: url)
        #expect(reloaded.leftAloneCopies == plan.leftAloneCopies && reloaded.leftAloneAtPlan == plan.leftAloneAtPlan)
        #expect(reloaded.entries == plan.entries && reloaded.skippedBeforePlan == plan.skippedBeforePlan)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["leftAloneCopies"] != nil && json["leftAloneAtPlan"] != nil)
        json["leftAloneCopies"] = nil
        json["leftAloneAtPlan"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let old = try DeleteDuplicatesPlanStore.load(url: url)
        #expect(old.leftAloneCopies == nil && old.leftAloneAtPlan == nil && old.entries == plan.entries)
        #expect(old.leftAlone.line == nil)

        // With NOTHING else to do, the run still says what it left alone.
        free.duplicateDisposition = .review
        let job = DeleteDuplicatesJob(model: model, volumePath: here, planRoot: root)
        job.start()
        await job.task?.value
        #expect(job.state == .finished(summary: "No duplicates to delete on \(dir.lastPathComponent) — 2 skipped"
                                       + " · 1 copy left alone — in use by the Archive Angel · 1 promoted archive copy left alone"), "\(job.state)")
        #expect(job.plan?.leftAloneCopies?.count == 2 && job.plan?.entries.isEmpty == true)
    }

    /// The running Prepare's own list: rows on their way into the batch
    /// hold their record; a skipped or failed row is free; the hand-picked
    /// ids count only until the plan has rows.
    @Test func aRunningPrepareHoldsItsRowsAndUntilItHasRowsItsHandPickedRecords() {
        let ids = (0..<6).map { _ in UUID() }
        var plan = ArchiveAngelPlan(batchDir: "/tmp/test_duphold_batch", requestedCount: 6, makeLossless: false)
        #expect(ArchiveAngelJob.heldRecordIDs(explicit: ids, plan: plan) == Set(ids), "picked by hand, not planned yet")
        #expect(ArchiveAngelJob.heldRecordIDs(explicit: nil, plan: plan).isEmpty)
        let statuses: [ArchiveAngelPlan.EntryStatus] = [.pending, .preparing, .ready, .skipped, .failed, .promoted]
        plan.entries = zip(ids, statuses).map { id, status in
            var e = ArchiveAngelPlan.Entry(id: id, sourcePath: "/Volumes/SanDisk/\(id).mov", filename: "\(id).mov", sizeBytes: 1,
                                           durationSeconds: 61, score: 0, evidence: [], proposedName: "\(id).mov")
            e.status = status
            return e
        }
        #expect(ArchiveAngelJob.heldRecordIDs(explicit: ids, plan: plan) == Set(ids.prefix(3)),
                "pending / preparing / ready hold; skipped, failed and promoted rows are free")
    }

    /// The Storage tab's Reclaimable estimate: a copy the run would leave
    /// alone is not reclaimable, but still counts as a sibling.
    @Test func theReclaimableEstimateDoesNotCountCopiesTheRunLeavesAlone() {
        let model = makeModel(tempDir("reclaim"))
        let g = UUID()
        let keeper = dupRecord(path: "\(volume)/keeper.mov", size: 100, group: g, disposition: .keep)
        let free = dupRecord(path: "\(volume)/free.mov", size: 100, group: g, disposition: .extraCopy)
        let angel = dupRecord(path: "\(volume)/angel.mov", size: 100, group: g, disposition: .extraCopy)
        model.records = [keeper, free, angel]
        setAngel(model, prepared: [angel.id])
        let hold = model.duplicateDeletionHoldRule()
        let inputs = ReclaimableCalculator.project(model.records, leftAlone: { hold($0) != nil })
        #expect(inputs.map(\.isExtraCopy) == [false, true, false])
        let estimate = ReclaimableCalculator.compute(inputs: inputs, volumeRoot: volume, mountedRoots: [volume],
                                                     alsoCleanUpWorkingCopies: false)
        #expect(estimate.copies == 1 && estimate.bytes == 100, "the estimate counted the Angel's copy as reclaimable")
        #expect(model.volumesWithDeletableDuplicates().map(\.count) == [estimate.copies], "the card and the Delete step agree")
        // Without the rule (the old projection) it over-stated.
        #expect(ReclaimableCalculator.compute(inputs: ReclaimableCalculator.project(model.records), volumeRoot: volume,
                                              mountedRoots: [volume], alsoCleanUpWorkingCopies: false).copies == 2)
    }

    /// NOT held (ruling 2026-10-03): the Angel merely LISTS the copy as a
    /// candidate. (It never does today — its own `extraCopy` rule keeps an
    /// Extra copy out of the recommendations; ArchiveAngelExtraCopyGuardTests.)
    @Test func aCopyTheAngelMerelyListsIsAnOrdinaryCopy() {
        let model = makeModel(tempDir("listed"))
        let g = UUID()
        let listed = dupRecord(path: "\(volume)/listed.mov", group: g, disposition: .extraCopy)
        let free = dupRecord(path: "\(volume)/free.mov", group: g, disposition: .extraCopy)
        model.records = [dupRecord(path: "\(volume)/keeper.mov", group: g, disposition: .keep), listed, free]
        setAngel(model, candidates: [listed.id])
        let selection = model.duplicateDeletionSelection(onVolume: volume)
        #expect(Set(selection.targets.map(\.id)) == [listed.id, free.id] && selection.held.isEmpty)
        #expect(model.duplicateDeletionHoldRule()(listed) == nil)
    }

    @Test func class2ACopyInAPreparedBatchOrJustPromotedIsNeverATarget() {
        let model = makeModel(tempDir("c2"))
        let g = UUID()
        let prepared = dupRecord(path: "\(volume)/prepared.mov", group: g, disposition: .extraCopy)
        let promoted = dupRecord(path: "\(volume)/promoted.mov", group: g, disposition: .extraCopy)
        let free = dupRecord(path: "\(volume)/free.mov", group: g, disposition: .extraCopy)
        model.records = [dupRecord(path: "\(volume)/keeper.mov", group: g, disposition: .keep), prepared, promoted, free]
        func targets() -> Set<UUID> { Set(model.duplicateDeletionSelection(onVolume: volume).targets.map(\.id)) }
        setAngel(model, prepared: [prepared.id])
        #expect(targets() == [promoted.id, free.id], "a copy in a prepared batch was offered")
        setAngel(model, promoted: [promoted.id])
        #expect(targets() == [prepared.id, free.id], "the source of a batch just promoted was offered")
        setAngel(model, prepared: [prepared.id], promoted: [promoted.id])
        #expect(targets() == [free.id])
    }

    /// The Prepare job Rick started by hand is still running: its picks are
    /// in no published set yet (the batch is not `ready`), only in the job.
    @Test func class3ACopyHandPickedForAPrepareStillRunningIsNeverATarget() async {
        let dir = tempDir("c3")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let g = UUID()
        let picked = dupRecord(path: "\(volume)/picked.mov", group: g, disposition: .extraCopy)
        let free = dupRecord(path: "\(volume)/free.mov", group: g, disposition: .extraCopy)
        model.records = [dupRecord(path: "\(volume)/keeper.mov", group: g, disposition: .keep), picked, free]

        let center = MediaFileOperationsCenter()
        model.archiveAngel.attach(jobRunner: center)
        // Registered and active (a job is `.running` from the moment it is
        // made); never started — no file is touched.
        let job = ArchiveAngelJob(model: model, center: center, count: 1, makeLossless: false,
                                  bufferRoot: dir.appendingPathComponent("buffer", isDirectory: true),
                                  explicitRecordIDs: [picked.id])
        #expect(center.add(job) && job.state.isActive)
        #expect(model.archiveAngel.recommendations.preparedIDs.isEmpty, "fixture: the pick is in no published set")
        #expect(model.duplicateDeletionSelection(onVolume: volume).targets.map(\.id) == [free.id])

        // Once that Prepare is over it hands its records over (codex #258
        // F7): still held until the buffer has been re-read; then the copy
        // is ordinary again (a batch that became ready is the prepared
        // set's business — class 2).
        job.refuseToStart(reason: "test: over")
        #expect(!job.state.isActive)
        #expect(model.duplicateDeletionSelection(onVolume: volume).targets.map(\.id) == [free.id], "no gap at the Prepare's end")
        await model.archiveAngel.refreshRecordIDsInBatchesOnDisk()
        #expect(Set(model.duplicateDeletionSelection(onVolume: volume).targets.map(\.id)) == [picked.id, free.id])
    }

    /// NOT held (ruling 2026-10-03): the Archived label in Triage. The copy
    /// may go; the label follows the keeper (DuplicateKeeperCarryOverTests).
    @Test func aCopyLabelledArchivedInTriageIsAnOrdinaryCopy() {
        let model = makeModel(tempDir("label"))
        let g = UUID()
        let filed = dupRecord(path: "\(volume)/filed.mov", group: g, disposition: .extraCopy)
        filed.lifecycleStage = .archived
        let free = dupRecord(path: "\(volume)/free.mov", group: g, disposition: .extraCopy)
        model.records = [dupRecord(path: "\(volume)/keeper.mov", group: g, disposition: .keep), filed, free]
        let selection = model.duplicateDeletionSelection(onVolume: volume)
        #expect(Set(selection.targets.map(\.id)) == [filed.id, free.id] && selection.held.isEmpty)
        #expect(model.duplicateDeletionHoldRule()(filed) == nil)
    }

    /// A batch ON DISK holds its rows even when the Archive tab was never
    /// opened this launch (nothing published `preparedIDs`) — read from the
    /// buffer's own plan files, and STRICTLY read-only: a batch a quit left
    /// `preparing` (which the Archive tab's refresh would settle or remove)
    /// is not touched.
    @Test func aBatchOnDiskHoldsItsRowsWithoutTheArchiveTabAndTheReadChangesNothing() async throws {
        let dir = tempDir("ondisk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        var env = AngelEnvironment.app
        env.bufferRoot = dir.appendingPathComponent("Buffer", isDirectory: true)
        env.evidenceDirectory = dir.appendingPathComponent("evidence", isDirectory: true)
        env.policyOverrideURL = dir.appendingPathComponent("no-policy.json")
        env.isTestHost = true
        model.archiveAngel = ArchiveAngel(model: model, environment: env)

        let g = UUID()
        let ready = dupRecord(path: "\(volume)/ready.mov", group: g, disposition: .extraCopy)
        let promoting = dupRecord(path: "\(volume)/promoting.mov", group: g, disposition: .extraCopy)
        let skipped = dupRecord(path: "\(volume)/skipped.mov", group: g, disposition: .extraCopy)
        let interrupted = dupRecord(path: "\(volume)/interrupted.mov", group: g, disposition: .extraCopy)
        let free = dupRecord(path: "\(volume)/free.mov", group: g, disposition: .extraCopy)
        model.records = [dupRecord(path: "\(volume)/keeper.mov", group: g, disposition: .keep),
                         ready, promoting, skipped, interrupted, free]

        func batch(_ name: String, _ status: ArchiveAngelPlan.Status,
                   _ rows: [(VideoRecord, ArchiveAngelPlan.EntryStatus)]) throws -> ArchiveAngelPlan {
            let folder = env.bufferRoot.appendingPathComponent("batch-\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var plan = ArchiveAngelPlan(batchDir: folder.path, requestedCount: rows.count, makeLossless: false)
            plan.status = status
            plan.entries = rows.map { record, rowStatus in
                var e = ArchiveAngelPlan.Entry(id: record.id, sourcePath: record.fullPath, filename: record.filename,
                                               sizeBytes: 1, durationSeconds: 61, score: 0, evidence: [],
                                               proposedName: record.filename)
                e.status = rowStatus
                return e
            }
            try ArchiveAngelPlanStore.save(plan)
            return plan
        }
        _ = try batch("ready", .ready, [(ready, .ready), (skipped, .skipped)])
        _ = try batch("promoting", .promoting, [(promoting, .ready)])
        // A batch a quit left `preparing` two hours ago: interrupted — its
        // rows are free again, and it is the Archive tab's to settle.
        let stale = try batch("stale", .preparing, [(interrupted, .pending)])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7_200)],
                                              ofItemAtPath: stale.planURL.path)
        func fingerprint() throws -> [String] {
            try FileManager.default.subpathsOfDirectory(atPath: env.bufferRoot.path).sorted().map { rel in
                let path = env.bufferRoot.appendingPathComponent(rel).path
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                let bytes = (attrs[.type] as? FileAttributeType) == .typeRegular ? FileManager.default.contents(atPath: path) : nil
                return "\(rel)|\(String(describing: attrs[.modificationDate]))|\(bytes?.count ?? -1)|\(bytes.map { sha256([UInt8]($0)) } ?? "")"
            }
        }
        let before = try fingerprint()

        // Nothing has been read yet, and no tab published anything.
        #expect(model.archiveAngel.recommendations.preparedIDs.isEmpty && model.archiveAngel.recordIDsInBatchesOnDisk.isEmpty)
        // Planning reads the buffer itself.
        let plan = try #require(await model.prepareDuplicateDeletion(onVolume: volume))
        #expect(model.archiveAngel.recordIDsInBatchesOnDisk == [ready.id, promoting.id])
        #expect(Set(plan.entries.map(\.id)) == [skipped.id, interrupted.id, free.id],
                "ready rows of a ready or promoting batch are held; a skipped row and an interrupted batch's rows are free")
        #expect(plan.leftAloneCopies?.map(\.reason) == ["left alone — in use by the Archive Angel",
                                                        "left alone — in use by the Archive Angel"])
        #expect(try fingerprint() == before, "reading which records the batches hold changed the buffer")

        // The same answer through the launch path's own function.
        #expect(await ArchiveAngel.readRecordIDsInBatches(bufferRoot: env.bufferRoot) == [ready.id, promoting.id])
        #expect(try fingerprint() == before)
    }

    /// `bulkDeleteRefusal` answers nil when no Master Archive is designated,
    /// so a promoted copy used to be an ordinary target then.
    @Test func class5APromotedCopyIsNeverATargetEvenWithNoMasterArchiveDesignated() {
        let model = makeModel(tempDir("c5"))
        #expect(model.masterArchive == nil, "fixture: nothing designated")
        let g = UUID()
        let promoted = dupRecord(path: "\(volume)/promoted.mov", group: g, disposition: .extraCopy)
        promoted.derivationKind = ArchivePromotion.derivationKind
        let free = dupRecord(path: "\(volume)/free.mov", group: g, disposition: .extraCopy)
        model.records = [dupRecord(path: "\(volume)/keeper.mov", group: g, disposition: .keep), promoted, free]
        #expect(model.bulkDeleteRefusal(promoted) == nil, "fixture: the archive rule alone says nothing here")
        #expect(model.duplicateDeletionSelection(onVolume: volume).targets.map(\.id) == [free.id])
    }

    /// Working-copy mode reaches copies whose keeper is on another drive:
    /// the same rule holds there.
    @Test func theRuleHoldsForWorkingCopiesToo() {
        let model = makeModel(tempDir("cross"))
        // The fixture DuplicateCrossVolumeDeleteTests.selectionScale100k
        // uses: the keeper's drive outranks the working drive.
        let working = "/Volumes/CrucialX9"
        model.scanTargets = ["/Volumes/LaCieWorkspace", working].map {
            let t = CatalogScanTarget(searchPath: $0)
            t.role = .workspace
            t.isReachable = true
            return t
        }
        model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        let g = UUID()
        let chosen = dupRecord(path: "\(working)/chosen.mov", group: g, disposition: .extraCopy)
        let free = dupRecord(path: "\(working)/free.mov", group: g, disposition: .extraCopy)
        model.records = [dupRecord(path: "/Volumes/LaCieWorkspace/keeper.mov", group: g, disposition: .keep), chosen, free]
        #expect(Set(model.duplicateDeletionSelection(onVolume: working).targets.map(\.id)) == [chosen.id, free.id],
                "fixture: both working copies are eligible before the Angel chooses one")
        setAngel(model, prepared: [chosen.id])
        let selection = model.duplicateDeletionSelection(onVolume: working)
        #expect(selection.targets.map(\.id) == [free.id] && selection.crossVolumeCount == 1)
        #expect(model.volumesWithDeletableDuplicates().map(\.count) == [1])
    }

    // MARK: Delete time (the copy's turn)

    private struct Rig {
        let dir: URL
        let root: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let copies: [VideoRecord]
        let digest: String
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// keeper + two identical copies in one folder (the "drive"), with the
    /// archive copy + verified sibling a permanent deletion needs.
    private func makeRig(_ label: String, family: Bool = true) -> Rig {
        let dir = tempDir(label)
        let bytes = (0..<fileSize).map { UInt8($0 % 197) }
        func file(_ name: String) -> String {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
            return url.path
        }
        let group = UUID()
        let model = makeModel(dir)
        let keeper = dupRecord(path: file("keeper.mov"), size: Int64(fileSize), group: group, disposition: .keep)
        let copies = ["copy1.mov", "copy2.mov"].map {
            dupRecord(path: file($0), size: Int64(fileSize), group: group, disposition: .extraCopy)
        }
        model.records = [keeper] + copies
        if family { addVerifiedArchiveFamily(to: model, keeper: keeper) }
        return Rig(dir: dir, root: dir.appendingPathComponent("plans", isDirectory: true), model: model,
                   keeper: keeper, copies: copies, digest: sha256(bytes))
    }

    /// Planned as an ordinary copy; the Angel chooses it before its turn.
    @Test func aCopyTheAngelChoosesAfterPlanningIsLeftAloneAtItsTurn() async throws {
        let rig = makeRig("turn"); defer { rig.cleanup() }
        let hooks = SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir)
        let plan = try #require(await rig.model.prepareDuplicateDeletion(onVolume: rig.dir.path))
        #expect(plan.entries.map(\.id) == rig.copies.map(\.id), "fixture: both copies were planned")
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)

        // The Angel's sweep lands while the run is in flight.
        setAngel(rig.model, prepared: [rig.copies[1].id])

        // The live authorization, asked directly…
        switch rig.model.authorizeDuplicateDeletion(entry: plan.entries[1], volumePath: rig.dir.path,
                                                    crossVolumeMode: false, stage: "before deletion") {
        case .skip(let note, _, _):
            #expect(note == "left alone — in use by the Archive Angel")
        case .authorized: Issue.record("authorized the Angel's copy for deletion")
        case .refuse(let note): Issue.record("refused (which re-marks the row Review) instead of leaving it alone: \(note)")
        }
        if case .authorized = rig.model.authorizeDuplicateDeletion(entry: plan.entries[0], volumePath: rig.dir.path,
                                                                   crossVolumeMode: false, stage: "before deletion") {} else {
            Issue.record("the free copy must still be authorized")
        }

        // …and by a job handed that plan (the fresh-run turn is the next test).
        let job = DeleteDuplicatesJob(model: rig.model, resuming: plan, hooks: hooks, planRoot: rig.root)
        job.start()
        await job.task?.value
        let after = try #require(job.plan)
        #expect(after.entries.map(\.status) == [.trashed, .skipped], "\(after.entries.map(\.status))")
        #expect(after.entries[1].note == "left alone — in use by the Archive Angel")
        #expect(!FileManager.default.fileExists(atPath: rig.copies[0].fullPath))
        #expect(FileManager.default.fileExists(atPath: rig.copies[1].fullPath), "the Angel's copy was unlinked or trashed")
        #expect(!FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("Trash/\(rig.copies[1].filename)").path),
                "the Angel's copy did not go to the Trash")
        #expect(rig.copies[1].duplicateDisposition == .extraCopy, "left alone is not a refusal — the row is not re-marked Review")
        #expect(rig.model.records.contains { $0 === rig.copies[1] }, "its catalog row stays")
        #expect(job.result.deleted == 1 && job.result.failed == 0)
    }

    /// The same, in a FRESH run: the first pair is held mid-read, the
    /// Angel's sweep lands, the run goes on to the second copy.
    @Test func aFreshRunLeavesAloneACopyTheAngelChoosesMidRun() async throws {
        let rig = makeRig("midrun"); defer { rig.cleanup() }
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var started = false
        var hooks = SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir)
        hooks.didReadBlock = { label in
            // The first pair's first read of its duplicate: hold it there.
            guard label == "duplicate", lock.withLock({ () -> Bool in
                if started { return false }
                started = true
                return true
            }) else { return }
            release.wait()
        }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: hooks, planRoot: rig.root)
        job.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !lock.withLock({ started }) { await Task.yield() }
        #expect(lock.withLock { started })
        #expect(job.plan?.entries.map(\.id) == rig.copies.map(\.id), "fixture: both copies were planned")

        setAngel(rig.model, prepared: [rig.copies[1].id])
        release.signal()
        await job.task?.value

        let after = try #require(job.plan)
        #expect(after.entries.map(\.status) == [.trashed, .skipped], "\(after.entries.map(\.status))")
        #expect(after.entries[1].note == "left alone — in use by the Archive Angel")
        #expect(FileManager.default.fileExists(atPath: rig.copies[1].fullPath), "the Angel's copy was unlinked or trashed")
        #expect(rig.copies[1].duplicateDisposition == .extraCopy)
        #expect(job.result.deleted == 1 && job.result.failed == 0)
    }

    /// The narrowest window: the copy was authorized at its turn, and the
    /// Angel chooses it WHILE its pair is being read — after the file was
    /// moved aside, before the removal. It is put back at its own path,
    /// untouched, and the run goes on.
    @Test func aCopyTheAngelChoosesWhileItIsBeingReadIsPutBackNotRemoved() async throws {
        let rig = makeRig("boundary"); defer { rig.cleanup() }
        let chosen = rig.copies[0]
        let before = try Data(contentsOf: URL(fileURLWithPath: chosen.fullPath))
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir), planRoot: rig.root)
        var sawQuarantine = false
        // Runs on the main actor once the row is verified and in quarantine,
        // immediately before the removal phase would start.
        job.testHookAfterQuarantineSaved = { entry in
            guard entry.id == chosen.id else { return }
            sawQuarantine = true
            setAngel(rig.model, prepared: [chosen.id])
        }
        job.start()
        await job.task?.value

        #expect(sawQuarantine, "fixture: the copy was verified and moved aside before the Angel chose it")
        let after = try #require(job.plan)
        #expect(after.entries.map(\.status) == [.skipped, .trashed], "\(after.entries.map(\.status))")
        #expect(after.entries[0].note == "left alone — in use by the Archive Angel")
        #expect(after.entries[0].quarantineDirectory == nil && after.entries[0].tier == nil)
        #expect(FileManager.default.fileExists(atPath: chosen.fullPath), "the Angel's copy was removed after it was chosen")
        #expect(try Data(contentsOf: URL(fileURLWithPath: chosen.fullPath)) == before, "put back untouched")
        #expect(chosen.duplicateDisposition == .extraCopy && rig.model.records.contains { $0 === chosen })
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: rig.dir.path)
            .filter { $0.hasPrefix(DeleteDuplicatesJob.quarantinePrefix) }
        #expect(leftovers.isEmpty, "nothing left in quarantine: \(leftovers)")
        #expect(!FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("Trash/\(chosen.filename)").path),
                "the Angel's copy is not in the Trash")
        #expect(job.runTally.skipped == 1 && job.runTally.leftAlone == 0 && job.runTally.refused == 0,
                "a skip — not the tier's ‘too few copies’, not a refusal")
        #expect(job.result.deleted == 1 && job.result.failed == 0)
        let moved = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        let volume = VolumeReachability.volumeName(forPath: rig.copies[1].fullPath)
        #expect(job.state == .finished(summary: "0 deleted · 1 to the Trash · \(moved) waiting in the Trash of \(volume) · 1 copy left alone — in use by the Archive Angel"),
                "\(job.state)")
        await rig.model.mediaLedger.waitForPendingWrites()
        #expect(rig.model.mediaLedger.allEvents().filter { $0.event == .copyTrashed }.map(\.filename) == ["copy2.mov"])
    }

    /// A saved plan, revalidated later: every class is re-asked.
    @Test func resumeLeavesAloneWhatWentIntoABatchOrTheArchiveSinceThePlan() async throws {
        let rig = makeRig("resume"); defer { rig.cleanup() }
        let plan = try #require(await rig.model.prepareDuplicateDeletion(onVolume: rig.dir.path))
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)

        // Between sessions: one copy went into a prepared batch, the other
        // was promoted (it is an archive copy now).
        setAngel(rig.model, prepared: [rig.copies[0].id])
        rig.copies[1].derivationKind = ArchivePromotion.derivationKind

        rig.model.checkForUnfinishedDeleteDuplicatesPlans(root: rig.root)
        let pending = try #require(rig.model.pendingDeleteDuplicatesResume)
        let job = MediaFileOperationsCenter().resumeDeleteDuplicates(plan: pending, model: rig.model, planRoot: rig.root)
        await job.task?.value

        let after = try #require(job.plan)
        #expect(after.entries.map(\.status) == [.skipped, .skipped])
        #expect(after.entries[0].note == "left alone — in use by the Archive Angel")
        #expect(after.entries[1].note == "left alone — it is a promoted archive copy")
        for copy in rig.copies {
            #expect(FileManager.default.fileExists(atPath: copy.fullPath))
            #expect(copy.duplicateDisposition == .extraCopy)
        }
        #expect(job.result.deleted == 0 && job.result.failed == 0)
        #expect(rig.model.records.count == 5, "no row left the catalog")
    }

    // MARK: The survival rule is unchanged

    /// A copy the run leaves alone is NEVER counted for another copy of the
    /// run, whatever its stored evidence says (codex #258 F1); a plain
    /// non-target sibling (a Review row — never a row of the run on main
    /// either) counts when its stored evidence reproduces.
    @Test func aCopyLeftAloneIsNeverCountedAndAPlainSiblingCountsByItsEvidence() throws {
        let other = String(repeating: "cd", count: 32)
        for (label, evidence, expected) in [("matching", Optional("same"), 2), ("different", Optional(other), 1),
                                            ("none", String?.none, 1)] {
            var remaining: [Int] = []
            for heldByAngel in [true, false] {
                let rig = makeRig("survive", family: false); defer { rig.cleanup() }
                let free = rig.copies[0], sibling = rig.copies[1]
                rig.keeper.contentFixity = ContentFixity.captured(path: rig.keeper.fullPath, digest: rig.digest,
                                                                  byteCount: Int64(fileSize))
                if let evidence {
                    sibling.contentFixity = ContentFixity.captured(path: sibling.fullPath,
                                                                   digest: evidence == "same" ? rig.digest : evidence,
                                                                   byteCount: Int64(fileSize))
                }
                if heldByAngel {
                    setAngel(rig.model, prepared: [sibling.id])
                } else {
                    sibling.duplicateDisposition = .review          // the control: a plain non-target sibling
                }
                let selection = rig.model.duplicateDeletionSelection(onVolume: rig.dir.path)
                #expect(selection.targets.map(\.id) == [free.id], "\(label), Angel \(heldByAngel)")
                // As the job asks: through the run's own survivor rule.
                var run = DuplicateRunScope(volumePath: rig.dir.path)
                run.pending = Set(selection.targets.map(\.id)).subtracting([free.id])
                let candidates = rig.model.deletionTierCandidates(record: free, keeper: rig.keeper, run: run)
                if heldByAngel {
                    #expect(candidates.otherCopies.isEmpty, "the held copy is not asked about as a sibling")
                    #expect(candidates.leftAloneByRun == ["sibling copy2.mov on \(VolumeReachability.volumeName(forPath: sibling.fullPath)) not counted (in use by the Archive Angel)"])
                } else {
                    #expect(candidates.otherCopies.map(\.recordID) == [sibling.id] && candidates.leftAloneByRun.isEmpty)
                }
                #expect(candidates.archiveCopies.isEmpty && candidates.alsoInThisRun.isEmpty)
                remaining.append(DeletionTierFacts.gather(candidates, digest: rig.digest).remainingVerifiedCopies)
            }
            #expect(remaining == [1, expected],
                    "\(label) evidence: the Angel's copy counted \(remaining[0]) (must be the keeper alone), a plain sibling \(remaining[1])")
        }
    }

    /// End to end (codex #258 F1 — this test used to pin the opposite):
    /// keeper + the Angel's verified copy + a free copy. The Angel's copy is
    /// never a row of the run AND never a survivor for the free copy — only
    /// the keeper would remain, so the free copy is left alone, exactly as
    /// on main, where the Angel's copy was a pending row of the same run.
    @Test func theAngelsVerifiedCopyDoesNotEarnTheFreeCopyTheTrash() async throws {
        let rig = makeRig("tier", family: false); defer { rig.cleanup() }
        let free = rig.copies[0], angel = rig.copies[1]
        angel.contentFixity = ContentFixity.captured(path: angel.fullPath, digest: rig.digest, byteCount: Int64(fileSize))
        setAngel(rig.model, prepared: [angel.id])
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir), planRoot: rig.root)
        job.start()
        await job.task?.value
        let plan = try #require(job.plan)
        #expect(plan.entries.map(\.id) == [free.id], "the Angel's copy is not a row of the run")
        #expect(plan.entries.first?.status == .skipped, "\(String(describing: plan.entries.first?.status)) — \(plan.entries.first?.note ?? "")")
        #expect(plan.entries.first?.remainingVerifiedCopies == 1)
        #expect(FileManager.default.fileExists(atPath: free.fullPath), "the free copy left the drive on the strength of a held copy")
        #expect(FileManager.default.fileExists(atPath: angel.fullPath) && FileManager.default.fileExists(atPath: rig.keeper.fullPath))
        #expect(angel.duplicateDisposition == .extraCopy)
    }

    // MARK: Scale

    /// 100k records, 10k of them the Angel's: set lookups, no O(n·m). The
    /// selection's existing budget (DeleteDuplicatesSafetyTests.planningScale100k).
    @Test("100k selection with 10k Angel ids stays within the selection budget", .timeLimit(.minutes(1)))
    func selectionScale100kWithTenThousandAngelIDs() {
        let model = makeModel(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_duphold_scale"))
        let scaleVolume = "/Volumes/ScaleHold"
        let group = UUID()
        var catalog: [VideoRecord] = []
        catalog.reserveCapacity(100_000)
        catalog.append(dupRecord(path: "\(scaleVolume)/keeper.mov", group: group, disposition: .keep))
        var chosen = Set<UUID>(), prepared = Set<UUID>(), filed = 0
        for index in 1..<100_000 {
            let r = dupRecord(path: "\(scaleVolume)/copy-\(index).mov", group: group, disposition: .extraCopy)
            switch (index - 1) % 20 {
            case 0: chosen.insert(r.id)
            case 1: prepared.insert(r.id)
            case 2: r.lifecycleStage = .archived; filed += 1      // a label: NOT held
            default: break
            }
            catalog.append(r)
        }
        model.records = catalog
        setAngel(model, prepared: chosen, promoted: prepared)
        #expect(chosen.count + prepared.count == 10_000)

        let start = ContinuousClock.now
        let selection = model.duplicateDeletionSelection(onVolume: scaleVolume)
        let elapsed = start.duration(to: .now)
        #expect(filed == 5_000 && selection.targets.count == 99_999 - 10_000)
        #expect(selection.skippedCount == 10_000)
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(2)), "100k selection with 10k Angel ids took \(elapsed)")
    }

    // MARK: Sensor

    /// ONE predicate, asked by the selection, the menu count AND the
    /// delete-time authorization — so a later edit cannot drop one side.
    @Test func theSelectionTheMenuCountAndTheAuthorizationAllAskTheOnePredicate() throws {
        let source = try SourceTree.appSource(named: "VideoScanModel+Duplicates.swift")
        func body(of signature: String, upTo next: String) throws -> String {
            let start = try #require(source.range(of: signature), "\(signature) is gone")
            let end = try #require(source.range(of: next, range: start.upperBound..<source.endIndex), "\(next) is gone")
            return String(source[start.upperBound..<end.lowerBound])
        }
        let call = "duplicateDeletionHoldRule()"
        #expect(try body(of: "func authorizeDuplicateDeletion(", upTo: "func settleDeletedDuplicate(").contains(call),
                "the delete-time / resume authorization no longer asks the hold rule")
        #expect(try body(of: "func duplicateDeletionSelection(", upTo: "func volumesWithDeletableDuplicates(").contains(call),
                "the selection no longer asks the hold rule")
        #expect(try body(of: "func volumesWithDeletableDuplicates(", upTo: "func keepersByGroupID(").contains(call),
                "the menu count no longer asks the hold rule")
        #expect(source.components(separatedBy: "func duplicateDeletionHoldRule(").count == 2, "exactly one definition")
        // The rule itself reads the Angel's ONE set of numbers and the
        // running Prepare, the Triage filing and the promoted-copy mark.
        let rule = try body(of: "func duplicateDeletionHoldRule(", upTo: "func prepareDuplicateDeletion(")
        for read in ["archiveAngel.recommendations", "preparedIDs.contains(", "promotedIDs.contains(",
                     "archiveAngel.recordIDsInBatchesOnDisk", "archiveAngel.recordIDsInRunningPrepare",
                     "archiveAngel.recordIDsHandedOver", "isArchiveCopy("] {
            #expect(rule.contains(read), "the hold rule no longer reads `\(read)`")
        }
        // Ruling 2026-10-03: a merely-listed candidate and the Archived
        // label are NOT holds — neither may creep back into the rule.
        for dropped in ["candidateIDs", "lifecycleStage"] {
            #expect(!rule.contains(dropped), "the hold rule reads `\(dropped)` again")
        }
        // The buffer is read before a run plans and before it resumes — the
        // hold does not wait for the Archive tab.
        let refresh = "archiveAngel.refreshRecordIDsInBatchesOnDisk()"
        #expect(try body(of: "func prepareDuplicateDeletion(", upTo: "func captureStamps(").contains(refresh))
        // The steward asks the planner's rule — it has no list of its own.
        let steward = try SourceTree.appSource(named: "VideoScanModel+Steward.swift")
        #expect(steward.contains(call))
        // Both of the job's authorizations are the model's one function.
        let job = try SourceTree.appSource(named: "DeleteDuplicatesJob.swift")
        #expect(job.components(separatedBy: "model.authorizeDuplicateDeletion(").count == 3,
                "the job authorizes at the copy's turn and at resume, through the one function")
        // …and the pair asks once more after its read, BEFORE the removal
        // phase is started.
        let pairStart = try #require(job.range(of: "private func runPair("))
        let removal = try #require(job.range(of: "DeleteDuplicatesDiskWorker.deleteQuarantined(ticket",
                                             range: pairStart.upperBound..<job.endIndex))
        #expect(String(job[pairStart.upperBound..<removal.lowerBound]).contains("model.duplicateDeletionHoldRule()"),
                "the pair no longer re-asks the hold rule between its read and its removal")
    }
}
