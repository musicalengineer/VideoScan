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
//     the switch) is not watched — unless the open REQUIRES it (the app's
//     launch and Reopen, QA r1 D): then no latch, no open (#354 words);
//   - the stop is sticky for the session: adopt, the sealed copy (backup,
//     viewer snapshot) and every write refuse with the same words (QA r1
//     F1, F2), and an engine error that arrives instead is reported in them.
//
// close() after a stop (QA r1 F3, 2026-10-21 — the earlier "keep the
// checkpoint" decision was reversed by evidence): Apple SQLite refuses or
// silently skips the checkpoint once it has noticed the rename, so the
// session's committed frames stay in catalog.sqlite-wal at the PATH, and the
// replacement's next open REPLAYED them into itself (another catalog at
// generation 7 reopened as generation 5, integrity_check clean). So: no
// checkpoint after a stop, and once the pool is closed the -wal and -shm at
// the path — only if they are still this session's own files (device +
// inode recorded when the session first saw them) — are RENAMED into
// `catalog-wal-quarantine-<stamp>/` beside the catalog. Never deleted: put
// back beside the moved-aside file under its name + "-wal", they complete it.
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

// MARK: - The latch an app open requires (QA r1 D)

extension GRDBCatalogRepository {
    /// GH #354's words, ONE place (the app's CatalogAuthority.noLatchWords
    /// returns these): no latch beside the catalog — nothing is opened.
    public static func noLatchWords(folder: URL) -> String {
        let latch = SQLiteCatalogReader.latchFileName
        let database = SQLiteCatalogReader.databaseFileName
        return "No catalog — \(latch) is not beside the catalog in \(folder.path), so this Mac was never switched to "
            + "\(database). catalog.json is not opened (not even read-only): the master (or migrate_data.sh) "
            + "must carry \(database) and its \(latch). Nothing will be saved this session."
    }
}

// MARK: - The session's own -wal and -shm (QA r1 F3)

enum CatalogSidecarQuarantine {
    static let suffixes = ["-wal", "-shm"]

    /// What is at `<database>-wal` / `-shm` now, by suffix (present files only).
    static func identities(besideDatabaseAt url: URL) -> [String: CatalogFileIdentity] {
        var found: [String: CatalogFileIdentity] = [:]
        for suffix in suffixes {
            if case .file(let identity) = CatalogFileIdentity.read(URL(fileURLWithPath: url.path + suffix)) {
                found[suffix] = identity
            }
        }
        return found
    }

    /// After the pool closed, when catalog.sqlite at the path is NOT this
    /// session's file: rename the -wal / -shm at the path into
    /// `catalog-wal-quarantine-<stamp>/` beside the catalog — ONLY those still
    /// this session's own files (`own`); anything else is someone else's and
    /// is left alone. If the folder cannot be made, each file is renamed in
    /// place to `<name>-wal.quarantined-<stamp>` (QA r2-3); if even that
    /// fails, the words name exactly what to move away before reopening.
    /// Never deletes. Returns the START / OUTCOME lines (also written to the
    /// store log) for the app's sink.
    @discardableResult
    /// `folder`: a test seam only (a folder that cannot be made, QA r2-3).
    static func quarantine(besideDatabaseAt url: URL, own: [String: CatalogFileIdentity], why: String,
                           now: Date = Date(), folder override: URL? = nil) -> [String] {
        var lines: [String] = []
        func say(_ line: String) { lines.append(line); guardLog.notice("\(line, privacy: .public)") }
        let name = url.lastPathComponent
        var mine: [String] = []
        for suffix in suffixes {
            let reading = CatalogFileIdentity.read(URL(fileURLWithPath: url.path + suffix))
            guard case .file(let identity) = reading else { continue }
            if let recorded = own[suffix], recorded == identity {
                mine.append(suffix)
            } else {
                say("Catalog store: QUARANTINE — \(name)\(suffix) at the path is not this session's file; left where it is")
            }
        }
        guard !mine.isEmpty else { return lines }
        let folder = override ?? folderName(beside: url, now: now)
        say("Catalog store: START quarantine of this session's \(mine.map { name + $0 }.joined(separator: " and ")) "
            + "into \(folder.lastPathComponent) (\(why)) — renamed, never deleted")
        var folderMade = true
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            folderMade = false
            say("Catalog store: QUARANTINE — \(folder.lastPathComponent) could not be made (\(error.localizedDescription)); renaming in place instead")
        }
        var moved: [String] = []
        var stuck: [String] = []
        for suffix in mine {
            let source = URL(fileURLWithPath: url.path + suffix)
            let target = folderMade
                ? folder.appendingPathComponent(name + suffix)
                : URL(fileURLWithPath: source.path + ".quarantined-" + stamp(now))
            do {
                try FileManager.default.moveItem(at: source, to: target)
                moved.append(target.path)
            } catch {
                stuck.append("\(source.path) (\(error.localizedDescription))")
            }
        }
        if stuck.isEmpty {
            say("Catalog store: OUTCOME quarantine — \(moved.count) file(s) moved: \(moved.joined(separator: ", ")). They hold the "
                + "moved-aside catalog's last commits: put \(name)-wal beside that file under its own name + \"-wal\" to complete it.")
        } else {
            say("Catalog store: OUTCOME quarantine FAILED — nothing was deleted, but these could not be moved: "
                + stuck.joined(separator: "; ") + ". Move them out of \(url.deletingLastPathComponent().path) BEFORE opening VideoScan "
                + "again, or the catalog.sqlite there will take another catalog's commits."
                + (moved.isEmpty ? "" : " Moved: \(moved.joined(separator: ", "))."))
        }
        return lines
    }

    /// The pool did not close (QA r2 nit): nothing is renamed while a
    /// connection may still hold the files — the words say what to move.
    static func skipped(besideDatabaseAt url: URL, because why: String) -> [String] {
        let line = "Catalog store: OUTCOME quarantine SKIPPED — \(why). catalog.sqlite is not this session's file: move "
            + "\(url.path)-wal and \(url.path)-shm (if present) out of the folder BEFORE opening VideoScan again."
        guardLog.error("\(line, privacy: .public)")
        return [line]
    }

    static func stamp(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: now)
    }

    /// `catalog-wal-quarantine-<yyyyMMdd-HHmmss>`, with `-2`, `-3`… if taken.
    static func folderName(beside url: URL, now: Date) -> URL {
        let base = "catalog-wal-quarantine-\(stamp(now))"
        let parent = url.deletingLastPathComponent()
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }
}

/// QA r2-2: the last close's quarantine lines, for the app's sink. For
/// Rick: a mutex around a vector of strings.
final class CatalogCloseNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var current: [String] { lock.withLock { lines } }
    func set(_ new: [String]) { lock.withLock { lines = new } }
}

extension GRDBCatalogRepository {
    /// What the last close() said about quarantining this session's -wal /
    /// -shm (START / OUTCOME lines); empty when there was nothing to say.
    public nonisolated var lastCloseNotes: [String] { closeNotes.current }
}

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

    /// After a commit: record the -wal / -shm if not yet seen (normally
    /// done at open; this covers a sidecar created later) — only while the
    /// database is still the file this session opened.
    func noteSidecarsOnce(_ fileGuard: CatalogFileGuard) {
        guard !sidecarsComplete, fileGuard.violation() == nil else { return }
        noteSidecars(CatalogSidecarQuarantine.identities(besideDatabaseAt: fileGuard.databaseURL))
    }
}
