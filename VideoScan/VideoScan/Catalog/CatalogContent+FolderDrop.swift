// CatalogContent+FolderDrop.swift
// Drag files onto a folder, like Finder (Rick 2026-10-19;
// docs/design/October_Design_Retrospective.md §3.2 — "Finder's handling,
// Photos albums' meaning": a folder is a confirmed event, a label, never a
// place on disk).
//
//   • Record rows in both tables are drag sources. The payload is a record
//     id as a STRING ("videoscan-record:<uuid>", plus "@<folder>" when the
//     row is shown inside a folder), never a file URL: a drop into Finder
//     must not copy media — at worst it makes a text clipping.
//   • A folder row is the drop target (`TableRow.dropDestination`; the
//     table highlights the row while hovered, the Finder way). A loose
//     file row and empty space are not targets.
//   • Dragging a selected row drags the whole on-screen selection (the
//     `displayedIDs` rule every row action reads).
//   • Finder parity: dragged OUT OF a folder = MOVE (the files leave that
//     folder); ⌥ held at the drop = ADD (every folder keeps them); loose
//     files always ADD. A file may be in many folders.
//   • The plan is `EventsFolderDrop` (pure); the write, the selection and
//     the log line are the one membership path
//     (CatalogContent+FolderLabels.swift).
//   • No Undo: nothing in the app registers undo for event decisions yet.
//
// (Swift extension ≈ C++ partial class via free member functions.)

import AppKit
import SwiftUI

/// The drag payload: a record id as a string, and the folder the row was
/// shown under. (A caseless `enum` ≈ a C++ namespace of free functions.)
enum CatalogRecordDrag {
    static let prefix = "videoscan-record:"
    static let folderSeparator: Character = "@"

    static func payload(_ id: UUID, from folder: UUID? = nil) -> String {
        prefix + id.uuidString + (folder.map { String(folderSeparator) + $0.uuidString } ?? "")
    }

    /// One dragged row: its record, and its folder when it had one.
    struct Item: Hashable, Sendable {
        let record: UUID
        let folder: UUID?
    }

    /// The rows among dropped strings; anything else (text dragged in from
    /// another app) is ignored.
    static func items(in strings: [String]) -> [Item] {
        strings.compactMap { s in
            guard s.hasPrefix(prefix) else { return nil }
            let body = s.dropFirst(prefix.count).split(separator: folderSeparator, maxSplits: 1)
            guard let first = body.first, let record = UUID(uuidString: String(first)) else { return nil }
            return Item(record: record, folder: body.count > 1 ? UUID(uuidString: String(body[1])) : nil)
        }
    }

    /// The record ids among dropped strings.
    static func recordIDs(in strings: [String]) -> Set<UUID> {
        Set(items(in: strings).map(\.record))
    }

    /// Finder: out of one folder = move, ⌥ = add, loose files = add.
    static func mode(for items: [Item], target: UUID, optionHeld: Bool) -> EventsFolderDrop.Mode {
        guard !optionHeld else { return .add }
        let folders = Set(items.map(\.folder))
        guard folders.count == 1, let only = folders.first, let source = only, source != target else { return .add }
        return .move(from: source)
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
    private func droppedRecordIDs(_ items: [CatalogRecordDrag.Item]) -> Set<UUID> {
        let dragged = Set(items.map(\.record))
        guard !dragged.isDisjoint(with: selectedIDs) else { return dragged }
        return dragged.union(displayedSelection)
    }

    /// Files dropped on a folder row. An event handler, never a body;
    /// O(n log n + the folders' members), n = dropped ids.
    func dropOnFolder(_ folderID: UUID, items strings: [String]) {
        let items = CatalogRecordDrag.items(in: strings)
        let ids = droppedRecordIDs(items)
        guard !ids.isEmpty else { return }
        let mode = CatalogRecordDrag.mode(for: items, target: folderID, optionHeld: NSEvent.modifierFlags.contains(.option))
        applyFolderMembership(target: folderID, recordIDs: ids, mode: mode, gesture: "a drop on a folder")
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

    /// The Events log line — counts only.
    static func logLine(_ d: EventsFolderDrop) -> String {
        let m = d.members
        var line = "\(m.fileCount) file\(m.fileCount == 1 ? "" : "s") into a folder: \(recordings(d.adding.count)) added"
        if m.copies > 0 { line += ", \(m.copies) cop\(m.copies == 1 ? "y" : "ies") folded in" }
        if d.alreadyIn > 0 { line += ", \(d.alreadyIn) already there" }
        if m.skipped > 0 { line += ", \(m.skipped) skipped" }
        if d.movedCount > 0 { line += ", \(recordings(d.movedCount)) moved out of the folder they were in" }
        return line
    }
}
