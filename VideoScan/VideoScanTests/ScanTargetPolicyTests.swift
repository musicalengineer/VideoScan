import Testing
import Foundation
@testable import VideoScan

/// Tests for the strict-catalog scan-target policy (Issue: stop auto-adding
/// random mounted volumes). Covers three pieces:
///   1. Mount handler no longer auto-appends targets.
///   2. Mount handler STILL refreshes reachability on existing targets.
///   3. `cleanupUnscannedTargets` removes only unscanned-idle targets,
///      is idempotent, and respects the XcodeRAM belt-and-suspenders guard.
@Suite("Scan Target Policy — strict catalog view")
@MainActor
struct ScanTargetPolicyTests {

    // MARK: - Helpers

    /// Make a fresh model with no targets and no leftover records.
    /// (Init still installs mount observers in the real notification center;
    /// that's fine — we don't simulate via NSWorkspace here, we call the
    /// synchronous handler directly.)
    private func freshModel() -> VideoScanModel {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        model.records.removeAll()
        return model
    }

    // MARK: - 1. Mount handler no longer auto-adds

    @Test func mountEventDoesNotAutoAppendTarget() {
        let model = freshModel()
        #expect(model.scanTargets.isEmpty)

        // Pretend a brand-new volume just mounted. Under the old behavior
        // this would have appended a CatalogScanTarget. Under the strict
        // policy it must NOT.
        let fakeMount = URL(fileURLWithPath: "/Volumes/SomeRandomDMG_\(UUID().uuidString)")
        model.handleVolumeMounted(at: fakeMount)

        #expect(model.scanTargets.isEmpty,
                "Mount notification must not auto-add a scan target under strict-catalog policy.")
    }

    @Test func mountEventForXcodeRAMDoesNotAutoAppend() {
        // Even before the strict-catalog change, XcodeRAM was the headline
        // offender. Belt-and-suspenders: prove the mount handler ignores it.
        let model = freshModel()
        let xcodeRAM = URL(fileURLWithPath: "/Volumes/XcodeRAM")
        model.handleVolumeMounted(at: xcodeRAM)
        #expect(model.scanTargets.isEmpty)
    }

    @Test func mountEventWithNilURLIsSafeNoOp() {
        // Real NSWorkspace.didMountNotification sometimes arrives without
        // a volumeURL — e.g. on rare disk-arbitration races. Must not crash.
        let model = freshModel()
        model.handleVolumeMounted(at: nil)
        #expect(model.scanTargets.isEmpty)
    }

    // MARK: - 2. Reachability refresh on existing targets still works

    @Test func mountEventRefreshesReachabilityOnExistingTarget() throws {
        // Create a real temp directory so VolumeReachability.isReachable
        // returns `true` when we check the path. We then set the target's
        // isReachable to false manually, fake a mount, and assert the
        // handler flipped it back to true.
        let tmpRoot = NSTemporaryDirectory() + "vs-strict-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpRoot) }

        // Drop the reachability cache so the first read isn't a stale hit
        // from another test in the same process.
        VolumeReachability.invalidateCache()

        let model = freshModel()
        let existing = CatalogScanTarget(searchPath: tmpRoot)
        existing.isReachable = false   // pretend it had been marked offline
        model.scanTargets = [existing]

        // Force the cache to its current "false" state so handleVolumeMounted
        // has to invalidate + recompute. (It does, per its first line.)
        VolumeReachability.invalidateCache()

        model.handleVolumeMounted(at: URL(fileURLWithPath: tmpRoot))

        #expect(model.scanTargets.count == 1,
                "Refreshing reachability must not add/remove targets.")
        #expect(existing.isReachable == true,
                "Existing target under the mounted volume must flip to reachable.")
    }

    // MARK: - 3. cleanupUnscannedTargets

    @Test func cleanupRemovesOnlyUnscannedIdleTargets() {
        let model = freshModel()

        let scanned = CatalogScanTarget(searchPath: "/Volumes/Scanned")
        scanned.lastScannedDate = Date()  // proof of life — keep

        let unscanned = CatalogScanTarget(searchPath: "/Volumes/RandomDMG")
        // lastScannedDate stays nil, status stays .idle — remove

        let scanning = CatalogScanTarget(searchPath: "/Volumes/InFlight")
        scanning.status = .scanning  // active work — keep

        let paused = CatalogScanTarget(searchPath: "/Volumes/Paused")
        paused.status = .paused  // mid-scan, keep

        model.scanTargets = [scanned, unscanned, scanning, paused]

        let removed = model.cleanupUnscannedTargets()

        #expect(removed == 1)
        #expect(model.scanTargets.count == 3)
        #expect(model.scanTargets.contains(where: { $0.searchPath == "/Volumes/Scanned" }))
        #expect(model.scanTargets.contains(where: { $0.searchPath == "/Volumes/InFlight" }))
        #expect(model.scanTargets.contains(where: { $0.searchPath == "/Volumes/Paused" }))
        #expect(!model.scanTargets.contains(where: { $0.searchPath == "/Volumes/RandomDMG" }))
    }

    @Test func cleanupIsIdempotent() {
        let model = freshModel()
        let unscanned1 = CatalogScanTarget(searchPath: "/Volumes/Junk1")
        let unscanned2 = CatalogScanTarget(searchPath: "/Volumes/Junk2")
        model.scanTargets = [unscanned1, unscanned2]

        let first = model.cleanupUnscannedTargets()
        let second = model.cleanupUnscannedTargets()

        #expect(first == 2)
        #expect(second == 0, "Calling cleanup again must remove zero — no double-sweep effects.")
        #expect(model.scanTargets.isEmpty)
    }

    @Test func cleanupRunsToCompletionWithPersistence() {
        // persistScanTargets() short-circuits under tests (see isRunningTests).
        // The point of this test is "does it complete without crashing and
        // does the in-memory list reflect the removal" — the disk side is
        // covered by ScanTargetPersistence tests separately. If the call
        // path ever stops invoking persistScanTargets() we'll catch that
        // when production code starts persisting empties.
        let model = freshModel()
        let unscanned = CatalogScanTarget(searchPath: "/Volumes/EphemeralVol")
        model.scanTargets = [unscanned]

        let removed = model.cleanupUnscannedTargets()

        #expect(removed == 1)
        #expect(model.scanTargets.isEmpty)
    }

    @Test func cleanupSkipsXcodeRAMEvenIfPresent() {
        // The mount handler no longer auto-adds, but an older persisted
        // target list might still contain XcodeRAM. Cleanup should leave
        // it alone — the belt-and-suspenders branch in
        // isUnscannedRemovable is what protects us from a double-cleanup
        // race where XcodeRAM had been carefully re-added.
        let model = freshModel()
        let ramdisk = CatalogScanTarget(searchPath: "/Volumes/XcodeRAM")
        // Make sure all OTHER cleanup criteria match (idle, never scanned).
        #expect(ramdisk.status.isIdle)
        #expect(ramdisk.lastScannedDate == nil)

        model.scanTargets = [ramdisk]

        let removed = model.cleanupUnscannedTargets()

        #expect(removed == 0)
        #expect(model.scanTargets.count == 1,
                "XcodeRAM must survive cleanup via the prefix guard.")
    }

    @Test func unscannedTargetCountMatchesCleanupRemoval() {
        // Count badge in the UI must stay in lock-step with what the
        // cleanup action will actually remove. If these diverge the user
        // sees a "(3)" button that removes 2 or 4.
        let model = freshModel()
        let keep = CatalogScanTarget(searchPath: "/Volumes/Kept")
        keep.lastScannedDate = Date()
        let drop1 = CatalogScanTarget(searchPath: "/Volumes/Drop1")
        let drop2 = CatalogScanTarget(searchPath: "/Volumes/Drop2")
        let ram = CatalogScanTarget(searchPath: "/Volumes/XcodeRAM")
        let active = CatalogScanTarget(searchPath: "/Volumes/Active")
        active.status = .scanning

        model.scanTargets = [keep, drop1, drop2, ram, active]

        #expect(model.unscannedTargetCount == 2)
        let removed = model.cleanupUnscannedTargets()
        #expect(removed == 2)
        #expect(model.unscannedTargetCount == 0)
    }

    @Test func unscannedTargetCountIsZeroWhenAllScanned() {
        let model = freshModel()
        let a = CatalogScanTarget(searchPath: "/Volumes/A")
        a.lastScannedDate = Date()
        let b = CatalogScanTarget(searchPath: "/Volumes/B")
        b.lastScannedDate = Date()
        model.scanTargets = [a, b]
        #expect(model.unscannedTargetCount == 0)
    }
}
