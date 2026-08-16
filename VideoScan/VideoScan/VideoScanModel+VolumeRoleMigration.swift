import Foundation
import os

// MARK: - Volume-role taxonomy migration (2026-08-16)
//
// docs/volume_taxonomy_proposal.md, approved by Rick 2026-08-16. The
// VolumeRole enum lost `.retired` (retirement is a lifecycle event owned by
// `CatalogScanTarget.retiredAt`), renamed `.lta` → `.offsite`, and gained
// `.working`. `.archive` now means THE Master Archive and `.system` the
// boot volume — neither is user-pickable.
//
// Two layers do the migration:
//   1. DECODE — `ScanTargetPersistence.applyPersistedRole` (UserDefaults
//      restore + bundle/volume-snapshot import) maps legacy raw strings and
//      converts a legacy "Retired" role into a `retiredAt` stamp.
//   2. MODEL — `migrateVolumeRoles()` below: needs knowledge the decoder
//      lacks (which target is the Master Archive, what the boot volume is).
//
// Both are idempotent and additive: safe to run on every launch, after
// every import, and twice in a row. Nothing here deletes a target or a
// stamp; the only user-facing effect is the one-time reclassification
// sheet in the Volumes window for legacy non-master "Archive" targets.

private let roleMigrationLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                      category: "volumeRoles")

extension VideoScanModel {

    /// One idempotent pass over `scanTargets`:
    ///   R1. boot volume root ("/", "/System/Volumes/Data", "/Volumes/<Boot>")
    ///       → `.system` (auto-assigned; hidden from pickers)
    ///   R2. `.system` on a NON-boot path inside a home folder (e.g. a hand-
    ///       tagged ~/Movies) → `.working` — folder targets in ~ are not system
    ///   R3. `.unassigned` inside a home folder → `.working` (default)
    ///   R4. `.archive` on a target that is NOT the designated Master
    ///       Archive, while a Master Archive IS designated → queued in
    ///       `pendingRoleReclassifications` (never silently renamed; the
    ///       Volumes window asks Original / Backup / Working once). With
    ///       no designation yet, an Archive-role target is left alone —
    ///       it may well be the one Rick is about to Initialize.
    ///   R5. legacy "Retired" role → handled at decode time (stamp), so by
    ///       the time we get here it is `.unassigned` + `retiredAt`.
    /// Returns the number of targets whose role changed (for logging /
    /// tests). Persists only when something changed.
    @discardableResult
    func migrateVolumeRoles(now: Date = Date()) -> Int {
        var changed = 0
        var queued = 0
        let master = masterArchive != nil ? resolvedMasterArchiveTarget() : nil

        for t in scanTargets where !t.searchPath.isEmpty && !t.isScratchVolume {
            let before = t.role
            if t.isBootVolumeRoot {
                // R1
                if t.role != .system { t.role = .system }
            } else if t.role == .system, t.isHomeFolderTarget {
                // R2
                t.role = .working
            } else if t.role == .unassigned, t.isHomeFolderTarget {
                // R3
                t.role = .working
            } else if t.role == .archive, masterArchive != nil,
                      master !== t, !isMasterArchive(t) {
                // R4 — flag, don't rename. Dedup so a second pass (or a
                // re-import) doesn't double-list the same target.
                if !pendingRoleReclassifications.contains(where: { $0 === t }) {
                    pendingRoleReclassifications.append(t)
                    queued += 1
                }
            }
            if t.role != before {
                changed += 1
                roleMigrationLog.notice("role migration: \(t.searchPath, privacy: .public) \(before.rawValue, privacy: .public) → \(t.role.rawValue, privacy: .public)")
            }
        }
        // Drop queue entries that no longer need asking (target removed,
        // became the master, or was re-roled by hand meanwhile).
        pendingRoleReclassifications.removeAll { t in
            t.role != .archive || isMasterArchive(t) || !scanTargets.contains(where: { $0 === t })
        }
        if changed > 0 {
            log("Volume roles updated for \(changed) target(s) (System / Working defaults).")
            persistScanDates()
            notifyTargetsChanged()
        }
        if queued > 0 {
            log("\(queued) volume(s) were marked Archive but only the Master Archive can be Archive now — the Volumes window will ask you to pick a role for each.")
        }
        return changed
    }

    /// The user answered the reclassification sheet for `target`. Only
    /// user-selectable roles are accepted (`.archive` / `.system` are
    /// refused — the whole point of the sheet is to leave `.archive` to
    /// the master). Removes the target from the pending list and persists.
    @discardableResult
    func resolveRoleReclassification(_ target: CatalogScanTarget, to role: VolumeRole) -> Bool {
        guard role.isUserSelectable else {
            log("Refused to reclassify \(VolumeReachability.displayLabel(forPath: target.searchPath)) as \(role.rawValue) — that role is not user-selectable.")
            return false
        }
        target.role = role
        pendingRoleReclassifications.removeAll { $0 === target }
        persistScanDates()
        notifyTargetsChanged()
        roleMigrationLog.notice("reclassified legacy Archive \(target.searchPath, privacy: .public) → \(role.rawValue, privacy: .public)")
        return true
    }
}
