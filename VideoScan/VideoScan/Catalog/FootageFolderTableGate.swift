// FootageFolderTableGate.swift
// GH #350: the Catalog's folder Table only redraws when something it SHOWS
// changed.
//
// WHY. CatalogContent observes the whole model and the MFO center
// (@EnvironmentObject). Every publish of either — a commit bumping
// `catalogMutationRevision`, a console line, a job's once-a-second progress
// forwarded by the center — re-ran CatalogContent's body, and the folder
// Table (an outline: DisclosureTableRow) then walked EVERY row closure
// again, even when the rows were the very same array. Measured 2026-10-20
// in a standalone harness (2,000 folders × 4 members, -O): every unrelated
// publish ran all 2,000 row closures; ~10.7k rows in the Debug app pegged
// the main thread for the whole of Fill In Full Hashes (12 of 12 `sample`
// frames in AppKitOutlineTableCoordinator.update). Making the rows
// Equatable alone changed nothing (same harness); an Equatable host view
// whose inputs did not change ran ZERO row closures, even with the
// context menu / focused values applied outside it.
//
// THE SEAM. Three parts, all here:
//   • FootageFolderTablePaint — everything the folder Table draws, as one
//     Equatable value: the rows, the selection, the twisted-open folders,
//     the sort, Show Pairs Only, the Angel's badge revision, and the paint
//     clock's revision. The host view compares THIS and nothing else.
//   • FootageFolderTableHost — the Equatable wrapper (`.equatable()`); its
//     body is the Table, built by CatalogContent as before.
//   • CatalogPaintClock — the one knob for what the paint value cannot
//     see: a record is a class written IN PLACE (a date typed in the
//     inspector, a tag, a drive going offline), so its cells repaint when
//     the model says something changed. The clock follows the model's
//     publishes, coalesced: at most one paint per 0.25 s when the catalog
//     is quiet, at most one per 10 s while a job or a scan writes to it
//     (CatalogPaintThrottle). Nothing is ever left unpainted: the last
//     request of a burst always lands (trailing edge).
// And the rows themselves are rebuilt only when the folder display lands,
// and published only when the new array differs (FootageFolderTableRows);
// a digest-only commit changes no row.
//
// NO O(records) work in any body: the paint value is O(1) to build (the
// rows array is compared by buffer identity first when unchanged — the
// stdlib's Array == fast path); the row build runs in the display handler.
//
// (For Rick: the host is a memoised render — like a C++ widget that keeps
// its last-drawn inputs and returns early from paint() when operator== says
// nothing changed. The clock is a leading+trailing debounce.)

import Combine
import Foundation
import SwiftUI

// MARK: - What the folder Table draws

/// Every input the folder Table's rows and cells draw from that is not the
/// record object itself. Equal value → the Table is not touched.
struct FootageFolderTablePaint: Equatable {
    var rows: [FootageFolderTableRow]
    /// The files highlighted (a folder title tints from this).
    var selectedIDs: Set<UUID>
    /// The rows Rick clicked (a file shown twice keeps its highlight there).
    var rowSelection: Set<UUID>
    var expanded: Set<UUID>
    var sort: [KeyPathComparator<FootageFolderTableRow>]
    var pairTint: Bool
    var angelBadgeRevision: Int
    /// CatalogPaintClock.revision: in-place record changes.
    var paintRevision: UInt64
}

/// The folder Table behind an equality gate. `content` builds the Table
/// exactly as before; it is NOT compared (a closure has no equality), so
/// everything it reads must be in `paint`.
struct FootageFolderTableHost<Content: View>: View, Equatable {
    let paint: FootageFolderTablePaint
    @ViewBuilder let content: () -> Content

    static func == (a: Self, b: Self) -> Bool { a.paint == b.paint }

    var body: some View { content() }
}

// MARK: - The rows (built in the display handler, published only on change)

/// The level → the Table's rows, pure: record lookups go through `record`
/// (the model's O(1) id index in the app), the sort facts through `keys`
/// when the join has not seen a row yet (a derivative that just landed).
enum FootageFolderTableRows {

    static func build(_ level: FootageFolderLevel.Level, index: FootageFolders.Index,
                      record: (UUID) -> VideoRecord?,
                      keys: (VideoRecord) -> FootageFolders.SortKeys) -> [FootageFolderTableRow] {
        var rows: [FootageFolderTableRow] = []
        rows.reserveCapacity(level.rows.count)
        // Inside a folder, every row is seen inside it.
        var scopeFolder: UUID?
        if case .event(let id)? = level.scope { scopeFolder = id }
        for d in level.rows {
            if let e = d.eventID {
                let members = (level.children[e] ?? []).compactMap {
                    recordRow($0, index: index, inFolder: e, record: record, keys: keys)
                }
                rows.append(FootageFolderTableRow(display: d, record: nil, folder: level.folders[e],
                                                  keys: index.folders[e]?.keys ?? FootageFolders.SortKeys(),
                                                  children: members.isEmpty ? nil : members))
            } else if let row = recordRow(d, index: index, inFolder: scopeFolder, record: record, keys: keys) {
                rows.append(row)
            }
        }
        return rows
    }

    /// A record's row; nil when the record has left the catalog.
    private static func recordRow(_ d: FootageFolders.DisplayRow, index: FootageFolders.Index, inFolder: UUID?,
                                  record: (UUID) -> VideoRecord?,
                                  keys: (VideoRecord) -> FootageFolders.SortKeys) -> FootageFolderTableRow? {
        guard let id = d.recordID, let rec = record(id) else { return nil }
        return FootageFolderTableRow(display: d, record: rec, keys: index.keysOf[id] ?? keys(rec), inFolder: inFolder)
    }

    /// Publish `new` over `current` only when the Table would draw
    /// something different. O(rows) compare, event handler only.
    static func shouldPublish(_ new: [FootageFolderTableRow], over current: [FootageFolderTableRow]) -> Bool {
        new != current
    }
}

// MARK: - The paint clock (in-place record changes, coalesced)

/// Who is writing to the catalog right now, in words — the paint clock
/// slows down for it and the viewer-snapshot publisher waits for it.
/// nil = nobody. Pure.
enum CatalogWriteActivity {
    static func words(runningJobTitle: String?, scanning: Bool) -> String? {
        if let title = runningJobTitle, !title.isEmpty { return "\(title) is running" }
        return scanning ? "a scan is running" : nil
    }
}

extension MediaFileOperationsCenter {
    /// The first live job's title (one that is not merely waiting to be
    /// stopped); nil when none runs. O(jobs).
    var firstRunningJobTitle: String? {
        jobs.first { $0.state.isActive && !$0.isQuiescentForQuit }?.title
    }
}

/// The coalescing rule, pure. A request paints at once when the last paint
/// is at least one gap old; otherwise one trailing paint is scheduled at
/// `last + gap` (or kept, when one is already due no later than that).
struct CatalogPaintThrottle: Equatable {
    static let idleGap: TimeInterval = 0.25
    static let busyGap: TimeInterval = 10

    enum Decision: Equatable {
        case paintNow
        case paintAt(Date)
        case alreadyScheduled
    }

    private(set) var lastPaint: Date?
    private(set) var scheduled: Date?

    mutating func request(now: Date, busy: Bool) -> Decision {
        let gap = busy ? Self.busyGap : Self.idleGap
        guard let last = lastPaint, now.timeIntervalSince(last) < gap else {
            didPaint(at: now)
            return .paintNow
        }
        let due = last.addingTimeInterval(gap)
        if let scheduled, scheduled <= due { return .alreadyScheduled }
        scheduled = due
        return .paintAt(due)
    }

    mutating func didPaint(at date: Date) {
        lastPaint = date
        scheduled = nil
    }
}

/// The revision the folder Table repaints on. Owned by the Catalog pane
/// (a @State reference), fed by the model's publishes.
@MainActor
final class CatalogPaintClock: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    private var throttle = CatalogPaintThrottle()
    private var trailing: Task<Void, Never>?

    /// Something the cells may show changed. `busy` = a job or a scan is
    /// writing to the catalog (the 10 s gap).
    func request(busy: Bool, now: Date = Date()) {
        switch throttle.request(now: now, busy: busy) {
        case .paintNow:
            trailing?.cancel()
            trailing = nil
            revision &+= 1
        case .paintAt(let due):
            trailing?.cancel()
            let delay = max(0, due.timeIntervalSince(now))
            trailing = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.throttle.didPaint(at: Date())
                self.trailing = nil
                self.revision &+= 1
            }
        case .alreadyScheduled:
            break
        }
    }
}
