// CatalogFileGuard.swift (VideoScanCore/Store)
// GH #359 (P1, Rick's fail-fast ruling 2026-10-21): the store notices when
// catalog.sqlite — or the latch `catalog.cutover` beside it — is no longer
// the file it opened, and refuses every later commit BEFORE writing.
//
// Why the store must look for itself: an open SQLite connection keeps its
// file descriptor, and a descriptor follows the inode, not the name. When
// catalog.sqlite is moved aside (a restore, a sync tool, Finder) the session
// goes on writing into the moved-aside file. Apple's SQLite can refuse with
// SQLITE_IOERR_VNODE (extended code 6922), but that comes from a file-system
// notice that arrives asynchronously: under load, commits landed in the
// moved-aside file (generation 2 → 3 → 4). This check is synchronous.
//
// The rule:
//   - at open the repository records the device + inode (`stat(2)`) of the
//     database file and, when it is there, of the latch beside it;
//   - before every commit transaction, before the high-water publish and
//     again just before COMMIT, both are compared; a database that is gone
//     or is another file, or a latch that was present at open and is now
//     gone or another file, is a violation, with the words below;
//   - a latch that was NOT there at open (a bare store, the importer before
//     the switch) is not watched.
//
// What it cannot do: a stat and a write are two system calls, so a file
// replaced in the microseconds between the last check and COMMIT is still
// written. The window used to be the whole session; it is now the time
// between one stat and the COMMIT that follows it.
//
// For Rick: `stat` here is the C call — device + inode is the identity a
// file keeps across renames, the same pair `ls -i` shows with the device.

import Foundation
import os

/// A file's identity on disk: the device and inode `stat(2)` reports.
struct CatalogFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    /// What `stat(2)` says at `url` now: the identity, or the errno.
    enum Reading: Equatable, Sendable {
        case file(CatalogFileIdentity)
        case missing
        case unreadable(errno: Int32)
    }

    static func read(_ url: URL) -> Reading {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return stat(path, &info)
        }
        guard result == 0 else {
            let code = errno
            return code == ENOENT ? .missing : .unreadable(errno: code)
        }
        return .file(CatalogFileIdentity(device: info.st_dev, inode: info.st_ino))
    }
}

/// The identities a session recorded at open, and the check run before
/// every commit. A value type: it is copied into each write's plan.
struct CatalogFileGuard: Equatable, Sendable {
    let databaseURL: URL
    let database: CatalogFileIdentity
    let latchURL: URL
    /// nil: there was no latch at open, so the latch is not watched.
    let latch: CatalogFileIdentity?

    /// The latch's name beside the database (the core's copy of
    /// `CatalogAuthority.latchFileName`).
    static let latchFileName = SQLiteCatalogReader.latchFileName

    /// Record both identities now. Throws the words when the database file
    /// itself cannot be identified (fail closed: a session that cannot be
    /// checked cannot write).
    static func record(databaseAt url: URL) throws -> CatalogFileGuard {
        let latchURL = url.deletingLastPathComponent().appendingPathComponent(latchFileName)
        guard case .file(let database) = CatalogFileIdentity.read(url) else {
            throw GuardFailure(words: "\(url.lastPathComponent) could not be identified when it was opened (\(describe(CatalogFileIdentity.read(url))))")
        }
        var latch: CatalogFileIdentity?
        if case .file(let identity) = CatalogFileIdentity.read(latchURL) { latch = identity }
        return CatalogFileGuard(databaseURL: url, database: database, latchURL: latchURL, latch: latch)
    }

    /// The same, for the file a pool has just opened. `before` is what was
    /// at `url` BEFORE the pool opened it: a file that existed then and is
    /// another file now was swapped DURING the open, and the open is
    /// refused, so a session never writes a file it did not check.
    static func record(databaseAt url: URL, before: CatalogFileIdentity.Reading) throws -> CatalogFileGuard {
        let recorded = try record(databaseAt: url)
        if case .file = before, before != .file(recorded.database) {
            throw GuardFailure(words: replacedWords(url.lastPathComponent, "was replaced while it was being opened"))
        }
        return recorded
    }

    struct GuardFailure: Error {
        let words: String
    }

    /// nil when both files are still the ones recorded at open; else the
    /// words the refused commit carries (Rick's ruling, 10/21).
    func violation() -> String? {
        let now = CatalogFileIdentity.read(databaseURL)
        if now != .file(database) {
            return Self.replacedWords(databaseURL.lastPathComponent, Self.what(now, else: "was replaced or moved"))
        }
        guard let latch else { return nil }
        let latchNow = CatalogFileIdentity.read(latchURL)
        if latchNow != .file(latch) {
            return Self.replacedWords(latchURL.lastPathComponent, Self.what(latchNow, else: "was replaced or removed"))
        }
        return nil
    }

    /// A stat that failed for another reason than "no such file" (EACCES,
    /// EIO) is still a refusal — the file cannot be shown to be the same.
    private static func what(_ reading: CatalogFileIdentity.Reading, else words: String) -> String {
        if case .unreadable(let code) = reading { return "could not be checked (\(String(cString: strerror(code))))" }
        return words
    }

    /// "catalog.sqlite was replaced or moved while VideoScan was open;
    /// nothing more will be saved — quit and reopen"
    static func replacedWords(_ name: String, _ what: String) -> String {
        "\(name) \(what) while VideoScan was open; nothing more will be saved — quit and reopen"
    }

    private static func describe(_ reading: CatalogFileIdentity.Reading) -> String {
        switch reading {
        case .file: return "identified"
        case .missing: return "no file"
        case .unreadable(let code): return String(cString: strerror(code))
        }
    }
}

private let guardLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "catalogStore")

extension WriterSession {
    /// The session's stop words, or a fresh violation — which becomes the
    /// stop. Sticky: a file moved back does not resume writing; only a new
    /// open (`reset`) clears it. Called by every write (three times), by
    /// adopt and by close.
    func fileStop(_ fileGuard: CatalogFileGuard) -> String? {
        if let words = fileStopped { return words }
        guard let words = fileGuard.violation() else { return nil }
        stopForFile(words)
        guardLog.error("catalog store STOPPED: \(words, privacy: .public)")
        return words
    }
}
