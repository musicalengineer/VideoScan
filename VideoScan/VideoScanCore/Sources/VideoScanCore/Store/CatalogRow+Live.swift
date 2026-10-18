// CatalogRow+Live.swift (VideoScanCore/Store)
// The row-shaped values of the live write doors (cutover B2, schema v1.7):
// one `row_knowledge` row, and what a commit reads back about one `files`
// row before it decides insert vs update.
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
}
