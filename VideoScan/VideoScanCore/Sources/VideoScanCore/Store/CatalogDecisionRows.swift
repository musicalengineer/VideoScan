// CatalogDecisionRows.swift (VideoScanCore/Store)
// Two more of Rick's decisions in catalog.sqlite (schema v1.11, 2026-10-19,
// CatalogDecisionTablesSchema.swift): the values the app reads and writes
// through the seam, and the seam's two halves for them.
//
//   footage_likeness   pairs of contents the duplicate check found alike
//                      although their bytes differ (evidence; the split
//                      writes them, a person confirms or rejects them with
//                      footage_decisions). Read back with the latest
//                      person's verdict on the pair, when there is one.
//   ignored_content    the content-keyed ignore list (v1). The app appends
//                      an entry (import_run NULL); its override is a row in
//                      `ignored_content_put_back` (v1.11) — an ignored row is
//                      never deleted or rewritten.
//
// The readings see every row, whatever wrote it (the cutover import or the
// app). A duplicate is a finding, never a replacement: a pair already
// recorded is left as it is (`alreadyRecorded`); an ignore entry whose
// entry_id is already there is the CALLER's finding (IgnoredContentJSONImport
// in the app) — the door itself never replaces a row.
//
// (For Rick: plain-old-data structs plus two protocols — the abstract
// reader / writer interfaces a C++ DAO would declare in its header.)

import Foundation

extension CatalogRow {

    // MARK: footage_likeness

    /// One `footage_likeness` row. The initializer orders the pair
    /// (`digestA < digestB`) and lowercases both digests, so a caller can
    /// hand the two contents in either order.
    public struct FootageLikeness: Sendable, Hashable {
        public var digestA: String
        public var digestB: String
        /// The duplicate check's reasons, verbatim ("timecode+duration").
        public var reasons: String
        /// 'weak' | 'anchored' (CatalogDecisionTablesSchema.strengths).
        public var strength: String
        /// 'duplicateCheck' | 'oldGroup' (CatalogDecisionTablesSchema.sources).
        public var source: String
        public var recordedAt: Int64

        public init(_ one: String, _ other: String, reasons: String, strength: String, source: String, recordedAt: Int64) {
            let x = one.lowercased(), y = other.lowercased()
            digestA = min(x, y)
            digestB = max(x, y)
            self.reasons = reasons
            self.strength = strength
            self.source = source
            self.recordedAt = recordedAt
        }

        /// The pair as an unordered key (the two digests, ordered).
        public var key: PairKey { PairKey(digestA, digestB) }
    }

    /// Two contents, unordered (a < b) — the key the app indexes pairs by.
    public struct PairKey: Sendable, Hashable {
        public let a: String
        public let b: String

        public init(_ x: String, _ y: String) {
            let l = x.lowercased(), r = y.lowercased()
            a = min(l, r)
            b = max(l, r)
        }
    }

    /// What `recordFootageLikeness` did with one pair.
    public enum FootageLikenessLanding: Sendable, Equatable {
        case recorded
        /// The pair was already there (its first record stands).
        case alreadyRecorded
        /// A digest is not a stored `content` row (the foreign key) —
        /// nothing written; the caller holds what depended on it.
        case contentMissing
    }

    /// One pair as a reviewer sees it: the row, and the latest verdict a
    /// person gave between ANY two files of these contents
    /// (`footage_decisions`, either direction); nil = nobody has said.
    public struct FootageLikenessReview: Sendable, Equatable {
        public var likeness: FootageLikeness
        /// 'same' | 'notSame' | nil.
        public var verdict: String?

        public init(likeness: FootageLikeness, verdict: String?) {
            self.likeness = likeness
            self.verdict = verdict
        }
    }

    // MARK: ignored_content (the app's side)

    /// One ignore entry as the app writes it (import_run NULL, unbound).
    /// Times are unix seconds (the DDL's unit).
    public struct IgnoredEntry: Sendable, Equatable {
        /// IgnoredContentEntry.id (a UUID string, 36 characters).
        public var entryID: String
        public var partialMD5: String
        public var sizeBytes: Int64
        public var filename: String
        public var reason: String
        public var addedAt: Int64
        public var samplePath: String

        public init(entryID: String, partialMD5: String, sizeBytes: Int64, filename: String, reason: String,
                    addedAt: Int64, samplePath: String) {
            self.entryID = entryID
            self.partialMD5 = partialMD5
            self.sizeBytes = sizeBytes
            self.filename = filename
            self.reason = reason
            self.addedAt = addedAt
            self.samplePath = samplePath
        }
    }

    /// One `ignored_content` row, any writer, with its put-back state.
    public struct IgnoredReading: Sendable, Equatable {
        public var seq: Int64
        public var entry: IgnoredEntry
        /// The cutover import wrote it (import_run NOT NULL).
        public var imported: Bool
        /// A put-back names it: it is no longer on the live list.
        public var putBack: Bool

        public init(seq: Int64, entry: IgnoredEntry, imported: Bool, putBack: Bool) {
            self.seq = seq
            self.entry = entry
            self.imported = imported
            self.putBack = putBack
        }
    }

    /// The two tables counted (the import's verification line).
    public struct IgnoredCounts: Sendable, Equatable {
        public var rows: Int
        public var putBack: Int
        public var live: Int { rows - putBack }

        public init(rows: Int, putBack: Int) {
            self.rows = rows
            self.putBack = putBack
        }
    }
}

/// What the app reads of the decision tables (every row, any writer).
public protocol CatalogDecisionReading {
    /// Every `footage_likeness` row with the latest person's verdict on it,
    /// in (digest_a, digest_b) order.
    func footageLikenessReviews(_ visit: (CatalogRow.FootageLikenessReview) throws -> Void) throws
    func footageLikenessCount() throws -> Int
    /// Every `ignored_content` row, oldest first (ignored_seq).
    func ignoredRows(_ visit: (CatalogRow.IgnoredReading) throws -> Void) throws
    func ignoredCounts() throws -> CatalogRow.IgnoredCounts
}

/// What the split and the ignore list write, inside one `write` /
/// `writeBlocking`.
public protocol CatalogDecisionWriting: CatalogDecisionReading {
    /// INSERT the pair unless it is there already; never replaces.
    func recordFootageLikeness(_ likeness: CatalogRow.FootageLikeness) throws -> CatalogRow.FootageLikenessLanding
    /// Append one ignore entry (import_run NULL, binding 'unbound').
    func appendIgnoredEntry(_ entry: CatalogRow.IgnoredEntry) throws
    /// Put back every LIVE row carrying `entryID` (one put-back row each);
    /// returns how many.
    @discardableResult
    func putBackIgnored(entryID: String, at: Int64) throws -> Int
}
