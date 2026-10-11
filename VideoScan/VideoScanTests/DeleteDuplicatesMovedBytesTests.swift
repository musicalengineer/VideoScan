// DeleteDuplicatesMovedBytesTests.swift
// Codex delete-engines review 2026-10-09, F7 (P2): "Duplicate completion
// reports use catalog sizes instead of moved sizes." A valid identical pair
// occupies 20 MB on disk while the target's catalog size says 10 MB → the
// job moved 20 MB and reported 10 MB: the worker's measured bytes reached a
// transient tally but never the persisted row the report reads.
//
// Now the measured size is persisted on the row (`movedBytes`) when it
// moves, and the outcome report and the plan counters sum THAT.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Delete Duplicates — bytes moved are the moved files' measured sizes (codex F7)", .serialized)
@MainActor
struct DeleteDuplicatesMovedBytesTests {

    @Test func theReportSumsTheMeasuredSizeNotTheCatalogs() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_dupbytes_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let size = FileHasher.segmentSize * 2
        let bytes = Data((0..<size).map { UInt8($0 % 173) })
        let group = UUID()
        func rec(_ name: String, _ d: DuplicateDisposition) -> VideoRecord {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: bytes)
            let r = VideoRecord()
            r.fullPath = url.path; r.filename = name; r.directory = dir.path
            r.sizeBytes = Int64(size); r.partialMD5 = "same"; r.durationSeconds = 61
            r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
            return r
        }
        let keeper = rec("keeper.mov", .keep)
        keeper.contentFixity = ContentFixity.captured(path: keeper.fullPath,
                                                      digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                                                      byteCount: Int64(size))
        let copy = rec("copy.mov", .extraCopy)
        copy.sizeBytes = Int64(size / 2)          // the catalog is out of date
        model.records = [keeper, copy]

        let job = DeleteDuplicatesJob(model: model, volumePath: dir.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: dir),
                                      planRoot: dir.appendingPathComponent("plans", isDirectory: true))
        job.start(); await job.task?.value

        let plan = try #require(job.plan)
        #expect(plan.entries.first?.status == .trashed, "\(plan.entries.first?.note ?? "-")")
        let report = plan.outcomeReport
        #expect(report.bytesMovedToTrash == Int64(size), "moved \(size) on disk, reported \(report.bytesMovedToTrash)")
        #expect(report.rows.first?.sizeBytes == Int64(size))
        #expect(plan.counts.trashedBytes == Int64(size))
        #expect(report.line.contains(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)),
                Comment(rawValue: report.line))
    }
}
