import Foundation

// MARK: - VideoScanModel+DeleteScanTarget
//
// "Delete from list" — companion to §1B Retire Volume. Retire is the
// "drive going on the shelf, data is safely backed up" path; Delete is
// the "this entry was a mistake (orphan, typo, dangling mount that was
// never really a scan target)" path. Real-world driver: `/Volumes/rickb`
// shows up in the Volumes window with 0 catalog records — it's a
// dangling target from a one-time mount that should never have been
// added. Retire is wrong for it (nothing to back up); Delete from list
// is the right call.
//
// Important contract: this removes ONLY the volume from `scanTargets`
// and its parallel UserDefaults entries. Catalog records whose
// `fullPath` is under the deleted volume's `searchPath` are NOT
// touched. They become orphans (no scan-target context) but stay in
// the catalog for history. The UI confirmation alert tells the user
// this explicitly.

extension VideoScanModel {

    /// Remove a scan target from `scanTargets` and clear all of its
    /// per-path UserDefaults dictionaries (dates, phases, roles, trust,
    /// filesystem, mediaTech, purchaseYear, capacity, notes, retire
    /// fields). Catalog records are deliberately left intact.
    ///
    /// Idempotent: calling on a target that's already absent from
    /// `scanTargets` is a no-op (logged at debug level so we still see
    /// the breadcrumb).
    ///
    /// Foot-shooting guard: refuses to delete a target whose `role` is
    /// `.system` OR whose `searchPath` is `"/"` (the root volume). The
    /// Volumes window also disables the menu item for these — this is
    /// the model-level belt-and-suspenders.
    @discardableResult
    func deleteScanTarget(_ target: CatalogScanTarget) -> Bool {
        // Guard: never delete the system volume. The role check covers
        // the explicit case; the "/" path check is a defensive fallback
        // for installs where the role wasn't set yet.
        // Swift's `guard` early-return ~= C++ `if (cond) return false;`.
        guard target.role != .system, target.searchPath != "/" else {
            log("Delete refused: \(target.searchPath) is the system volume.")
            return false
        }

        // Count records still pointing at this path BEFORE we remove
        // the target so the log breadcrumb carries the orphan count.
        let orphanCount = Self.totalRecordsOn(
            volumeRootPath: target.searchPath, in: records
        )
        let displayName = VolumeReachability.displayLabel(forPath: target.searchPath)

        // Remove from the published array. The `ObjectIdentifier`
        // comparison handles the case where two targets share a
        // searchPath (shouldn't happen, but defensive).
        // Swift's `removeAll(where:)` ~= C++ `erase_if(vec, pred)`.
        let beforeCount = scanTargets.count
        scanTargets.removeAll { $0 === target }
        let removed = scanTargets.count < beforeCount

        if !removed {
            log("Delete: target \(target.searchPath) was not in scanTargets list (no-op).")
            return false
        }

        // Persist: rewrite both the path list AND the per-path
        // dictionaries from the updated `scanTargets`. `persistMetadata`
        // builds each dict by iterating `scanTargets` — so the deleted
        // path naturally falls out of every dict in one shot.
        persistScanTargets()
        persistScanDates()
        notifyTargetsChanged()

        log("Volume \(displayName) deleted from scan-targets list (had \(orphanCount) catalog records — kept as orphans).")
        return true
    }
}
