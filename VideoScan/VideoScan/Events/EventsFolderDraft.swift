// EventsFolderDraft.swift
// Catalog ▸ focus banner ▸ "Make Folder…" (Rick 2026-10-19): the files the
// banner shows ("Thanksgiving 1984 (28 files)") become the members of ONE
// new confirmed event, through the same decision-store write the Events
// page's Confirm uses (`EventsDecisionStore.confirm`). Show ▸ As folders
// then draws that event as a folder.
//
// Pure values. The draft is built once, on the main actor, when the sheet
// opens (`init(name:records:)`); the sheet edits only the name; commit is
// `make(in:)`. Nothing here opens a file or reads the disk.
//
// Identity is the Events planner's (`VideoScanModel.eventsContentKey`):
// the stored full SHA-256; "pair:<id>" for the halves of an A/V pair. Copies
// share a key, so they fold into one member (the folder view shows them
// under it again). A file whose key would be only its record id
// ("id:<uuid>") has NO content identity — a rescan gives it a new id and the
// decision would point at nothing — so it is skipped and the sheet says how
// many. So is a file outside the Events scope (removed, set aside,
// superseded): the Events page never sees those either.
//
// Memory: one ContentRange (~80 B) per distinct content plus one Set of
// keys; the focus sets this runs on are tens to a few thousand files.

import Foundation
import VideoScanCore

/// The banner's files as event members: one range per content, copies
/// folded, the files that cannot be a member counted.
struct EventsFolderMembers: Sendable, Equatable {
    /// One per distinct content, in the order the files arrived.
    private(set) var ranges: [ContentRange] = []
    /// Files that are another member's copy (same content key).
    private(set) var copies = 0
    /// Files with no content identity, or outside the Events scope.
    private(set) var skipped = 0

    var fileCount: Int { ranges.count + copies + skipped }

    init(records: [VideoRecord]) {
        var seen = Set<String>()
        for r in records {
            guard let key = Self.contentKey(r) else {
                skipped += 1
                continue
            }
            // `Set.insert` returns (inserted, member) ≈ std::set::insert's pair<it, bool>.
            if seen.insert(key).inserted {
                ranges.append(ContentRange(contentKey: key))
            } else {
                copies += 1
            }
        }
    }

    /// The Events key, or nil when the file cannot be a durable member.
    nonisolated static func contentKey(_ r: VideoRecord) -> String? {
        guard VideoScanModel.isInEventsScope(r) else { return nil }
        let key = VideoScanModel.eventsContentKey(r)
        return key.hasPrefix(idKeyPrefix) ? nil : key
    }

    /// The planner's last-resort key — a record id, not content.
    static let idKeyPrefix = "id:"
}

/// What the Make Folder sheet commits: the name Rick types, the members
/// found when the sheet opened, the categories the name implies. Backed by
/// a confirmed event today; a later folder KIND (event / person / other)
/// is one more field here and one picker in the sheet — neither the
/// sheet's nor `CatalogContent.makeFolder(name:recordIDs:)`'s shape moves.
struct EventsFolderDraft: Sendable, Equatable {
    var name: String
    let members: EventsFolderMembers

    init(name: String, members: EventsFolderMembers) {
        self.name = name
        self.members = members
    }

    init(name: String, records: [VideoRecord]) {
        self.init(name: name, members: EventsFolderMembers(records: records))
    }

    /// THE entry both doors use — the focus banner (its file set) and the
    /// row menu's "New Folder with Selection" (the rows on screen): ids →
    /// records (an id no longer in the catalog is dropped) → members. The
    /// records are ordered by path, then id, so the same files give the
    /// same members whichever door they came through (a `Set` has no
    /// order). `record` is the model's O(1) id lookup. O(n log n), n = ids.
    init(name: String, recordIDs: Set<UUID>, record: (UUID) -> VideoRecord?) {
        let recs = recordIDs.compactMap(record).sorted {
            $0.fullPath != $1.fullPath ? $0.fullPath < $1.fullPath : $0.id.uuidString < $1.id.uuidString
        }
        self.init(name: name, records: recs)
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The categories the NAME says ("Thanksgiving 1984" → Thanksgiving),
    /// by the same name rules the planner reads a file name with.
    var categories: [String] { EventsNaming.categories(forName: trimmedName) }

    /// Why Make Folder is greyed, nil when it can run.
    var refusal: String? {
        if trimmedName.isEmpty { return "Type a name for the folder." }
        if members.ranges.isEmpty { return "None of these files can join a folder yet — they have no full content hash." }
        return nil
    }

    /// Confirm the event. nil when the store refuses (read-only, not
    /// loaded) or the draft cannot run.
    @MainActor
    func make(in store: EventsDecisionStore, now: Date = Date()) -> EventRecord? {
        guard refusal == nil else { return nil }
        return store.confirm(name: trimmedName, categories: categories, members: members.ranges, now: now)
    }
}
