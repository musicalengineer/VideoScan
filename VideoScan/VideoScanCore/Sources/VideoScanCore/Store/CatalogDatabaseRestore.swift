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
//      read-only and says generation == `expectedGeneration`; its page size
//      equals the live one (a WAL destination refuses a different size);
//      its generation is BELOW the highest high-water witness — so the
//      restored copy WILL open read-only and Adopt stays the person's choice
//      (a backup at or above it would come up writable, unasked: refused);
//   4. the backup, `pagesPerStep` pages a step; the file check runs before
//      every step (a throw aborts → SQLite rolls the destination back);
//   5. after SQLITE_DONE, the destination's own generation is read back on
//      the same connection; then the store CLOSES (the close checkpoints the
//      restored pages into catalog.sqlite). The witnesses are never touched.
// Outcomes: restored · refused (nothing changed; the store is open as it
// was) · restoredUnverified (the copy committed, the read-back disagreed;
// the store is closed — the safety copy the app took first is the way back).
//
// Memory: SQLite streams the copy page by page through its page cache
// (default ≈ 2 MB); `pagesPerStep` pages are dirty at most per step. Disk:
// the -wal grows to about the backup's size until the close's checkpoint
// (TRUNCATE) folds it into catalog.sqlite.
//
// (For Rick: sqlite3_backup is SQLite's own "copy pages from db A into db B
// under B's write lock" — the C API behind the sqlite3 shell's `.restore`.
// `enum` with no cases ≈ a C++ namespace of static functions.)

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
    static func copy(from source: URL, into db: Database, expectedGeneration: Int, witnessesBeside databaseURL: URL,
                     pagesPerStep: Int32, stop: @escaping () -> String?, step: (() throws -> Void)?,
                     progress: @escaping (_ copied: Int, _ total: Int) -> Void) throws -> Copied {
        if let words = stop() { throw Refusal(words: words) }
        // Read HERE, on the writer queue: no commit can raise them between
        // this read and the backup's write lock.
        let witnesses = try HighWaterWitnesses.read(db, besideDatabaseAt: databaseURL)
        if let words = witnesses.unreadable { throw Refusal(words: words) }
        let highWater = witnesses.highest
        let queue = try openSource(source)
        defer { try? queue.close() }
        let replaced = try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") ?? -1
        let livePageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
        var pages = 0
        try queue.read { src in
            let generation = try Int.fetchOne(src, sql: "SELECT generation FROM generations WHERE id = 1")
            guard let generation, generation == expectedGeneration else {
                throw Refusal(words: "the backup's catalog.sqlite reads generation \(generation.map(String.init) ?? "none"), "
                              + "not the \(expectedGeneration) it was checked at")
            }
            guard generation < highWater else {
                throw Refusal(words: "the backup is at generation \(generation), not below this Mac's high-water \(highWater): "
                              + "restored, it would open writable with no Adopt — a backup at or above the catalog this Mac "
                              + "last wrote is from another catalog, or the same as the live one")
            }
            let sourcePageSize = try Int.fetchOne(src, sql: "PRAGMA page_size") ?? 0
            guard sourcePageSize == livePageSize else {
                throw Refusal(words: "the backup's page size is \(sourcePageSize) bytes and the live catalog's is \(livePageSize); "
                              + "SQLite cannot restore across page sizes into a write-ahead-log database")
            }
            if let words = stop() { throw Refusal(words: words) }
            try src.backup(to: db, pagesPerStep: pagesPerStep) { done in
                pages = done.totalPageCount
                progress(done.completedPageCount, done.totalPageCount)
                guard !done.isCompleted else { return }
                if let words = stop() { throw Refusal(words: words) }
                try step?()
            }
        }
        let readBack = try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") ?? -1
        return Copied(replaced: replaced, readBack: readBack, pages: pages)
    }
}
