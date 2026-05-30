import Testing
import Foundation
@testable import VideoScan

// MARK: - CombinePerfSummaryTests
//
// Covers VideoScanModel.formatCombinePerfSummary — the pure formatter that
// builds the perf addendum appended to the Combine Complete banner.
//
// The function reads CombineJobStatus timing data plus optional on-disk
// output sizes (via injected FileManager). These tests stay synthetic —
// no real ffmpeg, no real combine runs — so they're cheap and fast.

@MainActor
struct CombinePerfSummaryTests {

    private func job(_ name: String,
                     start: Date?,
                     end: Date?,
                     phase: CombineJobStatus.CombinePhase) -> CombineJobStatus {
        var j = CombineJobStatus(
            pairIndex: 0,
            videoFilename: "\(name).V.mxf",
            audioFilename: "\(name).A.mxf",
            outputFilename: "\(name)_combined.mov",
            outputPath: "/tmp/vs-fake/\(name)_combined.mov",
            videoSizeBytes: 1_000_000,
            audioSizeBytes:   500_000,
            totalDurationSeconds: 10,
            videoOnline: true,
            audioOnline: true
        )
        j.startTime = start
        j.endTime = end
        j.phase = phase
        return j
    }

    @Test
    func emptyJobsProducesEmptyString() {
        let out = VideoScanModel.formatCombinePerfSummary(jobs: [])
        #expect(out.isEmpty)
    }

    @Test
    func skippedOnlyJobsProduceEmptyString() {
        // Skipped jobs have no startTime/endTime set in our pipeline.
        let jobs = [
            job("a", start: nil, end: nil, phase: .skipped),
            job("b", start: nil, end: nil, phase: .skipped)
        ]
        let out = VideoScanModel.formatCombinePerfSummary(jobs: jobs)
        #expect(out.isEmpty)
    }

    @Test
    func singleJobReportsWallClockAndPerJobStats() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(30)  // 30s job
        let jobs = [job("only", start: t0, end: t1, phase: .done)]

        let out = VideoScanModel.formatCombinePerfSummary(jobs: jobs)
        #expect(out.contains("Wall clock:        30.0s"))
        #expect(out.contains("median 30.0s"))
        #expect(out.contains("effective parallelism: 1.0x"))
    }

    @Test
    func parallelismComputedFromSumOverWallClock() {
        // Three jobs each 20s long, overlapping into a 20s wall window.
        // Sum 60s / wall 20s => 3.0x parallelism.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(20)
        let jobs = [
            job("a", start: t0, end: t1, phase: .done),
            job("b", start: t0, end: t1, phase: .done),
            job("c", start: t0, end: t1, phase: .done)
        ]

        let out = VideoScanModel.formatCombinePerfSummary(jobs: jobs)
        #expect(out.contains("Wall clock:        20.0s"))
        #expect(out.contains("Sum of job time:   1m 0s"))
        #expect(out.contains("effective parallelism: 3.0x"))
    }

    @Test
    func failedJobsCountIntoWallClockButNotPerJobDurationStats() {
        // One success, one failure — both timed. Per-job stats should only
        // include the success; wall clock spans both.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let okStart = t0
        let okEnd = t0.addingTimeInterval(10)
        let failStart = t0.addingTimeInterval(5)
        let failEnd = t0.addingTimeInterval(40)
        let jobs = [
            job("ok", start: okStart, end: okEnd, phase: .done),
            job("fail", start: failStart, end: failEnd, phase: .failed)
        ]

        let out = VideoScanModel.formatCombinePerfSummary(jobs: jobs)
        // Wall clock = max(end) - min(start) = 40s
        #expect(out.contains("Wall clock:        40.0s"))
        // Per-job duration considers succeeded only: just the 10s job
        #expect(out.contains("median 10.0s"))
        #expect(out.contains("min 10.0s, max 10.0s"))
    }

    @Test
    func minuteFormattingKicksInAtSixtySeconds() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(125)  // 2m 5s
        let jobs = [job("long", start: t0, end: t1, phase: .done)]

        let out = VideoScanModel.formatCombinePerfSummary(jobs: jobs)
        #expect(out.contains("Wall clock:        2m 5s"))
    }

    @Test
    func hourFormattingKicksInAtSixtyMinutes() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(3 * 3600 + 47 * 60)  // 3h 47m
        let jobs = [job("epic", start: t0, end: t1, phase: .done)]

        let out = VideoScanModel.formatCombinePerfSummary(jobs: jobs)
        #expect(out.contains("Wall clock:        3h 47m"))
    }

    @Test
    func outputThroughputReportedWhenFilesExist() throws {
        // Create a real output file in /tmp so FileManager can stat it,
        // then point a fake job at it.
        let tmp = URL(fileURLWithPath: "/tmp/vs-perf-summary-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outPath = tmp.appendingPathComponent("test_combined.mov").path
        let payload = Data(repeating: 0xAB, count: 8 * 1_048_576)  // 8 MB
        try payload.write(to: URL(fileURLWithPath: outPath))

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(4)  // 4s wall, 8 MB → 2.0 MB/s
        var j = job("test", start: t0, end: t1, phase: .done)
        // Override outputPath to the real file we just wrote.
        let jobs = [CombineJobStatus(
            pairIndex: j.pairIndex,
            videoFilename: j.videoFilename,
            audioFilename: j.audioFilename,
            outputFilename: j.outputFilename,
            outputPath: outPath,
            videoSizeBytes: j.videoSizeBytes,
            audioSizeBytes: j.audioSizeBytes,
            totalDurationSeconds: j.totalDurationSeconds,
            videoOnline: true,
            audioOnline: true
        )]
        var mutable = jobs[0]
        mutable.startTime = t0
        mutable.endTime = t1
        mutable.phase = .done
        _ = j  // silence unused warning

        let out = VideoScanModel.formatCombinePerfSummary(jobs: [mutable])
        #expect(out.contains("Output:"))
        // ByteCountFormatter ".file" uses SI (÷1,000,000): 8 MiB ≈ 8.4 MB.
        #expect(out.contains("8.4 MB"))
        // Throughput is computed in MiB (÷1,048,576): 8 MiB / 4s = 2.0 MB/s.
        #expect(out.contains("2.0 MB/s"))
    }
}
