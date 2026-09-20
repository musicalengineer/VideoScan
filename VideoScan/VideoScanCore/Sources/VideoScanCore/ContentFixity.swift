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
// What this is NOT: `contentHash` (the v1 segmented candidate signature)
// and `partialMD5` sample a few windows and can never prove two files the
// same (design #320). Nothing here weakens that rule: the file being
// DELETED is always read in full at the moment of deletion; the stamp only
// spares a second full read of the file that survives.
//
// (For Rick: two POD structs. `FileIdentityStamp` ≈ the `struct stat`
// fields that change when a file is replaced or rewritten; `ContentFixity`
// ≈ digest + byte count + that stamp + when it was computed.)

import Darwin
import Foundation

/// Filesystem identity + mutation stamp from ONE `stat` call.
/// Device + inode detect a path replacement; size + nanosecond mtime
/// detect an in-place rewrite by a well-behaved writer; nanosecond ctime
/// detects one that put the mtime back. `stat` follows symlinks on
/// purpose — it describes the bytes a reader would actually hash.
public struct FileIdentityStamp: Codable, Equatable, Hashable, Sendable {
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

    public static let unknownCtime: Int64 = -1

    public init(device: UInt64, inode: UInt64, size: Int64, mtimeNs: Int64,
                ctimeNs: Int64 = FileIdentityStamp.unknownCtime) {
        self.device = device
        self.inode = inode
        self.size = size
        self.mtimeNs = mtimeNs
        self.ctimeNs = ctimeNs
    }

    private enum CodingKeys: String, CodingKey { case device, inode, size, mtimeNs, ctimeNs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decode(UInt64.self, forKey: .device)
        inode = try c.decode(UInt64.self, forKey: .inode)
        size = try c.decode(Int64.self, forKey: .size)
        mtimeNs = try c.decode(Int64.self, forKey: .mtimeNs)
        // Schema: a stamp saved without ctime is a pre-ctime stamp.
        ctimeNs = try c.decodeIfPresent(Int64.self, forKey: .ctimeNs) ?? Self.unknownCtime
    }

    /// True when the stamp carries a kernel ctime — the only kind that may
    /// stand in for a read.
    public var hasChangeTime: Bool { ctimeNs != Self.unknownCtime }

    /// Same device, inode, size and mtime — the fields a rename cannot
    /// change. For comparing a file across a move (the quarantine step);
    /// everywhere else the full stamp, ctime included, is the identity.
    public func matchesIgnoringChangeTime(_ other: FileIdentityStamp) -> Bool {
        device == other.device && inode == other.inode && size == other.size && mtimeNs == other.mtimeNs
    }

    /// True when both stamps name ONE inode on one device — two names for
    /// the same file (hard link, or two spellings on a case-insensitive
    /// volume). Deleting "the duplicate" would delete the only copy.
    public func isSameFile(as other: FileIdentityStamp) -> Bool {
        device == other.device && inode == other.inode
    }

    /// nil when the path cannot be stat'ed (missing, permission, offline
    /// volume) — callers treat that as "cannot verify", never as a match.
    public static func capture(path: String) -> FileIdentityStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentityStamp(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mtimeNs: Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_mtimespec.tv_nsec),
            ctimeNs: Int64(info.st_ctimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_ctimespec.tv_nsec))
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

    /// The USER-VISIBLE stamp check: same device, inode, size and mtime.
    /// Enough to say "nothing ordinary touched this file"; NOT enough to
    /// stand in for a read — a same-size in-place rewrite with the mtime
    /// put back reproduces all four. Diagnostics and tests use this; the
    /// verification gate uses `describesFileNow`. A nil `current` (stat
    /// failed) never matches.
    public func stampMatches(_ current: FileIdentityStamp?) -> Bool {
        guard let current else { return false }
        return current.device == stamp.device && current.inode == stamp.inode
            && current.size == stamp.size && current.mtimeNs == stamp.mtimeNs
            && current.size == byteCount
    }

    /// Stat `path` now and compare (user-visible stamp).
    public func stampMatches(path: String) -> Bool {
        stampMatches(FileIdentityStamp.capture(path: path))
    }

    /// The VERIFICATION-GRADE check: `stampMatches` AND the kernel ctime
    /// reproduces AND the stored stamp carries one. Only this may let the
    /// stored digest stand in for reading the file.
    public func describesFileNow(_ current: FileIdentityStamp?) -> Bool {
        guard let current, stamp.hasChangeTime, stampMatches(current) else { return false }
        return current.ctimeNs == stamp.ctimeNs
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
}
