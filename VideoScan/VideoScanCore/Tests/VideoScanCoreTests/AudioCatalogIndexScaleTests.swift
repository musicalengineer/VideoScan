// AudioCatalogIndexScaleTests.swift — scale dimension for Find Master by
// sound (design provenance_retroactive_2026_10_26 §Phase A): 5,000 prints,
// 25 M landmarks — today's sidecar shape — built under a time budget with
// bounded resident growth, then 1,000 queries under a budget.
//
// The prints are GENERATED per row on each pass (never held), the way the
// store streams them, so resident growth measures the index alone. Numbers
// are printed; the bars are the design's and are never loosened.

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
        let rows: AudioCatalogIndex.RowSource = { body in
            for d in 0..<Self.documents { guard try body(Self.key(d), .success(Self.synthetic(d))) else { return } }
        }
        let clock = ContinuousClock()
        let before = ResidentSize.now().current
        let start = clock.now
        let (index, report) = try AudioCatalogIndex.build(rows: rows, expectedRows: Self.documents)
        let buildSeconds = TimingBudget.seconds(clock.now - start)
        let growth = ResidentSize.now().current - before
        print(String(format: "AudioCatalogIndex scale: %d docs, %d landmarks, build %.2f s, resident +%.0f MB (index ≈ %d MB)",
                     report.indexed, report.landmarks, buildSeconds, growth,
                     AudioCatalogIndex.megabytes(forPostings: index.postingCount)))
        #expect(report.landmarks == Self.documents * Self.landmarksPerDocument)
        #expect(buildSeconds < 15)
        #expect(growth < 400)

        // 1,000 queries: a 400-landmark slice of document q×5 each.
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
        let querySeconds = TimingBudget.seconds(clock.now - queryStart)
        print(String(format: "AudioCatalogIndex scale: 1,000 stage-1 queries %.2f s, %d ranked their source first", querySeconds, hits))
        #expect(querySeconds < 60)
        #expect(hits == 1_000)
    }
}
