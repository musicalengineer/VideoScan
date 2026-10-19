// CatalogFolderRows.swift (VideoScanCore/Store)
// Catalog folders in catalog.sqlite (schema v1.10, 2026-10-19): the values
// the app's folder store reads and writes through the seam, and the seam's
// two halves for them.
//
// A Catalog folder is a confirmed event — a LABEL Rick makes, never a place
// on disk. Three tables hold it, all from schema v1 (§7), plus v1.10's
// `events.kind`:
//   events           one row per folder (name, state, kind, categories,
//                    note, times) — upserted by the app, keyed by event_id;
//   event_decisions  the append-only stream: every add, move, remove,
//                    rename, kind change and delete, as the app's own
//                    `EventDecision` JSON, verbatim and in order. A kind
//                    this build does not know is kept (the triggers refuse
//                    UPDATE and DELETE);
//   event_members    the fold (accepted − rejected, merges followed) by
//                    DIGEST — rebuilt per folder a change touches. A member
//                    whose key is not a stored whole-file digest ("pair:")
//                    is kept in the stream only.
// Identity is content (the digest), never a path or a record id, so a
// folder survives copies, moves and rescans, and one content can be in
// several folders.
//
// The readings are separate from the import comparator's (which read ONE
// import run): the app reads every row, whatever wrote it.
//
// (For Rick: plain-old-data structs plus two protocols — the abstract
// reader / writer interfaces a C++ DAO would declare in its header.)

import Foundation

extension CatalogRow {

    /// One `events` row as the app's folder store reads and writes it.
    /// Times are unix seconds (the DDL's unit).
    public struct Folder: Sendable, Equatable {
        public var eventID: String
        public var name: String
        /// 'confirmed' | 'dismissed' (a deleted folder is dismissed — its
        /// history stays in the stream).
        public var state: String
        /// 'event' | 'person' | 'other' (v1.10).
        public var kind: String
        public var categories: [String]
        public var note: String?
        public var createdAt: Int64
        public var updatedAt: Int64

        public init(eventID: String, name: String, state: String, kind: String, categories: [String], note: String?,
                    createdAt: Int64, updatedAt: Int64) {
            self.eventID = eventID
            self.name = name
            self.state = state
            self.kind = kind
            self.categories = categories
            self.note = note
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    /// One `event_decisions` row: its place in the stream, its kind word and
    /// the payload as JSON text (verbatim — the app decodes it).
    public struct FolderDecision: Sendable, Equatable {
        public var seq: Int64
        public var kind: String
        public var payloadJSON: String

        public init(seq: Int64, kind: String, payloadJSON: String) {
            self.seq = seq
            self.kind = kind
            self.payloadJSON = payloadJSON
        }
    }

    /// One member of a folder's fold, as the app hands it over: the key it
    /// holds (a digest, or "pair:<id>") and the optional in-file range.
    /// Only a key that is a stored `content.digest` becomes an
    /// `event_members` row.
    public struct FolderMember: Sendable, Hashable {
        public var key: String
        public var rangeStart: Double?
        public var rangeEnd: Double?

        public init(key: String, rangeStart: Double? = nil, rangeEnd: Double? = nil) {
            self.key = key
            self.rangeStart = rangeStart
            self.rangeEnd = rangeEnd
        }
    }

    /// The three folder tables, counted (the import's verification line,
    /// Catalog Status).
    public struct FolderCounts: Sendable, Equatable {
        public var events: Int
        public var decisions: Int
        public var members: Int

        public init(events: Int, decisions: Int, members: Int) {
            self.events = events
            self.decisions = decisions
            self.members = members
        }
    }
}

/// What the app's folder store reads (every row, any writer).
public protocol CatalogFolderReading {
    /// Every `events` row, oldest first (created_at, then event_id).
    func folderRows(_ visit: (CatalogRow.Folder) throws -> Void) throws
    /// The whole decision stream, in `seq` order.
    func folderDecisions(_ visit: (CatalogRow.FolderDecision) throws -> Void) throws
    func folderCounts() throws -> CatalogRow.FolderCounts
}

/// What a folder edit writes, inside one `write` / `writeBlocking`.
public protocol CatalogFolderWriting: CatalogFolderReading {
    /// INSERT the folder, or UPDATE its name, state, kind, categories, note
    /// and updated_at (created_at and the import's run / ordinal are kept).
    func upsertFolder(_ folder: CatalogRow.Folder) throws
    /// Append one decision to the stream (import_run NULL: the app wrote it).
    func appendFolderDecision(kind: String, payloadJSON: String) throws
    /// The folder's `event_members` replaced by `members` — those whose key
    /// is a stored digest; returns how many rows landed.
    @discardableResult
    func replaceFolderMembers(eventID: String, _ members: [CatalogRow.FolderMember]) throws -> Int
}
