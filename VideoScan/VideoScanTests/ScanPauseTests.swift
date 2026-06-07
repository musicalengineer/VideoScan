import Foundation
import Testing
@testable import VideoScan

// MARK: - Pause toggle regression
//
// Rick 2026-06-07: triggered an "Update Catalog" rescan on LaCie,
// hit Pause All, scan kept running. Root cause: togglePauseTarget +
// pauseAllTargets both gated on `status == .scanning`, but a fresh
// scan spends its first phase in `.discovering` (initial file
// enumeration). The probe loop's pauseGate checkpoint works during
// either phase; the UI just refused to flip the gate.
//
// These tests pin the broader guard so a future refactor can't
// silently regress.

@MainActor
@Suite("Scan pause toggle")
struct ScanPauseTests {

    /// Construct a model with one target in a chosen status. The test
    /// doesn't actually launch a scan — togglePauseTarget is a pure
    /// state-and-PauseGate operation and that's all we need to verify.
    private func model(with status: CatalogTargetStatus) -> (VideoScanModel, CatalogScanTarget) {
        let m = VideoScanModel()
        let t = CatalogScanTarget(searchPath: "/Volumes/TestVol")
        t.status = status
        m.scanTargets = [t]
        return (m, t)
    }

    @Test func togglePauseDuringScanningGoesToPaused() {
        let (m, t) = model(with: .scanning)
        m.togglePauseTarget(t)
        #expect(t.status == .paused, "scanning → paused must work (the canonical case)")
    }

    @Test func togglePauseDuringDiscoveringAlsoGoesToPaused() {
        // The bug Rick hit. Discovering is an active state where the
        // file walk + probe dispatch is in flight; pause must work
        // here too, not just in .scanning.
        let (m, t) = model(with: .discovering)
        m.togglePauseTarget(t)
        #expect(t.status == .paused, "discovering → paused must work (the regression case)")
    }

    @Test func togglePauseDuringWaitingForVolumeAlsoGoesToPaused() {
        // Less common but consistent — any active state should be
        // pausable so the user can stop the scan to reorganize files.
        let (m, t) = model(with: .waitingForVolume)
        m.togglePauseTarget(t)
        #expect(t.status == .paused)
    }

    @Test func togglePauseWhileIdleIsNoOp() {
        // Defensive: a stale Pause click against an idle target must
        // not flip it into .paused (would confuse the UI).
        let (m, t) = model(with: .idle)
        m.togglePauseTarget(t)
        #expect(t.status == .idle, "idle stays idle")
    }

    @Test func togglePauseWhileCompleteIsNoOp() {
        let (m, t) = model(with: .complete)
        m.togglePauseTarget(t)
        #expect(t.status == .complete, "complete is not toggle-pausable")
    }

    @Test func togglePauseWhilePausedResumes() {
        // Round-trip: paused → scanning (the resume direction was
        // already correct, pin it so we don't break it).
        let (m, t) = model(with: .paused)
        m.togglePauseTarget(t)
        #expect(t.status == .scanning, "paused → scanning on toggle (resume)")
    }

    @Test func pauseAllTargetsPausesDiscoveringTargetsToo() {
        // Same bug at the bulk level. Rick clicks 'Pause All' while
        // one or more targets are still discovering — they all must
        // pause, not just the ones that have advanced to .scanning.
        let m = VideoScanModel()
        let scanning = CatalogScanTarget(searchPath: "/Volumes/A")
        scanning.status = .scanning
        let discovering = CatalogScanTarget(searchPath: "/Volumes/B")
        discovering.status = .discovering
        let waiting = CatalogScanTarget(searchPath: "/Volumes/C")
        waiting.status = .waitingForVolume
        let idle = CatalogScanTarget(searchPath: "/Volumes/D")
        idle.status = .idle
        m.scanTargets = [scanning, discovering, waiting, idle]

        m.pauseAllTargets()

        #expect(scanning.status == .paused)
        #expect(discovering.status == .paused)
        #expect(waiting.status == .paused)
        #expect(idle.status == .idle, "idle target must stay idle, not be pulled into the pause")
    }

    @Test func pauseAllIsIdempotent() {
        // Calling Pause All twice in a row shouldn't toggle paused
        // targets back to .scanning — only resume should do that.
        let m = VideoScanModel()
        let t = CatalogScanTarget(searchPath: "/Volumes/A")
        t.status = .scanning
        m.scanTargets = [t]

        m.pauseAllTargets()
        #expect(t.status == .paused)
        m.pauseAllTargets()
        #expect(t.status == .paused, "second Pause All must be a no-op on already-paused targets")
    }

    @Test func resumeAllTargetsOnlyTouchesPaused() {
        let m = VideoScanModel()
        let pausedT = CatalogScanTarget(searchPath: "/Volumes/A")
        pausedT.status = .paused
        let scanningT = CatalogScanTarget(searchPath: "/Volumes/B")
        scanningT.status = .scanning
        m.scanTargets = [pausedT, scanningT]

        m.resumeAllTargets()

        #expect(pausedT.status == .scanning, "paused target resumed")
        #expect(scanningT.status == .scanning, "scanning target unchanged")
    }
}
