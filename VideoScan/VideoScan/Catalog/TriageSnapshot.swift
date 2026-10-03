// TriageSnapshot.swift
// What the Triage tab draws, worked out OFF the main thread (2026-10-03).
//
// Why: every collection the Triage tab showed — the table's rows, the
// sidebar's nine counts, the progress bar, the status bar — was a computed
// property that walked `model.records` INSIDE the view body, and the body
// re-ran on every model publish. During a Delete Duplicates run (the model
// publishes per file settled, the job centre per progress tick) a 6-second
// sample put 85% of the main thread inside `TriageView.body.getter`, and
// the Archive Angel's main-actor slices went from ~1 s to ~150 s a pass.
//
// The rule (CLAUDE.md): NO O(records) work in view bodies. Pattern =
// VolumeStatusCache / AnalyzeCoverage / Steward:
//
//   project   one main-actor pass over `records` → Sendable `TriageRow`s
//   build     counts + filter + search + sort in a detached task
//   publish   through `TriageSnapshot`, only when the result differs
//
// The view observes `TriageSnapshot` and NOT the model, so a publish that
// has nothing to do with Triage no longer re-runs its body at all.
//
// (For Rick: `Sendable` ≈ "safe to hand to another thread" — value types
// with no shared mutable state. `KeyPathComparator` ≈ a sort functor built
// from a pointer-to-member.)

import Foundation
import SwiftUI
import Combine
import VideoScanCore

// MARK: - One row

/// The light, immutable copy of a record the Triage table needs. Strings
/// share storage with the record's own (copy-on-write), so a row is ~200
/// bytes of headers, not a copy of the text.
struct TriageRow: Identifiable, Sendable, Equatable {
    let id: UUID
    var filename: String
    var directory: String
    var notes: String
    var volumeName: String
    var fullPath: String
    /// Sort key for the Type column (the stored raw value)…
    var streamTypeRaw: String
    /// …and what the column shows (`streamType.rawValue`: an unknown raw
    /// value reads as the probe-failed label, exactly as before).
    var streamTypeLabel: String
    var duration: String
    var durationSeconds: Double
    var size: String
    var sizeBytes: Int64
    var starRating: Int
    var junkScore: Int
    var junkReasons: [String]
    var mediaDisposition: MediaDisposition
    var lifecycleStage: LifecycleStage
    var workspaceActive: Bool
    /// `cleanupRecipeID != nil` — the Cleaned up filter's fact.
    var cleaned: Bool
    /// `VideoRecord.filenameColor`, read once at projection.
    var filenameColor: Color

    @MainActor
    init(record r: VideoRecord) {
        id = r.id
        filename = r.filename
        directory = r.directory
        notes = r.notes
        volumeName = r.volumeName
        fullPath = r.fullPath
        streamTypeRaw = r.streamTypeRaw
        streamTypeLabel = r.streamType.rawValue
        duration = r.duration
        durationSeconds = r.durationSeconds
        size = r.size
        sizeBytes = r.sizeBytes
        starRating = r.starRating
        junkScore = r.junkScore
        junkReasons = r.junkReasons
        mediaDisposition = r.mediaDisposition
        lifecycleStage = r.lifecycleStage
        workspaceActive = r.workspaceActive
        cleaned = r.cleanupRecipeID != nil
        filenameColor = r.filenameColor
    }
}

extension TriageFilter {
    /// The same predicate as `matches(_: VideoRecord)`, over a row — both
    /// route through `matches(disposition:workspaceActive:lifecycleStage:cleaned:)`.
    func matches(_ row: TriageRow) -> Bool {
        matches(disposition: row.mediaDisposition, workspaceActive: row.workspaceActive,
                lifecycleStage: row.lifecycleStage, cleaned: row.cleaned)
    }
}

// MARK: - What the person asked to see

/// The view state that decides the table's rows and their order. Counts do
/// not depend on it.
struct TriageQuery: Equatable, Sendable {
    var filter: TriageFilter = .all
    var search: String = ""
    var onlineOnly: Bool = false
    /// The steward pane's "Review these below" — empty = no narrowing.
    var reviewIDs: Set<UUID> = []
    var sortOrder: [KeyPathComparator<TriageRow>] = TriageQuery.defaultSort

    static let defaultSort: [KeyPathComparator<TriageRow>] = [KeyPathComparator(\TriageRow.filename)]
}

// MARK: - The projection and the result

/// One main-actor pass over the catalog: every record in Triage's scope
/// (active, not archived), in catalog order, plus the one number that is
/// counted outside that scope.
struct TriageProjection: Sendable {
    var rows: [TriageRow] = []
    /// Tagged Confirmed Junk, not purged, already archived — the status
    /// bar's "N archived (hidden)".
    var archivedConfirmedJunk: Int = 0
}

struct TriageSnapshotValue: Sendable, Equatable {
    /// False until the first build lands (and again after the tab leaves
    /// the screen): the table area stays blank rather than claiming
    /// "Nothing to triage".
    var isReady = false
    /// The query `rows` was built for.
    var query = TriageQuery()
    /// Sidebar badges: every filter's count over the Triage scope.
    var counts: [TriageFilter: Int] = [:]
    /// Records in the Triage scope ("N of M triaged", "Analyze All (M)").
    var triageTotal = 0
    /// …of which the disposition is anything but Unreviewed.
    var reviewed = 0
    var archivedConfirmedJunk = 0
    /// The table: filtered, searched, sorted.
    var rows: [TriageRow] = []
    /// id → offset in `rows`, for O(1) row lookup from the context menu.
    private(set) var index: [UUID: Int] = [:]

    init() {}

    init(query: TriageQuery, counts: [TriageFilter: Int], triageTotal: Int, reviewed: Int,
         archivedConfirmedJunk: Int, rows: [TriageRow]) {
        self.isReady = true
        self.query = query
        self.counts = counts
        self.triageTotal = triageTotal
        self.reviewed = reviewed
        self.archivedConfirmedJunk = archivedConfirmedJunk
        self.rows = rows
        var index: [UUID: Int] = [:]
        index.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() { index[row.id] = offset }
        self.index = index
    }

    func count(_ filter: TriageFilter) -> Int { counts[filter] ?? 0 }

    func row(_ id: UUID) -> TriageRow? { index[id].map { rows[$0] } }

    /// `index` is derived from `rows`, so it is left out.
    static func == (a: TriageSnapshotValue, b: TriageSnapshotValue) -> Bool {
        a.isReady == b.isReady && a.triageTotal == b.triageTotal && a.reviewed == b.reviewed
            && a.archivedConfirmedJunk == b.archivedConfirmedJunk && a.counts == b.counts
            && a.query == b.query && a.rows == b.rows
    }
}

// MARK: - The builder (pure)

enum TriageSnapshotBuilder {

    /// Triage's scope: purged / set-aside / superseded records are out (the
    /// ONE visibility predicate, `pfActiveRecords`), and so is anything
    /// already archived.
    static func triageScope(_ records: [VideoRecord]) -> [VideoRecord] {
        pfActiveRecords(records).filter { $0.lifecycleStage != .archived }
    }

    /// The main-actor step: O(records), plain property reads, no I/O.
    @MainActor
    static func project(_ records: [VideoRecord]) -> TriageProjection {
        var archivedJunk = 0
        for r in records where r.mediaDisposition == .confirmedJunk && r.purgedAt == nil && r.lifecycleStage == .archived {
            archivedJunk += 1
        }
        let scope = triageScope(records)
        var rows: [TriageRow] = []
        rows.reserveCapacity(scope.count)
        for r in scope { rows.append(TriageRow(record: r)) }
        return TriageProjection(rows: rows, archivedConfirmedJunk: archivedJunk)
    }

    /// The key one reachability answer is shared under: "/Volumes/X" for a
    /// path on an external volume (every file on it has the same answer —
    /// VolumeReachability keys its own cache the same way); nil for an
    /// internal path, which is asked per file as before.
    static func volumeRootKey(_ path: String) -> String? {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        guard !rest.isEmpty, rest.first != "/" else { return nil }
        if let slash = rest.firstIndex(of: "/") {
            return String(path[path.startIndex..<slash])
        }
        return path
    }

    /// Everything the tab shows, from the projection. Pure: the only
    /// outside question is `reachable`, asked once per volume root per
    /// build (and only when "Online volumes only" is on). Returns nil when
    /// `isCancelled` turns true between steps.
    static func build(_ projection: TriageProjection,
                      query: TriageQuery,
                      reachable: (String) -> Bool,
                      isCancelled: () -> Bool = { false }) -> TriageSnapshotValue? {
        let all = projection.rows
        let filters = TriageFilter.allCases

        // Sidebar counts + progress: one pass, an int per filter.
        var tallies = [Int](repeating: 0, count: filters.count)
        var reviewed = 0
        for row in all {
            for (i, filter) in filters.enumerated() where filter.matches(row) { tallies[i] += 1 }
            if row.mediaDisposition != .unreviewed { reviewed += 1 }
        }
        var counts: [TriageFilter: Int] = [:]
        for (i, filter) in filters.enumerated() { counts[filter] = tallies[i] }
        if isCancelled() { return nil }

        // The table's rows: filter → steward narrowing → online → search.
        var rows = query.filter == .all ? all : all.filter { query.filter.matches($0) }
        if !query.reviewIDs.isEmpty {
            rows = rows.filter { query.reviewIDs.contains($0.id) }
        }
        if query.onlineOnly {
            var byRoot: [String: Bool] = [:]
            rows = rows.filter { row in
                guard let root = volumeRootKey(row.fullPath) else { return reachable(row.fullPath) }
                if let known = byRoot[root] { return known }
                let answer = reachable(row.fullPath)
                byRoot[root] = answer
                return answer
            }
        }
        if !query.search.isEmpty {
            let q = query.search.lowercased()
            rows = rows.filter {
                $0.filename.lowercased().contains(q) ||
                $0.directory.lowercased().contains(q) ||
                $0.notes.lowercased().contains(q) ||
                $0.volumeName.lowercased().contains(q)
            }
        }
        if isCancelled() { return nil }

        rows = rows.sorted(using: query.sortOrder)
        if isCancelled() { return nil }

        return TriageSnapshotValue(query: query, counts: counts, triageTotal: all.count, reviewed: reviewed,
                                   archivedConfirmedJunk: projection.archivedConfirmedJunk, rows: rows)
    }
}

// MARK: - The observed object

/// The Triage tab's ONLY observed dependency. Publishing an unchanged
/// value is a no-op (zero invalidation).
@MainActor
final class TriageSnapshot: ObservableObject {
    @Published private(set) var value = TriageSnapshotValue()
    /// Bumped when a drive comes or goes, so the offline italics repaint.
    @Published private(set) var reachabilityEpoch: UInt64 = 0
    /// Test hook: how many builds actually landed.
    private(set) var publishCount = 0

    /// `knownDifferent`: the build task already compared against the value
    /// it was started from, off the main thread — don't compare 100k rows
    /// again here.
    func publish(_ new: TriageSnapshotValue, knownDifferent: Bool = false) {
        guard knownDifferent || new != value else { return }
        publishCount += 1
        value = new
    }

    func noteReachabilityChanged() {
        reachabilityEpoch &+= 1
    }

    /// The tab left the screen: drop the rows.
    func reset() {
        guard value.isReady || !value.rows.isEmpty else { return }
        value = TriageSnapshotValue()
    }
}
