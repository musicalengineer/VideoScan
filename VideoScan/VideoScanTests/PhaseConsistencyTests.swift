import Testing
import Foundation
@testable import VideoScan

@Suite("Phase Consistency")
@MainActor
struct PhaseConsistencyTests {

    // MARK: - enforcePhaseConsistency

    @Test func catalogedTargetWithRecordsStaysCataloged() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let target = CatalogScanTarget(searchPath: "/Volumes/TestVol")
        target.phase = .cataloged
        model.scanTargets = [target]

        let rec = VideoRecord()
        rec.fullPath = "/Volumes/TestVol/clip.mov"
        model.records.append(rec)
        model.enforcePhaseConsistency()

        #expect(target.phase == .cataloged)
    }

    @Test func catalogedTargetWithNoRecordsResetsToNoCatalog() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let target = CatalogScanTarget(searchPath: "/Volumes/EmptyVol")
        target.phase = .cataloged
        target.lastScannedDate = Date()
        model.scanTargets = [target]

        model.enforcePhaseConsistency()

        #expect(target.phase == .noCatalog)
        #expect(target.lastScannedDate == nil)
    }

    @Test func noCatalogTargetUntouchedByConsistencyCheck() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let target = CatalogScanTarget(searchPath: "/Volumes/NeverScanned")
        target.phase = .noCatalog
        model.scanTargets = [target]

        model.enforcePhaseConsistency()

        #expect(target.phase == .noCatalog)
    }

    @Test func multipleTargetsMixedState() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let hasData = CatalogScanTarget(searchPath: "/Volumes/HasData")
        hasData.phase = .cataloged
        let noData = CatalogScanTarget(searchPath: "/Volumes/NoData")
        noData.phase = .cataloged

        let rec = VideoRecord()
        rec.fullPath = "/Volumes/HasData/video.mxf"

        model.scanTargets = [hasData, noData]
        model.records.append(rec)
        model.enforcePhaseConsistency()

        #expect(hasData.phase == .cataloged)
        #expect(noData.phase == .noCatalog)
    }

    // MARK: - repairCorruptedPhases

    @Test func repairsNoCatalogWhenRecordsExist() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let target = CatalogScanTarget(searchPath: "/Volumes/Corrupted")
        target.phase = .noCatalog
        let rec = VideoRecord()
        rec.fullPath = "/Volumes/Corrupted/family.mov"

        model.scanTargets = [target]
        model.records.append(rec)

        let repaired = model.repairCorruptedPhases()

        #expect(repaired == 1)
        #expect(target.phase == .cataloged)
    }

    @Test func doesNotRepairWhenNoRecords() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let target = CatalogScanTarget(searchPath: "/Volumes/TrulyEmpty")
        target.phase = .noCatalog

        model.scanTargets = [target]

        let repaired = model.repairCorruptedPhases()

        #expect(repaired == 0)
        #expect(target.phase == .noCatalog)
    }

    @Test func repairsMultipleCorruptedTargets() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let vol1 = CatalogScanTarget(searchPath: "/Volumes/Vol1")
        vol1.phase = .noCatalog
        let vol2 = CatalogScanTarget(searchPath: "/Volumes/Vol2")
        vol2.phase = .noCatalog
        let vol3 = CatalogScanTarget(searchPath: "/Volumes/Vol3")
        vol3.phase = .noCatalog

        let rec1 = VideoRecord(); rec1.fullPath = "/Volumes/Vol1/a.mov"
        let rec2 = VideoRecord(); rec2.fullPath = "/Volumes/Vol2/b.mov"

        model.scanTargets = [vol1, vol2, vol3]
        model.records.append(contentsOf: [rec1, rec2])

        let repaired = model.repairCorruptedPhases()

        #expect(repaired == 2)
        #expect(vol1.phase == .cataloged)
        #expect(vol2.phase == .cataloged)
        #expect(vol3.phase == .noCatalog)
    }

    @Test func skipsEmptySearchPath() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let target = CatalogScanTarget(searchPath: "")
        target.phase = .noCatalog
        let rec = VideoRecord(); rec.fullPath = "/Volumes/X/a.mov"

        model.scanTargets = [target]
        model.records.append(rec)

        let repaired = model.repairCorruptedPhases()

        #expect(repaired == 0)
        #expect(target.phase == .noCatalog)
    }

    @Test func leavesAlreadyCatalogedTargetAlone() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let target = CatalogScanTarget(searchPath: "/Volumes/Good")
        target.phase = .cataloged
        let rec = VideoRecord(); rec.fullPath = "/Volumes/Good/a.mov"

        model.scanTargets = [target]
        model.records.append(rec)

        let repaired = model.repairCorruptedPhases()

        #expect(repaired == 0)
        #expect(target.phase == .cataloged)
    }

    @Test func returnsZeroWhenRecordsArrayEmpty() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let target = CatalogScanTarget(searchPath: "/Volumes/X")
        target.phase = .noCatalog
        model.scanTargets = [target]

        let repaired = model.repairCorruptedPhases()

        #expect(repaired == 0)
    }

    // MARK: - Full corruption → repair round-trip

    @Test func consistencyThenRepairSimulatesTestCorruption() {
        let model = VideoScanModel()
        // Isolate: clear any targets restored from the real UserDefaults
        model.scanTargets.removeAll()

        let target = CatalogScanTarget(searchPath: "/Volumes/FamilyMedia")
        target.phase = .cataloged
        let rec = VideoRecord(); rec.fullPath = "/Volumes/FamilyMedia/donna_1998.mov"

        model.scanTargets.append(target)
        model.records.append(rec)

        // Step 1: simulate what happens when load() returns [] during tests —
        // the consistency check sees .cataloged with no records and resets.
        let saved = model.records
        model.records = []
        model.enforcePhaseConsistency()
        #expect(target.phase == .noCatalog)

        // Step 2: restore records (simulating a subsequent normal launch
        // that loads catalog.json successfully)
        model.records = saved

        // Step 3: auto-repair detects the mismatch and fixes it.
        let repaired = model.repairCorruptedPhases()
        #expect(repaired == 1)
        #expect(target.phase == .cataloged)
    }
    // MARK: - Isolation verification

    @Test func freshModelHasNoTestInterferenceOnRepair() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        model.records = []
        let repaired = model.repairCorruptedPhases()
        #expect(repaired == 0)
    }

    // regression: codex C2 — phase repair must scope on a component boundary.
    // Previously this documented a defect: "/Volumes/Volume99/a.mov" was
    // treated as living under "/Volumes/Vol" via raw hasPrefix, so the
    // unrelated "/Volumes/Vol" target got falsely repaired to .cataloged.
    // PathScope.contains rejects the sibling-prefix match, so no repair
    // happens — assert the corrected behavior.
    @Test func repairIgnoresSiblingPrefixNotComponentBoundary() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let target = CatalogScanTarget(searchPath: "/Volumes/Vol")
        target.phase = .noCatalog
        let rec = VideoRecord(); rec.fullPath = "/Volumes/Volume99/a.mov"
        model.scanTargets = [target]
        model.records = [rec]
        let repaired = model.repairCorruptedPhases()
        // "/Volumes/Volume99/a.mov" is NOT under "/Volumes/Vol" — different
        // volumes that merely share a name prefix. No phase should change.
        #expect(repaired == 0)
        #expect(target.phase == .noCatalog)
    }

    @Test func repairHandlesSlashTerminatedSearchPath() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let target = CatalogScanTarget(searchPath: "/Volumes/Media/")
        target.phase = .noCatalog
        let rec = VideoRecord(); rec.fullPath = "/Volumes/Media/clip.mov"
        model.scanTargets = [target]
        model.records = [rec]
        let repaired = model.repairCorruptedPhases()
        #expect(repaired == 1)
        #expect(target.phase == .cataloged)
    }

    @Test func enforceDoesNotCorruptPhasesWithRealTargetsCleared() {
        let model = VideoScanModel()
        model.scanTargets.removeAll()
        let target = CatalogScanTarget(searchPath: "/Volumes/Safe")
        target.phase = .cataloged
        let rec = VideoRecord(); rec.fullPath = "/Volumes/Safe/video.mp4"
        model.scanTargets = [target]
        model.records = [rec]
        model.enforcePhaseConsistency()
        #expect(target.phase == .cataloged)
    }
}

// MARK: - ScanTargetPersistence Round-Trip Tests

@Suite("ScanTarget Persistence")
@MainActor
struct ScanTargetPersistenceTests {

    // §1B Retire Volume — three additional dictionary keys (retAt, retRsn,
    // retWit). Tuple grew but all existing callsites at the bottom of this
    // suite get a paired update below.
    private func makeTestKeys() -> (paths: String, dates: String, phases: String,
                                     roles: String, trust: String, fs: String,
                                     mt: String, py: String, cap: String, notes: String,
                                     retAt: String, retRsn: String, retWit: String) {
        let id = UUID().uuidString.prefix(8)
        return ("t\(id)_p", "t\(id)_d", "t\(id)_ph", "t\(id)_r",
                "t\(id)_tr", "t\(id)_f", "t\(id)_m", "t\(id)_py",
                "t\(id)_c", "t\(id)_n",
                "t\(id)_rA", "t\(id)_rR", "t\(id)_rW")
    }

    private func cleanupKeys(_ k: (paths: String, dates: String, phases: String,
                                    roles: String, trust: String, fs: String,
                                    mt: String, py: String, cap: String, notes: String,
                                    retAt: String, retRsn: String, retWit: String)) {
        for key in [k.paths, k.dates, k.phases, k.roles, k.trust,
                    k.fs, k.mt, k.py, k.cap, k.notes,
                    k.retAt, k.retRsn, k.retWit] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test func roundTripPreservesPhases() {
        let k = makeTestKeys()
        defer { cleanupKeys(k) }

        let t1 = CatalogScanTarget(searchPath: "/Volumes/Alpha")
        t1.phase = .cataloged
        let t2 = CatalogScanTarget(searchPath: "/Volumes/Beta")
        t2.phase = .noCatalog

        ScanTargetPersistence.persistPaths([t1, t2], key: k.paths)
        ScanTargetPersistence.persistMetadata(
            [t1, t2],
            savedDatesKey: k.dates, savedPhasesKey: k.phases,
            savedRolesKey: k.roles, savedTrustKey: k.trust,
            savedFilesystemKey: k.fs, savedMediaTechKey: k.mt,
            savedPurchaseYearKey: k.py, savedCapacityKey: k.cap,
            savedNotesKey: k.notes,
            savedRetiredAtKey: k.retAt,
            savedRetiredReasonKey: k.retRsn,
            savedRetiredWitnessesKey: k.retWit
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

        #expect(restored.count == 2)
        let alpha = restored.first { $0.searchPath == "/Volumes/Alpha" }
        let beta = restored.first { $0.searchPath == "/Volumes/Beta" }
        #expect(alpha?.phase == .cataloged)
        #expect(beta?.phase == .noCatalog)
    }

    @Test func restoreSkipsExistingTargets() {
        let k = makeTestKeys()
        defer { cleanupKeys(k) }

        let existing = CatalogScanTarget(searchPath: "/Volumes/Existing")
        let t = CatalogScanTarget(searchPath: "/Volumes/Existing")
        t.phase = .cataloged

        ScanTargetPersistence.persistPaths([t], key: k.paths)
        ScanTargetPersistence.persistMetadata(
            [t],
            savedDatesKey: k.dates, savedPhasesKey: k.phases,
            savedRolesKey: k.roles, savedTrustKey: k.trust,
            savedFilesystemKey: k.fs, savedMediaTechKey: k.mt,
            savedPurchaseYearKey: k.py, savedCapacityKey: k.cap,
            savedNotesKey: k.notes,
            savedRetiredAtKey: k.retAt,
            savedRetiredReasonKey: k.retRsn,
            savedRetiredWitnessesKey: k.retWit
        )

        let restored = ScanTargetPersistence.restore(
            existing: [existing],
            savedTargetsKey: k.paths, savedDatesKey: k.dates,
            savedPhasesKey: k.phases, savedRolesKey: k.roles,
            savedTrustKey: k.trust, savedFilesystemKey: k.fs,
            savedMediaTechKey: k.mt, savedPurchaseYearKey: k.py,
            savedCapacityKey: k.cap, savedNotesKey: k.notes,
            savedRetiredAtKey: k.retAt,
            savedRetiredReasonKey: k.retRsn,
            savedRetiredWitnessesKey: k.retWit
        )

        #expect(restored.isEmpty)
    }
}
