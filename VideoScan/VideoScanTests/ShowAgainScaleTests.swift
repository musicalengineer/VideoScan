// ShowAgainScaleTests.swift
// SCALE dimension for "Show these files again": a 100,000-record catalog
// with 10,000 labelled-deleted records (ten times Rick's ~1,000), a fake disk
// (every file present at its size, one in ten missing) and an empty ledger.
// Budgets (Debug build, M4 Max, measured with headroom ×3+):
//   * candidate projection on the main actor  < 0.5 s  (O(records) field reads)
//   * the review check off the main actor      < 2 s
//   * the whole run, snapshot + receipt + label change + acknowledged save
//     of the 100k-record catalog              < 30 s
// Nothing here runs in a view body; the footer shows the cached caption.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Show again — scale (100k records)", .serialized)
@MainActor
struct ShowAgainScaleTests {

    @Test("100k records, 10k labelled: review and run within budget, exactly the present files change")
    func hundredThousand() async throws {
        let sb = try ShowAgainSandbox.make("scale"); defer { sb.cleanup() }
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/Volumes/Scale/\(i / 1000)/clip_\(i).mov"
            r.filename = "clip_\(i).mov"
            r.sizeBytes = Int64(10_000 + i)
            if i % 10 == 0 { r.archiveStage = .manuallyDeleted }
            records.append(r)
        }
        sb.model.records = records
        // Every tenth labelled file is missing; the rest are on disk at size.
        let sizes = Dictionary(uniqueKeysWithValues: records.filter { $0.archiveStage == .manuallyDeleted }
            .map { ($0.fullPath, $0.sizeBytes) })
        let disk = ShowAgainDisk(
            volumeOnline: { _ in true },
            stat: { path in
                guard let size = sizes[path] else { return .missing }
                let n = Int(path.split(separator: "_").last?.split(separator: ".").first ?? "") ?? 0
                return n % 100 == 0 ? .missing : .file(size: size)
            })

        let t0 = Date()
        let candidates = sb.model.showAgainCandidates()
        let projection = -t0.timeIntervalSinceNow
        #expect(candidates.count == 10_000)
        #expect(projection < 0.5, "candidate projection took \(projection) s")

        let t1 = Date()
        let reviewed = await sb.model.showAgainReview(disk: disk)
        let review = -t1.timeIntervalSinceNow
        #expect(reviewed.showCount == 9_000 && reviewed.staying.count == 1_000)
        #expect(review < 2, "review took \(review) s")

        let t2 = Date()
        let result = await sb.model.applyShowAgain(reviewed: reviewed, disk: disk)
        let run = -t2.timeIntervalSinceNow
        #expect(result.outcome == .shown, "\(result.outcome)")
        #expect(result.shown.count == 9_000 && result.stayed.count == 1_000)
        #expect(run < 30, "run took \(run) s")
        #expect(sb.model.records.filter { $0.archiveStage == .manuallyDeleted }.count == 1_000)
        let receipt = try ShowAgainReceiptFile.decode(Data(contentsOf: try #require(result.receiptURL)))
        #expect(receipt.changes.count == 9_000)
    }
}
