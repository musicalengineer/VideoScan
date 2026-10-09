// DeleteDuplicatesOutcomeTests.swift
// R6/R7 (design triage_delete_streamline_2026_10_09 §9 R6/R7, codex F6/F7):
//   • ONE outcome per requested copy — moved / held / failed / waiting to
//     be put back / missing / offline / not reached — and
//     requested == the sum, exactly;
//   • the held list is never truncated (3,000 held → 3,000 rows);
//   • bytes are the moved copies' own sizes (never scaled), labelled
//     "moved to the Trash" — never "freed" or "deleted";
//   • a copy missing at its turn is MISSING (not refused, not re-marked
//     Review); a reviewed plan whose drive is away is OFFLINE, row by row;
//   • a batch stopped before a drive's turn reports that drive's rows as
//     not reached.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dupoutcome_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ url: URL, _ bytes: [UInt8]) { FileManager.default.createFile(atPath: url.path, contents: Data(bytes)) }

private func plainSHA256(_ url: URL) -> String {
    SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
}

private func entry(_ name: String, size: Int64, _ status: DeleteDuplicatesPlan.EntryStatus,
                   kind: DeleteDuplicatesOutcomeKind? = nil, note: String = "",
                   quarantine: String? = nil) -> DeleteDuplicatesPlan.Entry {
    var e = DeleteDuplicatesPlan.Entry(id: UUID(), path: "/Volumes/S/\(name)", filename: name, sizeBytes: size,
                                       keeperID: UUID(), keeperPath: "/Volumes/S/k.mov", keeperFilename: "k.mov")
    e.status = status
    e.outcomeKind = kind
    e.note = note
    e.quarantineDirectory = quarantine
    return e
}

private func plan(_ entries: [DeleteDuplicatesPlan.Entry]) -> DeleteDuplicatesPlan {
    DeleteDuplicatesPlan(volumePath: "/Volumes/S", catalogLocation: "/c", crossVolumeMode: false,
                         skippedBeforePlan: 0, summaryLine: "", entries: entries)
}

@Suite("Delete Duplicates — one outcome per requested copy (R6/R7)", .serialized)
@MainActor
struct DeleteDuplicatesOutcomeTests {

    // MARK: Pure accounting

    @Test func everyRequestedCopyHasExactlyOneOutcomeAndTheyAddUp() {
        let p = plan([
            entry("moved-a.mov", size: 100, .trashed),
            entry("moved-b.mov", size: 7_000, .trashed),
            entry("held-refused.mov", size: 3, .refused, note: "keeper changed after verification"),
            entry("held-skip.mov", size: 5, .skipped, note: "left alone — in use by the Archive Angel"),
            entry("failed.mov", size: 11, .failed, note: "could not create quarantine directory"),
            entry("stranded.mov", size: 13, .failed, note: "retained safely", quarantine: "/Volumes/S/.videoscan-quarantine-x"),
            entry("missing.mov", size: 17, .skipped, kind: .missing, note: "no longer in the catalog at this path"),
            entry("offline.mov", size: 19, .skipped, kind: .offline, note: "S is not connected"),
            entry("cancelled.mov", size: 23, .skipped, kind: .cancelled, note: "cancelled during verification"),
            entry("not-reached.mov", size: 29, .pending),
            entry("legacy.mov", size: 31, .deleted),
        ])
        let r = p.outcomeReport
        #expect(r.requested == 11)
        let sum = DeleteDuplicatesOutcomeKind.allCases.reduce(0) { $0 + r.count($1) }
        #expect(sum == r.requested, "requested == the sum of the outcomes")
        #expect(r.count(.moved) == 2 && r.count(.held) == 2 && r.count(.failed) == 1 && r.count(.recoveryNeeded) == 1)
        #expect(r.count(.missing) == 1 && r.count(.offline) == 1 && r.count(.cancelled) == 2 && r.count(.deletedOutright) == 1)
        #expect(r.bytesMovedToTrash == 7_100, "the moved copies' own sizes — never scaled by a ratio")
        #expect(r.rows(.cancelled).contains { $0.reason == DeleteDuplicatesOutcomeReport.notReachedReason })
        #expect(r.rows.filter { $0.kind != .moved && $0.kind != .deletedOutright }.allSatisfy { !$0.reason.isEmpty },
                "every row that did not leave says why")
        #expect(r.line.hasPrefix("Moved 2 (") && r.line.contains("to the Trash") && !r.line.contains("freed"),
                Comment(rawValue: r.line))
    }

    @Test func theHeldListIsNeverTruncated() {
        let held = (0..<3_000).map { entry("h\($0).mov", size: 1, .skipped, note: "left alone — reason \($0)") }
        let r = plan(held).outcomeReport
        #expect(r.rows(.held).count == 3_000)
        #expect(Set(r.rows(.held).map(\.reason)).count == 3_000, "every reason kept")
    }

    @Test func theSubtitleSaysMovedToTheTrashNeverFreed() {
        var c = DeleteDuplicatesPlan.Counts()
        c.total = 10; c.trashed = 2; c.refused = 1; c.skipped = 1; c.trashedBytes = 800_000_000
        let text = DeleteDuplicatesRate.subtitle(counts: c, rate: DeleteDuplicatesRate(), trashVolumes: ["SanDisk"])
        #expect(text == "checked 4 of 10 · 2 moved to the Trash · 2 held · 800 MB moved to the Trash of SanDisk",
                Comment(rawValue: text))
        #expect(!text.contains("freed") && !text.contains("deleted"))
    }

    // MARK: Through the job

    private struct Rig {
        let dir: URL
        let root: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let copies: [VideoRecord]
        var hooks: SignatureVerification.Hooks { SignatureVerification.Hooks.live.withScratchTrash(in: dir) }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private func rig(_ label: String, copies n: Int, sizes: [Int]? = nil) -> Rig {
        let dir = tempDir(label)
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let bytes = (0..<(FileHasher.segmentSize * 2)).map { UInt8($0 % 239) }
        let group = UUID()
        func rec(_ name: String, _ d: DuplicateDisposition) -> VideoRecord {
            let url = dir.appendingPathComponent(name); write(url, bytes)
            let r = VideoRecord()
            r.fullPath = url.path; r.filename = name; r.directory = dir.path
            r.sizeBytes = Int64(bytes.count); r.partialMD5 = "same"; r.durationSeconds = 61
            r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
            return r
        }
        let keeper = rec("keeper.mov", .keep)
        keeper.contentFixity = ContentFixity.captured(path: keeper.fullPath,
                                                      digest: plainSHA256(URL(fileURLWithPath: keeper.fullPath)),
                                                      byteCount: keeper.sizeBytes)
        let copies = (1...n).map { rec("copy\($0).mov", .extraCopy) }
        model.records = [keeper] + copies
        return Rig(dir: dir, root: dir.appendingPathComponent("plans", isDirectory: true), model: model,
                   keeper: keeper, copies: copies)
    }

    /// Four copies requested: one moves, one is gone from the disk
    /// (MISSING — not refused, not Review), one is half of an A/V pair
    /// (HELD), one is gone from the catalog (MISSING). requested == sum.
    @Test func aMixedRunReportsEveryCopyOnce() async throws {
        let r = rig("mixed", copies: 4); defer { r.cleanup() }
        let picks = r.copies.map { ReviewedDuplicatePick(recordID: $0.id, path: $0.fullPath, keeperID: r.keeper.id) }
        let batch = await r.model.reviewedDuplicateBatch(picks)
        try FileManager.default.removeItem(atPath: r.copies[1].fullPath)          // gone from the disk
        r.copies[2].pairGroupID = UUID()                                          // an A/V half
        r.model.records.removeAll { $0.id == r.copies[3].id }                     // gone from the catalog
        let job = DeleteDuplicatesJob(model: r.model, reviewed: try #require(batch.plans.first),
                                      hooks: r.hooks, planRoot: r.root)
        job.start(); await job.task?.value

        let report = try #require(job.plan).outcomeReport
        #expect(report.requested == 4)
        #expect(DeleteDuplicatesOutcomeKind.allCases.reduce(0) { $0 + report.count($1) } == 4)
        #expect(report.count(.moved) == 1 && report.count(.held) == 1 && report.count(.missing) == 2,
                "\(report.rows.map { "\($0.filename): \($0.kind) — \($0.reason)" })")
        #expect(r.copies[1].duplicateDisposition == .extraCopy, "a missing copy is not re-marked Review")
        #expect(report.bytesMovedToTrash == r.copies[0].sizeBytes)
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.contains("Moved 1 (") && summary.contains("to the Trash") && !summary.contains("freed"),
                Comment(rawValue: summary))
        #expect(job.title.contains("to the Trash") && !job.title.hasPrefix("Delete"), Comment(rawValue: job.title))
    }

    /// The reviewed plan's drive is not connected: nothing is read, every
    /// row is OFFLINE with the reason.
    @Test func aReviewedPlanOnADriveThatIsAwayIsOfflineRowByRow() async throws {
        let r = rig("offline", copies: 2); defer { r.cleanup() }
        let entries = r.copies.map {
            DeleteDuplicatesPlan.Entry(id: $0.id, path: "/Volumes/VS-Test-Not-Connected/\($0.filename)", filename: $0.filename,
                                       sizeBytes: $0.sizeBytes, keeperID: r.keeper.id, keeperPath: r.keeper.fullPath,
                                       keeperFilename: r.keeper.filename)
        }
        var away = DeleteDuplicatesPlan(volumePath: "/Volumes/VS-Test-Not-Connected", catalogLocation: r.model.catalogStore.fileLocation,
                                        crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "", entries: entries)
        away.reviewed = true
        let job = DeleteDuplicatesJob(model: r.model, reviewed: away, hooks: r.hooks, planRoot: r.root)
        job.start(); await job.task?.value

        let report = try #require(job.plan).outcomeReport
        #expect(report.count(.offline) == 2 && report.requested == 2, "\(report.rows.map { "\($0.kind) \($0.reason)" })")
        #expect(report.rows.allSatisfy { $0.reason.contains("not connected") })
        #expect(r.copies.allSatisfy { FileManager.default.fileExists(atPath: $0.fullPath) })
    }

    /// A batch stopped before the second drive's turn: that drive's rows
    /// are reported as not reached; the sum still holds.
    @Test func aStoppedBatchReportsTheDrivesItNeverReached() async throws {
        let a = rig("batchA", copies: 1), b = rig("batchB", copies: 1)
        defer { a.cleanup(); b.cleanup() }
        let planA = DeleteDuplicatesPlan(volumePath: a.dir.path, catalogLocation: a.model.catalogStore.fileLocation,
                                         crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "",
                                         entries: [DeleteDuplicatesPlan.Entry(id: a.copies[0].id, path: a.copies[0].fullPath,
                                                                              filename: "copy1.mov", sizeBytes: a.copies[0].sizeBytes,
                                                                              keeperID: a.keeper.id, keeperPath: a.keeper.fullPath,
                                                                              keeperFilename: "keeper.mov")])
        var planB = planA
        planB.id = UUID(); planB.volumePath = b.dir.path
        planB.entries = [DeleteDuplicatesPlan.Entry(id: b.copies[0].id, path: b.copies[0].fullPath, filename: "copy1.mov",
                                                    sizeBytes: 5, keeperID: b.keeper.id, keeperPath: b.keeper.fullPath,
                                                    keeperFilename: "keeper.mov")]
        let run = DeleteDuplicatesBatchRun(batch: DeleteDuplicatesBatch(plans: [planA, planB]))
        run.start(make: { DeleteDuplicatesJob(model: a.model, reviewed: $0, hooks: a.hooks, planRoot: a.root) },
                  launch: { job in job.start(); job.cancel() })
        await run.task?.value

        let report = run.outcomeReport
        #expect(report.requested == 2)
        #expect(report.count(.cancelled) == 2, "\(report.rows.map { "\($0.kind) \($0.reason)" })")
        #expect(report.rows.last?.reason == DeleteDuplicatesOutcomeReport.notReachedReason)
    }
}
