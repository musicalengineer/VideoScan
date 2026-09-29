// VolumeIdentity.swift
// Which VOLUME a file lives on, in a form that survives a remount
// (2026-09-23, fixity-stamp volume identity; codex #1707).
//
// `st_dev` is NOT a volume identity: macOS hands out device numbers per
// mount, and a number one disk gave up is later handed to a DIFFERENT disk
// (both measured on Rick's catalog 2026-09-23).
//
// The PERSISTENT volume UUID is. It is read with `fgetattrlist` /
// `getattrlist` `ATTR_VOL_UUID` — getattrlist(2): "ATTR_VOL_UUID: a uuid_t
// containing the file system UUID". It is the same value Foundation's
// `URLResourceKey.volumeUUIDStringKey` ("the volume's persistent UUID"),
// `diskutil info` (VolumeUUID) and `ScanContext.volumeUUID` report —
// checked equal on BootData, LaCieWorkspace, FamilyArchive and Projects on
// 2026-09-23. It is NOT `volumeIdentifierKey`, which Foundation documents
// as an opaque identifier that is only valid while the volume is mounted
// (per-mount — exactly what we must not use).
//
// Resolution is per FILE, on the descriptor the stamp's fstat used
// (≈ 8–11 µs for open+fstat+fgetattrlist+stat+close): nothing needs caching,
// and a cache would need a key that identifies a mount, which nothing
// cheap does (st_dev is reused).
//
// nil — "cannot say" — for a failed call, a filesystem that reports no
// UUID, or the all-zero UUID. nil is never a wildcard: a stamp without a
// UUID is never usable for the persistent digest policy.
//
// (For Rick: `@TaskLocal` ≈ a thread_local override inherited by child
// tasks and popped at the end of `withValue { }` — a scoped test seam that
// cannot leak into another test the way a global would.)

import Darwin
import Foundation

public enum VolumeIdentity {

    /// TEST SEAM — task-local, never process-global. When set it answers
    /// (by path) instead of the kernel: simulate another disk at the same
    /// path, a volume with no UUID, or a remount between two captures.
    @TaskLocal public static var resolverOverride: (@Sendable (String) -> String?)? = nil

    /// The UUID of the volume holding `path` (uppercase), or nil.
    public static func uuid(forPath path: String) -> String? {
        if let resolverOverride { return resolverOverride(path).flatMap(normalized) }
        return query { getattrlist(path, &$0, $1, $2, 0) }
    }

    /// The UUID of the volume holding the OPEN file `fd`. `path` is only
    /// what the test seam is keyed by.
    public static func uuid(forDescriptor fd: Int32, path: String?) -> String? {
        if let resolverOverride { return resolverOverride(path ?? "").flatMap(normalized) }
        return query { fgetattrlist(fd, &$0, $1, $2, 0) }
    }

    /// Canonical spelling: uppercase, trimmed; nil for empty / all-zero.
    public static func normalized(_ uuid: String) -> String? {
        let u = uuid.trimmingCharacters(in: .whitespaces).uppercased()
        guard !u.isEmpty, u != "00000000-0000-0000-0000-000000000000" else { return nil }
        return u
    }

    /// ATTR_VOL_INFO|ATTR_VOL_UUID. Volume attributes cannot be combined
    /// with common ones (EINVAL) — the stat comes from fstat instead.
    private static func query(_ call: (inout attrlist, UnsafeMutableRawPointer?, Int) -> Int32) -> String? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_UUID)
        // Reply: u_int32_t total length, then the uuid_t (16 bytes).
        var reply = [UInt8](repeating: 0, count: 64)
        let rc = reply.withUnsafeMutableBytes { call(&request, $0.baseAddress, $0.count) }
        guard rc == 0 else { return nil }
        return reply.withUnsafeBytes { raw -> String? in
            guard raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self) >= 4 + 16 else { return nil }
            return normalized(UUID(uuid: raw.loadUnaligned(fromByteOffset: 4, as: uuid_t.self)).uuidString)
        }
    }
}
