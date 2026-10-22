// CatalogViewerSnapshot.swift
// The catalog.sqlite a viewer Mac reads (CatalogSync phase 2, 2026-10-19 —
// cutover acceptance audit gap 3: the viewers were frozen at 10/18 because
// sync shipped only catalog.json, which the master stopped writing).
//
// Layout, beside the master's catalog (Application Support/VideoScan):
//   viewer-catalog/catalog.sqlite   a sealed `VACUUM INTO` copy — one
//                                   self-contained rollback-journal file,
//                                   no -wal, consistent at one generation
//   viewer-catalog/catalog.cutover  a byte copy of the master's latch
// Both are named in `CatalogSyncScope.sqliteCatalog`, so manifest.sha256
// covers them and the viewer's rsync → verify → swap moves them exactly
// like every other synced file (a mismatch keeps the last good pair).
//
// Why a sub-folder and not catalog.sqlite + catalog.cutover at the root:
// on a viewer the launch rule (`CatalogAuthority.decide`) would find that
// pair at the root and open it READ-WRITE as this Mac's own authority —
// migrations, the high-water witnesses, a WAL beside it. In viewer-catalog/
// the launch rule never sees it; only `load` below opens it, read-only
// (`GRDBCatalogRepository.openSealedSnapshot`: SQLITE_OPEN_READONLY on a
// rollback-journal file, which creates no file beside it).
//
// Master: `publish` — seal (VACUUM INTO a temp beside the target), validate
// (open the temp sealed: integrity_check, schema, the row counts), publish
// with rename(2) through AtomicFilePublish (never replaceItemAt — the
// 2026-09-14 rename wedge), then the latch. The caller commits what is in
// memory first (`CatalogCommitter.commitBeforeSafetyCopy`).
// Viewer: `source(in:)` says what the synced folder holds; `load` reads it
// through the master's own read path (CatalogLoad + SQLiteCatalogLoader).
//
// Memory: VACUUM INTO streams page by page inside SQLite; the only Data
// held is the latch (< 1 KB). Disk: one temp the size of catalog.sqlite
// while a publish runs. A viewer load peaks at about twice the loaded
// catalog (SQLiteCatalogLoader's note), the same as the master's launch.
//
// (For Rick: an `enum` with no cases ≈ a C++ namespace of static
// functions; `@concurrent` ≈ "always run on a worker thread, never on the
// caller's actor" — needed because VACUUM INTO blocks its thread.)

import Foundation
import VideoScanCore

enum CatalogViewerSnapshot {

    // MARK: - Layout

    static let directoryName = "viewer-catalog"
    static let databaseFileName = CatalogAuthority.databaseFileName      // "catalog.sqlite"
    static let latchFileName = CatalogAuthority.latchFileName            // "catalog.cutover"
    static let databaseRelativePath = directoryName + "/" + databaseFileName
    static let latchRelativePath = directoryName + "/" + latchFileName

    /// What a viewer shows while no snapshot + latch has arrived. A
    /// catalog.json in the synced folder is never read (JSON gone, slice 2b,
    /// 2026-10-21 — it used to be shown read-only, labelled "older catalog").
    static let nothingSyncedWords = "nothing synced from the master yet"

    nonisolated static func directory(in liveDir: URL) -> URL {
        liveDir.appendingPathComponent(directoryName, isDirectory: true)
    }

    nonisolated static func databaseURL(in liveDir: URL) -> URL {
        liveDir.appendingPathComponent(databaseRelativePath)
    }

    nonisolated static func latchURL(in liveDir: URL) -> URL {
        liveDir.appendingPathComponent(latchRelativePath)
    }

    // MARK: - Master: seal, validate, publish

    /// What one publish produced.
    struct Published: Equatable, Sendable {
        let generation: Int
        /// `files` rows in the sealed copy (live + tombstoned).
        let files: Int
        let bytes: Int64
    }

    enum PublishError: LocalizedError, Equatable {
        case noLatch(String)
        case sealRefused(String)
        case notSealed(String)
        case publishFailed(String)

        var errorDescription: String? {
            switch self {
            case .noLatch(let path): return "no \(CatalogViewerSnapshot.latchFileName) at \(path) — catalog.sqlite is not this Mac's catalog"
            case .sealRefused(let why): return "the sealed copy could not be made: \(why)"
            case .notSealed(let why): return "the sealed copy did not check out: \(why)"
            case .publishFailed(let why): return "the sealed copy could not be published: \(why)"
            }
        }
    }

    /// Seal `repository` into `liveDir/viewer-catalog/catalog.sqlite` and
    /// copy `latch` beside it. Validates the copy BEFORE it is published,
    /// so a viewer can only ever receive a file that opened sealed and
    /// passed integrity_check here. Throws `PublishError`; on any throw the
    /// previously published pair is left exactly as it was.
    @concurrent
    nonisolated static func publish(from repository: any CatalogRepository, latch: URL,
                                    into liveDir: URL) async throws -> Published {
        let fm = FileManager.default
        guard fm.fileExists(atPath: latch.path) else { throw PublishError.noLatch(latch.path) }
        let latchBytes: Data
        do { latchBytes = try Data(contentsOf: latch) } catch { throw PublishError.noLatch(latch.path) }

        let folder = directory(in: liveDir)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            throw PublishError.publishFailed(error.localizedDescription)
        }
        // Hidden + the publish suffix: the manifest walk skips it, and any
        // sweep that knows AtomicFilePublish's temps recognises it.
        let temp = folder.appendingPathComponent(".\(databaseFileName).\(UUID().uuidString)\(AtomicFilePublish.temporarySuffix)")
        defer { try? fm.removeItem(at: temp) }   // consumed by the rename on success

        if let why = repository.sealedCopyBlocking(to: temp) { throw PublishError.sealRefused(why) }
        let checked = try await validate(temp)
        do {
            try AtomicFilePublish.publish(temp, as: databaseURL(in: liveDir))
            try AtomicFilePublish.write(latchBytes, to: latchURL(in: liveDir), durability: .fast, createIntermediates: false)
        } catch {
            throw PublishError.publishFailed(error.localizedDescription)
        }
        let bytes = (try? fm.attributesOfItem(atPath: databaseURL(in: liveDir).path)[.size] as? NSNumber)?.int64Value ?? 0
        return Published(generation: checked.generation, files: checked.files, bytes: bytes)
    }

    /// What `validate` read from a sealed copy.
    struct Checked: Equatable, Sendable {
        let generation: Int
        let files: Int
    }

    /// Open `url` the way a viewer will (sealed, read-only) and read its
    /// generation and row counts. Throws `.notSealed` with the store's words.
    @concurrent
    nonisolated static func validate(_ url: URL) async throws -> Checked {
        let facts = try await inspect(url)
        return Checked(generation: facts.generation, files: facts.counts.files)
    }

    /// Everything `inspect` reads from a sealed copy: its generation and
    /// every table count (the backup's manifest records them all).
    struct Facts: Equatable, Sendable {
        let generation: Int
        let counts: CatalogRow.TableCounts
    }

    /// The one sealed-copy check, shared by the viewer publish (`validate`)
    /// and Back Up Catalog (`CatalogBackupSeal`): open sealed + read-only
    /// (integrity_check, foreign_key_check, schema version), read the
    /// generation and the table counts, close. Throws `.notSealed`.
    @concurrent
    nonisolated static func inspect(_ url: URL) async throws -> Facts {
        let reader = GRDBCatalogRepository()
        if case .refused(let why) = await reader.openSealedSnapshot(at: url) {
            throw PublishError.notSealed(why)
        }
        do {
            let facts = try await reader.read { snapshot in
                Facts(generation: snapshot.generation, counts: try snapshot.recordCounts())
            }
            await reader.close()
            return facts
        } catch {
            await reader.close()
            throw PublishError.notSealed(String(describing: error))
        }
    }

    // MARK: - Viewer: what the synced folder holds, and the read

    /// What a viewer's synced folder can show.
    enum Source: Equatable, Sendable {
        /// The master's sealed catalog.sqlite AND its latch arrived.
        case snapshot(URL)
        /// No snapshot with its latch: a brand-new viewer, a snapshot that
        /// arrived without its latch, or a folder holding only the frozen
        /// catalog.json (never read).
        case none
    }

    nonisolated static func source(in liveDir: URL) -> Source {
        let fm = FileManager.default
        let db = databaseURL(in: liveDir)
        if fm.fileExists(atPath: db.path), fm.fileExists(atPath: latchURL(in: liveDir).path) {
            return .snapshot(db)
        }
        return .none
    }

    /// True when a manifest's text names the sealed snapshot — i.e. the
    /// master that wrote it publishes catalog.sqlite. A manifest without it
    /// came from a master on an older build (catalog.json only).
    nonisolated static func manifestNamesSnapshot(_ manifestText: String) -> Bool {
        snapshotHash(inManifest: manifestText) != nil
    }

    /// The SHA-256 the manifest records for the sealed snapshot, or nil.
    nonisolated static func snapshotHash(inManifest manifestText: String) -> String? {
        let suffix = "  " + databaseRelativePath
        for line in manifestText.split(separator: "\n") where line.hasSuffix(suffix) {
            return String(line.dropLast(suffix.count))
        }
        return nil
    }

    /// What a viewer shows for `source`: the snapshot's records handed to
    /// `adopt` (the model swaps them in), or "nothing synced" (`.none`), or —
    /// when the snapshot will not open — nothing adopted and the words.
    /// `note` is the one sink (console, catalog.log, videoscan.log).
    @MainActor
    static func show(_ source: Source, note: (String) -> Void,
                     adopt: (SQLiteCatalogLoader.LoadResult) -> Void) async -> ViewerCatalogStatus {
        switch source {
        case .none:
            return .none
        case .snapshot(let url):
            switch await load(url) {
            case .refused(let why):
                note("REFUSED viewer catalog — \(why). The previous catalog stays on screen.")
                return .refused(why)
            case .loaded(let result):
                adopt(result)
                note("OUTCOME viewer catalog: \(result.summary) — read-only, from the master")
                return .snapshot(generation: result.generation, records: result.records.count)
            }
        }
    }

    /// The outcome of a viewer read.
    enum LoadOutcome {
        case loaded(SQLiteCatalogLoader.LoadResult)
        case refused(String)
    }

    /// Read the sealed snapshot at `url` through the master's own read path
    /// (CatalogLoad's snapshot → SQLiteCatalogLoader's records, pairs
    /// rewired), opened read-only, closed before returning. Nothing is
    /// written: a snapshot whose display tables are still empty is refused
    /// (the display pass would have to write) rather than shown blank.
    @MainActor
    static func load(_ url: URL) async -> LoadOutcome {
        let repository = GRDBCatalogRepository()
        if case .refused(let why) = await repository.openSealedSnapshot(at: url) {
            return .refused("\(databaseFileName) from the master would not open: \(why)")
        }
        // Close awaited on both paths (≈ RAII by hand: Swift has no async defer).
        do {
            let result = try await SQLiteCatalogLoader.load(repository: repository)
            await repository.close()
            return .loaded(result)
        } catch {
            await repository.close()
            let words = (error as? CatalogLoad.Failure)?.words ?? String(describing: error)
            return .refused("\(databaseFileName) from the master could not be read: \(words)")
        }
    }
}

// MARK: - What a viewer is showing (the banner's catalog line)

enum ViewerCatalogStatus: Equatable, Sendable {
    /// Not decided yet this session.
    case unknown
    /// Nothing synced yet (no snapshot with its latch; catalog.json is never read).
    case none
    /// The master's catalog.sqlite, at this generation.
    case snapshot(generation: Int, records: Int)
    /// A snapshot arrived but would not open; the previous catalog is still shown.
    case refused(String)

    var words: String? {
        switch self {
        case .unknown: return nil
        case .none: return CatalogViewerSnapshot.nothingSyncedWords
        case .snapshot(let generation, let records):
            return "catalog.sqlite · generation \(generation) · \(records) records"
        case .refused(let why): return "kept the previous catalog — \(why)"
        }
    }
}
