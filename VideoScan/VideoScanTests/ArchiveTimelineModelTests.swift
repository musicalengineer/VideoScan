import Foundation
import Testing
@testable import VideoScan

// Archive Timeline (docs/archive-view.md, first cut 2026-08-20).
// Dimensions: Logic (parse/title/grouping) + Scale (100k items, budget).
// Pure model — no media, no globals, so no matrix/isolation dimension.

@Suite("Archive timeline — path parsing")
struct ArchiveTimelinePathTests {

    @Test func decadeYearFromFolderLayout() {
        #expect(ArchiveTimelinePath.year(fromRelPath:
            "1990-1999/1997/1997-xx-xx_Family_CapeCod_1997.dv") == 1997)
        #expect(ArchiveTimelinePath.year(fromRelPath:
            "2000-2009/2003/2003-07-04_Fireworks.mov") == 2003)
    }

    @Test func filenameYearIsTheFallbackOutsideTheDecadeTree() {
        // A milestone photo in the scaffold's photo folder still dates.
        #expect(ArchiveTimelinePath.year(fromRelPath:
            "10_Photos/1988-06-11_Wedding.jpg") == 1988)
        // Undated stays undated.
        #expect(ArchiveTimelinePath.year(fromRelPath:
            "Undated/mystery_tape.mov") == nil)
        // Digits that are not a leading date prefix never win.
        #expect(ArchiveTimelinePath.year(fromRelPath:
            "Undated/copy2004backup_of_tape.mov") == nil)
    }

    @Test func folderBeatsFilenameWhenBothPresent() {
        // The disk placement is the truth even if the name disagrees.
        #expect(ArchiveTimelinePath.year(fromRelPath:
            "1990-1999/1996/1997-xx-xx_missed_by_one.dv") == 1996)
    }

    @Test func decadeFolderShape() {
        #expect(ArchiveTimelinePath.isDecadeFolder("1990-1999"))
        #expect(!ArchiveTimelinePath.isDecadeFolder("1990-1998"))
        #expect(!ArchiveTimelinePath.isDecadeFolder("Undated"))
        #expect(!ArchiveTimelinePath.isDecadeFolder("10_Photos"))
        #expect(!ArchiveTimelinePath.isDecadeFolder("199-1999"))
    }

    @Test func implausibleYearsRejected() {
        #expect(ArchiveTimelinePath.plausibleYear("1899") == nil)
        #expect(ArchiveTimelinePath.plausibleYear("2100") == nil)
        #expect(ArchiveTimelinePath.plausibleYear("1900") == 1900)
        #expect(ArchiveTimelinePath.plausibleYear("2099") == 2099)
    }

    @Test func friendlyDurationsReadLikeAStoryNotATimecode() {
        // Rick, RD round 1: "2:10:45" → "2 hr 10 min" (hour scale
        // truncates to the minute), minute scale rounds, tiny clips in
        // seconds, unknown stays silent.
        #expect(ArchiveTimelinePath.friendlyDuration(seconds: 7845) == "2 hr 10 min")   // 2:10:45
        #expect(ArchiveTimelinePath.friendlyDuration(seconds: 3600) == "1 hr")
        #expect(ArchiveTimelinePath.friendlyDuration(seconds: 754) == "13 min")         // 12:34 rounds up
        #expect(ArchiveTimelinePath.friendlyDuration(seconds: 90) == "2 min")
        #expect(ArchiveTimelinePath.friendlyDuration(seconds: 45) == "45 sec")
        #expect(ArchiveTimelinePath.friendlyDuration(seconds: 0).isEmpty)
        #expect(ArchiveTimelinePath.friendlyDuration(seconds: -3).isEmpty)
    }

    @Test func titleStripsDatePrefixAndUnderscores() {
        #expect(ArchiveTimelinePath.title(fromArchiveFilename:
            "1997-xx-xx_Family_CapeCod_1997.dv") == "Family CapeCod 1997")
        #expect(ArchiveTimelinePath.title(fromArchiveFilename:
            "2003-07-04_Fireworks_Middlefield.mov") == "Fireworks Middlefield")
        // No prefix → just the prettified stem.
        #expect(ArchiveTimelinePath.title(fromArchiveFilename:
            "Grandma_interview.wav") == "Grandma interview")
        // A name that is ONLY a date keeps the stem rather than vanishing.
        #expect(ArchiveTimelinePath.title(fromArchiveFilename:
            "1997-xx-xx.dv") == "1997-xx-xx")
    }
}

@Suite("Archive timeline — grouping")
struct ArchiveTimelineBuildTests {

    private func item(_ title: String, year: Int?, kind: ArchiveTimelineItem.Kind = .video) -> ArchiveTimelineItem {
        ArchiveTimelineItem(id: UUID(), title: title,
                            archiveFilename: title + ".mov",
                            relPath: year.map { "\(($0/10)*10)-\(($0/10)*10+9)/\($0)/\(title).mov" } ?? "Undated/\(title).mov",
                            year: year, kind: kind,
                            durationSeconds: 60, peopleText: "", isVerified: true)
    }

    @Test func decadesSpanIncludesInteriorGaps() {
        let tl = ArchiveTimeline.build(items: [
            item("Wedding", year: 1988),
            item("CapeCod", year: 1997),
            item("Graduation", year: 2014),
        ])
        // 1980s through 2010s inclusive — 1990s present, 2000s an honest gap.
        #expect(tl.decades.map(\.start) == [1980, 1990, 2000, 2010])
        #expect(tl.decades[2].isGap)
        #expect(!tl.decades[1].isGap)
        #expect(tl.datedCount == 3)
        #expect(tl.decades.first?.years.first?.year == 1988)
    }

    @Test func oldestFirstAndSortedWithinYear() {
        let tl = ArchiveTimeline.build(items: [
            item("zebra", year: 1997),
            item("Alpha", year: 1997),
            item("older", year: 1990),
        ])
        #expect(tl.decades.count == 1)
        #expect(tl.decades[0].years.map(\.year) == [1990, 1997])
        #expect(tl.decades[0].years[1].items.map(\.title) == ["Alpha", "zebra"])
    }

    @Test func undatedShelfIsSeparateAndSorted() {
        let tl = ArchiveTimeline.build(items: [
            item("mystery B", year: nil),
            item("mystery A", year: nil),
            item("dated", year: 2001),
        ])
        #expect(tl.undated.map(\.title) == ["mystery A", "mystery B"])
        #expect(tl.datedCount == 1)
    }

    @Test func emptyArchiveIsEmptyNotCrashy() {
        let tl = ArchiveTimeline.build(items: [])
        #expect(tl.isEmpty)
        #expect(tl.decades.isEmpty)
    }

    @Test func searchNarrowsByTitlePeopleAndPath() {
        var donna = item("Beach day", year: 1995)
        donna = ArchiveTimelineItem(id: donna.id, title: donna.title,
                                    archiveFilename: donna.archiveFilename,
                                    relPath: donna.relPath, year: donna.year,
                                    kind: donna.kind, durationSeconds: donna.durationSeconds,
                                    peopleText: "Donna, Rick", isVerified: true)
        let items = [donna, item("Garage", year: 2001)]
        #expect(ArchiveTimeline.build(items: items, matching: "donna").datedCount == 1)
        #expect(ArchiveTimeline.build(items: items, matching: "garage").datedCount == 1)
        #expect(ArchiveTimeline.build(items: items, matching: "2001").datedCount == 1)   // relPath
        #expect(ArchiveTimeline.build(items: items, matching: "").datedCount == 2)
        #expect(ArchiveTimeline.build(items: items, matching: "nobody").isEmpty)
    }

    // SCALE: the build runs on the main actor per records-version change;
    // 100k archived items (far beyond the real archive for years) must
    // group well under a UI-blocking budget.
    @Test func scale100kUnderBudget() {
        let items = (0..<100_000).map { i in
            item("Clip \(i)", year: i % 90 == 0 ? nil : 1950 + (i % 75))
        }
        let start = ContinuousClock.now
        let tl = ArchiveTimeline.build(items: items)
        let elapsed = ContinuousClock.now - start
        #expect(tl.datedCount + tl.undated.count == 100_000)
        #expect(elapsed < .seconds(2), "100k build took \(elapsed)")
    }
}
