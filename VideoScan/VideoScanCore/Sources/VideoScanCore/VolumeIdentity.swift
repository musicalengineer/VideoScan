// VolumeIdentity.swift
// Which VOLUME a path lives on, in a form that survives a remount
// (2026-09-23, fixity-stamp volume identity).
//
// `st_dev` is NOT a volume identity. macOS hands out device numbers when a
// volume mounts, so the same disk gets a different one after every
// replug / reboot — and a number one disk gave up is later handed to a
// DIFFERENT disk. Both were measured on Rick's catalog on 2026-09-23:
// 1,429 of 1,493 stored fixity stamps differed from today's stat only in
// `st_dev`, and 16777252 had been LaCieWorkspace's number before it became
// Projects'. So a device number can neither prove "same disk" after a
// remount nor be used as a cache key for one.
//
// The volume UUID can. It is read with ONE `getattrlist(ATTR_VOL_UUID)`
// on the path itself (the kernel answers for the volume holding it; the
// same value NSURL's `volumeUUIDStringKey`, `diskutil info` and
// `ScanContext.volumeUUID` report). Cost ≈ 3 µs — cheaper than NSURL's
// resource-value path (≈ 8 µs) and with NO cache: a cache would have to be
// keyed by something that identifies a mount, and nothing cheap does
// (see above). Callers run it off the main actor, next to the `stat`
// they already do.
//
// nil — "cannot say" — for an unstat-able path, a filesystem that reports
// no UUID (some network/FAT volumes), or the all-zero UUID. Callers treat
// nil as "identity not proven", never as a match.
//
// (For Rick: `@TaskLocal` ≈ a thread_local override that is inherited by
// child tasks and automatically popped at the end of `withValue { }` — a
// scoped test seam that can never leak into another test the way a global
// would.)

import Darwin
import Foundation

public enum VolumeIdentity {

    /// TEST SEAM — task-local, never process-global. When set, it answers
    /// instead of the kernel (e.g. to simulate a different disk mounted at
    /// the same path, or a volume with no UUID).
    /// `VolumeIdentity.$resolverOverride.withValue({ _ in "X" }) { … }`.
    @TaskLocal public static var resolverOverride: (@Sendable (String) -> String?)? = nil

    /// The UUID of the volume holding `path` (uppercase canonical form),
    /// or nil when it cannot be established.
    public static func uuid(forPath path: String) -> String? {
        if let resolverOverride { return resolverOverride(path).flatMap(normalized) }
        return kernelVolumeUUID(path)
    }

    /// Canonical spelling for comparison: uppercase, trimmed; nil for an
    /// empty or all-zero UUID (no identity at all).
    public static func normalized(_ uuid: String) -> String? {
        let u = uuid.trimmingCharacters(in: .whitespaces).uppercased()
        guard !u.isEmpty, u != "00000000-0000-0000-0000-000000000000" else { return nil }
        return u
    }

    /// `getattrlist(path, ATTR_VOL_INFO|ATTR_VOL_UUID)`. Volume attributes
    /// may be asked of any path on the volume. They cannot be combined
    /// with common attributes (EINVAL), which is why `FileIdentityStamp.
    /// capture` brackets this call between two stats instead.
    private static func kernelVolumeUUID(_ path: String) -> String? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_UUID)
        // Reply layout: u_int32_t total length, then the uuid_t (16 bytes).
        var reply = [UInt8](repeating: 0, count: 64)
        let rc = reply.withUnsafeMutableBytes { getattrlist(path, &request, $0.baseAddress, $0.count, 0) }
        guard rc == 0 else { return nil }
        return reply.withUnsafeBytes { raw -> String? in
            let length = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            guard length >= 4 + 16 else { return nil }
            let u = raw.loadUnaligned(fromByteOffset: 4, as: uuid_t.self)
            return normalized(UUID(uuid: u).uuidString)
        }
    }
}
