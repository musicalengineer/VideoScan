// ArchiveIndexLock.swift
// ONE write exclusion for the Master Archive's 00_Index (codex review of
// Refile, finding 1, 2026-09-27). Before this, a whole-file index rewrite
// (Catalog rename carried to the index, Refile) checked each index file's
// identity and then replaced it — two steps — while Promote could append a
// manifest / journal row in between, and that row was silently dropped by
// the replace (and again by a rollback's restore).
//
// Now every writer of an index file holds this lock for the whole of its
// write:
//   • ArchiveIndexRename.apply — from the identity recheck through the
//     media move, the publish AND any rollback (Catalog rename, Refile);
//   • every append: the manifest row (Promote), the promote journal, the
//     decisions log, the attestation journal.
// A writer that cannot get it within a short wait REFUSES — logged — and
// never waits unboundedly (appends run on the Promote job's actor; a
// beachball is not an acceptable way to wait).
//
// Mechanism: flock(2) LOCK_EX on the 00_Index DIRECTORY itself, opened
// through the O_NOFOLLOW descriptor chain (no lock file to clutter the
// index; the same idea as the #204 `.rename_backups` lock). flock locks
// belong to the open file description, so two opens in the SAME process
// exclude each other too. UNVERIFIED across machines on SMB / exFAT (the
// same caveat as #204): there the lock may not exclude another Mac.
//
// (For Rick: ≈ a named mutex around the index files, with try-lock and a
// timeout instead of an unbounded wait.)

import Darwin
import Foundation
import os

private let indexLockLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveIndexLock")

enum ArchiveIndexLock {

    /// The default wait before a writer refuses. Short on purpose: the
    /// long holder is a Refile (two whole-file hashes); a Promote append
    /// that meets it fails its file, and the promote journal converges it
    /// on the next run (the existing crash-recovery path).
    static let defaultWait: Duration = .milliseconds(250)

    /// The lock is held by someone else.
    struct Busy: Error, CustomStringConvertible, Equatable {
        let wanted: String
        let heldBy: String?
        var description: String {
            "the archive index is busy (\(heldBy ?? "another writer") is updating it) — \(wanted) was refused; nothing was written"
        }
    }

    /// In-process record of who holds it, for the refusal line only.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var holders: [String: String] = [:]

    /// Run `body` holding the exclusive index lock for `root`. Throws
    /// `Busy` (logged) when it is not free within `wait`; rethrows what the
    /// index directory open or `body` throws.
    static func withExclusive<T>(root: String, holder: String, wait: Duration = defaultWait,
                                 _ body: () throws -> T) throws -> T {
        let fd = try ArchivePromoteEngine.openIndexDirectory(root: root)
        defer { Darwin.close(fd) }
        let deadline = ContinuousClock.now + wait
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            if e == EINTR { continue }
            guard e == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO) }
            if ContinuousClock.now >= deadline {
                let other = registryLock.withLock { holders[root] }
                let busy = Busy(wanted: holder, heldBy: other)
                appLog.write("archive index: \(busy.description) (\(root))")
                indexLockLog.notice("index lock busy: \(holder, privacy: .public) refused; held by \(other ?? "?", privacy: .public)")
                throw busy
            }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }
        registryLock.withLock { holders[root] = holder }
        defer { registryLock.withLock { _ = holders.removeValue(forKey: root) } }
        return try body()
    }
}
