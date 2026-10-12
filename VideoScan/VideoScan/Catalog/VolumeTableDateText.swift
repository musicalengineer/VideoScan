// VolumeTableDateText.swift
// Date text for the Catalog's volume table and backup pill, with the
// formatters built ONCE.
//
// 2026-10-11 resize hang: the Scanned column built a fresh DateFormatter
// per cell per body evaluation (and the backup pill's tooltip another),
// which made `CatalogView.shortDateStatic` the hottest frame of the
// Catalog window's own body in the main-thread sample. A DateFormatter is
// expensive to create (ICU setup) and cheap to reuse — like constructing
// a std::locale per call instead of holding one.
//
// Main-actor only (DateFormatter is not thread-safe to share), which is
// where the views that call it run.

import Foundation

@MainActor
enum VolumeTableDateText {

    private static let thisYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let otherYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static let mediumDateShortTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// "Oct 11" this year, "Oct 11, 2025" otherwise — the Scanned column.
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? thisYear : otherYear).string(from: date)
    }

    /// Medium date + short time — the backup pill's tooltip.
    static func backupTooltip(_ date: Date) -> String {
        mediumDateShortTime.string(from: date)
    }
}
