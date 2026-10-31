// ModelLabScaleTests.swift — SCALE for the lab (video_llm_lab §6):
//   • a SamplePlan for 100k files whose durations sum to 450 h, planned
//     through WindowSampler with scene cuts, inside a stated budget;
//   • 1.6 M `outputs` rows written in batches, then paged in 256-row keyset
//     pages while a SECOND connection keeps inserting — the reader never
//     sees SQLITE_BUSY and the writer never fails.
// Both are load-aware (TimingBudget, GH #208). The 1.6 M-row test follows
// the package's slow-test convention: `.tags(.scale)` and skipped when
// VIDEOSCAN_SKIP_SCALE=1.
//
// Memory: the plan test keeps counts, never the plans (100k plans at once
// would be ~110k windows × up to 60 doubles ≈ 53 MB; streamed it is one
// plan at a time, ≤ 115 KB). The store test holds one 10k-row batch of
// ~200-byte rows (~2 MB) while binding and one 256-row page while reading;
// the SQLite file is ~400 MB in the scratch folder and is removed after.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("ModelLab — scale", .tags(.scale), .serialized)
struct ModelLabScaleTests {

    /// Durations shaped like the catalog: 100k files, mostly short clips,
    /// ~1 % long tapes, scaled so the total is exactly 450 h. Seeded, so the
    /// same plan every run.
    private static func durations(files: Int, totalHours: Double) -> [Double] {
        var rng = SplitMix64(seed: 0x450)
        var raw = (0..<files).map { _ -> Double in
            let u = Double(rng.next() % 1_000_000) / 1_000_000
            if u < 0.01 { return 1_800 + u * 100 * 7_200 }      // tapes: 30 min – 2.5 h
            if u < 0.30 { return 60 + u * 600 }                  // 1 – 4 min scenes
            return 2 + u * 40                                    // 2 – 42 s clips
        }
        let scale = totalHours * 3_600 / raw.reduce(0, +)
        for i in raw.indices { raw[i] *= scale }
        return raw
    }

    /// Measured 2026-10-30, M5 Ultra, Debug, load ~5/30 while another agent
    /// built the app: 114,831 windows and 1,671,298 frame times in 0.095 s.
    /// Budget 2 s ≈ 20× (an O(n²) slip in cut snapping would show at once).
    @Test("100k files × 450 h planned through WindowSampler(60 s, 1 fps, scene cuts) inside 2 s; every plan covers its file")
    func hundredThousandFilePlans() {
        let durations = Self.durations(files: 100_000, totalHours: 450)
        #expect(abs(durations.reduce(0, +) - 450 * 3_600) < 1)
        let sampler = WindowSampler(seconds: 60, fps: 1, cutAt: .sceneCuts(withinS: 15))
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        var windows = 0, frames = 0, bad = 0
        for (i, d) in durations.enumerated() {
            // One synthetic cut every ~45 s so snapping does real work.
            let cuts: [Double]? = d > 90 ? stride(from: 45.0, to: d, by: 45.0 + Double(i % 7)).map { $0 } : nil
            let plan = sampler.plan(for: .init(durationS: d, fps: 29.97, hasAudio: true, sceneCutsS: cuts))
            windows += plan.windows.count
            frames += plan.frameCount
            if plan.windows.first?.startS != 0 || plan.windows.last?.endS != d { bad += 1 }
        }
        let elapsed = clock.now - start
        print("[modellab-scale] 100k plans: \(windows) windows, \(frames) frames in \(elapsed)")
        #expect(bad == 0)
        #expect(windows >= 100_000 && frames >= windows)
        expectWithinTimingBudget("ModelLab 100k SamplePlans", measured: elapsed, budget: .seconds(2), loadBefore: loadBefore)
    }

    /// Measured 2026-10-30, M5 Ultra, Debug, load ~5/30: write 4.0 s
    /// (160 batches of 10k, ~2.5 µs per row), page-walk 0.69 s for 6,250
    /// pages while the second connection wrote 20k rows; file 376 MB.
    /// Budgets 20 s / 5 s ≈ 5× / 7×.
    @Test("1.6 M outputs rows: batched writes, then 256-row keyset pages while a second connection inserts — no SQLITE_BUSY, every row seen once",
          .enabled(if: ProcessInfo.processInfo.environment["VIDEOSCAN_SKIP_SCALE"] != "1"))
    func sixteenHundredThousandRowsPagedUnderAWriter() async throws {
        let dir = try modelLabScratch("1m6"); defer { try? FileManager.default.removeItem(at: dir) }
        let total = 1_600_000
        let batch = 10_000
        let store = try ModelLabStore(directory: dir)
        try store.beginRun(ModelLabStoreFixtures.run("big"), host: ModelLabStoreFixtures.host)
        try store.beginRun(ModelLabStoreFixtures.run("side"), host: ModelLabStoreFixtures.host)

        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let writeStart = clock.now
        var rows: [ModelLabStore.OutputRow] = []
        rows.reserveCapacity(batch)
        for n in 0..<total {
            rows.append(ModelLabStoreFixtures.output("big", n: n, valid: n % 20 != 0))
            if rows.count == batch { try store.putOutputs(rows); rows.removeAll(keepingCapacity: true) }
        }
        if !rows.isEmpty { try store.putOutputs(rows) }
        let writeElapsed = clock.now - writeStart
        #expect(try store.outputCount(runID: "big") == total)

        // A second connection (another job) inserts into another run while we page.
        let writer = Task.detached(priority: .utility) { () throws -> Int in
            let other = try ModelLabStore(directory: dir)
            var written = 0
            for b in 0..<40 {
                try other.putOutputs((0..<500).map { ModelLabStoreFixtures.output("side", n: b * 500 + $0) })
                written += 500
            }
            return written
        }
        let pageStart = clock.now
        var seen = 0
        var lastRowID: Int64 = -1
        var ordered = true
        try store.forEachOutput(runID: "big", pageSize: ModelLabStore.defaultPageSize) { rowid, _ in
            if rowid <= lastRowID { ordered = false }
            lastRowID = rowid
            seen += 1
            return true
        }
        let pageElapsed = clock.now - pageStart
        let written = try await writer.value
        #expect(seen == total, "every row once")
        #expect(ordered, "strictly increasing rowid")
        #expect(written == 20_000)
        #expect(try store.outputCount(runID: "side") == 20_000, "the concurrent writer's rows all landed")
        let size = (try? FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.size] as? Int64) ?? 0
        print("[modellab-scale] 1.6M rows: write \(writeElapsed), page-walk \(pageElapsed) under a writer, file \(size >> 20) MB")
        expectWithinTimingBudget("ModelLab 1.6M outputs write", measured: writeElapsed, budget: .seconds(20), loadBefore: loadBefore)
        expectWithinTimingBudget("ModelLab 1.6M outputs page-walk under a writer", measured: pageElapsed, budget: .seconds(5), loadBefore: loadBefore)
    }
}
