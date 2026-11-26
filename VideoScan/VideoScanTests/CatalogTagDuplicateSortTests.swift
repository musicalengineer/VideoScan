// CatalogTagDuplicateSortTests.swift
// The Catalog's Tag and Duplicate columns sort (Rick 2026-11-25: "Tag and
// Duplicate are not sortable").
//
//   Logic   — Tag: Important › Recoverable › Unreviewed › Suspected Junk ›
//             Confirmed Junk, then the workflow tags (tagged before
//             untagged, tag order independent of insertion). Duplicate:
//             Keep › Review › Extra copy › not analysed, then copy count.
//   Scale   — 100k records sorted by each column through the same
//             KeyPathComparator the Table hands the model, inside a budget.
//   Sensor  — both tables give both columns a `value:` key path, and the
//             folder table's sort mapping carries both (the round trip).
//   Media matrix / isolation: N/A — catalog fields only, no file, no prefs.
//
// Suites: CatalogTagDuplicateSortLogicTests · CatalogTagDuplicateSortScaleTests ·
//         CatalogTagDuplicateSortSensorTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func record(_ d: MediaDisposition = .unreviewed, tags: [String] = [],
                    dup: DuplicateDisposition = .none, copies: Int = 0) -> VideoRecord {
    let r = VideoRecord()
    r.mediaDisposition = d
    r.tags = tags
    r.duplicateDisposition = dup
    r.duplicateGroupCount = copies
    return r
}

@Suite("Catalog Tag / Duplicate sort — logic")
struct CatalogTagDuplicateSortLogicTests {

    @Test func tagSortsByDispositionInReviewOrder() {
        let order: [MediaDisposition] = [.important, .recoverable, .unreviewed, .suspectedJunk, .confirmedJunk]
        let shuffled = [order[3], order[0], order[4], order[2], order[1]].map { record($0) }
        let sorted = shuffled.sorted(using: KeyPathComparator(\VideoRecord.tagSortKey))
        #expect(sorted.map(\.mediaDisposition) == order)
        #expect(MediaDisposition.allCases.count == order.count, "a new disposition needs a place in the order")
    }

    @Test func withinADispositionTaggedRowsComeFirstThenByTag() {
        let untagged = record(.important)
        let zebra = record(.important, tags: ["Zebra"])
        let birthday = record(.important, tags: ["birthday"])
        let numbered = record(.important, tags: ["2025 trip"])
        let junkTagged = record(.confirmedJunk, tags: ["aaa"])
        let sorted = [junkTagged, untagged, zebra, birthday, numbered]
            .sorted(using: KeyPathComparator(\VideoRecord.tagSortKey))
        #expect(sorted.map(\.id) == [numbered.id, birthday.id, zebra.id, untagged.id, junkTagged.id])
    }

    @Test func tagOrderDoesNotDependOnInsertionOrder() {
        #expect(record(tags: ["Xmas", "Archive"]).tagSortKey == record(tags: ["Archive", "Xmas"]).tagSortKey)
    }

    @Test func duplicateSortsByDispositionThenCopyCount() {
        let none = record(dup: .none, copies: 0)
        let keep3 = record(dup: .keep, copies: 3)
        let keep2 = record(dup: .keep, copies: 2)
        let review = record(dup: .review, copies: 2)
        let extra = record(dup: .extraCopy, copies: 9)
        let sorted = [none, extra, keep3, review, keep2].sorted(using: KeyPathComparator(\VideoRecord.duplicateSortKey))
        #expect(sorted.map(\.id) == [keep2.id, keep3.id, review.id, extra.id, none.id])
    }

    @Test func aHugeOrNegativeCountNeverCrossesIntoTheNextDisposition() {
        let keepHuge = record(dup: .keep, copies: Int.max)
        let review = record(dup: .review, copies: -5)
        #expect(keepHuge.duplicateSortKey < review.duplicateSortKey)
        #expect(review.duplicateSortKey == DuplicateDisposition.review.catalogSortRank * VideoRecord.duplicateRankStride)
    }

    @Test func aFolderRowSortsAfterEveryFile() {
        #expect(record(.confirmedJunk).tagSortKey < CatalogTagSortKey.notAFile)
    }
}

@Suite("Catalog Tag / Duplicate sort — scale")
struct CatalogTagDuplicateSortScaleTests {

    /// 100k records, a mix of every disposition, 0–3 tags, every duplicate
    /// disposition and counts: each column sorted the way the model sorts
    /// on a header click (`sort(using:)` with the column's comparator).
    @Test func hundredThousandRowsSortInsideTheBudget() {
        let dispositions = MediaDisposition.allCases
        let dups: [DuplicateDisposition] = [.none, .keep, .review, .extraCopy]
        let tagPool = ["birthday", "Xmas", "2025 trip", "needs date", "Donna's", "wedding"]
        var rows: [VideoRecord] = []
        rows.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let tags = (0..<(i % 4)).map { tagPool[(i / 7 + $0 * 3) % tagPool.count] }
            rows.append(record(dispositions[i % dispositions.count], tags: tags,
                               dup: dups[(i / 3) % dups.count], copies: i % 9))
        }
        let load = TimingBudget.sampleLoad()
        let start = ContinuousClock.now
        let byTag = rows.sorted(using: KeyPathComparator(\VideoRecord.tagSortKey))
        let tagTime = ContinuousClock.now - start
        let dupStart = ContinuousClock.now
        let byDup = rows.sorted(using: KeyPathComparator(\VideoRecord.duplicateSortKey, order: .reverse))
        let dupTime = ContinuousClock.now - dupStart

        #expect(byTag.count == 100_000 && byDup.count == 100_000)
        #expect(byTag.first?.mediaDisposition == .important && byTag.last?.mediaDisposition == .confirmedJunk)
        #expect(byDup.first?.duplicateDisposition == DuplicateDisposition.none, "reverse: not analysed first")
        expectWithinTimingBudget("Catalog Tag column sort, 100k rows", measured: tagTime,
                                 budget: PerformanceLane.debugCeiling(.milliseconds(3_000)), loadBefore: load)
        expectWithinTimingBudget("Catalog Duplicate column sort, 100k rows", measured: dupTime,
                                 budget: PerformanceLane.debugCeiling(.milliseconds(1_000)), loadBefore: load)
    }
}

@Suite("Catalog Tag / Duplicate sort — sensor")
struct CatalogTagDuplicateSortSensorTests {

    private func code(_ name: String) throws -> String {
        try SourceTree.strippingComments(SourceTree.appSource(named: name))
    }

    @Test func bothTablesGiveTagAndDuplicateASortKey() throws {
        let linear = try code("CatalogContent+Table.swift")
        #expect(linear.contains("TableColumn(\"Tag\", value: \\VideoRecord.tagSortKey)"))
        #expect(linear.contains("TableColumn(\"Duplicate\", value: \\VideoRecord.duplicateSortKey)"))
        let folders = try code("CatalogContent+FolderTable.swift")
        #expect(folders.contains("TableColumn(\"Tag\", value: \\FootageFolderTableRow.tag)"))
        #expect(folders.contains("TableColumn(\"Duplicate\", value: \\FootageFolderTableRow.duplicate)"))
    }

    @Test func theFolderSortMappingCarriesBothColumns() {
        #expect(FootageFolders.SortKey(rawValue: "tag") != nil)
        #expect(FootageFolders.SortKey(rawValue: "duplicate") != nil)
        let keys = Set(FootageFolderSort.columns.map(\.key.rawValue))
        #expect(keys.contains("tag") && keys.contains("duplicate"))
    }
}
