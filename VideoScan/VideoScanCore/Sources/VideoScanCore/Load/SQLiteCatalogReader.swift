// SQLiteCatalogReader.swift (VideoScanCore/Load)
// The catalog as a process that is NOT its writer sees it (2026-10-19,
// cutover acceptance audit gap 3): the preview helper (videoscan-preview-
// sweep) and the Hallie shell read catalog.sqlite READ-ONLY through this one
// door. catalog.json has been frozen since the 10/18 cutover, so a reader of
// it sees a catalog that stopped on that day. On a viewer Mac the file is the
// master's synced copy, opened sealed (`Source.syncedCopy`, 2026-11-04).
//
// The rules:
//   * the file must be catalog.sqlite with `catalog.cutover` beside it — no
//     latch means the catalog was never switched, and the reader says so
//     and stops; it NEVER falls back to catalog.json;
//   * the open is `GRDBCatalogRepository.openForReading` (SQLITE_OPEN_READONLY:
//     no migration, no high-water write, no display pass — `CatalogLoad.read`
//     is not used because its display pass writes);
//   * the records are Core's own reverse mapping, `VideoRecord(loaded:)` —
//     the same one the app's `SQLiteCatalogLoader` wraps — with the purged
//     rows skipped and the held `pending_rows` records added, as the app's
//     load does. Pair links are not rewired (neither reader needs them;
//     the JSON reader before this did not rewire them either).
//
// (For Rick: an `enum` with only statics is a namespace; `Result<T, E>` is
// a tagged union of the value or the error, like std::expected.)

import Foundation

public enum SQLiteCatalogReader {

    public static let databaseFileName = CatalogImporter.Inputs.databaseFileName
    /// Written only by the app's "Switch Catalog to SQLite…" door.
    public static let latchFileName = "catalog.cutover"

    /// Why the catalog could not be read (words for the person).
    public struct Failure: Error, Equatable, CustomStringConvertible, Sendable {
        public let words: String
        public init(_ words: String) { self.words = words }
        public var description: String { words }
    }

    /// What one read gave back.
    public struct Loaded {
        public var records: [VideoRecord]
        /// `catalog_state.master_archive`, verbatim JSON text; nil when none.
        public var masterArchiveJSON: String?
        public var generation: Int
        /// Rows skipped because the app purged them.
        public var purged: Int
        /// Rows (main or held) that would not become a record.
        public var unreadable: Int
    }

    /// WHICH catalog.sqlite a non-writer reads (2026-11-04, the M4's Hallie
    /// lane: a viewer's shell opened the top-level file left from its master
    /// days — schema v14, never updated — while the app on that Mac shows the
    /// master's synced copy). The app's role rule picks the case
    /// (`CatalogAuthority.headlessSource`); this type only says how to open it.
    ///   live        this Mac's own catalog (the master; or an explicit path):
    ///               `openForReading`, `catalog.cutover` beside it;
    ///   syncedCopy  a viewer's sealed snapshot from `master`
    ///               (viewer-catalog/catalog.sqlite): `openSealedSnapshot` —
    ///               rollback-journal, read-only, no file created beside it, so
    ///               the synced folder stays byte-identical to the manifest.
    /// (For Rick: an enum with payloads ≈ a tagged union / std::variant.)
    public enum Source: Equatable, Sendable {
        case live(URL)
        case syncedCopy(URL, master: String)

        public var databaseURL: URL {
            switch self {
            case .live(let url), .syncedCopy(let url, _): return url
            }
        }

        /// How the words name the file: "catalog.sqlite" for this Mac's own,
        /// "<path> (the synced copy from <master>)" for a viewer's.
        public var named: String {
            switch self {
            case .live: return databaseFileName
            case .syncedCopy(let url, let master): return "\(url.path) (the synced copy from \(master))"
            }
        }
    }

    /// Daemon/CLI-only; never a test default.
    /// ~/Library/Application Support/VideoScan/catalog.sqlite
    public static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent(databaseFileName)
    }

    /// The file a commit always rewrites (the high-water sidecar): its
    /// modification time is the "catalog changed" signal for a watcher.
    /// catalog.sqlite's own mtime moves only at a checkpoint.
    public static func freshnessURL(databaseURL: URL) -> URL {
        CatalogHighWater.url(besideDatabaseAt: databaseURL)
    }

    /// nil when `databaseURL` may be read; else why not. Reads only.
    public static func preflight(databaseURL: URL, fileManager: FileManager = .default) -> Failure? {
        if databaseURL.pathExtension.lowercased() == "json" {
            return Failure("\(databaseURL.path) is catalog.json, which is frozen since the switch to SQLite — "
                           + "read \(databaseFileName) instead")
        }
        let latch = databaseURL.deletingLastPathComponent().appendingPathComponent(latchFileName)
        guard fileManager.fileExists(atPath: latch.path) else {
            return Failure("no \(latchFileName) beside \(databaseURL.path): this catalog was never switched to SQLite. "
                           + "Open VideoScan and use Catalog ▸ Switch Catalog to SQLite… first "
                           + "(catalog.json is not read as a fallback)")
        }
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return Failure("\(latchFileName) says the catalog is in SQLite, but there is no \(databaseFileName) at \(databaseURL.path)")
        }
        return nil
    }

    /// `preflight(databaseURL:)` for either source. A synced copy that has
    /// not arrived (no file, or no latch beside it) says "nothing synced
    /// from <master> yet" and names the path; the top-level file of a viewer
    /// is never the fallback.
    public static func preflight(_ source: Source, fileManager: FileManager = .default) -> Failure? {
        guard case .syncedCopy(let url, let master) = source else {
            return preflight(databaseURL: source.databaseURL, fileManager: fileManager)
        }
        let latch = url.deletingLastPathComponent().appendingPathComponent(latchFileName)
        guard fileManager.fileExists(atPath: url.path), fileManager.fileExists(atPath: latch.path) else {
            return Failure("nothing synced from \(master) yet — no \(databaseFileName) with its \(latchFileName) at "
                           + "\(url.deletingLastPathComponent().path) (the synced copy from \(master)). This Mac is a viewer: "
                           + "VideoScan here pulls the copy from \(master) while it runs; this Mac's own top-level "
                           + "\(databaseFileName) is not read")
        }
        return nil
    }

    /// Preflight, read-only open, one read, close.
    public static func load(databaseURL: URL) async -> Result<Loaded, Failure> {
        await load(.live(databaseURL))
    }

    /// The same for either source: the open differs (`Source`), the read
    /// and the records are the one path. Memory: the loaded rows and their
    /// records, about twice the catalog's row data while `loaded()` maps.
    public static func load(_ source: Source) async -> Result<Loaded, Failure> {
        if let failure = preflight(source) { return .failure(failure) }
        let repository = GRDBCatalogRepository()
        let opened: CatalogOpenOutcome
        switch source {
        case .live(let url): opened = await repository.openForReading(at: url)
        case .syncedCopy(let url, _): opened = await repository.openSealedSnapshot(at: url)
        }
        if case .refused(let reason) = opened {
            return .failure(Failure("\(source.named) would not open for reading: \(reason)"))
        }
        let snapshot: Snapshot
        do {
            snapshot = try await repository.read { reader in try Snapshot(reader) }
        } catch {
            await repository.close()
            return .failure(Failure("\(source.named) could not be read: \(error)"))
        }
        await repository.close()
        return .success(snapshot.loaded())
    }

    /// The plain values one read transaction gives (Sendable, unlike a record).
    private struct Snapshot: Sendable {
        var rows: [CatalogLoadedRow] = []
        var pending: [CatalogRow.PendingRow] = []
        var purged = 0
        var designation: String?
        var generation = 0

        init(_ reader: any CatalogReader) throws {
            try reader.loadedRows { row in
                if CatalogCommitWords.isPurged(row.file) { purged += 1 } else { rows.append(row) }
            }
            try reader.pendingRows { pending.append($0) }
            designation = try reader.masterArchiveJSON()
            generation = reader.generation
        }

        func loaded() -> Loaded {
            var records: [VideoRecord] = []
            records.reserveCapacity(rows.count + pending.count)
            var unreadable = 0
            for row in rows {
                if let record = try? VideoRecord(loaded: row) { records.append(record) } else { unreadable += 1 }
            }
            let stored = Set(records.map(\.id))
            for row in pending {
                guard let record = try? CatalogPendingRecord.record(row.json) else { unreadable += 1; continue }
                if !stored.contains(record.id) { records.append(record) }
            }
            return Loaded(records: records, masterArchiveJSON: designation, generation: generation,
                          purged: purged, unreadable: unreadable)
        }
    }
}

// MARK: - The preview helper's source

/// The preview sweep's work-list from catalog.sqlite, read-only. Eligibility
/// is the shared `previewSweepCandidates(from:isReachable:)` rule, exactly
/// as `FileBackedCatalogSource` applies it to a catalog.json.
public struct SQLiteCatalogSource: PreviewCatalogSource {

    public let databaseURL: URL
    public let isReachable: @Sendable (String) -> Bool
    /// Where a failed read is reported (the helper's stdout).
    public let report: @Sendable (String) -> Void

    public init(databaseURL: URL,
                isReachable: @escaping @Sendable (String) -> Bool,
                report: @escaping @Sendable (String) -> Void = { _ in }) {
        self.databaseURL = databaseURL
        self.isReachable = isReachable
        self.report = report
    }

    public func eligibleCandidates() async -> [PreviewSweepCandidate] {
        switch await SQLiteCatalogReader.load(databaseURL: databaseURL) {
        case .success(let loaded):
            return previewSweepCandidates(from: loaded.records, isReachable: isReachable)
        case .failure(let failure):
            report("preview sweep helper: catalog not read — \(failure.words)")
            return []
        }
    }
}
