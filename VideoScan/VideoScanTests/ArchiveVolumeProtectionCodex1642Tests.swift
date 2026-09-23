// ArchiveVolumeProtectionCodex1642Tests.swift
//
// codex #1642 (review of main 7e0503a3, docs/codex-review-1633-1638-2026-09-23.md):
//
//   D3 / P1 — a Master Archive designation whose path is not LITERALLY
//   under /Volumes was classified as a boot-disk FOLDER, which switched
//   off whole-volume UUID protection. Designating through
//   /System/Volumes/Data/Volumes/FamilyArchive (the firmlink spelling),
//   through a symlink, or at a custom mount point left the canonical
//   /Volumes/FamilyArchive/MoviesExpansion/a.mov unprotected — the UUID
//   probe was never even consulted.
//
//   D6 / P2 — Remove / Remove from Catalog / Tidy Catalog treated an
//   "unprovable" verdict as removable, so while the snapshot was still
//   PROVISIONAL (a rename / reconnect just happened) the real archive at
//   "/Volumes/FamilyArchive 1" could lose catalog rows. Rick 2026-09-22:
//   "For now we won't Remove anything from FamilyArchive."
//
// Five dimensions (CLAUDE.md):
//   Logic     — every test below
//   Scale     — the per-record verdict stays string-only (the 100k menu
//               budget in ArchiveVolumeProtectionTests still pins it)
//   Media     — n/a (no media file is opened)
//   Isolation — synthetic paths; task-local mount-table, mount-identity
//               and volume-UUID probes; one real symlink in a temp dir
//   Sensor    — the identity rule is pinned for every spelling Rick can
//               produce from the Initialize panel

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
private func record(_ path: String) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = 1
    r.partialMD5 = "m-\(path.hashValue)"
    r.durationSeconds = 61
    return r
}

@MainActor
private func isolatedModel() -> VideoScanModel {
    let model = VideoScanModel()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_arch1642_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    model.catalogStore = CatalogStore(directory: dir)
    model.ignoredContentStore = IgnoredContentStore(directory: dir)
    return model
}

@MainActor
private func consoleText(_ model: VideoScanModel) async -> String {
    try? await Task.sleep(nanoseconds: 400_000_000)   // the console flushes every 0.15 s
    return model.dashboard.consoleLines.joined(separator: "\n")
}

/// UUIDs by volume root: "/Volumes/<name>" roots from the table, the boot
/// disk ("/", "/Users/…", "/System/Volumes/Data/…") is "BOOT".
private func uuidProbe(_ table: [String: String]) -> @Sendable (String) -> String? {
    { path in
        for (root, uuid) in table where path == root || path.hasPrefix(root + "/") { return uuid }
        if ArchiveVolumeProtection.externalVolumeRoot(of: path) != nil { return nil }
        return "BOOT"
    }
}

// MARK: - P1: identity from the mount, never from the spelling

@Suite("Archive volume protection — codex #1642 identity by mount", .serialized)
struct ArchiveVolumeProtectionCodex1642IdentityTests {

    private let canonicalLoose = "/Volumes/FamilyArchive/MoviesExpansion/a.mov"

    /// codex's exact repro: the firmlink spelling of the archive volume.
    @Test func firmlinkSpelledDesignationProtectsTheCanonicalPathByUUID() {
        let d = MasterArchiveDesignation(targetPath: "/System/Volumes/Data/Volumes/FamilyArchive",
                                         rootPath: "/System/Volumes/Data/Volumes/FamilyArchive/Breen_Family_Archive",
                                         volumeUUID: "UUID-ARCH")
        let probe = uuidProbe(["/Volumes/FamilyArchive": "UUID-ARCH",
                               "/System/Volumes/Data/Volumes/FamilyArchive": "UUID-ARCH",
                               "/Volumes/CrucialX10": "UUID-X10"])
        let snap = ArchiveVolumeProtection.make(designation: d,
                                                mountedRoots: { ["/Volumes/FamilyArchive", "/Volumes/CrucialX10"] },
                                                probe: probe,
                                                identity: identityProbe(["/Volumes/FamilyArchive": ("/Volumes/FamilyArchive", "/Volumes/FamilyArchive")]),
                                                networkRoots: { [] })
        #expect(snap?.verdict(forPath: canonicalLoose) == .onArchiveVolume, "canonical spelling of the same volume")
        #expect(snap?.verdictAtRemoval(path: canonicalLoose, probe: probe) == .onArchiveVolume)
        #expect(snap?.verdict(forPath: "/Volumes/CrucialX10/a.mov") == .clear)
        #expect(snap?.verdict(forPath: "/Users/rickb/Movies/a.mov") == .clear, "the boot disk is not the archive")
        // Even with no disk access at all (the provisional snapshot).
        let early = ArchiveVolumeProtection.provisional(designation: d)
        #expect(early?.verdict(forPath: canonicalLoose) == .onArchiveVolume)
    }

    /// A symlink / custom-mount spelling that cannot be resolved right now
    /// (the alias is dangling, the custom mount is unmounted) but whose
    /// recorded UUID is NOT the boot disk's: it is an external volume, and
    /// wherever that UUID is mounted, the whole volume is protected.
    @Test func aliasSpelledDesignationWithAnExternalUUIDProtectsThatVolumeWhereverItIsMounted() {
        let d = MasterArchiveDesignation(targetPath: "/Users/rickb/Links/FamilyArchive-test-1642",
                                         rootPath: "/Users/rickb/Links/FamilyArchive-test-1642/Breen_Family_Archive",
                                         volumeUUID: "UUID-ARCH")
        let probe = uuidProbe(["/Volumes/FamilyArchive": "UUID-ARCH", "/Volumes/CrucialX10": "UUID-X10"])
        let snap = ArchiveVolumeProtection.make(designation: d,
                                                mountedRoots: { ["/Volumes/FamilyArchive", "/Volumes/CrucialX10"] },
                                                probe: probe,
                                                // Dangling alias: its directory reads as the boot disk.
                                                identity: identityProbe([:]), networkRoots: { [] })
        #expect(snap?.verdict(forPath: canonicalLoose) == .onArchiveVolume, "found by UUID at its canonical mount")
        #expect(snap?.verdictAtRemoval(path: "/Volumes/FamilyArchive/loose.mov", probe: probe) == .onArchiveVolume,
                "the removal-time UUID check is consulted")
        #expect(snap?.verdict(forPath: "/Volumes/CrucialX10/a.mov") == .clear)
        #expect(snap?.verdictAtRemoval(path: "/Users/rickb/Movies/a.mov", probe: probe) == .clear,
                "the boot disk (UUID BOOT) is never this archive")
        #expect(snap?.verdict(forPath: "/Users/rickb/Links/FamilyArchive-test-1642/x.mov") == .onArchiveVolume,
                "the designated spelling itself stays protected")
    }

    /// QA on #1642 (MAJOR): APFS is case-insensitive, so these spellings
    /// ARE the archive volume — and Remove / Tidy / purge ask only this
    /// string verdict (no removal-time re-check).
    @Test func caseFoldedSpellingsAreTheArchiveVolume() {
        let d = MasterArchiveDesignation(targetPath: "/Volumes/FamilyArchive", rootPath: "/Volumes/FamilyArchive/Breen_Family_Archive", volumeUUID: "UUID-ARCH")
        let snap = ArchiveVolumeProtection.make(designation: d, mountedRoots: { ["/Volumes/FamilyArchive"] },
            probe: uuidProbe(["/Volumes/FamilyArchive": "UUID-ARCH"]),
            identity: { $0.hasPrefix("/Volumes/FamilyArchive") ? MountIdentity(resolvedPath: $0, mountPoint: "/Volumes/FamilyArchive") : nil },
            networkRoots: { [] })
        #expect(snap?.verdict(forPath: "/volumes/familyarchive/MoviesExpansion/a.mov") == .onArchiveVolume)
        #expect(snap?.verdict(forPath: "/VOLUMES/FamilyArchive/a.mov") == .onArchiveVolume)
        #expect(snap?.verdict(forPath: "/system/volumes/data/Volumes/FamilyArchive/a.mov") == .onArchiveVolume)
        #expect(snap?.verdict(forPath: "/volumes/CrucialX10/a.mov") == .clear, "another drive, however spelled, is still clear")
    }

    /// QA on #1642 (MINOR): a designation outside /Volumes that does not
    /// resolve and has no UUID could be an unmounted custom mount — never
    /// assume boot folder (a held/provisional copy would clear /Volumes).
    @Test func unresolvableNoUUIDDesignationIsNotABootFolder() {
        let d = MasterArchiveDesignation(targetPath: "/Users/rickb/FA-1642", rootPath: "/Users/rickb/FA-1642/Breen_Family_Archive", volumeUUID: nil)
        let built = ArchiveVolumeProtection.make(designation: d, mountedRoots: { [] }, probe: { _ in nil }, identity: { _ in nil }, networkRoots: { [] })
        let p = ArchiveVolumeProtection.provisional(designation: d, previous: built)
        #expect(p?.verdict(forPath: "/Volumes/FamilyArchive/a.mov") != .clear)
        #expect(built?.verdict(forPath: "/Users/rickb/FA-1642/x.mov") == .onArchiveVolume, "its own spelling stays protected")
    }

    /// The legitimate boot-disk case is unchanged: a folder on the boot
    /// disk protects that FOLDER, never the whole boot disk.
    @Test func bootDiskFolderDesignationStillProtectsOnlyItsFolder() {
        let d = MasterArchiveDesignation(targetPath: "/Users/rickb/ArchiveHere-test-1642",
                                         rootPath: "/Users/rickb/ArchiveHere-test-1642/Breen_Family_Archive",
                                         volumeUUID: "BOOT")
        let probe = uuidProbe([:])
        let snap = ArchiveVolumeProtection.make(designation: d, mountedRoots: { ["/Volumes/CrucialX10"] }, probe: probe,
                                                identity: identityProbe([:]), networkRoots: { [] })
        #expect(snap?.verdict(forPath: "/Users/rickb/ArchiveHere-test-1642/MoviesExpansion/a.mov") == .onArchiveVolume)
        #expect(snap?.verdict(forPath: "/Users/rickb/Movies/a.mov") == .clear)
        #expect(snap?.verdictAtRemoval(path: "/Users/rickb/Movies/a.mov", probe: probe) == .clear,
                "the shared boot UUID must not protect the whole boot disk")
        #expect(snap?.verdict(forPath: "/Volumes/CrucialX10/a.mov") == .clear)
    }
}

// MARK: - P2: catalog removal while the archive's identity is unresolved

@Suite("Archive volume protection — codex #1642 catalog removal waits for identity", .serialized)
@MainActor
struct ArchiveVolumeProtectionCodex1642CatalogRemovalTests {

    /// FamilyArchive was just renamed / reconnected as "FamilyArchive 1";
    /// the snapshot is still provisional. Remove, Remove from Catalog and
    /// Tidy Catalog must write NOTHING for a row they cannot prove is off
    /// the archive, and say it is transient.
    @Test func provisionalSnapshotRefusesCatalogRemovalWithNoWrites() async {
        let model = isolatedModel()
        model.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/FamilyArchive",
                                                       rootPath: "/Volumes/FamilyArchive/Breen_Family_Archive",
                                                       volumeUUID: "UUID-ARCH")
        let renamed = record("/Volumes/FamilyArchive 1/MoviesExpansion/a.mov")
        let renamed2 = record("/Volumes/FamilyArchive 1/MoviesExpansion/b.mov")
        let renamed3 = record("/Volumes/FamilyArchive 1/MoviesExpansion/c.mov")
        model.records = [renamed, renamed2, renamed3]
        #expect(model.isArchiveVolumeSnapshotFresh == false, "fixture: provisional")
        #expect(model.purgeRecords(ids: [renamed.id]) == 0)
        #expect(model.removeFromCatalog(recordIDs: [renamed2.id]) == 0)
        var plan = VideoScanModel.TidyCatalogPlan()
        plan.rows = [.init(id: renamed3.id, filename: renamed3.filename,
                           fullPath: renamed3.fullPath, sizeBytes: 1, reason: .stillImage)]
        #expect(model.applyTidyCatalog(plan) == 0)
        for r in [renamed, renamed2, renamed3] {
            #expect(r.purgedAt == nil && r.setAsideReason == nil, "no catalog write for \(r.fullPath)")
        }
        #expect(model.lastPurgedBatch == nil && model.lastTidyBatch == nil, "no undo batch armed")
        let text = await consoleText(model)
        #expect(text.contains("try again in a moment"), "the refusal says it is transient — \(text)")
    }

    /// Once the snapshot is built: the renamed archive is refused for good
    /// (by UUID), and a row proven to be on another drive is removable.
    @Test func freshSnapshotRefusesTheRenamedArchiveAndAllowsAnotherDrive() async {
        let model = isolatedModel()
        model.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/FamilyArchive",
                                                       rootPath: "/Volumes/FamilyArchive/Breen_Family_Archive",
                                                       volumeUUID: "UUID-ARCH")
        let renamed = record("/Volumes/FamilyArchive 1/MoviesExpansion/a.mov")
        let other = record("/Volumes/CrucialX10/b.mov")
        model.records = [renamed, other]
        await ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({ ["/Volumes/FamilyArchive 1", "/Volumes/CrucialX10"] }) {
            await MasterArchiveDesignation.$volumeUUIDProbe.withValue(
                uuidProbe(["/Volumes/FamilyArchive 1": "UUID-ARCH", "/Volumes/CrucialX10": "UUID-X10"])) {
                await model.refreshArchiveVolumeSnapshot(force: true)
                #expect(model.purgeRecords(ids: [renamed.id, other.id]) == 1)
            }
        }
        #expect(renamed.purgedAt == nil, "the renamed FamilyArchive keeps its row")
        #expect(other.purgedAt != nil, "a drive proven not to be the archive is removable")
    }
}

// MARK: - P1 with the mount identity resolved (realpath + statfs seams)

/// A fake mount table for the identity seam: longest mapped prefix wins;
/// the boot disk ("/Users/…") answers with mount "/System/Volumes/Data".
private func identityProbe(_ links: [String: (resolved: String, mount: String)])
    -> @Sendable (String) -> MountIdentity? {
    { path in
        let best = links.keys.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        if let best, let hit = links[best] {
            return MountIdentity(resolvedPath: hit.resolved + String(path.dropFirst(best.count)), mountPoint: hit.mount)
        }
        if path.hasPrefix("/Users/") { return MountIdentity(resolvedPath: path, mountPoint: "/System/Volumes/Data") }
        return nil
    }
}

@Suite("Archive volume protection — codex #1642 resolved aliases", .serialized)
struct ArchiveVolumeProtectionCodex1642ResolvedAliasTests {

    private let canonicalLoose = "/Volumes/FamilyArchive/MoviesExpansion/a.mov"
    private let probe = uuidProbe(["/Volumes/FamilyArchive": "UUID-ARCH", "/Volumes/CrucialX10": "UUID-X10",
                                   "/Users/rickb/mnt/FA": "UUID-ARCH"])

    @Test func symlinkDesignationIsTheExternalVolumeItPointsAt() {
        let d = MasterArchiveDesignation(targetPath: "/Users/rickb/FA-link", rootPath: "/Users/rickb/FA-link/Breen_Family_Archive",
                                         volumeUUID: "UUID-ARCH")
        let ident = identityProbe(["/Users/rickb/FA-link": ("/Volumes/FamilyArchive", "/Volumes/FamilyArchive")])
        let snap = ArchiveVolumeProtection.make(designation: d, mountedRoots: { Issue.record("resolved at its mount: no scan"); return [] },
                                                probe: probe, identity: ident, networkRoots: { [] })
        #expect(snap?.placement == .externalVolume)
        #expect(snap?.isResolved == true)
        #expect(snap?.verdict(forPath: canonicalLoose) == .onArchiveVolume, "the canonical path, by the real mount")
        #expect(snap?.verdict(forPath: "/Users/rickb/FA-link/MoviesExpansion/a.mov") == .onArchiveVolume, "and through the link")
        #expect(snap?.verdict(forPath: "/Volumes/CrucialX10/a.mov") == .clear)
        #expect(snap?.verdictAtRemoval(path: "/Users/rickb/Movies/a.mov", probe: probe, identity: ident) == .clear)
    }

    @Test func customMountPointDesignationProtectsTheVolumeHereAndWhenRemountedUnderVolumes() {
        let d = MasterArchiveDesignation(targetPath: "/Users/rickb/mnt/FA", rootPath: "/Users/rickb/mnt/FA/Breen_Family_Archive",
                                         volumeUUID: "UUID-ARCH")
        // Mounted at the custom mount point.
        let here = ArchiveVolumeProtection.make(
            designation: d, mountedRoots: { [] }, probe: probe,
            identity: identityProbe(["/Users/rickb/mnt/FA": ("/Users/rickb/mnt/FA", "/Users/rickb/mnt/FA")]),
            networkRoots: { [] })
        #expect(here?.placement == .externalVolume)
        #expect(here?.verdict(forPath: "/Users/rickb/mnt/FA/MoviesExpansion/a.mov") == .onArchiveVolume)
        #expect(here?.verdict(forPath: "/Users/rickb/Movies/a.mov") == .clear, "the rest of the boot disk is not the archive")
        #expect(here?.verdictAtRemoval(path: "/Users/rickb/Movies/a.mov", probe: probe,
                                       identity: identityProbe([:])) == .clear)
        // Unmounted there (the empty mount-point directory reads as the
        // boot disk) and remounted at /Volumes/FamilyArchive.
        let remounted = ArchiveVolumeProtection.make(
            designation: d, mountedRoots: { ["/Volumes/FamilyArchive", "/Volumes/CrucialX10"] },
            probe: uuidProbe(["/Volumes/FamilyArchive": "UUID-ARCH", "/Volumes/CrucialX10": "UUID-X10"]),
            identity: identityProbe([:]), networkRoots: { [] })
        #expect(remounted?.placement == .externalVolume, "UUID is not the boot disk's → external")
        #expect(remounted?.verdict(forPath: canonicalLoose) == .onArchiveVolume)
        #expect(remounted?.verdict(forPath: "/Volumes/CrucialX10/a.mov") == .clear)
    }

    /// Real filesystem: a boot-disk folder designated THROUGH a symlink is
    /// still a boot folder (production realpath + statfs), and protects
    /// the real folder under both spellings — never the rest of the disk.
    @Test func realSymlinkToABootFolderProtectsTheFolderOnly() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_arch1642_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let real = base.appendingPathComponent("RealArchive", isDirectory: true)
        let link = base.appendingPathComponent("LinkArchive")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let bootUUID = MasterArchiveDesignation.volumeUUID(forPath: "/")
        let d = MasterArchiveDesignation(targetPath: link.path, rootPath: link.path + "/Breen_Family_Archive",
                                         volumeUUID: MasterArchiveDesignation.volumeUUID(forPath: real.path))
        let snap = try #require(ArchiveVolumeProtection.make(designation: d, mountedRoots: { [] }, networkRoots: { [] }))
        #expect(bootUUID != nil && snap.placement == .bootFolder)
        let realPath = ArchiveVolumeProtection.liveMountIdentity(real.path)!.resolvedPath
        #expect(snap.verdict(forPath: realPath + "/MoviesExpansion/a.mov") == .onArchiveVolume, "the real folder")
        #expect(snap.verdict(forPath: link.path + "/MoviesExpansion/a.mov") == .onArchiveVolume, "the link spelling")
        let sibling = base.appendingPathComponent("test_sibling.mov")
        FileManager.default.createFile(atPath: sibling.path, contents: Data([1]))
        #expect(snap.verdictAtRemoval(path: sibling.path, probe: { MasterArchiveDesignation.volumeUUID(forPath: $0) }) == .clear,
                "the boot disk's shared UUID must not protect a sibling")
        // Designation canonicalization at Initialize resolves the link.
        #expect(VideoScanModel.canonicalDesignationPath(link) == ArchiveVolumeProtection.canonical(realPath))
    }

    @Test func designationPathIsCanonicalizedAtInitialize() {
        #expect(VideoScanModel.canonicalDesignationPath(URL(fileURLWithPath: "/System/Volumes/Data/Volumes/NoSuchArchive-1642"))
                == "/Volumes/NoSuchArchive-1642", "the firmlink spelling folds back even when not mounted")
        ArchiveVolumeProtection.$mountIdentityProbe.withValue(
            identityProbe(["/Users/rickb/FA-link": ("/Volumes/FamilyArchive", "/Volumes/FamilyArchive")])) {
            #expect(VideoScanModel.canonicalDesignationPath(URL(fileURLWithPath: "/Users/rickb/FA-link")) == "/Volumes/FamilyArchive")
        }
    }

    /// Scan-time spellings (codex #1642 "final alias protection" for the
    /// catalog verbs): a row spelled through the firmlink, or under a scan
    /// target whose realpath lands on the archive's mount, is refused by
    /// the per-record STRING verdict — no per-row disk read.
    @Test func firmlinkSpelledRowIsTheArchiveVolume() {
        let d = MasterArchiveDesignation(targetPath: "/Volumes/FamilyArchive",
                                         rootPath: "/Volumes/FamilyArchive/Breen_Family_Archive", volumeUUID: nil)
        let snap = ArchiveVolumeProtection.provisional(designation: d)
        #expect(snap?.verdict(forPath: "/System/Volumes/Data/Volumes/FamilyArchive/MoviesExpansion/a.mov") == .onArchiveVolume)
    }
}

@Suite("Archive volume protection — codex #1642 scan-target aliases", .serialized)
@MainActor
struct ArchiveVolumeProtectionCodex1642ScanAliasTests {

    @Test func catalogRemovalRefusesRowsUnderAScanTargetThatIsAnAliasOfTheArchive() async {
        let model = isolatedModel()
        model.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/FamilyArchive",
                                                       rootPath: "/Volumes/FamilyArchive/Breen_Family_Archive",
                                                       volumeUUID: "UUID-ARCH")
        model.scanTargets = [CatalogScanTarget(searchPath: "/Users/rickb/FA-Movies-link"),
                             CatalogScanTarget(searchPath: "/Users/rickb/Movies")]
        let viaLink = record("/Users/rickb/FA-Movies-link/1994 Christmas.mov")
        let onBoot = record("/Users/rickb/Movies/a.mov")
        model.records = [viaLink, onBoot]
        let ident = identityProbe(["/Users/rickb/FA-Movies-link": ("/Volumes/FamilyArchive/MoviesExpansion", "/Volumes/FamilyArchive"),
                                   "/Volumes/FamilyArchive": ("/Volumes/FamilyArchive", "/Volumes/FamilyArchive")])
        await ArchiveVolumeProtection.$mountIdentityProbe.withValue(ident) {
            await ArchiveVolumeProtection.$networkMountRootsProbe.withValue({ [] }) {
                await ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({ ["/Volumes/FamilyArchive"] }) {
                    await MasterArchiveDesignation.$volumeUUIDProbe.withValue(uuidProbe(["/Volumes/FamilyArchive": "UUID-ARCH"])) {
                        await model.refreshArchiveVolumeSnapshot(force: true)
                        #expect(model.isArchiveVolumeSnapshotFresh)
                        #expect(model.purgeRecords(ids: [viaLink.id, onBoot.id]) == 1)
                        #expect(model.removeFromCatalog(recordIDs: [viaLink.id]) == 0)
                        // A new scan target makes the snapshot stale (it may be another alias).
                        model.scanTargets.append(CatalogScanTarget(searchPath: "/Users/rickb/Other"))
                        #expect(model.isArchiveVolumeSnapshotFresh == false)
                        #expect(model.archiveVolumeProtection()?.verdict(forPath: viaLink.fullPath) == .onArchiveVolume,
                                "the provisional snapshot keeps the proven alias")
                    }
                }
            }
        }
        #expect(viaLink.purgedAt == nil && viaLink.setAsideReason == nil, "the aliased FamilyArchive row stays")
        #expect(onBoot.purgedAt != nil, "a boot-disk row is still removable")
    }
}

@Suite("Archive volume protection — codex #1642 unknown placement until built", .serialized)
@MainActor
struct ArchiveVolumeProtectionCodex1642UnknownPlacementTests {

    /// A non-/Volumes designation loaded from the catalog (no Initialize
    /// this session) could be a boot folder OR a custom mount: until the
    /// off-main build says which, /Volumes rows are a transient refusal
    /// for catalog removal; once built as a boot folder they are removable.
    @Test func loadedNonVolumesDesignationWaitsForTheBuildThenAllows() async {
        let model = isolatedModel()
        model.masterArchive = MasterArchiveDesignation(targetPath: "/Users/rickb/ArchiveHere-test-1642",
                                                       rootPath: "/Users/rickb/ArchiveHere-test-1642/Breen_Family_Archive",
                                                       volumeUUID: "BOOT")
        let row = record("/Volumes/CrucialX10/a.mov")
        model.records = [row]
        await ArchiveVolumeProtection.$mountIdentityProbe.withValue(identityProbe([:])) {
            await ArchiveVolumeProtection.$mountedVolumeRootsProbe.withValue({ ["/Volumes/CrucialX10"] }) {
                await MasterArchiveDesignation.$volumeUUIDProbe.withValue(uuidProbe(["/Volumes/CrucialX10": "UUID-X10"])) {
                    #expect(model.archiveVolumeProtection()?.placement == .unknown)
                    #expect(model.purgeRecords(ids: [row.id]) == 0, "transient while unknown")
                    #expect(row.purgedAt == nil)
                    await model.refreshArchiveVolumeSnapshot(force: true)
                    #expect(model.archiveVolumeProtection()?.placement == .bootFolder)
                    #expect(model.purgeRecords(ids: [row.id]) == 1, "a boot-folder archive never blocks another drive")
                }
            }
        }
        #expect(row.purgedAt != nil)
    }

    /// Initialize proves the placement on the spot, so the very first
    /// (provisional) answer for a boot-folder archive is already exact.
    @Test func initializeOfABootFolderIsExactFromTheFirstMoment() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("arch1642")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        #expect(model.isArchiveVolumeSnapshotFresh == false, "fixture: nothing built yet")
        let snap = model.archiveVolumeProtection()
        #expect(snap?.placement == .bootFolder)
        #expect(snap?.verdict(forPath: "/Volumes/CrucialX10/a.mov") == .clear)
        #expect(snap?.verdict(forPath: sb.archiveVolume.appendingPathComponent("MoviesExpansion/a.mov").path) == .onArchiveVolume)
    }
}
