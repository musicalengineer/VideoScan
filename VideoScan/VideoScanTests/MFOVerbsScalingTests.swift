// MFOVerbsScalingTests.swift
// Rick 2026-11-20: "Each verb should be able to run as a unit test at the
// same time, or at least up to N verbs where N is optimal." The performance
// half of MFOVerbsParallelTests.swift: one fixed batch of real verb jobs
// (12 media-heavy verbs × 4, 10-second synthetic clips, each job in its own
// sandbox and its own Center, as each test in the testbed has) admitted K at
// a time for K = 1, 2, 4, 8, cores/2, 24, cores, 48. Prints the wall time per
// K and N = the smallest K within 5 % of the best. Asserts only what is not
// load-sensitive: every K gives the same outcomes, the best K is > 1 and at
// least 2× K = 1. Run it alone (-only-testing) for numbers worth quoting.
// Memory: 48 fixtures of ≤ 10 s at ≤ 720×576 (~5 MB each) on disk at once,
// K ffmpeg children in flight — bounded by the batch.

import Foundation
import Testing
@testable import VideoScan

// MARK: - Scaling: the N where wall time stops improving

@Suite("MFO verbs — scaling sweep (perf): K in flight for K = 1 … 48, including cores/2")
@MainActor
struct MFOVerbsScalingTests {

    /// The batch: the media-heavy verbs (each decodes or encodes real
    /// frames) on `len`-second clips, four copies each in fresh sandboxes —
    /// 48 jobs.
    static func batch(len: Int = 10) -> [MFOVerbScenario] {
        let heavy: [MFOVerbScenario] = [MFOVerbFixtures.verifyVideo(len), MFOVerbFixtures.verifyAudio(len), MFOVerbFixtures.transcode(len),
                                        MFOVerbFixtures.trim(len), MFOVerbFixtures.checkMedia(len), MFOVerbFixtures.repair(len),
                                        MFOVerbFixtures.rebuildAudio(len), MFOVerbFixtures.balanceAudio(len), MFOVerbFixtures.reformat(len),
                                        MFOVerbFixtures.compare(len), MFOVerbFixtures.fingerprintSound(len), MFOVerbFixtures.promote(len)]
        return Array(repeating: heavy, count: 4).flatMap { $0 }
    }

    @Test("PERF timing sweep: every K gives the same outcomes; the best K is > 1 and beats K = 1 by 2× or more",
          .timeLimit(.minutes(30)))
    func sweep() async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies")
        let cores = ProcessInfo.processInfo.activeProcessorCount
        var reference: [String]?
        var times: [(k: Int, wall: Double)] = []
        // Rick 2026-11-20: the target is at least cores/2 verbs at once.
        let ks = Array(Set([1, 2, 4, 8, max(1, cores / 2), 24, cores, 48])).sorted()
        // Warm-up, unmeasured: the first jobs in a process pay one-time
        // costs (VideoToolbox sessions, AVFoundation and GRDB loading, the
        // ProRes encoder probe) that would otherwise land on K = 1 alone.
        _ = try await MFOVerbHarness.run(Array(Self.batch().prefix(12)), limit: 12, centerPerJob: true)
        for k in ks {
            let run = try await MFOVerbHarness.run(Self.batch(), limit: k, centerPerJob: true)
            let facts = run.outcomes.map(\.facts)
            if let reference { #expect(facts == reference, "K=\(k): outcomes changed with concurrency") } else { reference = facts }
            times.append((k, run.wall))
            print(String(format: "MFO scaling: K=%2d → %6.1f s (%.2f× vs K=1)  [%d cores]  main-actor lag max %.0f ms", k, run.wall,
                         times[0].wall / max(run.wall, 0.001), cores, run.mainLagMax * 1000))
            // Per verb: mean seconds per job at this K — who slows down
            // under contention names the bottleneck.
            var perKind: [String: [Double]] = [:]
            for o in run.outcomes { perKind[o.kind.rawValue, default: []].append(o.seconds) }
            let row = perKind.keys.sorted().map { k in
                String(format: "%@ %.2f", k, perKind[k]!.reduce(0, +) / Double(perKind[k]!.count))
            }
            print("MFO scaling:   K=\(k) per-job mean s — " + row.joined(separator: " · "))
        }
        let best = times.min { $0.wall < $1.wall }!
        // N: the smallest K within 5 % of the best wall time.
        let n = times.first { $0.wall <= best.wall * 1.05 }!.k
        print(String(format: "MFO scaling: N = %d (best K=%d at %.1f s; K=1 %.1f s; speedup %.1f×) on %d cores",
                     n, best.k, best.wall, times[0].wall, times[0].wall / max(best.wall, 0.001), cores))
        #expect(best.k > 1)
        #expect(times[0].wall / best.wall >= 2, "the best K only reached \(times[0].wall / best.wall)×")
    }
}
