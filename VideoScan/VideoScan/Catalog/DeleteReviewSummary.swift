// DeleteReviewSummary.swift
// The "is it safe to delete these?" table, as a VALUE (Rick 2026-10-11):
//
//   "A user is simply thinking: is it safe to delete these because these
//    are extras or explicitly marked junk? Humans can't hold a spreadsheet
//    in their heads."
//
// SHAPE. A handful of plain-language recommendation rows, each with a file
// count, the space it frees and (where it may) a checkbox. This file is the
// pure half — no SwiftUI, no model, no disk — so the same table can later
// front Triage's Delete Junk and Delete Duplicates: a front fills the rows
// (its own classifier), `DeleteReviewSummaryView` draws them, and the
// selection maths below says what the ticked rows would move.
//
// SAFETY RULES BUILT INTO THE VALUE (not the view):
//   * `.onlyCopy` never offers a checkbox and never yields a removal, even
//     if a classifier handed it one (Rick's standing rule: the app never
//     deletes a single-copy unique file). Pinned by a sensor test.
//   * A row frees only its items that carry a removal — "copies of each
//     other" lists the copy that stays but frees only the extras.
//   * A removal is a REQUEST to an existing engine, which proves the
//     surviving copy at the move; it is never a delete by itself.
//
// (For Rick: an `enum` with associated values ≈ a tagged union — C++'s
// std::variant with a name on every alternative. `Sendable` ≈ "safe to hand
// to another thread by value".)

import Foundation

// MARK: - What a ticked file asks for

/// What moving one file asks of an existing engine. One case today — the
/// Delete Duplicates engine's reviewed pick (it re-proves the keeper in full
/// at the move). Triage's Delete Junk adds its own case when it adopts this
/// table; nothing here deletes.
enum DeleteReviewRemoval: Sendable, Hashable {
    case duplicate(ReviewedDuplicatePick)

    var recordID: UUID {
        switch self {
        case .duplicate(let pick): return pick.recordID
        }
    }
}

// MARK: - The rows

/// The recommendation rows, in the order the table shows them.
enum DeleteReviewCategory: Int, CaseIterable, Sendable, Hashable, Identifiable, Comparable {
    case copiesElsewhere
    case copiesOfEachOther
    case markedJunk
    case onlyCopy
    case unsure

    var id: Int { rawValue }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The row's recommendation, in family words.
    var title: String {
        switch self {
        case .copiesElsewhere: return "Copies exist elsewhere: safe to delete"
        case .copiesOfEachOther: return "Copies of each other: keep one, delete the extras"
        case .markedJunk: return "Marked junk by you (Confirmed in Triage): safe to delete"
        case .onlyCopy: return "Only copy: recommend keeping"
        case .unsure: return "Unsure: needs review"
        }
    }

    /// One line under the title saying why.
    var explanation: String {
        switch self {
        case .copiesElsewhere:
            return "Another copy with the very same bytes is kept on a drive. It is checked again, byte for byte, just before each file moves."
        case .copiesOfEachOther:
            return "These files are copies of one another. One of each is kept (on the best drive); only the extras move."
        case .markedJunk:
            return "You confirmed these as junk in Triage."
        case .onlyCopy:
            return "No other copy is known. These stay."
        case .unsure:
            return "Probably copies, but not yet checked byte for byte, or something needs a look. A ticked file is checked in full first; one that doesn't match stays."
        }
    }

    /// SF Symbol for the row.
    var symbol: String {
        switch self {
        case .copiesElsewhere: return "checkmark.circle.fill"
        case .copiesOfEachOther: return "square.on.square"
        case .markedJunk: return "trash"
        case .onlyCopy: return "lock.fill"
        case .unsure: return "questionmark.circle"
        }
    }

    /// May this row ever be ticked? Never for an only copy.
    var allowsRemoval: Bool { self != .onlyCopy }

    /// Ticked when the sheet opens.
    var checkedByDefault: Bool {
        switch self {
        case .copiesElsewhere, .copiesOfEachOther, .markedJunk: return true
        case .onlyCopy, .unsure: return false
        }
    }
}

/// One file in a row, as the disclosure list shows it.
struct DeleteReviewItem: Sendable, Identifiable, Equatable {
    let id: UUID
    let filename: String
    let path: String
    let sizeBytes: Int64
    /// Why this file is in this row ("kept: the copy that stays").
    let note: String
    /// What ticking the row asks for this file; nil = it stays whatever is ticked.
    let removal: DeleteReviewRemoval?
}

struct DeleteReviewRow: Sendable, Identifiable, Equatable {
    let category: DeleteReviewCategory
    let items: [DeleteReviewItem]
    /// Totals computed once here, so a view body reads them in O(1).
    let totalBytes: Int64
    /// The items a tick would move: those with a removal, and never any in
    /// a row that may not be ticked.
    let removableCount: Int
    let freeableBytes: Int64

    init(category: DeleteReviewCategory, items: [DeleteReviewItem]) {
        self.category = category
        self.items = items
        totalBytes = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let removable = category.allowsRemoval ? items.filter { $0.removal != nil } : []
        removableCount = removable.count
        freeableBytes = removable.reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    var id: DeleteReviewCategory { category }
    var fileCount: Int { items.count }

    /// A checkbox is drawn only when ticking would move something.
    var isSelectable: Bool { removableCount > 0 }

    /// What a tick on this row asks for, in list order.
    var removals: [DeleteReviewRemoval] {
        guard category.allowsRemoval else { return [] }
        return items.compactMap(\.removal)
    }
}

// MARK: - The table

struct DeleteReviewSummary: Sendable, Equatable {
    /// Non-empty rows, in category order (an empty row is hidden).
    let rows: [DeleteReviewRow]

    static let empty = DeleteReviewSummary(rows: [])

    init(rows: [DeleteReviewRow]) {
        self.rows = rows.filter { !$0.items.isEmpty }.sorted { $0.category < $1.category }
    }

    /// Group items by category into rows.
    init(grouping items: [(DeleteReviewCategory, DeleteReviewItem)]) {
        var byCategory: [DeleteReviewCategory: [DeleteReviewItem]] = [:]
        for (category, item) in items { byCategory[category, default: []].append(item) }
        self.init(rows: byCategory.map { DeleteReviewRow(category: $0.key, items: $0.value) })
    }

    var fileCount: Int { rows.reduce(0) { $0 + $1.fileCount } }
    var totalBytes: Int64 { rows.reduce(Int64(0)) { $0 + $1.totalBytes } }

    func row(_ category: DeleteReviewCategory) -> DeleteReviewRow? { rows.first { $0.category == category } }

    /// One line for the logs: "Copies exist elsewhere: safe to delete 675 (592 GB); …".
    var logLine: String {
        rows.map { "\($0.category.title) \($0.fileCount.formatted()) (\(MediaBytes.display($0.totalBytes)))" }
            .joined(separator: "; ")
    }

    /// The rows ticked when the table opens: selectable AND checked by default.
    var defaultSelection: Set<DeleteReviewCategory> {
        Set(rows.filter { $0.isSelectable && $0.category.checkedByDefault }.map(\.category))
    }

    /// The ticked rows' totals. O(rows) — safe in a view body. A tick on a
    /// row that may not be ticked contributes nothing.
    func totals(_ checked: Set<DeleteReviewCategory>) -> DeleteReviewTotals {
        var totals = DeleteReviewTotals(fileCount: 0, bytes: 0)
        for row in rows where checked.contains(row.category) {
            totals.fileCount += row.removableCount
            totals.bytes += row.freeableBytes
        }
        return totals
    }

    /// What the ticked rows ask for, in table order. O(files) — call it at
    /// Apply, not in a body.
    func removals(_ checked: Set<DeleteReviewCategory>) -> [DeleteReviewRemoval] {
        rows.filter { checked.contains($0.category) }.flatMap(\.removals)
    }

    /// Every pick for the Delete Duplicates engine the ticked rows ask for.
    func duplicatePicks(_ checked: Set<DeleteReviewCategory>) -> [ReviewedDuplicatePick] {
        removals(checked).map { removal in
            switch removal {
            case .duplicate(let pick): return pick
            }
        }
    }
}

/// The ticked rows' sum: the footer line and the button.
struct DeleteReviewTotals: Sendable, Equatable {
    var fileCount: Int
    var bytes: Int64

    var isEmpty: Bool { fileCount == 0 }

    /// "Selected: 701 files, 836 GB will move to the Trash (you can Put Back from Finder)".
    var footerLine: String {
        guard !isEmpty else { return "Nothing selected: no file will move to the Trash" }
        return "Selected: \(fileCount.formatted()) file\(fileCount == 1 ? "" : "s"), \(MediaBytes.display(bytes)) will move to the Trash (you can Put Back from Finder)"
    }

    /// "Move 701 to Trash".
    var moveTitle: String { "Move \(fileCount.formatted()) to Trash" }
}
