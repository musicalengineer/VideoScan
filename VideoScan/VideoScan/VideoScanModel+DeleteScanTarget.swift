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

// MARK: - Guarded record removal under a target root (2026-07-03)
//
// Safety net for the 2026-07-01 incident: removing two folder targets
// silently deleted 2,720 catalog records including dossier enrichment.
// Every record-removal scoped to a target's root now goes through ONE
// helper that (a) keeps records still covered by ANOTHER registered
// target's root (component-boundary PathScope — a folder target nested
// under a volume target does not own its records exclusively), (b) writes
// a catalog.pre-target-removal.<stamp>.json recovery snapshot before any
// removal larger than the threshold, degrading to NO removal if the
// snapshot cannot be written (same fail-safe contract as the scan-merge
// tripwire), and (c) emits one prominent log line carrying the count.

/// Outcome of a guarded target-scoped record removal.
struct TargetRecordRemovalOutcome {
    var removed = 0
    /// Records under the root that were KEPT because another registered
    /// scan target's root also covers them.
    var keptCoveredByOtherTargets = 0
    var snapshotPath: String?
    /// True when >threshold records should have been removed but the
    /// safety snapshot could not be written — nothing was removed.
    var degradedNoSnapshot = false
}

extension VideoScanModel {

    /// Removals larger than this must land a recovery snapshot first.
    static let targetRemovalSnapshotThreshold = 50

    /// Remove catalog records under `root`, honoring the coverage check,
    /// snapshot tripwire, and fail-safe degrade described above.
    /// `action` names the caller for the log trail ("reset",
    /// "delete catalog", …).
    @discardableResult
    func removeCatalogRecords(underTargetRoot root: String, action: String) -> TargetRecordRemovalOutcome {
        var outcome = TargetRecordRemovalOutcome()
        let normRoot = PathScope.normalize(root)
        // Every OTHER registered target root that could cover a record.
        // Retired targets count: retire deliberately keeps records, so
        // their roots still own them.
        let otherRoots = scanTargets.map(\.searchPath)
            .filter { PathScope.normalize($0) != normRoot }

        var doomed = Set<ObjectIdentifier>()
        for rec in records where PathScope.contains(rec.fullPath, within: root) {
            if otherRoots.contains(where: { PathScope.contains(rec.fullPath, within: $0) }) {
                outcome.keptCoveredByOtherTargets += 1
            } else {
                doomed.insert(ObjectIdentifier(rec))
            }
        }

        guard !doomed.isEmpty else {
            if outcome.keptCoveredByOtherTargets > 0 {
                log("Target \(action) (\(root)): removed 0 record(s) — all \(outcome.keptCoveredByOtherTargets) under this root are still covered by other scan target(s).")
            }
            return outcome
        }

        if doomed.count > Self.targetRemovalSnapshotThreshold {
            outcome.snapshotPath = snapshotCatalog(prefix: "pre-target-removal")
            if outcome.snapshotPath == nil {
                // FAIL SAFE: no recovery copy → no destruction. Mirrors the
                // scan-merge tripwire degrade.
                outcome.degradedNoSnapshot = true
                log("""
                  ⚠️⚠️ TARGET \(action.uppercased()) DEGRADED — \(root)
                  This would remove \(doomed.count) catalog record(s), but the pre-removal safety snapshot could NOT be written.
                  NOTHING was removed. Fix the catalog directory and retry to remove for real.
                  """)
                appLog.write("TARGET \(action.uppercased()) (DEGRADED): could not write catalog.pre-target-removal snapshot; kept all \(doomed.count) record(s) under \(root)")
                return outcome
            }
        }

        records.removeAll { doomed.contains(ObjectIdentifier($0)) }
        outcome.removed = doomed.count

        // (b) THE one prominent line — count first, context after.
        let keptNote = outcome.keptCoveredByOtherTargets > 0
            ? " — kept \(outcome.keptCoveredByOtherTargets) record(s) still covered by other scan target(s)"
            : ""
        let snapNote = outcome.snapshotPath.map { " — recovery snapshot: \($0)" } ?? ""
        log("⚠️ Target \(action): removed \(outcome.removed) catalog record(s) under \(root)\(keptNote)\(snapNote)")
        appLog.write("Target \(action) (\(root)): removed \(outcome.removed) record(s), kept \(outcome.keptCoveredByOtherTargets) covered by other targets\(snapNote)")
        return outcome
    }
}
