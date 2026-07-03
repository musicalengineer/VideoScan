// DossierCountsCacheTests.swift
// Cache-semantics proof for the O(1) chrome counters (2026-07-02
// feedback-storm fix, leg 1: NO O(records) work in view bodies).
//
// DossierToolbarChip used to reduce over the whole records array inside
// its body — at 90k records × per-file dashboard invalidations, one leg
// of the storm that stretched the RicksBackups sweep to 14.5h. The chip
// now reads VideoScanModel.dossierCounts, a cached value the model
// recomputes (debounced) on catalog mutation.
//
// The contract proven here, via the model's recompute counter:
//   * N reads between mutations = 0 additional computations,
//   * a burst of mutations coalesces into ONE recompute,
//   * the count is correct after mutations — including IN-PLACE dossier
//     stamps that the records-array didSet cannot observe.

import Testing
import Foundation
@testable import VideoScan

@MainActor
struct DossierCountsCacheTests {

    private func makeRecord(path: String, dossiered: Bool = false) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        if dossiered { r.dossierProcessedAt = Date() }
        return r
    }

    /// Debounce window is 250 ms — wait it out with margin.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 450_000_000)
    }

    // MARK: - 1. Reads are free; mutations recompute exactly once

    @Test func readsNeverRecomputeAndMutationRecomputesOnce() async throws {
        let model = VideoScanModel()
        try await self.settle()  // drain any init-time refresh
        let baseline = model.dossierCountsRecomputeCount

        model.records = [
            makeRecord(path: "/Volumes/T/a.mov", dossiered: true),
            makeRecord(path: "/Volumes/T/b.mov")
        ]
        try await self.settle()
        #expect(model.dossierCountsRecomputeCount == baseline + 1,
                "One mutation batch → exactly one recompute")
        #expect(model.dossierCounts == .init(dossiered: 1, total: 2))

        // The view-body pattern: many reads between mutations. Zero
        // additional computations allowed.
        for _ in 0..<1_000 {
            _ = model.dossierCounts.dossiered
            _ = model.dossierCounts.total
        }
        #expect(model.dossierCountsRecomputeCount == baseline + 1,
                "Reads must never recompute — the whole point of the cache")
    }

    // MARK: - 2. A burst of mutations coalesces into one recompute

    @Test func mutationBurstCoalescesIntoOneRecompute() async throws {
        let model = VideoScanModel()
        model.records = [makeRecord(path: "/Volumes/T/seed.mov")]
        try await self.settle()
        let baseline = model.dossierCountsRecomputeCount

        // 100 appends in one tick — the scan-commit / import shape.
        for i in 0..<100 {
            model.records.append(makeRecord(path: "/Volumes/T/c\(i).mov",
                                            dossiered: i % 2 == 0))
        }
        try await self.settle()

        #expect(model.dossierCountsRecomputeCount == baseline + 1,
                "Debounce must coalesce a mutation burst into one recompute — got \(model.dossierCountsRecomputeCount - baseline)")
        #expect(model.dossierCounts == .init(dossiered: 50, total: 101))
    }

    // MARK: - 3. In-place dossier stamps invalidate the cache

    @Test func inPlaceProvenanceStampRefreshesCounts() async throws {
        let model = VideoScanModel()
        let rec = makeRecord(path: "/Volumes/T/stamp.mov")
        model.records = [rec]
        try await self.settle()
        #expect(model.dossierCounts == .init(dossiered: 0, total: 1))

        // stampDossierProvenance writes dossierProcessedAt on the record
        // object without touching the array — didSet can't see it, so the
        // stamp site must invalidate explicitly.
        model.stampDossierProvenance(on: rec, modelID: "whisper-medium", at: Date())
        try await self.settle()

        #expect(model.dossierCounts == .init(dossiered: 1, total: 1),
                "In-place dossier stamp must refresh the cached counts")
    }
}
