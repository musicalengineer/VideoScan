// CatalogProvenanceAssertionRows.swift (VideoScanCore/Store)
// Provenance assertions in catalog.sqlite (schema v1.13, 2026-11-01,
// CatalogProvenanceAssertionsSchema.swift): the values the app reads and
// writes through the seam, the seam's two halves, and the two pure rules
// every writer of the table shares —
//   * `ProvenanceAssertionSubject.contentID` — the ONE place a digest in any
//     spelling ("sha256:<HEX>", "<hex>") becomes `content.digest`'s spelling
//     (64 lowercase hex), or nil;
//   * `ProvenanceAssertionFieldPolicy` — which fields are a NAME or a DATE
//     (refused on an archived content: rule 3, only Rick changes an archived
//     name or date) and which are OBSERVATIONS (metadata, allowed anywhere).
//
// Step 1's writer is the app's JournalApplier: one plain INSERT per
// observation, inside the committer's one transaction; the door itself
// decides duplicate / vetoed / content missing / archived name-or-date, so
// no caller can skip a rule.
//
// (For Rick: the DAO header — value structs plus two interfaces — and two
// free functions a C++ codebase would put in a `policy.h`.)

import Foundation

/// Subject ids, normalised once.
public enum ProvenanceAssertionSubject {
    public static let content = "content"
    /// The DDL's CHECK list, verbatim.
    public static let kinds: Set<String> = ["content", "carrier", "captureEvent", "captureSetup", "excerpt"]

    /// `content.digest`'s spelling of `digest` — 64 lowercase hex, with any
    /// "sha256:" prefix (EvidenceAssertion.subjectDigest's form) removed —
    /// or nil when what is left is not a whole-file SHA-256.
    public static func contentID(_ digest: String) -> String? {
        var text = digest.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("sha256:") { text.removeFirst("sha256:".count) }
        guard text.utf8.count == 64, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return text
    }
}

/// Which fields an archived content may receive from a background writer.
public enum ProvenanceAssertionFieldPolicy {
    /// Machine observations step 1 writes. They describe the footage; they
    /// are NOT the file's name or date (DECISIONS 2026-11-01: "Observations
    /// are never shown as a date") — so they are metadata, and rule 3
    /// ("background jobs add metadata only") allows them on archived rows.
    public static let observationFields: Set<String> = ["era.yearRange", "era.fused", "ocr.date"]

    /// A field that IS a name or a date of the file: refused on an archived
    /// content from any writer but Rick's Update… (rule 3).
    public static func isNameOrDate(_ field: String) -> Bool {
        if observationFields.contains(field) { return false }
        let head = field.split(separator: ".", maxSplits: 1).first.map(String.init) ?? field
        return ["name", "filename", "title", "date", "recordedDate", "confirmedDate", "userDate",
                "tapeYear", "digitizedOn"].contains(head)
    }
}

extension CatalogRow {

    /// One row as a writer appends it.
    public struct ProvenanceAssertionDraft: Sendable, Equatable {
        public var subjectKind: String
        public var subjectID: String
        public var field: String
        public var value: String
        public var state: String
        public var by: String
        /// Unix seconds (the DDL's unit).
        public var at: Int64
        public var confidence: Double?
        public var evidenceJSON: String

        public init(subjectKind: String, subjectID: String, field: String, value: String, state: String, by: String,
                    at: Int64, confidence: Double?, evidenceJSON: String) {
            self.subjectKind = subjectKind
            self.subjectID = subjectID
            self.field = field
            self.value = value
            self.state = state
            self.by = by
            self.at = at
            self.confidence = confidence
            self.evidenceJSON = evidenceJSON
        }
    }

    /// One stored row as read back.
    public struct ProvenanceAssertionReading: Sendable, Equatable {
        public var seq: Int64
        public var subjectKind: String
        public var subjectID: String
        public var field: String
        public var value: String
        public var state: String
        public var by: String
        public var at: Int64
        public var confidence: Double?
        public var evidenceJSON: String

        public init(seq: Int64, subjectKind: String, subjectID: String, field: String, value: String, state: String,
                    by: String, at: Int64, confidence: Double?, evidenceJSON: String) {
            self.seq = seq
            self.subjectKind = subjectKind
            self.subjectID = subjectID
            self.field = field
            self.value = value
            self.state = state
            self.by = by
            self.at = at
            self.confidence = confidence
            self.evidenceJSON = evidenceJSON
        }
    }

    /// What `appendProvenanceAssertion` did. Only `.recorded` wrote a row.
    public enum ProvenanceAssertionLanding: Sendable, Equatable {
        case recorded(seq: Int64)
        /// A row with the same whole payload is stored — applying a journal
        /// line twice is applying it once.
        case duplicate
        /// The veto trigger ignored it: Rick's latest decision on this value is "rejected".
        case vetoed
        /// subject_kind 'content' and the digest is not a stored `content` row.
        case contentMissing
        /// A name or date field on an archived content (rule 3).
        case archivedNameOrDate
        /// The store's CHECKs refused the row (the engine's words); nothing written.
        case storeRefused(String)
    }
}

/// What the app reads of `provenance_assertions`.
public protocol CatalogProvenanceAssertionReading {
    /// Every row, any writer.
    func provenanceAssertionCount() throws -> Int
    /// Every row of one subject, oldest first.
    func provenanceAssertions(subjectKind: String, subjectID: String) throws -> [CatalogRow.ProvenanceAssertionReading]
    /// Every row of `subjectKind` whose field is one of `fields`, streamed
    /// ONE SUBJECT AT A TIME (subject_id order, each subject's rows oldest
    /// first) — the bulk read a model-owned cache fills from in one query
    /// (MachineEraResolver.eras(in:)). Memory: one subject's rows (tens) in
    /// flight, never the table.
    func forEachProvenanceAssertionSubject(subjectKind: String, fields: [String],
                                           _ body: (_ subjectID: String, _ rows: [CatalogRow.ProvenanceAssertionReading]) throws -> Void) throws
}

/// The one door, inside one `write` / `writeBlocking`.
public protocol CatalogProvenanceAssertionWriting: CatalogProvenanceAssertionReading {
    /// Append one row (plain INSERT, never REPLACE) after the door's own
    /// checks; the CHECKs and triggers are the second layer.
    func appendProvenanceAssertion(_ draft: CatalogRow.ProvenanceAssertionDraft) throws -> CatalogRow.ProvenanceAssertionLanding
}
