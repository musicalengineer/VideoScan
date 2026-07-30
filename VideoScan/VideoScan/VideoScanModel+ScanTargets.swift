import Foundation
import AppKit

// MARK: - Scan Target Management (the list, not the per-scan run)
//
// CRUD on the scanTargets array: add a folder, remove a target, and restore
// lost targets from catalog history. The actual
// scan lifecycle (start/stop/pause) lives in VideoScanModel+ScanLifecycle.
// The big runScanForTarget probe loop lives in
// VideoScanModel+ScanExecution.

extension VideoScanModel {

    func addScanTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select volumes or folders to scan (⌘-click for multiple)"
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path
                // Ingestion screen: the RAM-disk scratch volume is plumbing,
                // never a scan target — even if hand-picked in the panel.
                guard !CatalogScanTarget.isScratchVolumePath(path) else {
                    log("Skipped \(path) — that's VideoScan's own RAM-disk scratch volume, not a scannable target.")
                    continue
                }
                if !scanTargets.contains(where: { $0.searchPath == path }) {
                    scanTargets.append(CatalogScanTarget(searchPath: path))
                }
            }
            persistScanTargets()
        }
    }

    /// Number of scan targets that pass the "unscanned & idle" sweep.
    /// Used by the UI to decide whether to surface the cleanup affordance.
    var unscannedTargetCount: Int {
        scanTargets.lazy.filter { Self.isUnscannedRemovable($0) }.count
    }

    /// Belt-and-suspenders predicate used by `cleanupUnscannedTargets` and the
    /// UI count. Kept `static` so tests can exercise it directly and so it
    /// stays in lock-step between the count badge and the actual removal.
    static func isUnscannedRemovable(_ t: CatalogScanTarget) -> Bool {
        if t.lastScannedDate != nil { return false }
        if !t.status.isIdle { return false }
        // Defensive against double-cleanup races and against the obvious noise
        // case where XcodeRAM was somehow injected into scanTargets.
        if t.searchPath.hasPrefix("/Volumes/XcodeRAM") { return false }
        return true
    }

    /// Remove scan targets that have never been scanned successfully and
    /// aren't currently doing anything. This is the manual escape hatch for
    /// users whose target list got polluted by the old auto-add-on-mount
    /// behavior. Returns the number of targets removed.
    @discardableResult
    func cleanupUnscannedTargets() -> Int {
        // Swift's `filter` returns a new Array — equivalent to a C++
        // std::copy_if into a fresh vector. No mutation of `scanTargets` yet.
        let toRemove = scanTargets.filter { Self.isUnscannedRemovable($0) }
        let removeIDs = Set(toRemove.map { $0.id })
        scanTargets.removeAll { removeIDs.contains($0.id) }
        persistScanTargets()
        log("Cleaned up \(toRemove.count) unscanned scan target(s)")
        notifyTargetsChanged()
        return toRemove.count
    }

    /// Scan catalog records for volume roots that aren't in the current scan target
    /// list and re-add them. This recovers targets lost due to UserDefaults resets or
    /// key name changes. Returns the number of targets restored.
    @discardableResult
    func restoreTargetsFromCatalog() -> Int {
        let existingPaths = Set(scanTargets.map { $0.searchPath })
        var volumeRoots = Set<String>()

        for rec in records {
            let path = rec.fullPath
            guard !path.isEmpty else { continue }
            // Extract volume root: /Volumes/VolumeName
            if path.hasPrefix("/Volumes/") {
                let parts = path.split(separator: "/", maxSplits: 3)
                if parts.count >= 2 {
                    let root = "/Volumes/" + String(parts[1])
                    volumeRoots.insert(root)
                }
            }
        }

        var restored = 0
        for root in volumeRoots.sorted() where !existingPaths.contains(root) {
            // If scratch-volume records ever slipped into the catalog
            // (pre-screening builds), don't resurrect the RAM disk as a
            // target from their paths.
            guard !CatalogScanTarget.isScratchVolumePath(root) else { continue }
            let target = CatalogScanTarget(searchPath: root)
            scanTargets.append(target)
            restored += 1
        }

        if restored > 0 {
            persistScanTargets()
            refreshTargetReachability()
            log("Restored \(restored) scan target(s) from catalog history.")
        }
        return restored
    }

    /// "Remove from List" / "Remove Selected" (Catalog volume context menu).
    ///
    /// DATA-SAFETY CONTRACT (codex C1): this is a *list* operation, not a
    /// catalog purge. It stops any in-flight work for the target and drops
    /// its probe cache (all safe, record-independent cleanup), then removes
    /// the target from `scanTargets` while PRESERVING every catalog record
    /// under the volume as an orphan. The record-preserving removal +
    /// per-path UserDefaults teardown is exactly `deleteScanTarget`'s
    /// contract, so we delegate to it rather than duplicating the logic.
    ///
    /// Previously this method did `records.removeAll { hasPrefix }` followed
    /// by `saveCatalogNow()`, which permanently deleted and persisted-away
    /// the user's irreplaceable catalog records with no confirmation. If a
    /// genuinely-destructive "remove AND purge records" action is ever
    /// wanted it must be a separate, clearly-labeled, confirmation-gated
    /// action — never the default "Remove from List".
    func removeScanTarget(_ target: CatalogScanTarget) {
        // Record-independent cleanup — always safe to run.
        target.scanTask?.cancel()
        target.stopElapsedTimer()
        clearCacheForTarget(target)
        // Remove from the list but KEEP catalog records (orphan semantics).
        deleteScanTarget(target)
    }
}
