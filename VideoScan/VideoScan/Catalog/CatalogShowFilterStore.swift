// CatalogShowFilterStore.swift
// The Catalog ▸ Show filters: the filter list, and the ONE store that owns
// which of them are on (Rick 2026-11-17, after a row vanished under a filter
// he had not knowingly set — DECISIONS "The Catalog's Show menu is cut to the
// bare minimum").
//
// ONE OWNER. `CatalogShowFilterStore` holds the active set. Nothing else may
// change it: `active` is `private(set)`, and the persisted keys are named in
// this file only (sensor: ShowFiltersAuditSensorTests). Every writer — the
// Show menu, the Analyze menu, the Steward's "Show one per footage", the empty
// table's Clear All Filters, the one-time seed — calls a method here and names
// itself, and every change writes ONE line through the app's log sink saying
// what changed, who changed it and what is on now. Launch logs what was
// restored.
//
// STABLE KEYS. The set is stored as the filters' `rawValue`s ("notYetArchived"),
// never the menu's words, so a reworded menu cannot drop a setting. The old
// value (`catalog.viewFilters`, the menu labels joined by "|") is migrated
// once: the filters that remain are carried over, the ones the 2026-11-17 trim
// removed and anything unknown are dropped, and the log says which.
//
// ONE RULE. Not Yet Archived and Has Master Copy cannot both be on (together
// they empty the table): turning one on turns the other off, in the same
// change and the same log line.
//
// LIFETIME. ContentView's root owns it as a @StateObject, above the tabs (the
// CatalogPersonFilterStore pattern, #337 — no new VideoScanModel state), so
// the Steward on the Triage tab reaches it while the Catalog view is not alive.
//
// COST. A set of at most six small enums and two UserDefaults writes per
// change; no records are read here. Worst-case memory: a few hundred bytes.
//
// (For Rick: an `ObservableObject` with `@Published private(set)` ≈ a C++
// class with a public const getter, private setter and an observer list; the
// `Writer` enum is the caller's badge on every mutating call.)

import Combine
import Foundation
import SwiftUI
import VideoScanCore

// MARK: - The filters

/// One Show ▸ filter. The raw value is the STABLE persisted key; the menu and
/// the Showing box both say `title`. Declaration order is menu order.
enum CatalogViewFilter: String, CaseIterable, Hashable, Sendable {
    // Removed 2026-11-17 (Rick: "trim the show down to the absolute bare
    // minimum"): Video+Audio Only, Rated Only, Has Family, In Workspace,
    // Untagged (junk candidate), Archive Candidates, No Place Yet. Confirmed
    // Date was inverted into Needs a Date. (.onlineOnly went 2026-07-20.)
    case unpairedOnly
    /// Repair-lifecycle worklist (GH #132 P3): repair copies waiting for
    /// Rick's one-click "Sounds Good". Named for removal on 2026-11-17 but
    /// KEPT until Rick rules: it is the only way to list that queue.
    case awaitingConfirmation
    /// Master Archive (2026-08-15): live sources without a promoted copy.
    /// Backed by pfNotYetArchived (memoized reverse index — O(1) per record).
    case notYetArchived
    /// Master Archive: sources whose master copy is proven.
    case hasMasterCopy
    /// "Hide Other Versions" (Find Similar Footage, 2026-09-23; the menu said
    /// "One Per Footage" until 2026-11-17 — the case name and the stored key
    /// keep the old word, which is the point of a stable key): one file per
    /// same-footage group — its best-ranked VISIBLE member — plus every
    /// ungrouped file, and one of any set of byte-identical files the footage
    /// run has not grouped yet (CatalogOneOfIdentical).
    case onePerFootage
    /// Rows with no usable filing date (2026-11-17, the inverse of the old
    /// Confirmed Date): the ones Promote would file under Undated/. Backed by
    /// pfRecordNeedsDate — the Archive tab's "Needs a Date" rule.
    case needsDate

    /// The words the Show menu AND the Showing box use — one vocabulary.
    var title: String {
        switch self {
        case .unpairedOnly:         return "Unpaired Only"
        case .awaitingConfirmation: return "Repaired — Awaiting Confirmation"
        case .notYetArchived:       return "Not Yet Archived"
        case .hasMasterCopy:        return "Has Master Copy"
        case .onePerFootage:        return "Hide Other Versions"
        case .needsDate:            return "Needs a Date"
        }
    }

    var icon: String {
        switch self {
        case .unpairedOnly:         return "exclamationmark.triangle"
        case .awaitingConfirmation: return "checkmark.seal"
        case .notYetArchived:       return "archivebox"
        case .hasMasterCopy:        return "archivebox.fill"
        case .onePerFootage:        return "square.stack.3d.up"
        case .needsDate:            return "calendar.badge.exclamationmark"
        }
    }

    /// The pure per-record test behind this filter — nil for the filters that
    /// need the model (the archive index) or a whole-group pass (one per
    /// footage). `CatalogRows` applies every non-nil one in declaration order,
    /// in ONE place. (≈ a C++ table of function pointers keyed by the enum.)
    var recordPredicate: ((VideoRecord) -> Bool)? {
        switch self {
        case .unpairedOnly:
            return { ($0.streamType == .videoOnly || $0.streamType == .audioOnly) && $0.pairedWith == nil }
        case .awaitingConfirmation: return pfAwaitingConfirmation
        case .needsDate:            return pfRecordNeedsDate
        case .notYetArchived, .hasMasterCopy, .onePerFootage:
            return nil
        }
    }

    /// The filter that cannot be on with this one (they empty the table).
    var excludes: CatalogViewFilter? {
        switch self {
        case .notYetArchived: return .hasMasterCopy
        case .hasMasterCopy:  return .notYetArchived
        default:              return nil
        }
    }

    /// The members of `set` in menu order — every list of filter names is
    /// built from this, so two surfaces never disagree on order.
    static func ordered(_ set: Set<CatalogViewFilter>) -> [CatalogViewFilter] {
        allCases.filter(set.contains)
    }
}

// MARK: - The store

@MainActor
final class CatalogShowFilterStore: ObservableObject {

    /// Who asked for a change. The raw value is what the log line says.
    enum Writer: String, CaseIterable, Sendable {
        case showMenu = "Show menu"
        case analyzeMenu = "Analyze menu"
        case steward = "Steward"
        case emptyTable = "empty-table note"
        case seed = "first-run default"
    }

    /// The filters that are on. Read anywhere; written only here.
    @Published private(set) var active: Set<CatalogViewFilter> = []

    /// The stable-key setting: filter raw values joined by ",".
    nonisolated static let key = "catalog.showFilters.v2"
    /// The pre-2026-11-17 setting: menu labels joined by "|". Read once, then removed.
    nonisolated static let legacyKey = "catalog.viewFilters"
    /// Set the first time the Not Yet Archived default was applied.
    nonisolated static let seededKey = "catalog.viewFilters.seeded"
    /// The Show ▸ hidden-records reveals (Removed, Set aside) that were
    /// removed 2026-11-17. Their stored values are deleted at launch: a
    /// stored `true` must never leave those rows listed with no menu row to
    /// turn it off. (Superseded originals was session-only: nothing stored.)
    nonisolated static let retiredRevealKeys = ["catalogShowRemoved", "catalogShowSetAside"]
    nonisolated static let separator = ","
    nonisolated static let legacySeparator = "|"
    /// Every line this store writes starts with this.
    nonisolated static let logPrefix = "Catalog Show filters: "

    /// Old menu label → the filter it still is.
    nonisolated static let legacyLabels: [String: CatalogViewFilter] = [
        "Unpaired Only": .unpairedOnly,
        "Repaired — Awaiting Confirmation": .awaitingConfirmation,
        "Not Yet Archived": .notYetArchived,
        "Has Master Copy": .hasMasterCopy,
        "One Per Footage": .onePerFootage,
    ]
    /// Old menu labels the 2026-11-17 trim removed. Confirmed Date is here on
    /// purpose: Needs a Date is its opposite, so it is dropped, not carried.
    nonisolated static let removedLegacyLabels: Set<String> = [
        "Video+Audio Only", "Rated Only", "Has Family", "In Workspace", "Untagged (junk candidate)",
        "Archive Candidates", "No Place Yet", "Confirmed Date",
    ]

    private let defaults: UserDefaults
    private let log: (String) -> Void

    /// Reads (and, once, migrates) the stored set and logs what was restored.
    init(defaults: UserDefaults, log: @escaping (String) -> Void) {
        self.defaults = defaults
        self.log = log
        let restored = Self.restore(from: defaults)
        active = restored.filters
        if restored.rewrite {
            defaults.set(Self.encode(restored.filters), forKey: Self.key)
            defaults.removeObject(forKey: Self.legacyKey)
        }
        log(Self.logPrefix + "restored at launch → " + Self.names(restored.filters) + restored.note)
        if let line = Self.retireHiddenRecordReveals(in: defaults) { log(line) }
    }

    /// The app's store: the standard defaults and the one log sink.
    static func production() -> CatalogShowFilterStore {
        CatalogShowFilterStore(defaults: .standard, log: { appLog.write($0) })
    }

    // MARK: Writers

    /// Turn one filter on or off. Turning on a filter turns off the one it
    /// excludes. No change → no write, no line.
    func set(_ filter: CatalogViewFilter, on: Bool, by writer: Writer) {
        commit(Self.applying(filter, on: on, to: active), by: writer)
    }

    /// Clear All Filters.
    func clearAll(by writer: Writer) {
        commit([], by: writer)
    }

    /// Once a Master Archive exists the catalog defaults to the to-do view
    /// (Rick 2026-08-22). Applied ONCE per install and logged; after that the
    /// Show menu is the user's call. Has Master Copy on → left alone.
    func seedDefaultIfUntouched(hasMasterArchive: Bool) {
        guard hasMasterArchive, !defaults.bool(forKey: Self.seededKey) else { return }
        defaults.set(true, forKey: Self.seededKey)
        guard !active.contains(.hasMasterCopy) else { return }
        set(.notYetArchived, on: true, by: .seed)
    }

    private func commit(_ next: Set<CatalogViewFilter>, by writer: Writer) {
        guard next != active else { return }
        let line = Self.changeLine(from: active, to: next, by: writer)
        active = next
        defaults.set(Self.encode(next), forKey: Self.key)
        log(line)
    }

    // MARK: Pure rules (tested without a store)

    /// Delete the retired reveal settings. Returns the one line to log when
    /// a reveal was ON (rows that were listed are hidden again); nil when
    /// there was nothing to say. Idempotent.
    nonisolated static func retireHiddenRecordReveals(in defaults: UserDefaults) -> String? {
        var wasOn: [String] = []
        for key in retiredRevealKeys where defaults.object(forKey: key) != nil {
            if defaults.bool(forKey: key) { wasOn.append(key) }
            defaults.removeObject(forKey: key)
        }
        guard !wasOn.isEmpty else { return nil }
        return logPrefix + "the Show menu's hidden-records reveals were removed; "
            + wasOn.joined(separator: ", ") + " was on and is now off — removed and set-aside rows are hidden again"
    }

    /// `set` after `filter` goes on or off — the exclusion applied.
    nonisolated static func applying(_ filter: CatalogViewFilter, on: Bool,
                                     to set: Set<CatalogViewFilter>) -> Set<CatalogViewFilter> {
        var next = set
        if on {
            next.insert(filter)
            if let other = filter.excludes { next.remove(other) }
        } else {
            next.remove(filter)
        }
        return next
    }

    /// A set no surface could have produced (both archive filters, from an
    /// old or hand-edited setting) made legal: Not Yet Archived wins.
    nonisolated static func legal(_ set: Set<CatalogViewFilter>) -> Set<CatalogViewFilter> {
        set.contains(.notYetArchived) && set.contains(.hasMasterCopy) ? set.subtracting([.hasMasterCopy]) : set
    }

    /// "Not Yet Archived, Needs a Date" in menu order; "none" for the empty set.
    nonisolated static func names(_ set: Set<CatalogViewFilter>) -> String {
        set.isEmpty ? "none" : CatalogViewFilter.ordered(set).map(\.title).joined(separator: ", ")
    }

    /// The one line a change writes: what went on, what went off, who, and
    /// what is on now.
    nonisolated static func changeLine(from old: Set<CatalogViewFilter>, to new: Set<CatalogViewFilter>,
                                       by writer: Writer) -> String {
        let on = CatalogViewFilter.ordered(new.subtracting(old)).map { "on: " + $0.title }
        let off = CatalogViewFilter.ordered(old.subtracting(new)).map { "off: " + $0.title }
        return logPrefix + (on + off).joined(separator: "; ") + " (by \(writer.rawValue)) → now " + names(new)
    }

    nonisolated static func encode(_ set: Set<CatalogViewFilter>) -> String {
        CatalogViewFilter.ordered(set).map(\.rawValue).joined(separator: separator)
    }

    /// What launch restores: the filters, a note for the log line, and
    /// whether the stored value must be rewritten (a migration, or a value
    /// that held something this build dropped).
    struct Restored: Equatable {
        var filters: Set<CatalogViewFilter>
        var note: String
        var rewrite: Bool
    }

    /// Stable key first; the old key only when the stable one was never
    /// written. A value that is not a string (poisoned) reads as no filters
    /// and is rewritten. Never throws, never crashes.
    nonisolated static func restore(from defaults: UserDefaults) -> Restored {
        if let stored = defaults.object(forKey: key) {
            guard let raw = stored as? String else {
                return Restored(filters: [], note: " (the stored setting was unreadable and was reset)", rewrite: true)
            }
            return decode(tokens: raw.components(separatedBy: separator), known: { CatalogViewFilter(rawValue: $0) },
                          removed: [], origin: "")
        }
        guard let old = defaults.object(forKey: legacyKey) else {
            return Restored(filters: [], note: "", rewrite: false)
        }
        guard let raw = old as? String else {
            return Restored(filters: [], note: " (the old setting was unreadable and was reset)", rewrite: true)
        }
        var restored = decode(tokens: raw.components(separatedBy: legacySeparator), known: { legacyLabels[$0] },
                              removed: removedLegacyLabels, origin: " (migrated from the old setting")
        restored.rewrite = true
        return restored
    }

    private nonisolated static func decode(tokens: [String], known: (String) -> CatalogViewFilter?,
                                           removed: Set<String>, origin: String) -> Restored {
        var filters: Set<CatalogViewFilter> = []
        var gone: [String] = []
        var unknown: [String] = []
        for token in tokens.map({ $0.trimmingCharacters(in: .whitespaces) }) where !token.isEmpty {
            if let filter = known(token) { filters.insert(filter) }
            else if removed.contains(token) { gone.append(token) }
            else { unknown.append(String(token.prefix(60))) }
        }
        let legalSet = legal(filters)
        var parts: [String] = []
        if !gone.isEmpty { parts.append("dropped, no longer in the menu: " + gone.joined(separator: ", ")) }
        if !unknown.isEmpty { parts.append("dropped, not known to this build: " + unknown.joined(separator: ", ")) }
        if legalSet != filters { parts.append("dropped Has Master Copy: it cannot be on with Not Yet Archived") }
        let changed = !parts.isEmpty
        var note = origin
        if !parts.isEmpty { note += (origin.isEmpty ? " (" : "; ") + parts.joined(separator: "; ") }
        if !note.isEmpty { note += ")" }
        return Restored(filters: legalSet, note: note, rewrite: changed)
    }
}

// MARK: - The door for views that may live outside the Catalog's window

private struct CatalogShowFilterStoreKey: EnvironmentKey {
    static let defaultValue: CatalogShowFilterStore? = nil
}

extension EnvironmentValues {
    /// A plain reference to the store (no subscription) for a view that only
    /// WRITES — the Steward's "Show one per footage". nil outside the main
    /// window: the caller refuses out loud instead of writing the setting itself.
    var catalogShowFilterReference: CatalogShowFilterStore? {
        get { self[CatalogShowFilterStoreKey.self] }
        set { self[CatalogShowFilterStoreKey.self] = newValue }
    }
}
