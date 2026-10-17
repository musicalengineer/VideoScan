// ReconcileByDigest.swift
// The ONE pure decision the rescan (step E′, contract §g) makes per media
// file it has probed and hashed: what the catalog does with a (digest,
// volume, path) it just found, given what it already holds. No I/O — the
// walk, the still-being-written rule's two `fstat`s, the hashing and the
// writes are the rescan job's; this is the table in §g as a function, so it
// can be tested row by row before any of that exists.
//
// Step A (files / content) and Step B (quarantine resolution) are two
// values of one `Action`, because §g says Step B follows Step A for the same
// file. A row with findings is never resolved by a byte match (F5r3): it is
// listed in `findingsStillOpen`.
//
// (For Rick: a pure function from a struct of facts to an enum — a
// `constexpr` decision table. Nothing here can touch a disk.)

import Foundation

public enum ReconcileByDigest {

    // MARK: - Inputs

    /// What the walk found at one path.
    public struct Found: Sendable, Equatable {
        public var digest: String
        public var volumeUUID: String
        public var path: String
        /// §g rule 1: the two stamps ≥ 30 s apart disagreed, or the file is too young.
        public var stillBeingWritten: Bool
        /// The fd-bound walk refused a link at some component.
        public var linkInPath: Bool

        public init(digest: String, volumeUUID: String, path: String, stillBeingWritten: Bool = false, linkInPath: Bool = false) {
            self.digest = digest.lowercased()
            self.volumeUUID = volumeUUID
            self.path = path
            self.stillBeingWritten = stillBeingWritten
            self.linkInPath = linkInPath
        }
    }

    /// A live `files` row the catalog holds (at the found path, or sharing the digest).
    public struct MainRow: Sendable, Equatable {
        public var fileID: String
        public var digest: String
        public var volumeUUID: String
        public var path: String
        /// The audit's proof rule said this row is gone from its own path.
        public var provenGone: Bool

        public init(fileID: String, digest: String, volumeUUID: String, path: String, provenGone: Bool = false) {
            self.fileID = fileID
            self.digest = digest.lowercased()
            self.volumeUUID = volumeUUID
            self.path = path
            self.provenGone = provenGone
        }
    }

    /// An open quarantine row sharing the digest.
    public struct QuarantineRow: Sendable, Equatable {
        public var qid: Int64
        public var reason: CatalogDDL.ReasonCode
        public var hasFindings: Bool
        public var jsonRowID: String?
        /// The row id occurs once in the import and is not a `files.id`.
        public var jsonRowIDUsable: Bool

        public init(qid: Int64, reason: CatalogDDL.ReasonCode, hasFindings: Bool, jsonRowID: String? = nil, jsonRowIDUsable: Bool = false) {
            self.qid = qid
            self.reason = reason
            self.hasFindings = hasFindings
            self.jsonRowID = jsonRowID
            self.jsonRowIDUsable = jsonRowIDUsable
        }
    }

    public struct Existing: Sendable, Equatable {
        /// The live row at (volume, path), if any.
        public var atPath: MainRow?
        /// Every live `files` row with the found digest (may include `atPath`).
        public var withDigest: [MainRow]
        /// Every open quarantine row with the found digest.
        public var quarantined: [QuarantineRow]

        public init(atPath: MainRow? = nil, withDigest: [MainRow] = [], quarantined: [QuarantineRow] = []) {
            self.atPath = atPath
            self.withDigest = withDigest
            self.quarantined = quarantined
        }
    }

    // MARK: - Outcome

    /// Step A, §g's table, one case per row of it.
    public enum FileAction: Sendable, Equatable {
        /// Same row, same bytes: refresh disk facts and the stamp, nothing else.
        case refreshInPlace(fileID: String)
        /// The file at this path was replaced: the old row is removed
        /// (`replacedAtPath`, tombstone first), a new row carries the new digest.
        case replaceAtPath(oldFileID: String)
        /// Exactly one live row with this digest is proven gone from its own
        /// path: that row's path is updated through the store's one path door.
        case updatePath(fileID: String)
        /// The digest's other rows are still present (or several are gone):
        /// a new row, a copy; knowledge shared by digest.
        case newCopyRow
        /// A new `files` row (and, for `.newDigest`, a new `content` row).
        case newRow(id: NewRowID)
    }

    /// Where a new row's id comes from (§g: the quarantined row's JSON id
    /// only when it occurs once and is not already a files.id).
    public enum NewRowID: Sendable, Equatable {
        case jsonRowID(String)
        case fresh
    }

    /// Step B: one resolution per eligible quarantine row.
    public struct QuarantineResolution: Sendable, Equatable {
        public enum Kind: String, Sendable { case foundByDigest, resolvedAsCopy }
        public var qid: Int64
        public var kind: Kind
        public init(qid: Int64, kind: Kind) {
            self.qid = qid
            self.kind = kind
        }
    }

    public enum Action: Sendable, Equatable {
        /// Not catalogued this run; never a row, never a resolution.
        case deferred(StillBeingWritten)
        /// A link in the path: refused, listed.
        case refusedLinkInPath
        /// Catalogued: Step A, then Step B.
        case reconciled(file: FileAction, resolved: [QuarantineResolution], findingsStillOpen: [Int64])
    }

    public struct StillBeingWritten: Sendable, Equatable {
        public let path: String
        public init(path: String) { self.path = path }
    }

    // MARK: - Decide

    public static func decide(found: Found, existing: Existing) -> Action {
        if found.stillBeingWritten { return .deferred(StillBeingWritten(path: found.path)) }
        if found.linkInPath { return .refusedLinkInPath }
        let file = fileAction(found: found, existing: existing)
        let (resolved, open) = quarantineResolutions(for: file, existing: existing)
        return .reconciled(file: file, resolved: resolved, findingsStillOpen: open)
    }

    /// Step A — the §g table, top to bottom.
    static func fileAction(found: Found, existing: Existing) -> FileAction {
        if let row = existing.atPath {
            return row.digest == found.digest ? .refreshInPlace(fileID: row.fileID) : .replaceAtPath(oldFileID: row.fileID)
        }
        let known = existing.withDigest
        if !known.isEmpty {
            let gone = known.filter(\.provenGone)
            if gone.count == 1, known.count == 1 { return .updatePath(fileID: gone[0].fileID) }
            return .newCopyRow
        }
        guard let first = existing.quarantined.first else { return .newRow(id: .fresh) }
        if let id = first.jsonRowID, first.jsonRowIDUsable { return .newRow(id: .jsonRowID(id)) }
        return .newRow(id: .fresh)
    }

    /// Step B — only presence reasons with NO findings resolve by a byte
    /// match; the kind says whether a main row already carried the digest.
    static func quarantineResolutions(for file: FileAction, existing: Existing) -> ([QuarantineResolution], [Int64]) {
        var resolved: [QuarantineResolution] = []
        var open: [Int64] = []
        let kind: QuarantineResolution.Kind
        switch file {
        case .newRow: kind = .foundByDigest
        case .newCopyRow, .updatePath, .refreshInPlace: kind = .resolvedAsCopy
        case .replaceAtPath: kind = existing.withDigest.isEmpty ? .foundByDigest : .resolvedAsCopy
        }
        for row in existing.quarantined {
            if row.hasFindings || !Self.resolvesByByteMatch(row.reason) {
                open.append(row.qid)
            } else {
                resolved.append(QuarantineResolution(qid: row.qid, kind: kind))
            }
        }
        return (resolved, open)
    }

    /// The presence reasons a byte match may close (§g Step B). The two
    /// digest-less presence reasons (`noWholeFileDigest`, `removedNoDigest`)
    /// have nothing to match: their route is a candidate for Rick
    /// (`personDecided`), never automatic (F7).
    static func resolvesByByteMatch(_ reason: CatalogDDL.ReasonCode) -> Bool {
        switch reason {
        case .auditGone, .auditNeverSeen, .auditCouldNotCheck: return true
        case .noWholeFileDigest, .removedNoDigest, .auditChanged, .tier5Finding, .referenceMovie, .fixityDisagree,
             .duplicateId, .stillBeingWritten, .pathReplaced, .unreadable: return false
        }
    }
}
