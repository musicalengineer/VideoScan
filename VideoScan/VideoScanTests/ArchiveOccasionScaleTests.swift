import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// Occasion cues on the Archive decade page (Rick 2026-10-07). SCALE
// dimension (CLAUDE.md #2): the cues are derived and the per-year occasion
// strips grouped once per data change on the main actor (ArchiveView's
// timeline memo). 100k archived items — far beyond the real archive for
// years — must do both well under a UI-blocking budget, and every video
// must be counted in exactly one strip segment of its year.

@Suite("Archive occasion cues — 100k derivation + grouping budget")
struct ArchiveOccasionScaleTests {

    private static let folders = ["Christmas 1994", "Thanksgiving", "Timmy bday", "Camping Trip",
                                  "Lake George", "Halloween", "Tapes", "misc"]

    private func item(_ i: Int, year: Int, cue: ArchiveOccasionCue?) -> ArchiveTimelineItem {
        let title = "Clip \(i)"
        var item = ArchiveTimelineItem(
            id: UUID(), title: title, archiveFilename: title + ".mov",
            relPath: "\((year / 10) * 10)-\((year / 10) * 10 + 9)/\(year)/\(title).mov",
            year: year, kind: cue == nil ? .photo : .video,
            durationSeconds: Double(60 + i % 600), peopleText: "", isVerified: true)
        item.occasion = cue
        return item
    }

    @Test func derive100kCuesThroughTheAngelsReaderUnderBudget() {
        let reader = ArchiveAngel.OccasionReader()
        let now = Date()
        var memo = EventLabeler.FolderWordCache()
        let facts = (0..<100_000).map { i in
            ArchiveAngel.OccasionFacts(
                id: UUID(), filename: "clip\(i).mov",
                fullPath: "/Volumes/LaCie/Family/\(Self.folders[i % Self.folders.count])/d\(i % 500)/clip\(i).mov",
                userDate: String(1950 + i % 70))
        }
        let start = ContinuousClock.now
        let cues = facts.map { ArchiveOccasionCue.from(labels: reader.occasions(for: $0, now: now, folders: &memo).labels) }
        let elapsed = ContinuousClock.now - start

        var tally: [ArchiveOccasion: Int] = [:]
        for c in cues { tally[c.occasion, default: 0] += 1 }
        #expect(tally.values.reduce(0, +) == 100_000)
        #expect(tally[.christmas] == 12_500 && tally[.thanksgiving] == 12_500 && tally[.birthday] == 12_500)
        #expect(tally[.trip] == 25_000, "Camping Trip and Lake George are trips (new lexicon words)")
        #expect(tally[.other] == 12_500 && tally[.unlabeled] == 25_000)
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(4_000)), "100k occasion derivation took \(elapsed)")
    }

    @Test func group100kOccasionStripsUnderBudget() {
        // Four entries: co-prime with the 85 years, so every year gets a mix.
        let cues: [ArchiveOccasionCue?] = [
            ArchiveOccasionCue(occasion: .christmas, word: "Christmas", help: ""),
            ArchiveOccasionCue(occasion: .trip, word: "Camping", help: ""),
            .unlabeled,
            nil,                                                    // a photo: no cue
        ]
        let items = (0..<100_000).map { i in item(i, year: 1940 + i % 85, cue: cues[i % cues.count]) }

        let start = ContinuousClock.now
        let snap = ArchiveTimelineSnapshot.build(items: items, matching: "")
        let elapsed = ContinuousClock.now - start

        let years = snap.timeline.decades.flatMap(\.years)
        let counted = years.reduce(0) { $0 + $1.occasionStrip.segments.reduce(0) { $0 + $1.count } }
        #expect(counted == 75_000, "every video in exactly one segment; photos uncounted")
        for y in years {
            let total = y.occasionStrip.segments.reduce(0.0) { $0 + $1.fraction }
            #expect(abs(total - 1) < 1e-9, "\(y.year) strip fills its width")
            #expect(y.occasionStrip.segments.map(\.occasion)
                    == ArchiveOccasion.allCases.filter { o in y.occasionStrip.segments.contains { $0.occasion == o } },
                    "fixed category order")
            #expect(!y.occasionStrip.help.isEmpty)
        }
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(2)), "100k occasion grouping took \(elapsed)")
    }

    @Test func firstLabelWinsAndTripWordsFoldIntoTrip() {
        func cue(_ events: [String]) -> ArchiveOccasionCue {
            ArchiveOccasionCue.from(labels: events.map {
                EventLabel(event: $0, year: 1995, source: .name, why: .word(place: "file", word: $0))
            })
        }
        #expect(cue([]) == .unlabeled)
        #expect(cue(["christmas", "lake"]).occasion == .christmas)
        #expect(cue(["camp"]).occasion == .trip && cue(["camp"]).word == "Camping")
        #expect(cue(["lake"]).word == "Lake")
        #expect(cue(["halloween"]).occasion == .other && cue(["halloween"]).word == "Halloween")
        #expect(cue(["vacation"]).help == "Vacation 1995 — file name says 'vacation'")
    }
}
