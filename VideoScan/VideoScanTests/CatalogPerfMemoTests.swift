import Testing
import Foundation
@testable import VideoScan

// MARK: - CatalogPerfMemo tests (perf batch 2026-06-10)
//
// Pins the invalidation contracts of the render-time memo helpers:
//
//   - RenderMemo: computes once per key, recomputes when the key (e.g. a
//     records-version bump) changes, and honors explicit invalidate().
//   - RecordIDIndex: O(1) hit path, rebuild on count change, and the
//     miss-fallback that covers same-count membership swaps (the one
//     hole in count-based versioning).
//   - CatalogStreamTypeCounts: the single-pass toolbar badge counts.
//
// All pure — no SwiftUI, no model, no timing.

@Suite("CatalogPerfMemo")
struct CatalogPerfMemoTests {

    // MARK: - Fixtures

    private func makeRecord(path: String, streamType: StreamType = .videoAndAudio) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.streamTypeRaw = streamType.rawValue
        return r
    }

    // MARK: - RenderMemo

    @Test("Same key computes once; key change (records-version bump) recomputes")
    func renderMemoKeyedInvalidation() {
        let memo = RenderMemo<RecordsVersion, Int>()
        let v1 = RecordsVersion(count: 100, revision: 0)

        #expect(memo.value(for: v1) { 42 } == 42)
        // Same key → cached, compute closure NOT run again.
        #expect(memo.value(for: v1) { Issue.record("must not recompute"); return -1 } == 42)
        #expect(memo.computeCount == 1)

        // Count bump (add/remove) invalidates.
        let v2 = RecordsVersion(count: 101, revision: 0)
        #expect(memo.value(for: v2) { 43 } == 43)
        #expect(memo.computeCount == 2)

        // Revision bump (in-place bulk mutation) invalidates too.
        let v3 = RecordsVersion(count: 101, revision: 1)
        #expect(memo.value(for: v3) { 44 } == 44)
        #expect(memo.computeCount == 3)
    }

    @Test("invalidate() forces recompute even for an identical key")
    func renderMemoExplicitInvalidate() {
        let memo = RenderMemo<Int, String>()
        #expect(memo.value(for: 7) { "a" } == "a")
        memo.invalidate()
        #expect(memo.value(for: 7) { "b" } == "b")
        #expect(memo.computeCount == 2)
    }

    // MARK: - RecordIDIndex

    @Test("Lookup hits without rescanning; count change rebuilds and finds new records")
    func indexRebuildOnCountChange() {
        let index = RecordIDIndex()
        var records = [
            makeRecord(path: "/Volumes/V/a.mov"),
            makeRecord(path: "/Volumes/V/b.mov")
        ]
        let a = records[0]

        #expect(index.record(forID: a.id, in: records) === a)
        #expect(index.rebuildCount == 1)
        // Second hit: no rebuild.
        #expect(index.record(forID: a.id, in: records) === a)
        #expect(index.rebuildCount == 1)

        // Append (count change) → rebuild, new record findable.
        let c = makeRecord(path: "/Volumes/V/c.mov")
        records.append(c)
        #expect(index.record(forID: c.id, in: records) === c)
        #expect(index.rebuildCount == 2)
    }

    @Test("Same-count membership swap is caught by the miss fallback")
    func indexSameCountSwapFallback() {
        let index = RecordIDIndex()
        var records = [
            makeRecord(path: "/Volumes/V/a.mov"),
            makeRecord(path: "/Volumes/V/b.mov")
        ]
        _ = index.record(forID: records[0].id, in: records)

        // Replace b with a NEW instance (new UUID) — count unchanged, so
        // the count check alone would serve a stale index.
        let replacement = makeRecord(path: "/Volumes/V/b2.mov")
        records[1] = replacement

        #expect(index.record(forID: replacement.id, in: records) === replacement)
        // And the fallback rebuilt the index, so the next hit is O(1).
        let rebuilds = index.rebuildCount
        #expect(index.record(forID: replacement.id, in: records) === replacement)
        #expect(index.rebuildCount == rebuilds)
    }

    @Test("Absent id returns nil")
    func indexAbsentID() {
        let index = RecordIDIndex()
        let records = [makeRecord(path: "/Volumes/V/a.mov")]
        #expect(index.record(forID: UUID(), in: records) == nil)
    }

    // MARK: - CatalogStreamTypeCounts

    @Test("Single-pass counts match the per-type filters they replaced")
    func streamTypeCounts() {
        let records = [
            makeRecord(path: "/v/1.mxf", streamType: .videoOnly),
            makeRecord(path: "/v/2.mxf", streamType: .videoOnly),
            makeRecord(path: "/v/3.wav", streamType: .audioOnly),
            makeRecord(path: "/v/4.mov", streamType: .videoAndAudio),
            makeRecord(path: "/v/5.bad", streamType: .ffprobeFailed)
        ]
        let counts = CatalogStreamTypeCounts.compute(records)
        #expect(counts.videoOnly == 2)
        #expect(counts.audioOnly == 1)
        // Equivalence with the old per-render filters (the spec this replaced).
        #expect(counts.videoOnly == records.filter { $0.streamType == .videoOnly }.count)
        #expect(counts.audioOnly == records.filter { $0.streamType == .audioOnly }.count)
        let empty = CatalogStreamTypeCounts.compute([])
        #expect(empty == CatalogStreamTypeCounts())
    }
}
