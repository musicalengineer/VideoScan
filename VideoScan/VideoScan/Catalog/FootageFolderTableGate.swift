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
// context menu / focused values applied outside it. Inside that host, a
// paint-revision bump with the SAME rows re-ran the visible cells (24 of
// 24 on screen) and no row closures — the repaint is cheap.
//
// THE SEAM. All here:
//   • FootageFolderTablePaint — everything the folder Table draws, as one
//     value with a hand-written ==: the rows (`drawsTheSame`), the
//     selection, the twisted-open folders, the sort, Show Pairs Only, the
//     Angel's badge revision and the paint clock's revision.
//   • FootageFolderTableHost — the Equatable wrapper (`.equatable()`); its
//     body is the Table, built by CatalogContent as before.
//   • CatalogPaintClock — the one knob for what the paint value cannot
//     see: a record is a class written IN PLACE (a date typed in the
//     inspector, a tag, a drive going offline), so its cells repaint when
//     the model says something changed. Coalesced (CatalogPaintThrottle):
//     at most one paint per 0.25 s when quiet or when Rick just acted
//     (urgent), at most one per 10 s for a catalog-writing job's churn.
//     The last request of a burst always lands (trailing edge).
//   • The rows: rebuilt only when the folder display lands, published only
//     when they would draw differently (FootageFolderTableRows); a
//     digest-only commit changes no row.
//
// The row type is deliberately NOT Equatable (FootageFolderTableRow.swift):
// the only equality question is "would the Table draw the same rows?",
// asked here by name.
//
// COST. No O(records) work in any body. Building the paint value is O(1);
// comparing two of them is O(1) while the rows are the same array (the
// buffer-identity fast path in `drawsTheSame`) and O(rows) when a display
// lands with a new array — once per landing, not per publish.
//
// (For Rick: the host is a memoised render — like a C++ widget that keeps
// its last-drawn inputs and returns early from paint() when operator== says
// nothing changed. The clock is a leading+trailing debounce on a monotonic
// clock, std::chrono::steady_clock rather than system_clock.)

import AppKit
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

    static func == (a: Self, b: Self) -> Bool {
        a.paintRevision == b.paintRevision && a.angelBadgeRevision == b.angelBadgeRevision && a.pairTint == b.pairTint
            && a.selectedIDs == b.selectedIDs && a.rowSelection == b.rowSelection && a.expanded == b.expanded
            && a.sort == b.sort && FootageFolderTableRows.drawsTheSame(a.rows, b.rows)
    }
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

    /// Would the Table draw the same rows from `a` and `b`? The same id,
    /// display, folder summary, sort facts, members and folder per row —
    /// and the SAME record object (`===`): a record replaced by a fresh
    /// object with the same id (a rescan) is a different row, so the cells
    /// never keep reading a retired object. The record's own fields are not
    /// compared (a class written in place — the paint clock repaints them).
    /// O(1) when both are the same array buffer, else O(rows).
    /// (For Rick: `===` ≈ comparing two pointers.)
    static func drawsTheSame(_ a: [FootageFolderTableRow], _ b: [FootageFolderTableRow]) -> Bool {
        guard a.count == b.count else { return false }
        let sameBuffer = a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
        if sameBuffer { return true }
        return zip(a, b).allSatisfy { rowDrawsTheSame($0, $1) }
    }

    private static func rowDrawsTheSame(_ a: FootageFolderTableRow, _ b: FootageFolderTableRow) -> Bool {
        guard a.id == b.id, a.record === b.record, a.inFolder == b.inFolder, a.display == b.display,
              a.folder == b.folder, a.keys == b.keys else { return false }
        switch (a.children, b.children) {
        case (nil, nil): return true
        case let (x?, y?): return drawsTheSame(x, y)
        default: return false
        }
    }

    /// Publish `new` over `current` only when the Table would draw
    /// something different. O(rows), event handler only.
    static func shouldPublish(_ new: [FootageFolderTableRow], over current: [FootageFolderTableRow]) -> Bool {
        !drawsTheSame(new, current)
    }
}

// MARK: - The paint clock (in-place record changes, coalesced)

/// Who is writing to the catalog right now, in words — the paint clock
/// slows down for it and the viewer-snapshot publisher waits for it.
/// nil = nobody. Pure. The job half is
/// `MediaFileOperationsCenter.runningCatalogWriterTitle` (MediaOps/CatalogWriterJobs.swift).
enum CatalogWriteActivity {
    static func words(catalogWriterTitle: String?, scanning: Bool) -> String? {
        if let title = catalogWriterTitle, !title.isEmpty { return "\(title) is running" }
        return scanning ? "a scan is running" : nil
    }
}

/// "Did Rick just do something?" — the urgency rule. A model publish that
/// arrives within `window` of his last key press or click is treated as his
/// (an inspector commit, a row-menu Tag or Disposition, a typed date or
/// place) and paints at the quiet pace even while a job writes; the job's
/// own churn arrives with no recent event and keeps the 10 s gap. ONE rule
/// at the clock instead of a flag at every edit site.
enum CatalogUserEditRecency {
    static let window: TimeInterval = 1.0

    /// Both times are seconds since boot (NSEvent.timestamp's clock). Pure.
    static func isRecent(eventTimestamp: TimeInterval?, now: TimeInterval) -> Bool {
        guard let t = eventTimestamp else { return false }
        let age = now - t
        return age >= 0 && age <= window
    }

    /// Only a discrete action is an edit: a key press or a click's release
    /// (a menu choice, a button, a field commit). NSApp.currentEvent
    /// OUTLIVES its dispatch (QA r2), so a hover, a drag, a scroll or a
    /// modifier change would otherwise make every job commit inside the next
    /// second "urgent" while Rick merely browses.
    static let editTypes: Set<NSEvent.EventType> = [.keyDown, .leftMouseUp, .rightMouseUp, .otherMouseUp]

    static func isEdit(_ type: NSEvent.EventType) -> Bool { editTypes.contains(type) }

    /// The live answer (main thread: the last event AppKit dispatched).
    @MainActor
    static func now() -> Bool {
        guard let event = NSApp.currentEvent, isEdit(event.type) else { return false }
        return isRecent(eventTimestamp: event.timestamp, now: ProcessInfo.processInfo.systemUptime)
    }
}

/// The coalescing rule, pure, on a MONOTONIC clock (a wall-clock step can
/// never push a paint into the future). A request paints at once when the
/// last paint is at least one gap old; otherwise one trailing paint is
/// scheduled at `last + gap` (or kept, when one is already due no later).
/// `urgent` (Rick just acted) uses the quiet gap even while a job writes.
struct CatalogPaintThrottle: Equatable {
    typealias Instant = ContinuousClock.Instant
    static let idleGap: Duration = .milliseconds(250)
    static let busyGap: Duration = .seconds(10)

    enum Decision: Equatable {
        case paintNow
        case paintAt(Instant)
        case alreadyScheduled
    }

    private(set) var lastPaint: Instant?
    private(set) var scheduled: Instant?

    mutating func request(now: Instant, busy: Bool, urgent: Bool = false) -> Decision {
        let gap = (busy && !urgent) ? Self.busyGap : Self.idleGap
        // `now` before the last paint cannot happen on this clock; if a
        // caller ever hands one in, it paints rather than waiting past `now + gap`.
        guard let last = lastPaint, now >= last, now - last < gap else {
            didPaint(at: now)
            return .paintNow
        }
        let due = last + gap
        if let scheduled, scheduled <= due { return .alreadyScheduled }
        scheduled = due
        return .paintAt(due)
    }

    mutating func didPaint(at instant: Instant) {
        lastPaint = instant
        scheduled = nil
    }
}

/// The revision the folder Table repaints on. Owned by the Catalog pane
/// (a @State reference in CatalogTableState), fed by the model's publishes.
@MainActor
final class CatalogPaintClock: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    private var throttle = CatalogPaintThrottle()
    private var trailing: Task<Void, Never>?

    /// Something the cells may show changed. `busy` = a catalog-writing job
    /// or a scan runs (the 10 s gap); `urgent` = Rick just acted.
    func request(busy: Bool, urgent: Bool = false, now: ContinuousClock.Instant = .now) {
        switch throttle.request(now: now, busy: busy, urgent: urgent) {
        case .paintNow:
            trailing?.cancel()
            trailing = nil
            revision &+= 1
        case .paintAt(let due):
            trailing?.cancel()
            trailing = Task { [weak self] in
                try? await Task.sleep(until: due, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                self.throttle.didPaint(at: .now)
                self.trailing = nil
                self.revision &+= 1
            }
        case .alreadyScheduled:
            break
        }
    }
}
