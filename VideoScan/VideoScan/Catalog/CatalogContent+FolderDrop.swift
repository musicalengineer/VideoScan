// CatalogContent+FolderDrop.swift
// Drag files onto a folder to add them, like Finder (Rick 2026-10-19;
// docs/design/October_Design_Retrospective.md §3.2 — "Finder's handling,
// Photos albums' meaning": a folder is a confirmed event, a label, never a
// place on disk).
//
//   • Record rows in both tables are drag sources. The payload is a record
//     id as a STRING ("videoscan-record:<uuid>"), never a file URL: a drop
//     into Finder must not copy media — at worst it makes a text clipping.
//   • A folder row is the drop target (`TableRow.dropDestination`; the
//     table highlights the row while hovered, the Finder way). A loose
//     file row and empty space are not targets.
//   • Dragging a selected row drags the whole on-screen selection (the
//     `displayedIDs` rule every row action reads).
//   • The drop is `EventsFolderDrop` (pure): members as Make Folder builds
//     them; a recording in ANOTHER folder moves; one already here is left
//     alone; a drop that adds nothing does nothing.
//   • Afterwards the folder stays where it is, its count follows the
//     store's revision (the join watches it), and the dropped rows are
//     selected inside it once the join shows them (`pendingDropSelection`)
//     — the folder row itself when it is closed. One Events log line,
//     counts only; one console line names the folders files moved out of.
//   • No Undo: nothing in the app registers undo for event decisions yet.
//
// (Swift extension ≈ C++ partial class via free member functions.)

import SwiftUI

/// The drag payload: a record id as a string. (A caseless `enum` ≈ a C++
/// namespace of free functions.)
enum CatalogRecordDrag {
    static let prefix = "videoscan-record:"

    static func payload(_ id: UUID) -> String { prefix + id.uuidString }

    /// The record ids among dropped strings; anything else (text dragged
    /// in from another app) is ignored.
    static func recordIDs(in items: [String]) -> Set<UUID> {
        Set(items.compactMap { $0.hasPrefix(prefix) ? UUID(uuidString: String($0.dropFirst(prefix.count))) : nil })
    }
}

/// The dropped rows to select once the folder shows them.
struct FolderDropLanding: Equatable {
    let folder: UUID
    let recordIDs: Set<UUID>
}

extension CatalogContent {

    /// Drag ids → the files to add: a dragged row that is part of the
    /// selection brings the whole on-screen selection; otherwise just the
    /// dragged rows.
    private func droppedRecordIDs(_ items: [String]) -> Set<UUID> {
        let dragged = CatalogRecordDrag.recordIDs(in: items)
        guard !dragged.isDisjoint(with: selectedIDs) else { return dragged }
        return dragged.union(displayedSelection)
    }

    /// Files dropped on a folder row. An event handler, never a body;
    /// O(n log n + live members), n = dropped ids.
    func dropOnFolder(_ folderID: UUID, items: [String]) {
        let ids = droppedRecordIDs(items)
        guard !ids.isEmpty else { return }
        let store = EventsDecisionStore.shared
        let drop = EventsFolderDrop(target: folderID, recordIDs: ids, record: { model.record(forID: $0) },
                                    decisions: store.snapshot())
        if let why = drop.refusal {
            model.eventsNote("a drop on a folder did nothing — \(why)")
            return
        }
        guard !drop.isNoOp else { return }   // already in this folder (or nothing can join): nothing
        let movedWords = FolderDropWords.moved(drop, title: { folderTitle(store, $0) })
        guard drop.apply(in: store) else {
            model.eventsNote("a drop on a folder did nothing — \(store.writeRefusal ?? "the store refused")")
            return
        }
        EventsStore.shared.eventConfirmedElsewhere(model: model)
        let added = drop.addedKeys
        tableState.pendingDropSelection = FolderDropLanding(
            folder: drop.target,
            recordIDs: ids.filter { id in model.record(forID: id).flatMap(EventsFolderMembers.contentKey).map(added.contains) ?? false })
        if let movedWords { model.log(movedWords) }
        model.eventsNote(FolderDropWords.logLine(drop))
    }

    private func folderTitle(_ store: EventsDecisionStore, _ id: UUID) -> String {
        store.event(id: id).map { EventsNaming.folderTitle($0.name) } ?? "a folder"
    }

    /// The display landed: when the folder now shows the dropped rows,
    /// select them (an open folder) or the folder row (a closed one). A
    /// display from before the join placed them waits for the next.
    /// Called from `rebuildFolderRows`, after the displayed set is counted.
    func completePendingDrop(in level: FootageFolderLevel.Level) {
        guard let landing = tableState.pendingDropSelection, let members = level.children[landing.folder] else { return }
        let shown = Set(members.compactMap(\.recordID)).intersection(landing.recordIDs)
        guard !shown.isEmpty else { return }
        tableState.pendingDropSelection = nil
        selectedIDs = tableState.expandedFolderIDs.contains(landing.folder) ? shown : [landing.folder]
    }
}

// MARK: - Words (pure)

enum FolderDropWords {
    private static func recordings(_ n: Int) -> String { "\(n) recording\(n == 1 ? "" : "s")" }

    /// The Events log line — counts only (a log line never names an event).
    static func logLine(_ d: EventsFolderDrop) -> String {
        let m = d.members
        var line = "dropped \(m.fileCount) file\(m.fileCount == 1 ? "" : "s") on a folder: \(recordings(d.adding.count)) added"
        if m.copies > 0 { line += ", \(m.copies) cop\(m.copies == 1 ? "y" : "ies") folded in" }
        if d.alreadyIn > 0 { line += ", \(d.alreadyIn) already there" }
        if m.skipped > 0 { line += ", \(m.skipped) skipped" }
        if d.movedCount > 0 { line += ", \(recordings(d.movedCount)) moved from \(d.movingFrom.count) other folder\(d.movingFrom.count == 1 ? "" : "s")" }
        return line
    }

    /// The console line when recordings left other folders, nil when none
    /// did: "Moved 2 recordings out of “Cape 1990” into “Marks Birthday 1984”."
    static func moved(_ d: EventsFolderDrop, title: (UUID) -> String) -> String? {
        guard d.movedCount > 0 else { return nil }
        let from = d.movingFrom.keys.map(title).sorted().map { "“\($0)”" }.joined(separator: ", ")
        return "Moved \(recordings(d.movedCount)) out of \(from) into “\(title(d.target))” — a recording is in one folder at a time."
    }
}
