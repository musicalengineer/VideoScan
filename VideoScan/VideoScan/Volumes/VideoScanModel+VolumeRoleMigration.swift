import Foundation
import os

// MARK: - Volume-role taxonomy migration (2026-08-16)
//
// docs/volume_taxonomy_proposal.md, approved by Rick 2026-08-16. The
// VolumeRole enum lost `.retired` (retirement is a lifecycle event owned by
// `CatalogScanTarget.retiredAt`), merged `.original` into the new
// `.workspace`, renamed `.lta` → `.cloud`. `.archive` ("Master Archive")
// means THE Master Archive and `.system` the boot volume — neither is
// user-pickable.
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
    ///       tagged ~/Movies) → `.workspace` — folder targets in ~ are not system
    ///   R3. `.unassigned` inside a home folder → `.workspace` (default)
    ///   R4. `.archive` on a target that is PROVABLY not the designated
    ///       Master Archive, while the master's own target is RESOLVED
    ///       (`resolvedMasterArchiveTarget() != nil`) → queued in
    ///       `pendingRoleReclassifications` (never silently renamed; the
    ///       Volumes window asks Workspace / Backup once). "Unknown ≠
    ///       not-master" (codex M1, same rule as PromoteToArchiveJob): a
    ///       target that is offline, reports no volume UUID, carries the
    ///       designation's UUID, or is a volume-rename candidate pointing
    ///       at the designation is NEVER queued — see
    ///       `isProvablyNotMasterArchiveVolume`. With no designation yet
    ///       (or an unresolvable master) an Archive-role target is left
    ///       alone — it may well be the one Rick is about to Initialize.
    ///   R5. legacy "Retired" role → handled at decode time (stamp), so by
    ///       the time we get here it is `.unassigned` + `retiredAt`.
    /// Returns the number of targets whose role changed (for logging /
    /// tests). Persists only when something changed.
    @discardableResult
    func migrateVolumeRoles(now: Date = Date()) -> Int {
        var changed = 0
        var queued = 0
        // R4 needs the master's own target resolved (path or volume UUID)
        // — otherwise every Archive-role target is a suspect for being the
        // master under a renamed/rehomed path, and we ask nobody.
        let master = masterArchive != nil ? resolvedMasterArchiveTarget() : nil

        for t in scanTargets where !t.searchPath.isEmpty && !t.isScratchVolume {
            let before = t.role
            if t.isBootVolumeRoot {
                // R1
                if t.role != .system { t.role = .system }
            } else if t.role == .system, t.isHomeFolderTarget {
                // R2
                t.role = .workspace
            } else if t.role == .unassigned, t.isHomeFolderTarget {
                // R3
                t.role = .workspace
            } else if t.role == .archive, let master, master !== t,
                      isProvablyNotMasterArchiveVolume(t) {
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
            log("Volume roles updated for \(changed) target(s) (System / Workspace defaults).")
            persistScanDates()
            notifyTargetsChanged()
        }
        if queued > 0 {
            log("\(queued) volume(s) were marked Archive but only the Master Archive can be that now — the Volumes window will ask you to pick Workspace or Backup for each.")
        }
        return changed
    }

    /// codex M1 — R4's "is this Archive-role target really NOT the Master
    /// Archive?" question, answered conservatively. Returns true ONLY when
    /// we can prove it; every unknown answers false (never queued):
    ///   - no designation, or `t` IS the designation's path → false
    ///   - `t` is a volume-rename candidate whose new path is the
    ///     designation's path or whose volume UUID is the designation's
    ///     (the master's stale old-path target after a rename) → false
    ///   - `t` offline → false (cannot read its identity)
    ///   - designation has a UUID: `t`'s mounted volume must report a
    ///     DIFFERENT UUID (equal or nil → false)
    ///   - designation has no UUID (legacy): reachable + different path
    ///     is the best evidence available → true
    func isProvablyNotMasterArchiveVolume(_ t: CatalogScanTarget) -> Bool {
        guard let d = masterArchive else { return false }
        if isMasterArchive(t) { return false }
        if let c = volumeRenameCandidate(for: t.searchPath) {
            if Self.samePath(c.newTargetPath, d.targetPath) { return false }
            if let uuid = d.volumeUUID, c.volumeUUID == uuid { return false }
        }
        guard t.isReachable else { return false }
        if let uuid = d.volumeUUID {
            guard let mine = MasterArchiveDesignation.volumeUUID(forPath: t.searchPath) else { return false }
            return mine != uuid
        }
        return true
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
