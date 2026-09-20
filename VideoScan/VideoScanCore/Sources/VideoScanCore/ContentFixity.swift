// ContentFixity.swift
// Full-file fixity for ANY catalog record (Rick 2026-09-20, Delete
// Duplicates: "look at precomputed hash IDs … if we must compare
// byte-for-byte, only do one file, the one being deleted").
//
// `ArchiveFixity` is the Master Archive's read-back proof and lives only on
// archive copies. This is the general one: whenever the app has hashed a
// whole file — a keeper during duplicate verification, an archive copy at
// promotion or audit — the digest is kept HERE together with a stat stamp
// (device, inode, size, mtime to the nanosecond) of the file the digest
// describes. A later stat that reproduces the stamp means the bytes have
// not been rewritten or replaced, so the stored digest may stand in for a
// fresh read of that side.
//
// What this is NOT: `contentHash` (the v1 segmented candidate signature)
// and `partialMD5` sample a few windows and can never prove two files the
// same (design #320). Nothing here weakens that rule: the file being
// DELETED is always read in full at the moment of deletion; the stamp only
// spares a second full read of the file that survives.
//
// (For Rick: two POD structs. `FileIdentityStamp` ≈ the four `struct stat`
// fields that change when a file is replaced or rewritten; `ContentFixity`
// ≈ digest + byte count + that stamp + when it was computed.)

import Darwin
import Foundation

/// Filesystem identity + mutation stamp from ONE `stat` call.
/// Device + inode detect a path replacement; size + nanosecond mtime
/// detect an in-place rewrite. `stat` follows symlinks on purpose — it
/// describes the bytes a reader would actually hash.
public struct FileIdentityStamp: Codable, Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    /// Modification time as nanoseconds since the epoch (tv_sec * 1e9 +
    /// tv_nsec) — one integer, no float rounding, Codable as-is.
    public let mtimeNs: Int64

    public init(device: UInt64, inode: UInt64, size: Int64, mtimeNs: Int64) {
        self.device = device
        self.inode = inode
        self.size = size
        self.mtimeNs = mtimeNs
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
            mtimeNs: Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_mtimespec.tv_nsec))
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

    /// True when the file at rest still matches the one that was hashed:
    /// same device, inode, size and nanosecond mtime. A nil `current`
    /// (stat failed) never matches.
    public func stampMatches(_ current: FileIdentityStamp?) -> Bool {
        guard let current else { return false }
        return current == stamp && current.size == byteCount
    }

    /// Stat `path` now and compare.
    public func stampMatches(path: String) -> Bool {
        stampMatches(FileIdentityStamp.capture(path: path))
    }

    /// Build a fixity for a file that was JUST hashed in full: stat it and
    /// bind the digest to that stamp. nil when the stat fails or the size
    /// on disk no longer equals the byte count hashed (the file changed
    /// under the read — a digest nobody can reproduce must not be kept).
    public static func captured(path: String, digest: String, byteCount: Int64,
                                computedAt: Date = Date()) -> ContentFixity? {
        guard !digest.isEmpty, let stamp = FileIdentityStamp.capture(path: path),
              stamp.size == byteCount else { return nil }
        return ContentFixity(digest: digest, byteCount: byteCount, stamp: stamp, computedAt: computedAt)
    }
}
