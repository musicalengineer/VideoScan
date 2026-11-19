// CatalogRows.swift
// Which records the Catalog's files table lists — ONE pure function,
// `CatalogRows.rows(records, state)`, that `CatalogContent.computeFiltered`
// calls (2026-11-17; the steps themselves are unchanged from the function
// that lived in CatalogHelpers.swift, in the same order).
//
// WHY PURE. Row membership decides what ⌘⌫ and Promote can reach and what
// Rick believes is in the catalog; it was only testable by building a SwiftUI
// view. Everything it needs comes in through `State`: plain values, plus the
// four things only the model knows (the search index, drive reachability, the
// archive index) as closures — `Engines`. (≈ a C++ free function taking a
// const struct of options and a struct of std::function callbacks.)
//
// THE HELD ROW (Rick 2026-11-17: "a row vanished"). An edit can make a listed
// row stop matching a Show filter (date it under Needs a Date; promote it under
// Not Yet Archived). The row must not vanish at some later, unrelated refresh.
// Rule: a row that is SELECTED and was LISTED stays listed — marked "no longer
// matches" — until the selection moves off it; then it leaves. `State.held` is
// that set (the caller passes the visible selection after an edit, and nothing
// after Rick changes a filter, a search or a scope himself: then Finder's rule
// applies and a hidden row leaves and is deselected). Only the Show filters
// are forgiven: a held row that was trashed, set aside, superseded, or that
// falls outside the search, the person, the volumes or the connected drives
// leaves at once. So every listed row is still one the user can see, and
// ⌘⌫ / Promote never reach a row that is not on screen.
//
// COST. O(records) per call, a handful of passes, each a pointer filter;
// called from event handlers only, never a view body. The held merge is one
// more pass and runs only when a held row stopped matching. Worst-case memory:
// a few arrays of object references the size of the catalog (8 B per row,
// ~0.8 MB each at 100k), freed on return, and the result the table keeps.

import Combine
import Foundation
import VideoScanCore

enum CatalogRows {

    /// What only the model can answer. The defaults make `State()` usable in
    /// a test with no model: a filename search, every drive connected,
    /// nothing archived.
    struct Engines {
        /// The search index over the rows that reached the search step.
        var search: (_ rows: [VideoRecord], _ query: String) -> [VideoRecord] = { rows, query in
            rows.filter { $0.filename.localizedCaseInsensitiveContains(query) }
        }
        /// Is this path on a mounted volume (VolumeReachability)?
        var isReachable: (String) -> Bool = { _ in true }
        /// VideoScanModel.pfNotYetArchived / isPossiblyArchivedSampled.
        var notYetArchived: (VideoRecord) -> Bool = { _ in true }
        var possiblyArchivedSampled: (VideoRecord) -> Bool = { _ in false }
    }

    /// Everything that decides the rows, as values.
    struct State {
        /// A focus set ("Show in Catalog", an A/V pair): when non-empty these
        /// records are the rows and every other field is ignored.
        var focusIDs: Set<UUID> = []
        /// Reveals of hidden rows. No surface sets these since 2026-11-17 (the
        /// Show ▸ hidden-records panel was removed): always false in the app.
        /// Kept so the three hide filters stay exercised through this one
        /// function, and a reveal can come back as one line if Rick asks.
        var showRemoved = false
        var showSetAside = false
        var showSuperseded = false
        var searchText = ""
        var person: CatalogPerson?
        /// The Volumes-pane selection's path prefixes; empty = every volume.
        var volumePrefixes: [String] = []
        var showPairsOnly = false
        var sortOrder: [KeyPathComparator<VideoRecord>] = []
        var showDisconnectedMedia = false
        /// The Show ▸ filters that are on (CatalogShowFilterStore.active).
        var filters: Set<CatalogViewFilter> = []
        /// Rows to keep listed although a Show filter no longer matches them
        /// (see THE HELD ROW above). Empty = no forgiveness.
        var held: Set<UUID> = []
        var engines = Engines()
    }

    struct Result {
        var rows: [VideoRecord] = []
        /// The catalog's rows that are not removed (trashed) — the Showing
        /// box's "of N". Counted in the purge step this pass runs anyway.
        var catalogCount = 0
        /// The Showing box's count: the rows listed, of the catalog — from
        /// this one pass, so it is the table's row count in the same update.
        var shownCount: CatalogShowingSummary.ShownCount {
            CatalogShowingSummary.ShownCount(shown: rows.count, total: catalogCount)
        }
        /// The toolbar's search badge: hits before the person, volume and
        /// Show filters (connected drives only unless disconnected media shows).
        var searchHitCount = 0
        /// Search hits Not Yet Archived hid, and how many of those are hidden
        /// only by a sampled match — the "already in the Archive" banner.
        var archivedSearchHitIDs: [UUID] = []
        var archivedSearchSampledHitCount = 0
        /// Held rows that are listed but no longer match the Show filters.
        var noLongerMatching: Set<UUID> = []
    }

    static func rows(_ records: [VideoRecord], _ state: State) -> Result {
        // An explicit-IDs ask always wins, including over Show Removed: the
        // user asked for those specific records.
        if !state.focusIDs.isEmpty {
            var focused = Result(rows: records.filter { state.focusIDs.contains($0.id) })
            focused.catalogCount = records.count { !$0.isPurged }
            return focused
        }
        var result = Result()
        let scoped = scope(records, state, &result)
        let filtered = applyShowFilters(scoped, state, &result)
        result.rows = keepingHeld(filtered, scoped: scoped, state.held, &result)
        return result
    }

    // MARK: Steps

    /// Everything that is NOT a Show filter, in the table's order: purge →
    /// set-aside → superseded → search (the badge is counted here) →
    /// person → volumes → pairs → connected drives. (No media-kind step since
    /// 2026-11-17: every kind is in scope; Audio Only is a Show filter.)
    private static func scope(_ records: [VideoRecord], _ state: State, _ result: inout Result) -> [VideoRecord] {
        var out = pfApplyPurgeFilter(records, showRemoved: state.showRemoved)
        // The box's "of N": the purge step's survivors ARE the not-removed
        // rows — free. Only the (app-unused) reveal needs its own count.
        result.catalogCount = state.showRemoved ? records.count { !$0.isPurged } : out.count
        out = pfApplySetAsideFilter(out, showSetAside: state.showSetAside)
        out = pfApplySupersededFilter(out, showSuperseded: state.showSuperseded)
        if !state.searchText.isEmpty {
            // ONE scan per settled query (GH #123 PR B): the hits over this
            // base ARE the badge; the later steps narrow the survivors.
            out = state.engines.search(out, state.searchText)
            result.searchHitCount = state.showDisconnectedMedia
                ? out.count
                : out.filter { state.engines.isReachable($0.fullPath) }.count
        }
        out = CatalogPersonFilter.apply(out, person: state.person)
        if !state.volumePrefixes.isEmpty {
            // CURRENT physical location only — see pfRecordOnSelectedVolume.
            out = out.filter { pfRecordOnSelectedVolume($0, prefixes: state.volumePrefixes) }
        }
        if state.showPairsOnly { out = pairsOnly(out, sortOrder: state.sortOrder) }
        if !state.showDisconnectedMedia {
            out = out.filter { state.engines.isReachable($0.fullPath) }
        }
        return out
    }

    /// Show Pairs Only: the records with a correlated partner, flattened
    /// video-then-its-audio in the table's sort order.
    private static func pairsOnly(_ rows: [VideoRecord], sortOrder: [KeyPathComparator<VideoRecord>]) -> [VideoRecord] {
        let pairedIDs = Set(rows.compactMap { $0.pairedWith != nil ? $0.id : nil })
        let partnerIDs = Set(rows.compactMap { $0.pairedWith?.id })
        let allPairIDs = pairedIDs.union(partnerIDs)
        var videos = rows.filter { allPairIDs.contains($0.id) && $0.streamType == .videoOnly && $0.pairedWith != nil }
        videos.sort(using: sortOrder)
        var out: [VideoRecord] = []
        out.reserveCapacity(videos.count * 2)
        for video in videos {
            out.append(video)
            if let audio = video.pairedWith { out.append(audio) }
        }
        return out
    }

    /// The Show ▸ filters (additive — each one narrows further): the pure
    /// per-record ones from the enum's own table (Audio Only, Videos with
    /// Sound, Videos Missing Sound, Needs a Date), then Not Yet Archived, then Hide Other Versions
    /// LAST so it picks among the rows the others left.
    private static func applyShowFilters(_ rows: [VideoRecord], _ state: State, _ result: inout Result) -> [VideoRecord] {
        var out = rows
        for filter in CatalogViewFilter.ordered(state.filters) {
            if let keep = filter.recordPredicate { out = out.filter(keep) }
        }
        if state.filters.contains(.notYetArchived) {
            if state.searchText.isEmpty {
                out = out.filter(state.engines.notYetArchived)
            } else {
                // Remember what the to-do view hid: a search for an archived
                // file must never dead-end at "No matches" (Rick 2026-08-22).
                let split = CatalogShowingSummary.splitArchivedHits(out) { !state.engines.notYetArchived($0) }
                out = split.shown
                result.archivedSearchHitIDs = split.archived.map(\.id)
                result.archivedSearchSampledHitCount = split.archived.filter(state.engines.possiblyArchivedSampled).count
            }
        }
        if state.filters.contains(.onePerFootage) {
            // Hide Other Versions: one per footage group, then one of any
            // byte-identical set the footage run has not grouped.
            out = CatalogOneOfIdentical.filter(FootageOnePerGroup.filter(out))
        }
        return out
    }

    /// Put back the held rows the Show filters dropped — only those still in
    /// `scoped` (so a trashed or out-of-scope row is never kept), at the place
    /// they had. `filtered` is `scoped` minus rows, in the same order, so one
    /// walk of `scoped` merges them. Nothing held, or every held row still
    /// matching → `filtered` itself, no pass.
    private static func keepingHeld(_ filtered: [VideoRecord], scoped: [VideoRecord], _ held: Set<UUID>,
                                    _ result: inout Result) -> [VideoRecord] {
        guard !held.isEmpty else { return filtered }
        var missing = held
        for row in filtered where missing.contains(row.id) {
            missing.remove(row.id)
            if missing.isEmpty { return filtered }
        }
        var merged: [VideoRecord] = []
        merged.reserveCapacity(filtered.count + missing.count)
        var next = 0
        var kept: Set<UUID> = []
        for row in scoped {
            if next < filtered.count, filtered[next] === row {
                merged.append(row)
                next += 1
            } else if missing.contains(row.id), kept.insert(row.id).inserted {
                merged.append(row)
            }
        }
        // Defensive: were `filtered` ever not a subsequence of `scoped`, keep
        // every matching row and add the held ones after them.
        if next < filtered.count {
            merged = filtered + scoped.filter { kept.contains($0.id) }
        }
        result.noLongerMatching = kept
        if !kept.isEmpty, !result.archivedSearchHitIDs.isEmpty {
            // A held row is on screen: the banner must not count it as hidden.
            result.archivedSearchHitIDs.removeAll(where: kept.contains)
        }
        return merged
    }

    // MARK: Words

    /// The held row's tooltip and VoiceOver line.
    static let noLongerMatchingHelp =
        "No longer matches the Show filters. It stays listed while it is selected, and leaves when you select something else."
}

// MARK: - A record edit reaches the table

/// Ticks `revision` shortly after the last `.videoScanCatalogMutated` post (an
/// inspector save, a job's batch of in-place writes), so the files table
/// re-applies its filters THEN — not at the next unrelated refresh. A burst of
/// posts is one tick (the 0.25 s quiet period), so a job that posts per record
/// costs one O(records) pass, not one per post. One per Catalog pane, held in
/// @State (CatalogTableState); the pane reads `$revision` in `.onReceive`.
/// (≈ a C++ debounce timer owned by the view that fires one "dirty" signal.)
@MainActor
final class CatalogEditClock: ObservableObject {
    @Published private(set) var revision: UInt64 = 0
    private var pending: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    static let quiet: Duration = .milliseconds(250)

    /// Swift 6: nonisolated so `@State var editClock = CatalogEditClock()`
    /// (CatalogTableState's memberwise init is not main-actor isolated) can
    /// build one. Nothing is read or subscribed here; `start()` does that.
    nonisolated init() {}

    /// Begin listening (idempotent). Called when the pane appears.
    func start(center: NotificationCenter = .default) {
        guard observer == nil else { return }
        observer = center.addObserver(forName: .videoScanCatalogMutated, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteEdit() }
        }
    }

    /// Stop listening and drop a pending tick. Called when the pane leaves.
    func stop(center: NotificationCenter = .default) {
        if let observer { center.removeObserver(observer) }
        observer = nil
        pending?.cancel()
        pending = nil
    }

    /// A record changed: tick once the posts go quiet.
    func noteEdit(quiet: Duration = CatalogEditClock.quiet) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: quiet)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.revision &+= 1
        }
    }
}

// MARK: - Hide Other Versions: byte-identical files the footage run missed

/// One of each set of byte-identical rows (Rick 2026-11-17: "a clear view of
/// unique media"). Footage membership is what the last Find Similar Footage
/// run WROTE: a file scanned or hashed since then has none, so two files with
/// the same whole-file SHA-256 can both be ungrouped, or sit in different
/// groups — and both would be listed under Hide Other Versions. This pass,
/// run after the per-group one, keeps one row per stored digest.
///
/// WHICH ONE: the existing rank rule — the lowest footage rank among them
/// (0 = the likely original); a row with no footage rank ranks after every
/// ranked one; ties keep the first in the table's order.
///
/// EVIDENCE: `VideoScanModel.storedFullDigest` — a recorded whole-file
/// SHA-256 whose byte count still equals the row's size; a sampled signature
/// never counts. It only HIDES a row from one view; nothing is deleted, and
/// turning the filter off lists every row again.
///
/// COST: one pass and one dictionary — O(rows), only while the filter is on.
/// Worst-case memory: one 64-character key per row with a digest (~10 MB at
/// 100k rows), freed on return. Rows without a digest are always kept.
enum CatalogOneOfIdentical {
    static func filter(_ rows: [VideoRecord]) -> [VideoRecord] {
        var best: [String: (rank: Int, id: UUID)] = [:]
        var repeated = false
        for row in rows {
            guard let digest = VideoScanModel.storedFullDigest(row)?.lowercased() else { continue }
            let rank = row.footage?.rank ?? Int.max
            if let current = best[digest] {
                repeated = true
                if current.rank <= rank { continue }
            }
            best[digest] = (rank, row.id)
        }
        guard repeated else { return rows }
        return rows.filter { row in
            guard let digest = VideoScanModel.storedFullDigest(row)?.lowercased() else { return true }
            return best[digest]?.id == row.id
        }
    }
}
