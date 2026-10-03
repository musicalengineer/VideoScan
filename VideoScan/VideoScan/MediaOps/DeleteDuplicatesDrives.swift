// DeleteDuplicatesDrives.swift
// Delete Duplicates — WHICH DRIVE a copy sits on, and whether that drive
// counts as a separate one (the two-drives rule, Rick 2026-10-03; codex
// #258 findings 8, 9, 10).
//
// The tier deletes a copy outright only when the verified copies that
// remain sit on at least two different drives. This file is the ONE answer
// to "which drive is this copy on?" — asked by the run (`DeletionTierFacts
// .gather`), by the sibling prover, by the steward's proof and by the
// forecast, so they cannot disagree.
//
// ONE KEY PER VOLUME (finding 8). A drive is keyed by the `st_dev` of the
// mounted volume, read by the same stat that proves the copy — never by the
// path's spelling, and never by a mix of "UUID when known, device when not"
// (one volume keyed two ways counted as two drives). Every copy of one
// counting pass is stat'ed within seconds, on one set of mounts, so st_dev
// names the volume exactly; nothing here is stored across a remount (the
// removal boundary re-stats every counted copy and drops one whose stamp —
// device included — no longer reproduces).
//
// WHAT COUNTS AS A DRIVE (finding 9):
//   • a local volume on a physical device ......... yes, one drive each
//   • a network volume (SMB / AFP / NFS) ........... yes, one drive each
//   • a mounted DISK IMAGE (.dmg, .sparsebundle,
//     a RAM disk) .................................. NEVER — its backing file
//     may sit on the very drive the other copies are on, and nothing on the
//     volume says where
//   • a volume whose kind cannot be established .... NEVER (refuse over guess)
// A copy on a volume that is not a drive still counts as a COPY, exactly as
// before; it just cannot be the "second drive".
//
// KNOWN LIMIT, documented, not solved (docs/practices/invariants/MediaOps.md,
// MOPS-2): two volumes on ONE physical device — two APFS volumes in one
// container, two partitions of one disk or one RAID — count as two drives.
//
// How a disk image is recognised: statfs(2) names the volume's device node
// (`f_mntfromname`, "/dev/disk29s1"); DiskArbitration describes that device;
// a disk image's device model is "Disk Image" and its protocol "Virtual
// Interface" (both the old IOHDIX driver and the DiskImages2 driver —
// measured on macOS 27 for .dmg/APFS, .dmg/HFS+, .sparsebundle and a RAM
// disk). DiskArbitration walks from an APFS volume to its physical store,
// so a volume inside an image is recognised too.
//
// Cost: one statfs + one DiskArbitration description per distinct volume
// per pass (memoised in `Resolver`); nothing per record.
//
// (For Rick: `@TaskLocal` ≈ a thread_local a test installs for one scope;
// `Resolver` is a small struct with a cache — pass it by reference with
// `inout`/`var`, like a C++ functor with a memo table.)

import Darwin
import DiskArbitration
import Foundation
import VideoScanCore

enum DuplicateDrives {

    /// What kind of volume a copy sits on — only as far as the two-drives
    /// rule needs to know.
    enum VolumeKind: String, Sendable, Equatable {
        /// A local volume on a real device.
        case physical
        /// A network share. One drive per share.
        case network
        /// A mounted disk image (or RAM disk): never a drive of its own.
        case diskImage
        /// Could not be established: never a drive of its own.
        case unknown

        /// May this volume be the "second drive" of the rule?
        var addsADrive: Bool { self == .physical || self == .network }

        /// Why it does not count, for the row's reason (nil when it does).
        var notADriveNote: String? {
            switch self {
            case .physical, .network: return nil
            case .diskImage: return "a disk image is not a second drive"
            case .unknown: return "a volume VideoScan cannot identify is not a second drive"
            }
        }
    }

    /// A volume, as one counting pass sees it.
    struct Identity: Sendable, Equatable {
        /// `st_dev` of the mounted volume.
        var device: UInt64
        var kind: VolumeKind
    }

    /// TEST SEAM — task-local, never process-global. When set it answers
    /// (by path) instead of the disk: two drives cannot be had inside one
    /// temp folder, and a disk image must not be mounted by a unit test.
    /// nil for a path = ask the disk as usual.
    @TaskLocal static var identityOverride: (@Sendable (String) -> Identity?)? = nil

    /// The key every caller compares: one per mounted volume.
    nonisolated static func key(device: UInt64) -> String { "dev:\(device)" }

    /// One pass's memo: the kind of each volume met, and (for the forecast,
    /// which has no stamps) the volume of each folder met.
    struct Resolver {
        private var kinds: [UInt64: VolumeKind] = [:]
        private var folders: [String: Identity?] = [:]

        init() {}

        /// The volume of a copy that was just stat'ed (`stamp`).
        mutating func identity(path: String, stamp: FileIdentityStamp) -> Identity {
            if let override = DuplicateDrives.identityOverride, let given = override(path) { return given }
            return Identity(device: stamp.device, kind: kind(device: stamp.device, path: path))
        }

        /// The drive of a copy that was just stat'ed.
        mutating func drive(path: String, stamp: FileIdentityStamp) -> DeletionTierFacts.Drive {
            let id = identity(path: path, stamp: stamp)
            return DeletionTierFacts.Drive(key: DuplicateDrives.key(device: id.device),
                                           label: DeletionTierFacts.driveLabel(forPath: path), kind: id.kind)
        }

        /// The drive of a copy known only by its PATH (the forecast): one
        /// stat of its folder, memoised per folder — files of one folder sit
        /// on one volume. nil when the folder cannot be stat'ed (its drive
        /// is then unknown and never adds one).
        mutating func drive(forPath path: String) -> DeletionTierFacts.Drive? {
            let id: Identity?
            if let override = DuplicateDrives.identityOverride, let given = override(path) {
                id = given
            } else {
                let folder = (path as NSString).deletingLastPathComponent
                if let known = folders[folder] {
                    id = known
                } else {
                    var info = stat()
                    if stat(folder, &info) == 0 {
                        let device = UInt64(info.st_dev)
                        id = Identity(device: device, kind: kind(device: device, path: folder))
                    } else {
                        id = nil
                    }
                    folders[folder] = id
                }
            }
            return id.map {
                DeletionTierFacts.Drive(key: DuplicateDrives.key(device: $0.device),
                                        label: DeletionTierFacts.driveLabel(forPath: path), kind: $0.kind)
            }
        }

        private mutating func kind(device: UInt64, path: String) -> VolumeKind {
            if let known = kinds[device] { return known }
            let found = DuplicateDrives.liveKind(forPath: path)
            kinds[device] = found
            return found
        }
    }

    /// Ask the disk what kind of volume holds `path`. DISK I/O (statfs +
    /// one DiskArbitration lookup): never per record — go through `Resolver`.
    nonisolated static func liveKind(forPath path: String) -> VolumeKind {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return .unknown }
        guard fs.f_flags & UInt32(MNT_LOCAL) != 0 else { return .network }
        let node = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard node.hasPrefix("/dev/"),
              let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, node),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return .unknown }
        return kind(model: description[kDADiskDescriptionDeviceModelKey as String] as? String,
                    deviceProtocol: description[kDADiskDescriptionDeviceProtocolKey as String] as? String)
    }

    /// Pure: a disk image by either of the two things DiskArbitration says
    /// about one. A device with neither a model nor a protocol is unknown.
    nonisolated static func kind(model: String?, deviceProtocol: String?) -> VolumeKind {
        let model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        let proto = deviceProtocol?.trimmingCharacters(in: .whitespaces) ?? ""
        if model.caseInsensitiveCompare("Disk Image") == .orderedSame
            || proto.caseInsensitiveCompare("Virtual Interface") == .orderedSame { return .diskImage }
        if model.isEmpty && proto.isEmpty { return .unknown }
        return .physical
    }
}
