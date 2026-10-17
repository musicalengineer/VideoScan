// CatalogImporterScaleTests.swift
// SCALE: a 100k-row synthetic catalog (the poisoned fixture's 17 shapes plus
// 100k healthy bulk rows, every one `present` with a stamp, one in ten with a
// star, one in 25 with a caption) imported end to end — gate, rows,
// relations, sidecars, comparator over the second decode, finish — within a
// load-aware budget (TimingBudget, GH #208). Seconds and resident MB are
// printed; memory is O(rows) (two decodes, never both alive) and nothing is
// O(rows²).

import Darwin
import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogImporterScale", .serialized)
struct CatalogImporterScaleTests {

    /// Measured 2026-10-17, M4 Max, Debug, load 18.8 on 16 cores (an
    /// xcodebuild running beside it): 100,017 rows / 81.5 MB catalog.json in
    /// 135.8 s, resident 705 → 1,222 MB (two decodes, never both alive; the
    /// comparator's sides and the facts map are the rest). The budget is
    /// ≈ 1.8× of that busy run; TimingBudget scales it with the load.
    static let hundredThousandBudget: Duration = .seconds(240)

    /// Resident set size in MB (mach task info), for the printed line.
    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    @Test func oneHundredThousandRowsImportWithinBudget() async throws {
        let rows = 100_000
        let scene = try ImporterScene.make(healthyRows: rows)
        defer { scene.remove() }
        let fileMB = Double(scene.fixture.catalogData.count) / 1_048_576
        let before = Self.residentMB()
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let run = await scene.run()
        let elapsed = clock.now - start
        let after = Self.residentMB()
        let r = try #require(run.outcome.reconciliation, Comment(rawValue: "\(run.outcome)"))
        print("[import-scale] \(rows + 17) rows (catalog.json \(String(format: "%.1f", fileMB)) MB): \(elapsed), "
              + "resident \(String(format: "%.0f", before)) → \(String(format: "%.0f", after)) MB (\(TimingBudget.loadDescription()))")
        #expect(r.rowsBefore == rows + 17)
        #expect(r.rowsMain == rows + 5)
        #expect(r.digests == rows + 12)
        #expect(r.knowledgeRows == 11 + rows / 10)                  // the shapes' 11 + one star per ten bulk rows
        #expect(r.unverified == rows / 25)
        #expect(r.auditResults == rows + 15)
        expectWithinTimingBudget("100k-row import", measured: elapsed, budget: Self.hundredThousandBudget, loadBefore: loadBefore)
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts.files == rows + 5)
    }
}
