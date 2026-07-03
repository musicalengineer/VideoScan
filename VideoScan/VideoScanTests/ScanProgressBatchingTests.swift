// ScanProgressBatchingTests.swift
// Regression suite for the scan/dashboard feedback storm (2026-07-02):
// during the 14.5h RicksBackups crawl, DashboardState.recordScanFile fired
// @Published setters (→ objectWillChange.send) once PER SCANNED FILE. Every
// probe poked the dashboard, every poke invalidated the toolbar chrome, and
// (before the DossierToolbarChip cache fix) every invalidation recounted the
// 90k-record catalog — the scan starved itself through its own UI.
//
// The fix batches scan-progress publishing: recordScanFile accumulates into
// non-published pending state and flushes at ≤4 Hz OR every 50 files
// (whichever comes first), plus a guaranteed trailing flush so the final
// file/volume always lands even after the scan stops.
//
// Red/green: `rapidRecordScanFileCallsAreBatched` FAILS against the
// pre-fix implementation (~600 objectWillChange emissions for 200 calls —
// 3 published setters each) and passes after (≤ a few flushes' worth).
// It intentionally uses only the pre-fix API surface so the red run is
// honest.

import Testing
import Foundation
import Combine
@testable import VideoScan

@MainActor
struct ScanProgressBatchingTests {

    // MARK: - 1. Bounded emissions under per-file hammering

    @Test func rapidRecordScanFileCallsAreBatched() async throws {
        let ds = DashboardState()
        var emissions = 0
        let sub = ds.objectWillChange.sink { emissions += 1 }
        defer { sub.cancel() }

        // 200 files arriving as fast as the probe pool can produce them.
        // Pre-fix: 3 @Published writes per call → ~600 emissions.
        // Post-fix: flush on the 1st call (nothing flushed yet), then every
        // 50 files or 250 ms — a handful of flushes at ≤3 emissions each.
        for i in 0..<200 {
            ds.recordScanFile(volume: "RicksBackups", filename: "clip\(i).mov")
        }

        #expect(emissions <= 60,
                "recordScanFile must not publish per scanned file — got \(emissions) objectWillChange emissions for 200 calls")
    }

    // MARK: - 2. Final state is guaranteed to land (trailing flush)

    @Test func finalScanFileStateLandsAfterBurstEnds() async throws {
        let ds = DashboardState()

        for i in 0..<203 {
            ds.recordScanFile(volume: "RicksBackups", filename: "clip\(i).mov")
        }

        // No further calls — the scan just ended mid-batch. The trailing
        // flush must deliver the last file/volume without any extra poke.
        // 250 ms throttle window + margin.
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(ds.scanCurrentVolume == "RicksBackups")
        #expect(ds.scanCurrentFile == "clip202.mov",
                "Last recorded file must be published after the trailing flush — got '\(ds.scanCurrentFile)'")
        #expect(ds.scanRecentFiles.last == "clip202.mov")
        #expect(ds.scanRecentFiles.count <= 14,
                "Recent-files ticker must stay capped — got \(ds.scanRecentFiles.count)")
    }

    // MARK: - 3. Reset clears pending state (no ghost flush after reset)

    @Test func resetForScanDropsPendingScanProgress() async throws {
        let ds = DashboardState()

        for i in 0..<20 {
            ds.recordScanFile(volume: "OldVolume", filename: "old\(i).mov")
        }
        ds.resetForScan()

        // Any trailing flush scheduled before the reset must not resurrect
        // pre-reset state.
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(ds.scanCurrentFile.isEmpty,
                "A flush scheduled before resetForScan must not resurrect stale state — got '\(ds.scanCurrentFile)'")
        #expect(ds.scanRecentFiles.isEmpty)
    }
}
