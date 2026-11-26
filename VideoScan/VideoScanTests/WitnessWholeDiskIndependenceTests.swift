// WitnessWholeDiskIndependenceTests.swift
// REGRESSION GH #311: Relocate's "safely redundant" witness check and the
// Retire gate (both through RelocateReconcile.witnessIsOffTheSourceDrive)
// called a witness "on another drive" when its st_dev differed from the
// source root's. st_dev is per VOLUME (and per mount): two APFS volumes in
// one container, or two partitions of one disk, have different st_dev and
// share the hardware — one failure takes both copies.
//
// Fix: the witness must sit on a different PHYSICAL drive by the one answer
// the app already has for that question, DuplicateDrives (DiskArbitration's
// device path — from an APFS volume through its container to the physical
// store), asked fresh. A witness on a disk image, or on a volume whose
// drive cannot be established, is never independent (refuse over guess).
//
// The real-disk tests use this Mac's own internal SSD: the Preboot volume
// and the Data volume (the per-user temp dir) are two APFS volumes in one
// container — exactly the #311 shape, with different st_dev.
//
// Red/green (before the fix → after):
//   twoVolumesOfTheInternalSSDAreNotIndependent ................ RED → green
//   retireRefusesAWitnessOnAnotherVolumeOfTheSameDisk .......... RED → green
//   witnessOnADiskImageIsNotIndependent ........................ RED → green
//   witnessOnAnUnknownVolumeIsNotIndependent ................... RED → green
//   sameDeviceDifferentVolumesIsNotIndependent ................. RED → green
//   differentPhysicalDrivesAreIndependent ...................... green → green
//   networkShareWitnessIsIndependentOfALocalDisk ............... green → green
//   theWitnessThatIsTheSourceFileIsNeverIndependent ............ green → green
//
// Round 2 (Codex #387, 2026-11-26) — red on 0e5b2180c, green after:
//   anUnmountedSourceDriveNeverProvesIndependence ............... RED → green
//   retireRefusesWhileTheSourceDriveIsNotConnected .............. RED → green
//   twoNetworkSharesAreNotIndependent ........................... RED → green
//   retireNamesWhyAWitnessOnAnotherVolumeDoesNotCount ........... RED → green
//   aLocalDriveWitnessIsIndependentOfANetworkSource (control) ... green → green

import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Witness independence — a different PHYSICAL drive, never just another volume (GH #311)",
       .serialized, .scratchCleanup)
struct WitnessWholeDiskIndependenceTests {

    /// A volume of the internal SSD other than the Data volume, mounted on
    /// every Apple-silicon Mac.
    private static let siblingVolumeRoot = "/System/Volumes/Preboot"

    private static func device(_ path: String) -> UInt64? {
        var sb = stat()
        guard stat(path, &sb) == 0 else { return nil }
        return DeviceID.from(sb.st_dev)
    }

    /// A real witness file in the test temp dir (the Data volume).
    private static func witness(size: Int = 4096) throws -> (path: String, size: Int64) {
        let dir = try TestScratch.unique("vs_wholedisk_")
        let url = dir.appendingPathComponent("witness.mov")
        try Data(repeating: 0x5A, count: size).write(to: url)
        return (url.path, Int64(size))
    }

    /// Preconditions every real-disk test states before it runs.
    private static func requireTwoVolumesOfOneDisk(_ witness: String) throws {
        let root = try #require(device(siblingVolumeRoot), "\(siblingVolumeRoot) is not mounted on this Mac")
        let w = try #require(device(witness))
        try #require(root != w, "the witness and \(siblingVolumeRoot) must be two volumes (different st_dev)")
    }

    // MARK: Real disks

    @Test("two APFS volumes of this Mac's internal SSD are not independent witnesses")
    func twoVolumesOfTheInternalSSDAreNotIndependent() throws {
        let w = try Self.witness()
        try Self.requireTwoVolumesOfOneDisk(w.path)
        let source = Self.siblingVolumeRoot + "/no-such-source.mov"

        #expect(!RelocateReconcile.witnessIsOffTheSourceDrive(w.path, source, Self.siblingVolumeRoot),
                "a witness on the Data volume was called independent of the Preboot volume — same SSD")
    }

    @Test("Retire refuses a drive whose only witness is on another volume of the same disk")
    func retireRefusesAWitnessOnAnotherVolumeOfTheSameDisk() throws {
        let w = try Self.witness()
        try Self.requireTwoVolumesOfOneDisk(w.path)
        let row = RetireGateInput.Row(path: Self.siblingVolumeRoot + "/clip.mov", size: w.size,
                                      labelled: false, witnesses: [w.path])
        let input = RetireGateInput(volumeRootPath: Self.siblingVolumeRoot, total: 1, disposed: 1,
                                    rows: [row], recordedVolumeUUID: nil)

        let check = RetireGate.evaluate(input, independence: RelocateReconcile.witnessIsOffTheSourceDrive,
                                        disk: .retireLive, drive: .live)

        #expect(check.refusal != nil, "Retire allowed: the only copy is on the same physical SSD")
        #expect(check.unproven.witnessNotIndependent == [row.path])
    }

    @Test("Retire's refusal says WHY a copy on disk does not count (not on another physical drive)")
    func retireNamesWhyAWitnessOnAnotherVolumeDoesNotCount() throws {
        let w = try Self.witness()
        try Self.requireTwoVolumesOfOneDisk(w.path)
        let row = RetireGateInput.Row(path: Self.siblingVolumeRoot + "/clip.mov", size: w.size,
                                      labelled: false, witnesses: [w.path])
        let input = RetireGateInput(volumeRootPath: Self.siblingVolumeRoot, total: 1, disposed: 1,
                                    rows: [row], recordedVolumeUUID: nil)

        let check = RetireGate.evaluate(input, independence: RelocateReconcile.witnessIsOffTheSourceDrive,
                                        disk: .retireLive, drive: .live)

        let words = try #require(check.refusal)
        #expect(words.contains("not proven to be on another physical drive"), "refusal words: \(words)")
    }

    // MARK: Round 2 — the source's drive must be established NOW (Codex #387 finding 1)

    /// A /Volumes path no volume is mounted at (the source drive unplugged).
    private static func unmountedRoot() -> String { "/Volumes/VS-not-mounted-\(UUID().uuidString)" }

    @Test("an UNMOUNTED source drive never proves independence — its physical disk cannot be established")
    func anUnmountedSourceDriveNeverProvesIndependence() throws {
        let w = try Self.witness()
        let root = Self.unmountedRoot()
        // The witness is on a real physical drive (this Mac's SSD); the source
        // drive may be another volume of that very SSD — nobody can tell.
        #expect(!RelocateReconcile.witnessIsOffTheSourceDrive(w.path, root + "/clip.mov", root),
                "a witness was called independent of a drive that is not connected")
    }

    @Test("Retire refuses while the drive is not connected, and says so")
    func retireRefusesWhileTheSourceDriveIsNotConnected() throws {
        let w = try Self.witness()
        let root = Self.unmountedRoot()
        let row = RetireGateInput.Row(path: root + "/clip.mov", size: w.size, labelled: false, witnesses: [w.path])
        let input = RetireGateInput(volumeRootPath: root, total: 1, disposed: 1, rows: [row], recordedVolumeUUID: nil)

        let check = RetireGate.evaluate(input, independence: RelocateReconcile.witnessIsOffTheSourceDrive,
                                        disk: .retireLive, drive: .live)

        let words = try #require(check.refusal, "Retire allowed with the drive unplugged — independence unproven")
        #expect(check.unproven.witnessNotIndependent == [row.path])
        #expect(words.contains("this drive is not connected"), "refusal words: \(words)")
    }

    // MARK: Round 2 — network shares (Codex #387 finding 2)

    @Test("two network shares are never independent of each other — both may be one NAS disk")
    func twoNetworkSharesAreNotIndependent() throws {
        let w = try Self.witness()
        try Self.requireTwoVolumesOfOneDisk(w.path)
        #expect(!Self.independent(witness: w.path,
                                  rootDrive: .init(device: 1, kind: .network, physicalDevice: "net://nas/Source"),
                                  witnessDrive: .init(device: 2, kind: .network, physicalDevice: "net://nas/Backup")))
    }

    @Test("control: a witness on a local physical drive is independent of a network source")
    func aLocalDriveWitnessIsIndependentOfANetworkSource() throws {
        let w = try Self.witness()
        try Self.requireTwoVolumesOfOneDisk(w.path)
        #expect(Self.independent(witness: w.path,
                                 rootDrive: .init(device: 1, kind: .network, physicalDevice: "net://nas/Source"),
                                 witnessDrive: .init(device: 2, kind: .physical, physicalDevice: "IOService:/B")))
    }

    // MARK: Injected drives (the one seam DuplicateDrives already has)

    private static func realPath(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    private static func independent(witness w: String, root: String = siblingVolumeRoot,
                                    rootDrive: DuplicateDrives.Identity,
                                    witnessDrive: DuplicateDrives.Identity) -> Bool {
        // The seam is asked with realpath(3) (DuplicateDrives.overridden) —
        // not Foundation's resolvingSymlinksInPath, which drops "/private".
        let realW = Self.realPath(w), realRoot = Self.realPath(root)
        return DuplicateDrives.$identityOverride.withValue({ path in
            if path == realW || path == w { return witnessDrive }
            if path == realRoot || path == root { return rootDrive }
            return nil
        }) {
            RelocateReconcile.witnessIsOffTheSourceDrive(w, root + "/no-such-source.mov", root)
        }
    }

    @Test("a witness on a disk image is never independent (its backing file may be on the source disk)")
    func witnessOnADiskImageIsNotIndependent() throws {
        let w = try Self.witness()
        try Self.requireTwoVolumesOfOneDisk(w.path)
        #expect(!Self.independent(witness: w.path,
                                  rootDrive: .init(device: 1, kind: .physical, physicalDevice: "IOService:/A"),
                                  witnessDrive: .init(device: 2, kind: .diskImage)))
    }

    @Test("a witness on a volume whose drive cannot be established is never independent")
    func witnessOnAnUnknownVolumeIsNotIndependent() throws {
        let w = try Self.witness()
        try Self.requireTwoVolumesOfOneDisk(w.path)
        #expect(!Self.independent(witness: w.path,
                                  rootDrive: .init(device: 1, kind: .physical, physicalDevice: "IOService:/A"),
                                  witnessDrive: .init(device: 2, kind: .unknown)))
    }

    @Test("two volumes that report one physical device are one drive")
    func sameDeviceDifferentVolumesIsNotIndependent() throws {
        let w = try Self.witness()
        try Self.requireTwoVolumesOfOneDisk(w.path)
        #expect(!Self.independent(witness: w.path,
                                  rootDrive: .init(device: 1, kind: .physical, physicalDevice: "IOService:/RAID"),
                                  witnessDrive: .init(device: 2, kind: .physical, physicalDevice: "IOService:/RAID")))
    }

    @Test("control: two physical devices are independent")
    func differentPhysicalDrivesAreIndependent() throws {
        let w = try Self.witness()
        try Self.requireTwoVolumesOfOneDisk(w.path)
        #expect(Self.independent(witness: w.path,
                                 rootDrive: .init(device: 1, kind: .physical, physicalDevice: "IOService:/A"),
                                 witnessDrive: .init(device: 2, kind: .physical, physicalDevice: "IOService:/B")))
    }

    @Test("control: a witness on a network share is independent of a local disk")
    func networkShareWitnessIsIndependentOfALocalDisk() throws {
        let w = try Self.witness()
        try Self.requireTwoVolumesOfOneDisk(w.path)
        #expect(Self.independent(witness: w.path,
                                 rootDrive: .init(device: 1, kind: .physical, physicalDevice: "IOService:/A"),
                                 witnessDrive: .init(device: 2, kind: .network, physicalDevice: "net://nas/share")))
    }

    @Test("control: a witness that IS the source file (same device + inode) is never independent")
    func theWitnessThatIsTheSourceFileIsNeverIndependent() throws {
        let w = try Self.witness()
        let dir = (w.path as NSString).deletingLastPathComponent
        #expect(!RelocateReconcile.witnessIsNotTheSourceFile(w.path, w.path, dir))
    }
}
