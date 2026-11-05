// CatalogAnalysisResultsRows.swift (VideoScanCore/Store)
// What the Content Analysis ▸ Results sheet reads of catalog.sqlite (Rick
// 2026-11-04, BACKLOG "results sheet"; background_service.md §6 view 1):
// the values and the read-only seam. READ ONLY — every method runs inside a
// `read` (a snapshot); nothing here writes, and no schema changes.
//
// Every count is aggregated in SQLite (GROUP BY), never by walking records
// in Swift; the one per-row read (`eraFusedRowsOfDatedContents`) streams only
// the contents Rick has dated, one subject at a time, so the agreement count
// runs through MachineEraResolver's own selection rule (rule 4: one engine
// for "which era does this file show").
//
// Rick's confirmed date (the brief asked which source): `user_dates.value`,
// the date Rick typed or imported — exactly what the inspector, Catalog
// Status's convergence line (MachineEraStore via `VideoRecord.userDate` and
// `pfRecordHasConfirmedDate`) and the era planner's bounds read. Known and
// estimated both count, as there. `provenance_assertions` rows by 'rick'
// (confirmed / corrected) have no writer yet, so they cannot be the source.
//
// (For Rick: the DAO header — value structs plus one read-only interface.)

import Foundation

extension CatalogRow {

    /// One machine signer's verdicts, per content (a content counts once).
    public struct AnalyzerOutcomeCounts: Sendable, Equatable {
        /// "machine:<approach id>@r<revision>", verbatim.
        public var signer: String
        /// Contents with at least one inferred row by this signer (the planner's "cached").
        public var analyzed: Int
        /// Contents with an `era.fused` row whose value MachineEraResolver.range accepts.
        public var eraFound: Int
        /// Not found, and an `era.none` row with no `gaveUp` in its evidence.
        public var eraNone: Int
        /// Not found, and an `era.none` row whose evidence says `gaveUp: true` (EraRecordMapper.giveUpLine).
        public var gaveUp: Int

        public init(signer: String, analyzed: Int, eraFound: Int, eraNone: Int, gaveUp: Int) {
            self.signer = signer
            self.analyzed = analyzed
            self.eraFound = eraFound
            self.eraNone = eraNone
            self.gaveUp = gaveUp
        }
    }

    /// One row of a Results file list: a content and the file that stands for it.
    public struct AnalyzerOutcomeFile: Sendable, Equatable {
        public var digest: String
        /// `files.id` (= VideoRecord.id) of the content's first live file by
        /// path, else its first file; nil when the content has no file row.
        public var fileID: String?
        public var path: String?
        public var filename: String?
        /// Every file of the content is removed from the catalog.
        public var removed: Bool
        /// eraFound: the fused value ("1991-1995"); else nil.
        public var value: String?
        /// eraNone / gaveUp: the verdict's `evidence.reason`, verbatim; else nil.
        public var reason: String?

        public init(digest: String, fileID: String?, path: String?, filename: String?, removed: Bool,
                    value: String? = nil, reason: String? = nil) {
            self.digest = digest
            self.fileID = fileID
            self.path = path
            self.filename = filename
            self.removed = removed
            self.value = value
            self.reason = reason
        }
    }

    /// Which list a Results row belongs to (the SQL's classification).
    public enum AnalyzerVerdictKind: String, Sendable, CaseIterable {
        case eraFound, eraNone, gaveUp
    }
}

/// The Results sheet's reads. Implemented on the GRDB read handle only.
public protocol CatalogAnalysisResultsReading {
    /// Every machine signer with an inferred content row, its outcome counts; signer order.
    func analyzerOutcomeCounts() throws -> [CatalogRow.AnalyzerOutcomeCounts]
    /// Contents of live video files (EraPlanner.plannedFilesPredicate) with no catalog row by `signer` — the
    /// catalog half of the planner's "not cached"; the caller subtracts the journal half (EraPlanner.answeredInJournal).
    /// Memory: one digest (64 B) per such content.
    func eraUnansweredInCatalog(signer: String) throws -> [String]
    /// Which of `digests` have any catalog row by `signer`.
    func analyzerAnswered(signer: String, digests: [String]) throws -> Set<String>
    /// Contents whose FIRST row by `signer` has `at >= since` (files analyzed since then).
    func analyzerFirstVerdicts(signer: String, since: Int64) throws -> Int
    /// For each content with a live file and Rick's date (`user_dates.value`): that
    /// date and its `era.fused` rows of every `by` (Rick's rejections included,
    /// so the resolver can honour them), streamed one content at a time.
    func eraFusedRowsOfDatedContents(_ body: (_ subjectID: String, _ rickDate: String,
                                              _ rows: [CatalogRow.ProvenanceAssertionReading]) throws -> Void) throws
    /// The files of one verdict kind for `signer`, by file name, at most `limit`.
    func analyzerOutcomeFiles(signer: String, kind: CatalogRow.AnalyzerVerdictKind, limit: Int) throws -> [CatalogRow.AnalyzerOutcomeFile]
    /// The standing file of each digest (as in the lists), for digests known from elsewhere (the try counts).
    func analyzerFiles(digests: [String]) throws -> [CatalogRow.AnalyzerOutcomeFile]
}
