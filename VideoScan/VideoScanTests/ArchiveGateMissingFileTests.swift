// ArchiveGateMissingFileTests.swift
//
// Rick, 2026-10-11 13:27:54 — Triage → Delete Confirmed Junk: moved 0 ·
// held 38 · missing 0. Every row said "FamilyArchive, the Master Archive
// volume, is not connected — cannot prove this drive is not it", while
// FamilyArchive WAS mounted. The 38 files were Chrome cache files under
// /Volumes/Projects/osx10.8_backup/rickb/Library/Caches/Google/Chrome/
// Default/Cache/ — that folder, and …/Caches/Google above it, no longer
// existed.
//
// Root cause: `ArchiveVolumeProtection.verdictAtRemoval` (and its twin in
// ReadOnlyVolumeProtection) read the file's own volume UUID — nil for a
// file that is gone — then fell back to the mount identity of the file or
// its PARENT only. Both gone → `.unprovable`, worded "not connected"
// whatever the archive's real state. The junk disk turn asks the gate
// before the existence check (on purpose: a gone ARCHIVE file must never
// be stamped), so the files were held instead of reported missing.
//
// The fix: climb to the nearest EXISTING ancestor (bounded: never above a
// "/Volumes/<name>" root, never above "/", at most 64 levels). Nothing
// below that ancestor exists, so the gone file would live on that
// ancestor's volume — read ITS UUID; then today's rules. And "is not
// connected" only when the archive volume really was not found mounted.
//
// Dimensions: Logic (the verdict table below) · Scale N/A (one climb per
// removal, bounded) · Media matrix N/A (no media opened) · Isolation (a
// fake disk through the seams — nothing reads this Mac's drives; a stale
// designation) · Sensor (Rick's 38-file shape through the junk disk turn).
//
// Suites: ArchiveGateMissingFileTests, ArchiveGateMissingFileSensor

import Foundation
import Testing
@testable import VideoScan

/// A pretend disk: which paths exist, the mounts (longest prefix wins) and
/// their volume UUIDs. Symlinks = an existing path whose real path is
/// elsewhere. (≈ a C++ fake implementing the two probe interfaces.)
private struct FakeDisk: Sendable {
    var existing: Set<String>
    var mounts: [String: String?]          // mount point → UUID (nil = unreadable)
    var links: [String: String] = [:]      // existing path → its real path
    /// Every path `identity` was asked about (to pin the climb's bounds).
    final class Asked: @unchecked Sendable { var paths: [String] = [] }
    let asked = Asked()

    private func mountPoint(of real: String) -> String {
        mounts.keys.filter { $0 == "/" || real == $0 || real.hasPrefix($0 + "/") }.max { $0.count < $1.count } ?? "/"
    }
    func identity(_ p: String) -> MountIdentity? {
        asked.paths.append(p)
        guard existing.contains(p) else { return nil }
        let real = links[p] ?? p
        return MountIdentity(resolvedPath: real, mountPoint: mountPoint(of: real))
    }
    func probe(_ p: String) -> String? {
        guard existing.contains(p) else { return nil }
        let real = links[p] ?? p
        return mounts[mountPoint(of: real)].flatMap { $0 }   // String?? → String?
    }
}

private let archiveUUID = "TEST-ARCH-91D10242"
private let projectsUUID = "TEST-PROJ-0978904A"
private let bootUUID = "TEST-BOOT"
private let cacheDir = "/Volumes/TestProjects/osx10.8_backup/rickb/Library/Caches/Google/Chrome/Default/Cache"
/// 28 of the 38 names from Rick's receipt (2026-10-11_132754_junk.csv) —
/// enough to replay the shape; their bytes are never read.
private let rickNames = ["f_0001ba", "f_0001bc", "f_0001bd", "f_0001be", "f_0002d0", "f_0002d2", "f_0002d3", "f_0002d4",
                         "f_0002d5", "f_00032a", "f_00032b", "f_00055a", "f_00055b", "f_00055c", "f_00055d", "f_00055e",
                         "f_00055f", "f_000242", "f_000243", "f_000244", "f_000245", "f_000246", "f_000247", "f_000248",
                         "f_000250", "f_000324", "f_000325", "f_000326"]

/// Rick's machine at 13:27:54: FamilyArchive mounted (or not), TestProjects
/// mounted, the rickb folder there, the Caches/Google tree gone.
private func rickDisk(archiveMounted: Bool = true, projectsUUIDReadable: Bool = true) -> FakeDisk {
    var existing: Set<String> = ["/", "/Volumes", "/Users", "/Users/test",
                                 "/Volumes/TestProjects", "/Volumes/TestProjects/osx10.8_backup",
                                 "/Volumes/TestProjects/osx10.8_backup/rickb",
                                 "/Volumes/TestProjects/osx10.8_backup/rickb/Library"]
    var mounts: [String: String?] = ["/": bootUUID, "/Volumes/TestProjects": projectsUUIDReadable ? projectsUUID : nil]
    if archiveMounted {
        existing.formUnion(["/Volumes/TestFamilyArchive", "/Volumes/TestFamilyArchive/Test_Family_Archive"])
        mounts["/Volumes/TestFamilyArchive"] = archiveUUID
    }
    return FakeDisk(existing: existing, mounts: mounts)
}

private let designation = MasterArchiveDesignation(targetPath: "/Volumes/TestFamilyArchive",
                                                   rootPath: "/Volumes/TestFamilyArchive/Test_Family_Archive",
                                                   volumeUUID: archiveUUID)

private func protection(_ disk: FakeDisk, designation d: MasterArchiveDesignation = designation) throws -> ArchiveVolumeProtection {
    let mounted = disk.mounts.keys.filter { $0 != "/" }.sorted()
    return try #require(ArchiveVolumeProtection.make(designation: d, mountedRoots: { mounted }, probe: disk.probe,
                                                     identity: disk.identity, networkRoots: { [] }))
}

@Suite("Archive gate — a missing file is judged by its nearest existing folder", .serialized)
struct ArchiveGateMissingFileTests {

    /// THE bug: archive mounted, the file and two folders above it gone, on
    /// a drive that is provably not the archive → clear (then "missing").
    @Test func rickShapeArchiveMountedMissingDeepFileIsClear() throws {
        let disk = rickDisk()
        let p = try protection(disk)
        #expect(p.isResolved, "the fake archive is mounted and found by its UUID")
        #expect(p.verdictAtRemoval(path: cacheDir + "/f_0001ba", probe: disk.probe, identity: disk.identity) == .clear)
    }

    /// The archive unplugged: the nearest existing folder's volume UUID
    /// proves the drive is TestProjects, not the archive.
    @Test func archiveUnpluggedMissingDeepFileOnAProvenOtherDriveIsClear() throws {
        let disk = rickDisk(archiveMounted: false)
        let p = try protection(disk)
        #expect(!p.isResolved)
        #expect(p.verdictAtRemoval(path: cacheDir + "/f_0001ba", probe: disk.probe, identity: disk.identity) == .clear)
    }

    /// Archive unplugged AND the drive's UUID unreadable: nothing proves it
    /// is not the archive (a renamed FamilyArchive) → still refused.
    @Test func archiveUnpluggedAndDriveIdentityUnreadableStaysUnprovable() throws {
        let disk = rickDisk(archiveMounted: false, projectsUUIDReadable: false)
        let p = try protection(disk)
        #expect(p.verdictAtRemoval(path: cacheDir + "/f_0001ba", probe: disk.probe, identity: disk.identity) == .unprovable)
    }

    /// A missing file deep under the archive volume, by its path → refused.
    @Test func missingDeepFileOnTheArchiveVolumeIsRefused() throws {
        let disk = rickDisk()
        let p = try protection(disk)
        for path in ["/Volumes/TestFamilyArchive/Gone/Deeper/a.mov",
                     "/Volumes/TestFamilyArchive/Test_Family_Archive/30_Video/gone/a.mov"] {
            #expect(p.verdictAtRemoval(path: path, probe: disk.probe, identity: disk.identity) == .onArchiveVolume, "\(path)")
        }
    }

    /// Drives swapped under one name: when the snapshot was built,
    /// "TestSwapped" was another drive (proven other); now the archive is
    /// mounted there. A gone file there is found by its surviving folder's UUID.
    @Test func missingDeepFileOnASwappedInArchiveIsRefused() throws {
        var before = rickDisk(archiveMounted: false)
        before.existing.insert("/Volumes/TestSwapped")
        before.mounts["/Volumes/TestSwapped"] = "TEST-OTHER"
        let stale = try protection(before)
        #expect(stale.verdict(forPath: "/Volumes/TestSwapped/x.mov") == .clear, "proven other at build time")
        var now = rickDisk(archiveMounted: false)
        now.existing.formUnion(["/Volumes/TestSwapped", "/Volumes/TestSwapped/Clips"])
        now.mounts["/Volumes/TestSwapped"] = archiveUUID
        #expect(stale.verdictAtRemoval(path: "/Volumes/TestSwapped/Clips/gone/a.mov",
                                       probe: now.probe, identity: now.identity) == .onArchiveVolume)
    }

    /// A gone tree reached through a symlink into the archive → refused as
    /// the archive (the real path of the surviving link + the gone tail).
    @Test func missingDeepFileThroughASymlinkIntoTheArchiveIsRefused() throws {
        var disk = rickDisk()
        disk.existing.insert("/Volumes/TestProjects/osx10.8_backup/rickb/link")
        disk.existing.insert("/Volumes/TestFamilyArchive/Sub")
        disk.links["/Volumes/TestProjects/osx10.8_backup/rickb/link"] = "/Volumes/TestFamilyArchive/Sub"
        let p = try protection(disk)
        let path = "/Volumes/TestProjects/osx10.8_backup/rickb/link/gone/deeper/a.mov"
        #expect(p.verdictAtRemoval(path: path, probe: disk.probe, identity: disk.identity) == .onArchiveVolume)
    }

    /// codex #258 r5-4 kept: the archive at a custom mount whose identity
    /// cannot be read — a deep missing file there is still not cleared.
    @Test func r5DeepMissingFileAtAnUnreadableCustomMountStaysUnprovable() throws {
        let d = MasterArchiveDesignation(targetPath: "/Volumes/TestArchive", rootPath: "/Volumes/TestArchive/Test_Family_Archive",
                                         volumeUUID: "TEST-U")
        let custom: (String) -> MountIdentity? = { p in
            ["/TestCustom", "/TestCustom/clips"].contains(p) ? MountIdentity(resolvedPath: p, mountPoint: "/TestCustom") : nil
        }
        let p = try #require(ArchiveVolumeProtection.make(designation: d, mountedRoots: { ["/TestCustom"] }, probe: { _ in nil },
                                                          identity: custom, networkRoots: { [] }))
        #expect(p.verdictAtRemoval(path: "/TestCustom/clips/gone/deeper/extra.mov", probe: { _ in nil }, identity: custom) == .unprovable)
    }

    /// A gone tree whose survivor is on the boot disk: clear when the
    /// archive is found mounted elsewhere; refused while it is not (the
    /// survivor could be an unplugged custom mount's leftover directory).
    @Test func deepMissingFileOnTheBootDiskDependsOnTheArchiveBeingFound() throws {
        let path = "/Users/test/Library/Caches/gone/deeper/a.mov"
        let mounted = rickDisk()
        let unplugged = rickDisk(archiveMounted: false)
        let bootOnly: (String) -> String? = { _ in nil }    // no UUID read at all: only the mount speaks
        #expect(try protection(mounted).verdictAtRemoval(path: path, probe: bootOnly, identity: mounted.identity) == .clear)
        #expect(try protection(unplugged).verdictAtRemoval(path: path, probe: bootOnly, identity: unplugged.identity) == .unprovable)
        // The boot disk's UUID does NOT prove it (QA r1 on 680157026): a
        // missing component may be a DANGLING symlink into the unplugged
        // archive, which realpath reports exactly like a gone folder.
        #expect(try protection(unplugged).verdictAtRemoval(path: path, probe: unplugged.probe, identity: unplugged.identity) == .unprovable)
    }

    /// The climb is bounded: it never reads "/Volumes" or "/" for a
    /// /Volumes path (that is the boot disk — an unplugged drive's
    /// leftover would read as "not the archive").
    @Test func theClimbStopsAtTheVolumeRoot() throws {
        let disk = rickDisk()
        let p = try protection(disk)
        disk.asked.paths.removeAll()
        let v = p.verdictAtRemoval(path: "/Volumes/TestGhost/a/b/c/d.mov", probe: disk.probe, identity: disk.identity)
        #expect(v == .unprovable)
        #expect(!disk.asked.paths.contains("/Volumes") && !disk.asked.paths.contains("/"), "\(disk.asked.paths)")
        #expect(disk.asked.paths.contains("/Volumes/TestGhost"))
        let found = ArchiveVolumeProtection.nearestExistingAncestor(of: "/" + Array(repeating: "x", count: 500).joined(separator: "/"),
                                                                   identity: { _ in nil })
        #expect(found == nil, "a path that resolves nowhere climbs a bounded number of levels")
    }

    /// Isolation — a stale designation: the drive now named TestFamilyArchive
    /// reads a different UUID (re-formatted / swapped). Its spelling stays
    /// protected; a gone file on another, proven drive is still clear.
    @Test func staleDesignationKeepsTheSpellingProtected() throws {
        var disk = rickDisk()
        disk.mounts["/Volumes/TestFamilyArchive"] = "TEST-SOMETHING-ELSE"
        let p = try protection(disk)
        #expect(!p.isResolved)
        #expect(p.verdictAtRemoval(path: "/Volumes/TestFamilyArchive/gone/a.mov", probe: disk.probe, identity: disk.identity) == .onArchiveVolume)
        #expect(p.verdictAtRemoval(path: cacheDir + "/f_0001ba", probe: disk.probe, identity: disk.identity) == .clear)
    }

    // MARK: Wording

    /// "is not connected" only when the archive really was not found mounted.
    @Test func wordingSaysNotConnectedOnlyWhenTheArchiveIsNotMounted() throws {
        let unplugged = try protection(rickDisk(archiveMounted: false))
        let mounted = try protection(rickDisk())
        let away = VideoScanModel.archiveVolumeUnprovableNote(unplugged)
        let here = VideoScanModel.archiveVolumeUnprovableNote(mounted)
        #expect(away == VideoScanModel.bulkDeleteRefusalNote(.archiveVolumeUnprovable, volume: unplugged.label),
                "the unplugged sentence is unchanged: \(away)")
        #expect(away.contains("is not connected"))
        #expect(!here.contains("not connected"), Comment(rawValue: here))
        #expect(here.contains("is connected") && here.contains("could not read"), Comment(rawValue: here))
        let pending = try #require(ArchiveVolumeProtection.provisional(designation: designation, previous: unplugged))
        #expect(!VideoScanModel.archiveVolumeUnprovableNote(pending).contains("not connected"),
                "while the drive list is re-read nobody knows yet")
    }

    /// The removal-time check (Delete Duplicates, Transcode, Repair) words
    /// it the same way.
    @Test func removalCheckUsesTheSameWording() throws {
        // Mounted archive; a drive where nothing at all can be read.
        let disk = rickDisk()
        let p = try protection(disk)
        let check = ArchiveRemovalCheck(protection: p, probe: { _ in nil }, identity: { _ in nil })
        let note = try #require(check.refusalNote(forPath: "/Volumes/TestOdd/a.mov"))
        #expect(!note.contains("not connected") && note.contains("could not read"), Comment(rawValue: note))
    }
}

@Suite("Archive gate — missing-file sensor (Rick's 2026-10-11 junk run)", .serialized)
struct ArchiveGateMissingFileSensor {

    /// Run one file through the junk lane's disk half, on the fake disk.
    /// The removal seam records an issue: nothing may be moved here.
    private func turn(_ path: String, disk: FakeDisk, protections: JunkTurnProtections) -> VideoScanModel.JunkFileOutcome {
        let t = JunkDiskTurn(mode: .removeThroughTestSeam({ url in Issue.record("moved \(url.path)") }),
                             uuidProbe: { disk.probe($0) }, beforeRemoval: nil,
                             remove: { url in Issue.record("moved \(url.path)") })
        return ArchiveVolumeProtection.$mountIdentityProbe.withValue({ disk.identity($0) }) {
            t.run(path: path, protections: protections, catalogBytes: 1)
        }
    }

    /// Replay: every file missing, the archive mounted → every outcome
    /// `.missing`, none held, none moved.
    @Test func rickShapeEveryFileIsMissingNotHeld() throws {
        let disk = rickDisk()
        let protections = JunkTurnProtections(archiveVolume: try protection(disk), readOnlyVolumes: .none)
        var kinds: [VideoScanModel.JunkFileOutcome.Kind: Int] = [:]
        for name in rickNames {
            let outcome = turn(cacheDir + "/" + name, disk: disk, protections: protections)
            kinds[outcome.kind, default: 0] += 1
            if case .held(let why) = outcome { Issue.record("held: \(why)") }
        }
        #expect(kinds == [.missing: rickNames.count], "\(kinds)")
    }

    /// The same shape with a drive marked Read only elsewhere: the
    /// read-only gate must not hold them either (same climb).
    @Test func rickShapeWithAReadOnlyMarkIsStillMissing() throws {
        var disk = rickDisk()
        disk.existing.insert("/Volumes/TestSanDisk")
        disk.mounts["/Volumes/TestSanDisk"] = "TEST-RO"
        let marks = [ReadOnlyVolumeProtection.Mark(searchPath: "/Volumes/TestSanDisk", volumeUUID: "TEST-RO")]
        let readOnly = ReadOnlyVolumeProtection.make(marks: marks, mountedRoots: { ["/Volumes/TestSanDisk", "/Volumes/TestProjects"] },
                                                     probe: disk.probe, identity: disk.identity, networkRoots: { [] })
        let protections = JunkTurnProtections(archiveVolume: try protection(disk), readOnlyVolumes: readOnly)
        let outcome = turn(cacheDir + "/f_0001ba", disk: disk, protections: protections)
        #expect(outcome.kind == .missing, "\(outcome)")
        // A missing file deep on the MARKED drive is still held.
        disk.existing.insert("/Volumes/TestSanDisk/Clips")
        let marked = turn("/Volumes/TestSanDisk/Clips/gone/a.mov", disk: disk, protections: protections)
        #expect(marked.kind == .held, "\(marked)")
    }

    /// The archive twin of the shape: the same gone tree on the archive
    /// volume stays HELD (its record is never stamped by a bulk verb).
    @Test func theSameShapeOnTheArchiveVolumeStaysHeld() throws {
        let disk = rickDisk()
        let protections = JunkTurnProtections(archiveVolume: try protection(disk), readOnlyVolumes: .none)
        let archived = cacheDir.replacingOccurrences(of: "/Volumes/TestProjects", with: "/Volumes/TestFamilyArchive")
        for name in rickNames.prefix(5) {
            let outcome = turn(archived + "/" + name, disk: disk, protections: protections)
            guard case .held(let why) = outcome else { Issue.record("not held: \(outcome)"); continue }
            #expect(why.contains("Master Archive volume, which only archive actions may change"), Comment(rawValue: why))
        }
    }

    /// Archive unplugged + unreadable drive identity: held, and the note
    /// says "not connected" — which is then true.
    @Test func archiveUnpluggedUnreadableDriveIsHeldAsNotConnected() throws {
        let disk = rickDisk(archiveMounted: false, projectsUUIDReadable: false)
        let protections = JunkTurnProtections(archiveVolume: try protection(disk), readOnlyVolumes: .none)
        guard case .held(let why) = turn(cacheDir + "/f_0001ba", disk: disk, protections: protections) else {
            Issue.record("not held"); return
        }
        #expect(why.contains("is not connected"), Comment(rawValue: why))
    }

    /// Archive mounted, a drive that cannot be read at all: held, and the
    /// note does NOT claim the archive is not connected.
    @Test func archiveMountedUnreadableDriveIsHeldWithoutNotConnected() throws {
        let disk = rickDisk()
        let protections = JunkTurnProtections(archiveVolume: try protection(disk), readOnlyVolumes: .none)
        guard case .held(let why) = turn("/Volumes/TestOdd/a.mov", disk: disk, protections: protections) else {
            Issue.record("not held"); return
        }
        #expect(!why.contains("not connected") && why.contains("could not read"), Comment(rawValue: why))
    }
}

/// QA round 1 on 680157026: a gone tree whose nearest survivor is on the
/// BOOT disk (more than one level up) may hide a dangling symlink into an
/// unplugged drive — a scan target such as ~/ArchiveLink → FamilyArchive.
/// realpath fails on the link exactly as on a gone folder, so the boot
/// disk's UUID proves nothing about the file.
@Suite("Archive gate — boot-disk survivor of a gone tree proves nothing", .serialized)
struct ArchiveGateBootSurvivorRedTests {

    @Test func danglingSymlinkScanTargetIntoUnpluggedArchiveIsNotCleared() throws {
        let disk = rickDisk(archiveMounted: false)
        let p = try protection(disk)
        let v = p.verdictAtRemoval(path: "/Users/test/ArchiveLink/30_Video/a.mov", probe: disk.probe, identity: disk.identity)
        #expect(v != .clear, "a file behind a dangling link into the unplugged archive was cleared")
    }

    @Test func danglingSymlinkIntoUnpluggedReadOnlyDriveIsStillHeld() {
        let disk = rickDisk()
        let marks = [ReadOnlyVolumeProtection.Mark(searchPath: "/Volumes/TestSanDisk", volumeUUID: "TEST-RO")]
        let readOnly = ReadOnlyVolumeProtection.make(marks: marks, mountedRoots: { ["/Volumes/TestProjects", "/Volumes/TestFamilyArchive"] },
                                                     probe: disk.probe, identity: disk.identity, networkRoots: { [] })
        #expect(readOnly.verdictAtRemoval(path: "/Users/test/SanLink/Clips/a.mov", probe: disk.probe, identity: disk.identity) != nil,
                "a file behind a dangling link into the unplugged Read-only drive was cleared")
    }

    /// QA MINOR 2: the climb's ceiling holds under every spelling of a
    /// /Volumes path — case-folded and the data-volume firmlink.
    @Test func climbNeverReadsVolumesUnderAnySpelling() {
        for path in ["/volumes/TestGhost/a/b/c.mov", "/System/Volumes/Data/Volumes/TestGhost/a/b/c.mov"] {
            let disk = FakeDisk(existing: [], mounts: ["/": bootUUID])
            #expect(ArchiveVolumeProtection.nearestExistingAncestor(of: path, identity: disk.identity) == nil)
            let asked = Set(disk.asked.paths.map { $0.lowercased() })
            for forbidden in ["/volumes", "/system/volumes/data/volumes", "/system/volumes/data", "/system/volumes", "/system", "/"] {
                #expect(!asked.contains(forbidden), "\(path) read \(forbidden): \(disk.asked.paths)")
            }
        }
    }
}
