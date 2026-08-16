import Foundation
import os

private let rolePersistenceLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                        category: "volumeRoles")

/// Persistence helpers for CatalogScanTarget metadata (phase, role, trust,
/// filesystem, purchaseYear, capacityTB, notes, lastScannedDate, plus the
/// §1B retire fields: retiredAt, retiredReason, retiredWitnesses).
/// All data stored in UserDefaults using the provided key prefix.
@MainActor enum ScanTargetPersistence {

    // MARK: - Role decoding (legacy-aware, ONE place)

    /// Reason stamped onto a target whose persisted role was the pre-
    /// taxonomy "Retired" string with no `retiredAt` of its own. Retirement
    /// has one owner (`retiredAt`), so the migration converts the role into
    /// a stamp rather than losing the fact.
    static let legacyRetiredMigrationReason =
        "Marked retired before retirement had a date (migrated 2026-08-16)"

    /// Apply a persisted role string — current or legacy — to `t`. This is
    /// the ONE decode path for roles (UserDefaults restore AND bundle /
    /// volume-snapshot import both route here) so every legacy rule lives
    /// in exactly one place:
    ///   - "Long-Term Archive" / "LTA" → `.offsite`
    ///   - "Retired" → `.unassigned` AND `retiredAt` stamped if nil
    ///     (`lastScannedDate` if known, else `now`), reason set if empty
    ///   - unknown string → `.unassigned` + one log line, target kept
    /// Idempotent: a target that already carries a stamp is not re-stamped,
    /// and a current raw string is a plain assignment.
    /// Returns the decode so callers can act on `unknownRaw`.
    @discardableResult
    static func applyPersistedRole(_ raw: String,
                                   to t: CatalogScanTarget,
                                   now: Date = Date()) -> VolumeRole.LegacyDecode {
        let d = VolumeRole.decodeLegacy(raw)
        t.role = d.role
        if d.wasRetired {
            if t.retiredAt == nil {
                t.retiredAt = t.lastScannedDate ?? now
                rolePersistenceLog.notice("legacy 'Retired' role on \(t.searchPath, privacy: .public) → retiredAt stamped (\(t.lastScannedDate == nil ? "now" : "lastScannedDate", privacy: .public))")
            }
            if (t.retiredReason ?? "").isEmpty {
                t.retiredReason = legacyRetiredMigrationReason
            }
        }
        if let unknown = d.unknownRaw {
            rolePersistenceLog.error("unknown persisted VolumeRole '\(unknown, privacy: .public)' on \(t.searchPath, privacy: .public) → Unassigned (target kept)")
        } else if raw != d.role.rawValue {
            rolePersistenceLog.notice("legacy VolumeRole '\(raw, privacy: .public)' on \(t.searchPath, privacy: .public) → \(d.role.rawValue, privacy: .public)")
        }
        return d
    }

    // MARK: - Restore

    /// Restore scan targets from UserDefaults. Returns new targets not already
    /// present in `existing`.
    static func restore(
        existing: [CatalogScanTarget],
        savedTargetsKey: String,
        savedDatesKey: String,
        savedPhasesKey: String,
        savedRolesKey: String,
        savedTrustKey: String,
        savedFilesystemKey: String,
        savedMediaTechKey: String,
        savedPurchaseYearKey: String,
        savedCapacityKey: String,
        savedNotesKey: String,
        savedRetiredAtKey: String,
        savedRetiredReasonKey: String,
        savedRetiredWitnessesKey: String
    ) -> [CatalogScanTarget] {
        let paths = UserDefaults.standard.stringArray(forKey: savedTargetsKey) ?? []
        let dates = UserDefaults.standard.dictionary(forKey: savedDatesKey) as? [String: Date] ?? [:]
        let phases = UserDefaults.standard.dictionary(forKey: savedPhasesKey) as? [String: String] ?? [:]
        let roles = UserDefaults.standard.dictionary(forKey: savedRolesKey) as? [String: String] ?? [:]
        let trusts = UserDefaults.standard.dictionary(forKey: savedTrustKey) as? [String: String] ?? [:]
        let filesystems = UserDefaults.standard.dictionary(forKey: savedFilesystemKey) as? [String: String] ?? [:]
        let mediaTechs = UserDefaults.standard.dictionary(forKey: savedMediaTechKey) as? [String: String] ?? [:]
        let purchaseYears = UserDefaults.standard.dictionary(forKey: savedPurchaseYearKey) as? [String: Int] ?? [:]
        let capacities = UserDefaults.standard.dictionary(forKey: savedCapacityKey) as? [String: Double] ?? [:]
        let notes = UserDefaults.standard.dictionary(forKey: savedNotesKey) as? [String: String] ?? [:]
        // §1B retire dictionaries. Each is keyed by searchPath; presence in
        // retiredAt dict is the retired-or-not signal.
        let retiredAt = UserDefaults.standard.dictionary(forKey: savedRetiredAtKey) as? [String: Date] ?? [:]
        let retiredReason = UserDefaults.standard.dictionary(forKey: savedRetiredReasonKey) as? [String: String] ?? [:]
        let retiredWitnesses = UserDefaults.standard.dictionary(forKey: savedRetiredWitnessesKey) as? [String: [String]] ?? [:]

        var result: [CatalogScanTarget] = []
        // Restore-time screen + heal: pre-fix builds could persist the
        // RAM-disk scratch volume (VideoScan_Temp*) into the saved target
        // list. Never restore it — the next persistPaths call rewrites the
        // list without it, so polluted state heals itself.
        for p in paths where !p.isEmpty && !CatalogScanTarget.isScratchVolumePath(p) {
            if !existing.contains(where: { $0.searchPath == p }) {
                let t = CatalogScanTarget(searchPath: p)
                t.lastScannedDate = dates[p]
                if let raw = phases[p] {
                    if let phase = VolumePhase(rawValue: raw) {
                        t.phase = phase
                    } else if raw == "New" {
                        t.phase = .noCatalog
                    }
                }
                if let raw = trusts[p], let trust = VolumeTrust(rawValue: raw) {
                    t.trust = trust
                }
                t.filesystem = filesystems[p] ?? ""
                if let raw = mediaTechs[p], let tech = VolumeMediaTech(rawValue: raw) {
                    t.mediaTech = tech
                }
                t.purchaseYear = purchaseYears[p]
                t.capacityTB = capacities[p]
                t.notes = notes[p] ?? ""
                // §1B Retire — three parallel optional fields. Missing keys
                // round-trip as nil so legacy installs come back not-retired.
                // Applied BEFORE the role so a legacy "Retired" role string
                // sees the real stamp (if any) and doesn't overwrite it.
                t.retiredAt = retiredAt[p]
                t.retiredReason = retiredReason[p]
                t.retiredWitnesses = retiredWitnesses[p]
                // Role last: legacy-aware (may stamp retiredAt — see above).
                if let raw = roles[p] {
                    applyPersistedRole(raw, to: t)
                }
                result.append(t)
            }
        }
        return result
    }

    // MARK: - Persist

    static func persistPaths(_ targets: [CatalogScanTarget], key: String) {
        UserDefaults.standard.set(targets.map { $0.searchPath }, forKey: key)
    }

    static func persistMetadata(
        _ targets: [CatalogScanTarget],
        savedDatesKey: String,
        savedPhasesKey: String,
        savedRolesKey: String,
        savedTrustKey: String,
        savedFilesystemKey: String,
        savedMediaTechKey: String,
        savedPurchaseYearKey: String,
        savedCapacityKey: String,
        savedNotesKey: String,
        savedRetiredAtKey: String,
        savedRetiredReasonKey: String,
        savedRetiredWitnessesKey: String
    ) {
        var dates: [String: Date] = [:]
        var phases: [String: String] = [:]
        var roles: [String: String] = [:]
        var trusts: [String: String] = [:]
        var filesystems: [String: String] = [:]
        var mediaTechs: [String: String] = [:]
        var purchaseYears: [String: Int] = [:]
        var capacities: [String: Double] = [:]
        var notesMap: [String: String] = [:]
        var retiredAtMap: [String: Date] = [:]
        var retiredReasonMap: [String: String] = [:]
        var retiredWitnessesMap: [String: [String]] = [:]
        for t in targets {
            if let d = t.lastScannedDate { dates[t.searchPath] = d }
            phases[t.searchPath] = t.phase.rawValue
            roles[t.searchPath] = t.role.rawValue
            trusts[t.searchPath] = t.trust.rawValue
            if !t.filesystem.isEmpty { filesystems[t.searchPath] = t.filesystem }
            mediaTechs[t.searchPath] = t.mediaTech.rawValue
            if let y = t.purchaseYear { purchaseYears[t.searchPath] = y }
            if let c = t.capacityTB { capacities[t.searchPath] = c }
            if !t.notes.isEmpty { notesMap[t.searchPath] = t.notes }
            // §1B Retire — only write entries for retired volumes. Absence
            // is the not-retired signal (parallel to how purchase year and
            // notes are handled above).
            if let r = t.retiredAt { retiredAtMap[t.searchPath] = r }
            if let r = t.retiredReason, !r.isEmpty { retiredReasonMap[t.searchPath] = r }
            if let w = t.retiredWitnesses, !w.isEmpty { retiredWitnessesMap[t.searchPath] = w }
        }
        UserDefaults.standard.set(dates, forKey: savedDatesKey)
        UserDefaults.standard.set(phases, forKey: savedPhasesKey)
        UserDefaults.standard.set(roles, forKey: savedRolesKey)
        UserDefaults.standard.set(trusts, forKey: savedTrustKey)
        UserDefaults.standard.set(filesystems, forKey: savedFilesystemKey)
        UserDefaults.standard.set(mediaTechs, forKey: savedMediaTechKey)
        UserDefaults.standard.set(purchaseYears, forKey: savedPurchaseYearKey)
        UserDefaults.standard.set(capacities, forKey: savedCapacityKey)
        UserDefaults.standard.set(notesMap, forKey: savedNotesKey)
        UserDefaults.standard.set(retiredAtMap, forKey: savedRetiredAtKey)
        UserDefaults.standard.set(retiredReasonMap, forKey: savedRetiredReasonKey)
        UserDefaults.standard.set(retiredWitnessesMap, forKey: savedRetiredWitnessesKey)
    }

    // MARK: - Volume Snapshot

    static func applyVolumeSnapshot(_ s: VolumeMetadataSnapshot, to t: CatalogScanTarget) {
        if let phase = VolumePhase(rawValue: s.phase) { t.phase = phase }
        if let trust = VolumeTrust(rawValue: s.trust) { t.trust = trust }
        if let tech = VolumeMediaTech(rawValue: s.mediaTech) { t.mediaTech = tech }
        t.filesystem = s.filesystem
        t.purchaseYear = s.purchaseYear
        t.capacityTB = s.capacityTB
        t.notes = s.notes
        if let d = s.lastScannedDate { t.lastScannedDate = d }
        // §1B Retire — apply from snapshot if the bundle carried these fields.
        // Legacy bundles (pre-§1B) decode with nil/nil/nil and leave the
        // target's existing retire state untouched.
        t.retiredAt = s.retiredAt
        t.retiredReason = s.retiredReason
        t.retiredWitnesses = s.retiredWitnesses
        // Role LAST and legacy-aware: a pre-taxonomy bundle carrying
        // role "Retired" (no stamp) becomes an unassigned target WITH a
        // stamp; "Long-Term Archive" becomes Offsite. Same rules as the
        // UserDefaults restore path — one decoder for both.
        applyPersistedRole(s.role, to: t)
    }
}
