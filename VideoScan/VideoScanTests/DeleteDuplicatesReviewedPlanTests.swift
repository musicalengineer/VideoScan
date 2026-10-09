// DeleteDuplicatesReviewedPlanTests.swift
// R2 (design triage_delete_streamline_2026_10_09 §9 R2, codex F2): Delete
// Duplicates runs EXACTLY the plan Rick reviewed — "move the extras I
// selected to the Trash, exactly as I reviewed them."
//
//   • only the reviewed rows run; a copy he did not tick is never touched,
//     even when the bulk rule would take it (never widen);
//   • a fact that changed since the review HOLDS the row (copy moved,
//     keeper re-elected, a keeper chosen as a target under any name);
//   • a plan over several volumes runs as sequential per-volume jobs with
//     ONE fixed keeper per group; a Stop leaves the later volumes untouched
//     and reported;
//   • the 100k-record freeze stays inside its time budget (scale).
//
// Synthetic files in temp folders; the Trash is a scratch folder.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dupreviewed_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ url: URL, _ bytes: [UInt8]) { FileManager.default.createFile(atPath: url.path, contents: Data(bytes)) }

private func plainSHA256(_ url: URL) -> String {
    SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
}

private let fileSize = FileHasher.segmentSize * 2

@MainActor
private func makeModel(_ dir: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
    model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
    return model
}

@MainActor
private func copyRecord(_ url: URL, bytes: [UInt8], group: UUID, _ d: DuplicateDisposition) -> VideoRecord {
    write(url, bytes)
    let r = VideoRecord()
    r.fullPath = url.path; r.filename = url.lastPathComponent; r.directory = url.deletingLastPathComponent().path
    r.sizeBytes = Int64(bytes.count); r.partialMD5 = "same"; r.durationSeconds = 61
    r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
    if d == .keep {
        r.contentFixity = ContentFixity.captured(path: url.path, digest: plainSHA256(url), byteCount: Int64(bytes.count))
    }
    return r
}

private func pick(_ r: VideoRecord, keeper: VideoRecord) -> ReviewedDuplicatePick {
    ReviewedDuplicatePick(recordID: r.id, path: r.fullPath, keeperID: keeper.id)
}

@Suite("Delete Duplicates — run exactly the reviewed plan (R2)", .serialized)
@MainActor
struct DeleteDuplicatesReviewedPlanTests {

    private struct OneVolume {
        let dir: URL
        let root: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let copies: [VideoRecord]
        var hooks: SignatureVerification.Hooks { SignatureVerification.Hooks.live.withScratchTrash(in: dir) }
        func inTrash(_ r: VideoRecord) -> Bool {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("Trash/\(r.filename)").path)
        }
        func atHome(_ r: VideoRecord) -> Bool { FileManager.default.fileExists(atPath: r.fullPath) }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private func oneVolume(_ label: String, copies n: Int) -> OneVolume {
        let dir = tempDir(label)
        let model = makeModel(dir)
        let bytes = (0..<fileSize).map { UInt8($0 % 227) }
        let group = UUID()
        let keeper = copyRecord(dir.appendingPathComponent("keeper.mov"), bytes: bytes, group: group, .keep)
        let copies = (1...n).map { copyRecord(dir.appendingPathComponent("copy\($0).mov"), bytes: bytes, group: group, .extraCopy) }
        model.records = [keeper] + copies
        return OneVolume(dir: dir, root: dir.appendingPathComponent("plans", isDirectory: true), model: model,
                         keeper: keeper, copies: copies)
    }

    private func run(_ plan: DeleteDuplicatesPlan, _ v: OneVolume) async -> DeleteDuplicatesJob {
        let job = DeleteDuplicatesJob(model: v.model, reviewed: plan, hooks: v.hooks, planRoot: v.root)
        job.start(); await job.task?.value
        return job
    }

    // MARK: Exactly the reviewed rows

    /// Four copies (all pre-selected by the bulk rule); Rick ticked ONE.
    /// Only that one moves — the bulk rule never widens a reviewed plan.
    @Test func onlyTheTickedCopyMoves() async throws {
        let v = oneVolume("exact", copies: 3); defer { v.cleanup() }
        let batch = await v.model.reviewedDuplicateBatch([pick(v.copies[0], keeper: v.keeper)])
        #expect(batch.plans.count == 1 && batch.requested == 1)
        let job = await run(try #require(batch.plans.first), v)

        let plan = try #require(job.plan)
        #expect(plan.entries.map(\.id) == [v.copies[0].id], "the plan is the review, nothing added")
        #expect(plan.entries[0].status == .trashed, Comment(rawValue: plan.entries[0].note))
        #expect(v.inTrash(v.copies[0]))
        #expect(v.atHome(v.copies[1]) && v.atHome(v.copies[2]) && v.atHome(v.keeper), "unticked copies are never touched")
        #expect(plan.isReviewed)
    }

    /// A ticked two-copy group's extra runs (the tick IS the choice) —
    /// pre-selection is the bulk run's default only.
    @Test func aTickedTwoCopyExtraRunsInAReviewedPlan() async throws {
        let v = oneVolume("two", copies: 1); defer { v.cleanup() }
        let batch = await v.model.reviewedDuplicateBatch([pick(v.copies[0], keeper: v.keeper)])
        let entry = try #require(batch.plans.first?.entries.first)
        #expect(entry.groupCopyCount == 2 && !entry.preselected)
        let job = await run(try #require(batch.plans.first), v)
        #expect(job.plan?.entries.first?.status == .trashed)
        #expect(v.inTrash(v.copies[0]) && v.atHome(v.keeper))
    }

    // MARK: A changed fact holds

    @Test func factsThatChangedSinceTheReviewHoldTheirRows() async throws {
        let v = oneVolume("changed", copies: 3); defer { v.cleanup() }
        let batch = await v.model.reviewedDuplicateBatch(v.copies.map { pick($0, keeper: v.keeper) })
        // After the freeze: copy2 is re-pointed (moved), copy3 re-elected
        // keeper (the old keeper becomes an extra), and a fourth copy shows up.
        v.copies[1].fullPath = v.dir.appendingPathComponent("elsewhere/copy2.mov").path
        v.copies[2].duplicateDisposition = .keep
        v.keeper.duplicateDisposition = .extraCopy
        let late = copyRecord(v.dir.appendingPathComponent("late.mov"), bytes: (0..<fileSize).map { UInt8($0 % 227) },
                              group: v.keeper.duplicateGroupID!, .extraCopy)
        v.model.records.append(late)
        let job = await run(try #require(batch.plans.first), v)

        let plan = try #require(job.plan)
        #expect(plan.entries.count == 3, "never widened: \(plan.entries.map(\.filename))")
        #expect(plan.entries.allSatisfy { $0.status != .trashed && $0.status != .deleted },
                "\(plan.entries.map { "\($0.filename): \($0.status) \($0.note)" })")
        #expect(v.copies.allSatisfy { v.atHome($0) || $0.id == v.copies[1].id } && v.atHome(late) && v.atHome(v.keeper))
        #expect(!FileManager.default.fileExists(atPath: v.dir.appendingPathComponent("Trash").path), "nothing moved")
    }

    // MARK: No keeper is ever a target

    @Test func aKeeperChosenAsATargetIsHeldUnderEveryName() async throws {
        let v = oneVolume("alias", copies: 1); defer { v.cleanup() }
        // The keeper ticked as if it were an extra (same id, its own keeper).
        let keeperAsTarget = ReviewedDuplicatePick(recordID: v.keeper.id, path: v.keeper.fullPath, keeperID: v.keeper.id)
        // A hard link of the keeper, catalogued as an extra copy.
        let link = v.dir.appendingPathComponent("keeper-link.mov")
        try FileManager.default.linkItem(at: URL(fileURLWithPath: v.keeper.fullPath), to: link)
        let linked = VideoRecord()
        linked.fullPath = link.path; linked.filename = link.lastPathComponent; linked.directory = v.dir.path
        linked.sizeBytes = v.keeper.sizeBytes; linked.duplicateGroupID = v.keeper.duplicateGroupID
        linked.duplicateDisposition = .extraCopy; linked.duplicateConfidence = .high
        v.model.records.append(linked)

        let batch = await v.model.reviewedDuplicateBatch([keeperAsTarget, pick(linked, keeper: v.keeper),
                                                          pick(v.copies[0], keeper: v.keeper)])
        let plan = try #require(batch.plans.first)
        let byID = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.id, $0) })
        #expect(byID[v.keeper.id]?.status == .skipped, "\(byID[v.keeper.id]?.note ?? "-")")
        #expect(byID[linked.id]?.status == .skipped && byID[linked.id]?.note.contains("a link") == true,
                "\(byID[linked.id]?.note ?? "-")")
        #expect(byID[v.copies[0].id]?.status == .pending)

        let job = await run(plan, v)
        #expect(v.atHome(v.keeper) && FileManager.default.fileExists(atPath: link.path), "the keeper, under both names, stays")
        #expect(job.plan?.entries.first { $0.id == v.copies[0].id }?.status == .trashed)
    }

    /// Pure: a case-spelling of a keeper, and one group with two keepers.
    @Test func holdsByCaseSpellingAndByTwoKeepersForOneGroup() {
        let group = UUID(), k1 = UUID(), k2 = UUID()
        func entry(_ path: String, keeper: UUID, keeperPath: String, group g: UUID? = group) -> DeleteDuplicatesPlan.Entry {
            DeleteDuplicatesPlan.Entry(id: UUID(), path: path, filename: (path as NSString).lastPathComponent, sizeBytes: 1,
                                       keeperID: keeper, keeperPath: keeperPath, keeperFilename: "k.mov", groupID: g)
        }
        let caseAlias = entry("/Volumes/A/Films/KEEPER.mov", keeper: k1, keeperPath: "/Volumes/A/Films/keeper.mov", group: UUID())
        let first = entry("/Volumes/B/x.mov", keeper: k1, keeperPath: "/Volumes/A/k.mov")
        let second = entry("/Volumes/C/y.mov", keeper: k2, keeperPath: "/Volumes/D/k.mov")
        let fine = entry("/Volumes/E/z.mov", keeper: k1, keeperPath: "/Volumes/A/k.mov", group: UUID())
        let holds = DeleteDuplicatesReview.holds([caseAlias, first, second, fine], stamps: [:])
        #expect(holds[caseAlias.id]?.contains("another name") == true)
        #expect(holds[first.id] == DeleteDuplicatesReview.twoKeepersNote && holds[second.id] == DeleteDuplicatesReview.twoKeepersNote)
        #expect(holds[fine.id] == nil)
    }

    // MARK: Several volumes

    private struct TwoVolumes {
        let base: URL
        let a: URL
        let b: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let onA: VideoRecord
        let onB: [VideoRecord]
        var hooks: SignatureVerification.Hooks { SignatureVerification.Hooks.live.withScratchTrash(in: base) }
        func inTrash(_ r: VideoRecord) -> Bool {
            FileManager.default.fileExists(atPath: base.appendingPathComponent("Trash/\(r.filename)").path)
        }
        func atHome(_ r: VideoRecord) -> Bool { FileManager.default.fileExists(atPath: r.fullPath) }
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    /// Volume A (ranked higher, a workspace) holds the keeper and one extra;
    /// volume B (unassigned) holds two more extras of the same group.
    private func twoVolumes(_ label: String) -> TwoVolumes {
        let base = tempDir(label)
        let a = base.appendingPathComponent("VolA", isDirectory: true)
        let b = base.appendingPathComponent("VolB", isDirectory: true)
        try? FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let model = makeModel(base)
        let ta = CatalogScanTarget(searchPath: a.path); ta.role = .workspace; ta.isReachable = true
        let tb = CatalogScanTarget(searchPath: b.path); tb.role = .unassigned; tb.isReachable = true
        model.scanTargets = [ta, tb]
        let bytes = (0..<fileSize).map { UInt8($0 % 229) }
        let group = UUID()
        let keeper = copyRecord(a.appendingPathComponent("keeper.mov"), bytes: bytes, group: group, .keep)
        let onA = copyRecord(a.appendingPathComponent("a1.mov"), bytes: bytes, group: group, .extraCopy)
        let onB = [copyRecord(b.appendingPathComponent("b1.mov"), bytes: bytes, group: group, .extraCopy),
                   copyRecord(b.appendingPathComponent("b2.mov"), bytes: bytes, group: group, .extraCopy)]
        model.records = [keeper, onA] + onB
        return TwoVolumes(base: base, a: a, b: b, model: model, keeper: keeper, onA: onA, onB: onB)
    }

    @Test func aPlanOverTwoVolumesRunsAsTwoJobsInOrderWithOneKeeper() async throws {
        let v = twoVolumes("batch"); defer { v.cleanup() }
        #expect(!v.model.duplicateKeeperSettings.alsoCleanUpWorkingCopies, "the bulk toggle is not what authorises a reviewed copy")
        let batch = await v.model.reviewedDuplicateBatch(([v.onA] + v.onB).map { pick($0, keeper: v.keeper) })
        #expect(batch.plans.map(\.volumePath) == [v.a.path, v.b.path])
        #expect(batch.plans[1].crossVolumeMode && batch.plans[1].entries.allSatisfy(\.isWorkingCopy))
        #expect(Set(batch.plans.flatMap(\.entries).map(\.keeperID)) == [v.keeper.id], "one keeper for the group")

        let run = DeleteDuplicatesBatchRun(batch: batch)
        let root = v.base.appendingPathComponent("plans", isDirectory: true)
        run.start(make: { DeleteDuplicatesJob(model: v.model, reviewed: $0, hooks: v.hooks, planRoot: root) },
                  launch: { $0.start() })
        await run.task?.value

        #expect(run.jobs.count == 2 && run.notStarted.isEmpty)
        #expect(run.jobs.map(\.volumePath) == [v.a.path, v.b.path], "volume by volume, in order")
        let rows = run.jobs.compactMap(\.plan).flatMap(\.entries)
        #expect(rows.allSatisfy { $0.status == .trashed }, "\(rows.map { "\($0.filename): \($0.status) \($0.note)" })")
        #expect(v.inTrash(v.onA) && v.inTrash(v.onB[0]) && v.inTrash(v.onB[1]))
        #expect(v.atHome(v.keeper), "the one keeper stays")
    }

    @Test func aStoppedBatchLeavesTheLaterVolumesUntouchedAndReported() async throws {
        let v = twoVolumes("stop"); defer { v.cleanup() }
        let batch = await v.model.reviewedDuplicateBatch(([v.onA] + v.onB).map { pick($0, keeper: v.keeper) })
        let run = DeleteDuplicatesBatchRun(batch: batch)
        let root = v.base.appendingPathComponent("plans", isDirectory: true)
        run.start(make: { DeleteDuplicatesJob(model: v.model, reviewed: $0, hooks: v.hooks, planRoot: root) },
                  launch: { job in job.start(); job.cancel() })
        await run.task?.value

        #expect(run.jobs.count == 1, "the second volume never started")
        #expect(run.notStarted.map(\.volumePath) == [v.b.path])
        #expect(v.atHome(v.onB[0]) && v.atHome(v.onB[1]) && v.atHome(v.keeper))
    }

    // MARK: Scale

    /// 100k records (33,334 three-copy groups) on a volume that is not
    /// mounted: freezing a 20,000-copy review and the bulk plan stay inside
    /// their budgets. O(records) passes only; no file is opened.
    @Test func freezingAReviewOverAHundredThousandRecordsIsFast() async throws {
        let dir = tempDir("scale"); defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        var records: [VideoRecord] = []
        records.reserveCapacity(100_002)
        var picks: [ReviewedDuplicatePick] = []
        var g = 0
        while records.count < 100_000 {
            let group = UUID()
            func rec(_ i: Int, _ d: DuplicateDisposition) -> VideoRecord {
                let r = VideoRecord()
                r.fullPath = "/Volumes/VS-Scale-Not-Mounted/g\(g)/c\(i).mov"; r.filename = "c\(i).mov"
                r.sizeBytes = 1_000; r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
                return r
            }
            let k = rec(0, .keep), e1 = rec(1, .extraCopy), e2 = rec(2, .extraCopy)
            records += [k, e1, e2]
            if picks.count < 20_000 { picks.append(ReviewedDuplicatePick(recordID: e1.id, path: e1.fullPath, keeperID: k.id)) }
            g += 1
        }
        model.records = records

        let clock = ContinuousClock()
        let started = clock.now
        let batch = await model.reviewedDuplicateBatch(picks)
        let freeze = clock.now - started
        #expect(batch.requested == 20_000)
        #expect(batch.plans.first?.entries.allSatisfy { $0.preselected } == true, "three-copy groups are pre-selected")
        #expect(freeze < .seconds(10), "freeze took \(freeze)")

        let forecastStart = clock.now
        let forecast = model.deleteDuplicatesForecast(for: try #require(batch.plans.first))
        #expect(forecast.total.files == 20_000)
        #expect(clock.now - forecastStart < .seconds(5), "forecast took \(clock.now - forecastStart)")
    }
}
