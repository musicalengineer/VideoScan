// EventsFolderDrop.swift
// Catalog ▸ files into a folder (Rick 2026-10-19, "Finder's handling,
// Photos albums' meaning" — docs/design/October_Design_Retrospective.md
// §3.2): a drag onto a folder, or the row menu's "Add to Folder ▸" /
// "Move to Folder ▸". The files join the folder's confirmed event, their
// members built exactly as Make Folder builds them (`EventsFolderMembers`:
// copies folded, keyless files skipped).
//
// A folder is a LABEL and a recording may carry several (2026-10-19:
// "a file in many folders"), so:
//   .add             — the files join the target; every folder they are
//                      already in keeps them (Add to Folder ▸, ⌥-drag, a
//                      drag of loose files);
//   .move(from: F)   — they join the target AND leave F (Move to Folder ▸
//                      while viewing F, a drag out of F — the Finder's
//                      drag-is-move). Other folders keep them.
// A recording already in the target is left there; a plan that changes
// nothing does nothing. `EventsFolderRemoval` is "Remove from <Folder>".
//
// Pure values: built once on the main actor from Rick's decisions (a
// snapshot) when the gesture lands; commit is `apply(in:)`. Nothing here
// opens a file or reads the disk.
//
// Memory: one ContentRange (~80 B) per dropped distinct content, plus the
// source folder's members that the files name.

import Foundation
import VideoScanCore

struct EventsFolderDrop: Sendable, Equatable {

    enum Mode: Sendable, Equatable {
        case add
        case move(from: UUID)
    }

    /// The folder's event (after merges).
    let target: UUID
    let mode: Mode
    /// The dropped files as members (copies folded, keyless counted).
    let members: EventsFolderMembers
    /// The members that are not in the folder yet, in arrival order.
    private(set) var adding: [ContentRange] = []
    /// Members already in this folder: left alone.
    private(set) var alreadyIn = 0
    /// The source folder → the ranges (as stored) that leave it. Only for
    /// `.move`, never the target itself.
    private(set) var movingFrom: [UUID: [ContentRange]] = [:]
    /// The target is not a live confirmed event (dismissed, merged away,
    /// unknown): the plan is refused.
    let targetIsLive: Bool

    init(target: UUID, members: EventsFolderMembers, decisions: EventsDecisionSnapshot, mode: Mode = .add) {
        let t = decisions.effectiveEvent(target)
        self.target = t
        self.members = members
        targetIsLive = decisions.liveEvents.contains { $0.id == t }
        let inTarget = Set(decisions.members(of: t).map(\.contentKey))
        for r in members.ranges {
            if inTarget.contains(r.contentKey) { alreadyIn += 1 } else { adding.append(r) }
        }
        if case .move(let from) = mode, decisions.effectiveEvent(from) != t {
            let source = decisions.effectiveEvent(from)
            let dropped = Set(members.ranges.map(\.contentKey))
            // The ranges as stored (a stored range may carry a start / end),
            // so the rejection names exactly what was accepted.
            let leaving = decisions.members(of: source).filter { dropped.contains($0.contentKey) }
                .sorted { $0.contentKey < $1.contentKey }
            if !leaving.isEmpty { movingFrom[source] = leaving }
            self.mode = .move(from: source)
        } else {
            self.mode = .add
        }
    }

    /// Records → members → the plan. The one entry the Catalog uses.
    init(target: UUID, recordIDs: Set<UUID>, record: (UUID) -> VideoRecord?, decisions: EventsDecisionSnapshot,
         mode: Mode = .add) {
        self.init(target: target, members: EventsFolderMembers(recordIDs: recordIDs, record: record), decisions: decisions,
                  mode: mode)
    }

    /// Nothing to add and nothing leaves: every file is already here, or
    /// none can be a member. The plan does nothing.
    var isNoOp: Bool { adding.isEmpty && movingFrom.isEmpty }

    /// Recordings that leave the source folder.
    var movedCount: Int { movingFrom.values.reduce(0) { $0 + $1.count } }

    /// The content keys this plan adds — for selecting the dropped rows
    /// once the folder shows them.
    var addedKeys: Set<String> { Set(adding.map(\.contentKey)) }

    /// Every content key the plan names (added, already there, or moved).
    var namedKeys: Set<String> { Set(members.ranges.map(\.contentKey)) }

    /// Why the plan is refused, nil when it can run (or is a no-op).
    var refusal: String? {
        targetIsLive ? nil : "that folder is no longer a confirmed event"
    }

    /// Write it: one change, one write. false when refused, a no-op, or
    /// the store says no (read-only, not loaded, the catalog refused).
    @MainActor
    func apply(in store: EventsDecisionStore, now: Date = Date()) -> Bool {
        guard refusal == nil, !isNoOp else { return false }
        return store.addMembers(adding, to: target, movingFrom: movingFrom, now: now)
    }
}

/// "Remove from <Folder>": the selected files' content leaves ONE folder;
/// the files themselves are untouched, and every other folder keeps them.
struct EventsFolderRemoval: Sendable, Equatable {
    let folder: UUID
    let members: EventsFolderMembers
    /// The ranges as the folder stores them, for the named content.
    let leaving: [ContentRange]

    init(folder: UUID, members: EventsFolderMembers, decisions: EventsDecisionSnapshot) {
        let f = decisions.effectiveEvent(folder)
        self.folder = f
        self.members = members
        let named = Set(members.ranges.map(\.contentKey))
        leaving = decisions.members(of: f).filter { named.contains($0.contentKey) }.sorted { $0.contentKey < $1.contentKey }
    }

    init(folder: UUID, recordIDs: Set<UUID>, record: (UUID) -> VideoRecord?, decisions: EventsDecisionSnapshot) {
        self.init(folder: folder, members: EventsFolderMembers(recordIDs: recordIDs, record: record), decisions: decisions)
    }

    var isNoOp: Bool { leaving.isEmpty }
    var leavingKeys: Set<String> { Set(leaving.map(\.contentKey)) }

    @MainActor
    func apply(in store: EventsDecisionStore, now: Date = Date()) -> Bool {
        guard !isNoOp else { return false }
        return store.removeMembers(leaving, from: folder, now: now)
    }
}
