// CatalogReminderClock.swift — the 7-day REMINDER clocks on the catalog
// backup and on sync (Rick 2026-11-07: "we still want a clock on the catalog
// backup and we still want a clock on sync as a reminder to periodically
// check, say 7 days or so"; DECISIONS 2026-11-07).
//
// A reminder, not an alarm: under 7 days → fresh (green / plain); 7 days or
// more, or never → remind (yellow: "it's been a while, check it"). There is
// no orange or red step — nothing is broken because a week passed.
//
// Read by: the Backup Catalog pill (CatalogView+VolumeTable), the viewer's
// sync chip (CatalogInfoWindow's ViewerStatusChip) and Catalog Database
// Info's "Last backup" / "Last sync" rows. The dates are the ones those
// surfaces already show (VideoScan.lastBackupAt; CatalogSync's
// last_sync.txt); this file only judges their age. Pure, O(1).

import Foundation

enum CatalogReminderClock {

    /// 7 days.
    static let remindAfter: TimeInterval = 7 * 86_400

    enum State: Equatable {
        /// Within 7 days.
        case fresh
        /// 7 days or more since `last`, or never (`last` nil).
        case remind
    }

    static func state(last: Date?, now: Date) -> State {
        guard let last else { return .remind }
        return now.timeIntervalSince(last) >= remindAfter ? .remind : .fresh
    }

    /// The backup pill's reminder words (tooltip), nil when fresh.
    static func backupReminder(last: Date?, now: Date) -> String? {
        guard state(last: last, now: now) == .remind else { return nil }
        return last == nil ? "No catalog backup yet — a reminder to make one."
            : "It's been 7 days or more since the last catalog backup — a reminder to make a fresh one."
    }

    /// The sync chip's reminder words, nil when fresh or never synced (the
    /// chip already says "never synced" / "no previous snapshot").
    static func syncReminder(last: Date?, now: Date) -> String? {
        guard let last, state(last: last, now: now) == .remind else { return nil }
        return "7 days or more since the last sync — check the master is reachable"
    }

    /// Catalog Database Info's suffix on the Last backup / Last sync value.
    static func infoSuffix(last: Date?, now: Date) -> String {
        guard let last, state(last: last, now: now) == .remind else { return "" }
        return " — 7 days or more ago; a reminder to check it"
    }
}
