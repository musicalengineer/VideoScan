// CatalogHeldBackRows.swift (VideoScanCore/Store)
// GH #339 (DECISIONS 2026-11-25 evening, "Four rulings" item 3): the rows the
// October import held back (`quarantine`, DDL §8) — the values the app reads
// through the seam, the one value it writes, and the seam's two halves.
//
// One sentence (Rick's): "show me what the import held back and where those
// files are now; when a moved copy is proven, let me carry my tag, date and
// place onto it."
//
// Reading: every quarantine row, open or resolved, streamed (2,110 today).
// The raw JSON row comes back as TEXT — the app parses it with
// `HeldBackCurated.parse`, which never throws (a poisoned row reads as
// "could not be read", never as an empty record).
//
// Writing: ONE door, `resolveHeldBack` — an UPDATE of the existing resolution
// columns only (`resolved_file_id`, `resolved_at`, `resolution`,
// `resolution_note`), `resolution = 'personDecided'` (Rick confirmed it). No
// schema change: the DDL's CHECKs and the `quarantine_resolve_once` trigger
// still refuse a second resolution, a row with integrity findings (only
// `resolvedByRule` may close those), and evidence edits.
//
// (For Rick: a DAO header — one POD per row read, one per row written, and
// the two interfaces the GRDB file implements.)

import Foundation

extension CatalogRow {

    /// One `quarantine` row as the held-back list reads it.
    public struct HeldBackRow: Sendable, Equatable {
        public var qid: Int64
        public var reasonCode: String
        /// The import's family-app words: what was wrong.
        public var words: String
        /// The path the October catalog recorded (a location, never identity).
        public var fullPath: String
        public var sizeBytes: Int64?
        /// The agreeing whole-file SHA-256, lowercase hex; nil when none.
        public var digest: String?
        /// The `v1:` segmented hash the row carried (evidence only).
        public var sampledHash: String?
        /// How many integrity findings the row carries (0 for presence rows).
        public var findingsCount: Int
        /// `raw_row`, verbatim TEXT (nil for a rescan-origin row).
        public var rawRowText: String?
        public var quarantinedAt: Int64
        public var resolvedFileID: String?
        public var resolvedAt: Int64?
        public var resolution: String?
        public var resolutionNote: String?

        public init(qid: Int64, reasonCode: String, words: String, fullPath: String, sizeBytes: Int64?, digest: String?,
                    sampledHash: String?, findingsCount: Int, rawRowText: String?, quarantinedAt: Int64,
                    resolvedFileID: String? = nil, resolvedAt: Int64? = nil, resolution: String? = nil,
                    resolutionNote: String? = nil) {
            self.qid = qid
            self.reasonCode = reasonCode
            self.words = words
            self.fullPath = fullPath
            self.sizeBytes = sizeBytes
            self.digest = digest
            self.sampledHash = sampledHash
            self.findingsCount = findingsCount
            self.rawRowText = rawRowText
            self.quarantinedAt = quarantinedAt
            self.resolvedFileID = resolvedFileID
            self.resolvedAt = resolvedAt
            self.resolution = resolution
            self.resolutionNote = resolutionNote
        }

        public var isResolved: Bool { resolvedAt != nil }
    }

    /// Rick's confirmed carry: the held-back row `qid` now lives on as the
    /// `files` row `fileID`; `note` says what was carried and on what proof.
    public struct HeldBackResolution: Sendable, Equatable {
        public var qid: Int64
        public var fileID: String
        public var note: String
        /// Unix seconds (the DDL's unit).
        public var resolvedAt: Int64

        public init(qid: Int64, fileID: String, note: String, resolvedAt: Int64) {
            self.qid = qid
            self.fileID = fileID
            self.note = note
            self.resolvedAt = resolvedAt
        }
    }

    /// What `resolveHeldBack` did.
    public enum HeldBackLanding: Sendable, Equatable {
        case resolved
        /// The row was already resolved (by another carry, or a rescan) —
        /// nothing written; the caller says so.
        case alreadyResolved
        /// No such `quarantine` row.
        case missing
        /// `fileID` is not a stored `files` row — nothing written.
        case fileMissing
    }
}

/// What the app reads of `quarantine` (every row, any origin).
public protocol CatalogHeldBackReading {
    /// Every row in qid order, streamed (a cursor; nothing O(rows) held).
    func heldBackRows(_ visit: (CatalogRow.HeldBackRow) throws -> Void) throws
    /// Open (unresolved) rows — Catalog Status's number. One indexed count.
    func heldBackOpenCount() throws -> Int
}

/// The one writer: a confirmed carry closes its row, inside one `writeBlocking`.
public protocol CatalogHeldBackWriting: CatalogHeldBackReading {
    /// UPDATE the row's resolution columns (`personDecided`). The DDL refuses
    /// a row with findings and a second resolution; the throw rolls the
    /// whole transaction back.
    func resolveHeldBack(_ resolution: CatalogRow.HeldBackResolution) throws -> CatalogRow.HeldBackLanding
}
