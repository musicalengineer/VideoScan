// UserPlaceRoster.swift
// The inspector's Place picker: Rick's OWN prior places, distinct
// canonical `userPlace` values across the catalog, sorted by frequency
// then name (Rick 2026-09-12). Seeded with nothing — the list grows from
// use. Free text is always allowed beside it.
//
// COST. Two passes, same shape as CatalogSizeTotals: `project` on the
// main actor (one optional-String read per record), then `compute` off
// the main actor (a dictionary count + one sort). Scheduled by
// VideoScanModel.refreshDossierCountsNow — the already-debounced
// catalog-change pass — so it is NEVER computed in a view body.
// Budgeted at 100k records by UserPlaceTests.
//
// MEMORY. One String per PLACED record (copy-on-write shares of the
// record's own storage, not copies) — a few KB today; ~1.6 MB worst case
// if all 100k records were placed. The count dictionary holds one entry
// per distinct place (dozens) and is freed on return.
//
// (Swift `struct` with static funcs ≈ a C++ POD plus a namespace of free
// functions; `nonisolated` = "no actor/thread affinity — pure".)

import Foundation

struct UserPlaceRoster: Equatable, Sendable {

    /// One picker row. `id` is the place itself — canonical strings are
    /// unique by construction.
    struct Entry: Equatable, Sendable, Identifiable {
        let place: String
        let count: Int
        var id: String { place }
    }

    /// Most-used first; ties broken by name (case-insensitive), so the
    /// menu is stable between refreshes.
    var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// The places alone, in roster order — what the picker shows.
    var places: [String] { entries.map(\.place) }

    /// MAIN-ACTOR pass: pull the placed records' canonical strings. No
    /// filtering by purge / set-aside state on purpose — a place Rick
    /// typed on any record is a place Rick uses.
    @MainActor
    static func project(_ records: [VideoRecord]) -> [String] {
        var out: [String] = []
        for rec in records {
            if let p = rec.userPlace, !p.isEmpty { out.append(p) }
        }
        return out
    }

    /// OFF-MAIN pass: count and order. Pure.
    nonisolated static func compute(_ places: [String]) -> UserPlaceRoster {
        var counts: [String: Int] = [:]
        for p in places { counts[p, default: 0] += 1 }
        let entries = counts.map { Entry(place: $0.key, count: $0.value) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                let byName = a.place.localizedCaseInsensitiveCompare(b.place)
                if byName != .orderedSame { return byName == .orderedAscending }
                return a.place < b.place
            }
        return UserPlaceRoster(entries: entries)
    }

    /// Both halves in one call — for tests and callers already off-main.
    @MainActor
    static func compute(records: [VideoRecord]) -> UserPlaceRoster {
        compute(project(records))
    }
}
