// ScanCounterInvariantTests.swift
// Regression suite for the discovered/completed counter race Rick observed
// live on 2026-07-02: the dashboard showed "PROBING 18,456/18,450 (99%)" —
// completed EXCEEDED discovered, and the percent display quietly hid the
// invariant violation.
//
// Root cause (see VideoScanModel+ProbeEngine / DashboardState): stopping a
// scan marks the target .stopped immediately, but the aborted probe pool's
// in-flight children keep running (bounded only by the probe timeout).
// Starting the next scan then sees no active targets → resetForScan()
// zeroes BOTH counters → the old scan's straggler completions landed in the
// NEW scan's scanCompleted with no matching discovery increment. From that
// moment on, completed > discovered for the entire scan.
//
// The fix stamps every probe with the scan generation captured at ENQUEUE
// time (the same turn as its discovery increment); completions carrying a
// stale generation are dropped at the DashboardState seam, and the seam
// counts/logs/asserts the invariant instead of letting the UI clamp it away.
//
// RED evidence (2026-07-03, pre-fix run):
//   stalePreResetProbeCompletionCannotExceedDiscovered — scanCompleted 1 >
//     scanTotal 0 after reset (straggler counted against fresh counters)
//   perFileProbeCounterPublishesAreBatched — 506 objectWillChange
//     emissions for 100 files (per-file publish storm, item-4 leg 2)
// (Pre-fix forms drove the discovery side via direct `ds.scanTotal += 1`,
// the exact shape ProbeEngine used; the fix replaced that surface with the
// generation-stamped seam, so the tests now speak the seam.)

import Testing
import Foundation
import Combine
@testable import VideoScan

@MainActor
struct ScanCounterInvariantTests {

    // MARK: - 1. Cross-reset straggler cannot break completed <= discovered

    @Test func stalePreResetProbeCompletionCannotExceedDiscovered() async throws {
        let model = VideoScanModel()
        let ds = model.dashboard

        // Scan 1 begins: one file is discovered and its probe is enqueued,
        // carrying scan 1's generation stamp.
        ds.resetForScan()
        let staleGen = ds.scanGeneration
        ds.beginVolumeWalk(volumeRoot: "/Volumes/OldVol", volumeName: "OldVol",
                           generation: staleGen)
        ds.recordFileDiscovered(volumeRoot: "/Volumes/OldVol", generation: staleGen)

        // User stops scan 1 and immediately starts scan 2 — the dashboard
        // resets while the scan-1 probe is still in flight.
        ds.resetForScan()

        // The scan-1 straggler completes NOW, against the fresh counters.
        let missing = URL(fileURLWithPath: "/tmp/vs-invariant-missing-\(UUID().uuidString).mov")
        _ = await model.probeAndRecord(
            url: missing,
            volName: "OldVol",
            root: "/Volumes/OldVol",
            rootIsNetwork: false,
            ramMountPoint: nil,
            skipHashing: true,
            useTimeout: false,
            echoFilename: false,
            scanGeneration: staleGen
        )

        // Let any batched publish land.
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(ds.scanCompleted <= ds.scanTotal,
                "Invariant violated: scanCompleted \(ds.scanCompleted) > scanTotal \(ds.scanTotal) — a stale straggler completion was counted against the new scan")
        #expect(ds.scanCompletedInternal == 0,
                "Stale-generation completion must be dropped at the seam — internal completed is \(ds.scanCompletedInternal)")
        #expect(ds.scanCounterInvariantViolations == 0)
    }

    // MARK: - 2. Same-turn discovery+completion holds the invariant throughout

    @Test func sameTurnDiscoveryAndCompletionKeepInvariant() {
        let ds = DashboardState()
        ds.resetForScan()
        let gen = ds.scanGeneration
        ds.beginVolumeWalk(volumeRoot: "/Volumes/Fast", volumeName: "Fast", generation: gen)

        // A probe completing in the SAME actor turn as its discovery (cache
        // hits over a fast local SSD do this) must never see completed >
        // discovered — discovery increments synchronously before enqueue.
        for _ in 0..<500 {
            ds.recordFileDiscovered(volumeRoot: "/Volumes/Fast", generation: gen)
            #expect(ds.scanCompletedInternal <= ds.scanDiscoveredInternal)
            ds.recordProbeCompletion(volumeRoot: "/Volumes/Fast", wasCacheHit: true,
                                     isProbeError: false,
                                     streamTypeRaw: StreamType.videoAndAudio.rawValue,
                                     generation: gen)
            #expect(ds.scanCompletedInternal <= ds.scanDiscoveredInternal)
        }
        #expect(ds.scanCounterInvariantViolations == 0,
                "No violation may be recorded for a well-ordered scan — got \(ds.scanCounterInvariantViolations)")
        #expect(ds.scanDiscoveredInternal == 500)
        #expect(ds.scanCompletedInternal == 500)
    }

    // MARK: - 3. Per-file counter publishing is batched (item 4 / leg 2)

    @Test func perFileProbeCounterPublishesAreBatched() async throws {
        let model = VideoScanModel()
        let ds = model.dashboard
        ds.resetForScan()
        let gen = ds.scanGeneration
        ds.beginVolumeWalk(volumeRoot: "/Volumes/BatchVol", volumeName: "BatchVol", generation: gen)

        var emissions = 0
        let sub = ds.objectWillChange.sink { emissions += 1 }
        defer { sub.cancel() }

        // 100 files discovered + probed (missing files → deterministic
        // fast-fail outcomes, no ffprobe). Pre-fix: probeAndRecord's counter
        // block hit 4 @Published setters per file (scanCompleted,
        // cacheMisses, scanErrors, liveStreamCounts) → 506 emissions
        // measured. Post-fix: everything rides the ≤4 Hz / 50-event flush.
        for i in 0..<100 {
            ds.recordFileDiscovered(volumeRoot: "/Volumes/BatchVol", generation: gen)
            _ = await model.probeAndRecord(
                url: URL(fileURLWithPath: "/tmp/vs-batch-missing-\(i).mov"),
                volName: "BatchVol",
                root: "/Volumes/BatchVol",
                rootIsNetwork: false,
                ramMountPoint: nil,
                skipHashing: true,
                useTimeout: false,
                echoFilename: false,
                scanGeneration: gen
            )
        }

        // Bound: ~9 flushes × ~9 published properties each ≈ 80; pre-fix
        // measured 506 (5+ per file), so 100 cleanly separates the storm
        // from the batched behavior.
        #expect(emissions <= 100,
                "probeAndRecord must not publish per scanned file — got \(emissions) objectWillChange emissions for 100 files")

        // Eventual consistency: after the trailing flush the published
        // counters must reflect every file, and stay pairwise sane.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(ds.scanCompleted == 100,
                "Trailing flush must publish the final completed count — got \(ds.scanCompleted)")
        #expect(ds.scanTotal == 100)
        #expect(ds.scanCompleted <= ds.scanTotal)
        #expect(ds.scanErrors == 100, "Missing files are probe errors — got \(ds.scanErrors)")
        #expect(ds.scanCacheMisses == 100)
        // Per-volume row carried the batch too.
        let row = ds.volumeProgress.first { $0.rootPath == "/Volumes/BatchVol" }
        #expect(row?.completedFiles == 100)
        #expect(row?.errors == 100)
    }

    // MARK: - 4. Percent is suppressed until the denominator is final (1b)

    @Test func percentSuppressedWhileDiscoveryIncomplete() {
        let ds = DashboardState()
        ds.resetForScan()
        let gen = ds.scanGeneration

        // No volumes registered yet → nothing to show a percent for.
        #expect(ds.scanDisplayFraction == nil)

        ds.beginVolumeWalk(volumeRoot: "/Volumes/Walky", volumeName: "Walky", generation: gen)
        for _ in 0..<10 {
            ds.recordFileDiscovered(volumeRoot: "/Volumes/Walky", generation: gen)
        }
        ds.flushScanProgress()

        // Walk still streaming: percent must be nil (count-only display).
        #expect(!ds.scanDiscoveryFinal)
        #expect(ds.scanDisplayFraction == nil,
                "Percent must not exist while the walker is still discovering files")

        // Walk finishes → denominator final → true fraction appears.
        ds.markVolumeWalkComplete(volumeRoot: "/Volumes/Walky", totalFiles: 10, generation: gen)
        #expect(ds.scanDiscoveryFinal)
        #expect(ds.scanDisplayFraction != nil)
        #expect(ds.scanTotal == 10)
    }

    /// Resumed scans have no walk — the checkpoint list is the final
    /// denominator from the start, so percent is available immediately.
    @Test func resumedScanRowStartsWithFinalDenominator() {
        let ds = DashboardState()
        ds.resetForScan()
        let gen = ds.scanGeneration
        ds.beginVolumeWalk(volumeRoot: "/Volumes/Resumed", volumeName: "Resumed",
                           generation: gen, knownTotal: 42)
        #expect(ds.scanDiscoveryFinal,
                "A resumed scan's denominator is known up front — no walking treatment")
        #expect(ds.volumeProgress.first?.totalFiles == 42)
        #expect(ds.volumeProgress.first?.isWalking == false)
    }
}
