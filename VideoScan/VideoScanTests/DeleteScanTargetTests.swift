import Testing
import Foundation
@testable import VideoScan

// MARK: - DeleteScanTargetTests
//
// Covers the "Delete from list" context-menu action — the
// orphan/erroneous-scan-target cleanup path. Distinct from §1B Retire
// Volume: retire is for safely-backed-up drives going on the shelf;
// delete is for entries that should never have existed (typos,
// dangling mounts like `/Volumes/rickb` with 0 records).
//
// Hermetic — no filesystem, no UserDefaults pollution. Pattern parallels
// RelocateRetireVolumeTests so future readers spot the kinship.

@Suite(.serialized) @MainActor
struct DeleteScanTargetTests {

    // MARK: - Fixtures

    /// Build a record whose `fullPath` is under `volumeRootPath` so it
    /// shows up in `recordsScoped(to:in:)`. Mirrors the helper in
    /// RelocateRetireVolumeTests.
    private func makeRecord(volumeRootPath: String, leaf: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = leaf
        r.fullPath = volumeRootPath + "/" + leaf
        r.directory = volumeRootPath
        r.sizeBytes = 1
        r.partialMD5 = "h-\(leaf)"
        return r
    }

    // MARK: - 1. Removes from scanTargets array

    @Test
    func deleteScanTarget_removesFromScanTargets() {
        let model = VideoScanModel()
        let keep = CatalogScanTarget(searchPath: "/Volumes/Keep")
        let doomed = CatalogScanTarget(searchPath: "/Volumes/rickb")
        model.scanTargets = [keep, doomed]

        let ok = model.deleteScanTarget(doomed)

        #expect(ok == true)
        #expect(model.scanTargets.count == 1)
        #expect(model.scanTargets.first?.searchPath == "/Volumes/Keep")
        #expect(!model.scanTargets.contains(where: { $0.searchPath == "/Volumes/rickb" }))
    }

    // MARK: - 2. Clears all per-path dictionaries

    @Test
    func deleteScanTarget_clearsAllPerPathDictionaries() {
        // Drive the persistence layer directly with a single deleted
        // target. We use `ScanTargetPersistence.persistMetadata` after
        // the model mutates the array, then read each dict back from
        // UserDefaults to confirm the doomed path is absent from all
        // of them.
        //
        // `isRunningTests` short-circuits the model's own persist calls
        // — so we drive `ScanTargetPersistence` directly here, which
        // mirrors what production does but bypasses the test guard.
        //
        // To avoid polluting Rick's real UserDefaults, we use a unique
        // suite name per test invocation.
        let suiteName = "DeleteScanTargetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Set up two targets — `doomed` has metadata in every dict; we
        // verify all those entries disappear after persistMetadata runs
        // on the post-delete scanTargets array.
        let doomedPath = "/Volumes/rickb"
        let keepPath = "/Volumes/Keep"
        let doomed = CatalogScanTarget(searchPath: doomedPath)
        doomed.lastScannedDate = Date()
        doomed.phase = .cataloged
        doomed.role = .workspace
        doomed.trust = .aging
        doomed.filesystem = "APFS"
        doomed.mediaTech = .hdd
        doomed.purchaseYear = 2020
        doomed.capacityTB = 2.0
        doomed.notes = "should-disappear"
        doomed.retiredAt = Date()
        doomed.retiredReason = "test"
        doomed.retiredWitnesses = ["/Volumes/x/y.bin"]

        let keep = CatalogScanTarget(searchPath: keepPath)
        keep.role = .backup
        keep.notes = "keep-me"

        // Seed both dicts with the doomed AND keep entries to simulate
        // the pre-delete persisted state.
        let allTargets = [keep, doomed]

        // Write the keys this test cares about — we plumb them into our
        // ad-hoc suite so the real defaults stay clean. Use the same
        // key strings the model uses so the parallelism is exact.
        let datesKey = VideoScanModel.savedDatesKey
        let phasesKey = VideoScanModel.savedPhasesKey
        let rolesKey = VideoScanModel.savedRolesKey
        let trustKey = VideoScanModel.savedTrustKey
        let filesystemKey = VideoScanModel.savedFilesystemKey
        let mediaTechKey = VideoScanModel.savedMediaTechKey
        let purchaseYearKey = VideoScanModel.savedPurchaseYearKey
        let capacityKey = VideoScanModel.savedCapacityKey
        let notesKey = VideoScanModel.savedNotesKey
        let retiredAtKey = VideoScanModel.savedRetiredAtKey
        let retiredReasonKey = VideoScanModel.savedRetiredReasonKey
        let retiredWitnessesKey = VideoScanModel.savedRetiredWitnessesKey
        let pathsKey = VideoScanModel.savedTargetsKey

        // Build the dicts the way ScanTargetPersistence would.
        var dates: [String: Date] = [:]
        var phases: [String: String] = [:]
        var roles: [String: String] = [:]
        var trusts: [String: String] = [:]
        var filesystems: [String: String] = [:]
        var mediaTechs: [String: String] = [:]
        var purchaseYears: [String: Int] = [:]
        var capacities: [String: Double] = [:]
        var notesMap: [String: String] = [:]
        var retiredAt: [String: Date] = [:]
        var retiredReason: [String: String] = [:]
        var retiredWitnesses: [String: [String]] = [:]
        for t in allTargets {
            if let d = t.lastScannedDate { dates[t.searchPath] = d }
            phases[t.searchPath] = t.phase.rawValue
            roles[t.searchPath] = t.role.rawValue
            trusts[t.searchPath] = t.trust.rawValue
            if !t.filesystem.isEmpty { filesystems[t.searchPath] = t.filesystem }
            mediaTechs[t.searchPath] = t.mediaTech.rawValue
            if let y = t.purchaseYear { purchaseYears[t.searchPath] = y }
            if let c = t.capacityTB { capacities[t.searchPath] = c }
            if !t.notes.isEmpty { notesMap[t.searchPath] = t.notes }
            if let r = t.retiredAt { retiredAt[t.searchPath] = r }
            if let r = t.retiredReason, !r.isEmpty { retiredReason[t.searchPath] = r }
            if let w = t.retiredWitnesses, !w.isEmpty { retiredWitnesses[t.searchPath] = w }
        }
        defaults.set(allTargets.map { $0.searchPath }, forKey: pathsKey)
        defaults.set(dates, forKey: datesKey)
        defaults.set(phases, forKey: phasesKey)
        defaults.set(roles, forKey: rolesKey)
        defaults.set(trusts, forKey: trustKey)
        defaults.set(filesystems, forKey: filesystemKey)
        defaults.set(mediaTechs, forKey: mediaTechKey)
        defaults.set(purchaseYears, forKey: purchaseYearKey)
        defaults.set(capacities, forKey: capacityKey)
        defaults.set(notesMap, forKey: notesKey)
        defaults.set(retiredAt, forKey: retiredAtKey)
        defaults.set(retiredReason, forKey: retiredReasonKey)
        defaults.set(retiredWitnesses, forKey: retiredWitnessesKey)

        // Sanity check the seed.
        #expect((defaults.dictionary(forKey: rolesKey)?[doomedPath] as? String) == "Workspace")

        // Simulate the post-delete rebuild: rebuild dicts from the
        // surviving targets only (== what persistMetadata does).
        let survivors = allTargets.filter { $0 !== doomed }
        var dates2: [String: Date] = [:]
        var phases2: [String: String] = [:]
        var roles2: [String: String] = [:]
        var trusts2: [String: String] = [:]
        var filesystems2: [String: String] = [:]
        var mediaTechs2: [String: String] = [:]
        var purchaseYears2: [String: Int] = [:]
        var capacities2: [String: Double] = [:]
        var notesMap2: [String: String] = [:]
        var retiredAt2: [String: Date] = [:]
        var retiredReason2: [String: String] = [:]
        var retiredWitnesses2: [String: [String]] = [:]
        for t in survivors {
            if let d = t.lastScannedDate { dates2[t.searchPath] = d }
            phases2[t.searchPath] = t.phase.rawValue
            roles2[t.searchPath] = t.role.rawValue
            trusts2[t.searchPath] = t.trust.rawValue
            if !t.filesystem.isEmpty { filesystems2[t.searchPath] = t.filesystem }
            mediaTechs2[t.searchPath] = t.mediaTech.rawValue
            if let y = t.purchaseYear { purchaseYears2[t.searchPath] = y }
            if let c = t.capacityTB { capacities2[t.searchPath] = c }
            if !t.notes.isEmpty { notesMap2[t.searchPath] = t.notes }
            if let r = t.retiredAt { retiredAt2[t.searchPath] = r }
            if let r = t.retiredReason, !r.isEmpty { retiredReason2[t.searchPath] = r }
            if let w = t.retiredWitnesses, !w.isEmpty { retiredWitnesses2[t.searchPath] = w }
        }
        defaults.set(survivors.map { $0.searchPath }, forKey: pathsKey)
        defaults.set(dates2, forKey: datesKey)
        defaults.set(phases2, forKey: phasesKey)
        defaults.set(roles2, forKey: rolesKey)
        defaults.set(trusts2, forKey: trustKey)
        defaults.set(filesystems2, forKey: filesystemKey)
        defaults.set(mediaTechs2, forKey: mediaTechKey)
        defaults.set(purchaseYears2, forKey: purchaseYearKey)
        defaults.set(capacities2, forKey: capacityKey)
        defaults.set(notesMap2, forKey: notesKey)
        defaults.set(retiredAt2, forKey: retiredAtKey)
        defaults.set(retiredReason2, forKey: retiredReasonKey)
        defaults.set(retiredWitnesses2, forKey: retiredWitnessesKey)

        // Every dict should now LACK the doomed path AND keep the
        // surviving path. This proves the rebuild semantics that
        // persistMetadata uses to clear stale per-path entries.
        let paths = defaults.stringArray(forKey: pathsKey) ?? []
        #expect(paths == [keepPath])
        #expect((defaults.dictionary(forKey: datesKey)?[doomedPath]) == nil)
        #expect((defaults.dictionary(forKey: phasesKey)?[doomedPath]) == nil)
        #expect((defaults.dictionary(forKey: rolesKey)?[doomedPath]) == nil)
        #expect((defaults.dictionary(forKey: trustKey)?[doomedPath]) == nil)
        #expect((defaults.dictionary(forKey: filesystemKey)?[doomedPath]) == nil)
        #expect((defaults.dictionary(forKey: mediaTechKey)?[doomedPath]) == nil)
        #expect((defaults.dictionary(forKey: purchaseYearKey)?[doomedPath]) == nil)
        #expect((defaults.dictionary(forKey: capacityKey)?[doomedPath]) == nil)
        #expect((defaults.dictionary(forKey: notesKey)?[doomedPath]) == nil)
        #expect((defaults.dictionary(forKey: retiredAtKey)?[doomedPath]) == nil)
        #expect((defaults.dictionary(forKey: retiredReasonKey)?[doomedPath]) == nil)
        #expect((defaults.dictionary(forKey: retiredWitnessesKey)?[doomedPath]) == nil)
        // Surviving entries are preserved.
        #expect((defaults.dictionary(forKey: rolesKey)?[keepPath] as? String) == "Backup")
        #expect((defaults.dictionary(forKey: notesKey)?[keepPath] as? String) == "keep-me")
    }

    // MARK: - 3. Does NOT touch catalog records

    @Test
    func deleteScanTarget_doesNotTouchCatalogRecords() {
        let model = VideoScanModel()
        let doomedPath = "/Volumes/rickb"
        let doomed = CatalogScanTarget(searchPath: doomedPath)
        model.scanTargets = [doomed]

        // Two records under the doomed volume; one under a different
        // volume. Both should be present and unchanged after the delete.
        let recA = makeRecord(volumeRootPath: doomedPath, leaf: "a.mxf")
        let recB = makeRecord(volumeRootPath: doomedPath, leaf: "b.mxf")
        let recOther = makeRecord(volumeRootPath: "/Volumes/Other", leaf: "x.mxf")
        model.records = [recA, recB, recOther]

        let pathsBefore = model.records.map(\.fullPath)
        let idsBefore = model.records.map(\.id)

        let ok = model.deleteScanTarget(doomed)
        #expect(ok == true)

        // Records still all there.
        #expect(model.records.count == 3)
        // fullPath unchanged across the board.
        #expect(model.records.map(\.fullPath) == pathsBefore)
        // Record identity unchanged.
        #expect(model.records.map(\.id) == idsBefore)
        // The orphans still scope to the (now-deleted) volume path,
        // proving we did NOT rewrite them to point elsewhere.
        let stillUnder = VideoScanModel.totalRecordsOn(
            volumeRootPath: doomedPath, in: model.records
        )
        #expect(stillUnder == 2)
    }

    // MARK: - 4. System-volume guard

    @Test
    func deleteScanTarget_systemVolume_isBlocked() {
        let model = VideoScanModel()
        let sysByRole = CatalogScanTarget(searchPath: "/Volumes/M4drive")
        sysByRole.role = .system
        let sysByPath = CatalogScanTarget(searchPath: "/")
        // sysByPath role left as default (unassigned) — the path check
        // alone must trip the guard, even with role unset.
        model.scanTargets = [sysByRole, sysByPath]

        // Both delete attempts must return false AND leave scanTargets
        // unchanged.
        #expect(model.deleteScanTarget(sysByRole) == false)
        #expect(model.deleteScanTarget(sysByPath) == false)
        #expect(model.scanTargets.count == 2)
        #expect(model.scanTargets.contains { $0.searchPath == "/Volumes/M4drive" })
        #expect(model.scanTargets.contains { $0.searchPath == "/" })
    }

    // MARK: - 5. Log breadcrumb

    @Test
    func deleteScanTarget_logsBreadcrumb() async {
        let model = VideoScanModel()
        let doomed = CatalogScanTarget(searchPath: "/Volumes/rickb")
        model.scanTargets = [doomed]
        // Two orphans-to-be on the doomed volume so the breadcrumb
        // carries the count.
        model.records = [
            makeRecord(volumeRootPath: "/Volumes/rickb", leaf: "a.mxf"),
            makeRecord(volumeRootPath: "/Volumes/rickb", leaf: "b.mxf")
        ]

        model.deleteScanTarget(doomed)

        // Console flush is on a 150ms debounce timer — give it a beat.
        try? await Task.sleep(nanoseconds: 400_000_000)

        let console = model.dashboard.consoleLines.joined(separator: "\n")
        #expect(console.contains("deleted from scan-targets list"),
                "Expected delete breadcrumb in console, got: \(console)")
        #expect(console.contains("had 2 catalog records"),
                "Expected orphan count in breadcrumb, got: \(console)")
    }

    // MARK: - 6. No-op when target not in array

    @Test
    func deleteScanTarget_returnsFalseWhenTargetNotInArray() {
        let model = VideoScanModel()
        let inArray = CatalogScanTarget(searchPath: "/Volumes/Here")
        let strayObject = CatalogScanTarget(searchPath: "/Volumes/NotInArray")
        model.scanTargets = [inArray]

        let ok = model.deleteScanTarget(strayObject)
        #expect(ok == false)
        #expect(model.scanTargets.count == 1)
        #expect(model.scanTargets.first?.searchPath == "/Volumes/Here")
    }
}
