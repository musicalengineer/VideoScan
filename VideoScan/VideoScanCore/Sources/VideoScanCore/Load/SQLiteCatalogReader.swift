// SQLiteCatalogReader.swift (VideoScanCore/Load)
// The catalog as a process that is NOT its writer sees it (2026-10-19,
// cutover acceptance audit gap 3): the preview helper (videoscan-preview-
// sweep) and the Hallie shell read catalog.sqlite READ-ONLY through this one
// door. catalog.json has been frozen since the 10/18 cutover, so a reader of
// it sees a catalog that stopped on that day.
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

    /// Preflight, read-only open, one read, close.
    public static func load(databaseURL: URL) async -> Result<Loaded, Failure> {
        if let failure = preflight(databaseURL: databaseURL) { return .failure(failure) }
        let repository = GRDBCatalogRepository()
        if case .refused(let reason) = await repository.openForReading(at: databaseURL) {
            return .failure(Failure("\(databaseFileName) would not open for reading: \(reason)"))
        }
        let snapshot: Snapshot
        do {
            snapshot = try await repository.read { reader in try Snapshot(reader) }
        } catch {
            await repository.close()
            return .failure(Failure("\(databaseFileName) could not be read: \(error)"))
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
