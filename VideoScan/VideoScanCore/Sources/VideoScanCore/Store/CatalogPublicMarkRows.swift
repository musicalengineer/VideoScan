// CatalogPublicMarkRows.swift (VideoScanCore/Store)
// The public bit in catalog.sqlite (schema v1.15, 2026-11-09,
// CatalogPublicMarksSchema.swift): the values the app reads and writes
// through the seam, and the seam's two halves.
//
// One sentence (Rick's): "mark a video public — the whole family may watch
// it — or clear that mark; everything else is private."
//
// Truth rule: a content is PUBLIC only when the newest `public_marks` row
// for its digest holds exactly 1. No row, a 0, or a value this build cannot
// read (a poisoned or future row) is PRIVATE — the bit fails closed, never
// open, and an unreadable row is counted, never guessed.
//
// (For Rick: a bool with history, plus the DAO interface — the header a C++
// repository would declare.)

import Foundation

extension CatalogRow {

    /// One choice Rick made for one content, as the door appends it.
    public struct PublicMarkDecision: Sendable, Equatable {
        public var digest: String
        public var isPublic: Bool
        /// Unix seconds (the DDL's unit).
        public var decidedAt: Int64

        public init(digest: String, isPublic: Bool, decidedAt: Int64) {
            self.digest = digest.lowercased()
            self.isPublic = isPublic
            self.decidedAt = decidedAt
        }
    }

    /// One stored `public_marks` row as read back.
    public struct PublicMarkReading: Sendable, Equatable {
        public var markID: Int64
        public var digest: String
        /// The flag as stored, verbatim.
        public var storedFlag: Int64
        public var decidedAt: Int64

        public init(markID: Int64, digest: String, storedFlag: Int64, decidedAt: Int64) {
            self.markID = markID
            self.digest = digest
            self.storedFlag = storedFlag
            self.decidedAt = decidedAt
        }

        /// False when the stored flag is neither 0 nor 1.
        public var readable: Bool { storedFlag == 0 || storedFlag == 1 }
        /// Public ONLY on an exact 1: anything else is private (fail closed).
        public var isPublic: Bool { storedFlag == 1 }
    }

    /// What `appendPublicMark` did.
    public enum PublicMarkLanding: Sendable, Equatable {
        case recorded
        /// The digest is not a stored `content` row (the foreign key) —
        /// nothing written; the caller refuses the whole change.
        case contentMissing
    }
}

/// What the app reads of `public_marks` (every row, any writer).
public protocol CatalogPublicMarkReading {
    /// The CURRENT row (highest mark_id) of each of `digests` that has one;
    /// a digest with no row is absent (= private). O(k log n).
    func currentPublicMarks(digests: [String]) throws -> [String: CatalogRow.PublicMarkReading]
    /// The current row of every digest that has one, in digest order.
    func currentPublicMarks(_ visit: (CatalogRow.PublicMarkReading) throws -> Void) throws
    /// Every row of `digest`, oldest first (the history).
    func publicMarkHistory(digest: String) throws -> [CatalogRow.PublicMarkReading]
}

/// The one writer: Make Public / Make Private, inside one `write` / `writeBlocking`.
public protocol CatalogPublicMarkWriting: CatalogPublicMarkReading {
    /// Append one row. Never updates, never replaces.
    func appendPublicMark(_ decision: CatalogRow.PublicMarkDecision) throws -> CatalogRow.PublicMarkLanding
}
