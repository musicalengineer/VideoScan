import Foundation

// MARK: - Scan Target Persistence + Phase Consistency
//
// Restore/persist scan targets to UserDefaults via ScanTargetPersistence,
// repair phase corruption from older builds, and provide the per-field
// setters that fire `notifyTargetsChanged` + persist on every mutation.
//
// The persisted-key constants and `isRunningTests` test-guard stay in the
// main class — extensions can't add new stored properties (including
// static ones in some Swift versions); keeping them next to the @Published
// `scanTargets` array is also clearer.

extension VideoScanModel {

    func restoreScanTargets() {
        let restored = ScanTargetPersistence.restore(
            existing: scanTargets,
            savedTargetsKey: Self.savedTargetsKey,
            savedDatesKey: Self.savedDatesKey,
            savedPhasesKey: Self.savedPhasesKey,
            savedRolesKey: Self.savedRolesKey,
            savedTrustKey: Self.savedTrustKey,
            savedFilesystemKey: Self.savedFilesystemKey,
            savedMediaTechKey: Self.savedMediaTechKey,
            savedPurchaseYearKey: Self.savedPurchaseYearKey,
            savedCapacityKey: Self.savedCapacityKey,
            savedNotesKey: Self.savedNotesKey
        )
        scanTargets.append(contentsOf: restored)
    }

    func persistScanTargets() {
        if Self.isRunningTests { return }
        ScanTargetPersistence.persistPaths(scanTargets, key: Self.savedTargetsKey)
    }

    func persistScanDates() {
        if Self.isRunningTests { return }
        ScanTargetPersistence.persistMetadata(
            scanTargets,
            savedDatesKey: Self.savedDatesKey,
            savedPhasesKey: Self.savedPhasesKey,
            savedRolesKey: Self.savedRolesKey,
            savedTrustKey: Self.savedTrustKey,
            savedFilesystemKey: Self.savedFilesystemKey,
            savedMediaTechKey: Self.savedMediaTechKey,
            savedPurchaseYearKey: Self.savedPurchaseYearKey,
            savedCapacityKey: Self.savedCapacityKey,
            savedNotesKey: Self.savedNotesKey
        )
    }

    // MARK: - Phase Consistency

    /// If a target claims "Cataloged" but has zero records, the catalog was
    /// deleted or lost — reset to NO CATALOG so the UI doesn't lie.
    func enforcePhaseConsistency() {
        for t in scanTargets where t.phase == .cataloged {
            let hasRecords = records.contains { $0.fullPath.hasPrefix(t.searchPath) }
            if !hasRecords {
                t.phase = .noCatalog
                t.lastScannedDate = nil
            }
        }
    }

    /// If a target shows noCatalog but we have records for it, a previous
    /// test run (or crash) corrupted the persisted phase. Re-derive the
    /// phase from actual catalog data. Returns number of targets repaired.
    @discardableResult
    func repairCorruptedPhases() -> Int {
        guard !records.isEmpty else { return 0 }
        var repaired = 0
        for t in scanTargets where t.phase == .noCatalog && !t.searchPath.isEmpty {
            if records.contains(where: { $0.fullPath.hasPrefix(t.searchPath) }) {
                t.phase = .cataloged
                repaired += 1
            }
        }
        if repaired > 0 {
            log("Repaired \(repaired) volume phase(s) — catalog data exists but phases were reset.")
            persistScanDates()
        }
        return repaired
    }

    /// Update a volume's lifecycle phase and persist.
    func setPhase(_ phase: VolumePhase, for target: CatalogScanTarget) {
        target.phase = phase
        persistScanDates()
        notifyTargetsChanged()
    }

    func setRole(_ role: VolumeRole, for target: CatalogScanTarget) {
        target.role = role
        persistScanDates()
        notifyTargetsChanged()
    }

    func setTrust(_ trust: VolumeTrust, for target: CatalogScanTarget) {
        target.trust = trust
        persistScanDates()
        notifyTargetsChanged()
    }

    func setFilesystem(_ value: String, for target: CatalogScanTarget) {
        target.filesystem = value
        persistScanDates()
        notifyTargetsChanged()
    }

    func setMediaTech(_ value: VolumeMediaTech, for target: CatalogScanTarget) {
        target.mediaTech = value
        persistScanDates()
        notifyTargetsChanged()
    }

    func setPurchaseYear(_ value: Int?, for target: CatalogScanTarget) {
        target.purchaseYear = value
        persistScanDates()
        notifyTargetsChanged()
    }

    func setCapacityTB(_ value: Double?, for target: CatalogScanTarget) {
        target.capacityTB = value
        persistScanDates()
        notifyTargetsChanged()
    }

    func setNotes(_ value: String, for target: CatalogScanTarget) {
        target.notes = value
        persistScanDates()
        notifyTargetsChanged()
    }
}
