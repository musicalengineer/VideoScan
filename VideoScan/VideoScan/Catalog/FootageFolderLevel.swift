// FootageFolderLevel.swift
// The two Finder levels of Show ▸ Events & Copies as Folders (Rick,
// 2026-10-17: "I'd really like it to look like Finder in this view, with
// MarksBirthday, Cape1990, etc, then double-click shows the event
// including copies").
//
// This is the PRESENTATION step between the join's published display
// (FootageFolders.compose — untouched) and the table's rows:
//
//   top(index:display:)        the TOP level, what a Finder window shows:
//                              one row per event folder (by date, then by
//                              name), then the loose files — the rows in
//                              no event — exactly as the flat view already
//                              lays them out (a loose file's copies and
//                              versions stay under it: "a family is not a
//                              folder, it is the file"). Since 2026-10-18
//                              (Rick: "like Finder's list view") each
//                              folder also carries its members as
//                              `children`, for the disclosure triangle —
//                              the table composes the top with every
//                              folder open, and this step lifts each
//                              folder's member rows out from under it.
//   inside(_:index:display:)   INSIDE one folder (or one file's family):
//                              its members with their glyph rows, which is
//                              the flat view's event scope minus the
//                              folder's own row — the breadcrumb names it.
//
// Pure: values in, values out, O(display rows). Built once per published
// display in the table's event handler (CatalogContent.rebuildFolderRows),
// never in a body. Memory: one DisplayRow per visible row plus one
// FolderRow per folder present — nothing is retained between calls.
//
// (For Rick: everything here is a `struct`/`enum` with value semantics —
// a C++ POD — and `static` functions; `FootageFolders.Scope?` doubles as
// "where we are": nil = the top, .event = inside that folder.)

import Foundation

enum FootageFolderLevel {

    /// One event folder as a row of the top level.
    struct FolderRow: Sendable, Equatable, Identifiable {
        /// The event id.
        let id: UUID
        let name: String
        /// Event / person / other — the folder glyph's colour.
        var kind: FolderKind = .event
        /// Files counted in the folder (copies included; hidden rows not).
        let items: Int
        let copies: Int
        let archived: Int
        let totalSeconds: Double
        let totalBytes: Int64
        /// The earliest recording's day, for the order; distantPast when none.
        let date: Date
        /// "Nov 26, 2009" or "Nov 26, 2009 – Nov 28, 2009" (the Events
        /// page's own words when it has them and no member is dated).
        let dateWords: String

        /// "12 items · 3 copies"
        var itemsWords: String { FootageFolderWords.itemsAndCopies(items: items, copies: copies) }

        /// Date, then name — the top level's order (Rick's archive reads
        /// chronologically; ties by name as the Finder would).
        static func precedes(_ a: FolderRow, _ b: FolderRow) -> Bool {
            if a.date != b.date { return a.date < b.date }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// One level, ready for the table: the rows in display order, the
    /// folder rows among them by event id, and each folder's members (the
    /// rows its disclosure triangle reveals in place; top level only).
    struct Level: Sendable, Equatable {
        var scope: FootageFolders.Scope?
        /// The level's own rows: folders and loose rows (with a loose
        /// file's copies under it). Never a folder's member.
        var rows: [FootageFolders.DisplayRow] = []
        var folders: [UUID: FolderRow] = [:]
        /// Event id → its member rows in the join's family order
        /// (recording · ↳ · = · ⊂ · ≈). Empty inside a scope.
        var children: [UUID: [FootageFolders.DisplayRow]] = [:]

        static let empty = Level()

        /// The record ids on screen with every folder collapsed.
        var recordIDs: Set<UUID> { recordIDs(expanded: []) }

        /// The record ids on screen when the `expanded` folders are
        /// twisted open — THE displayed set every row action intersects
        /// with. A collapsed folder's members are off screen and never
        /// here; a folder row is not a record and is never here either.
        /// O(rows + the expanded folders' members).
        func recordIDs(expanded: Set<UUID>) -> Set<UUID> {
            var ids = Set(rows.compactMap(\.recordID))
            for id in expanded {
                guard let members = children[id] else { continue }
                ids.formUnion(members.compactMap(\.recordID))
            }
            return ids
        }

        var folderIDs: Set<UUID> { Set(folders.keys) }
        var isTop: Bool { scope == nil }
    }

    // MARK: - The levels

    /// Where the table is → its level.
    static func level(scope: FootageFolders.Scope?, index: FootageFolders.Index, display: FootageFolders.Display) -> Level {
        guard let scope else { return top(index: index, display: display) }
        return inside(scope, index: index, display: display)
    }

    /// The top: folders (date, then name) first, then the loose rows in
    /// the display's (the table's) order. `display` is the join's compose
    /// with no scope; a folder composed OPEN has its member rows right
    /// after it, and they become that folder's `children` (a collapsed
    /// folder simply has none). A loose file's copies are `.member` rows
    /// too, but they follow a `.loose` row, never a folder row — that is
    /// the whole rule.
    static func top(index: FootageFolders.Index, display: FootageFolders.Display) -> Level {
        var level = Level(scope: nil)
        var folderRows: [FolderRow] = []
        var loose: [FootageFolders.DisplayRow] = []
        loose.reserveCapacity(display.rows.count)
        // Which folder the member rows now belong to: .none = not under a
        // folder (loose); .some(nil) = under a folder the join no longer
        // has (dropped with it). (Swift's `UUID??` ≈ C++ optional<optional<UUID>>.)
        var owner: UUID?? = .none
        for row in display.rows {
            if let eventID = row.eventID {
                guard let folder = index.folders[eventID] else { owner = .some(nil); continue }   // a folder the join no longer has
                folderRows.append(folderRow(folder))
                owner = .some(eventID)
            } else if case .member = row.kind, case .some(let folderID) = owner {
                if let folderID { level.children[folderID, default: []].append(row) }
            } else {
                owner = .none
                loose.append(row)
            }
        }
        folderRows.sort(by: FolderRow.precedes)
        level.rows.reserveCapacity(folderRows.count + loose.count)
        for f in folderRows {
            guard let folder = index.folders[f.id] else { continue }
            level.folders[f.id] = f
            level.rows.append(.folder(folder))
        }
        level.rows += loose
        return level
    }

    /// Inside one event (or one file's family): the members with their
    /// glyph rows. `display` is the join's compose under that scope; its
    /// leading folder row (the event scope's) is dropped — the breadcrumb
    /// names the folder — and nothing else moves.
    static func inside(_ scope: FootageFolders.Scope, index: FootageFolders.Index, display: FootageFolders.Display) -> Level {
        var level = Level(scope: scope)
        level.rows = display.rows.filter { !$0.isFolder }
        return level
    }

    /// Does the scope still name something the join knows? An event that
    /// a merge or a dismiss removed, or a record that left the catalog,
    /// sends the table back to the top. An index that has not been built
    /// yet (no keys at all) says nothing either way.
    static func exists(_ scope: FootageFolders.Scope, in index: FootageFolders.Index) -> Bool {
        guard !index.keysOf.isEmpty else { return true }
        switch scope {
        case .event(let id): return index.folders[id] != nil
        case .family(let id): return index.keysOf[id] != nil
        }
    }

    // MARK: - A folder as a row

    static func folderRow(_ folder: FootageFolders.Folder) -> FolderRow {
        let s = folder.summary
        return FolderRow(id: folder.id, name: folder.title, kind: folder.kind, items: s.files, copies: s.copies, archived: s.archivedCount,
                         totalSeconds: s.totalSeconds, totalBytes: s.totalBytes, date: s.date ?? .distantPast,
                         dateWords: dateWords(summary: s))
    }

    /// The range of the folder's recordings when it is dated; the Events
    /// page's own words otherwise.
    static func dateWords(summary s: FootageFolders.Summary) -> String {
        guard let earliest = s.date else { return s.dateWords }
        return FootageFolderWords.dateRange(earliest, s.latestDate ?? earliest)
    }
}
