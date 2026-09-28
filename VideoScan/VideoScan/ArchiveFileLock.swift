// ArchiveFileLock.swift
// Locked archive files (Rick 2026-09-27): "once it's in the archive, nothing
// but Update… can change or delete it." Each archived MEDIA FILE carries the
// macOS user-immutable flag (UF_IMMUTABLE — what `chflags uchg` sets and
// Finder shows as "Locked"). While it is set the kernel itself refuses
// unlink, rename and write on that file (EPERM), for this app, for Finder,
// for a stray `rm` — the rule no longer depends on every code path
// remembering to ask ArchiveVolumeProtection.
//
// What is NOT locked:
//   • folders — Promote must keep adding files to them;
//   • 00_Index/ — the manifest and journals are appended to;
//   • the system flag (SF_IMMUTABLE, `schg`) — never used: only root can
//     clear it, so a mistake could not be undone from the app.
//
// Who may change the flag — the ONLY callers, inventoried (with reasons) in
// `ArchiveVolumeProtection.fileLockInventory` and pinned by a source sensor
// (ArchiveFileLockSensorTests):
//   • Promote            — sets it after fixity verification;
//   • Update… (Refile)   — clears it on the source, re-sets it on the target
//                          (and at the original on a rollback);
//   • "Lock files already in the archive (one-time)…" — the catch-up job.
// Clearing is refused for any other reason (`Reason.mayUnlock`).
//
// Every change goes through `set(_:…)`, which writes one audit line through
// the caller's sink. The flag change itself is `fchflags(2)` on a descriptor
// opened THROUGH the archive's dirfd O_NOFOLLOW chain
// (ArchivePromoteEngine.openContainedFile) — a symlink or a path outside the
// root is refused before any flag is touched.
//
// Memory: O(1) per call (one descriptor, one fstat). Worst case for the
// lock-all job over 100k rows is the manifest's row list, not this file.
//
// (For Rick: `fchflags` ≈ the BSD chflags(2) you know, applied through an
// fd so the path cannot be swapped between the check and the change. A
// `struct` of `@Sendable` closures ≈ a table of std::function the tests can
// replace — the job and the engine receive it explicitly, never via a
// global.)

import Darwin
import Foundation
import os

let archiveLockLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveLock")

enum ArchiveFileLock {

    enum Change: String, Sendable { case lock, unlock }

    /// Why a flag is being changed — part of every audit line, and the gate
    /// on who may CLEAR it.
    enum Reason: String, Sendable, CaseIterable {
        /// Promote, after the copy's fixity was verified.
        case promote
        /// Update…: cleared on the file about to be moved.
        case updateUnlock
        /// Update…: re-set on the file at its new place.
        case updateRelock
        /// Update… rolled back: re-set at the original place.
        case updateRollbackRelock
        /// The one-time catch-up job (files promoted before locking existed).
        case lockAll

        /// Only Update… (to move the file) may clear the flag. Nothing else,
        /// ever (Rick 2026-09-27: no Unlock job — `chflags` in Terminal).
        var mayUnlock: Bool { self == .updateUnlock }
    }

    /// What happened to one file.
    enum Result: Equatable, Sendable {
        /// The flag is now as requested; it was not before.
        case changed
        /// The flag already was as requested — nothing written.
        case alreadySo
        /// No file at that path.
        case absent
        /// Refused or failed — nothing changed (the reason says why).
        case failed(String)

        var isOK: Bool { self == .changed || self == .alreadySo }
    }

    /// The two primitives, injectable. Production = `.live`.
    struct Seams: Sendable {
        /// Set or clear UF_IMMUTABLE on one archive-relative file.
        var apply: @Sendable (_ root: String, _ relPath: String, _ change: Change) -> Result
        /// nil = absent or unreadable; else whether UF_IMMUTABLE is set.
        var isLocked: @Sendable (_ root: String, _ relPath: String) -> Bool?

        static let live = Seams(apply: { ArchiveFileLock.liveApply(root: $0, relPath: $1, change: $2) },
                                isLocked: { ArchiveFileLock.liveIsLocked(root: $0, relPath: $1) })
    }

    // MARK: - The one audited entry point

    /// Change the flag on ONE archived file. Refuses to clear it for any
    /// reason that is not allowed to (`Reason.mayUnlock`). `audit` receives
    /// one line (console + catalog.log + videoscan.log in production).
    @discardableResult
    static func set(_ change: Change, root: String, relPath: String, reason: Reason,
                    seams: Seams = .live, audit: (String) -> Void) -> Result {
        if change == .unlock, !reason.mayUnlock {
            let why = "clearing the lock is not allowed for \(reason.rawValue) — only Update… may"
            audit("Archive lock: REFUSED to unlock \(relPath) — \(why)")
            archiveLockLog.fault("unlock refused for \(reason.rawValue, privacy: .public): \(relPath, privacy: .public)")
            return .failed(why)
        }
        let result = seams.apply(root, relPath, change)
        switch result {
        case .changed:
            audit("Archive lock: \(change == .lock ? "locked" : "UNLOCKED") \(relPath) (\(reason.rawValue))")
        case .alreadySo:
            archiveLockLog.debug("\(change.rawValue, privacy: .public) no-op (already so): \(relPath, privacy: .public)")
        case .absent:
            audit("Archive lock: \(relPath) — no file there; nothing \(change == .lock ? "locked" : "unlocked") (\(reason.rawValue))")
        case .failed(let why):
            audit("Archive lock: could NOT \(change.rawValue) \(relPath) (\(reason.rawValue)) — \(why)")
            archiveLockLog.error("\(change.rawValue, privacy: .public) failed: \(relPath, privacy: .public) — \(why, privacy: .public)")
        }
        return result
    }

    // MARK: - Live primitives (DISK I/O — call off the main actor)

    /// fchflags(2) through the contained dirfd chain. Only UF_IMMUTABLE is
    /// touched; every other flag bit is kept.
    nonisolated static func liveApply(root: String, relPath: String, change: Change) -> Result {
        let fd: Int32
        do {
            guard let opened = try ArchivePromoteEngine.openContainedFile(root: root, relativePath: relPath) else {
                return .absent
            }
            fd = opened
        } catch {
            return .failed("the file cannot be opened safely (\(ArchiveAttestationJournal.describe(error)))")
        }
        defer { Darwin.close(fd) }
        var sb = stat()
        guard fstat(fd, &sb) == 0 else { return .failed("stat failed (errno \(errno))") }
        let immutable = UInt32(UF_IMMUTABLE)
        let isSet = (sb.st_flags & immutable) != 0
        if (change == .lock) == isSet { return .alreadySo }
        let flags = change == .lock ? (sb.st_flags | immutable) : (sb.st_flags & ~immutable)
        guard fchflags(fd, flags) == 0 else {
            let e = errno
            return .failed("chflags failed (\(String(cString: strerror(e))), errno \(e))")
        }
        return .changed
    }

    nonisolated static func liveIsLocked(root: String, relPath: String) -> Bool? {
        guard let fd = try? ArchivePromoteEngine.openContainedFile(root: root, relativePath: relPath) else { return nil }
        defer { Darwin.close(fd) }
        var sb = stat()
        guard fstat(fd, &sb) == 0 else { return nil }
        return (sb.st_flags & UInt32(UF_IMMUTABLE)) != 0
    }
}

// MARK: - The audit sink

extension VideoScanModel {
    /// One lock/unlock line → videoscan.log and the unified log right away
    /// (a hang leaves its line), and the console / catalog.log in order on
    /// the main actor. Safe to call from a disk thread.
    func archiveLockAuditSink() -> @Sendable (String) -> Void {
        { [weak self] line in
            appLog.write("[archive-lock] " + line)
            archiveLockLog.notice("\(line, privacy: .public)")
            Task { @MainActor [weak self] in self?.log(line) }
        }
    }
}
