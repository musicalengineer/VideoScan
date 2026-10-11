// TriageSnapshotTests.swift
// The Triage tab's off-main snapshot (2026-10-03, perf/triage-view-snapshot).
//
// Evidence that started it: a 6-second sample during Delete Duplicates put
// 85% of the main thread inside `TriageView.body.getter` — every computed
// collection walked `model.records` in the view body, on every publish.
//
// Dimensions (feature-test checklist):
//   Logic     — the snapshot's counts, rows and ORDER equal the old view's
//               computed properties (kept below, verbatim, as a test-only
//               reference) for every TriageFilter × search × online-only ×
//               steward narrowing, and for every sortable column both ways.
//   Scale     — 100k records: projection and build, explicit budgets.
//   Isolation — reachability is a seam (`reachable:` / the model's
//               `triageReachability`); nothing here depends on what is
//               plugged in. No media is opened.
//   Sensor    — N mutations inside the debounce window → ONE publish and
//               ONE projection; nothing is built while the tab is off
//               screen; and the view file itself is pinned (no records
//               walk, no model observation) in TriageViewSensorTests.
//   Numbers   — a micro-benchmark prints old-body-pass vs snapshot-read
//               milliseconds at 10k and 100k (configuration in the line).

import Foundation
import SwiftUI
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - The old view's computations (reference, test-only)

/// TriageView's computed properties exactly as they stood before
/// 2026-10-03 (TriageView.swift @ 32718e41), lifted out of the view so the
/// snapshot can be checked against them. `reachable` stands in for
/// `VolumeReachability.isReachable(path:)`.
@MainActor
enum TriageOldViewReference {

    static func triageRecords(_ records: [VideoRecord]) -> [VideoRecord] {
        pfActiveRecords(records).filter { $0.lifecycleStage != .archived }
    }

    static func filteredRecords(_ records: [VideoRecord], selectedFilter: TriageFilter, searchText: String,
                                showOnlineOnly: Bool, stewardReviewIDs: Set<UUID>,
                                reachable: (String) -> Bool) -> [VideoRecord] {
        let triage = triageRecords(records)
        let filtered: [VideoRecord] = selectedFilter == .all
            ? triage
            : triage.filter { selectedFilter.matches($0) }
        let base: [VideoRecord] = stewardReviewIDs.isEmpty
            ? filtered
            : filtered.filter { stewardReviewIDs.contains($0.id) }
        let afterOnline = showOnlineOnly
            ? base.filter { reachable($0.fullPath) }
            : base
        if searchText.isEmpty { return afterOnline }
        let q = searchText.lowercased()
        return afterOnline.filter {
            $0.filename.lowercased().contains(q) ||
            $0.directory.lowercased().contains(q) ||
            $0.notes.lowercased().contains(q) ||
            $0.volumeName.lowercased().contains(q)
        }
    }

    static func countFor(_ filter: TriageFilter, _ records: [VideoRecord]) -> Int {
        filter == .all
            ? triageRecords(records).count
            : triageRecords(records).filter { filter.matches($0) }.count
    }

    static func archivedConfirmedJunkCount(_ records: [VideoRecord]) -> Int {
        records.filter {
            $0.mediaDisposition == .confirmedJunk
                && $0.purgedAt == nil
                && $0.lifecycleStage == .archived
        }.count
    }

    static func confirmedJunk(_ records: [VideoRecord]) -> [VideoRecord] {
        triageRecords(records).filter { $0.mediaDisposition == .confirmedJunk }
    }

    static func reviewed(_ records: [VideoRecord]) -> Int {
        triageRecords(records).filter { $0.mediaDisposition != .unreviewed }.count
    }

    /// ONE evaluation of the old `body`, call for call: the sidebar's nine
    /// badges and progress, the toolbar's Delete Junk and Analyze counts,
    /// the sorted table rows and the status bar. Returns a checksum so the
    /// optimizer cannot drop the work.
    static func bodyPass(_ records: [VideoRecord], selectedFilter: TriageFilter, searchText: String,
                         showOnlineOnly: Bool, stewardReviewIDs: Set<UUID>,
                         sortOrder: [KeyPathComparator<VideoRecord>],
                         reachable: (String) -> Bool) -> Int {
        var sum = 0
        for filter in TriageFilter.allCases { sum &+= countFor(filter, records) }          // sidebar badges
        sum &+= triageRecords(records).count &+ reviewed(records)                          // triageProgress
        if !confirmedJunk(records).isEmpty { sum &+= confirmedJunk(records).count }        // Delete Junk
        sum &+= triageRecords(records).count                                               // "Analyze All (N)"
        sum &+= triageRecords(records).isEmpty ? 0 : 1                                     // .disabled(…)
        let rows = filteredRecords(records, selectedFilter: selectedFilter, searchText: searchText,
                                   showOnlineOnly: showOnlineOnly, stewardReviewIDs: stewardReviewIDs,
                                   reachable: reachable).sorted(using: sortOrder)          // the table
        sum &+= rows.count
        sum &+= filteredRecords(records, selectedFilter: selectedFilter, searchText: searchText,
                                showOnlineOnly: showOnlineOnly, stewardReviewIDs: stewardReviewIDs,
                                reachable: reachable).count                                // status bar
        if selectedFilter == .confirmedJunk { sum &+= archivedConfirmedJunkCount(records) }
        return sum
    }
}

// MARK: - Fixture

@MainActor
enum TriageFixture {

    static let roots = ["/Volumes/Alpha", "/Volumes/Beta", "/Volumes/Gamma Ray", "/Users/test/Movies"]

    /// Beta is unplugged; on the internal disk, files ending in "3.mov"
    /// are gone (the real check is per file there).
    static let reachable: @Sendable (String) -> Bool = { path in
        if path.hasPrefix("/Volumes/Beta/") || path == "/Volumes/Beta" { return false }
        if path.hasPrefix("/Users/") { return !path.hasSuffix("3.mov") }
        return true
    }

    /// Deterministic records covering every disposition, lifecycle stage,
    /// workflow flag, hidden state, four roots, duplicate names (sort
    /// ties), mixed case and digit runs (natural vs plain ordering).
    static func records(_ count: Int) -> [VideoRecord] {
        let dispositions: [MediaDisposition] = [.unreviewed, .important, .suspectedJunk, .confirmedJunk, .recoverable]
        let streams = [StreamType.videoAndAudio.rawValue, StreamType.videoOnly.rawValue,
                       StreamType.audioOnly.rawValue, StreamType.ffprobeFailed.rawValue]
        var out: [VideoRecord] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let r = VideoRecord()
            let dir = "\(roots[i % roots.count])/Folder\(i % 17)"
            if i % 11 == 0 {
                r.filename = "holiday \(i % 13).mp4"
            } else if i % 5 == 0 {
                r.filename = "Clip\(i).MOV"
            } else {
                r.filename = "clip\(i).mov"
            }
            r.directory = dir
            r.fullPath = dir + "/" + r.filename
            r.notes = i % 9 == 0 ? "Birthday at the lake" : ""
            r.streamTypeRaw = i % 23 == 0 ? "bogus" : streams[i % streams.count]
            r.durationSeconds = Double((i * 37) % 5_000)
            r.duration = r.durationSeconds == 0 ? "" : "\(Int(r.durationSeconds))s"
            r.sizeBytes = Int64((i * 7_919) % 100_000)
            r.size = "\(r.sizeBytes) B"
            r.junkScore = i % 10
            r.junkReasons = r.junkScore > 0 ? ["short", "dark"] : []
            r.starRating = i % 4
            r.mediaDisposition = dispositions[(i / 2) % dispositions.count]
            if i % 7 == 0 {
                r.lifecycleStage = .archived
            } else if i % 13 == 0 {
                r.lifecycleStage = .workbench
            } else if i % 3 == 0 {
                r.lifecycleStage = .reviewing
            }
            r.workspaceActive = i % 6 == 0
            if i % 8 == 0 { r.cleanupRecipeID = "vhs-quick-clean" }
            if i % 19 == 0 { r.purgedAt = Date(timeIntervalSince1970: 1) }
            if i % 29 == 0 { r.setAsideReason = "test" }
            if i % 31 == 0 { r.supersededByID = UUID() }
            out.append(r)
        }
        return out
    }

    /// Each sortable column as the Table produces it — the record-typed
    /// comparator the old view sorted with, and the row-typed one the
    /// snapshot sorts with. String columns clicked in the header use
    /// `.localizedStandard`; the initial order is plain `Comparable`.
    static func sortColumns(_ order: SortOrder) -> [(name: String, old: KeyPathComparator<VideoRecord>, new: KeyPathComparator<TriageRow>)] {
        [
            ("initial filename", KeyPathComparator(\VideoRecord.filename, order: order), KeyPathComparator(\TriageRow.filename, order: order)),
            ("Filename", KeyPathComparator(\VideoRecord.filename, comparator: .localizedStandard, order: order),
             KeyPathComparator(\TriageRow.filename, comparator: .localizedStandard, order: order)),
            ("Type", KeyPathComparator(\VideoRecord.streamTypeRaw, comparator: .localizedStandard, order: order),
             KeyPathComparator(\TriageRow.streamTypeRaw, comparator: .localizedStandard, order: order)),
            ("Duration", KeyPathComparator(\VideoRecord.durationSeconds, order: order), KeyPathComparator(\TriageRow.durationSeconds, order: order)),
            ("Size", KeyPathComparator(\VideoRecord.sizeBytes, order: order), KeyPathComparator(\TriageRow.sizeBytes, order: order)),
            ("Volume", KeyPathComparator(\VideoRecord.volumeName, comparator: .localizedStandard, order: order),
             KeyPathComparator(\TriageRow.volumeName, comparator: .localizedStandard, order: order)),
            ("Score", KeyPathComparator(\VideoRecord.junkScore, order: order), KeyPathComparator(\TriageRow.junkScore, order: order)),
        ]
    }
}

// MARK: - Logic: the snapshot equals the old computed properties

@Suite("Triage snapshot — equals the old view computations")
@MainActor
struct TriageSnapshotParityTests {

    private let records = TriageFixture.records(600)

    private func build(_ query: TriageQuery) throws -> TriageSnapshotValue {
        try #require(TriageSnapshotBuilder.build(TriageSnapshotBuilder.project(records), query: query,
                                                 reachable: TriageFixture.reachable))
    }

    @Test func theFixtureCoversEveryCase() {
        let scope = TriageOldViewReference.triageRecords(records)
        #expect(scope.count > 300 && scope.count < records.count, "hidden and archived records are left out")
        for filter in TriageFilter.allCases {
            #expect(TriageOldViewReference.countFor(filter, records) > 0, "\(filter) has no rows in the fixture")
        }
        #expect(TriageOldViewReference.archivedConfirmedJunkCount(records) > 0)
        #expect(Set(scope.map { TriageFixture.reachable($0.fullPath) }) == [true, false])
    }

    @Test func sidebarCountsProgressAndStatusBarNumbersMatch() throws {
        let value = try build(TriageQuery())
        #expect(value.isReady)
        for filter in TriageFilter.allCases {
            #expect(value.count(filter) == TriageOldViewReference.countFor(filter, records), "badge for \(filter)")
        }
        #expect(value.triageTotal == TriageOldViewReference.triageRecords(records).count)
        #expect(value.reviewed == TriageOldViewReference.reviewed(records))
        #expect(value.archivedConfirmedJunk == TriageOldViewReference.archivedConfirmedJunkCount(records))
        #expect(value.count(.confirmedJunk) == TriageOldViewReference.confirmedJunk(records).count, "the Delete Junk count")
    }

    /// Counts never depend on what the table is narrowed to.
    @Test func countsAreTheSameUnderAnyQuery() throws {
        let plain = try build(TriageQuery())
        let narrowed = try build(TriageQuery(filter: .important, search: "clip1", onlineOnly: true))
        #expect(narrowed.counts == plain.counts && narrowed.triageTotal == plain.triageTotal && narrowed.reviewed == plain.reviewed)
    }

    @Test func rowsMatchForEveryFilterSearchOnlineAndStewardNarrowing() throws {
        let scope = TriageOldViewReference.triageRecords(records)
        // A steward set: every third in-scope record plus ids that are not
        // in scope at all (an archived record, a stranger).
        var review = Set(scope.enumerated().filter { $0.offset % 3 == 0 }.map(\.element.id))
        review.insert(try #require(records.first { $0.lifecycleStage == .archived }).id)
        review.insert(UUID())
        let oldSort = [KeyPathComparator(\VideoRecord.filename)]
        var compared = 0
        for filter in TriageFilter.allCases {
            for search in ["", "clip1", "BIRTHDAY", "gamma", "folder3", "no such thing"] {
                for online in [false, true] {
                    for ids in [Set<UUID>(), review] {
                        let expected = TriageOldViewReference.filteredRecords(
                            records, selectedFilter: filter, searchText: search, showOnlineOnly: online,
                            stewardReviewIDs: ids, reachable: TriageFixture.reachable).sorted(using: oldSort)
                        let value = try build(TriageQuery(filter: filter, search: search, onlineOnly: online, reviewIDs: ids))
                        #expect(value.rows.map(\.id) == expected.map(\.id),
                                "\(filter) search=\(search) online=\(online) narrowed=\(!ids.isEmpty)")
                        compared += 1
                    }
                }
            }
        }
        #expect(compared == TriageFilter.allCases.count * 6 * 2 * 2)
    }

    @Test func orderMatchesForEverySortColumnBothWays() throws {
        for order in [SortOrder.forward, .reverse] {
            for column in TriageFixture.sortColumns(order) {
                for filter in [TriageFilter.all, .untriaged, .workspace] {
                    let expected = TriageOldViewReference.filteredRecords(
                        records, selectedFilter: filter, searchText: "", showOnlineOnly: false,
                        stewardReviewIDs: [], reachable: TriageFixture.reachable).sorted(using: [column.old])
                    let value = try build(TriageQuery(filter: filter, sortOrder: [column.new]))
                    #expect(value.rows.map(\.id) == expected.map(\.id), "\(column.name) \(order) on \(filter)")
                }
            }
        }
        // Two keys, as after clicking one header and then another.
        let old = [KeyPathComparator(\VideoRecord.junkScore, order: .reverse),
                   KeyPathComparator(\VideoRecord.filename, comparator: .localizedStandard)]
        let new = [KeyPathComparator(\TriageRow.junkScore, order: .reverse),
                   KeyPathComparator(\TriageRow.filename, comparator: .localizedStandard)]
        let expected = TriageOldViewReference.triageRecords(records).sorted(using: old)
        #expect(try build(TriageQuery(sortOrder: new)).rows.map(\.id) == expected.map(\.id))
    }

    /// What a cell shows is what the record says.
    @Test func everyRowCarriesWhatItsCellsShow() throws {
        let value = try build(TriageQuery())
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        #expect(value.rows.count == value.triageTotal)
        for row in value.rows {
            let rec = try #require(byID[row.id])
            #expect(row.filename == rec.filename && row.fullPath == rec.fullPath && row.volumeName == rec.volumeName)
            #expect(row.streamTypeLabel == rec.streamType.rawValue && row.streamTypeRaw == rec.streamTypeRaw)
            #expect(row.duration == rec.duration && row.size == rec.size && row.starRating == rec.starRating)
            #expect(row.junkScore == rec.junkScore && row.junkReasons == rec.junkReasons)
            #expect(row.mediaDisposition == rec.mediaDisposition && row.lifecycleStage == rec.lifecycleStage)
            #expect(row.filenameColor == rec.filenameColor)
            for filter in TriageFilter.allCases { #expect(filter.matches(row) == filter.matches(rec)) }
            #expect(value.row(row.id) == row, "the id index finds the row")
        }
        #expect(value.row(UUID()) == nil)
    }

    /// "Online volumes only" asks once per /Volumes root per build, and
    /// per file on the internal disk (where the old check was per file).
    @Test func reachabilityIsAskedOncePerVolumeRoot() throws {
        var asked: [String] = []
        let projection = TriageSnapshotBuilder.project(records)
        let value = try #require(TriageSnapshotBuilder.build(projection, query: TriageQuery(onlineOnly: true), reachable: { path in
            asked.append(path)
            return TriageFixture.reachable(path)
        }))
        let external = asked.filter { $0.hasPrefix("/Volumes/") }
        let internalRows = projection.rows.filter { !$0.fullPath.hasPrefix("/Volumes/") }.count
        #expect(external.count == 3, "one question each for Alpha, Beta and Gamma Ray (asked \(external.count))")
        #expect(asked.count == 3 + internalRows)
        #expect(value.rows.allSatisfy { TriageFixture.reachable($0.fullPath) } && !value.rows.isEmpty)
        // Off: nothing is asked at all.
        asked = []
        _ = TriageSnapshotBuilder.build(projection, query: TriageQuery(), reachable: { asked.append($0); return true })
        #expect(asked.isEmpty)
    }

    @Test func theVolumeRootKeyIsTheReachabilityCachesKey() {
        #expect(TriageSnapshotBuilder.volumeRootKey("/Volumes/Alpha/a/b.mov") == "/Volumes/Alpha")
        #expect(TriageSnapshotBuilder.volumeRootKey("/Volumes/Gamma Ray/b.mov") == "/Volumes/Gamma Ray")
        #expect(TriageSnapshotBuilder.volumeRootKey("/Volumes/Alpha") == "/Volumes/Alpha")
        #expect(TriageSnapshotBuilder.volumeRootKey("/Volumes/") == nil)
        #expect(TriageSnapshotBuilder.volumeRootKey("/Users/test/Movies/a.mov") == nil)
        #expect(TriageSnapshotBuilder.volumeRootKey("") == nil)
        // Same rule as VolumeReachability's private cacheKey(forPath:).
        for path in ["/Volumes/Alpha/a/b.mov", "/Volumes/Gamma Ray/b.mov", "/Volumes/Alpha"] {
            let comps = (path as NSString).pathComponents
            #expect(TriageSnapshotBuilder.volumeRootKey(path) == "/Volumes/\(comps[2])")
        }
    }

    @Test func aCancelledBuildReturnsNothing() {
        let projection = TriageSnapshotBuilder.project(records)
        #expect(TriageSnapshotBuilder.build(projection, query: TriageQuery(), reachable: { _ in true }, isCancelled: { true }) == nil)
    }

    @Test func anEmptyCatalogIsReadyAndEmpty() throws {
        let value = try #require(TriageSnapshotBuilder.build(TriageSnapshotBuilder.project([]), query: TriageQuery(), reachable: { _ in true }))
        #expect(value.isReady && value.rows.isEmpty && value.triageTotal == 0 && value.count(.all) == 0)
        #expect(!TriageSnapshotValue().isReady, "before the first build the tab draws blank, not “Nothing to triage”")
    }
}

// MARK: - Scale

@Suite("Triage snapshot — scale")
@MainActor
struct TriageSnapshotScaleTests {

    /// Budgets (Debug, alone on an M-series Mac): the main-actor projection
    /// of 100k records ≤ 1.5 s; the off-main build (counts + filter +
    /// search + the default sort + index) ≤ 3 s. A quadratic step in either
    /// would take minutes.
    @Test func oneHundredThousandRecordsWithinBudget() throws {
        let records = TriageFixture.records(100_000)

        var start = ContinuousClock.now
        let projection = TriageSnapshotBuilder.project(records)
        let projectTime = ContinuousClock.now - start

        start = ContinuousClock.now
        let value = try #require(TriageSnapshotBuilder.build(projection, query: TriageQuery(search: "clip", onlineOnly: true),
                                                             reachable: TriageFixture.reachable))
        let buildTime = ContinuousClock.now - start

        #expect(projection.rows.count == TriageOldViewReference.triageRecords(records).count)
        #expect(value.triageTotal == projection.rows.count && value.rows.count > 10_000)
        #expect(value.count(.all) == value.triageTotal)
        #expect(projectTime < PerformanceLane.debugCeiling(.milliseconds(1_500)),
                "projecting 100k records took \(projectTime) — over the 1.5 s budget (this step is on the main actor)")
        #expect(buildTime < PerformanceLane.debugCeiling(.milliseconds(3_000)),
                "building the 100k snapshot took \(buildTime) — over the 3 s budget")
    }

    /// The row lookup the context menu uses is an index read, not a scan:
    /// 100k lookups in well under a second.
    @Test func rowLookupByIDIsNotAScan() throws {
        let records = TriageFixture.records(100_000)
        let value = try #require(TriageSnapshotBuilder.build(TriageSnapshotBuilder.project(records), query: TriageQuery(),
                                                             reachable: { _ in true }))
        let ids = value.rows.map(\.id)
        let start = ContinuousClock.now
        var found = 0
        for id in ids where value.row(id) != nil { found += 1 }
        let elapsed = ContinuousClock.now - start
        #expect(found == ids.count)
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(1_000)), "\(ids.count) row lookups took \(elapsed)")
    }
}

// MARK: - The model's cache: when it builds, how often it publishes

@Suite("Triage snapshot — model cache", .serialized)
@MainActor
struct TriageSnapshotModelTests {

    /// Debounce (250 ms) + detached build — wait it out with margin.
    private func settle() async throws { try await Task.sleep(nanoseconds: 800_000_000) }

    private func makeModel(_ count: Int = 200) -> VideoScanModel {
        let model = VideoScanModel()
        model.triageReachability = TriageFixture.reachable
        model.records = TriageFixture.records(count)
        return model
    }

    @Test func nothingIsBuiltUntilTheTabIsShown() async throws {
        let model = makeModel()
        model.records.append(contentsOf: TriageFixture.records(5))
        model.noteCatalogChangedForDossierCounts()
        model.setTriageQuery(TriageQuery(filter: .important))
        try await settle()
        #expect(model.triageProjectionCount == 0, "a launch that never opens Triage pays nothing")
        #expect(model.triageSnapshot.publishCount == 0 && !model.triageSnapshot.value.isReady)
    }

    @Test func aBurstOfMutationsInsideTheDebounceWindowIsOnePublish() async throws {
        let model = makeModel()
        model.triageViewAppeared(query: TriageQuery())
        try await settle()
        let publishes = model.triageSnapshot.publishCount
        let projections = model.triageProjectionCount
        #expect(publishes == 1 && projections == 1, "appearing builds once")
        let before = model.triageSnapshot.value.triageTotal

        // What a Delete Duplicates run does to the catalog, file by file:
        // array-level changes and in-place edits, 300 of them, no pause.
        let extra = TriageFixture.records(100)
        for (i, r) in extra.enumerated() {
            model.records.append(r)
            model.records[i].mediaDisposition = .confirmedJunk
            model.noteCatalogChangedForDossierCounts()
            model.noteCatalogMutated()
        }
        try await settle()
        #expect(model.triageSnapshot.publishCount == publishes + 1,
                "300 mutations inside the window → ONE publish (got \(model.triageSnapshot.publishCount - publishes))")
        #expect(model.triageProjectionCount == projections + 1,
                "…and ONE pass over the records (got \(model.triageProjectionCount - projections))")
        #expect(model.triageSnapshot.value.triageTotal > before)
        #expect(model.triageSnapshot.value.triageTotal == TriageOldViewReference.triageRecords(model.records).count)

        // Reads are free.
        for _ in 0..<1_000 { _ = model.triageSnapshot.value.count(.confirmedJunk) }
        #expect(model.triageProjectionCount == projections + 1 && model.triageSnapshot.publishCount == publishes + 1)
    }

    @Test func anUnchangedRebuildDoesNotPublish() async throws {
        let model = makeModel()
        model.triageViewAppeared(query: TriageQuery())
        try await settle()
        let publishes = model.triageSnapshot.publishCount
        model.refreshTriageSnapshotNow()
        model.noteCatalogMutated()
        try await settle()
        #expect(model.triageSnapshot.publishCount == publishes, "same catalog, same query → zero invalidation")
    }

    @Test func aQueryChangeRebuildsWithoutWalkingTheRecordsAgain() async throws {
        let model = makeModel()
        model.triageViewAppeared(query: TriageQuery())
        try await settle()
        let projections = model.triageProjectionCount
        let query = TriageQuery(filter: .untriaged, search: "clip", onlineOnly: true,
                                sortOrder: [KeyPathComparator(\TriageRow.sizeBytes, order: .reverse)])
        model.setTriageQuery(query)
        try await settle()
        #expect(model.triageProjectionCount == projections, "filter / search / sort reuse the projection")
        let value = model.triageSnapshot.value
        #expect(value.query == query)
        let expected = TriageOldViewReference.filteredRecords(
            model.records, selectedFilter: .untriaged, searchText: "clip", showOnlineOnly: true,
            stewardReviewIDs: [], reachable: TriageFixture.reachable)
            .sorted(using: [KeyPathComparator(\VideoRecord.sizeBytes, order: .reverse)])
        #expect(value.rows.map(\.id) == expected.map(\.id) && !expected.isEmpty)
        // The same query again is not even a build.
        let publishes = model.triageSnapshot.publishCount
        model.setTriageQuery(query)
        try await settle()
        #expect(model.triageSnapshot.publishCount == publishes)
    }

    @Test func anEditMadeInTheTabShowsWithoutWaitingOutTheDebounce() async throws {
        let model = makeModel()
        model.triageViewAppeared(query: TriageQuery())
        try await settle()
        let target = try #require(model.triageSnapshot.value.rows.first { $0.mediaDisposition == .unreviewed })
        try #require(model.record(forID: target.id)).mediaDisposition = .important
        model.refreshTriageSnapshotNow()
        // Well inside the 250 ms debounce.
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(model.triageSnapshot.value.row(target.id)?.mediaDisposition == .important)
    }

    @Test func leavingTheScreenStopsTheWorkAndDropsTheRows() async throws {
        let model = makeModel()
        model.triageViewAppeared(query: TriageQuery())
        try await settle()
        #expect(model.triageSnapshot.value.isReady && !model.triageSnapshot.value.rows.isEmpty)
        model.triageViewDisappeared()
        #expect(!model.triageWanted && !model.triageSnapshot.value.isReady && model.triageSnapshot.value.rows.isEmpty)
        #expect(model.triageProjection == nil, "the projection is not kept for a tab nobody is looking at")
        let projections = model.triageProjectionCount
        let publishes = model.triageSnapshot.publishCount
        model.records.append(contentsOf: TriageFixture.records(10))
        model.noteCatalogChangedForDossierCounts()
        try await settle()
        #expect(model.triageProjectionCount == projections && model.triageSnapshot.publishCount == publishes)
        // …and coming back builds again.
        model.triageViewAppeared(query: TriageQuery(filter: .important))
        try await settle()
        #expect(model.triageSnapshot.value.isReady && model.triageSnapshot.value.query.filter == .important)
    }

    /// Tabs 2 and 3 both show Triage; the new view's appear can arrive
    /// before the old one's disappear.
    @Test func theOnScreenCountSurvivesAppearBeforeDisappear() async throws {
        let model = makeModel()
        model.triageViewAppeared(query: TriageQuery())
        model.triageViewAppeared(query: TriageQuery(filter: .workspace))
        model.triageViewDisappeared()
        #expect(model.triageWanted)
        try await settle()
        #expect(model.triageSnapshot.value.isReady && model.triageSnapshot.value.query.filter == .workspace)
        model.triageViewDisappeared()
        model.triageViewDisappeared()
        #expect(!model.triageWanted && model.triageViewers == 0)
    }

    @Test func aDriveComingOrGoingRepaintsAndRefiltersOnlyWhenAskedTo() async throws {
        let model = makeModel()
        model.noteTriageReachabilityChanged()
        #expect(model.triageSnapshot.reachabilityEpoch == 0, "off screen: nothing")
        model.triageViewAppeared(query: TriageQuery(onlineOnly: true))
        try await settle()
        let rows = model.triageSnapshot.value.rows.count
        let projections = model.triageProjectionCount
        // Beta is plugged in.
        model.triageReachability = { path in path.hasPrefix("/Users/") ? !path.hasSuffix("3.mov") : true }
        model.refreshTargetReachability()
        try await settle()
        #expect(model.triageSnapshot.reachabilityEpoch == 1)
        #expect(model.triageSnapshot.value.rows.count > rows, "Beta's rows are back")
        #expect(model.triageProjectionCount == projections, "no pass over the records for a mount")
    }

    /// QA F9: the steward queue stops rebuilding once its pane is gone.
    @Test func theStewardQueueStopsWhenItsPaneLeavesTheScreen() {
        let model = VideoScanModel()
        #expect(!model.stewardWanted)
        model.stewardPaneAppeared()
        model.stewardPaneAppeared()
        model.stewardPaneDisappeared()
        #expect(model.stewardWanted, "another pane is still on screen")
        #expect(model.stewardAngelWatch != nil, "the Angel is watched while a pane is up")
        model.stewardPaneDisappeared()
        #expect(!model.stewardWanted && model.stewardTask == nil)
        #expect(model.stewardAngelWatch == nil, "…and not once the last pane has gone")
        model.stewardPaneDisappeared()
        #expect(model.stewardPaneCount == 0)
    }
}

// MARK: - Numbers: the old body pass vs reading the snapshot

@Suite("Triage snapshot — before/after numbers", .serialized)
@MainActor
struct TriageSnapshotBenchmarkTests {

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    private func best(of runs: Int, _ work: () -> Int) -> (ms: Double, sum: Int) {
        var bestMS = Double.infinity
        var sum = 0
        for _ in 0..<runs {
            let start = ContinuousClock.now
            sum = work()
            bestMS = min(bestMS, ms(ContinuousClock.now - start))
        }
        return (bestMS, sum)
    }

    /// What the new `body` reads per evaluation: nine badges, the progress
    /// numbers, the Delete Junk and Analyze counts, the rows array (a
    /// retain) and its count, the stale check.
    private func snapshotRead(_ value: TriageSnapshotValue, query: TriageQuery) -> Int {
        var sum = 0
        for filter in TriageFilter.allCases { sum &+= value.count(filter) }
        sum &+= value.triageTotal &+ value.reviewed &+ value.count(.confirmedJunk) &+ value.archivedConfirmedJunk
        let rows = value.rows
        sum &+= rows.count
        if value.query != query { sum &+= 1 }
        return sum
    }

    @Test(arguments: [10_000, 100_000])
    func oldBodyPassVersusSnapshotRead(count: Int) throws {
        let records = TriageFixture.records(count)
        let oldSort = [KeyPathComparator(\VideoRecord.filename)]
        let query = TriageQuery()

        // BEFORE: one evaluation of the old body, all of it on the main thread.
        let old = best(of: 3) {
            TriageOldViewReference.bodyPass(records, selectedFilter: .all, searchText: "", showOnlineOnly: false,
                                            stewardReviewIDs: [], sortOrder: oldSort, reachable: TriageFixture.reachable)
        }
        // The same with "Online volumes only" on and a search typed.
        let oldBusy = best(of: 3) {
            TriageOldViewReference.bodyPass(records, selectedFilter: .all, searchText: "clip", showOnlineOnly: true,
                                            stewardReviewIDs: [], sortOrder: oldSort, reachable: TriageFixture.reachable)
        }

        // AFTER: per catalog change (debounced) one projection on the main
        // thread and one build off it; per body evaluation, a read.
        var projection = TriageProjection()
        let project = best(of: 3) { projection = TriageSnapshotBuilder.project(records); return projection.rows.count }
        var value = TriageSnapshotValue()
        let build = best(of: 3) {
            value = TriageSnapshotBuilder.build(projection, query: query, reachable: TriageFixture.reachable) ?? TriageSnapshotValue()
            return value.rows.count
        }
        let reads = 10_000
        var readSum = 0
        let readStart = ContinuousClock.now
        for _ in 0..<reads { readSum &+= snapshotRead(value, query: query) }
        let readMS = ms(ContinuousClock.now - readStart) / Double(reads)

        #expect(value.rows.count == TriageOldViewReference.triageRecords(records).count)
        #expect(old.sum != 0 && oldBusy.sum != 0 && readSum != 0 && project.sum == value.triageTotal && build.sum == value.rows.count)
        let line = String(format: "TRIAGE-BENCH [%@] records=%d | BEFORE old body pass (main): %.1f ms; with search+online-only: %.1f ms"
                          + " | AFTER projection (main, per debounced catalog change): %.1f ms; build (off-main): %.1f ms;"
                          + " body read (main, per evaluation): %.5f ms",
                          PerformanceLane.configurationName, count, old.ms, oldBusy.ms, project.ms, build.ms, readMS)
        print(line)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("triage_snapshot_bench_\(count).txt")
        try? (line + "\n").write(to: out, atomically: true, encoding: .utf8)
        print("TRIAGE-BENCH written to \(out.path)")

        // The point of the change, as a floor that cannot flake: reading
        // the snapshot is at least 100× cheaper than the old body pass.
        #expect(readMS * 100 < old.ms, "snapshot read \(readMS) ms vs old body pass \(old.ms) ms")
    }
}

// MARK: - Source sensors: the view does no records work and does not observe the model

@Suite("Triage view — source sensors")
struct TriageViewSensorTests {

    private func source(_ file: String) throws -> String {
        try SourceTree.appSource(named: file)
    }

    /// Code only — comment lines stripped so headers that EXPLAIN the rule
    /// don't trip the check.
    private func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The whole view — `body` and every property and helper it reaches —
    /// from the struct's opening to the end of the file.
    private func viewCode() throws -> String {
        let src = code(try source("TriageView.swift"))
        let start = try #require(src.range(of: "struct TriageView: View {"))
        return String(src[start.lowerBound...])
    }

    @Test func theViewObservesTheSnapshotAndNotTheModel() throws {
        let view = try viewCode()
        #expect(view.count > 20_000, "the scan is reading nothing")
        #expect(view.contains("let model: VideoScanModel"), "a plain reference — no subscription")
        #expect(view.contains("@ObservedObject private var snapshot: TriageSnapshot"))
        #expect(view.contains("self._snapshot = ObservedObject(wrappedValue: model.triageSnapshot)"))
        #expect(!view.contains("@EnvironmentObject"),
                "TriageView must not observe the model or the job centre wholesale — both publish many times a second during a long run")
        #expect(!view.contains("@ObservedObject var model") && !view.contains("@StateObject"))
        #expect(occurrences(of: "@ObservedObject", in: view) == 1, "the snapshot is the only observed object")
        #expect(view.contains("@Environment(\\.mediaFileOperationsCenterReference) private var fileOpsCenterReference"),
                "the job centre is a plain reference, read when a context menu opens")
        #expect(try code(source("ContentView.swift")).contains("TriageView(model: model)"))
    }

    @Test func noRecordsWalkAnywhereInTheView() throws {
        let view = try viewCode()
        // The two places the view names the array at all: handing it to the
        // import sheet (built only while that sheet is up) and appending
        // the imported record.
        let named = try NSRegularExpression(pattern: #"model\.records\b"#)
            .numberOfMatches(in: view, range: NSRange(location: 0, length: (view as NSString).length))
        #expect(named == 2, "found \(named)")
        #expect(view.contains("catalogRecords: model.records,") && view.contains("model.records.append(rec)"))
        let walks = ["records.filter", "records.map", "records.reduce", "records.sorted", "records.first", "records.count",
                     "records.contains", "records.compactMap", "records.forEach", "records.lazy", "records.isEmpty",
                     "for r in records", "for rec in records", "in model.records", "pfActiveRecords(", "pfExportableRecords(",
                     "first(where:", ".sorted(", "filteredRecords", "TriageSnapshotBuilder.project(", "TriageSnapshotBuilder.build("]
        for walk in walks {
            #expect(!view.contains(walk), "TriageView has `\(walk)` — O(records) work belongs in TriageSnapshotBuilder")
        }
        #expect(!view.contains(".first { $0") && !view.contains("first { $0.id == id }"),
                "a linear scan by id — use model.record(forID:)")
        // The only O(records) calls left are click-time, inside button actions.
        #expect(occurrences(of: "model.triageScopeRecords()", in: view) == 2, "Analyze All and Analyze Selected, at click time")
        #expect(view.contains("runAnalysis(records: model.triageScopeRecords())"))
        #expect(view.contains("let selected = model.triageScopeRecords().filter { selectedIDs.contains($0.id) }"))
        #expect(occurrences(of: "triageConfirmedJunkRecords()", in: view) == 1)
        // Since the frozen Delete Junk snapshot (design R1, 2026-10-09) the
        // records are gathered when the button is pressed and frozen by
        // `freezeJunkSnapshot`, which applies the bulk-verb gate itself.
        #expect(view.contains("let records = model.triageConfirmedJunkRecords()")
                && view.contains("junkSheet = .confirm(await model.freezeJunkSnapshot(records))"),
                "the Delete Junk records are gathered when the button is pressed")
    }

    @Test func whatTheBodyDrawsComesFromTheSnapshot() throws {
        let view = try viewCode()
        for read in ["let count = snapshot.value.count(filter)",
                     "let total = snapshot.value.triageTotal",
                     "let reviewed = snapshot.value.reviewed",
                     "let rows = snapshot.value.rows",
                     "Text(\"\\(snapshot.value.rows.count) \\(selectedFilter.rawValue.lowercased())\")",
                     "snapshot.value.archivedConfirmedJunk > 0",
                     "if snapshot.value.count(.confirmedJunk) > 0 {",
                     "Button(\"Analyze All (\\(snapshot.value.triageTotal))\")",
                     "private func fileTable(rows: [TriageRow]) -> some View {",
                     "if !snapshot.value.isReady {"] {
            #expect(view.contains(read), "the view no longer reads `\(read)`")
        }
        // Selected-record lookups go through the model's id index.
        let start = try #require(view.range(of: "private func applyDisposition("))
        let end = try #require(view.range(of: "private func showInCatalog(", range: start.upperBound..<view.endIndex))
        let apply = String(view[start.upperBound..<end.lowerBound])
        #expect(apply.contains("for rec in model.triageRecords(withIDs: ids) {"), "O(selection), not O(selection × records)")
        #expect(apply.contains("model.saveCatalogDebounced()") && apply.contains("catalogEdited()"))
        #expect(try code(source("VideoScanModel+TriageSnapshot.swift")).contains("ids.compactMap { record(forID: $0) }"))
    }

    @Test func theViewTellsTheModelWhenItIsOnScreenAndWhatItWants() throws {
        let view = try viewCode()
        #expect(view.contains("model.triageViewAppeared(query: currentQuery)"))
        #expect(view.contains("model.triageViewDisappeared()") && view.contains(".onDisappear {"))
        for change in [".onChange(of: selectedFilter) { _, _ in pushQuery() }",
                       ".onChange(of: showOnlineOnly) { _, _ in pushQuery() }",
                       ".onChange(of: stewardReviewIDs) { _, _ in pushQuery() }",
                       ".onChange(of: sortOrder) { _, _ in pushQuery() }",
                       ".onChange(of: searchText) { _, _ in pushQueryAfterTyping() }"] {
            #expect(view.contains(change), "missing `\(change)`")
        }
        #expect(view.contains("try? await Task.sleep(nanoseconds: 200_000_000)"), "search-as-you-type waits 200 ms")
        #expect(code(try source("StewardPaneView.swift")).contains(".onDisappear { model.stewardPaneDisappeared() }"))
    }

    @Test func theModelBuildsOffMainOnlyWhileShownAndRidesTheMutationFunnels() throws {
        let ext = code(try source("VideoScanModel+TriageSnapshot.swift"))
        #expect(ext.contains("Task.detached(priority: priority)"), "the build is off the main actor")
        #expect(occurrences(of: "guard triageWanted else { return }", in: ext) >= 4, "no work while the tab is off screen")
        #expect(ext.contains("try? await Task.sleep(nanoseconds: delay)"), "one rebuild per burst")
        // 250 ms, stretched to 10× the last projection pass, capped at 5 s.
        #expect(VideoScanModel.triageDebounceNanos(lastProjectionNanos: 0) == 250_000_000)
        #expect(VideoScanModel.triageDebounceNanos(lastProjectionNanos: 20_000_000) == 250_000_000)
        #expect(VideoScanModel.triageDebounceNanos(lastProjectionNanos: 200_000_000) == 2_000_000_000)
        #expect(VideoScanModel.triageDebounceNanos(lastProjectionNanos: 900_000_000) == 5_000_000_000)
        #expect(VideoScanModel.triageDebounceNanos(lastProjectionNanos: .max) == 5_000_000_000)
        #expect(ext.contains("self.triageGeneration == generation"), "a late build never publishes")
        #expect(ext.contains("let changed = value != previous"), "the equality gate runs off-main")
        #expect(occurrences(of: "TriageSnapshotBuilder.project(records)", in: ext) == 1, "ONE place walks the records")
        let model = code(try source("VideoScanModel.swift"))
        let mutated = try #require(model.range(of: "func noteCatalogMutated() {"))
        #expect(String(model[mutated.upperBound...].prefix(300)).contains("noteTriageCatalogChanged()"))
        let dossier = try #require(model.range(of: "func noteCatalogChangedForDossierCounts() {"))
        #expect(String(model[dossier.upperBound...].prefix(600)).contains("noteTriageCatalogChanged()"))
        #expect(code(try source("VideoScanModel+VolumeLifecycle.swift")).contains("noteTriageReachabilityChanged()"))
        let builder = code(try source("TriageSnapshot.swift"))
        #expect(builder.contains("pfActiveRecords(records).filter { $0.lifecycleStage != .archived }"),
                "Triage's scope still routes through the one visibility predicate")
        #expect(builder.contains("guard knownDifferent || new != value else { return }"), "publishing is equality-gated")
        #expect(builder.contains("rows = rows.filter { query.reviewIDs.contains($0.id) }"), "Review these below narrows the table")
    }
}
