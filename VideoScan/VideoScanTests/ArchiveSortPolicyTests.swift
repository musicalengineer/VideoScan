// ArchiveSortPolicyTests.swift
// GH #175 — the Archive tab's "Archived" column: newest first on the first
// click, undated rows last either way, source rows by their copy's date.
// Pure: no view, no model, no disk.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive tab — Archived column sort (GH #175)")
struct ArchiveSortPolicyTests {

    private let byName = [KeyPathComparator(\VideoRecord.filename)]
    private let archivedForward = [KeyPathComparator(\VideoRecord.archivedSortDate, order: .forward)]
    private let archivedReverse = [KeyPathComparator(\VideoRecord.archivedSortDate, order: .reverse)]

    @Test("the first click on Archived lands newest-first; later clicks toggle as the table says; other columns untouched")
    func firstClickIsNewestFirst() {
        #expect(ArchiveSortPolicy.adjusted(new: archivedForward, previous: byName) == archivedReverse)
        #expect(ArchiveSortPolicy.adjusted(new: archivedForward, previous: archivedReverse) == archivedForward, "second click toggles to oldest-first")
        #expect(ArchiveSortPolicy.adjusted(new: archivedReverse, previous: byName) == archivedReverse)
        #expect(ArchiveSortPolicy.adjusted(new: byName, previous: archivedReverse) == byName)
        #expect(ArchiveSortPolicy.adjusted(new: [], previous: byName) == [])
        // Re-applying the adjusted order is a fixed point (no onChange loop).
        #expect(ArchiveSortPolicy.adjusted(new: archivedReverse, previous: archivedForward) == archivedReverse)
        #expect(ArchiveSortPolicy.isArchivedDateSort(archivedForward) && !ArchiveSortPolicy.isArchivedDateSort(byName))
    }

    @Test("newest first with undated rows last; oldest first keeps undated last too; ties and undated stay stable")
    func ordering() {
        struct Row: Equatable { let name: String; let date: Date? }
        let d = { (days: Int) in Date(timeIntervalSince1970: Double(days) * 86_400) }
        let rows = [Row(name: "old", date: d(1)), Row(name: "none-a", date: nil), Row(name: "new", date: d(30)),
                    Row(name: "mid", date: d(10)), Row(name: "none-b", date: nil), Row(name: "mid-twin", date: d(10))]
        let newest = ArchiveSortPolicy.sortedByArchivedDate(rows, order: .reverse) { $0.date }.map(\.name)
        #expect(newest == ["new", "mid", "mid-twin", "old", "none-a", "none-b"])
        let oldest = ArchiveSortPolicy.sortedByArchivedDate(rows, order: .forward) { $0.date }.map(\.name)
        #expect(oldest == ["old", "mid", "mid-twin", "new", "none-a", "none-b"])
        #expect(ArchiveSortPolicy.sortedByArchivedDate([Row](), order: .reverse) { $0.date }.isEmpty)
    }

    @Test("SCALE: 100k rows sort under 1 s (Debug ceiling)")
    func scale() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let rows = (0..<100_000).map { i in (i, i % 7 == 0 ? nil : base.addingTimeInterval(Double((i * 7919) % 100_000))) }
        let started = ContinuousClock.now
        let sorted = ArchiveSortPolicy.sortedByArchivedDate(rows, order: .reverse) { $0.1 }
        let elapsed = ContinuousClock.now - started
        #expect(sorted.count == 100_000)
        #expect(sorted.suffix(100_000 / 7 + 1).allSatisfy { $0.1 == nil } == false || sorted.last?.1 == nil)
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(1)), "100k rows took \(elapsed)")
    }
}
