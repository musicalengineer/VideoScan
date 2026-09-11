// ArchiveSortPolicy.swift
// GH #175 (Rick 2026-09-10): "I need to see the recently archived files —
// the file list in archive view should show me the date archived column
// sorted." Pure rules for the Archive tab's "Archived" column:
//   • the first click on the column sorts NEWEST first (SwiftUI's default
//     would be oldest first);
//   • rows with no archived date sort LAST in either direction;
//   • a source row sorts by its master copy's date — the same date the
//     cell shows — which needs the model, so the view passes a closure.
// Table-testable, no view or model here.

import Foundation

enum ArchiveSortPolicy {

    /// True when the table's sort is on the Archived column.
    static func isArchivedDateSort(_ order: [KeyPathComparator<VideoRecord>]) -> Bool {
        order.first?.keyPath == \VideoRecord.archivedSortDate
    }

    /// The order the table should actually use after the user changed it:
    /// switching ONTO the Archived column lands newest-first; every later
    /// click on it toggles as the table decides; other columns untouched.
    static func adjusted(new: [KeyPathComparator<VideoRecord>],
                         previous: [KeyPathComparator<VideoRecord>]) -> [KeyPathComparator<VideoRecord>] {
        guard isArchivedDateSort(new), !isArchivedDateSort(previous),
              new.first?.order == .forward else { return new }
        return [KeyPathComparator(\VideoRecord.archivedSortDate, order: .reverse)]
    }

    /// Rows by archived date; undated rows last whichever way the dated
    /// ones run; ties and the undated keep their incoming order (stable).
    static func sortedByArchivedDate<Row>(_ rows: [Row], order: SortOrder,
                                          date: (Row) -> Date?) -> [Row] {
        let indexed = rows.enumerated().map { (offset: $0.offset, row: $0.element, date: date($0.element)) }
        let dated = indexed.filter { $0.date != nil }.sorted { a, b in
            guard let da = a.date, let db = b.date else { return false }
            if da != db { return order == .reverse ? da > db : da < db }
            return a.offset < b.offset
        }
        let undated = indexed.filter { $0.date == nil }
        return (dated + undated).map(\.row)
    }
}
