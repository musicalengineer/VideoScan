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
        // Test hosts must never inherit the machine's REAL persisted scan
        // targets — the read-side mirror of the persist gates below.
        // Nightly 2026-07-05: M5/M1 defaults held "/" as a saved target, so
        // every test-created model restored it and the init backfill vacuumed
        // all prior fixture probes out of the shared per-process metadata
        // cache (foreign records → ScanMergeMoveIdentityTests count failures),
        // plus a ~1.3–2.3 s per-test reachability stall over 20+ stale
        // targets. Restore LOGIC stays covered by PhaseConsistencyTests via
        // ScanTargetPersistence.restore with per-test unique keys.
        if Self.isRunningTests {
            // Gauntlet UI tests inject a fixture folder here instead
            // (transient launch-arg seam — see GauntletSeams.swift).
            installGauntletScanTargetIfRequested()
            return
        }
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
            savedNotesKey: Self.savedNotesKey,
            savedRetiredAtKey: Self.savedRetiredAtKey,
            savedRetiredReasonKey: Self.savedRetiredReasonKey,
            savedRetiredWitnessesKey: Self.savedRetiredWitnessesKey
        )
        scanTargets.append(contentsOf: restored)

        // One-time heal for pre-fix pollution: if the persisted path list
        // still carries RAM-disk scratch entries (ScanTargetPersistence
        // .restore screens them out of `restored`), rewrite it without
        // them now rather than waiting for the next incidental persist.
        let savedPaths = UserDefaults.standard.stringArray(forKey: Self.savedTargetsKey) ?? []
        if savedPaths.contains(where: { CatalogScanTarget.isScratchVolumePath($0) }) {
            log("Removed the RAM-disk scratch volume from the saved scan-target list (one-time cleanup).")
            persistScanTargets()
        }
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
            savedNotesKey: Self.savedNotesKey,
            savedRetiredAtKey: Self.savedRetiredAtKey,
            savedRetiredReasonKey: Self.savedRetiredReasonKey,
            savedRetiredWitnessesKey: Self.savedRetiredWitnessesKey
        )
    }

    // MARK: - Phase Consistency

    /// If a target claims "Cataloged" but has zero records, the catalog was
    /// deleted or lost — reset to NO CATALOG so the UI doesn't lie.
    func enforcePhaseConsistency() {
        for t in scanTargets where t.phase == .cataloged {
            let hasRecords = records.contains { PathScope.contains($0.fullPath, within: t.searchPath) } // regression: codex C2
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
            if records.contains(where: { PathScope.contains($0.fullPath, within: t.searchPath) }) { // regression: codex C2
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
