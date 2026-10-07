import Foundation
import Testing
@testable import VideoScan

// Decade ribbon (Rick 2026-10-06). SCALE dimension (CLAUDE.md #2): the
// decade→year grouping + ribbon ticks are built once per data change on
// the main actor (ArchiveView.cachedTimeline). 100k archived items — far
// beyond the real archive for years — must group well under a
// UI-blocking budget, and every item must land on exactly one page.

@Suite("Archive decade ribbon — 100k grouping budget")
struct ArchiveDecadeRibbonScaleTests {

    private func item(_ i: Int, year: Int?) -> ArchiveTimelineItem {
        let title = "Clip \(i)"
        return ArchiveTimelineItem(
            id: UUID(), title: title, archiveFilename: title + ".mov",
            relPath: year.map { "\(($0 / 10) * 10)-\(($0 / 10) * 10 + 9)/\($0)/\(title).mov" } ?? "Undated/\(title).mov",
            year: year, kind: .video, durationSeconds: 60, peopleText: "", isVerified: true)
    }

    @Test func snapshot100kUnderBudget() {
        // 1940–2024 with every 90th item undated; the 1960s left empty so
        // the ribbon carries an interior gap.
        let items = (0..<100_000).map { i -> ArchiveTimelineItem in
            guard i % 90 != 0 else { return item(i, year: nil) }
            var y = 1940 + (i % 85)
            if (1960...1969).contains(y) { y += 10 }
            return item(i, year: y)
        }
        let start = ContinuousClock.now
        let snap = ArchiveTimelineSnapshot.build(items: items, matching: "")
        let elapsed = ContinuousClock.now - start

        #expect(snap.ticks.reduce(0) { $0 + $1.count } == 100_000, "every item on exactly one page")
        #expect(snap.ticks.map(\.id) == [1940, 1950, 1960, 1970, 1980, 1990, 2000, 2010, 2020,
                                         ArchiveDecadeTick.undatedID])
        #expect(snap.ticks.first { $0.id == 1960 }?.isGap == true, "the empty 1960s stay on the ribbon")
        #expect(snap.ticks.first { $0.id == 2020 }?.yearsWithMedia == Set(2020...2024))
        #expect(snap.page(selected: nil) == 1940, "default page is the oldest decade with media")
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(2)), "100k ribbon build took \(elapsed)")
    }
}
