// ArchiveVolumeProtectionTests.swift
//
// Rick, 2026-09-22: "the app should never offer to delete from
// FamilyArchive since it is almost read only except for dropping in
// videos, photos, promotions etc."
//
// Before this fix the bulk-verb choke point (`excludingMasterArchiveFiles`)
// protected only the Breen_Family_Archive TREE. Everything else on the
// same volume — MoviesExpansion, RecordingProjectArchives, Hallie,
// ancestry, loose scans at the volume root — could be offered and moved
// to the Trash by Delete Duplicates, Delete Confirmed Junk, ⌘⌫, Discard
// (Under Construction) and "Archived — what next?" → Move to Trash.
//
// Now the WHOLE volume that hosts the Master Archive is protected from
// every verb that removes files. Catalog-only verbs (Remove from Catalog,
// Tidy) keep the tree-only rule — they never touch the disk.
//
// Five dimensions (CLAUDE.md):
//   Logic     — every disk verb refuses a file at <volume>/MoviesExpansion
//   Scale     — the Delete Duplicates menu over 100k records stays in budget
//   Media     — n/a (no file is opened; the junk/prune paths use blobs)
//   Isolation — synthetic /Volumes paths, sandbox temp dirs, injected
//               UUID + mount-table probes (task-local, never global)
//   Sensor    — a source sensor pins every file-removal call site in the
//               app target to a reviewed list

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Fixtures

@MainActor
private func record(_ path: String, group: UUID? = nil,
                    disposition: DuplicateDisposition = .none) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = 1
    r.partialMD5 = "m"
    r.durationSeconds = 61
    if let group {
        r.duplicateGroupID = group
        r.duplicateDisposition = disposition
        r.duplicateConfidence = .high
    }
    return r
}

@MainActor
private func isolatedModel() -> VideoScanModel {
    let model = VideoScanModel()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_archvol_\(UUID().uuidString.prefix(8))", isDirectory: true)
    model.catalogStore = CatalogStore(directory: dir)
    return model
}

/// "/Volumes/FamilyArchive" designated, no UUID recorded (the path is the
/// only identity — the tree-era default).
@MainActor
private func designateFamilyArchive(_ model: VideoScanModel, uuid: String? = nil,
                                    at volume: String = "/Volumes/FamilyArchive") {
    model.masterArchive = MasterArchiveDesignation(
        targetPath: volume, rootPath: volume + "/Breen_Family_Archive", volumeUUID: uuid)
}

private let onVolume = "/Volumes/FamilyArchive/MoviesExpansion/1994 Christmas.mov"
private let inTree = "/Volumes/FamilyArchive/Breen_Family_Archive/1990s/1994 Christmas.mov"
private let elsewhere = "/Volumes/CrucialX10/1994 Christmas.mov"
private let prefixTrap = "/Volumes/FamilyArchiveOld/1994 Christmas.mov"

@Suite("Archive volume protection — every disk verb", .serialized)
@MainActor
struct ArchiveVolumeProtectionTests {

    // MARK: The choke point

    @Test func chokePointProtectsTheWholeArchiveVolume() {
        let model = isolatedModel()
        designateFamilyArchive(model)
        let recs = [record(onVolume), record(inTree), record(elsewhere), record(prefixTrap),
                    record("/Volumes/FamilyArchive/loose scan.tif"),
                    record("/Volumes/FamilyArchive/Hallie/voice.wav")]
        let kept = model.excludingMasterArchiveFiles(recs, verb: "Delete Confirmed Junk").map(\.fullPath)
        #expect(kept == [elsewhere, prefixTrap],
                "only files OFF the archive volume survive; '/Volumes/FamilyArchiveOld' is a different volume")
    }

    @Test func chokePointLogsTheVolumeLineAndKeepsTheTreeLine() async throws {
        let model = isolatedModel()
        designateFamilyArchive(model)
        _ = model.excludingMasterArchiveFiles([record(onVolume), record(inTree)], verb: "Delete Duplicates")
        try await Task.sleep(nanoseconds: 400_000_000)   // the console flushes every 0.15 s
        let text = model.dashboard.consoleLines.joined(separator: "\n")
        #expect(text.contains(VideoScanModel.masterArchiveRefusalLine(verb: "Delete Duplicates", count: 1)),
                "the tree file keeps its existing line (log format unchanged)")
        #expect(text.contains("Delete Duplicates: left 1 file(s) alone — they live on FamilyArchive, the Master Archive volume, which only archive actions may change."),
                "the new volume line names the volume — \(text)")
    }

    @Test func noDesignationLeavesEveryVerbUnchanged() {
        let model = isolatedModel()
        let recs = [record(onVolume), record(inTree), record(elsewhere)]
        #expect(model.excludingMasterArchiveFiles(recs, verb: "Delete Confirmed Junk").count == 3)
    }

    // MARK: Delete Duplicates — the menu, the selection, the per-file gate

    @Test func deleteDuplicatesMenuNeverListsTheArchiveVolumeSameVolumeMode() {
        let model = isolatedModel()
        designateFamilyArchive(model)
        let gA = UUID(), gB = UUID()
        model.records = [
            record("/Volumes/FamilyArchive/MoviesExpansion/a.mov", group: gA, disposition: .keep),
            record("/Volumes/FamilyArchive/MoviesExpansion/a copy.mov", group: gA, disposition: .extraCopy),
            record("/Volumes/CrucialX10/b.mov", group: gB, disposition: .keep),
            record("/Volumes/CrucialX10/b copy.mov", group: gB, disposition: .extraCopy),
        ]
        #expect(model.duplicateKeeperSettings.alsoCleanUpWorkingCopies == false)
        let menu = model.volumesWithDeletableDuplicates().map(\.path)
        #expect(menu == ["/Volumes/CrucialX10"], "FamilyArchive is never offered — \(menu)")
        #expect(model.duplicateDeletionSelection(onVolume: "/Volumes/FamilyArchive").targets.isEmpty,
                "and picking it anyway selects nothing")
    }

    @Test func deleteDuplicatesMenuNeverListsTheArchiveVolumeCrossVolumeMode() {
        let model = isolatedModel()
        designateFamilyArchive(model)
        let raid = CatalogScanTarget(searchPath: "/Volumes/Projects"); raid.isReachable = true
        let arch = CatalogScanTarget(searchPath: "/Volumes/FamilyArchive"); arch.isReachable = true
        model.scanTargets = [raid, arch]
        model.duplicateKeeperSettings.volumePrecedence = ["/Volumes/Projects", "/Volumes/FamilyArchive"]
        model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        let g = UUID()
        model.records = [
            record("/Volumes/Projects/a.mov", group: g, disposition: .keep),
            record("/Volumes/FamilyArchive/MoviesExpansion/a.mov", group: g, disposition: .extraCopy),
        ]
        #expect(model.volumesWithDeletableDuplicates().isEmpty)
        #expect(model.duplicateDeletionSelection(onVolume: "/Volumes/FamilyArchive").targets.isEmpty)
    }

    @Test func archiveVolumeFileStillServesAsTheKeeperForACopyElsewhere() {
        // Keeper side unchanged: protecting FamilyArchive's files never
        // stops them from being the surviving copy.
        let model = isolatedModel()
        designateFamilyArchive(model)
        let arch = CatalogScanTarget(searchPath: "/Volumes/FamilyArchive"); arch.isReachable = true
        let x10 = CatalogScanTarget(searchPath: "/Volumes/CrucialX10"); x10.isReachable = true
        model.scanTargets = [arch, x10]
        model.duplicateKeeperSettings.volumePrecedence = ["/Volumes/FamilyArchive", "/Volumes/CrucialX10"]
        model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = true
        let g = UUID()
        let keeper = record("/Volumes/FamilyArchive/MoviesExpansion/a.mov", group: g, disposition: .keep)
        let extra = record("/Volumes/CrucialX10/a.mov", group: g, disposition: .extraCopy)
        model.records = [keeper, extra]
        let sel = model.duplicateDeletionSelection(onVolume: "/Volumes/CrucialX10")
        #expect(sel.targets.map(\.id) == [extra.id], "the X10 copy may go, its keeper on FamilyArchive stays — \(sel.skippedReasons)")
        #expect(model.volumesWithDeletableDuplicates().map(\.path) == ["/Volumes/CrucialX10"])
        #expect(model.bulkDeleteRefusal(keeper) == .archiveVolume, "…and the keeper itself is never deletable")
    }

    @Test func deleteDuplicatesRefusesAnArchiveVolumeFileAtDeleteTime() {
        // Planned BEFORE the designation (an old plan resumed, or the
        // archive designated mid-run): the per-file gate still refuses.
        let model = isolatedModel()
        let g = UUID()
        let keeper = record("/Volumes/FamilyArchive/MoviesExpansion/a.mov", group: g, disposition: .keep)
        let extra = record("/Volumes/FamilyArchive/MoviesExpansion/a copy.mov", group: g, disposition: .extraCopy)
        model.records = [keeper, extra]
        let entry = DeleteDuplicatesPlan.Entry(
            id: extra.id, path: extra.fullPath, filename: extra.filename, sizeBytes: 1,
            keeperID: keeper.id, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
            keeperStamp: nil)
        if case .authorized = model.authorizeDuplicateDeletion(entry: entry, volumePath: "/Volumes/FamilyArchive",
                                                               crossVolumeMode: false, stage: "before deletion") {
        } else {
            Issue.record("fixture: without a designation the pair is authorized")
        }
        designateFamilyArchive(model)
        switch model.authorizeDuplicateDeletion(entry: entry, volumePath: "/Volumes/FamilyArchive",
                                                crossVolumeMode: false, stage: "before deletion") {
        case .refuse(let note):
            #expect(note.contains("Master Archive"), "\(note)")
        default:
            Issue.record("an archive-volume file must be refused at delete time")
        }
    }

    // MARK: ⌘⌫, Discard, Delete Confirmed Junk

    @Test func trashShortcutPlanRefusesArchiveVolumeRows() {
        let model = isolatedModel()
        designateFamilyArchive(model)
        let a = record(onVolume), b = record(elsewhere)
        let plan = model.catalogTrashPlan(for: [a, b])
        #expect(plan.refused.map(\.id) == [a.id])
        #expect(plan.refused.first?.reason == .masterArchive)
        #expect(plan.toTrash == [b.id])
    }

    @Test func discardUnderConstructionLeavesArchiveVolumeFilesAlone() {
        // The path does not exist, so even a regression trashes nothing
        // real; the record's state is what tells.
        let model = isolatedModel()
        designateFamilyArchive(model)
        let r = record("/Volumes/FamilyArchive/MoviesExpansion/test_archvol_missing_\(UUID().uuidString).mov")
        model.records = [r]
        #expect(model.discardWorkbench([r]) == 0)
        #expect(r.purgedAt == nil, "the row stays active — nothing was discarded")
    }

    @Test func deleteConfirmedJunkLeavesArchiveVolumeFilesOnDisk() async throws {
        // Real files: the archive target is a sandbox folder (not under
        // /Volumes), so the protected region is that whole folder.
        let sb = try MasterArchiveTestSupport.makeSandbox("junk")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let expansion = sb.archiveVolume.appendingPathComponent("MoviesExpansion", isDirectory: true)
        try FileManager.default.createDirectory(at: expansion, withIntermediateDirectories: true)
        let protected = try MasterArchiveTestSupport.writeBlob(at: expansion.appendingPathComponent("test_keep.mov"), bytes: 1024, seed: 1)
        let loose = try MasterArchiveTestSupport.writeBlob(at: sb.archiveVolume.appendingPathComponent("test_loose.mov"), bytes: 1024, seed: 2)
        let control = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_go.mov"), bytes: 1024, seed: 3)
        let recs = [protected, loose, control].map { MasterArchiveTestSupport.makeRecord(path: $0.path) }
        model.records = recs
        let result = await model.deleteConfirmedJunk(recs, mode: .permanent)
        #expect(result.succeeded == 1)
        #expect(FileManager.default.fileExists(atPath: protected.path))
        #expect(FileManager.default.fileExists(atPath: loose.path))
        #expect(!FileManager.default.fileExists(atPath: control.path))
        #expect(recs[0].purgedAt == nil && recs[1].purgedAt == nil)
    }

    // MARK: "Archived — what next?" → Move to Trash

    @Test func moveToTrashNeverOffersOrMovesAnArchiveVolumeCopy() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("prune")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let a = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_prune_a.mov"),
                                                       bytes: 40 * 1024, seed: 7)
        let recA = MasterArchiveTestSupport.makeRecord(path: a.path, userDate: "1992")
        model.records = [recA]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [recA.id]))
        await job.completionTask?.value
        let archive = try #require(model.archivedCopy(of: recA))

        // A byte-identical copy on the archive VOLUME, outside the tree.
        let expansion = sb.archiveVolume.appendingPathComponent("MoviesExpansion", isDirectory: true)
        try FileManager.default.createDirectory(at: expansion, withIntermediateDirectories: true)
        let x = expansion.appendingPathComponent("test_prune_a.mov")
        try FileManager.default.copyItem(at: a, to: x)
        let recX = MasterArchiveTestSupport.makeRecord(path: x.path, userDate: "1992")
        for r in [recA, recX, archive] { r.contentHash = "v1:test-archvol-a" }
        model.records.append(recX)
        let ids = [recA.id, recX.id]

        let shown = await model.prunePlan(for: ids, options: .init(), isOnline: { _ in true })
        let family = try #require(shown.families.first)
        let row = try #require(family.rows.first { $0.id == recX.id }, "the copy is listed — \(family.rows)")
        #expect(!row.checkable, "an archive-volume copy is never offered — \(row)")
        #expect(!family.defaultSelection.contains(recX.id))
        #expect(family.rows.first { $0.id == recA.id }?.checkable == true, "the sources copy still is")

        // Even when a caller insists (a stale sheet), nothing moves.
        _ = await model.applyPrune(shown: shown, selected: [recX.id], recordIDs: ids, options: .init(),
                                   batchID: "test-archvol", mode: .permanent)
        #expect(FileManager.default.fileExists(atPath: x.path))
        #expect(recX.purgedAt == nil)
    }

    // MARK: Scale — the menu stays O(records)

    @Test("100k-record Delete Duplicates menu stays within budget with an archive designated",
          .timeLimit(.minutes(1)))
    func menuScale100k() {
        let model = isolatedModel()
        designateFamilyArchive(model)
        let gArch = UUID(), gOther = UUID()
        var catalog: [VideoRecord] = []
        catalog.reserveCapacity(100_000)
        catalog.append(record("/Volumes/FamilyArchive/MoviesExpansion/keeper.mov", group: gArch, disposition: .keep))
        catalog.append(record("/Volumes/CrucialX9/keeper.mov", group: gOther, disposition: .keep))
        for i in 2..<100_000 {
            let onArch = i % 2 == 0
            catalog.append(record(onArch ? "/Volumes/FamilyArchive/MoviesExpansion/copy-\(i).mov"
                                         : "/Volumes/CrucialX9/copy-\(i).mov",
                                  group: onArch ? gArch : gOther, disposition: .extraCopy))
        }
        model.records = catalog
        let start = ContinuousClock.now
        let menu = model.volumesWithDeletableDuplicates()
        let elapsed = start.duration(to: .now)
        #expect(menu.map(\.path) == ["/Volumes/CrucialX9"])
        #expect(menu.first?.count == 49_999)
        #expect(elapsed < .seconds(2), "100k menu exceeded 2 s: \(elapsed)")
    }
}

// MARK: - Identity: UUID, remount, unresolvable designation

/// Injects the mount table and the volume-UUID probe for one scope
/// (task-local — never process-global; parallel suites cannot see it).
@MainActor
private func withVolumes<T>(mounted: [String], uuids: [String: String],
                            _ body: () throws -> T) rethrows -> T {
    try ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({ mounted }) {
        try MasterArchiveDesignation.$volumeUUIDProbe.withValue({ path in
            // A path's UUID is its /Volumes root's (the real probe reads
            // the file's own volume the same way).
            guard let root = ArchiveVolumeProtection.externalVolumeRoot(of: path) else { return "BOOT-UUID" }
            return uuids[root]
        }) {
            try body()
        }
    }
}

@Suite("Archive volume protection — identity", .serialized)
@MainActor
struct ArchiveVolumeProtectionIdentityTests {

    @Test func renamedMountIsStillProtectedByUUID() {
        let model = isolatedModel()
        designateFamilyArchive(model, uuid: "UUID-ARCH")
        withVolumes(mounted: ["/Volumes/FamilyArchive 1", "/Volumes/CrucialX10"],
                    uuids: ["/Volumes/FamilyArchive 1": "UUID-ARCH", "/Volumes/CrucialX10": "UUID-X10"]) {
            let recs = [record("/Volumes/FamilyArchive 1/MoviesExpansion/a.mov"),
                        record("/Volumes/FamilyArchive/MoviesExpansion/a.mov"),   // stale path: still refused
                        record("/Volumes/CrucialX10/a.mov"),
                        record("/Users/rickb/Movies/a.mov")]
            let kept = model.excludingMasterArchiveFiles(recs, verb: "Delete Duplicates").map(\.fullPath)
            #expect(kept == ["/Volumes/CrucialX10/a.mov", "/Users/rickb/Movies/a.mov"])
            let g = UUID()
            model.records = [record("/Volumes/FamilyArchive 1/x.mov", group: g, disposition: .keep),
                             record("/Volumes/FamilyArchive 1/x copy.mov", group: g, disposition: .extraCopy)]
            #expect(model.volumesWithDeletableDuplicates().isEmpty, "the renamed mount is never offered")
        }
    }

    @Test func unresolvableDesignationRefusesWhatItCannotProve() {
        let model = isolatedModel()
        designateFamilyArchive(model, uuid: "UUID-ARCH")
        // The archive volume is NOT mounted anywhere.
        withVolumes(mounted: ["/Volumes/CrucialX10", "/Volumes/NoUUID"],
                    uuids: ["/Volumes/CrucialX10": "UUID-X10"]) {
            let snap = model.archiveVolumeProtection()
            #expect(snap?.isResolved == false)
            let x10 = record("/Volumes/CrucialX10/a.mov")          // proven another volume
            let noUUID = record("/Volumes/NoUUID/a.mov")           // cannot prove
            let gone = record("/Volumes/SomeOldDrive/a.mov")       // not mounted: cannot prove
            let boot = record("/Users/rickb/Movies/a.mov")         // boot disk is never the archive
            #expect(model.bulkDeleteRefusal(x10, volume: snap) == nil)
            #expect(model.bulkDeleteRefusal(noUUID, volume: snap) == .archiveVolumeUnprovable)
            #expect(model.bulkDeleteRefusal(gone, volume: snap) == .archiveVolumeUnprovable)
            #expect(model.bulkDeleteRefusal(boot, volume: snap) == nil)
            let kept = model.excludingMasterArchiveFiles([x10, noUUID, gone, boot], verb: "Delete Confirmed Junk")
            #expect(kept.map(\.id) == [x10.id, boot.id])
        }
    }

    @Test func resolvedByPathCostsOneProbeAndClearsOtherVolumes() {
        final class Counter: @unchecked Sendable { var n = 0 }
        let calls = Counter()
        let d = MasterArchiveDesignation(targetPath: "/Volumes/FamilyArchive",
                                         rootPath: "/Volumes/FamilyArchive/Breen_Family_Archive", volumeUUID: "U")
        let snap = ArchiveVolumeProtection.make(designation: d, mountedRoots: { Issue.record("no mount scan needed"); return [] },
                                                probe: { _ in calls.n += 1; return "U" })
        #expect(calls.n == 1)
        #expect(snap?.isResolved == true)
        #expect(snap?.verdict(forPath: "/Volumes/Anything/x.mov") == .clear)
        #expect(snap?.verdict(forPath: "/Volumes/FamilyArchive/x.mov") == .onArchiveVolume)
        #expect(snap?.verdict(forPath: "/Volumes/familyarchive/x.mov") == .onArchiveVolume, "case-insensitive, like the boot volume")
        #expect(snap?.verdict(forPath: "/Volumes/CrucialX10/../FamilyArchive/x.mov") == .onArchiveVolume, "'..' cannot smuggle it out")
    }

    @Test func removalTimeRecheckCatchesAVolumeMountedAfterTheSnapshot() {
        // Snapshot taken while the archive was offline and an unknown
        // mount looked "proven other"; at removal the file's own volume
        // reads back the archive's UUID.
        let d = MasterArchiveDesignation(targetPath: "/Volumes/FamilyArchive",
                                         rootPath: "/Volumes/FamilyArchive/Breen_Family_Archive", volumeUUID: "U")
        let snap = ArchiveVolumeProtection.make(designation: d, mountedRoots: { ["/Volumes/Other"] },
                                                probe: { $0.hasPrefix("/Volumes/Other") ? "O" : nil })
        let s = try? #require(snap)
        #expect(s?.verdict(forPath: "/Volumes/Other/a.mov") == .clear)
        #expect(s?.verdictAtRemoval(path: "/Volumes/Other/a.mov", probe: { _ in "U" }) == .onArchiveVolume)
        #expect(s?.verdictAtRemoval(path: "/Volumes/Other/a.mov", probe: { _ in "O" }) == .clear)
    }

    @Test func bootDiskArchiveProtectsItsFolderNotTheWholeBootDisk() {
        let d = MasterArchiveDesignation(targetPath: "/Users/rickb/ArchiveHere",
                                         rootPath: "/Users/rickb/ArchiveHere/Breen_Family_Archive", volumeUUID: "BOOT")
        let s = ArchiveVolumeProtection.make(designation: d, mountedRoots: { [] }, probe: { _ in "BOOT" })
        #expect(s?.verdict(forPath: "/Users/rickb/ArchiveHere/MoviesExpansion/a.mov") == .onArchiveVolume)
        #expect(s?.verdict(forPath: "/Users/rickb/Movies/a.mov") == .clear)
        #expect(s?.verdictAtRemoval(path: "/Users/rickb/Movies/a.mov", probe: { _ in "BOOT" }) == .clear,
                "the shared boot UUID must not protect the whole boot disk")
        #expect(s?.verdict(forPath: "/Users/rickb/ArchiveHereToo/a.mov") == .clear, "component-wise, not a string prefix")
    }

    @Test func catalogOnlyVerbsKeepTheTreeOnlyRule() {
        let model = isolatedModel()
        designateFamilyArchive(model)
        let vol = record(onVolume), tree = record(inTree)
        model.records = [vol, tree]
        // Remove from Catalog never touches the disk: allowed off-tree…
        #expect(model.purgeRecords(ids: [vol.id, tree.id]) == 1)
        #expect(vol.purgedAt != nil && tree.purgedAt == nil, "…and the tree stays refused")
    }

    @Test func junkEngineReChecksTheFilesOwnVolumeAtTheMomentOfRemoval() async throws {
        // The plan-time snapshot says "clear" (a boot-disk path, archive
        // offline); at the moment of removal the file's OWN volume reads
        // back the archive's UUID — as if FamilyArchive had been mounted
        // there since. The engine must refuse, name it, and move nothing.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_archvol_removal_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test_keep.mov")
        FileManager.default.createFile(atPath: file.path, contents: Data([1, 2, 3]))
        let model = isolatedModel()
        designateFamilyArchive(model, uuid: "UUID-ARCH")
        let r = record(file.path)
        model.records = [r]
        let dirPath = dir.path
        let result = await ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({ [] }) {
            await MasterArchiveDesignation.$volumeUUIDProbe.withValue({ path in
                path.hasPrefix(dirPath) ? "UUID-ARCH" : nil
            }) {
                #expect(model.bulkDeleteRefusal(r) == nil, "fixture: plan time says clear")
                return await model.deleteConfirmedJunk([r], mode: .permanent)
            }
        }
        #expect(result.succeeded == 0)
        #expect(result.refused.count == 1)
        #expect(result.refused.first?.reason.contains("Master Archive volume") == true, "\(result.refused)")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(r.purgedAt == nil)
    }
}

// MARK: - Sensor: every file-removal call site is reviewed

@Suite("Archive volume protection — source sensor")
struct ArchiveVolumeProtectionSourceSensor {

    /// The reviewed inventory (2026-09-22) of file-removal primitives —
    /// `trashItem(` / `removeItem(` / `unlink(` / `unlinkat(` /
    /// `removefile(` outside comment lines — per source file. Everything
    /// here removes the app's OWN files (partials, temp dirs, caches,
    /// staging, POI data, derivative outputs, archive-internal partials)
    /// EXCEPT the three that remove CATALOG files, each pinned below to
    /// the one bulk-delete rule:
    ///   VideoScanModel+JunkDelete.swift  (Junk, ⌘⌫, row Delete File,
    ///                                     Move to Trash) — choke point +
    ///                                     removal-time volume re-check
    ///   VideoScanModel+Workbench.swift   (Discard) — choke point
    ///   SignatureVerification.swift      (Delete Duplicates) — behind
    ///                                     authorizeDuplicateDeletion
    /// A NEW call site, or more of them in a file, fails here: if it can
    /// remove a catalog record's file, route it through
    /// `excludingMasterArchiveFiles` / `bulkDeleteRefusal` first; then
    /// update this list.
    static let reviewed: [String: Int] = [
        "VideoScan/AdaFaceEngine.swift": 1, "VideoScan/ArcFaceEngine.swift": 1,
        "VideoScan/ArchiveAngelJob.swift": 1, "VideoScan/ArchiveAngelPlan.swift": 2,
        "VideoScan/ArchivePromoteEngine.swift": 3, "VideoScan/AudioTranscriber.swift": 1,
        "VideoScan/BalanceAudioJob.swift": 1, "VideoScan/BundleExporter.swift": 1,
        "VideoScan/BundleImporter.swift": 2, "VideoScan/CaptionRunner.swift": 2,
        "VideoScan/CatalogStore.swift": 1, "VideoScan/CatalogSync.swift": 3,
        "VideoScan/CatalogWriteError.swift": 1, "VideoScan/CleanupJob.swift": 4,
        "VideoScan/CouplePortrait.swift": 2, "VideoScan/FamilyAssetStore.swift": 2,
        "VideoScan/FamilySearchPullCoordinator.swift": 6, "VideoScan/FindPersonJob.swift": 1,
        "VideoScan/HallieNeuralSpeech.swift": 7, "VideoScan/HalliePhotoImport.swift": 1,
        "VideoScan/HalliePronunciationLexicon.swift": 1, "VideoScan/HallieWebPoster.swift": 3,
        "VideoScan/HallieWebProxy.swift": 3, "VideoScan/IdentifyFamilyModel.swift": 1,
        "VideoScan/MediaPersonLinks.swift": 1,   // a method named unlink(personID:) — no file
        "VideoScan/POIProfileFileStore.swift": 2, "VideoScan/POIStorage.swift": 1,
        "VideoScan/PerceptualFingerprinter.swift": 1, "VideoScan/PersonEditSheet.swift": 1,
        "VideoScan/PersonFinderCompilation.swift": 7, "VideoScan/RebuildAudioJob.swift": 1,
        "VideoScan/RecipeGenderAgeGate.swift": 1, "VideoScan/ReformatJob.swift": 8,
        "VideoScan/RelocateEngine.swift": 1, "VideoScan/RescueFileCopier.swift": 3,
        "VideoScan/ReviewThumbnailRenderer.swift": 1, "VideoScan/ScanCheckpoint.swift": 1,
        "VideoScan/ScanJobsStorage.swift": 2, "VideoScan/SignatureVerification.swift": 2,
        "VideoScan/TranscodeJob.swift": 7, "VideoScan/TrimJob.swift": 1,
        "VideoScan/VideoScanModel+Combine.swift": 3, "VideoScan/VideoScanModel+JunkDelete.swift": 2,
        "VideoScan/VideoScanModel+ProbeEngine.swift": 1, "VideoScan/VideoScanModel+Workbench.swift": 1,
        "VideoScanCore/AtomicFilePublish.swift": 2, "VideoScanCore/CyberBrainWriter.swift": 3,
        "VideoScanCore/FFmpegFrameRip.swift": 1, "VideoScanCore/FamilyGraphCompiledStore.swift": 5,
        "VideoScanCore/PreviewDiskCache.swift": 4,
    ]

    private static var projectDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func source(_ rel: String) throws -> String {
        try String(contentsOf: projectDir.appendingPathComponent(rel), encoding: .utf8)
    }

    @Test func noUnreviewedFileRemovalCallSite() throws {
        let pattern = try NSRegularExpression(pattern: #"\b(trashItem|removeItem|unlink|unlinkat|removefile)\("#)
        var found: [String: Int] = [:]
        let dirs = [("VideoScan", "VideoScan"), ("VideoScanCore", "VideoScanCore/Sources/VideoScanCore")]
        for (label, rel) in dirs {
            let dir = Self.projectDir.appendingPathComponent(rel)
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
            for name in names {
                let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                var n = 0
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    let s = String(line)
                    n += pattern.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
                }
                if n > 0 { found["\(label)/\(name)"] = n }
            }
        }
        #expect(found.count >= 40, "the scan found the sources — \(found.count) files")
        for (file, n) in found.sorted(by: { $0.key < $1.key }) {
            let pinned = Self.reviewed[file] ?? 0
            #expect(n <= pinned,
                    "\(file) has \(n) file-removal call(s), reviewed \(pinned). If it can remove a catalog record's file, route it through excludingMasterArchiveFiles / bulkDeleteRefusal (the Master Archive volume rule), then update ArchiveVolumeProtectionSourceSensor.reviewed.")
        }
    }

    @Test func theCatalogFileRemoversGoThroughTheOneRule() throws {
        let junk = try Self.source("VideoScan/VideoScanModel+JunkDelete.swift")
        #expect(junk.contains("let records = excludingMasterArchiveFiles(requested, verb: \"Delete Confirmed Junk\")"))
        #expect(junk.contains("archiveVolume.verdictAtRemoval(path: path, probe: uuidProbe)"),
                "the removal-time re-check sits in the detached pass")
        let bench = try Self.source("VideoScan/VideoScanModel+Workbench.swift")
        #expect(bench.contains("let recs = excludingMasterArchiveFiles(requested, verb: \"Discard\")"))
        let dups = try Self.source("VideoScan/VideoScanModel+Duplicates.swift")
        #expect(dups.contains("switch bulkDeleteRefusal(rec, volume: archiveVolume)"),
                "authorizeDuplicateDeletion asks the one rule live")
        #expect(dups.contains("var targets = excludingMasterArchiveFiles(selection.targets, verb: \"Delete Duplicates\")"))
        let job = try Self.source("VideoScan/DeleteDuplicatesJob.swift")
        #expect(job.components(separatedBy: "model.authorizeDuplicateDeletion(").count - 1 >= 2,
                "dispatch AND resume re-check authorize every pair")
        let prune = try Self.source("VideoScan/VideoScanModel+PruneApply.swift")
        #expect(prune.contains("if let refusal = bulkDeleteRefusal(rec, volume: archiveVolume)"))
        let selection = try Self.source("VideoScan/VideoScanModel+TrashSelection.swift")
        #expect(selection.contains("self.bulkDeleteRefusal($0, volume: archiveVolume) != nil"))
    }
}
