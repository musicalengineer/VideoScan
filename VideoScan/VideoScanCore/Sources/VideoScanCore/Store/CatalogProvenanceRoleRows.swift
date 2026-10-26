// CatalogProvenanceRoleRows.swift (VideoScanCore/Store)
// Provenance roles in catalog.sqlite (schema v1.12, 2026-10-26,
// CatalogProvenanceRolesSchema.swift): the role keys, the values the app
// reads and writes through the seam, and the seam's two halves.
//
// One sentence (Rick's): "say what this file is — Master, Camera Original,
// … — and have every copy of it say the same, for good."
//
// Truth rule: a role shown is the newest `provenance_roles` row for the
// content's digest, read from the store; a key this build does not know
// (a poisoned or future row) reads as UNREADABLE — shown as Unknown and
// counted, never a crash and never guessed into a neighbour.
//
// (For Rick: a scoped enum of string keys plus the DAO interface — the
// header a C++ repository would declare.)

import Foundation

/// What a content is (docs/guides/provenance_roles.md). The raw values are
/// the stored keys — permanent; `title` is the words the menu shows.
public enum ProvenanceRole: String, CaseIterable, Sendable, Codable {
    case master
    case cameraOriginal
    case alternateCapture
    case remasteredCopy
    case editCopy
    case excerpt
    case viewCopy
    case testCopy
    case unknown

    /// The menu and Inspector words, Rick's.
    public var title: String {
        switch self {
        case .master: return "Master"
        case .cameraOriginal: return "Camera Original"
        case .alternateCapture: return "Alternate Capture"
        case .remasteredCopy: return "Remastered Copy"
        case .editCopy: return "Edit Copy"
        case .excerpt: return "Excerpt"
        case .viewCopy: return "View Copy"
        case .testCopy: return "Test Copy"
        case .unknown: return "Unknown"
        }
    }
}

extension CatalogRow {

    /// One role Rick chose for one content, as the door appends it.
    /// `sourceMissing` is kept only for `.master` (the initializer clears
    /// it on any other role — it means nothing there).
    public struct ProvenanceRoleDecision: Sendable, Equatable {
        public var digest: String
        public var role: ProvenanceRole
        /// Unix seconds (the DDL's unit).
        public var decidedAt: Int64
        public var sourceMissing: Bool
        public var note: String?

        public init(digest: String, role: ProvenanceRole, decidedAt: Int64, sourceMissing: Bool = false, note: String? = nil) {
            self.digest = digest.lowercased()
            self.role = role
            self.decidedAt = decidedAt
            self.sourceMissing = role == .master && sourceMissing
            self.note = note
        }
    }

    /// One stored `provenance_roles` row as read back.
    public struct ProvenanceRoleReading: Sendable, Equatable {
        public var roleID: Int64
        public var digest: String
        /// The key as stored, verbatim.
        public var storedRole: String
        public var decidedAt: Int64
        /// The stored flag, verbatim (see `sourceNotInCatalog`).
        public var storedSourceMissing: Bool
        public var note: String?

        public init(roleID: Int64, digest: String, storedRole: String, decidedAt: Int64, storedSourceMissing: Bool, note: String?) {
            self.roleID = roleID
            self.digest = digest
            self.storedRole = storedRole
            self.decidedAt = decidedAt
            self.storedSourceMissing = storedSourceMissing
            self.note = note
        }

        /// The role, or nil when the stored key is not one this build knows.
        public var known: ProvenanceRole? { ProvenanceRole(rawValue: storedRole) }
        /// What is shown: an unreadable key is Unknown (and counted by the reader's caller).
        public var role: ProvenanceRole { known ?? .unknown }
        /// "Source not in the catalog" — only on a Master.
        public var sourceNotInCatalog: Bool { known == .master && storedSourceMissing }
    }

    /// What `appendProvenanceRole` did.
    public enum ProvenanceRoleLanding: Sendable, Equatable {
        case recorded
        /// The digest is not a stored `content` row (the foreign key) —
        /// nothing written; the caller refuses the whole change.
        case contentMissing
    }
}

/// What the app reads of `provenance_roles` (every row, any writer).
public protocol CatalogProvenanceRoleReading {
    /// The CURRENT row (highest role_id) of each of `digests` that has one;
    /// a digest with no row is absent (= Unknown). O(k log n).
    func currentProvenanceRoles(digests: [String]) throws -> [String: CatalogRow.ProvenanceRoleReading]
    /// The current row of every digest that has one, in digest order.
    func currentProvenanceRoles(_ visit: (CatalogRow.ProvenanceRoleReading) throws -> Void) throws
    /// Every row of `digest`, oldest first (the history).
    func provenanceRoleHistory(digest: String) throws -> [CatalogRow.ProvenanceRoleReading]
}

/// The one writer: Provenance ▸ Set Role, inside one `write` / `writeBlocking`.
public protocol CatalogProvenanceRoleWriting: CatalogProvenanceRoleReading {
    /// Append one row. Never updates, never replaces.
    func appendProvenanceRole(_ decision: CatalogRow.ProvenanceRoleDecision) throws -> CatalogRow.ProvenanceRoleLanding
}
