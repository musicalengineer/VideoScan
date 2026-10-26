// SQLiteWALSidecar.swift (VideoScanCore/Store)
// GH #386, Rick 2026-10-26 (docs/DECISIONS.md): "Read-only opens restore a
// missing WAL sidecar."
//
// Apple's libsqlite3 (3.54.0 "aapl", macOS 27) answers SQLITE_CANTOPEN (14,
// "unable to open database file") to a READ-ONLY open of a WAL-mode database
// that has no `-wal` beside it. Upstream SQLite opens it and creates the
// sidecar itself; `/usr/bin/sqlite3 -readonly` fails like GRDB. The `-wal` is
// missing when the database's LAST closer was read-write and cleaned up — a
// `sqlite3` shell session, a `.backup`, a `cp` of the file alone. A 0-byte
// `-wal` is what SQLite itself creates and what this app's own close leaves;
// it holds no frames, so it changes nothing any reader sees.
//
// So, before a read-only open: a WAL-mode file with no `-wal` gets an EMPTY
// one when the folder takes it — create-only (O_CREAT|O_EXCL|O_NOFOLLOW: an
// existing file, even a dangling symlink, is never truncated, replaced or
// followed; losing a race to another creator is success) — and otherwise the
// open is refused in words that say why and what restores it. Nothing is ever
// removed here. Not specific to the catalog: any SQLite sidecar database this
// app opens read-only (the provenance store, when it exists) uses it.
//
// Cost: one 100-byte header read and, at most, one open(2)+close(2).
// Memory: 100 bytes.
// For Rick: `open(path, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, mode)` in C —
// the atomic "make it only if nobody has" the kernel gives us.

import Foundation

public enum SQLiteWALSidecar {

    /// What `prepareForReadOnlyOpen` found or did.
    public enum Readiness: Equatable, Sendable {
        /// Not a WAL-mode SQLite file (or unreadable): nothing to do here —
        /// the open itself reports anything wrong with it.
        case notNeeded
        /// The `-wal` was already beside it; untouched.
        case alreadyThere
        /// This call created the empty `-wal`.
        case created
        /// A WAL-mode file with no `-wal`, and the folder would not take
        /// one: the open must be refused, in these words.
        case refused(String)
    }

    /// Before a READ-ONLY open of `database`: make sure a WAL-mode file has
    /// its `-wal` (see the file comment). Never deletes or rewrites anything.
    public static func prepareForReadOnlyOpen(_ database: URL) -> Readiness {
        guard isWALMode(database) else { return .notNeeded }
        let wal = database.path + "-wal"
        // The database's own permission bits, as SQLite gives its sidecars.
        var info = stat()
        let mode = stat(database.path, &info) == 0 ? mode_t(info.st_mode & 0o777) : 0o644
        let fd = open(wal, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        if fd >= 0 {
            close(fd)
            return .created
        }
        let failure = errno
        if failure == EEXIST { return .alreadyThere }   // there before us, or another creator won the race
        return .refused(missingWords(database, why: String(cString: strerror(failure))))
    }

    /// The words when the `-wal` cannot be restored here (#386).
    static func missingWords(_ database: URL, why: String) -> String {
        let name = database.lastPathComponent
        return "\(name) was last closed by another program (a sqlite3 shell, a copy), which removed its journal file \(name)-wal, and this folder will not take a new one (\(why)) — it was not opened. Opening it once in VideoScan, where its folder is writable, restores its journal files."
    }

    /// The header says WAL: the "SQLite format 3" magic, then the read and
    /// write format versions at bytes 18 and 19 both 2 (fileformat.html §1.3).
    static func isWALMode(_ database: URL) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: database.path) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 100)) ?? Data()
        return header.count == 100 && header.prefix(16) == Data("SQLite format 3\u{0}".utf8)
            && header[18] == 2 && header[19] == 2
    }
}
