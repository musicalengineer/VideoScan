import Foundation

/// Persistence helpers for CatalogScanTarget metadata (phase, role, trust,
/// filesystem, purchaseYear, capacityTB, notes, lastScannedDate).
/// All data stored in UserDefaults using the provided key prefix.
@MainActor enum ScanTargetPersistence {

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
        savedNotesKey: String
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

        var result: [CatalogScanTarget] = []
        for p in paths where !p.isEmpty {
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
                if let raw = roles[p], let role = VolumeRole(rawValue: raw) {
                    t.role = role
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
        savedNotesKey: String
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
    }

    // MARK: - Volume Snapshot

    static func applyVolumeSnapshot(_ s: VolumeMetadataSnapshot, to t: CatalogScanTarget) {
        if let phase = VolumePhase(rawValue: s.phase) { t.phase = phase }
        if let role = VolumeRole(rawValue: s.role) { t.role = role }
        if let trust = VolumeTrust(rawValue: s.trust) { t.trust = trust }
        if let tech = VolumeMediaTech(rawValue: s.mediaTech) { t.mediaTech = tech }
        t.filesystem = s.filesystem
        t.purchaseYear = s.purchaseYear
        t.capacityTB = s.capacityTB
        t.notes = s.notes
        if let d = s.lastScannedDate { t.lastScannedDate = d }
    }
}
