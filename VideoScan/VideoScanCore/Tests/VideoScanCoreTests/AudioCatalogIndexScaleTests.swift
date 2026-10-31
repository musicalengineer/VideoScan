// AudioCatalogIndexScaleTests.swift — scale dimension for Find Master by
// sound (design provenance_retroactive_2026_10_26 §Phase A): 5,000 prints,
// 25 M landmarks — today's sidecar shape — built under a time budget with
// bounded resident growth, then 1,000 queries under a budget.
//
// The prints are GENERATED per row on each pass (never held), the way the
// store streams them, so resident growth measures the index alone. Numbers
// are printed; the bars are the design's and are never loosened.
//
// How the bars are judged (laptop full Debug suite 2026-10-26: build 45.0 s,
// "+3,701 MB" — the whole parallel test process, not this index; the same
// test alone on an M4 in Debug: 14.6 s, +257 MB). The repo's rules, no new
// mechanism:
//   - 15 s build / 60 s queries are the product's numbers: asserted on the
//     reference run (VIDEOSCAN_TIMING_STRICT=1, the nightly), logged
//     elsewhere (`expectWithinReferenceTimingBudget`, GH #385).
//   - Everywhere: the build at 4× the documents may cost at most 8× the
//     thread CPU time of the ¼ build (linear ≈ 4; quadratic 16) — GH #385's
//     growth check, which host, core type and Debug divide out of.
//   - Resident growth < 400 MB is a failure only where the lane pins
//     VIDEOSCAN_TIMING_STRICT=1 (`strict`: the nightly, which runs Core
//     serially); anywhere else the process's resident size is not this
//     index's (#407: a parallel `swift test` saw +1.7 GB) and a miss is
//     listed as a known issue (the pattern of AudioFingerprintEngineTests').
// Worst-case memory: the index (≈ 255 MB for 25 M landmarks) plus one
// generated print (5,000 landmarks); the ¼ build runs after the full one is
// released.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("AudioCatalogIndex scale", .tags(.scale), .serialized)
struct AudioCatalogIndexScaleTests {

    static let documents = 5_000
    static let landmarksPerDocument = 5_000

    /// One base print; document d's hashes are the base's with f1/f2 bits
    /// scrambled by d (dt kept), so every document is distinct and cheap.
    static let base = CatalogIndexFixtures.randomPrint(count: landmarksPerDocument, seed: 0xBA5E, seconds: 600)

    static func synthetic(_ d: Int) -> AudioFingerprint {
        let salt = UInt32(truncatingIfNeeded: (d &* 2_654_435_761)) & 0x00FF_FFC0
        return AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: 600,
                                hashes: base.hashes.map { $0 ^ salt }, times: base.times)
    }

    static func key(_ d: Int) -> AudioFingerprintStore.Key {
        AudioFingerprintStore.Key(contentDigest: "sha256:" + String(format: "%064x", d), sizeBytes: Int64(d + 1))
    }

    @Test("25 M landmarks: build < 15 s, resident growth < 400 MB; 1,000 queries < 60 s")
    func twentyFiveMillionLandmarks() throws {
        // The full index lives only inside `fullBuildAndQueries`: released
        // before the ¼ build below.
        let buildCPU = try Self.fullBuildAndQueries()

        // Growth (GH #385): the ¼ build, after the full index is released.
        let quarter = try TimingBudget.measureThreadCPUTime { _ = try Self.build(documents: Self.documents / 4) }
        expectRatio(TimingBudget.judgeGrowth("AudioCatalogIndex build \(Self.documents / 4) → \(Self.documents) docs (CPU)",
                                             small: quarter, large: buildCPU, sizeRatio: 4, limit: 8))
    }

    /// The 25 M build (wall, thread CPU, resident growth) and the 1,000
    /// queries against it. Returns the build's thread CPU time.
    static func fullBuildAndQueries() throws -> Duration {
        let clock = ContinuousClock()
        let loadBefore = TimingBudget.sampleLoad()
        let before = ResidentSize.now().current
        let start = clock.now
        var built: (AudioCatalogIndex, AudioCatalogIndex.BuildReport)?
        let buildCPU = try TimingBudget.measureThreadCPUTime { built = try Self.build(documents: Self.documents) }
        let buildWall = clock.now - start
        let growth = ResidentSize.now().current - before
        let (index, report) = try #require(built)
        print(String(format: "AudioCatalogIndex scale: %d docs, %d landmarks, build %.2f s (CPU %.2f s), resident +%.0f MB (index ≈ %d MB)",
                     report.indexed, report.landmarks, TimingBudget.seconds(buildWall), TimingBudget.seconds(buildCPU), growth,
                     AudioCatalogIndex.megabytes(forPostings: index.postingCount)))
        #expect(report.landmarks == Self.documents * Self.landmarksPerDocument)
        let buildJudgement = expectWithinReferenceTimingBudget("AudioCatalogIndex build, 25 M landmarks", measured: buildWall,
                                                               budget: .seconds(15), loadBefore: loadBefore)
        let growthLine = Comment(rawValue: String(format: "resident growth %.0f MB for the 25 M-landmark index (bar 400 MB)", growth))
        if buildJudgement.strict {
            #expect(growth < 400, growthLine)
        } else {
            withKnownIssue("resident-size growth is not attributable on a busy or hosted box (\(buildJudgement.modeReason))",
                           isIntermittent: true) {
                #expect(growth < 400, growthLine)
            }
        }

        // 1,000 queries: a 400-landmark slice of document q×5 each.
        let queryLoad = TimingBudget.sampleLoad()
        let queryStart = clock.now
        var hits = 0
        for q in 0..<1_000 {
            let d = q * 5
            let full = Self.synthetic(d)
            let lo = (q * 37) % (Self.landmarksPerDocument - 400)
            let query = AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: 600,
                                         hashes: Array(full.hashes[lo..<lo + 400]), times: Array(full.times[lo..<lo + 400]))
            let ranked = AudioMasterFinder.candidates(query: query, excluding: nil, in: index)
            if ranked.first?.ordinal == d { hits += 1 }
        }
        let queryWall = clock.now - queryStart
        print(String(format: "AudioCatalogIndex scale: 1,000 stage-1 queries %.2f s, %d ranked their source first",
                     TimingBudget.seconds(queryWall), hits))
        expectWithinReferenceTimingBudget("AudioCatalogIndex 1,000 stage-1 queries", measured: queryWall,
                                          budget: .seconds(60), loadBefore: queryLoad)
        #expect(hits == 1_000)
        return buildCPU
    }

    static func build(documents: Int) throws -> (AudioCatalogIndex, AudioCatalogIndex.BuildReport) {
        let rows: AudioCatalogIndex.RowSource = { body in
            for d in 0..<documents { guard try body(Self.key(d), .success(Self.synthetic(d))) else { return } }
        }
        return try AudioCatalogIndex.build(rows: rows, expectedRows: documents)
    }
}
