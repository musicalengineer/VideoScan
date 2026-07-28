// PreviewSweepScaleTests.swift
// SCALE dimension + REGRESSION SENSOR for the background preview sweep
// (2026-07-27): the work plan over 100k synthetic records against a
// 20k-file cache index must stay a pure in-memory diff.
//
// THE INVARIANT THIS PINS: plan cost is O(cacheFiles + records) with
// ZERO per-record cache I/O. The failure mode that motivated it:
// PreviewDiskCache.hasCompleteFilmstrip lists the cache directory per
// probe — 17k probes at ~5 ms of directory listing each would be
// ~90 s of pure I/O per replan (and a spindle wake per probe). The
// planner API takes pre-listed filenames + pre-computed keys, so I/O
// CAN'T creep in without changing these signatures — the wall-time
// budget below then catches any accidental quadratic (e.g. an Array
// `contains` sneaking in where a Set lookup belongs).
//
// Budget: measured 2026-07-27 on the M4 Max — index build (20k names)
// + key computation (100k SHA256) + diff (100k) lands well under 2 s.
// Budget 10 s leaves loaded-host headroom (MBP under a full suite)
// while still failing hard on O(n²) or per-record I/O regressions.

import Testing
import Foundation
@testable import VideoScan

@Suite(.timeLimit(.minutes(2)))
struct PreviewSweepScaleTests {

    @Test("100k-record plan against a 20k-file cache index stays inside a 10 s budget")
    func planAtScale() throws {
        // ---- Synthesize a 20k-file cache listing -------------------
        // 6k best stills, 6k fast stills, 500 complete 16-frame strips
        // (8k files), plus some junk — realistic shape for a warmed
        // 2 GB cache.
        var files: [(name: String, size: Int64)] = []
        files.reserveCapacity(20_100)
        func key(_ n: Int) -> String {
            // Distinct 64-char pseudo-keys, cheap to generate.
            String(format: "%064x", n)
        }
        for n in 0..<6_000 { files.append(("\(key(n))-best.jpg", 40_000)) }
        for n in 6_000..<12_000 { files.append(("\(key(n))-fast.jpg", 40_000)) }
        for n in 12_000..<12_500 {
            for idx in 0..<16 {
                files.append(("\(key(n))-strip-\(idx)-of-16-\(idx * 500).jpg", 30_000))
            }
        }
        for n in 0..<100 { files.append(("tmp-\(n)", 1_000)) }
        try #require(files.count == 20_100)

        // ---- Synthesize 100k keyed candidates ----------------------
        // Keys overlap the cache for the first 12.5k (mix of covered /
        // upgradeable), the rest are cold. Every 20th record routes
        // ffmpegDirect (mkv/ffv1) to exercise the strip side of the diff.
        var candidates: [PreviewSweepKeyedCandidate] = []
        candidates.reserveCapacity(100_000)

        let clock = ContinuousClock()
        var index = PreviewSweepCacheIndex()
        var items: [PreviewSweepWorkItem] = []

        let elapsed = clock.measure {
            index = PreviewSweepPlanner.buildCacheIndex(files: files)
            for n in 0..<100_000 {
                let ffmpegDirect = n % 20 == 0
                let candidate = PreviewSweepCandidate(
                    path: "/Volumes/Scale/\(n / 1000)/clip_\(n).\(ffmpegDirect ? "mkv" : "mp4")",
                    container: ffmpegDirect ? "Matroska / WebM" : "QuickTime / MOV",
                    videoCodec: ffmpegDirect ? "ffv1" : "h264",
                    likelyUnanalyzable: false,
                    durationSeconds: 120)
                // Real key derivation cost included: one SHA256 per
                // record, exactly what the service pays per plan.
                candidates.append(PreviewSweepKeyedCandidate(
                    candidate: candidate,
                    key: n < 12_500
                        ? key(n)
                        : PreviewDiskCache.cacheKey(path: candidate.path,
                                                    mtime: 1_700_000_000,
                                                    size: Int64(n))))
            }
            items = PreviewSweepPlanner.workItems(candidates: candidates, index: index)
        }

        // Correctness spot checks at scale.
        #expect(index.bestKeys.count == 6_000)
        #expect(index.fastKeys.count == 6_000)
        #expect(index.completeStripKeys.count == 500)
        // Covered: 6k best-covered AVF records (keys 0..<6000, minus the
        // ffmpegDirect ones among them which still need strips).
        #expect(items.count > 90_000 && items.count < 100_000,
                "diff shape moved: \(items.count) items")
        // A best-covered, strip-covered ffmpegDirect record must NOT
        // appear (keys 12_000..<12_500 are strip-complete but lack best
        // stills — they DO appear, with needsBestStill only when routed
        // ffmpegDirect and n%20==0 aligns; just assert no item is a
        // no-op).
        #expect(items.allSatisfy { $0.needsBestStill || $0.needsFilmstrip },
                "planner emitted no-op work items")

        #expect(elapsed < .seconds(10),
                "100k-record plan took \(elapsed) — the in-memory diff regressed (budget 10 s; suspect per-record I/O or O(n²))")
    }
}
