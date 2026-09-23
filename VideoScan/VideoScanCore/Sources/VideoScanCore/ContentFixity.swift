// ContentFixity.swift
// Full-file fixity for ANY catalog record (Rick 2026-09-20, Delete
// Duplicates: "look at precomputed hash IDs … if we must compare
// byte-for-byte, only do one file, the one being deleted").
//
// `ArchiveFixity` is the Master Archive's read-back proof and lives only on
// archive copies. This is the general one: whenever the app has hashed a
// whole file — a keeper during duplicate verification, an archive copy at
// audit — the digest is kept HERE together with a stat stamp of the file
// the digest describes. A later stat that reproduces the stamp means the
// bytes have not been rewritten or replaced, so the stored digest may
// stand in for a fresh read of that side.
//
// THE STAMP MUST INCLUDE ctime (QA on 462b034b, MAJOR 1). Device, inode,
// size and mtime are all reproducible by ordinary tools — `cp -p`,
// `rsync -t --inplace`, `touch -r` — after an in-place rewrite of the SAME
// size (DV tapes of equal length have identical byte counts). A stale
// digest would then vouch for bytes the keeper no longer holds, and a
// duplicate equal to the OLD bytes — the last copy of them — would be
// deleted. `st_ctimespec` is set by the kernel on every inode change
// (data write, rename, chmod, utimes) and cannot be set by user tools, so
// a verification-grade match requires it. Fixities written before the
// ctime field existed decode with `unknownCtime` and are treated as
// absent: one keeper re-read, then a proper stamp.
//
// VOLUME IDENTITY (2026-09-23). The stamp used to name its volume by
// `st_dev`, which macOS reassigns on every mount — after a replug or a
// reboot 1,429 of Rick's 1,493 stamps failed ONLY on the device number,
// so "Identical" was unreachable in Find Similar Footage, Archive Angel
// lent nothing, and Delete Duplicates re-read keepers and siblings it had
// already proven. Device numbers are also REUSED across different disks
// (measured: 16777252 was LaCieWorkspace's, is now Projects'). The design:
//
//   identity  = volume UUID + inode + size + mtime + ctime
//               (`volumeUUID`, ADDITIVE — old catalogs decode unchanged)
//   st_dev    = kept, but only the legacy same-mount fast path for stamps
//               that carry no UUID; it never overrides a UUID.
//
// ONE comparison — `FileIdentityStamp.describesSameFile(now:…)` — is used
// by every "is this still the file I stamped?" question in the app
// (`describesFileNow`, `stampMatches`, the quarantine/resume identity,
// the removal-boundary recheck). A source sensor pins that nothing else
// compares a stored stamp's device for freshness.
//
// The rule, stored stamp S vs a stat taken now N:
//   • S has a UUID  → N must have the SAME UUID (st_dev ignored). N with
//                     no UUID (cannot resolve now) → NOT the same: refuse.
//   • S has none    → legacy: S.device == N.device (today's rule, no
//                     looser), or — for the resume/quarantine identity,
//                     which has always ignored the device — not compared.
//   • then inode, size, mtime, and (verification grade) ctime must match.
//
// Old stamps are UPGRADED, never guessed: `upgradedToVolumeIdentity`
// binds a pre-UUID stamp to today's volume UUID only when inode, size,
// mtime and ctime all reproduce AND the volume is proven to be the one the
// stamp was taken on — either the device number still matches (legacy
// rule) or the volume UUID resolved NOW equals the UUID the catalog record
// was scanned from (`ScanContext.volumeUUID`). Anything else stays stale:
// one re-read writes a proper stamp. The app writes upgrades back to the
// catalog (VideoScanModel+FixityStampUpgrade), logged once per volume.
//
// Cases this rule was checked against (tests in ContentFixityVolumeIdentityTests):
//   remount, same disk, new st_dev ............ fresh (the fix)
//   same disk remounted at another path ....... fresh (stat follows the
//                                               record's path; UUID equal)
//   different disk at the same path ........... stale (UUID differs)
//   APFS inode reused after delete ............ stale (ctime/mtime/size)
//   clonefile / Finder duplicate .............. stale (new inode)
//   Time Machine / Finder restore ............. stale (new inode)
//   replaced via rename (atomic save) ......... stale (new inode)
//   in-place same-size rewrite, mtime put back  stale (ctime)
//   UUID cannot be resolved now ............... stale
//
// What this is NOT: `contentHash` (the v1 segmented candidate signature)
// and `partialMD5` sample a few windows and can never prove two files the
// same (design #320). Nothing here weakens that rule: the file being
// DELETED is always read in full at the moment of deletion; the stamp only
// spares a second full read of the file that survives.
//
// (For Rick: two POD structs. `FileIdentityStamp` ≈ the `struct stat`
// fields that change when a file is replaced or rewritten, plus the
// volume's UUID; `ContentFixity` ≈ digest + byte count + that stamp +
// when it was computed. Swift synthesises `==`/`hash` member-wise, like a
// defaulted `operator==` in C++20.)

import Darwin
import Foundation

/// Filesystem identity + mutation stamp from one `stat` (plus the volume
/// UUID). Inode + volume detect a path replacement; size + nanosecond
/// mtime detect an in-place rewrite by a well-behaved writer; nanosecond
/// ctime detects one that put the mtime back. `stat` follows symlinks on
/// purpose — it describes the bytes a reader would actually hash.
public struct FileIdentityStamp: Codable, Equatable, Hashable, Sendable {
    /// `st_dev` at capture. Valid only for the mount it was taken on —
    /// see the file header. Used for same-instant identity (hard links)
    /// and as the legacy fast path for stamps without `volumeUUID`.
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    /// Modification time as nanoseconds since the epoch (tv_sec * 1e9 +
    /// tv_nsec) — one integer, no float rounding, Codable as-is.
    public let mtimeNs: Int64
    /// Inode change time, same encoding. Kernel-set on every inode change;
    /// not settable by user tools. `unknownCtime` for stamps written
    /// before 2026-09-20 (decoded from JSON without the key) — such a
    /// stamp can never satisfy `describesFileNow`.
    public let ctimeNs: Int64
    /// The volume's UUID (uppercase) at capture — the remount-proof volume
    /// identity. nil for stamps written before 2026-09-23 and for volumes
    /// that report none; such a stamp is judged by `device` (legacy).
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

    /// True when the stamp carries a kernel ctime — the only kind that may
    /// stand in for a read.
    public var hasChangeTime: Bool { ctimeNs != Self.unknownCtime }

    // MARK: - THE comparison

    /// Whether the ctime must reproduce too.
    public enum ChangeTimeRule: Sendable {
        /// Verification grade — the only grade that may stand in for a read.
        case mustMatch
        /// A rename changes ctime; used only across the quarantine move
        /// and for the user-visible "nothing ordinary touched it" check.
        case ignored
    }

    /// How a stamp WITHOUT a volume UUID names its volume.
    public enum LegacyVolumeRule: Sendable {
        /// The device number must reproduce (today's freshness rule).
        case deviceMustMatch
        /// Not compared — the resume/quarantine identity, which has always
        /// accepted a replugged drive's new device number.
        case notCompared
    }

    /// THE one "is `current` still the file this stamp describes?" check
    /// (self = the STORED stamp; `current` = a stat taken now). Every
    /// freshness question in the app goes through here — see the header.
    public func describesSameFile(now current: FileIdentityStamp,
                                  changeTime: ChangeTimeRule = .mustMatch,
                                  legacyVolume: LegacyVolumeRule = .deviceMustMatch) -> Bool {
        guard isOnSameVolume(asNow: current, legacyVolume: legacyVolume) else { return false }
        guard inode == current.inode, size == current.size, mtimeNs == current.mtimeNs else { return false }
        switch changeTime {
        case .mustMatch: return hasChangeTime && ctimeNs == current.ctimeNs
        case .ignored: return true
        }
    }

    /// The volume half of `describesSameFile`. A UUID, when this stamp has
    /// one, decides alone — `st_dev` is reassigned on every mount and
    /// reused across disks. A current stat with no UUID cannot prove it.
    public func isOnSameVolume(asNow current: FileIdentityStamp,
                               legacyVolume: LegacyVolumeRule = .deviceMustMatch) -> Bool {
        if let mine = volumeUUID { return current.volumeUUID == mine }
        switch legacyVolume {
        case .deviceMustMatch: return device == current.device
        case .notCompared: return true
        }
    }

    /// Same volume, inode, size and mtime — the fields a rename cannot
    /// change. For comparing a file across a move (the quarantine step).
    /// self = the file NOW; `stored` = the stamp taken before the move.
    public func matchesIgnoringChangeTime(_ stored: FileIdentityStamp) -> Bool {
        stored.describesSameFile(now: self, changeTime: .ignored)
    }

    /// True when both stamps name ONE inode on one device — two names for
    /// the same file (hard link, or two spellings on a case-insensitive
    /// volume). Deleting "the duplicate" would delete the only copy.
    /// SAME-INSTANT only (two stats of one pass): a device number is valid
    /// only for the mount it was read on.
    public func isSameFile(as other: FileIdentityStamp) -> Bool {
        device == other.device && inode == other.inode
    }

    /// nil when the path cannot be stat'ed (missing, permission, offline
    /// volume) — callers treat that as "cannot verify", never as a match.
    ///
    /// The volume UUID is read BETWEEN two stats and kept only when both
    /// stats name the same device + inode — so it is the UUID of the
    /// volume the stamped file was on, even if a mount changed under the
    /// call (then the UUID is nil: identity not proven). The returned
    /// fields are the second stat's.
    public static func capture(path: String) -> FileIdentityStamp? {
        var first = stat()
        guard stat(path, &first) == 0 else { return nil }
        let uuid = VolumeIdentity.uuid(forPath: path)
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let bound = first.st_dev == info.st_dev && first.st_ino == info.st_ino
        return FileIdentityStamp(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mtimeNs: Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_mtimespec.tv_nsec),
            ctimeNs: Int64(info.st_ctimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_ctimespec.tv_nsec),
            volumeUUID: bound ? uuid : nil)
    }
}

/// A whole-file digest with the stamp of the file it describes.
public struct ContentFixity: Codable, Equatable, Hashable, Sendable {
    /// "sha256" today; the tag exists so a future algorithm never has to
    /// reinterpret old digests.
    public let algorithm: String
    /// Lowercase hex SHA-256 of EVERY byte of the file — the same value
    /// `CatalogStore.sha256HexStreaming` and the archive manifest carry,
    /// so the archive's fixity and the verification gate's agree.
    public let digest: String
    /// Bytes the digest covers. Always equals `stamp.size`; kept
    /// separately so a digest can be compared without a stamp.
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

    /// The USER-VISIBLE stamp check: same volume, inode, size and mtime.
    /// Enough to say "nothing ordinary touched this file"; NOT enough to
    /// stand in for a read — a same-size in-place rewrite with the mtime
    /// put back reproduces all four. Diagnostics and tests use this; the
    /// verification gate uses `describesFileNow`. A nil `current` (stat
    /// failed) never matches.
    public func stampMatches(_ current: FileIdentityStamp?) -> Bool {
        guard let current else { return false }
        return stamp.describesSameFile(now: current, changeTime: .ignored) && current.size == byteCount
    }

    /// Stat `path` now and compare (user-visible stamp).
    public func stampMatches(path: String) -> Bool {
        stampMatches(FileIdentityStamp.capture(path: path))
    }

    /// The VERIFICATION-GRADE check: same volume (UUID, or the legacy
    /// device rule), inode, size, mtime AND kernel ctime, with a stored
    /// stamp that carries one. Only this may let the stored digest stand
    /// in for reading the file.
    public func describesFileNow(_ current: FileIdentityStamp?) -> Bool {
        guard let current else { return false }
        return stamp.describesSameFile(now: current, changeTime: .mustMatch) && current.size == byteCount
    }

    /// True when this fixity can ever satisfy `describesFileNow`: sha256
    /// with a ctime-bearing stamp. A pre-ctime fixity is "absent" to the
    /// gate — one re-read replaces it.
    public var isUsableForVerification: Bool {
        algorithm == Self.sha256 && stamp.hasChangeTime
    }

    /// Build a fixity for a file that was JUST hashed in full: stat it and
    /// bind the digest to that stamp. When `before` (a stamp taken BEFORE
    /// the read) is given, the after-stamp must equal it — the file must
    /// not have changed under the read — as `SignatureVerification.verify`
    /// requires. nil when the stat fails, the size on disk no longer
    /// equals the byte count hashed, or before ≠ after.
    public static func captured(path: String, digest: String, byteCount: Int64,
                                before: FileIdentityStamp? = nil,
                                computedAt: Date = Date()) -> ContentFixity? {
        guard !digest.isEmpty, let stamp = FileIdentityStamp.capture(path: path),
              stamp.size == byteCount else { return nil }
        if let before, before != stamp { return nil }
        return ContentFixity(digest: digest, byteCount: byteCount, stamp: stamp, computedAt: computedAt)
    }

    // MARK: - Upgrading a pre-UUID stamp

    /// What `upgradedToVolumeIdentity` concluded for one record.
    public enum VolumeIdentityUpgrade: Equatable, Sendable {
        /// The stamp already carries a volume UUID — nothing to do.
        case alreadyBound
        /// Proven: the same file on the same volume. Store this fixity
        /// (same digest and computedAt, stamp = the stat taken now).
        case upgraded(ContentFixity)
        /// Not proven — left exactly as it is (stale until a re-read).
        case notUpgraded(Reason)

        public enum Reason: String, Sendable, CaseIterable {
            /// Pre-ctime or non-sha256 — never usable; a re-read replaces it.
            case notUsable = "not usable for verification"
            /// The file cannot be stat'ed now.
            case offline = "offline"
            /// Inode, size, mtime or ctime differ — a different or changed file.
            case fileChanged = "file changed"
            /// The volume reports no UUID now (or a mount raced the stat).
            case noVolumeIdentityNow = "volume identity unavailable"
            /// Device differs and the record's scan-time volume UUID is
            /// missing or differs from today's — cannot prove same disk.
            case volumeNotProven = "volume not proven"
        }
    }

    /// Bind a pre-UUID stamp to today's volume UUID — ONLY when proven.
    /// `current` = a stat of the record's path taken now;
    /// `recordVolumeUUID` = the UUID the record was scanned from
    /// (`ScanContext.volumeUUID`; "" when unknown). See the file header.
    public func upgradedToVolumeIdentity(current: FileIdentityStamp?,
                                         recordVolumeUUID: String) -> VolumeIdentityUpgrade {
        guard stamp.volumeUUID == nil else { return .alreadyBound }
        guard isUsableForVerification else { return .notUpgraded(.notUsable) }
        guard let current else { return .notUpgraded(.offline) }
        guard stamp.inode == current.inode, stamp.size == current.size,
              stamp.mtimeNs == current.mtimeNs, stamp.ctimeNs == current.ctimeNs,
              current.size == byteCount else { return .notUpgraded(.fileChanged) }
        guard let nowUUID = current.volumeUUID else { return .notUpgraded(.noVolumeIdentityNow) }
        // Same mount (legacy rule — already fresh today), or a remount of
        // the very volume the record was scanned from.
        let sameMount = stamp.device == current.device
        let scannedFromThisVolume = VolumeIdentity.normalized(recordVolumeUUID) == nowUUID
        guard sameMount || scannedFromThisVolume else { return .notUpgraded(.volumeNotProven) }
        return .upgraded(ContentFixity(algorithm: algorithm, digest: digest, byteCount: byteCount,
                                       stamp: current, computedAt: computedAt))
    }
}
