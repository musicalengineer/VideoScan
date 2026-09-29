// ContentFixity.swift
// Full-file fixity for ANY catalog record (Rick 2026-09-20, Delete
// Duplicates: "look at precomputed hash IDs … if we must compare
// byte-for-byte, only do one file, the one being deleted").
//
// `ArchiveFixity` is the Master Archive's read-back proof and lives only on
// archive copies. This is the general one: whenever the app has hashed a
// whole file — a keeper during duplicate verification, an archive copy at
// audit, a Bind Fixity to Volume pass — the digest is kept HERE together
// with a stamp of the file the digest describes. A later stamp that
// reproduces it means the bytes have not been rewritten or replaced, so
// the stored digest may stand in for a fresh read of that side.
//
// THE STAMP MUST INCLUDE ctime (QA on 462b034b, MAJOR 1). Device, inode,
// size and mtime are all reproducible by ordinary tools — `cp -p`,
// `rsync -t --inplace`, `touch -r` — after an in-place rewrite of the SAME
// size. `st_ctimespec` is set by the kernel on every inode change and
// cannot be set by user tools, so a verification-grade match requires it
// (full nanoseconds).
//
// THE STAMP MUST NAME ITS VOLUME PERSISTENTLY (2026-09-23; codex #1707).
// `st_dev` is handed out per mount: the same disk gets a new one after a
// replug or reboot (1,429 of Rick's 1,493 stamps failed only on it), and a
// number one disk gave up is later handed to ANOTHER disk (measured:
// 16777252 was LaCieWorkspace's, is now Projects'). So:
//
//   PERSISTENT DIGEST POLICY (`describesFileNow`, `isUsableForVerification`)
//     identity = volume UUID + inode + size + mtime + ctime (+ sha256,
//                byteCount == size). The volume UUID is the persistent
//                one (`VolumeIdentity`: getattrlist ATTR_VOL_UUID ≡
//                NSURL volumeUUIDStringKey — never volumeIdentifierKey,
//                which is per-mount). st_dev is not consulted at all.
//     A stamp WITHOUT a volume UUID — every stamp written before this
//     change, and any stamp of a volume that reports none — is NOT usable:
//     "absent" to the gate, exactly like a pre-ctime stamp. It records no
//     proof of which volume produced the digest, and nothing recorded at
//     stamp time identifies the mount epoch it was taken in (macOS exposes
//     no mount generation; st_dev is reused), so same-mount trust cannot be
//     proven either. One full re-read with before/after identity checks
//     (Delete Duplicates' keeper read, Verify Archive Copies, or the
//     "Bind Fixity to Volume" job) replaces it with a UUID-bearing stamp.
//     A missing or unresolvable UUID is never a wildcard.
//
//   SAME-OPERATION IDENTITY (`stampMatches`, `matchesIgnoringChangeTime`,
//     `isSameFile`, the `==` checks inside one verification)
//     Two stats of ONE operation, seconds apart: device must match, and the
//     UUIDs must be equal (both known and equal, or both unknown) — a device
//     number can never bypass a KNOWN UUID mismatch.
//
//   RESUME IDENTITY (`LegacyVolumeRule.notCompared`, the Delete Duplicates
//     resume/quarantine check): a recorded UUID must reproduce; a plan
//     written before UUIDs keeps its original device-blind rule.
//
// Capture binds the UUID and the stat to ONE opened file: open → fstat +
// fgetattrlist on that descriptor → stat(path) must still name the same
// device+inode (else nil: the path moved under us). A volume cannot change
// under an open descriptor; a forced unmount makes the calls fail (nil).
//
// Cases (tests in ContentFixityVolumeIdentityTests):
//   new stamp, remount, same UUID, new st_dev ..... fresh (the fix)
//   same disk remounted at another path ........... fresh (UUID equal)
//   different disk at the same path / reused dev .. stale (UUID differs)
//   legacy stamp (no UUID), any mount ............. untrusted until re-read
//   APFS inode reuse / clonefile / restore /
//   rename-replace / symlink retarget ............. stale (inode/ctime)
//   same-size rewrite, mtime put back ............. stale (ctime)
//   UUID cannot be resolved now ................... stale
//
// What this is NOT: `contentHash` and `partialMD5` sample a few windows and
// can never prove two files the same (design #320). The file being DELETED
// is always read in full at the moment of deletion; the stamp only spares a
// second full read of the file that survives.
//
// (For Rick: two POD structs. `FileIdentityStamp` ≈ the `struct stat`
// fields that change when a file is replaced or rewritten, plus the
// volume's UUID; `ContentFixity` ≈ digest + byte count + that stamp. Swift
// synthesises `==`/`hash` member-wise, like a defaulted C++20 operator==.)

import Darwin
import Foundation

/// Filesystem identity + mutation stamp of one opened file.
public struct FileIdentityStamp: Codable, Equatable, Hashable, Sendable {
    /// `st_dev` at capture — valid only for the mount it was read on. Used
    /// for same-operation identity (hard links, the quarantine move), never
    /// by the persistent digest policy.
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    /// Modification time, nanoseconds since the epoch.
    public let mtimeNs: Int64
    /// Inode change time, same encoding. Kernel-set; `unknownCtime` for
    /// stamps written before 2026-09-20.
    public let ctimeNs: Int64
    /// The volume's persistent UUID (uppercase) at capture. nil for stamps
    /// written before 2026-09-23 and for volumes that report none — such a
    /// stamp can never satisfy the persistent policy.
    public let volumeUUID: String?

    public static let unknownCtime: Int64 = -1

    public init(device: UInt64, inode: UInt64, size: Int64, mtimeNs: Int64,
                ctimeNs: Int64 = FileIdentityStamp.unknownCtime,
                volumeUUID: String? = nil) {
        self.device = device
        self.inode = inode
        self.size = size
        self.mtimeNs = mtimeNs
        self.ctimeNs = ctimeNs
        self.volumeUUID = volumeUUID.flatMap(VolumeIdentity.normalized)
    }

    private enum CodingKeys: String, CodingKey { case device, inode, size, mtimeNs, ctimeNs, volumeUUID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decode(UInt64.self, forKey: .device)
        inode = try c.decode(UInt64.self, forKey: .inode)
        size = try c.decode(Int64.self, forKey: .size)
        mtimeNs = try c.decode(Int64.self, forKey: .mtimeNs)
        // Schema: a stamp saved without ctime is a pre-ctime stamp.
        ctimeNs = try c.decodeIfPresent(Int64.self, forKey: .ctimeNs) ?? Self.unknownCtime
        // Schema: a stamp saved without a volume UUID is a pre-UUID stamp.
        volumeUUID = try c.decodeIfPresent(String.self, forKey: .volumeUUID).flatMap(VolumeIdentity.normalized)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(device, forKey: .device)
        try c.encode(inode, forKey: .inode)
        try c.encode(size, forKey: .size)
        try c.encode(mtimeNs, forKey: .mtimeNs)
        try c.encode(ctimeNs, forKey: .ctimeNs)
        try c.encodeIfPresent(volumeUUID, forKey: .volumeUUID)
    }

    /// True when the stamp carries a kernel ctime.
    public var hasChangeTime: Bool { ctimeNs != Self.unknownCtime }

    /// True when the stamp names its volume persistently.
    public var isBoundToVolume: Bool { volumeUUID != nil }

    // MARK: - THE comparison

    public enum ChangeTimeRule: Sendable {
        /// Verification grade: ctime known on the stored stamp and equal.
        case mustMatch
        /// A rename changes ctime; only across the quarantine move and
        /// for the user-visible "nothing ordinary touched it" check.
        case ignored
    }

    /// Which volume rule applies — see the file header.
    public enum VolumeRule: Sendable {
        /// Persistent digest policy: the stored stamp MUST carry a UUID
        /// and `current` must carry the same one. st_dev not consulted.
        case persistentUUID
        /// Two stats of one operation: same device AND same UUID-or-none.
        case sameOperation
        /// Delete Duplicates resume/quarantine: a recorded UUID must
        /// reproduce; a pre-UUID plan's stamp is device-blind (as it was
        /// written under). Never used for the digest policy.
        case resumeAcrossRemount
    }

    /// THE one "is `current` still the file this stamp describes?" check
    /// (self = the STORED/earlier stamp; `current` = a stamp taken now).
    public func describesSameFile(now current: FileIdentityStamp,
                                  changeTime: ChangeTimeRule = .mustMatch,
                                  volume: VolumeRule) -> Bool {
        guard isOnSameVolume(asNow: current, rule: volume) else { return false }
        guard inode == current.inode, size == current.size, mtimeNs == current.mtimeNs else { return false }
        switch changeTime {
        case .mustMatch: return hasChangeTime && ctimeNs == current.ctimeNs
        case .ignored: return true
        }
    }

    /// The volume half of `describesSameFile`.
    public func isOnSameVolume(asNow current: FileIdentityStamp, rule: VolumeRule) -> Bool {
        switch rule {
        case .persistentUUID:
            guard let mine = volumeUUID else { return false }        // no proof of volume
            return current.volumeUUID == mine                        // nil now never matches
        case .sameOperation:
            // A device number never overrides a known UUID mismatch.
            return device == current.device && volumeUUID == current.volumeUUID
        case .resumeAcrossRemount:
            if let mine = volumeUUID { return current.volumeUUID == mine }
            return true
        }
    }

    /// Same volume, inode, size and mtime across the quarantine MOVE (one
    /// operation). self = the file NOW; `before` = its stamp before the move.
    public func matchesIgnoringChangeTime(_ before: FileIdentityStamp) -> Bool {
        before.describesSameFile(now: self, changeTime: .ignored, volume: .sameOperation)
    }

    /// Both stamps name ONE inode on one device — two names for the same
    /// file (hard link, case-insensitive spelling). SAME-OPERATION only.
    public func isSameFile(as other: FileIdentityStamp) -> Bool {
        device == other.device && inode == other.inode
    }

    // MARK: - Capture

    /// Stamp the file at `path`, UUID and stat bound to one opened file
    /// (see the header). nil when the path cannot be stat'ed, or no longer
    /// names the opened file. A file that can be stat'ed but not opened
    /// (no read permission) gets a stat-only stamp WITHOUT a volume UUID:
    /// fine for same-operation identity, never usable for the digest policy.
    public static func capture(path: String) -> FileIdentityStamp? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return stamp(from: info, volumeUUID: nil)
        }
        defer { close(fd) }
        return capture(fd: fd, path: path)
    }

    /// Stamp an ALREADY-OPEN file: fstat + the volume UUID of the same
    /// descriptor, then `path` (when given) must still name this device +
    /// inode. The hashing paths stamp through the descriptor they read.
    public static func capture(fd: Int32, path: String?) -> FileIdentityStamp? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let uuid = VolumeIdentity.uuid(forDescriptor: fd, path: path)
        if let path {
            var named = stat()
            guard stat(path, &named) == 0, named.st_dev == info.st_dev, named.st_ino == info.st_ino else { return nil }
        }
        return stamp(from: info, volumeUUID: uuid)
    }

    private static func stamp(from info: stat, volumeUUID: String?) -> FileIdentityStamp {
        FileIdentityStamp(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mtimeNs: Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_mtimespec.tv_nsec),
            ctimeNs: Int64(info.st_ctimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_ctimespec.tv_nsec),
            volumeUUID: volumeUUID)
    }
}

/// A whole-file digest with the stamp of the file it describes.
public struct ContentFixity: Codable, Equatable, Hashable, Sendable {
    /// "sha256" today; the tag exists so a future algorithm never has to
    /// reinterpret old digests.
    public let algorithm: String
    /// Lowercase hex SHA-256 of EVERY byte of the file.
    public let digest: String
    /// Bytes the digest covers. Always equals `stamp.size`.
    public let byteCount: Int64
    /// The file as it was when `digest` was computed.
    public let stamp: FileIdentityStamp
    public let computedAt: Date

    public static let sha256 = "sha256"

    public init(algorithm: String = ContentFixity.sha256, digest: String, byteCount: Int64,
                stamp: FileIdentityStamp, computedAt: Date = Date()) {
        self.algorithm = algorithm
        self.digest = digest.lowercased()
        self.byteCount = byteCount
        self.stamp = stamp
        self.computedAt = computedAt
    }

    /// The USER-VISIBLE, same-operation check: same device + UUID-or-none,
    /// inode, size, mtime. NOT enough to stand in for a read. Diagnostics
    /// and tests only; nil never matches.
    public func stampMatches(_ current: FileIdentityStamp?) -> Bool {
        guard let current else { return false }
        return stamp.describesSameFile(now: current, changeTime: .ignored, volume: .sameOperation)
            && current.size == byteCount
    }

    public func stampMatches(path: String) -> Bool {
        stampMatches(FileIdentityStamp.capture(path: path))
    }

    /// THE PERSISTENT DIGEST POLICY: sha256, a stored stamp with ctime AND
    /// a volume UUID, and `current` on the same volume UUID with the same
    /// inode, size, mtime and ctime, and size == byteCount. Only this may
    /// let the stored digest stand in for reading the file.
    public func describesFileNow(_ current: FileIdentityStamp?) -> Bool {
        guard let current, isUsableForVerification else { return false }
        return stamp.describesSameFile(now: current, changeTime: .mustMatch, volume: .persistentUUID)
            && current.size == byteCount
    }

    /// True when this fixity can ever satisfy `describesFileNow`: sha256,
    /// ctime-bearing and volume-bound. Anything else is "absent" to the
    /// gate — one full re-read replaces it.
    public var isUsableForVerification: Bool {
        algorithm == Self.sha256 && stamp.hasChangeTime && stamp.isBoundToVolume
    }

    /// Build a fixity for a file that was JUST hashed in full: stat it and
    /// bind the digest to that stamp. When `before` (a stamp taken BEFORE
    /// the read) is given, the after-stamp must equal it exactly. nil when
    /// the stat fails, the size no longer equals the byte count hashed, or
    /// before ≠ after.
    public static func captured(path: String, digest: String, byteCount: Int64,
                                before: FileIdentityStamp? = nil,
                                computedAt: Date = Date()) -> ContentFixity? {
        guard !digest.isEmpty, let stamp = FileIdentityStamp.capture(path: path),
              stamp.size == byteCount else { return nil }
        if let before, before != stamp { return nil }
        return ContentFixity(digest: digest, byteCount: byteCount, stamp: stamp, computedAt: computedAt)
    }
}
