// RemovalMarker.swift
// The ONE "gone" shape (GH #143, Rick's ruling 2026-10-11; design:
// docs/design/one_removal_marker_and_trash_engine.md). A catalog row is
// never deleted when its file leaves; it carries one of three states:
//
//   - inTrash            — the app moved the file to the Finder Trash. The
//                          Trash URL macOS returned is kept; a later stat
//                          that finds it gone records "Trash emptied".
//   - removedFromCatalog — the file is untouched on disk; the catalog hides
//                          the row; Restore undoes it.
//   - missing            — the file vanished outside the app; last seen
//                          is kept when known.
//
// Before this type there were four encodings of "gone" (`purgedAt` alone,
// `purgedAt` + lifecycle Trashed/Deleted, archiveStage Manually Deleted,
// and a deleted row). `migrated(...)` maps every one of them onto a state
// at load time; `VideoRecord.purgedAt` is now DERIVED from the marker.
//
// Shape: a value type whose stored fields are read-only from outside and
// whose only constructors are the three factories, so a combination that
// means nothing (a Trash path on a "missing" row) cannot be built.
// (For Rick: `public private(set)` ≈ a C++ struct with public getters and
// private setters; the static factories ≈ named constructors.)

import Foundation

/// Why a row left: an open, machine-readable key. A struct over a String
/// rather than an enum so a catalog written by a newer build (a reason this
/// build has never heard of) still decodes. (≈ `Notification.Name`.)
public struct RemovalReason: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    // Doors (one per way a file or row can leave).
    public static let junk = RemovalReason(rawValue: "junk")                       // Triage Delete Junk
    public static let catalogTrash = RemovalReason(rawValue: "catalogTrash")       // ⌘⌫ / Move to Trash
    public static let duplicate = RemovalReason(rawValue: "duplicate")             // Delete Duplicates
    public static let prune = RemovalReason(rawValue: "prune")                     // Archived what-next / Excess copies
    public static let workbench = RemovalReason(rawValue: "workbench")             // Under Construction Discard
    public static let angelCompanion = RemovalReason(rawValue: "angelCompanion")   // Archive Angel companion settle
    public static let userRemoved = RemovalReason(rawValue: "userRemoved")         // Remove from Catalog
    public static let missingOnDisk = RemovalReason(rawValue: "missingOnDisk")     // analysis found the file gone
    public static let missingAtTrashTurn = RemovalReason(rawValue: "missingAtTrashTurn") // gone when its Trash turn came
    public static let missingAtMigrate = RemovalReason(rawValue: "missingAtMigrate")     // Migrate Bucket B: source not found
    public static let missingAtAudit = RemovalReason(rawValue: "missingAtAudit")         // Audit Catalog tier 0: stat found the file gone
    // Load-time migration of the old encodings.
    public static let legacyPurged = RemovalReason(rawValue: "legacyPurged")
    public static let legacyTrashed = RemovalReason(rawValue: "legacyTrashed")
    public static let legacyDeleted = RemovalReason(rawValue: "legacyDeleted")
    public static let legacyDeletedLabel = RemovalReason(rawValue: "legacyDeletedLabel")
    /// The record left the app's catalog array (Delete All, a prune, a
    /// purge) under catalog.sqlite (cutover B2.1): its `files` row is never
    /// deleted, it gets this marker (state removedFromCatalog) with its
    /// tombstone, and the load skips it. Never set on a live record.
    public static let purged = RemovalReason(rawValue: "purged")
    /// A job's output landed at this row's path (Balance Audio, Repair,
    /// Promote, a derivative) and the bytes are NOT known to be the same
    /// (cutover B2.4, codex B2.3 placeRecord finding): the row is kept,
    /// removed from the catalog with its curated values, never purged.
    /// (`files.removal_reason` is free text — no DDL CHECK lists reasons, so
    /// no schema change.)
    public static let replacedAtPath = RemovalReason(rawValue: "replacedAtPath")
    /// A `purgedAt` write that did not come through the engine (tests,
    /// and any writer the source sensor has not caught yet).
    public static let unspecified = RemovalReason(rawValue: "unspecified")
}

public struct RemovalMarker: Hashable, Codable, Sendable {

    public enum State: String, Codable, CaseIterable, Sendable {
        case inTrash, removedFromCatalog, missing
    }

    public private(set) var state: State
    /// When the row left: moved to the Trash / removed / noticed missing.
    /// `VideoRecord.purgedAt` reads this.
    public private(set) var since: Date
    public private(set) var reason: RemovalReason
    /// inTrash only: the URL path the Trash returned (nil when unknown —
    /// a migrated row, or a test seam).
    public private(set) var trashPath: String?
    /// inTrash only: when a stat first found `trashPath` gone.
    public private(set) var trashEmptiedSeenAt: Date?
    /// missing only: the last date the file was known to be on disk.
    public private(set) var lastSeen: Date?

    private init(state: State, since: Date, reason: RemovalReason,
                 trashPath: String? = nil, trashEmptiedSeenAt: Date? = nil, lastSeen: Date? = nil) {
        self.state = state
        self.since = since
        self.reason = reason
        self.trashPath = trashPath
        self.trashEmptiedSeenAt = trashEmptiedSeenAt
        self.lastSeen = lastSeen
    }

    public static func inTrash(movedAt: Date, trashPath: String?, reason: RemovalReason) -> RemovalMarker {
        RemovalMarker(state: .inTrash, since: movedAt, reason: reason, trashPath: trashPath)
    }

    public static func removedFromCatalog(at date: Date, reason: RemovalReason) -> RemovalMarker {
        RemovalMarker(state: .removedFromCatalog, since: date, reason: reason)
    }

    public static func missing(noticedAt: Date, lastSeen: Date?, reason: RemovalReason) -> RemovalMarker {
        RemovalMarker(state: .missing, since: noticedAt, reason: reason, lastSeen: lastSeen)
    }

    /// "Trash emptied": a stat found the Trash copy gone. Only meaningful
    /// for an inTrash marker with a known path; the first sighting wins.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func noteTrashEmptied(at date: Date) -> Bool {
        guard state == .inTrash, trashPath != nil, trashEmptiedSeenAt == nil else { return false }
        trashEmptiedSeenAt = date
        return true
    }

    /// True once the Trash copy is known to be gone.
    public var isTrashEmptied: Bool { trashEmptiedSeenAt != nil }

    /// The legacy `purgedAt` setter's write: a date on a row that has no
    /// marker becomes "removed from catalog" with an unspecified reason; a
    /// date on a row that has one moves only `since`.
    public func withSince(_ date: Date) -> RemovalMarker {
        var m = self
        m.since = date
        return m
    }

    // MARK: - Load-time migration

    /// Every "gone" encoding a catalog written before GH #143 can hold,
    /// mapped onto one state (design note §2). Pure; O(1); no disk access,
    /// so a 100k-record load pays nothing measurable and an offline drive
    /// is never asked anything.
    ///
    ///  stored                                  → marker
    ///  removal present                         → kept
    ///  purgedAt + .trashed                     → inTrash (no Trash path known)
    ///  purgedAt + .deletedPermanently          → missing (gone; last seen = purgedAt)
    ///  purgedAt, any other stage               → removedFromCatalog
    ///  archiveStage .manuallyDeleted, no purge → removedFromCatalog (label only — the
    ///                                            959 classification: the file was never touched)
    ///  .trashed / .deletedPermanently, no purge → nil (never newly hide a visible row)
    ///  anything else                           → nil
    public static func migrated(stored: RemovalMarker?, purgedAt: Date?,
                                lifecycleStage: LifecycleStage, archiveStage: ArchiveStage,
                                loadedAt: Date) -> RemovalMarker? {
        if let stored { return stored }
        if let purgedAt {
            switch lifecycleStage {
            case .trashed:
                return .inTrash(movedAt: purgedAt, trashPath: nil, reason: .legacyTrashed)
            case .deletedPermanently:
                return .missing(noticedAt: purgedAt, lastSeen: purgedAt, reason: .legacyDeleted)
            case .cataloged, .reviewing, .workbench, .archived:
                return .removedFromCatalog(at: purgedAt, reason: .legacyPurged)
            }
        }
        if archiveStage == .manuallyDeleted {
            return .removedFromCatalog(at: loadedAt, reason: .legacyDeletedLabel)
        }
        return nil
    }
}
