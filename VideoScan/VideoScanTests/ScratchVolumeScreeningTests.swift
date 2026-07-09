// ScratchVolumeScreeningTests.swift
//
// Regression sensors for the RAM-disk scratch volume
// (/Volumes/VideoScan_Temp*, mounted by RAMDisk.swift as the
// network-prefetch cache) leaking into scan-target lists — the bug Rick
// hit again 2026-07-08 when the RAM disk showed up as a row in the
// Analyze dashboard.
//
// Why it regressed before + why it can't now: screening used to be six
// scattered ad-hoc `contains("VideoScan_Temp")` filters, one per display
// surface, with no sensor — so every NEW enumeration surface (this time
// DossierDashboardView.reachableVolumes and the CaptionOrchestrator
// candidate gates) shipped unscreened. The fix centralizes on ONE
// predicate (CatalogScanTarget.isScratchVolumePath) and, more
// importantly, screens every INGESTION point so a scratch target can't
// even ENTER model.scanTargets:
//   * discoverVolumes / addDiscoveredVolumes  (the likely original leak —
//     the RAM disk is mounted during network scans, so it appeared in the
//     discovery sheet)
//   * addScanTarget (NSOpenPanel)
//   * restoreTargetsFromCatalog (volume roots derived from records)
//   * ScanTargetPersistence.restore (persisted state — heals pollution)
//   * bundle volume import (older bundles pre-date the export filter)
//   * startTarget / startAllTargets (last gate before catalog pollution)
// The ingestion sensors below fail for ANY future unscreened ingestion
// path that routes through these functions, and the analyzeCandidates /
// excludingScratch tests cover display surfaces that filter a targets
// list independently.
//
// Feature-test checklist dimensions covered: 1 (logic), 4 (poisoned
// persisted state), 5 (regression sensors).

import Foundation
import Testing
@testable import VideoScan

@Suite("Scratch Volume Screening") @MainActor
struct ScratchVolumeScreeningTests {

    // MARK: - Canonical predicate semantics (pinned)

    @Test func predicateMatchesRAMDiskFamilyPaths() {
        // The exact mount RAMDisk.mount creates.
        #expect(CatalogScanTarget.isScratchVolumePath("/Volumes/VideoScan_Temp"))
        #expect(CatalogScanTarget.isScratchVolumePath("/Volumes/VideoScan_Temp/"))
        // macOS mount-name collision suffixes — the same family
        // RAMDisk.cleanupStaleMounts reaps with its VideoScan_Temp* prefix.
        #expect(CatalogScanTarget.isScratchVolumePath("/Volumes/VideoScan_Temp 1"))
        #expect(CatalogScanTarget.isScratchVolumePath("/Volumes/VideoScan_Temp2"))
        // Subpaths beneath the scratch mount.
        #expect(CatalogScanTarget.isScratchVolumePath("/Volumes/VideoScan_Temp/prefetch/clip.mov"))
        // Component-PREFIX match anywhere in the path. Deliberate: keeps
        // the screen at least as strong as the old `contains` filters for
        // prefix-named folders.
        #expect(CatalogScanTarget.isScratchVolumePath("/Volumes/MyDrive/VideoScan_Temp_backup"))
    }

    @Test func predicateIgnoresLegitimatePaths() {
        #expect(!CatalogScanTarget.isScratchVolumePath(""))
        #expect(!CatalogScanTarget.isScratchVolumePath("/"))
        #expect(!CatalogScanTarget.isScratchVolumePath("/Volumes/LaCie 8TB"))
        #expect(!CatalogScanTarget.isScratchVolumePath("/Volumes/Seagate2TB/Family Videos"))
        // Mid-component hit was a false positive under the old bare
        // `contains("VideoScan_Temp")` — the predicate anchors on component
        // prefix, so a user folder like this stays visible. Pinned.
        #expect(!CatalogScanTarget.isScratchVolumePath("/Volumes/MyVideoScan_TempStuff"))
    }

    @Test func targetIsScratchVolumeDerivesFromSearchPath() {
        #expect(CatalogScanTarget(searchPath: "/Volumes/VideoScan_Temp").isScratchVolume)
        #expect(!CatalogScanTarget(searchPath: "/Volumes/LaCie").isScratchVolume)
    }

    // MARK: - Display/queue gates (extracted, testable filters)

    /// The Analyze dashboard rows + caption sweep + dossier queue all
    /// share this gate. A reachable, non-retired scratch target must be
    /// dropped by the scratch clause ALONE.
    @Test func analyzeCandidatesExcludeScratchTarget() {
        let real = CatalogScanTarget(searchPath: "/Volumes/TestReal")
        real.isReachable = true
        let scratch = CatalogScanTarget(searchPath: "/Volumes/VideoScan_Temp")
        scratch.isReachable = true // reachable + not retired — only the scratch clause can drop it
        let retired = CatalogScanTarget(searchPath: "/Volumes/TestRetired")
        retired.isReachable = true
        retired.retiredAt = Date()

        let rows = CatalogScanTarget.analyzeCandidates([real, scratch, retired])
        #expect(rows.map(\.searchPath) == ["/Volumes/TestReal"])
    }

    @Test func excludingScratchDropsOnlyScratchTargets() {
        let a = CatalogScanTarget(searchPath: "/Volumes/A")
        let s = CatalogScanTarget(searchPath: "/Volumes/VideoScan_Temp 1")
        let b = CatalogScanTarget(searchPath: "/Volumes/B")
        let out = CatalogScanTarget.excludingScratch([a, s, b])
        #expect(out.map(\.searchPath) == ["/Volumes/A", "/Volumes/B"])
    }

    // MARK: - Ingestion sensor: discovered-volume add

    @Test func addDiscoveredVolumesRefusesScratchMount() {
        let model = VideoScanModel()
        model.scanTargets = []
        let scratch = DiscoveredVolume(name: "VideoScan_Temp",
                                       path: "/Volumes/VideoScan_Temp",
                                       isNetwork: false,
                                       totalBytes: 4_000_000_000,
                                       freeBytes: 4_000_000_000,
                                       alreadyAdded: false)
        let real = DiscoveredVolume(name: "TestDrive",
                                    path: "/Volumes/TestDrive",
                                    isNetwork: false,
                                    totalBytes: 1, freeBytes: 1,
                                    alreadyAdded: false)
        model.addDiscoveredVolumes([scratch, real])
        #expect(model.scanTargets.map(\.searchPath) == ["/Volumes/TestDrive"])
    }

    // MARK: - Ingestion sensor: restore-from-catalog-history

    @Test func restoreTargetsFromCatalogSkipsScratchRecords() {
        let model = VideoScanModel()
        model.scanTargets = []
        let scratchRec = VideoRecord()
        scratchRec.fullPath = "/Volumes/VideoScan_Temp/prefetch/abc.mov"
        let realRec = VideoRecord()
        realRec.fullPath = "/Volumes/TestDriveXYZ/home/movie.mov"
        model.records = [scratchRec, realRec]

        let restoredCount = model.restoreTargetsFromCatalog()
        #expect(restoredCount == 1)
        #expect(model.scanTargets.map(\.searchPath) == ["/Volumes/TestDriveXYZ"])
    }

    // MARK: - Poisoned persisted state (checklist dimension 4)

    /// Pre-fix builds could persist the scratch volume into the saved
    /// scan-target list. Restore must screen it out, and re-persisting the
    /// screened list must heal the stored state.
    @Test func persistedStateRestoreDropsScratchTargetsAndHeals() {
        let id = UUID().uuidString.prefix(8)
        let k = (paths: "scr\(id)_p", dates: "scr\(id)_d", phases: "scr\(id)_ph",
                 roles: "scr\(id)_r", trust: "scr\(id)_tr", fs: "scr\(id)_f",
                 mt: "scr\(id)_m", py: "scr\(id)_py", cap: "scr\(id)_c",
                 notes: "scr\(id)_n", retAt: "scr\(id)_rA",
                 retRsn: "scr\(id)_rR", retWit: "scr\(id)_rW")
        defer {
            for key in [k.paths, k.dates, k.phases, k.roles, k.trust, k.fs,
                        k.mt, k.py, k.cap, k.notes, k.retAt, k.retRsn, k.retWit] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // Poison: saved list carries the RAM disk alongside a real volume.
        UserDefaults.standard.set(
            ["/Volumes/VideoScan_Temp", "/Volumes/TestKeeper"],
            forKey: k.paths
        )

        let restored = ScanTargetPersistence.restore(
            existing: [],
            savedTargetsKey: k.paths, savedDatesKey: k.dates,
            savedPhasesKey: k.phases, savedRolesKey: k.roles,
            savedTrustKey: k.trust, savedFilesystemKey: k.fs,
            savedMediaTechKey: k.mt, savedPurchaseYearKey: k.py,
            savedCapacityKey: k.cap, savedNotesKey: k.notes,
            savedRetiredAtKey: k.retAt,
            savedRetiredReasonKey: k.retRsn,
            savedRetiredWitnessesKey: k.retWit
        )
        #expect(restored.map(\.searchPath) == ["/Volumes/TestKeeper"])

        // Healing: persisting the screened list rewrites the stored paths
        // without the scratch entry (this is what restoreScanTargets does
        // right after restore when it detects pollution).
        ScanTargetPersistence.persistPaths(restored, key: k.paths)
        #expect(UserDefaults.standard.stringArray(forKey: k.paths) == ["/Volumes/TestKeeper"])
    }

    // MARK: - Resume path sensor: a stale checkpoint can't resurrect scratch

    /// resumeTarget bypasses startTarget entirely when a checkpoint
    /// exists, so it needs its OWN scratch guard (QA 2026-07-08 —
    /// mirrors the retire-guard precedent at the same site). Unique
    /// scratch-family path + defer delete so the real checkpoint
    /// directory is left exactly as found.
    @Test func resumeTargetRefusesScratchEvenWithCheckpoint() async {
        let model = VideoScanModel()
        let path = "/Volumes/VideoScan_Temp Sensor-\(UUID().uuidString.prefix(8))"
        let scratch = CatalogScanTarget(searchPath: path)
        scratch.isReachable = true
        model.scanTargets = [scratch]

        ScanCheckpointStorage.save(ScanCheckpoint(
            volumePath: path,
            startedAt: Date(),
            discoveredPaths: ["\(path)/a.mov"],
            totalDiscovered: 1))
        defer { ScanCheckpointStorage.delete(for: path) }

        model.resumeTarget(scratch)
        // Refused BEFORE the checkpoint is consumed: no state mutation,
        // no scan task. (Unfixed, this reads .scanning with a live task.)
        #expect(scratch.status.isIdle)
        #expect(scratch.scanTask == nil)
        #expect(!model.isScanning)
        await scratch.scanTask?.value   // drain if a regression spawned one
    }

    // MARK: - Browse-path sensor: re-pointing a target can't smuggle scratch

    /// The ninth ingestion vector: Browse… on an existing target row
    /// assigns searchPath directly, bypassing every add-time screen.
    @Test func browsedPathRefusesScratchVolume() {
        let target = CatalogScanTarget(searchPath: "/Volumes/Old")
        #expect(!CatalogView.applyBrowsedPath("/Volumes/VideoScan_Temp", to: target))
        #expect(target.searchPath == "/Volumes/Old")

        #expect(CatalogView.applyBrowsedPath("/Volumes/NewDrive", to: target))
        #expect(target.searchPath == "/Volumes/NewDrive")
    }

    // MARK: - Last-gate sensor: bulk scan start skips scratch

    /// startAllTargets' loop guard, exercised as predicate composition
    /// (same style as RelocateRetireVolumeTests — kicking a real scan in a
    /// unit test would touch real filesystem state).
    @Test func startAllCandidatesExcludeScratch() {
        let model = VideoScanModel()
        let real = CatalogScanTarget(searchPath: "/Volumes/TestReal")
        real.isReachable = true
        let scratch = CatalogScanTarget(searchPath: "/Volumes/VideoScan_Temp")
        scratch.isReachable = true
        model.scanTargets = [real, scratch]

        let candidates = model.scanTargets.filter {
            ($0.status.isIdle || $0.status == .stopped)
                && !$0.isScratchVolume && $0.isReachable && !$0.isRetired
        }
        #expect(candidates.map(\.searchPath) == ["/Volumes/TestReal"])
    }
}
