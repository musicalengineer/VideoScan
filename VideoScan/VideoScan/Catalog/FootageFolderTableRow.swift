// FootageFolderTableRow.swift
// The row type of the Footage folders Table, the sort mapping between
// that Table and the linear one, the remembered Show option, and the
// "reveal the selected row" helper (docs/design/footage_folders_2026_10_16.md).
//
// WHY A SECOND ROW TYPE. SwiftUI's `Table` draws ONE row type; the linear
// table's is `VideoRecord` and its sort order is `[KeyPathComparator<VideoRecord>]`,
// wired through ContentView, the model's `records.sort(using:)` and every
// filter. A folder is not a record (and must never reach ⌘⌫ or Promote as
// one), so the folder view is its own Table over this wrapper: a record
// row carries the record, a folder row carries its summary. Both tables
// share one selection (record ids; a folder's id is its event's) and one
// sort order — mapped here column by column.
//
// (For Rick: `PartialKeyPath` ≈ a type-erased pointer-to-member; the
// static `columns` table is the jump table, data instead of a switch.)

import AppKit
import Foundation
import SwiftUI

/// One row of the folder Table: a folder (event) or a record with its
/// relation to the recording above it.
struct FootageFolderTableRow: Identifiable {
    /// The event id for a folder, the record id otherwise (the selection
    /// set the inspector, ⌘⌫, ⌘O and Promote read).
    let id: UUID
    let display: FootageFolders.DisplayRow
    /// nil for a folder row.
    let record: VideoRecord?
    /// The folder's counts, size, running time and date words (the top
    /// level, FootageFolderLevel.swift); nil for a record row.
    let folder: FootageFolderLevel.FolderRow?
    /// The sortable facts (a folder's: title, running time, size, date).
    let keys: FootageFolders.SortKeys
    /// A top-level folder's members — the rows its disclosure triangle
    /// reveals in place (Finder list view, Rick 2026-10-18); nil for a
    /// record row and inside a scope. Built in the event handler from
    /// FootageFolderLevel.Level.children, never in a body.
    let children: [FootageFolderTableRow]?
    /// The folder a member row is shown under (its own triangle's, or the
    /// scope's); nil for a folder row and a loose file. A drag out of it is
    /// a move; its menu offers Move to Folder and Remove from it.
    let inFolder: UUID?

    init(display: FootageFolders.DisplayRow, record: VideoRecord?, folder: FootageFolderLevel.FolderRow? = nil,
         keys: FootageFolders.SortKeys, children: [FootageFolderTableRow]? = nil, inFolder: UUID? = nil) {
        self.id = display.id
        self.display = display
        self.record = record
        self.folder = folder
        self.keys = keys
        self.children = children
        self.inFolder = inFolder
    }

    /// What the row id stands for (CatalogContent's selection reads records).
    var ref: FolderRowRef { FolderRowRef(record: record?.id ?? id, folder: inFolder) }

    var isFolder: Bool { display.isFolder }
    var eventID: UUID? { display.eventID }
    var relation: FootageFolders.Relation? { display.relation }
    var title: String {
        if case .folder(_, let t, _) = display.kind { return t }
        return record?.filename ?? ""
    }

    // The sort columns, one key path per sortable TableColumn.
    var filename: String { keys.filename }
    var volume: String { keys.volume }
    var stream: String { keys.stream }
    var duration: Double { keys.duration }
    var pixels: Int { keys.pixels }
    var codec: String { keys.codec }
    var dossier: Int { keys.dossier }
    var size: Int64 { keys.size }
    var date: Date { keys.date }
    var place: String { keys.place }
    var people: String { keys.people }
}

// Deliberately NOT Equatable (GH #350, QA r1): an equal row VALUE could let
// SwiftUI decide a row's cells need no re-run when the paint clock moves,
// and an in-place record edit would then never repaint. "Would the Table
// draw the same rows?" is the named question
// `FootageFolderTableRows.drawsTheSame(_:_:)` (FootageFolderTableGate.swift),
// asked only by the row publish and the paint gate.

// MARK: - Row ids ⇄ records (a file shown under two folders, 2026-10-19)

/// A folder-table row id → the record it shows and the folder it is shown
/// under. A folder row's ref is its own id with no folder.
struct FolderRowRef: Sendable, Hashable {
    let record: UUID
    let folder: UUID?
}

/// The folder Table selects ROWS; the rest of the Catalog selects RECORDS
/// (the inspector, ⌘⌫, ⌘O, Promote, the row menu). A file under two open
/// folders has two rows — the second with an alias id
/// (`FootageFolderRowID`). This is the translation, pure:
///   rows → records: each row's record (a folder id stays itself);
///   records → rows: the rows Rick clicked when they still mean the same
///   records (so the highlight stays on the row he chose), else each
///   record's own id (its first row).
/// (For Rick: a two-way map between view indices and model keys — the
/// selection model of an NSOutlineView over a multimap.)
enum FolderRowSelection {

    static func recordIDs(of rows: Set<UUID>, refs: [UUID: FolderRowRef]) -> Set<UUID> {
        Set(rows.map { refs[$0]?.record ?? $0 })
    }

    static func rows(for records: Set<UUID>, remembered: Set<UUID>, refs: [UUID: FolderRowRef]) -> Set<UUID> {
        guard !remembered.isEmpty, Self.recordIDs(of: remembered, refs: refs) == records else { return records }
        return remembered
    }

    /// The folder the rows are all shown under, nil when none or mixed.
    static func commonFolder(of rows: Set<UUID>, refs: [UUID: FolderRowRef]) -> UUID? {
        let folders = Set(rows.compactMap { refs[$0] }.map(\.folder))
        guard folders.count == 1, let only = folders.first else { return nil }
        return only
    }
}

// MARK: - Sort mapping (linear table ⇄ folder table ⇄ the join's Sort)

enum FootageFolderSort {

    /// One sortable column: its key, and the comparator each table uses
    /// for it. Data, not a switch — a new column is one more line.
    struct Column {
        let key: FootageFolders.SortKey
        let record: PartialKeyPath<VideoRecord>
        let row: PartialKeyPath<FootageFolderTableRow>
        let recordComparator: (SortOrder) -> KeyPathComparator<VideoRecord>
        let rowComparator: (SortOrder) -> KeyPathComparator<FootageFolderTableRow>
    }

    /// Computed, not stored: eleven small values per call (a header click,
    /// a compose), and no shared mutable global for Swift 6 to flag.
    static var columns: [Column] { [
        Column(key: .filename, record: \VideoRecord.filename, row: \FootageFolderTableRow.filename,
               recordComparator: { KeyPathComparator(\VideoRecord.filename, order: $0) },
               rowComparator: { KeyPathComparator(\FootageFolderTableRow.filename, order: $0) }),
        Column(key: .volume, record: \VideoRecord.displayVolumeLabel, row: \FootageFolderTableRow.volume,
               recordComparator: { KeyPathComparator(\VideoRecord.displayVolumeLabel, order: $0) },
               rowComparator: { KeyPathComparator(\FootageFolderTableRow.volume, order: $0) }),
        Column(key: .stream, record: \VideoRecord.streamTypeRaw, row: \FootageFolderTableRow.stream,
               recordComparator: { KeyPathComparator(\VideoRecord.streamTypeRaw, order: $0) },
               rowComparator: { KeyPathComparator(\FootageFolderTableRow.stream, order: $0) }),
        Column(key: .duration, record: \VideoRecord.durationSeconds, row: \FootageFolderTableRow.duration,
               recordComparator: { KeyPathComparator(\VideoRecord.durationSeconds, order: $0) },
               rowComparator: { KeyPathComparator(\FootageFolderTableRow.duration, order: $0) }),
        Column(key: .resolution, record: \VideoRecord.pixelCount, row: \FootageFolderTableRow.pixels,
               recordComparator: { KeyPathComparator(\VideoRecord.pixelCount, order: $0) },
               rowComparator: { KeyPathComparator(\FootageFolderTableRow.pixels, order: $0) }),
        Column(key: .codec, record: \VideoRecord.displayCodec, row: \FootageFolderTableRow.codec,
               recordComparator: { KeyPathComparator(\VideoRecord.displayCodec, order: $0) },
               rowComparator: { KeyPathComparator(\FootageFolderTableRow.codec, order: $0) }),
        Column(key: .dossier, record: \VideoRecord.dossierChannelCount, row: \FootageFolderTableRow.dossier,
               recordComparator: { KeyPathComparator(\VideoRecord.dossierChannelCount, order: $0) },
               rowComparator: { KeyPathComparator(\FootageFolderTableRow.dossier, order: $0) }),
        Column(key: .size, record: \VideoRecord.sizeBytes, row: \FootageFolderTableRow.size,
               recordComparator: { KeyPathComparator(\VideoRecord.sizeBytes, order: $0) },
               rowComparator: { KeyPathComparator(\FootageFolderTableRow.size, order: $0) }),
        Column(key: .date, record: \VideoRecord.resolvedDateSortKey, row: \FootageFolderTableRow.date,
               recordComparator: { KeyPathComparator(\VideoRecord.resolvedDateSortKey, order: $0) },
               rowComparator: { KeyPathComparator(\FootageFolderTableRow.date, order: $0) }),
        Column(key: .place, record: \VideoRecord.resolvedPlaceSortKey, row: \FootageFolderTableRow.place,
               recordComparator: { KeyPathComparator(\VideoRecord.resolvedPlaceSortKey, order: $0) },
               rowComparator: { KeyPathComparator(\FootageFolderTableRow.place, order: $0) }),
        Column(key: .people, record: \VideoRecord.peopleSortKey, row: \FootageFolderTableRow.people,
               recordComparator: { KeyPathComparator(\VideoRecord.peopleSortKey, order: $0) },
               rowComparator: { KeyPathComparator(\FootageFolderTableRow.people, order: $0) }),
    ] }

    static func column(forRecord keyPath: PartialKeyPath<VideoRecord>) -> Column? {
        columns.first { $0.record == keyPath }
    }

    static func column(forRow keyPath: PartialKeyPath<FootageFolderTableRow>) -> Column? {
        columns.first { $0.row == keyPath }
    }

    /// The join's Sort from the linear table's order (its first comparator
    /// decides; an unknown column sorts by name).
    static func sort(from order: [KeyPathComparator<VideoRecord>]) -> FootageFolders.Sort {
        guard let first = order.first, let c = column(forRecord: first.keyPath) else { return .byName }
        return FootageFolders.Sort(key: c.key, ascending: first.order == .forward)
    }

    /// Linear → folder comparators (unknown columns dropped).
    static func rowComparators(from order: [KeyPathComparator<VideoRecord>]) -> [KeyPathComparator<FootageFolderTableRow>] {
        order.compactMap { c in column(forRecord: c.keyPath)?.rowComparator(c.order) }
    }

    /// Folder → linear comparators (unknown columns dropped).
    static func recordComparators(from order: [KeyPathComparator<FootageFolderTableRow>]) -> [KeyPathComparator<VideoRecord>] {
        order.compactMap { c in column(forRow: c.keyPath)?.recordComparator(c.order) }
    }
}

// MARK: - The remembered Show option

/// The strict read both Show options share: anything but a plist BOOLEAN
/// under the key — a poisoned or older value — reads as OFF, never as on.
/// `as? Bool` alone is not strict: a stored number 1 bridges to `true`
/// through NSNumber (codex 2026-10-16 P2), so the type is checked first.
/// (For Rick: CFGetTypeID ≈ a runtime typeid() on the plist value.)
enum StrictDefaultsBool {
    static func read(_ key: String, _ defaults: UserDefaults) -> Bool {
        guard let stored = defaults.object(forKey: key) else { return false }
        guard CFGetTypeID(stored as AnyObject) == CFBooleanGetTypeID() else { return false }
        return (stored as? Bool) ?? false
    }
}

/// Show ▸ Events & Copies as Folders, remembered per user like the other
/// Show options (UserDefaults), read strictly (StrictDefaultsBool).
enum CatalogFootageFoldersSetting {
    static let key = FootageFolderWords.settingKey

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        StrictDefaultsBool.read(key, defaults)
    }

    static func set(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key)
    }
}

/// Show ▸ Folders Only, remembered under its own key with the same strict
/// read: anything but a plist BOOLEAN reads as OFF.
enum CatalogFoldersOnlySetting {
    static let key = FootageFolderWords.foldersOnlySettingKey

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        StrictDefaultsBool.read(key, defaults)
    }

    static func set(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: key)
    }
}

/// The two Show options move together: Folders Only implies the folder
/// view. Pure, so the rule is pinned by tests rather than by a body.
/// (For Rick: a namespace of two free functions over plain bools.)
enum CatalogFoldersOnlyRule {
    /// Folders Only just flipped: on turns the folder view on; off leaves it.
    static func folders(afterFoldersOnly foldersOnly: Bool, folders: Bool) -> Bool {
        foldersOnly || folders
    }

    /// The folder view just flipped: off turns Folders Only off; on leaves it.
    static func foldersOnly(afterFolders folders: Bool, foldersOnly: Bool) -> Bool {
        folders && foldersOnly
    }

    /// At launch: a remembered Folders Only without the folder view (an
    /// older or poisoned pair) reads as off.
    static func launchFoldersOnly(_ defaults: UserDefaults = .standard) -> Bool {
        foldersOnly(afterFolders: CatalogFootageFoldersSetting.isOn(defaults),
                    foldersOnly: CatalogFoldersOnlySetting.isOn(defaults))
    }
}

// MARK: - A derivative landed: what the Catalog may select

/// What the Catalog pane does when a job's derivative lands (codex
/// 2026-10-16 P1). A row the current filter or scope would not show is
/// NEVER selected — a hidden selection was the ⌘⌫ / Promote trap. Pure:
/// the pane acts on the answer; tests pin the four cases.
/// (For Rick: a plain enum returned by a static function — a strategy
/// value, like returning an enum class from a planner in C++.)
enum DerivativeReveal: Equatable {
    /// On screen under the current filter and scope: select and scroll to it.
    case select
    /// Scoped to the SOURCE's own event or family: the row belongs here but
    /// the join has not placed it yet — clear the scope, open the folder, select.
    case openScopeAndSelect
    /// The filter or search hides it: say where it went, select nothing.
    case hiddenByFilter
    /// Scoped to ANOTHER event or family: say where it went, select nothing.
    case outsideScope

    /// `inTable`: the filter's survivors hold the new row. `foldersOn` and
    /// `scope`: the folder view's state. `index`: the join as published
    /// (it may not know the new row yet — that is the openScopeAndSelect case).
    /// `foldersOnly` (Show ▸ Folders Only): at the top, a derivative whose
    /// source and self are in no folder is not shown, so it is hidden.
    static func plan(landing: DerivativeLanding, inTable: Bool, foldersOn: Bool,
                     scope: FootageFolders.Scope?, index: FootageFolders.Index,
                     foldersOnly: Bool = false) -> DerivativeReveal {
        guard inTable else { return .hiddenByFilter }
        if foldersOnly, scope == nil, isLoose(landing, in: index) { return .hiddenByFilter }
        guard foldersOn, let scope else { return .select }
        switch scope {
        case .event(let eventID):
            if index.isIn(landing.id, folder: eventID) { return .select }
            return index.isIn(landing.sourceID, folder: eventID) ? .openScopeAndSelect : .outsideScope
        case .family(let memberID):
            let family = index.familyOf[memberID]
            if let family, index.familyOf[landing.id] == family { return .select }
            let sameFamily = landing.sourceID == memberID || (family != nil && index.familyOf[landing.sourceID] == family)
            return sameFamily ? .openScopeAndSelect : .outsideScope
        }
    }

    /// Neither the new row nor its source is in any folder.
    static func isLoose(_ landing: DerivativeLanding, in index: FootageFolders.Index) -> Bool {
        index.firstFolder(of: landing.id) == nil && index.firstFolder(of: landing.sourceID) == nil
    }
}

// MARK: - Reveal (scroll the selection into view)

/// SwiftUI's `Table` has no scroll-to; the selection it draws is an
/// NSTableView's. After a programmatic selection (the post-job reveal),
/// ask every table view in the app's visible windows to show its
/// selected row — a table with nothing selected is left alone.
enum CatalogTableReveal {
    @MainActor
    static func scrollSelectionIntoView() {
        // One run-loop turn later, so SwiftUI has applied the selection.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible {
                guard let root = window.contentView else { continue }
                for table in tableViews(under: root) where table.selectedRow >= 0 {
                    table.scrollRowToVisible(table.selectedRow)
                }
            }
        }
    }

    @MainActor
    static func tableViews(under view: NSView) -> [NSTableView] {
        var out: [NSTableView] = []
        var stack: [NSView] = [view]
        while let v = stack.popLast() {
            if let t = v as? NSTableView { out.append(t) }
            stack.append(contentsOf: v.subviews)
        }
        return out
    }
}
