// CatalogDatabaseRestore.swift (VideoScanCore/Store)
// The store half of Restore from Backup… (GH #343, Rick 2026-11-25). One
// sentence: the catalog becomes the sealed copy a backup holds, written INTO
// the open catalog.sqlite by SQLite's online backup API, and this Mac's
// high-water witnesses are left as they are, so the restored copy opens
// read-only "restored below high-water" and adopting it is a person's act.
//
// Why the backup API into the open store, not close → swap the file → reopen
// (both were on the table; the safer one is this):
//   * ONE TRANSACTION. sqlite3_backup_step holds the destination's write
//     lock from the first step until SQLITE_DONE, and every page goes
//     through the destination's pager — in WAL mode, into catalog.sqlite-wal
//     as one transaction that commits at the end. A failure or a crash at
//     any page leaves uncommitted frames that SQLite discards: the live
//     catalog, whole. A file swap is three renames (db, -wal, -shm) with
//     windows between them.
//   * NO "OLD DATABASE + NEWER -wal". The file at the path is never renamed,
//     replaced or unlinked; its -wal is its own (SQLite's), so a stale -wal
//     can never be replayed onto a different file — the trap a swap has to
//     defend at every step (GH #359's quarantine machinery exists for it).
//   * SAME FILE, SAME IDENTITY. The latch, the file guard's inode and every
//     other process's connection (the Background helper, Hallie) stay valid;
//     after the commit they simply read the restored pages.
// What it costs: the restore needs the store OPEN and writable (a catalog
// that will not open is not restorable from inside the app — say so; never
// guess), and the -wal briefly grows to the size of the backup.
//
// Steps (each refuses before the first page is written):
//   1. the store is open read-write and its file is still the one it opened;
//   2. the source is a sealed snapshot (rollback journal, nothing beside it);
//   3. on the writer queue, so no commit interleaves: the source opens
//      read-only and its read transaction takes SQLite's SHARED lock (no
//      SQLite writer can change it until the backup ends); it says
//      generation == `expectedGeneration`; its page size and text encoding
//      equal the live ones (a WAL destination refuses another page size; a
//      different encoding SQLite would COPY and only then fail to read —
//      codex #384 F1); its generation is BELOW the highest high-water
//      witness — so the restored copy WILL open read-only and Adopt stays
//      the person's choice (a backup at or above it would come up writable,
//      unasked: refused); and, under that lock, the file is still the bytes
//      the caller verified (`CatalogPinnedSource`: same device + inode,
//      size, mtime, ctime, and a full SHA-256 re-read through one fd —
//      codex #384 F2);
//   4. the backup, `pagesPerStep` pages a step; the file check runs before
//      every step (a throw aborts → SQLite rolls the destination back);
//   5. SQLITE_DONE = COMMITTED (SQLite's contract: rollback exists only
//      before it). From that moment no error is a refusal: the read-back of
//      the destination's generation, or anything else that fails, ends as
//      `.restoredUnverified`, and the store CLOSES either way (the close
//      checkpoints the restored pages into catalog.sqlite). The witnesses
//      are never touched.
// Outcomes: restored · refused (nothing changed; the store is open as it
// was) · restoredUnverified (the copy committed, the read-back failed or
// disagreed; the store is closed — the safety copy the app took first is
// the way back).
//
// Memory: SQLite streams the copy page by page through its page cache
// (default ≈ 2 MB); `pagesPerStep` pages are dirty at most per step. Disk:
// the -wal grows to about the backup's size until the close's checkpoint
// (TRUNCATE) folds it into catalog.sqlite.
//
// (For Rick: sqlite3_backup is SQLite's own "copy pages from db A into db B
// under B's write lock" — the C API behind the sqlite3 shell's `.restore`.
// `enum` with no cases ≈ a C++ namespace of static functions.)

import CryptoKit
import Foundation
import GRDB

/// What `restore(fromSealedCopy:…)` did. Callers switch without `default:`.
public enum CatalogRestoreOutcome: Sendable, Equatable {
    /// The live catalog.sqlite now holds the backup at `generation`; the
    /// store is CLOSED. `replaced` is the generation it held before.
    case restored(generation: Int, replaced: Int, pages: Int)
    /// Nothing was written; the store is open exactly as before.
    case refused(reason: String)
    /// The backup committed but reading it back disagreed; the store is
    /// CLOSED. The words say what was read.
    case restoredUnverified(reason: String)
}

/// The facts of a sealed copy, read through the same sealed read-only open
/// a viewer uses (integrity_check, foreign_key_check, schema version), plus
/// the counter row's own stamp — evidence from inside the file, not from a
/// manifest.
public struct CatalogSealedCopyFacts: Sendable, Equatable {
    public var generation: Int
    public var counts: CatalogRow.TableCounts
    /// `generations.saved_at` (Unix seconds): when this copy's catalog was last committed.
    public var savedAt: Int
    public var savedFromHost: String
    public var pageSize: Int
}

public enum CatalogDatabaseRestore {

    /// 4,096 pages a step (16 MB at the catalog's 4 KB pages): progress
    /// every step, the write lock held throughout either way.
    public static let defaultPagesPerStep: Int32 = 4_096

    /// Why a restore said no before writing (thrown inside the writer
    /// closure, turned into `.refused` by the repository).
    struct Refusal: Error {
        let words: String
    }

    /// Set the moment the backup reports SQLITE_DONE (the copy is
    /// committed); read by the repository to tell a refusal from an
    /// unverified restore. (≈ a mutex-guarded `bool` shared with the
    /// writer thread.)
    final class CommitMark: @unchecked Sendable {
        private let lock = NSLock()
        private var committed = false
        var isSet: Bool { lock.withLock { committed } }
        func set() { lock.withLock { committed = true } }
    }

    /// The words when a generation at or above this Mac's high-water is
    /// refused (codex #384 P2: it need not be another catalog).
    public static func atOrAboveHighWaterWords(generation: Int, highWater: Int) -> String {
        "the backup is at generation \(generation), not below this Mac's high-water \(highWater). A restored catalog must "
            + "open read-only so that keeping it is a person's choice (Adopt); one at or above the high-water would open "
            + "writable without asking. It may be a newer backup of this same catalog (made on another Mac, or after this "
            + "Mac last saved) or a different catalog — either way this Mac cannot restore it safely"
    }

    /// Open `url` sealed and read-only, run the open checks, read its
    /// generation, table counts and counter stamp, close. Throws `Refusal`.
    public static func inspectSealedCopy(_ url: URL) async throws -> CatalogSealedCopyFacts {
        let reader = GRDBCatalogRepository(host: "restore-inspect")
        if case .refused(let why) = await reader.openSealedSnapshot(at: url) {
            throw Refusal(words: "\(url.lastPathComponent) did not pass the sealed open: \(why)")
        }
        let read: (generation: Int, counts: CatalogRow.TableCounts)
        do {
            read = try await reader.read { ($0.generation, try $0.recordCounts()) }
            await reader.close()
        } catch {
            await reader.close()
            throw Refusal(words: "\(url.lastPathComponent) could not be read: \(error)")
        }
        let stamp: (savedAt: Int, host: String, pageSize: Int)
        do {
            let queue = try openSource(url)
            defer { try? queue.close() }
            stamp = try await queue.read { db -> (savedAt: Int, host: String, pageSize: Int) in
                let row = try Row.fetchOne(db, sql: "SELECT saved_at, saved_from_host FROM generations WHERE id = 1")
                let savedAt: Int = row?["saved_at"] ?? 0
                let host: String = row?["saved_from_host"] ?? ""
                let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
                return (savedAt, host, pageSize)
            }
        } catch let refusal as Refusal {
            throw refusal
        } catch {
            throw Refusal(words: "\(url.lastPathComponent) could not be read: \(error)")
        }
        return CatalogSealedCopyFacts(generation: read.generation, counts: read.counts,
                                      savedAt: stamp.savedAt, savedFromHost: stamp.host, pageSize: stamp.pageSize)
    }

    /// The source, read-only. A sealed copy is a rollback-journal file, so
    /// a read-only open takes shared locks and creates nothing beside it.
    static func openSource(_ url: URL) throws -> DatabaseQueue {
        if let why = GRDBCatalogRepository.sealedSnapshotRefusal(url) { throw Refusal(words: why) }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "VideoScan.restoreSource"
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    /// What `copy` did, read back on the destination connection.
    struct Copied: Sendable {
        let replaced: Int
        let readBack: Int
        let pages: Int
    }

    /// Steps 3–5's database part, ON THE WRITER QUEUE (`db` is the live
    /// store's writer connection, no transaction open). Throws `Refusal`
    /// before the first page; any other throw is the engine's, and the
    /// destination is rolled back by `sqlite3_backup_finish`.
    /// `stop`: the file check (non-nil = refuse / abort). `step`: test seam,
    /// run after each completed step that is not the last (a throw aborts).
    /// `committed` is set at SQLITE_DONE; any throw after it is NOT a
    /// refusal (the repository turns it into `.restoredUnverified`).
    /// `afterCommit`: test seam, run after SQLITE_DONE, before the read-back.
    /// `sourceLocked`: test seam, run once the source's SHARED lock is held,
    /// before the pin is re-checked under it.
    static func copy(from source: CatalogPinnedSource, into db: Database, expectedGeneration: Int, witnessesBeside databaseURL: URL,
                     pagesPerStep: Int32, stop: @escaping () -> String?, step: (() throws -> Void)?,
                     afterCommit: (() throws -> Void)? = nil, sourceLocked: (() throws -> Void)? = nil, committed: CommitMark,
                     progress: @escaping (_ copied: Int, _ total: Int) -> Void) throws -> Copied {
        if let words = stop() { throw Refusal(words: words) }
        // Read HERE, on the writer queue: no commit can raise them between
        // this read and the backup's write lock.
        let witnesses = try HighWaterWitnesses.read(db, besideDatabaseAt: databaseURL)
        if let words = witnesses.unreadable { throw Refusal(words: words) }
        let highWater = witnesses.highest
        // The path still names the pinned file before SQLite opens it, and
        // again after the re-hash below: the connection's fd is that inode.
        if let words = source.identityChange() { throw Refusal(words: changedWords(words)) }
        let queue = try openSource(source.url)
        defer { try? queue.close() }
        let replaced = try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") ?? -1
        let live = try FileShape(db)
        var pages = 0
        try queue.read { src in
            // The first SELECT takes the source's SHARED lock, held to the end of this closure.
            let generation = try Int.fetchOne(src, sql: "SELECT generation FROM generations WHERE id = 1")
            try sourceLocked?()
            if let words = try mismatch(src, generation: generation, expected: expectedGeneration, highWater: highWater, live: live) {
                throw Refusal(words: words)
            }
            if let words = source.changeSincePinned() { throw Refusal(words: changedWords(words)) }
            if let words = stop() { throw Refusal(words: words) }
            try src.backup(to: db, pagesPerStep: pagesPerStep) { done in
                if done.isCompleted { committed.set() }
                pages = done.totalPageCount
                progress(done.completedPageCount, done.totalPageCount)
                guard !done.isCompleted else { return }
                if let words = stop() { throw Refusal(words: words) }
                try step?()
            }
            try afterCommit?()
        }
        let readBack = try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") ?? -1
        return Copied(replaced: replaced, readBack: readBack, pages: pages)
    }

    /// What a backup must share with the live file for SQLite's backup API
    /// to write it into a WAL database AND read it afterwards.
    struct FileShape: Equatable {
        let pageSize: Int
        let encoding: String
        init(_ db: Database) throws {
            pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            encoding = try String.fetchOne(db, sql: "PRAGMA encoding") ?? "?"
        }
    }

    /// Why the source (`src`, read transaction open) may not be restored
    /// over the live file, or nil: its generation, the high-water, and its
    /// page size and text encoding against the live file's.
    static func mismatch(_ src: Database, generation: Int?, expected: Int, highWater: Int, live: FileShape) throws -> String? {
        guard let generation, generation == expected else {
            return "the backup's catalog.sqlite reads generation \(generation.map(String.init) ?? "none"), "
                + "not the \(expected) it was checked at"
        }
        guard generation < highWater else { return atOrAboveHighWaterWords(generation: generation, highWater: highWater) }
        let shape = try FileShape(src)
        guard shape.pageSize == live.pageSize else {
            return "the backup's page size is \(shape.pageSize) bytes and the live catalog's is \(live.pageSize); "
                + "SQLite cannot restore across page sizes into a write-ahead-log database"
        }
        guard shape.encoding == live.encoding else {
            return "the backup's text encoding is \(shape.encoding) and the live catalog's is \(live.encoding); "
                + "SQLite would copy it and then be unable to read it"
        }
        return nil
    }

    public static func changedWords(_ what: String) -> String {
        "the backup's verified copy changed after it was checked (\(what)) — it is not the file that was verified"
    }
}

// MARK: - The verified bytes, pinned (codex #384 F2)

/// A sealed copy as it was when it was verified: which file (device +
/// inode), its size, mtime and ctime, and the SHA-256 of its bytes read
/// through ONE file descriptor whose fstat matched the path's lstat before
/// and after the read. `changeSincePinned()` repeats exactly that and names
/// the first difference. The restore calls it under the source's SHARED
/// lock, just before the first page is copied.
///
/// What it cannot see: a change made AND undone between two checks that
/// leaves the same inode, size, mtime and ctime (a chmod or a write moves
/// ctime, which userland cannot set back). The app also makes the copy and
/// its folder non-writable after copying it in.
///
/// Memory: one 1 MB read buffer while hashing; the file is streamed.
/// (≈ a C++ value struct: `let` members, compared field by field.)
public struct CatalogPinnedSource: Sendable, Equatable {
    public struct Identity: Sendable, Equatable {
        public let device: Int64
        public let inode: UInt64
        public let bytes: Int64
        public let modified: Int64   // st_mtimespec, ns
        public let changed: Int64    // st_ctimespec, ns

        init(_ st: stat) {
            device = Int64(st.st_dev)
            inode = UInt64(st.st_ino)
            bytes = Int64(st.st_size)
            modified = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
            changed = Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec)
        }

        /// The fields a rename keeps (a move to the Trash changes ctime).
        func sameFileAndBytes(_ other: Identity) -> Bool {
            device == other.device && inode == other.inode && bytes == other.bytes && modified == other.modified
        }
    }

    public let url: URL
    public let identity: Identity
    /// Lowercase hex.
    public let sha256: String

    public struct Unreadable: Error, Sendable, Equatable {
        public let words: String
    }

    /// Pin the file at `url` now. Throws when it is not a readable regular
    /// file or changed while it was being hashed.
    public static func pin(_ url: URL) throws -> CatalogPinnedSource {
        switch read(url) {
        case .failure(let why): throw why
        case .success(let read): return CatalogPinnedSource(url: url, identity: read.identity, sha256: read.sha256)
        }
    }

    /// nil when `url` is still the pinned file with the pinned bytes; else
    /// the first difference, in words.
    public func changeSincePinned() -> String? {
        if let words = identityChange() { return words }
        switch Self.read(url) {
        case .failure(let why): return why.words
        case .success(let now):
            if now.identity != identity { return Self.difference(identity, now.identity) }
            if now.sha256 != sha256 { return "its SHA-256 is now \(now.sha256.prefix(12))…, it was \(sha256.prefix(12))…" }
            return nil
        }
    }

    /// The cheap half: lstat only (no hash).
    public func identityChange() -> String? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return "it is no longer at \(url.path)" }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return "\(url.lastPathComponent) is no longer a plain file" }
        let now = Identity(st)
        return now == identity ? nil : Self.difference(identity, now)
    }

    /// After a move (to the Trash): the same file (device + inode), size,
    /// mtime and full SHA-256 at `moved`. nil = proven; else words.
    public func provenMoved(to moved: URL) -> String? {
        switch Self.read(moved) {
        case .failure(let why): return why.words
        case .success(let now):
            guard now.identity.sameFileAndBytes(identity) else { return Self.difference(identity, now.identity) }
            guard now.sha256 == sha256 else { return "its SHA-256 is now \(now.sha256.prefix(12))…, it was \(sha256.prefix(12))…" }
            return nil
        }
    }

    private static func difference(_ was: Identity, _ now: Identity) -> String {
        if was.device != now.device || was.inode != now.inode { return "another file is at its path" }
        if was.bytes != now.bytes { return "it is \(now.bytes) bytes, it was \(was.bytes)" }
        if was.modified != now.modified { return "it was modified" }
        return "its attributes changed (ctime)"
    }

    /// lstat(path) → open(O_NOFOLLOW) → fstat(fd) == lstat → SHA-256 through
    /// the fd → fstat(fd) and lstat(path) again, all equal.
    private static func read(_ url: URL) -> Result<(identity: Identity, sha256: String), Unreadable> {
        let path = url.path
        var before = stat()
        guard lstat(path, &before) == 0 else { return .failure(Unreadable(words: "\(url.lastPathComponent) cannot be read (\(String(cString: strerror(errno))))")) }
        guard (before.st_mode & S_IFMT) == S_IFREG else { return .failure(Unreadable(words: "\(url.lastPathComponent) is not a plain file")) }
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return .failure(Unreadable(words: "\(url.lastPathComponent) cannot be opened (\(String(cString: strerror(errno))))")) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, Identity(opened) == Identity(before) else {
            return .failure(Unreadable(words: "\(url.lastPathComponent) changed while it was being opened"))
        }
        var hasher = SHA256()
        let chunk = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, chunk) }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(Unreadable(words: "\(url.lastPathComponent) could not be read (\(String(cString: strerror(errno))))"))
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
        }
        var after = stat()
        var atPath = stat()
        guard fstat(fd, &after) == 0, lstat(path, &atPath) == 0,
              Identity(after) == Identity(before), Identity(atPath) == Identity(before) else {
            return .failure(Unreadable(words: "\(url.lastPathComponent) changed while it was being read"))
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .success((Identity(before), hex))
    }
}
