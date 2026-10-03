// DeleteDuplicatesDrives.swift
// Delete Duplicates — WHICH DRIVE a copy sits on, and whether that drive
// counts as a separate one (the two-drives rule, Rick 2026-10-03; codex
// #258 findings 8, 9, 10; "a drive is a PHYSICAL device", 2026-10-03).
//
// The tier deletes a copy outright only when the verified copies that
// remain sit on at least two different drives. This file is the ONE answer
// to "which drive is this copy on?" — asked by the run (`DeletionTierFacts
// .gather`), by the sibling prover, by the steward's proof and by the
// forecast, so they cannot disagree.
//
// A DRIVE IS A PHYSICAL DEVICE. The rule promises a person that one device
// failing cannot take every copy. Two volumes of one device — two APFS
// volumes in one container, two partitions of one disk, FamilyArchive and
// Projects on one RAID — do not keep that promise, so they are ONE drive.
// The key is the device, not the volume:
//
//   statfs(2) f_mntfromname ........ the volume's device node ("/dev/disk23s1")
//   DiskArbitration description of that node:
//     kDADiskDescriptionDevicePathKey ..... the IOKit path of the PHYSICAL
//         device the volume is on. DiskArbitration walks there itself: from
//         an APFS volume through its container to the physical store, from
//         a partition to its whole disk. Two volumes of one device report
//         the SAME path; two devices report different ones.   → THE KEY
//     kDADiskDescriptionDeviceModelKey .... "Pegasus32 R4" — the label, and
//         "Disk Image" marks a disk image
//     kDADiskDescriptionDeviceProtocolKey . "Virtual Interface" marks a
//         disk image too
//
// Measured on the M4 Max Mac Studio, 2026-10-03 (volume names only):
//   FamilyArchive, Projects ............ one device path (the RAID)  → one drive
//   the boot volume, the Data volume,
//   M4drive ............................ one device path (internal SSD) → one drive
//   LaCieWorkspace · CrucialX9 ......... a device path each → two drives
//   XcodeRAM, .dmg/APFS, .dmg/HFS+,
//   .sparsebundle ...................... "Disk Image" / "Virtual Interface"
//
// WHAT COUNTS AS A DRIVE:
//   • a local volume on a physical device ......... yes — one drive per
//     DEVICE, however many of its volumes hold copies
//   • a network volume (SMB / AFP / NFS) ........... yes — one drive per
//     server + share (its `f_mntfromname`)
//   • a mounted DISK IMAGE (.dmg, .sparsebundle,
//     a RAM disk) .................................. NEVER — its backing file
//     may sit on the very drive the other copies are on
//   • a volume whose physical device cannot be
//     established .................................. NEVER (refuse over guess)
// A copy on a volume that is not a drive still counts as a COPY, exactly as
// before; it just cannot be the "second drive".
//
// WHAT CANNOT BE SEEN (docs/practices/invariants/MediaOps.md, MOPS-2): a
// hardware RAID presents as ONE device and counts as one drive — its
// internal redundancy is not a second drive; two disks in one enclosure that
// present as two devices count as two.
//
// Nothing here is stored across a remount: the key is asked afresh in every
// counting pass, and the removal boundary re-stats every counted copy.
//
// THE GENERATION (codex #258 r2-3). What DiskArbitration said is cached, and
// a cache can be stale: volume X is unmounted and another volume takes its
// st_dev and device node before the mount notification is delivered. Two
// defences, both needed:
//   1. the cache key carries the volume's own UUID (st_dev | node | UUID),
//      so a different volume at a reused number and node MISSES the cache;
//      a volume that reports no UUID is never cached at all;
//   2. `generation` — one process-wide counter, moved (and the cache
//      emptied) by every mount / unmount / rename, synchronously with the
//      notification, and by every run start. `DeletionTierFacts` records
//      the generation it was gathered under; `recheck` — the final verdict,
//      on the disk thread — reads the counter again and, when it has moved,
//      asks afresh which device every counted copy is on and re-decides the
//      tier. Evidence gathered before a mount change never survives it.
//
// Cost: one statfs per volume per counting pass (the `Resolver`'s memo), and
// ONE DiskArbitration description per mounted volume per generation — the
// process-wide `VolumeCache`. The forecast stats each connected copy once
// (the FILE, as the run does — a file symlink onto another device is placed
// where its bytes are: codex #258 r2-4). Nothing else per record.
//
// (For Rick: `@TaskLocal` ≈ a thread_local a test installs for one scope;
// `Resolver` is a small struct with a memo table, passed by reference.)

import CryptoKit
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
        /// A network share. One drive per server + share.
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
        /// The PHYSICAL device the volume sits on (see the file header);
        /// nil = not given (a test's identity: `device` then stands for it).
        var physicalDevice: String? = nil
        /// "Pegasus32 R4" — the device's model, for the reason text.
        var deviceLabel: String? = nil
    }

    /// TEST SEAM — task-local, never process-global. When set it answers
    /// instead of the disk: two drives cannot be had inside one temp
    /// folder, and a disk image must not be mounted by a unit test. It is
    /// asked with the copy's RESOLVED path (realpath — the file its bytes
    /// are in, as a stat sees it), by the run and by the forecast alike.
    /// nil for a path = ask the disk as usual.
    @TaskLocal static var identityOverride: (@Sendable (String) -> Identity?)? = nil

    /// TEST SEAM — task-local: stands in for the DiskArbitration lookup of
    /// one mounted volume (its device node, its st_dev), so a test can run
    /// the REAL cache through a mount / unmount schedule. nil = ask
    /// DiskArbitration.
    @TaskLocal static var lookupOverride: (@Sendable (_ node: String, _ device: UInt64) -> Identity)? = nil

    /// TEST SEAM — task-local: a prefix on this task's cache keys, so a test
    /// that walks the cache through a schedule is not disturbed by other
    /// suites looking up the same real volume. "" in production.
    @TaskLocal static var cacheScope: String = ""

    /// The key of a volume no physical device is known for.
    nonisolated static func key(device: UInt64) -> String { "dev:\(device)" }

    /// THE KEY every caller compares: one per PHYSICAL DEVICE (a short
    /// digest of its device path — the path itself is long and rides on
    /// every counted copy of the plan); per volume only when no device is
    /// given (a test's identity, a volume that never adds a drive anyway).
    nonisolated static func key(for identity: Identity) -> String {
        guard let physical = identity.physicalDevice, !physical.isEmpty else { return key(device: identity.device) }
        let digest = SHA256.hash(data: Data(physical.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "disk:" + digest
    }

    nonisolated static func drive(_ identity: Identity, path: String) -> DeletionTierFacts.Drive {
        DeletionTierFacts.Drive(key: key(for: identity), label: DeletionTierFacts.driveLabel(forPath: path),
                                kind: identity.kind, model: identity.deviceLabel)
    }

    /// One pass's memo: the identity of each volume met, and (for the
    /// forecast, which has no stamps) the volume of each folder met.
    struct Resolver {
        private var volumes: [UInt64: Identity] = [:]
        private var uuids: [UInt64: String?] = [:]

        init() {}

        /// The volume of a copy that was just stat'ed (`stamp`).
        mutating func identity(path: String, stamp: FileIdentityStamp) -> Identity {
            if let given = DuplicateDrives.overridden(path) { return given }
            return volume(device: stamp.device, volumeUUID: stamp.volumeUUID, path: path)
        }

        /// The drive of a copy that was just stat'ed.
        mutating func drive(path: String, stamp: FileIdentityStamp) -> DeletionTierFacts.Drive {
            DuplicateDrives.drive(identity(path: path, stamp: stamp), path: path)
        }

        /// The drive of a copy known only by its PATH (the forecast): one
        /// stat of the FILE ITSELF — the same question the run's stamp
        /// answers, so a file symlink onto another device is placed where
        /// its bytes are (codex #258 r2-4) — then this pass's memo of the
        /// volume. nil when the file cannot be stat'ed (its drive is then
        /// unknown and never adds one).
        mutating func drive(forPath path: String) -> DeletionTierFacts.Drive? {
            if let given = DuplicateDrives.overridden(path) { return DuplicateDrives.drive(given, path: path) }
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            let device = UInt64(info.st_dev)
            let uuid: String?
            if let known = uuids[device] { uuid = known } else {
                uuid = VolumeIdentity.uuid(forPath: path)
                uuids[device] = uuid
            }
            return DuplicateDrives.drive(volume(device: device, volumeUUID: uuid, path: path), path: path)
        }

        private mutating func volume(device: UInt64, volumeUUID: String?, path: String) -> Identity {
            if let known = volumes[device] { return known }
            let found = DuplicateDrives.liveIdentity(forPath: path, device: device, volumeUUID: volumeUUID)
            volumes[device] = found
            return found
        }
    }

    /// The seam's answer for a copy: asked with the path the copy's bytes
    /// are really at (symlinks resolved), as a stat would see it.
    nonisolated static func overridden(_ path: String) -> Identity? {
        guard let override = identityOverride else { return nil }
        guard let real = realpath(path, nil) else { return override(path) }
        defer { free(real) }
        return override(String(cString: real))
    }

    // MARK: Asking the disk

    /// What DiskArbitration said about mounted volumes, kept for one
    /// generation: keyed by `cacheKey` — st_dev + device node + the
    /// volume's UUID — so a number and a node handed to ANOTHER volume are
    /// never mistaken for this one.
    struct VolumeCache: Sendable {
        private(set) var entries: [String: Identity] = [:]
        /// How many times the disk was actually asked (tests read it).
        private(set) var lookups = 0

        mutating func identity(for key: String, lookup: () -> Identity) -> Identity {
            if let known = entries[key] { return known }
            lookups += 1
            let found = lookup()
            entries[key] = found
            return found
        }

        mutating func removeAll() { entries.removeAll() }
    }

    private final class CacheBox: @unchecked Sendable {
        let lock = NSLock()
        var cache = VolumeCache()
        var generation: UInt64 = 0
    }
    private static let shared = CacheBox()

    /// The drive-evidence generation (see the file header): moved by every
    /// `resetVolumeCache`. Readable from any thread.
    nonisolated static var generation: UInt64 { shared.lock.withLock { shared.generation } }

    /// Forget what was learned about the mounted volumes AND revoke every
    /// piece of drive evidence gathered so far (the generation moves): a
    /// Delete Duplicates run is starting, or a volume was mounted /
    /// unmounted / renamed. Synchronous; callable from any thread.
    nonisolated static func resetVolumeCache() {
        shared.lock.withLock {
            shared.cache.removeAll()
            shared.generation &+= 1
        }
    }

    /// The cache key of one mounted volume, or nil when it must not be
    /// cached: a volume that reports no UUID cannot be told from another
    /// one that later takes its st_dev and device node.
    nonisolated static func cacheKey(device: UInt64, node: String, volumeUUID: String?) -> String? {
        guard let volumeUUID, !volumeUUID.isEmpty else { return nil }
        return "\(device)|\(node)|\(volumeUUID)"
    }

    /// Ask the disk which volume holds `path` (whose stat said `device`):
    /// its kind and its physical device. DISK I/O (statfs; one
    /// DiskArbitration lookup the first time a volume is met in a run):
    /// never per record — go through `Resolver`.
    nonisolated static func liveIdentity(forPath path: String, device: UInt64, volumeUUID: String?) -> Identity {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return Identity(device: device, kind: .unknown) }
        let node = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        // A network share: one drive per server + share.
        guard fs.f_flags & UInt32(MNT_LOCAL) != 0 else {
            return Identity(device: device, kind: .network, physicalDevice: "net:" + node)
        }
        let lookup = { lookupOverride?(node, device) ?? describe(node: node, device: device) }
        guard let key = cacheKey(device: device, node: node, volumeUUID: volumeUUID) else { return lookup() }
        return shared.lock.withLock { shared.cache.identity(for: cacheScope + key, lookup: lookup) }
    }

    /// The kind alone (see `liveIdentity`).
    nonisolated static func liveKind(forPath path: String) -> VolumeKind {
        var info = stat()
        guard stat(path, &info) == 0 else { return .unknown }
        return liveIdentity(forPath: path, device: UInt64(info.st_dev), volumeUUID: VolumeIdentity.uuid(forPath: path)).kind
    }

    private nonisolated static func describe(node: String, device: UInt64) -> Identity {
        guard node.hasPrefix("/dev/"),
              let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, node),
              let description = DADiskCopyDescription(disk) as? [String: Any] else {
            return Identity(device: device, kind: .unknown)
        }
        return identity(device: device,
                        model: description[kDADiskDescriptionDeviceModelKey as String] as? String,
                        deviceProtocol: description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
                        devicePath: description[kDADiskDescriptionDevicePathKey as String] as? String)
    }

    /// Pure: what a DiskArbitration description means. A disk image is
    /// never a drive; a physical volume whose DEVICE PATH is not given
    /// cannot be told apart from another volume of the same device, so it
    /// is unknown (refuse over guess).
    nonisolated static func identity(device: UInt64, model: String?, deviceProtocol: String?, devicePath: String?) -> Identity {
        let kind = kind(model: model, deviceProtocol: deviceProtocol)
        guard kind == .physical else { return Identity(device: device, kind: kind) }
        guard let devicePath, !devicePath.isEmpty else { return Identity(device: device, kind: .unknown) }
        let label = model?.trimmingCharacters(in: .whitespaces)
        return Identity(device: device, kind: .physical, physicalDevice: devicePath,
                        deviceLabel: (label?.isEmpty ?? true) ? nil : label)
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
