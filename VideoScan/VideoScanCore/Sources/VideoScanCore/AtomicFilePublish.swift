import Foundation

/// Publishing a file at its final name, atomically, without `RENAME_SWAP`.
///
/// ## Why this exists instead of `FileManager.replaceItemAt`
///
/// On APFS `FileManager.replaceItemAt(_:withItemAt:)` is implemented with
/// `renameatx_np(… RENAME_SWAP)`. `Sandbox.kext` hooks that syscall in
/// `hook_vnode_notify_will_rename_swap`, where it takes an `IORWLock`
/// **exclusively and keeps holding it** for the duration of the VFS rename.
/// The holding thread then sleeps in `vfs_subr.c` waiting on a vnode whose
/// iocount belongs to a second thread — which is itself parked in the same
/// hook waiting for that rwlock. ABBA deadlock, inside the kernel.
///
/// The consequences are severe and not recoverable from user space: the
/// threads never return, so the process becomes an unkillable `?E` zombie
/// (`kill -9` cannot touch a thread blocked in the kernel), the rwlock is
/// never released, and later processes of the same app block on it too.
/// Only a reboot clears it. This cost Rick a live demo on 2026-09-14.
///
/// Measured on 2026-09-14 (M1, macOS 26.6.2, plain unsandboxed Python —
/// nothing app-specific about it):
///
/// | workload                                        | result              |
/// |-------------------------------------------------|---------------------|
/// | 2 threads, `RENAME_SWAP`, **same** path pair     | wedged after 26 ops |
/// | 8 threads, `RENAME_SWAP`, disjoint pairs, 1 dir  | 40,000 ops, 4.9 s   |
/// | 8 threads, `rename(2)`, **same** destination     | 32,000 ops, 12.7 s  |
///
/// So the trigger is precisely *two concurrent rename-swaps touching one
/// destination* — which is exactly what an "atomic save" store does when two
/// saves race (an apply and its immediate undo, say). Plain `rename(2)` is
/// just as atomic on APFS, takes a different Sandbox hook, and is immune.
///
/// Full evidence, both spindumps and the symbolicated kernel stacks:
/// `docs/incident_2026_09_14_sandbox_rename_wedge.md`.
///
/// - Important: Do not reintroduce `replaceItemAt` anywhere in this project.
///   `AtomicFilePublishSensorTests` fails the build if it reappears.
public enum AtomicFilePublish {

    public struct Failure: Error, CustomStringConvertible {
        public let source: URL
        public let destination: URL
        public let errnoValue: Int32
        public var description: String {
            "rename(\(source.path) -> \(destination.path)) failed: "
            + String(cString: strerror(errnoValue)) + " (errno \(errnoValue))"
        }
    }

    /// Move `source` onto `destination`, replacing whatever is there, as one
    /// atomic step.
    ///
    /// `source` must already be a fully written file on the **same volume** as
    /// `destination` — the usual shape is a uniquely named temp file in the
    /// destination's own directory. A reader either sees the whole old file or
    /// the whole new one, never a partial write.
    ///
    /// - Note: Unlike `replaceItemAt`, this does not carry the destination's
    ///   previous metadata over to the new file; the new file keeps its own.
    ///   Every call site here writes self-describing JSON sidecars, where that
    ///   is the behaviour we want anyway.
    public static func replaceItem(at destination: URL, withItemAt source: URL) throws {
        if rename(source.path, destination.path) != 0 {
            throw Failure(source: source, destination: destination, errnoValue: errno)
        }
    }
}
