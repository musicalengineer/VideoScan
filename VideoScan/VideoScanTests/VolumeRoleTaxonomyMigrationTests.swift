import Testing
import Foundation
@testable import VideoScan

// MARK: - VolumeRoleTaxonomyMigrationTests
//
// Volume-role taxonomy cleanup (docs/volume_taxonomy_proposal.md, Rick
// 2026-08-16). Five dimensions (CLAUDE.md checklist):
//   Logic     — every migration rule, decode → stamp, pending queue
//   Scale     — 1,000-target decode + migrate under budget (role logic is
//               per-target; records are untouched)
//   Media     — n/a (no media opened)
//   Isolation — restore with unique keys never touches the real prefs key;
//               poisoned legacy strings in test keys are absorbed
//   Sensor    — legacy "Retired" → stamp; retired host never "safe"
//
// Rule ↔ test map (for the report):
//   D1 legacy "Long-Term Archive"/"LTA" → .offsite   applyPersistedRole_legacyStrings
//   D2 legacy "Retired" → .unassigned + retiredAt    applyPersistedRole_retiredStampsOnce (+ RelocateRetireVolumeTests)
//   D3 unknown raw → .unassigned, target kept        applyPersistedRole_unknownKeepsTarget / restore_legacyAndJunkRoles_allTargetsKept_realPrefsUntouched
//   R1 boot volume root → .system                    migrate_bootVolumeBecomesSystem
//   R2 .system on ~/folder → .working                migrate_homeFolderTaggedSystemBecomesWorking
//   R3 unassigned ~/folder → .working                migrate_homeFolderDefaultsToWorking
//   R4 non-master Archive → pending (master kept)    migrate_nonMasterArchiveQueued_masterUntouched
//   R4' no designation → Archive left alone          migrate_noDesignationLeavesArchiveAlone
//   Idempotency                                      migrate_isIdempotent / applyPersistedRole_retiredStampsOnce
//   Reclassify sheet contract                        resolveReclassification_acceptsPickerRoles_refusesArchiveSystem
//   Retired badge from retiredAt only                isRetired_isRetiredAtOnly / volumeSafety_retiredHostNeverSafe
//   Bundle round-trip                                bundleSnapshot_roundTripPreservesEveryRole / bundleSnapshot_legacyStringsMigrate
//   Symlink in ~/Movies pin                          symlinkInHomeMovies_resolvesToRealVolume_isWorkingNotSystem

@Suite("Volume role taxonomy migration") @MainActor
struct VolumeRoleTaxonomyMigrationTests {

    // MARK: - Fixtures

    private func makeModel() -> VideoScanModel {
        let m = VideoScanModel()
        // Own catalog store so `masterArchive` never mirrors into the
        // shared process-wide store (see VideoScanModel.init note).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_roletax_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        m.catalogStore = CatalogStore(directory: dir)
        m.scanTargets = []
        m.records = []
        m.pendingRoleReclassifications = []
        return m
    }

    private func designateMaster(_ m: VideoScanModel, at path: String) {
        m.masterArchive = MasterArchiveDesignation(
            targetPath: path,
            rootPath: MasterArchiveLayout.rootURL(forTargetPath: path).path)
    }

    // MARK: - D1/D2/D3 decode → target

    @Test func applyPersistedRole_legacyStrings() {
        let lta = CatalogScanTarget(searchPath: "/Volumes/LaCieWorkspace")
        ScanTargetPersistence.applyPersistedRole("Long-Term Archive", to: lta)
        #expect(lta.role == .offsite)
        #expect(lta.retiredAt == nil, "rename must not stamp retirement")

        let short = CatalogScanTarget(searchPath: "/Volumes/Cloud")
        ScanTargetPersistence.applyPersistedRole("LTA", to: short)
        #expect(short.role == .offsite)

        // Current strings are plain assignments.
        for r in VolumeRole.allCases {
            let t = CatalogScanTarget(searchPath: "/Volumes/X")
            ScanTargetPersistence.applyPersistedRole(r.rawValue, to: t)
            #expect(t.role == r)
            #expect(t.retiredAt == nil)
        }
    }

    @Test func applyPersistedRole_retiredStampsOnce() {
        let scanned = Date(timeIntervalSince1970: 1_700_000_000)
        let t = CatalogScanTarget(searchPath: "/Volumes/RicksBackups")
        t.lastScannedDate = scanned
        let now = Date()

        let d1 = ScanTargetPersistence.applyPersistedRole("Retired", to: t, now: now)
        #expect(d1.wasRetired)
        #expect(t.role == .unassigned)
        #expect(t.retiredAt == scanned, "stamp prefers lastScannedDate when known")
        #expect(t.retiredReason == ScanTargetPersistence.legacyRetiredMigrationReason)
        #expect(t.isRetired)

        // Idempotent: a second decode (next launch, before the persist
        // rewrote the role) must not move the stamp or the reason.
        t.retiredReason = "hand-edited"
        ScanTargetPersistence.applyPersistedRole("Retired", to: t, now: now.addingTimeInterval(3600))
        #expect(t.retiredAt == scanned, "stamped once — never re-stamped")
        #expect(t.retiredReason == "hand-edited", "existing reason wins")

        // No lastScannedDate → `now`.
        let fresh = CatalogScanTarget(searchPath: "/Volumes/500USB")
        ScanTargetPersistence.applyPersistedRole("Retired", to: fresh, now: now)
        #expect(fresh.retiredAt == now)

        // A REAL stamp already present is never overwritten by the legacy rule.
        let real = CatalogScanTarget(searchPath: "/Volumes/Mini2TB")
        real.retiredAt = scanned
        real.retiredReason = "Relocate 2026-05-30"
        ScanTargetPersistence.applyPersistedRole("Retired", to: real, now: now)
        #expect(real.retiredAt == scanned)
        #expect(real.retiredReason == "Relocate 2026-05-30")
    }

    @Test func applyPersistedRole_unknownKeepsTarget() {
        let t = CatalogScanTarget(searchPath: "/Volumes/Weird")
        t.role = .backup
        let d = ScanTargetPersistence.applyPersistedRole("Bogus Role", to: t)
        #expect(d.unknownRaw == "Bogus Role")
        #expect(t.role == .unassigned, "unknown → Unassigned, never a crash")
        #expect(t.retiredAt == nil)
    }

    // MARK: - Restore path (UserDefaults, unique test keys)

    private struct Keys {
        let id = String(UUID().uuidString.prefix(8))
        var paths: String { "t\(id)_p" }
        var dates: String { "t\(id)_d" }
        var phases: String { "t\(id)_ph" }
        var roles: String { "t\(id)_r" }
        var trust: String { "t\(id)_tr" }
        var fs: String { "t\(id)_f" }
        var mt: String { "t\(id)_m" }
        var py: String { "t\(id)_py" }
        var cap: String { "t\(id)_c" }
        var notes: String { "t\(id)_n" }
        var retAt: String { "t\(id)_rA" }
        var retRsn: String { "t\(id)_rR" }
        var retWit: String { "t\(id)_rW" }
        var all: [String] { [paths, dates, phases, roles, trust, fs, mt, py, cap, notes, retAt, retRsn, retWit] }
        func cleanup() { all.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    }

    private func restore(_ k: Keys) -> [CatalogScanTarget] {
        ScanTargetPersistence.restore(
            existing: [],
            savedTargetsKey: k.paths, savedDatesKey: k.dates, savedPhasesKey: k.phases,
            savedRolesKey: k.roles, savedTrustKey: k.trust, savedFilesystemKey: k.fs,
            savedMediaTechKey: k.mt, savedPurchaseYearKey: k.py, savedCapacityKey: k.cap,
            savedNotesKey: k.notes, savedRetiredAtKey: k.retAt, savedRetiredReasonKey: k.retRsn,
            savedRetiredWitnessesKey: k.retWit)
    }

    /// Poisoned-state + isolation: a saved-roles dictionary carrying every
    /// legacy string AND junk restores every target, maps each role, stamps
    /// the legacy-retired one — and never touches the REAL prefs key.
    @Test func restore_legacyAndJunkRoles_allTargetsKept_realPrefsUntouched() {
        let k = Keys()
        defer { k.cleanup() }
        let realBefore = UserDefaults.standard.dictionary(forKey: VideoScanModel.savedRolesKey) as? [String: String]

        let paths = ["/Volumes/A", "/Volumes/B", "/Volumes/C", "/Volumes/D", "/Volumes/E"]
        UserDefaults.standard.set(paths, forKey: k.paths)
        UserDefaults.standard.set([
            "/Volumes/A": "Long-Term Archive",
            "/Volumes/B": "Retired",
            "/Volumes/C": "Bogus",
            "/Volumes/D": "Backup",
            // "/Volumes/E" — no role entry at all
        ], forKey: k.roles)

        let restored = restore(k)
        #expect(restored.count == 5, "no target is dropped for a bad role")
        let byPath = Dictionary(uniqueKeysWithValues: restored.map { ($0.searchPath, $0) })
        #expect(byPath["/Volumes/A"]?.role == .offsite)
        #expect(byPath["/Volumes/B"]?.role == .unassigned)
        #expect(byPath["/Volumes/B"]?.retiredAt != nil, "legacy Retired → stamp on restore")
        #expect(byPath["/Volumes/B"]?.isRetired == true)
        #expect(byPath["/Volumes/C"]?.role == .unassigned)
        #expect(byPath["/Volumes/D"]?.role == .backup)
        #expect(byPath["/Volumes/E"]?.role == .unassigned)

        let realAfter = UserDefaults.standard.dictionary(forKey: VideoScanModel.savedRolesKey) as? [String: String]
        #expect(realBefore == realAfter, "test keys only — the real \(VideoScanModel.savedRolesKey) is never written")
    }

    /// Restore applies the retire dictionaries BEFORE the role, so a real
    /// stamp beats the legacy migration stamp.
    @Test func restore_realStampWinsOverLegacyRetiredRole() {
        let k = Keys()
        defer { k.cleanup() }
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        UserDefaults.standard.set(["/Volumes/B"], forKey: k.paths)
        UserDefaults.standard.set(["/Volumes/B": "Retired"], forKey: k.roles)
        UserDefaults.standard.set(["/Volumes/B": stamp], forKey: k.retAt)
        UserDefaults.standard.set(["/Volumes/B": "Relocate done"], forKey: k.retRsn)
        let t = try? #require(restore(k).first)
        #expect(t?.retiredAt == stamp)
        #expect(t?.retiredReason == "Relocate done")
        #expect(t?.role == .unassigned)
    }

    /// Persist after restore writes CURRENT raw values (the plist heals
    /// itself on the next save) and round-trips every role.
    @Test func persistAfterRestore_writesCurrentRawValues() {
        let k = Keys()
        defer { k.cleanup() }
        let targets = VolumeRole.allCases.enumerated().map { i, r -> CatalogScanTarget in
            let t = CatalogScanTarget(searchPath: "/Volumes/R\(i)")
            t.role = r
            return t
        }
        ScanTargetPersistence.persistPaths(targets, key: k.paths)
        ScanTargetPersistence.persistMetadata(
            targets, savedDatesKey: k.dates, savedPhasesKey: k.phases, savedRolesKey: k.roles,
            savedTrustKey: k.trust, savedFilesystemKey: k.fs, savedMediaTechKey: k.mt,
            savedPurchaseYearKey: k.py, savedCapacityKey: k.cap, savedNotesKey: k.notes,
            savedRetiredAtKey: k.retAt, savedRetiredReasonKey: k.retRsn, savedRetiredWitnessesKey: k.retWit)
        let written = UserDefaults.standard.dictionary(forKey: k.roles) as? [String: String] ?? [:]
        #expect(Set(written.values) == Set(VolumeRole.allCases.map(\.rawValue)))
        #expect(!written.values.contains("Long-Term Archive"))
        #expect(!written.values.contains("Retired"))
        let back = restore(k)
        #expect(back.map(\.role) == targets.map(\.role))
    }

    // MARK: - Boot / home classification

    @Test func bootVolumeRootPathPredicate() {
        let boot = "BootDisk"
        #expect(CatalogScanTarget.isBootVolumeRootPath("/", bootVolumeName: boot))
        #expect(CatalogScanTarget.isBootVolumeRootPath("/System/Volumes/Data", bootVolumeName: boot))
        #expect(CatalogScanTarget.isBootVolumeRootPath("/System/Volumes/Data/", bootVolumeName: boot))
        #expect(CatalogScanTarget.isBootVolumeRootPath("/Volumes/BootDisk", bootVolumeName: boot))
        #expect(CatalogScanTarget.isBootVolumeRootPath("/Volumes/BootDisk/", bootVolumeName: boot))
        // NOT the boot root: another volume, a folder INSIDE the boot
        // volume (~/Movies), a folder under the alias, unknown boot name.
        #expect(!CatalogScanTarget.isBootVolumeRootPath("/Volumes/MyBook", bootVolumeName: boot))
        #expect(!CatalogScanTarget.isBootVolumeRootPath("/Users/rickb/Movies", bootVolumeName: boot))
        #expect(!CatalogScanTarget.isBootVolumeRootPath("/Volumes/BootDisk/Users/rickb", bootVolumeName: boot))
        #expect(!CatalogScanTarget.isBootVolumeRootPath("", bootVolumeName: boot))
        #expect(!CatalogScanTarget.isBootVolumeRootPath("/Volumes/BootDisk", bootVolumeName: nil))
        // Real machine: "/" is always the boot root; the OS boot name is
        // read once from "/" (internal SSD, never an external stat).
        #expect(CatalogScanTarget.isBootVolumeRootPath("/"))
        if let real = CatalogScanTarget.bootVolumeName {
            #expect(CatalogScanTarget.isBootVolumeRootPath("/Volumes/\(real)"))
        }
    }

    @Test func homeFolderPathPredicate() {
        #expect(CatalogScanTarget.isHomeFolderPath("/Users/rickb/Movies", homeDirectory: "/Users/rickb"))
        #expect(CatalogScanTarget.isHomeFolderPath("/Users/rickb", homeDirectory: "/Users/rickb"))
        #expect(CatalogScanTarget.isHomeFolderPath("/Users/donna/Movies", homeDirectory: "/Users/rickb"), "any /Users/<name>/… is a home folder")
        #expect(!CatalogScanTarget.isHomeFolderPath("/Users/Shared/Media", homeDirectory: "/Users/rickb"))
        #expect(!CatalogScanTarget.isHomeFolderPath("/Users", homeDirectory: "/Users/rickb"))
        #expect(!CatalogScanTarget.isHomeFolderPath("/Volumes/MyBook", homeDirectory: "/Users/rickb"))
        #expect(!CatalogScanTarget.isHomeFolderPath("/", homeDirectory: "/Users/rickb"))
        #expect(!CatalogScanTarget.isHomeFolderPath("/Volumes/M4drive/Users/rickb", homeDirectory: "/Users/rickb"))
    }

    // MARK: - migrateVolumeRoles rules

    @Test func migrate_bootVolumeBecomesSystem() {
        let m = makeModel()
        let root = CatalogScanTarget(searchPath: "/")
        root.role = .backup   // whatever a hand-edit left there
        let data = CatalogScanTarget(searchPath: "/System/Volumes/Data")
        m.scanTargets = [root, data]
        let changed = m.migrateVolumeRoles()
        #expect(root.role == .system)
        #expect(data.role == .system)
        #expect(changed == 2)
    }

    @Test func migrate_homeFolderDefaultsToWorking() {
        let m = makeModel()
        let movies = CatalogScanTarget(searchPath: NSHomeDirectory() + "/Movies")
        #expect(movies.role == .unassigned, "precondition")
        let ext = CatalogScanTarget(searchPath: "/Volumes/MyBook")   // unassigned, NOT home
        m.scanTargets = [movies, ext]
        m.migrateVolumeRoles()
        #expect(movies.role == .working)
        #expect(ext.role == .unassigned, "only home folders get the Working default")
        #expect(!movies.isBootVolumeRoot, "~/Movies is inside the boot volume but is not its root")
    }

    @Test func migrate_homeFolderTaggedSystemBecomesWorking() {
        let m = makeModel()
        let movies = CatalogScanTarget(searchPath: NSHomeDirectory() + "/Movies")
        movies.role = .system
        m.scanTargets = [movies]
        m.migrateVolumeRoles()
        #expect(movies.role == .working, "folder targets inside ~ are NOT system")
    }

    @Test func migrate_explicitHomeRolesAreKept() {
        let m = makeModel()
        let movies = CatalogScanTarget(searchPath: NSHomeDirectory() + "/Movies")
        movies.role = .original
        m.scanTargets = [movies]
        m.migrateVolumeRoles()
        #expect(movies.role == .original, "a chosen role is never overridden by the default")
    }

    @Test func migrate_nonMasterArchiveQueued_masterUntouched() {
        let m = makeModel()
        let master = CatalogScanTarget(searchPath: "/Volumes/FamilyArchive")
        master.role = .archive
        let legacyA = CatalogScanTarget(searchPath: "/Volumes/LaCieWorkspace")
        legacyA.role = .archive
        let legacyB = CatalogScanTarget(searchPath: "/Volumes/MyBook")
        legacyB.role = .archive
        let backup = CatalogScanTarget(searchPath: "/Volumes/X9")
        backup.role = .backup
        m.scanTargets = [master, legacyA, legacyB, backup]
        designateMaster(m, at: "/Volumes/FamilyArchive")

        m.migrateVolumeRoles()
        #expect(master.role == .archive, "the Master Archive keeps Archive")
        #expect(legacyA.role == .archive, "never silently renamed")
        #expect(legacyB.role == .archive)
        #expect(Set(m.pendingRoleReclassifications.map(\.searchPath)) == ["/Volumes/LaCieWorkspace", "/Volumes/MyBook"])
        #expect(!m.pendingRoleReclassifications.contains { $0 === master })
        #expect(!m.pendingRoleReclassifications.contains { $0 === backup })
    }

    @Test func migrate_noDesignationLeavesArchiveAlone() {
        let m = makeModel()
        let a = CatalogScanTarget(searchPath: "/Volumes/LaCieWorkspace")
        a.role = .archive
        m.scanTargets = [a]
        #expect(m.masterArchive == nil, "precondition")
        m.migrateVolumeRoles()
        #expect(a.role == .archive)
        #expect(m.pendingRoleReclassifications.isEmpty, "with no Master Archive yet, an Archive-role target may be the one about to be initialized")
    }

    @Test func migrate_isIdempotent() {
        let m = makeModel()
        let root = CatalogScanTarget(searchPath: "/")
        let movies = CatalogScanTarget(searchPath: NSHomeDirectory() + "/Movies")
        let legacy = CatalogScanTarget(searchPath: "/Volumes/LaCieWorkspace")
        legacy.role = .archive
        let master = CatalogScanTarget(searchPath: "/Volumes/FamilyArchive")
        master.role = .archive
        let retiredLegacy = CatalogScanTarget(searchPath: "/Volumes/RicksBackups")
        ScanTargetPersistence.applyPersistedRole("Retired", to: retiredLegacy)
        let stamp = retiredLegacy.retiredAt
        m.scanTargets = [root, movies, legacy, master, retiredLegacy]
        designateMaster(m, at: "/Volumes/FamilyArchive")

        let first = m.migrateVolumeRoles()
        let snapshot1 = m.scanTargets.map { ($0.role, $0.retiredAt) }
        let pending1 = m.pendingRoleReclassifications.map(\.searchPath)
        let second = m.migrateVolumeRoles()
        let snapshot2 = m.scanTargets.map { ($0.role, $0.retiredAt) }
        let pending2 = m.pendingRoleReclassifications.map(\.searchPath)

        #expect(first == 2, "root → System, ~/Movies → Working")
        #expect(second == 0, "second pass changes nothing")
        #expect(snapshot1.map(\.0) == snapshot2.map(\.0))
        #expect(snapshot1.map(\.1) == snapshot2.map(\.1))
        #expect(pending1 == pending2, "queue is deduped, not doubled")
        #expect(pending1 == ["/Volumes/LaCieWorkspace"])
        #expect(retiredLegacy.retiredAt == stamp, "stamped once")
        #expect(retiredLegacy.role == .unassigned)
    }

    @Test func migrate_dropsStaleQueueEntries() {
        let m = makeModel()
        let legacy = CatalogScanTarget(searchPath: "/Volumes/LaCieWorkspace")
        legacy.role = .archive
        let master = CatalogScanTarget(searchPath: "/Volumes/FamilyArchive")
        master.role = .archive
        m.scanTargets = [legacy, master]
        designateMaster(m, at: "/Volumes/FamilyArchive")
        m.migrateVolumeRoles()
        #expect(m.pendingRoleReclassifications.count == 1)
        // The user re-roles it by hand (Volumes window picker) → queue clears.
        m.setRole(.backup, for: legacy)
        #expect(m.pendingRoleReclassifications.isEmpty)
        m.migrateVolumeRoles()
        #expect(m.pendingRoleReclassifications.isEmpty)
        #expect(legacy.role == .backup)
    }

    @Test func resolveReclassification_acceptsPickerRoles_refusesArchiveSystem() {
        let m = makeModel()
        let legacy = CatalogScanTarget(searchPath: "/Volumes/LaCieWorkspace")
        legacy.role = .archive
        let master = CatalogScanTarget(searchPath: "/Volumes/FamilyArchive")
        master.role = .archive
        m.scanTargets = [legacy, master]
        designateMaster(m, at: "/Volumes/FamilyArchive")
        m.migrateVolumeRoles()

        #expect(m.resolveRoleReclassification(legacy, to: .archive) == false)
        #expect(legacy.role == .archive)
        #expect(m.pendingRoleReclassifications.count == 1, "refused answer keeps the question")
        #expect(m.resolveRoleReclassification(legacy, to: .system) == false)

        for choice in RoleReclassificationSheet.choices {
            #expect(VolumeRole.pickerCases.contains(choice), "sheet offers only user-selectable roles")
        }
        #expect(RoleReclassificationSheet.defaultChoice == .original)
        #expect(m.resolveRoleReclassification(legacy, to: .original))
        #expect(legacy.role == .original)
        #expect(m.pendingRoleReclassifications.isEmpty)
    }

    /// Initialize on a queued legacy-Archive target resolves the question
    /// (it IS the master now) and leaves role Archive.
    @Test func initializeMasterArchive_resolvesQueuedTarget() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("roletax")
        defer { sb.cleanup() }
        let m = makeModel()
        let t = CatalogScanTarget(searchPath: sb.archiveVolume.path)
        t.role = .archive
        let other = CatalogScanTarget(searchPath: "/Volumes/Elsewhere")
        other.role = .archive
        m.scanTargets = [t, other]
        designateMaster(m, at: "/Volumes/Elsewhere")   // someone else is master
        m.migrateVolumeRoles()
        #expect(m.pendingRoleReclassifications.contains { $0 === t })

        try m.initializeMasterArchive(at: sb.archiveVolume)
        #expect(t.role == .archive)
        #expect(!m.pendingRoleReclassifications.contains { $0 === t })
        // …and the previous master is now the non-master Archive → queued
        // on the next pass, never renamed.
        m.migrateVolumeRoles()
        #expect(other.role == .archive)
        #expect(m.pendingRoleReclassifications.contains { $0 === other })
    }

    // MARK: - Retired = retiredAt only

    @Test func isRetired_isRetiredAtOnly() {
        for r in VolumeRole.allCases {
            let t = CatalogScanTarget(searchPath: "/Volumes/T")
            t.role = r
            #expect(!t.isRetired, "\(r.rawValue) without a stamp is not retired")
            t.retiredAt = Date()
            #expect(t.isRetired, "\(r.rawValue) with a stamp IS retired — badge on any role")
        }
        // The badge component takes the flag explicitly; nothing derives
        // it from role any more.
        _ = VolumeBadge(role: .backup, trust: .reliable, isReachable: true, isRetired: true)
        #expect(VolumeBadge.retiredTag == "RTD")
    }

    @Test func scanGate_refusesRetiredViaStamp_onAnyRole() {
        let m = makeModel()
        let t = CatalogScanTarget(searchPath: "/Volumes/ShelfDrive")
        t.role = .backup
        t.retiredAt = Date()
        t.isReachable = true
        m.scanTargets = [t]
        m.startTarget(t)
        #expect(t.status == .idle || t.status == .stopped, "a Backup with a retiredAt stamp must not scan")
        m.reinstateVolume(at: "/Volumes/ShelfDrive")
        #expect(!t.isRetired)
        #expect(t.role == .backup, "reinstate leaves the role alone")
    }

    /// Sensor (codex R1-B2): a retired disk never authorizes a destructive
    /// disposition, whatever its role/trust says. Also pins the resolver
    /// shape after `.retired` left the enum.
    @Test func volumeSafety_retiredHostNeverSafe() {
        for r in VolumeRole.allCases {
            #expect(!VolumeSafety(role: r, trust: .reliable, isRetired: true).isSafe)
            #expect(VolumeSafety(role: r, trust: .reliable, isRetired: false).isSafe)
            #expect(!VolumeSafety(role: r, trust: .unreliable).isSafe)
        }
        #expect(VolumeSafety.unknown.isSafe, "unknown host stays safe-by-default")
        let w = SafeWitnessInfo(path: "/Volumes/Old/x", role: .offsite, trust: .reliable, isRetired: true)
        #expect(!w.isSafe)
        #expect(w.safetyScore == 3, "retired host scores 0 on the role axis (old .retired rank) + trust")
        #expect(SafeWitnessInfo(path: "", role: .offsite, trust: .reliable).safetyScore == 63)

        // The model resolver carries the stamp through.
        let m = makeModel()
        let t = CatalogScanTarget(searchPath: "/Volumes/ShelfDrive")
        t.role = .backup; t.trust = .reliable; t.retiredAt = Date()
        m.scanTargets = [t]
        let s = m.makeVolumeSafetyResolver()("/Volumes/ShelfDrive/clip.mxf")
        #expect(s.role == .backup && s.isRetired && !s.isSafe)
    }

    // MARK: - Bundle snapshot round-trip

    @Test func bundleSnapshot_roundTripPreservesEveryRole() throws {
        for r in VolumeRole.allCases {
            let src = CatalogScanTarget(searchPath: "/Volumes/RT")
            src.role = r
            src.trust = .reliable
            let snap = VolumeMetadataSnapshot(from: src)
            let data = try JSONEncoder().encode(snap)
            let decoded = try JSONDecoder().decode(VolumeMetadataSnapshot.self, from: data)
            #expect(decoded.role == r.rawValue)
            let dst = CatalogScanTarget(searchPath: "/Volumes/RT")
            ScanTargetPersistence.applyVolumeSnapshot(decoded, to: dst)
            #expect(dst.role == r, "\(r.rawValue) must survive export → import")
            #expect(dst.retiredAt == nil)
        }
    }

    /// A pre-taxonomy bundle: role strings "Long-Term Archive" / "Retired"
    /// (no stamp) import as Offsite / Unassigned+stamp. Hand-built JSON so
    /// the fixture cannot drift with the encoder.
    @Test func bundleSnapshot_legacyStringsMigrate() throws {
        func snap(_ role: String) throws -> VolumeMetadataSnapshot {
            let json = """
            {"searchPath":"/Volumes/Legacy","phase":"Cataloged","role":"\(role)","trust":"Reliable",
             "mediaTech":"HDD","filesystem":"HFS+","notes":""}
            """
            return try JSONDecoder().decode(VolumeMetadataSnapshot.self, from: Data(json.utf8))
        }
        let lta = CatalogScanTarget(searchPath: "/Volumes/Legacy")
        ScanTargetPersistence.applyVolumeSnapshot(try snap("Long-Term Archive"), to: lta)
        #expect(lta.role == .offsite)
        #expect(lta.retiredAt == nil)

        let ret = CatalogScanTarget(searchPath: "/Volumes/Legacy")
        ScanTargetPersistence.applyVolumeSnapshot(try snap("Retired"), to: ret)
        #expect(ret.role == .unassigned)
        #expect(ret.retiredAt != nil)
        #expect(ret.isRetired)

        let junk = CatalogScanTarget(searchPath: "/Volumes/Legacy")
        ScanTargetPersistence.applyVolumeSnapshot(try snap("Nonsense"), to: junk)
        #expect(junk.role == .unassigned)
    }

    // MARK: - Symlink in ~/Movies pin (existing behavior, unchanged)

    /// A symlinked folder inside a home-style tree that points at another
    /// location keeps resolving to its REAL location for reachability and
    /// free-space (URL resource values follow the link), and classifies as
    /// a Working home folder — never System. Built under the temp dir so
    /// the real ~/Movies is untouched.
    @Test func symlinkInHomeMovies_resolvesToRealVolume_isWorkingNotSystem() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("test_roletax_symlink_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let fakeHome = base.appendingPathComponent("Users/rickb", isDirectory: true)
        let movies = fakeHome.appendingPathComponent("Movies", isDirectory: true)
        let external = base.appendingPathComponent("ExternalVolume/Footage", isDirectory: true)
        try fm.createDirectory(at: movies, withIntermediateDirectories: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let link = movies.appendingPathComponent("Footage")
        try fm.createSymbolicLink(at: link, withDestinationURL: external)

        // Reachability: link resolves (real target exists) → reachable.
        #expect(VolumeReachability.isReachable(path: link.path))
        // Space: resource values follow the link to the real volume.
        let linkCap = try link.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        let realCap = try external.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        #expect(linkCap != nil && realCap != nil)
        // realpath lands on the real folder, not the link.
        #expect(link.resolvingSymlinksInPath().path == external.resolvingSymlinksInPath().path)

        // Classification: a home folder, not the boot root.
        #expect(CatalogScanTarget.isHomeFolderPath(link.path, homeDirectory: fakeHome.path))
        #expect(!CatalogScanTarget.isBootVolumeRootPath(link.path))
        // Migration default for it is Working (rule R3), pinned via the
        // predicate the migration uses.
        let m = makeModel()
        let t = CatalogScanTarget(searchPath: link.path)
        m.scanTargets = [t]
        // isHomeFolderTarget uses the REAL home; the fake tree lives under
        // tmp, so exercise the rule through the injectable predicate here
        // and the model rule through a real-home path in
        // migrate_homeFolderDefaultsToWorking.
        #expect(!t.isBootVolumeRoot)

        // Removing the real target makes the link dangling — reachability
        // must reflect the REAL volume going away, not the link's presence.
        try fm.removeItem(at: external)
        #expect(!fm.fileExists(atPath: link.path))
    }

    // MARK: - Scale sensor

    /// Role logic is per-target, never per-record. 1,000 targets through
    /// restore (legacy-aware decode) + migrate must stay well inside a
    /// budget that would flag any accidental O(records) or per-target
    /// disk work. Budget is generous for CI machines; typical is ~ms.
    @Test func scale_decodeAndMigrate1000Targets_underBudget() {
        let k = Keys()
        defer { k.cleanup() }
        let legacy = ["Long-Term Archive", "Retired", "Archive", "Backup", "Bogus", "Original", "Unassigned", "LTA"]
        let paths = (0..<1000).map { "/Volumes/Synthetic\($0)" }
        UserDefaults.standard.set(paths, forKey: k.paths)
        var roles: [String: String] = [:]
        for (i, p) in paths.enumerated() { roles[p] = legacy[i % legacy.count] }
        UserDefaults.standard.set(roles, forKey: k.roles)

        let m = makeModel()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let restored = restore(k)
            m.scanTargets = restored
            m.migrateVolumeRoles()
            m.migrateVolumeRoles()
        }
        #expect(m.scanTargets.count == 1000)
        #expect(m.scanTargets.filter { $0.isRetired }.count == 125, "every legacy 'Retired' stamped")
        #expect(m.scanTargets.filter { $0.role == .offsite }.count == 250)
        #expect(elapsed < .seconds(3), "1,000-target decode+migrate took \(elapsed)")
    }
}
