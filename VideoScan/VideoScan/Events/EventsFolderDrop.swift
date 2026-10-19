// EventsFolderDrop.swift
// Catalog ▸ drag files onto a folder (Rick 2026-10-19, "Finder's handling,
// Photos albums' meaning" — docs/design/October_Design_Retrospective.md
// §3.2). The dropped files join the folder's confirmed event, their members
// built exactly as Make Folder builds them (`EventsFolderMembers`: copies
// folded, keyless files skipped).
//
// Events do not overlap today, so a recording already in ANOTHER folder
// MOVES, like Finder: it is rejected from its old event and accepted into
// this one (the `split` pattern — `EventsDecisionStore.addMembers`). A
// recording already in this folder is left alone; a drop that adds nothing
// does nothing.
//
// Pure values: built once on the main actor from Rick's decisions (a
// snapshot) when the drop lands; commit is `apply(in:)`. Nothing here
// opens a file or reads the disk.
//
// Memory: one ContentRange (~80 B) per dropped distinct content, plus one
// key → events map over the live events' members that the drop names.

import Foundation
import VideoScanCore

struct EventsFolderDrop: Sendable, Equatable {
    /// The folder's event (after merges).
    let target: UUID
    /// The dropped files as members (copies folded, keyless counted).
    let members: EventsFolderMembers
    /// The members that are not in the folder yet, in arrival order.
    private(set) var adding: [ContentRange] = []
    /// Members already in this folder: left alone.
    private(set) var alreadyIn = 0
    /// Other event → the ranges that leave it for this one.
    private(set) var movingFrom: [UUID: [ContentRange]] = [:]
    /// The target is not a live confirmed event (dismissed, merged away,
    /// unknown): the drop is refused.
    let targetIsLive: Bool

    init(target: UUID, members: EventsFolderMembers, decisions: EventsDecisionSnapshot) {
        let t = decisions.effectiveEvent(target)
        self.target = t
        self.members = members
        let live = decisions.liveEvents
        targetIsLive = live.contains { $0.id == t }

        let dropped = Set(members.ranges.map(\.contentKey))
        let inTarget = Set(decisions.members(of: t).map(\.contentKey))
        // Which OTHER live events hold each dropped key — the ranges as
        // stored (a stored range may carry a start / end), so the rejection
        // names exactly what was accepted. O(live members).
        var holders: [String: [(UUID, ContentRange)]] = [:]
        for e in live where e.id != t {
            for r in decisions.members(of: e.id) where dropped.contains(r.contentKey) {
                holders[r.contentKey, default: []].append((e.id, r))
            }
        }
        for r in members.ranges {
            if inTarget.contains(r.contentKey) {
                alreadyIn += 1
                continue
            }
            adding.append(r)
            for (from, stored) in holders[r.contentKey] ?? [] {
                movingFrom[from, default: []].append(stored)
            }
        }
    }

    /// Records → members → the plan. The one entry the Catalog uses.
    init(target: UUID, recordIDs: Set<UUID>, record: (UUID) -> VideoRecord?, decisions: EventsDecisionSnapshot) {
        self.init(target: target, members: EventsFolderMembers(recordIDs: recordIDs, record: record), decisions: decisions)
    }

    /// Nothing to add: every dropped recording is already here, or none can
    /// be a member. The drop does nothing.
    var isNoOp: Bool { adding.isEmpty }

    /// Recordings that leave another folder.
    var movedCount: Int { movingFrom.values.reduce(0) { $0 + $1.count } }

    /// The content keys this drop adds — for selecting the dropped rows
    /// once the folder shows them.
    var addedKeys: Set<String> { Set(adding.map(\.contentKey)) }

    /// Why the drop is refused, nil when it can run (or is a no-op).
    var refusal: String? {
        targetIsLive ? nil : "that folder is no longer a confirmed event"
    }

    /// Write it: one batch, one save. false when refused, a no-op, or the
    /// store says no (read-only, not loaded).
    @MainActor
    func apply(in store: EventsDecisionStore, now: Date = Date()) -> Bool {
        guard refusal == nil, !isNoOp else { return false }
        return store.addMembers(adding, to: target, movingFrom: movingFrom, now: now)
    }
}
