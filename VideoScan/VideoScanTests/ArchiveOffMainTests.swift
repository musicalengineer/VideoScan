// ArchiveOffMainTests.swift
// 2026-10-04 perf: two O(records) passes the Archive tab ran on the MAIN
// thread on its first render after every catalog change (0.72 s in
// `ArchiveView.body` in Rick's Release trace) now run off it:
//   * `archiveProgress` computed `CatalogStorageTotalsCalculator.compute`
//     inside body (through a render memo);
//   * `ArchiveCategorySnapshot.compute` asked `RecordDateResolver.resolve`
//     (→ `FilenameDatePattern.match`) per not-yet-archived record.
// Both are now worked out in `.task(id: archiveStorageKey)`.
//
//   Logic/Equivalence — the "Needs a date" list from the off-main id set
//               equals the list resolved in place (order kept), on records
//               that hit every date source; `.pending` gives an empty list
//               and nothing else changes; the progress from the off-main
//               totals equals the progress from the in-place totals.
//   Scale     — 100k records + 5k promoted copies: the old in-place snapshot
//               and footer timed beside the new main-actor work; the
//               off-main pass under an explicit budget.
//   Sensor    — body no longer computes the totals; the snapshot is fed
//               the off-main answer.
// Isolation: the model has its own temp catalog directory.
// Media matrix: N/A — no media opened.
//
// Suites: ArchiveOffMainTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Archive tab — off-main progress totals and Needs a date", .serialized)
@MainActor
struct ArchiveOffMainTests {

    private static let archiveRoot = "/Volumes/TestArchive/Breen_Family_Archive"

    private static func makeModel() -> VideoScanModel {
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("test_archive_offmain_\(UUID().uuidString.prefix(8))", isDirectory: true))
        model.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/TestArchive", rootPath: archiveRoot)
        return model
    }

    private static func source(_ name: String, volume: String = "/Volumes/Src") -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "\(volume)/\(name)"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = 1_000
        return r
    }

    private static func copy(of src: VideoRecord, rel: String) -> VideoRecord {
        let c = VideoRecord()
        c.filename = (rel as NSString).lastPathComponent
        c.fullPath = archiveRoot + "/" + rel
        c.derivedFrom = src.id
        c.derivationKind = ArchivePromotion.derivationKind
        c.sizeBytes = src.sizeBytes
        c.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return c
    }

    /// Every date source the resolver ranks, plus none at all.
    private static func datedCatalog() -> [VideoRecord] {
        var out: [VideoRecord] = []
        for i in 0..<40 {
            let r: VideoRecord
            switch i % 8 {
            case 0: r = source("clip_\(i).mov")                                   // nothing → needs a date
            case 1: r = source("Trip_1990_\(i).mov")                              // a year in the name
            case 2: r = source("2004-07-04 picnic \(i).mov")                      // a day in the name
            case 3:
                r = source("user_\(i).mov"); r.userDate = "1987-06"; r.userDateConfidence = "exact"
            case 4:
                r = source("embedded_\(i).mov"); r.embeddedCreationDate = Date(timeIntervalSince1970: 900_000_000)
                r.originMake = "Sony"; r.originModel = "DCR-TRV900"
            case 5:
                r = source("inferred_\(i).mov"); r.inferredRecordDate = Date(timeIntervalSince1970: 600_000_000)
                r.inferredDateConfidence = 0.9
            case 6:
                r = source("weak_\(i).mov"); r.inferredRecordDate = Date(timeIntervalSince1970: 600_000_000)
                r.inferredDateConfidence = 0.2
            default:
                r = source("decade_\(i).mov"); r.userDate = "198x"
            }
            out.append(r)
        }
        // Archived ones (with copies) never reach the Needs-a-date list.
        let promoted = source("clip_promoted.mov")
        out += [promoted, copy(of: promoted, rel: "30_Video/Undated/clip_promoted.mov")]
        let purged = source("clip_purged.mov")
        purged.purgedAt = Date(timeIntervalSince1970: 1_000_000)
        out.append(purged)
        return out
    }

    @Test func theOffMainNeedsDateListEqualsTheOneResolvedInPlace() async {
        let model = Self.makeModel()
        model.records = Self.datedCatalog()
        let inPlace = ArchiveCategorySnapshot.compute(active: pfActiveRecords(model.records), allRecords: model.records,
                                                      model: model, volumeSearchPaths: ["/Volumes/Src"])
        let facts = ArchiveCategorySnapshot.projectDateFacts(model.records)
        let ids = await Task.detached(priority: .utility) { ArchiveCategorySnapshot.needsDateIDs(facts) }.value
        let offMain = ArchiveCategorySnapshot.compute(active: pfActiveRecords(model.records), allRecords: model.records,
                                                      model: model, volumeSearchPaths: ["/Volumes/Src"],
                                                      needsDate: .precomputed(ids))
        #expect(offMain.needsDate.map(\.id) == inPlace.needsDate.map(\.id))
        #expect(!inPlace.needsDate.isEmpty && inPlace.needsDate.count < inPlace.notYetArchived.count, "not vacuous")
        // Everything else is the same snapshot.
        #expect(offMain.archived.map(\.id) == inPlace.archived.map(\.id))
        #expect(offMain.notYetArchived.map(\.id) == inPlace.notYetArchived.map(\.id))
        #expect(offMain.activeAssetCount == inPlace.activeAssetCount && offMain.volumeFileCounts == inPlace.volumeFileCounts)
        // Before the first pass lands: an empty list, nothing else moves.
        let pending = ArchiveCategorySnapshot.compute(active: pfActiveRecords(model.records), allRecords: model.records,
                                                      model: model, volumeSearchPaths: ["/Volumes/Src"], needsDate: .pending)
        #expect(pending.needsDate.isEmpty && pending.notYetArchived.map(\.id) == inPlace.notYetArchived.map(\.id))
    }

    @Test func theMemoRecomputesOnceWhenTheOffMainAnswerLands() {
        let model = Self.makeModel()
        model.records = Self.datedCatalog()
        let memo = RenderMemo<ArchiveCategoryKey, ArchiveCategorySnapshot>()
        let pending = ArchiveCategorySnapshot.cached(in: memo, model: model, volumeSearchPaths: [], needsDate: .pending, needsDateGeneration: 0)
        _ = ArchiveCategorySnapshot.cached(in: memo, model: model, volumeSearchPaths: [], needsDate: .pending, needsDateGeneration: 0)
        #expect(pending.needsDate.isEmpty && memo.computeCount == 1)
        let ids = ArchiveCategorySnapshot.needsDateIDs(ArchiveCategorySnapshot.projectDateFacts(model.records))
        let landed = ArchiveCategorySnapshot.cached(in: memo, model: model, volumeSearchPaths: [], needsDate: .precomputed(ids), needsDateGeneration: 1)
        #expect(!landed.needsDate.isEmpty && memo.computeCount == 2)
    }

    @Test func theProgressFromTheOffMainTotalsEqualsTheInPlaceProgress() async {
        let model = Self.makeModel()
        model.records = Self.datedCatalog()
        let inPlace = ArchiveProgress.from(totals: model.masterArchiveTotals,
                                           storage: CatalogStorageTotalsCalculator.compute(records: model.records))
        let rows = CatalogStorageRow.projectForStorageTotals(model.records)
        let totals = await Task.detached(priority: .utility) { CatalogStorageTotalsCalculator.compute(facts: rows) }.value
        let offMain = ArchiveProgress.from(totals: model.masterArchiveTotals, storage: totals)
        #expect(offMain == inPlace)
    }

    /// 100k sources (a third with no date) + 5k promoted copies. Budgets
    /// (Release): the new main-actor work — the two projections plus the
    /// snapshot without the resolver — under 400 ms; the off-main pass
    /// under 2 s. The old in-place snapshot and footer are printed beside.
    @Test func hundredThousandRecordsUnderBudget() async {
        let model = Self.makeModel()
        var records: [VideoRecord] = []
        records.reserveCapacity(105_000)
        var sources: [VideoRecord] = []
        for i in 0..<100_000 {
            let r = Self.source(i % 3 == 0 ? "clip_\(i).mov" : "Trip_1990_\(i).mov", volume: "/Volumes/Src\(i % 4)")
            records.append(r)
            if i % 20 == 0 { sources.append(r) }
        }
        for s in sources { records.append(Self.copy(of: s, rel: "30_Video/1990/\(s.filename)")) }
        model.records = records
        let volumes = ["/Volumes/Src0", "/Volumes/Src1", "/Volumes/Src2", "/Volumes/Src3", "/Volumes/TestArchive"]
        let clock = ContinuousClock()

        var start = clock.now
        let oldSnap = ArchiveCategorySnapshot.compute(active: pfActiveRecords(model.records), allRecords: model.records,
                                                      model: model, volumeSearchPaths: volumes)
        let oldStorage = CatalogStorageTotalsCalculator.compute(records: model.records)
        let oldMain = clock.now - start

        start = clock.now
        let rows = CatalogStorageRow.projectForStorageTotals(model.records)
        let facts = ArchiveCategorySnapshot.projectDateFacts(model.records)
        let projections = clock.now - start
        let (totals, ids, offMain) = await Task.detached(priority: .utility) {
            let s = ContinuousClock.now
            let t = CatalogStorageTotalsCalculator.compute(facts: rows)
            let n = ArchiveCategorySnapshot.needsDateIDs(facts)
            return (t, n, ContinuousClock.now - s)
        }.value
        start = clock.now
        let newSnap = ArchiveCategorySnapshot.compute(active: pfActiveRecords(model.records), allRecords: model.records,
                                                      model: model, volumeSearchPaths: volumes, needsDate: .precomputed(ids))
        let newMain = projections + (clock.now - start)

        print("PERF_SCALE archive: old main-actor snapshot+totals \(oldMain); new main-actor projections+snapshot \(newMain); off-main \(offMain)")
        #expect(totals == oldStorage)
        #expect(newSnap.needsDate.map(\.id) == oldSnap.needsDate.map(\.id))
        #expect(newSnap.needsDate.count > 30_000, "a third of the sources have no date")
        #expect(newMain < .milliseconds(400), "main-actor work took \(newMain)")
        #expect(offMain < .seconds(2), "off-main pass took \(offMain)")
    }

    @Test func bodyNoLongerComputesTheTotalsAndTheSnapshotIsFedTheOffMainAnswer() throws {
        let table = try SourceTree.appSource(named: "ArchiveView+Table.swift")
        let start = try #require(table.range(of: "var archiveProgress: ArchiveProgress? {"))
        let end = try #require(table.range(of: "var archiveStorageKey: RecordsVersion {", range: start.upperBound..<table.endIndex))
        let progress = String(table[start.upperBound..<end.lowerBound])
        #expect(!progress.contains("CatalogStorageTotalsCalculator.compute("), "the progress bar computes the totals in body again")
        let refresh = try #require(table.range(of: "func refreshArchiveStorageTotals() async {"))
        let refreshBody = String(table[refresh.upperBound...].prefix(900))
        let detached = try #require(refreshBody.range(of: "Task.detached(priority: .utility) {"))
        let inTask = String(refreshBody[detached.upperBound...])
        #expect(inTask.contains("CatalogStorageTotalsCalculator.compute(facts: rows)")
                && inTask.contains("ArchiveCategorySnapshot.needsDateIDs(dateFacts)"), "both passes run in the detached task")
        let view = try SourceTree.appSource(named: "ArchiveView.swift")
        #expect(view.contains(".task(id: archiveStorageKey) { await refreshArchiveStorageTotals() }"))
        #expect(view.contains("needsDate: needsDateIDs.map { .precomputed($0) } ?? .pending,"))
        #expect(!view.contains("storageTotalsMemo"), "the in-body totals memo is back")
    }
}
