// ArchiveVolumeProtectionMakeCharacterizationTests.swift
// CHARACTERIZATION ONLY (refactor/archive-volume-protection-make, 2026-11-08):
// pins the WHOLE snapshot `ArchiveVolumeProtection.make` builds — every
// field, alias order included — and which disks it reads, for each shape a
// designation can take, so splitting `make` into its concepts (boot folder
// or external volume → the archive's spellings → find it by UUID among the
// mounted volumes → scan targets that land on it) can be shown to change
// nothing. Written and seen green on the unchanged code first.
//
// The probes record their calls: "the usual case costs ONE read", "network
// mounts are never read" and "a volume already known is not read again" are
// behaviour too (a hung SMB server once beachballed the app, GH #104).
//
// Isolation: synthetic paths only; every disk read is an injected closure.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("ArchiveVolumeProtection.make — characterization (every placement, every field)")
struct ArchiveVolumeProtectionMakeCharacterizationTests {

    /// Records every probe call (the closures are non-escaping, but a class
    /// keeps the test bodies short).
    final class Disk {
        var uuids: [String: String]
        var identities: [String: MountIdentity]
        var mounted: [String]
        var network: [String]
        var uuidReads: [String] = []
        var identityReads: [String] = []
        var mountedReads = 0
        var networkReads = 0

        init(uuids: [String: String] = [:], identities: [String: (String, String)] = [:],
             mounted: [String] = [], network: [String] = []) {
            self.uuids = uuids
            self.identities = identities.mapValues { MountIdentity(resolvedPath: $0.0, mountPoint: $0.1) }
            self.mounted = mounted
            self.network = network
        }

        func make(_ d: MasterArchiveDesignation?, aliases: [String] = []) -> ArchiveVolumeProtection? {
            ArchiveVolumeProtection.make(designation: d, aliasCandidates: aliases,
                                         mountedRoots: { self.mountedReads += 1; return self.mounted },
                                         probe: { self.uuidReads.append($0); return self.uuids[$0] },
                                         identity: { self.identityReads.append($0); return self.identities[$0] },
                                         networkRoots: { self.networkReads += 1; return self.network })
        }
    }

    static func designation(_ path: String, uuid: String?) -> MasterArchiveDesignation {
        MasterArchiveDesignation(targetPath: path, rootPath: path + "/Breen_Family_Archive", volumeUUID: uuid)
    }

    static func snapshot(label: String, placement: ArchiveVolumeProtection.Placement,
                         roots: Set<String> = [], aliases: [String] = [], folders: [String] = [],
                         uuid: String?, resolved: Bool, others: Set<String> = []) -> ArchiveVolumeProtection {
        ArchiveVolumeProtection(label: label, placement: placement, archiveRoots: roots, aliasRoots: aliases,
                                protectedFolders: folders, expectedUUID: uuid, isResolved: resolved,
                                provenOtherRoots: others, isProvisional: false)
    }

    @Test func noDesignationIsNoSnapshotAndNoDiskRead() {
        let disk = Disk()
        #expect(disk.make(nil) == nil)
        #expect(disk.uuidReads.isEmpty && disk.identityReads.isEmpty && disk.mountedReads == 0 && disk.networkReads == 0)
    }

    // MARK: External volume, mounted where designated

    @Test func theUsualCaseCostsOneUUIDReadAndResolvesScanTargetAliases() {
        let disk = Disk(uuids: ["/Volumes/FamilyArchive": "U-A"],
                        identities: ["/Volumes/FamilyArchive": ("/Volumes/FamilyArchive", "/Volumes/FamilyArchive"),
                                     "/Users/rickb/Scan": ("/Users/rickb/Scan", "/"),
                                     "/Links/fa": ("/Volumes/FamilyArchive/Movies", "/Volumes/FamilyArchive"),
                                     "/Links/gone": ("/Links/gone", "/")],
                        mounted: ["/Volumes/CrucialX10"], network: ["/Volumes/NAS"])
        let snap = disk.make(Self.designation("/Volumes/FamilyArchive", uuid: "U-A"),
                             aliases: ["/Users/rickb/Scan", "/Volumes/FamilyArchive/Movies", "/Links/fa",
                                       "/Links/fa/sub", "/", "", "/Volumes/NAS/share", "/Links/gone", "/Links/missing"])
        #expect(snap == Self.snapshot(label: "FamilyArchive", placement: .externalVolume,
                                      roots: ["/volumes/familyarchive"], aliases: ["/links/fa"],
                                      uuid: "U-A", resolved: true))
        #expect(disk.uuidReads == ["/Volumes/FamilyArchive"], "one read: the designated mount carries the UUID")
        #expect(disk.mountedReads == 0, "no other volume is read")
        #expect(disk.networkReads == 1)
        #expect(disk.identityReads == ["/Volumes/FamilyArchive", "/Users/rickb/Scan", "/Links/fa", "/Links/gone", "/Links/missing"],
                "never a network path, a path already on the archive, the root, or one inside a known alias")
    }

    @Test func theFirmlinkSpellingIsTheCanonicalVolume() {
        let disk = Disk(uuids: ["/Volumes/FamilyArchive": "U-A"],
                        identities: ["/Volumes/FamilyArchive": ("/Volumes/FamilyArchive", "/Volumes/FamilyArchive")])
        let snap = disk.make(Self.designation("/System/Volumes/Data/Volumes/FamilyArchive", uuid: "U-A"))
        #expect(snap == Self.snapshot(label: "FamilyArchive", placement: .externalVolume,
                                      roots: ["/volumes/familyarchive"], uuid: "U-A", resolved: true))
    }

    @Test func aMountedVolumeWithAnotherUUIDIsNotTheArchiveAndTheSearchProvesTheOthers() {
        // Something else is mounted at /Volumes/FamilyArchive: the spelling
        // stays protected (refuse over guess), the search reads the rest.
        let disk = Disk(uuids: ["/Volumes/FamilyArchive": "U-IMPOSTOR", "/Volumes/CrucialX10": "U-X",
                                "/Volumes/FamilyArchive 1": "U-A"],
                        identities: ["/Volumes/FamilyArchive": ("/Volumes/FamilyArchive", "/Volumes/FamilyArchive")],
                        mounted: ["/Volumes/FamilyArchive", "/Volumes/CrucialX10", "/Volumes/FamilyArchive 1"])
        let snap = disk.make(Self.designation("/Volumes/FamilyArchive", uuid: "U-A"))
        #expect(snap == Self.snapshot(label: "FamilyArchive", placement: .externalVolume,
                                      roots: ["/volumes/familyarchive", "/volumes/familyarchive 1"],
                                      uuid: "U-A", resolved: true, others: ["/volumes/crucialx10"]))
        #expect(disk.uuidReads == ["/Volumes/FamilyArchive", "/Volumes/CrucialX10", "/Volumes/FamilyArchive 1"],
                "the designated mount is read once, never again in the search")
    }

    // MARK: External volume, renamed / remounted / offline

    @Test func aRenamedArchiveIsFoundByUUIDAmongTheMountedVolumes() {
        let disk = Disk(uuids: ["/Volumes/CrucialX10": "U-X", "/Volumes/FamilyArchive 1": "U-A"],
                        mounted: ["/", "/Volumes/CrucialX10", "/Volumes/FamilyArchive 1", "/Volumes/NoUUID",
                                  "/System/Volumes/Data", "/Volumes/CrucialX10/"])
        let snap = disk.make(Self.designation("/Volumes/FamilyArchive", uuid: "U-A"), aliases: ["/Links/x"])
        #expect(snap == Self.snapshot(label: "FamilyArchive", placement: .externalVolume,
                                      roots: ["/volumes/familyarchive", "/volumes/familyarchive 1"],
                                      uuid: "U-A", resolved: true, others: ["/volumes/crucialx10"]))
        #expect(disk.uuidReads == ["/Volumes/FamilyArchive", "/Volumes/CrucialX10", "/Volumes/FamilyArchive 1",
                                   "/Volumes/NoUUID", "/Volumes/CrucialX10"],
                "the spelled root, then each mounted non-boot volume")
        #expect(disk.mountedReads == 1 && disk.networkReads == 1)
        #expect(disk.identityReads == ["/Volumes/FamilyArchive", "/Links/x"])
    }

    @Test func anOfflineArchiveIsUnresolvedAndReadsNoScanTarget() {
        let disk = Disk(uuids: ["/Volumes/CrucialX10": "U-X"],
                        mounted: ["/Volumes/FamilyArchive", "/Volumes/CrucialX10", "/Volumes/NoUUID"])
        let snap = disk.make(Self.designation("/Volumes/FamilyArchive", uuid: "U-A"), aliases: ["/Links/x"])
        #expect(snap == Self.snapshot(label: "FamilyArchive", placement: .externalVolume,
                                      roots: ["/volumes/familyarchive"], uuid: "U-A", resolved: false,
                                      others: ["/volumes/crucialx10"]))
        #expect(disk.uuidReads == ["/Volumes/FamilyArchive", "/Volumes/CrucialX10", "/Volumes/NoUUID"],
                "the designated root is not read twice")
        #expect(disk.networkReads == 0 && disk.identityReads == ["/Volumes/FamilyArchive"],
                "nothing is proven to be the archive, so no scan target is resolved")
    }

    @Test func aLeftoverDirectoryOfAnUnmountedVolumeIsNotTheArchive() {
        // /Volumes/FamilyArchive exists as an empty folder on the boot disk.
        let disk = Disk(uuids: ["/Volumes/FamilyArchive": "U-BOOT", "/": "U-BOOT"],
                        identities: ["/Volumes/FamilyArchive": ("/Volumes/FamilyArchive", "/")],
                        mounted: ["/Volumes/CrucialX10"])
        let snap = disk.make(Self.designation("/Volumes/FamilyArchive", uuid: "U-A"))
        #expect(snap == Self.snapshot(label: "FamilyArchive", placement: .externalVolume,
                                      roots: ["/volumes/familyarchive"], uuid: "U-A", resolved: false))
        #expect(disk.uuidReads == ["/Volumes/FamilyArchive", "/Volumes/CrucialX10"])
    }

    // MARK: External volume without a recorded UUID

    @Test func noRecordedUUIDReadsTheMountsAndIsResolvedByPath() {
        let read = Disk(uuids: ["/Volumes/Scratch": "U-S"],
                        identities: ["/Volumes/Scratch": ("/Volumes/Scratch", "/Volumes/Scratch")])
        #expect(read.make(Self.designation("/Volumes/Scratch", uuid: nil))
                == Self.snapshot(label: "Scratch", placement: .externalVolume, roots: ["/volumes/scratch"],
                                 uuid: "U-S", resolved: true))
        #expect(read.uuidReads == ["/Volumes/Scratch", "/Volumes/Scratch"], "once for `expected`, once to compare")

        let unreadable = Disk(identities: ["/Volumes/Scratch": ("/Volumes/Scratch", "/Volumes/Scratch")])
        #expect(unreadable.make(Self.designation("/Volumes/Scratch", uuid: nil))
                == Self.snapshot(label: "Scratch", placement: .externalVolume, roots: ["/volumes/scratch"],
                                 uuid: nil, resolved: true))
        #expect(unreadable.mountedReads == 0)

        let absent = Disk(mounted: ["/Volumes/CrucialX10"])
        #expect(absent.make(Self.designation("/Volumes/Scratch", uuid: nil))
                == Self.snapshot(label: "Scratch", placement: .externalVolume, roots: ["/volumes/scratch"],
                                 uuid: nil, resolved: true))
        #expect(absent.uuidReads.isEmpty && absent.mountedReads == 0)
    }

    // MARK: External volume spelled outside /Volumes

    @Test func aCustomMountPointIsAnAliasRootLabelledByTheMount() {
        let disk = Disk(uuids: ["/mnt/archive": "U-A"],
                        identities: ["/mnt/archive": ("/mnt/archive", "/mnt/archive")])
        let snap = disk.make(Self.designation("/mnt/archive", uuid: "U-A"))
        #expect(snap == Self.snapshot(label: "archive", placement: .externalVolume, aliases: ["/mnt/archive"],
                                      uuid: "U-A", resolved: true))
    }

    @Test func aSymlinkIntoTheVolumeProtectsBothSpellings() {
        let disk = Disk(uuids: ["/Volumes/FamilyArchive": "U-A"],
                        identities: ["/Users/rickb/Links/FA": ("/Volumes/FamilyArchive", "/Volumes/FamilyArchive")])
        let snap = disk.make(Self.designation("/Users/rickb/Links/FA", uuid: "U-A"))
        #expect(snap == Self.snapshot(label: "FamilyArchive", placement: .externalVolume,
                                      roots: ["/volumes/familyarchive"], aliases: ["/users/rickb/links/fa"],
                                      uuid: "U-A", resolved: true))
    }

    @Test func aDanglingAliasWithAnExternalUUIDIsAnExternalVolume() {
        let disk = Disk(uuids: ["/": "U-BOOT", "/Volumes/FamilyArchive": "U-A", "/Volumes/CrucialX10": "U-X"],
                        mounted: ["/Volumes/CrucialX10", "/Volumes/FamilyArchive"])
        let snap = disk.make(Self.designation("/Users/rickb/Links/FA", uuid: "U-A"))
        #expect(snap == Self.snapshot(label: "FA", placement: .externalVolume,
                                      roots: ["/volumes/familyarchive"], aliases: ["/users/rickb/links/fa"],
                                      uuid: "U-A", resolved: true, others: ["/volumes/crucialx10"]))
        #expect(disk.uuidReads == ["/", "/Volumes/CrucialX10", "/Volumes/FamilyArchive"])
    }

    @Test func anUnmountedCustomMountsLeftoverDirectoryWithAnExternalUUIDIsExternal() {
        let disk = Disk(uuids: ["/": "U-BOOT", "/Volumes/CrucialX10": "U-X"],
                        identities: ["/mnt/archive": ("/mnt/archive", "/")],
                        mounted: ["/Volumes/CrucialX10"])
        let snap = disk.make(Self.designation("/mnt/archive", uuid: "U-EXT"), aliases: ["/Links/x"])
        #expect(snap == Self.snapshot(label: "archive", placement: .externalVolume, aliases: ["/mnt/archive"],
                                      uuid: "U-EXT", resolved: false, others: ["/volumes/crucialx10"]))
        #expect(disk.networkReads == 0)
    }

    @Test func anUnreadableBootUUIDTrustsTheMount() {
        // Mounted on the boot disk, boot UUID unreadable → a boot folder.
        let onBoot = Disk(identities: ["/Users/rickb/Archive": ("/Users/rickb/Archive", "/")])
        #expect(onBoot.make(Self.designation("/Users/rickb/Archive", uuid: "U-A"))
                == Self.snapshot(label: "Archive", placement: .bootFolder, folders: ["/users/rickb/archive"],
                                 uuid: "U-A", resolved: true))
        // Not resolvable at all → external.
        let gone = Disk(mounted: [])
        #expect(gone.make(Self.designation("/Users/rickb/Archive", uuid: "U-A"))
                == Self.snapshot(label: "Archive", placement: .externalVolume, aliases: ["/users/rickb/archive"],
                                 uuid: "U-A", resolved: false))
    }

    // MARK: Boot folder and unknown

    @Test func theBootDisksOwnUUIDMakesAFolderArchive() {
        let disk = Disk(uuids: ["/": "U-BOOT"],
                        identities: ["/Users/rickb/Archive": ("/Users/rickb/Archive", "/"),
                                     "/Users/rickb/Archive/Sub": ("/Users/rickb/Archive/Sub", "/")])
        let snap = disk.make(Self.designation("/Users/rickb/Archive", uuid: "U-BOOT"), aliases: ["/Users/rickb/Archive/Sub"])
        #expect(snap == Self.snapshot(label: "Archive", placement: .bootFolder, folders: ["/users/rickb/archive"],
                                      uuid: "U-BOOT", resolved: true))
        #expect(disk.mountedReads == 0)
    }

    @Test func noUUIDOnTheBootDiskIsAFolderArchive() {
        let disk = Disk(identities: ["/Users/rickb/Archive": ("/Users/rickb/Archive", "/")])
        #expect(disk.make(Self.designation("/Users/rickb/Archive", uuid: nil))
                == Self.snapshot(label: "Archive", placement: .bootFolder, folders: ["/users/rickb/archive"],
                                 uuid: nil, resolved: true))
        #expect(disk.uuidReads.isEmpty)
    }

    @Test func noUUIDAndNothingThereIsUnknownAndProtectsTheSpelling() {
        let disk = Disk(mounted: ["/Volumes/CrucialX10"])
        #expect(disk.make(Self.designation("/Users/rickb/Gone/", uuid: nil))
                == Self.snapshot(label: "Gone", placement: .unknown, folders: ["/users/rickb/gone"],
                                 uuid: nil, resolved: false))
        #expect(disk.uuidReads.isEmpty && disk.mountedReads == 0 && disk.networkReads == 0)
    }
}
