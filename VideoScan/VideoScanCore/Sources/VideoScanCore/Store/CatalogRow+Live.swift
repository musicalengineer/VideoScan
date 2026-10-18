// CatalogRow+Live.swift (VideoScanCore/Store)
// The row-shaped values of the live write doors (cutover B2, schema v1.7):
// one `row_knowledge` row, and what a commit reads back about one `files`
// row before it decides insert vs update. B2.1 (v1.8): one `pending_rows`
// row, and what a purge did.
//
// (For Rick: PODs for the DAO, like the rest of CatalogRow.)

import Foundation

extension CatalogRow {

    /// One `row_knowledge` row. `field` is a `CatalogDDL.KnowledgeField` raw
    /// value or `"pair"`; `importRun` is set only for `source == "catalog.json"`.
    public struct RowKnowledge: Sendable, Equatable {
        public var fileID: String
        public var digest: String?
        public var field: String
        public var value: CatalogJSONValue
        public var setAt: Int64
        public var source: String
        public var importRun: String?

        public init(fileID: String, digest: String?, field: String, value: CatalogJSONValue, setAt: Int64,
                    source: String, importRun: String? = nil) {
            self.fileID = fileID
            self.digest = digest
            self.field = field
            self.value = value
            self.setAt = setAt
            self.source = source
            self.importRun = importRun
        }

        /// The `source` an app commit writes: `app:<door>`.
        public static func appSource(_ door: CatalogWriter) -> String { "app:\(door.rawValue)" }
    }

    /// The `source` of a value the importer read from catalog.json.
    public static let importSource = "catalog.json"

    /// The newest `import_runs` row that finished with the comparator's
    /// word: what "Switch Catalog to SQLite…" checks the JSON against.
    public struct FinishedImport: Sendable, Equatable {
        public var runID: String
        public var finishedAt: Int64
        public var sourceSHA256: String
        public var sourceGeneration: Int

        public init(runID: String, finishedAt: Int64, sourceSHA256: String, sourceGeneration: Int) {
            self.runID = runID
            self.finishedAt = finishedAt
            self.sourceSHA256 = sourceSHA256
            self.sourceGeneration = sourceGeneration
        }
    }

    /// One `pending_rows` row (v1.8): a new record with no whole-file digest
    /// yet, as the app's encoder wrote it.
    public struct PendingRow: Sendable, Equatable {
        public var id: String
        public var json: String
        public var queuedAt: Int64

        public init(id: String, json: String, queuedAt: Int64) {
            self.id = id
            self.json = json
            self.queuedAt = queuedAt
        }
    }

    /// What `purgeFile` did to one id.
    public enum PurgeLanding: Sendable, Equatable {
        /// No `files` row (nor pending row) has this id.
        case absent
        /// The id was only a pending row; it was deleted.
        case pendingDropped
        /// The row already carries the purge marker.
        case alreadyPurged
        /// The purge marker was written at this revision (its tombstone first).
        case purged(revision: Int)
    }

    /// `files.removal_reason` of a row the app removed from the catalog
    /// (Delete All, a prune, a purge): the load skips it.
    public static let purgeReason = RemovalReason.purged.rawValue
}
